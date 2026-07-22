import Foundation

/// The "Media Log" Notion database — the studio's reporting spine. Every card
/// dump becomes a row: where the footage lives (dump + backups), what it is
/// (camera, type, dates, size), and its transcription status + transcript link.
/// Answers "where is my footage / is it backed up / is it transcribed."
///
/// Notion's API can't create a database at the workspace root, so the DB is
/// created inside a page the user shared with the integration
/// (Config.mediaParentPage). Best-effort throughout: any failure logs and
/// returns nil/no-op — logging must never break a dump.
enum MediaLog {
    private static let apiVersion = "2022-06-28"

    // MARK: - HTTP (sync, matches the rest of the app)

    private static func send(_ urlString: String, method: String,
                             body: [String: Any]?, token: String) -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(apiVersion, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }

        let sema = DispatchSemaphore(value: 0)
        var out: [String: Any]? = nil
        URLSession.shared.dataTask(with: req) { data, response, _ in
            defer { sema.signal() }
            guard let data, let http = response as? HTTPURLResponse else { return }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if (200...299).contains(http.statusCode) {
                out = json ?? [:]
            } else {
                Log.write("Media Log \(method) \(url.lastPathComponent) failed (\(http.statusCode)): \((json?["message"] as? String) ?? "?")")
            }
        }.resume()
        _ = sema.wait(timeout: .now() + 15)
        return out
    }

    private static func rt(_ s: String) -> [String: Any] {
        ["rich_text": [["text": ["content": String(s.prefix(1900))]]]]
    }

    // MARK: - Database creation / discovery

    /// A usable Media Log database id, creating it if necessary. Order:
    /// saved id → search by title → create under the shared parent page → nil.
    static func ensureDatabase(config: Config) -> String? {
        let token = config.notionToken
        guard !token.isEmpty else { return nil }

        // 1) Saved id still valid?
        if !config.mediaDB.isEmpty,
           send("https://api.notion.com/v1/databases/\(config.mediaDB)", method: "GET",
                body: nil, token: token) != nil {
            return config.mediaDB
        }

        // 2) Existing "Media Log" the integration can see.
        if let found = send("https://api.notion.com/v1/search", method: "POST",
                            body: ["query": "Media Log",
                                   "filter": ["value": "database", "property": "object"]],
                            token: token),
           let results = found["results"] as? [[String: Any]] {
            for db in results {
                let title = ((db["title"] as? [[String: Any]]) ?? [])
                    .compactMap { ($0["plain_text"] as? String) }.joined()
                if title == "Media Log", let id = db["id"] as? String {
                    saveDBID(id); return id
                }
            }
        }

        // 3) Create it inside the shared parent page.
        guard !config.mediaParentPage.isEmpty else {
            Log.write("Media Log: no database yet. Create a Notion page, share it with the integration, and set its id as mediaParentPage in config — then dumps will be logged.")
            return nil
        }
        let schema: [String: Any] = [
            "Card": ["title": [:] as [String: Any]],
            "Project": ["relation": ["database_id": config.notionProjectsDB,
                                     "single_property": [:] as [String: Any]]],
            "Camera": ["rich_text": [:] as [String: Any]],
            "Type": ["select": ["options": [["name": "Video"], ["name": "Stills"], ["name": "Audio"]]]],
            "Dates": ["rich_text": [:] as [String: Any]],
            "Files": ["number": [:] as [String: Any]],
            "Size": ["rich_text": [:] as [String: Any]],
            "Dump Location": ["rich_text": [:] as [String: Any]],
            "Backup 1": ["rich_text": [:] as [String: Any]],
            "Backup 2": ["rich_text": [:] as [String: Any]],
            "Transcription": ["select": ["options": [["name": "N/A"], ["name": "Pending"], ["name": "Done"]]]],
            "Transcript": ["url": [:] as [String: Any]],
            "Dumped": ["date": [:] as [String: Any]],
        ]
        let body: [String: Any] = [
            "parent": ["type": "page_id", "page_id": config.mediaParentPage],
            "title": [["type": "text", "text": ["content": "Media Log"]]],
            "properties": schema,
        ]
        guard let created = send("https://api.notion.com/v1/databases", method: "POST",
                                 body: body, token: token),
              let id = created["id"] as? String else { return nil }
        Log.write("Media Log database created -> \(id)")
        saveDBID(id)
        return id
    }

    private static func saveDBID(_ id: String) {
        var cfg = Config.load()
        cfg.mediaDB = id
        cfg.save()
    }

    // MARK: - Rows

    /// Existing row's page id for a Card title, or nil.
    private static func findRow(dbID: String, card: String, token: String) -> String? {
        guard let res = send("https://api.notion.com/v1/databases/\(dbID)/query", method: "POST",
                             body: ["filter": ["property": "Card", "title": ["equals": card]]],
                             token: token),
              let results = res["results"] as? [[String: Any]] else { return nil }
        return results.first?["id"] as? String
    }

    /// Create or update the row for a card dump (idempotent by Card title).
    @discardableResult
    static func upsertDump(card: String, projectPageId: String?, camera: String,
                           type: String, dates: String, files: Int, size: String,
                           dumpLocation: String, backup1: String, backup2: String,
                           config: Config) -> String? {
        guard let dbID = ensureDatabase(config: config) else { return nil }
        let token = config.notionToken

        var props: [String: Any] = [
            "Card": ["title": [["text": ["content": card]]]],
            "Camera": rt(camera),
            "Type": ["select": ["name": type]],
            "Dates": rt(dates),
            "Files": ["number": files],
            "Size": rt(size),
            "Dump Location": rt(dumpLocation),
            "Backup 1": rt(backup1),
            "Backup 2": rt(backup2),
            "Dumped": ["date": ["start": isoDate()]],
        ]
        if let pid = projectPageId, !pid.isEmpty {
            props["Project"] = ["relation": [["id": pid]]]
        }

        if let existing = findRow(dbID: dbID, card: card, token: token) {
            _ = send("https://api.notion.com/v1/pages/\(existing)", method: "PATCH",
                     body: ["properties": props], token: token)
            return existing
        }
        guard let created = send("https://api.notion.com/v1/pages", method: "POST",
                                 body: ["parent": ["database_id": dbID], "properties": props],
                                 token: token),
              let id = created["id"] as? String else { return nil }
        Log.write("Media Log row created -> \(card)")
        return id
    }

    /// Update just the transcription status + transcript link on a card's row.
    static func setTranscription(card: String, status: String, transcriptURL: String?,
                                 config: Config) {
        guard let dbID = ensureDatabase(config: config) else { return }
        let token = config.notionToken
        guard let pageID = findRow(dbID: dbID, card: card, token: token) else {
            Log.write("Media Log: no row for \(card) to set transcription \(status)")
            return
        }
        var props: [String: Any] = ["Transcription": ["select": ["name": status]]]
        if let url = transcriptURL, !url.isEmpty { props["Transcript"] = ["url": url] }
        _ = send("https://api.notion.com/v1/pages/\(pageID)", method: "PATCH",
                 body: ["properties": props], token: token)
    }

    private static func isoDate() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
