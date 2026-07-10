import Foundation

/// Tiny append-only logger so we can see what the app is doing without a GUI.
/// Writes to ~/Library/Application Support/DITIngest/app.log.
enum Log {
    static var logFileURL: URL {
        return url
    }

    private static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DITIngest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // All writes go through one serial queue so concurrent backup tasks
    // can't interleave partial lines in the log file.
    private static let queue = DispatchQueue(label: "DITIngest.log")

    /// Blocks until all queued writes have hit the file. Call before reading
    /// the log back (e.g. the resume detector re-checking after a write).
    static func flush() {
        queue.sync {}
    }

    static func write(_ message: String) {
        let now = Date()
        queue.async {
            let line = "[\(formatter.string(from: now))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
