import Foundation

/// Persistent record of the last transcription job, so a crash/quit mid-run
/// can be resumed from the menu. The Notion child-page check is the real
/// source of truth (already-posted clips are skipped); this file just knows
/// WHICH folder was in flight and how far it got.
struct JobState: Codable {
    var folderPath: String
    var startedAt: Date
    var totalClips: Int
    var doneClips: [String]
    var finished: Bool

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotionTranscribe/job.json")
    }

    static func load() -> JobState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(JobState.self, from: data)
    }

    func save() {
        let url = JobState.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url)
        }
    }

    /// The folder to offer in "Resume Last Job", or nil when nothing's pending.
    static func resumable() -> JobState? {
        guard let s = load(), !s.finished,
              FileManager.default.fileExists(atPath: s.folderPath) else { return nil }
        return s
    }
}
