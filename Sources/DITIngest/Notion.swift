import Foundation

struct Project {
    let name: String
    let id: String
    let clientName: String   // "" if no client relation exists
    let jobCode: String      // "" if missing
}

/// Talks to Notion. For now it only lists active projects for the picker.
/// Until a token is set, it returns a placeholder list so the UI is testable.
enum Notion {
    static let version = "2022-06-28"
    static let placeholder = [Project(name: "(Notion not connected — set up token)", id: "", clientName: "", jobCode: "")]

    /// Synchronously fetch project names (paginated — handles >100 projects).
    /// Returns placeholder on any failure.
    static func listProjects(token: String, databaseID: String) -> [Project] {
        guard !token.isEmpty else { return placeholder }

        var parsed: [(name: String, id: String, clientID: String?, jobCode: String)] = []
        var startCursor: String? = nil
        var pageCount = 0

        repeat {
            let url = URL(string: "https://api.notion.com/v1/databases/\(databaseID)/query")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(version, forHTTPHeaderField: "Notion-Version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["page_size": 100]
            if let cursor = startCursor { body["start_cursor"] = cursor }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let sem = DispatchSemaphore(value: 0)
            var nextCursor: String? = nil
            URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { sem.signal() }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else { return }
                for page in results {
                    guard let id = page["id"] as? String else { continue }
                    if let title = extractTitle(page) {
                        let clientID = extractClientPageID(page)
                        let jobCode = extractJobCode(page)
                        parsed.append((name: title, id: id, clientID: clientID, jobCode: jobCode))
                    }
                }
                if json["has_more"] as? Bool == true {
                    nextCursor = json["next_cursor"] as? String
                }
            }.resume()
            _ = sem.wait(timeout: .now() + 30)

            startCursor = nextCursor
            pageCount += 1
        } while startCursor != nil && pageCount < 10

        if parsed.isEmpty {
            return placeholder
        }

        let uniqueClientIDs = Set(parsed.compactMap { $0.clientID })
        var clientNames: [String: String] = [:]
        for clientID in uniqueClientIDs {
            if let title = fetchPageTitle(token: token, pageID: clientID) {
                clientNames[clientID] = title
            }
        }

        var projects: [Project] = []
        for p in parsed {
            let clientName = p.clientID.flatMap { clientNames[$0] } ?? ""
            projects.append(Project(name: p.name, id: p.id, clientName: clientName, jobCode: p.jobCode))
        }

        return projects.sorted(by: { $0.name < $1.name })
    }

    static func postComment(token: String, pageID: String, text: String) -> Bool {
        guard !token.isEmpty, !pageID.isEmpty else { return false }

        let url = URL(string: "https://api.notion.com/v1/comments")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(version, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "parent": ["page_id": pageID],
            "rich_text": [
                [
                    "text": ["content": text]
                ]
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let sem = DispatchSemaphore(value: 0)
        var success = false
        URLSession.shared.dataTask(with: req) { data, response, _ in
            defer { sem.signal() }
            if let httpResponse = response as? HTTPURLResponse {
                success = (httpResponse.statusCode == 200)
                if !success {
                    if let data = data, let str = String(data: data, encoding: .utf8) {
                        Log.write("Notion comment failed (HTTP \(httpResponse.statusCode)): \(str)")
                    }
                }
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 30)

        return success
    }

    private static func extractTitle(_ page: [String: Any]) -> String? {
        guard let props = page["properties"] as? [String: Any] else { return nil }
        for value in props.values {
            if let prop = value as? [String: Any],
               prop["type"] as? String == "title",
               let title = prop["title"] as? [[String: Any]] {
                let text = title.compactMap { $0["plain_text"] as? String }.joined()
                return text.isEmpty ? nil : text
            }
        }
        return nil
    }

    private static func extractClientPageID(_ page: [String: Any]) -> String? {
        guard let props = page["properties"] as? [String: Any] else { return nil }
        for (key, value) in props {
            if key.caseInsensitiveCompare("Client") == .orderedSame {
                if let prop = value as? [String: Any],
                   prop["type"] as? String == "relation",
                   let relation = prop["relation"] as? [[String: Any]],
                   let first = relation.first,
                   let id = first["id"] as? String {
                    return id
                }
            }
        }
        return nil
    }

    private static func extractJobCode(_ page: [String: Any]) -> String {
        guard let props = page["properties"] as? [String: Any],
              let prop = props["Job Code"] as? [String: Any],
              prop["type"] as? String == "formula",
              let formula = prop["formula"] as? [String: Any] else {
            return ""
        }
        let formulaType = formula["type"] as? String
        if formulaType == "string", let stringVal = formula["string"] as? String {
            return stringVal
        } else if formulaType == "number" {
            if let numVal = formula["number"] as? Double {
                return String(format: "%.0f", numVal)
            } else if let numVal = formula["number"] as? Int {
                return String(numVal)
            }
        }
        // Fallbacks without checking formulaType explicitly
        if let stringVal = formula["string"] as? String {
            return stringVal
        }
        if let numVal = formula["number"] as? Double {
            return String(format: "%.0f", numVal)
        }
        if let numVal = formula["number"] as? Int {
            return String(numVal)
        }
        return ""
    }

    private static func fetchPageTitle(token: String, pageID: String) -> String? {
        let url = URL(string: "https://api.notion.com/v1/pages/\(pageID)")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(version, forHTTPHeaderField: "Notion-Version")
        let sem = DispatchSemaphore(value: 0)
        var title: String? = nil
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            title = extractTitle(json)
        }.resume()
        _ = sem.wait(timeout: .now() + 15)
        return title
    }
}
