import Foundation

enum ProjectResolver {
    private static let folderRegex = try! NSRegularExpression(pattern: "^\\d{2}\\.\\d{2}_(.+?)(_\\d+)?$")

    static func extractProjectName(fromFolderPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let components = url.pathComponents.reversed()
        for component in components {
            if component == "/" || component.isEmpty { continue }
            let range = NSRange(component.startIndex..<component.endIndex, in: component)
            if let match = folderRegex.firstMatch(in: component, options: [], range: range) {
                if let nameRange = Range(match.range(at: 1), in: component) {
                    let name = String(component[nameRange]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        return name
                    }
                }
            }
        }
        return nil
    }
}
