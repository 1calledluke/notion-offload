import Foundation

enum NotionClient {
    private static func makeRequest(url: URL, method: String, token: String, body: Data?) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    static func isDuplicate(title: String, config: Config) -> Bool {
        guard let url = URL(string: "https://api.notion.com/v1/databases/\(config.documentsDB)/query") else {
            return false
        }
        let filterDict: [String: Any] = [
            "filter": [
                "property": "Name",
                "title": [
                    "equals": title
                ]
            ]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: filterDict) else { return false }
        let request = makeRequest(url: url, method: "POST", token: config.notionToken, body: bodyData)
        
        let semaphore = DispatchSemaphore(value: 0)
        var isDup = false
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard let data, let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]] {
                isDup = !results.isEmpty
            }
        }.resume()
        
        _ = semaphore.wait(timeout: .now() + 15)
        return isDup
    }

    /// Exact title match first; if that misses, fuzzy: folder names drift from
    /// Notion titles (folder "Graceway 50th Celebration" vs project
    /// "50th Celebration"), so accept the project whose title is contained in
    /// the extracted name — or vice versa — preferring the longest title.
    static func findProjectPageId(projectName: String, config: Config) -> String? {
        if let exact = queryProject(filter: ["property": "Name", "title": ["equals": projectName]],
                                    config: config).first?.id {
            return exact
        }
        // Fuzzy pass: list projects and score containment either direction.
        let all = queryProject(filter: nil, config: config)
        let wanted = projectName.lowercased()
        let candidates = all.filter { p in
            let t = p.title.lowercased()
            return !t.isEmpty && (wanted.contains(t) || t.contains(wanted))
        }
        if let best = candidates.max(by: { $0.title.count < $1.title.count }) {
            Log.write("Project fuzzy-matched: '\(projectName)' -> '\(best.title)'")
            return best.id
        }
        Log.write("No Notion project matched '\(projectName)' — page will have no relation")
        return nil
    }

    private static func queryProject(filter: [String: Any]?, config: Config)
        -> [(id: String, title: String)] {
        guard let url = URL(string: "https://api.notion.com/v1/databases/\(config.projectsDB)/query") else {
            return []
        }
        var out: [(String, String)] = []
        var cursor: String? = nil
        for _ in 0..<10 {   // up to 1000 projects
            var body: [String: Any] = ["page_size": 100]
            if let f = filter { body["filter"] = f }
            if let c = cursor { body["start_cursor"] = c }
            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { break }
            let request = makeRequest(url: url, method: "POST", token: config.notionToken, body: bodyData)

            let semaphore = DispatchSemaphore(value: 0)
            var page: [String: Any]? = nil
            URLSession.shared.dataTask(with: request) { data, response, _ in
                defer { semaphore.signal() }
                guard let data, let httpResp = response as? HTTPURLResponse,
                      (200...299).contains(httpResp.statusCode) else { return }
                page = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }.resume()
            _ = semaphore.wait(timeout: .now() + 15)

            guard let json = page, let results = json["results"] as? [[String: Any]] else { break }
            for r in results {
                guard let id = r["id"] as? String else { continue }
                let title = (((r["properties"] as? [String: Any])?["Name"] as? [String: Any])?["title"]
                    as? [[String: Any]])?.compactMap { $0["plain_text"] as? String }.joined() ?? ""
                out.append((id, title))
            }
            if json["has_more"] as? Bool == true, let next = json["next_cursor"] as? String {
                cursor = next
            } else { break }
        }
        return out
    }

    static func createTranscriptPage(clipName: String, paragraphs: [String], projectPageId: String?, config: Config) -> Bool {
        guard let url = URL(string: "https://api.notion.com/v1/pages") else { return false }
        
        let pageTitle = "\(clipName) — Transcript"
        
        // Build all block objects
        var allBlocks: [[String: Any]] = []
        
        // H2 header block
        let h2Block: [String: Any] = [
            "object": "block",
            "type": "heading_2",
            "heading_2": [
                "rich_text": [
                    [
                        "type": "text",
                        "text": ["content": "Transcript — \(clipName)"]
                    ]
                ]
            ]
        ]
        allBlocks.append(h2Block)
        
        // Note if project relation was not resolved
        if projectPageId == nil {
            let noteBlock: [String: Any] = [
                "object": "block",
                "type": "paragraph",
                "paragraph": [
                    "rich_text": [
                        [
                            "type": "text",
                            "text": ["content": "Note: Project relation could not be resolved from folder path."]
                        ]
                    ]
                ]
            ]
            allBlocks.append(noteBlock)
        }
        
        // Paragraph blocks
        for paraText in paragraphs {
            let pBlock: [String: Any] = [
                "object": "block",
                "type": "paragraph",
                "paragraph": [
                    "rich_text": [
                        [
                            "type": "text",
                            "text": ["content": paraText]
                        ]
                    ]
                ]
            ]
            allBlocks.append(pBlock)
        }
        
        let firstBatchCount = min(90, allBlocks.count)
        let firstBatch = Array(allBlocks.prefix(firstBatchCount))
        
        var properties: [String: Any] = [
            "Name": [
                "title": [
                    [
                        "text": ["content": pageTitle]
                    ]
                ]
            ],
            "Tags": [
                "multi_select": [
                    ["name": "Transcript"],
                    ["name": "Auto"]
                ]
            ]
        ]
        
        if let projectPageId {
            properties["Project"] = [
                "relation": [
                    ["id": projectPageId]
                ]
            ]
        }
        
        let pageDict: [String: Any] = [
            "parent": ["database_id": config.documentsDB],
            "properties": properties,
            "children": firstBatch
        ]
        
        guard let bodyData = try? JSONSerialization.data(withJSONObject: pageDict) else { return false }
        let request = makeRequest(url: url, method: "POST", token: config.notionToken, body: bodyData)
        
        let semaphore = DispatchSemaphore(value: 0)
        var createdPageId: String? = nil
        var success = false
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard let data, let httpResp = response as? HTTPURLResponse else {
                if let error { Log.write("Notion create page network error: \(error)") }
                return
            }
            if (200...299).contains(httpResp.statusCode) {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = json["id"] as? String {
                    createdPageId = id
                    success = true
                }
            } else {
                let respStr = String(data: data, encoding: .utf8) ?? ""
                Log.write("Notion create page failed (\(httpResp.statusCode)): \(respStr)")
            }
        }.resume()
        
        _ = semaphore.wait(timeout: .now() + 20)
        
        guard success, let pageId = createdPageId else { return false }
        
        // Append remaining blocks in batches of 90
        if allBlocks.count > firstBatchCount {
            var startIndex = firstBatchCount
            while startIndex < allBlocks.count {
                let endIndex = min(startIndex + 90, allBlocks.count)
                let batch = Array(allBlocks[startIndex..<endIndex])
                let patchSuccess = appendBlocks(pageId: pageId, blocks: batch, config: config)
                if !patchSuccess {
                    Log.write("Warning: failed to append block batch \(startIndex)..<\(endIndex) to page \(pageId)")
                }
                startIndex = endIndex
            }
        }
        
        return true
    }

    private static func appendBlocks(pageId: String, blocks: [[String: Any]], config: Config) -> Bool {
        guard let url = URL(string: "https://api.notion.com/v1/blocks/\(pageId)/children") else { return false }
        let payload: [String: Any] = ["children": blocks]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        let request = makeRequest(url: url, method: "PATCH", token: config.notionToken, body: bodyData)
        
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard let data, let httpResp = response as? HTTPURLResponse else { return }
            if (200...299).contains(httpResp.statusCode) {
                success = true
            } else {
                let respStr = String(data: data, encoding: .utf8) ?? ""
                Log.write("Notion patch children failed (\(httpResp.statusCode)): \(respStr)")
            }
        }.resume()
        
        _ = semaphore.wait(timeout: .now() + 20)
        return success
    }
}
