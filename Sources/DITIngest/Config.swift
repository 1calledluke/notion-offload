import Foundation

/// Remembers last-used paths and settings between runs, stored as JSON in
/// ~/Library/Application Support/DITIngest/config.json.
struct Config: Codable {
    var dumpLocation: String = ""
    var backupLocation1: String = ""
    var backupLocation2: String = ""
    var justDump: Bool = false
    var autoTranscribe: Bool = true
    /// Read-only GitHub token for update checks on machines without the gh CLI
    var githubToken: String = ""
    var notionToken: String = ""
    var notionProjectsDB: String = "232714d3-333f-80c8-88fd-d1eefeed3b3f"

    // Transcription (merged in from Notion Transcribe)
    var documentsDB: String = "240714d3-333f-80ae-b147-e1bc122f0c86"
    var whisperModel: String = NSHomeDirectory() + "/Models/ggml-large-v3-turbo.bin"
    var minClipSeconds: Double = 60      // b-roll gate
    var lastFolder: String = ""

    // Transcription code was written against `projectsDB`/`documentsDB`.
    var projectsDB: String { notionProjectsDB }

    init() {}

    /// Tolerant decoder: any key missing from the JSON uses its default rather
    /// than failing the whole decode. Without this, adding a new field would
    /// wipe every existing config (Swift throws keyNotFound for missing
    /// non-optional keys even when they have defaults) — which silently emptied
    /// the Notion token when transcription fields were added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        dumpLocation     = try c.decodeIfPresent(String.self, forKey: .dumpLocation) ?? d.dumpLocation
        backupLocation1  = try c.decodeIfPresent(String.self, forKey: .backupLocation1) ?? d.backupLocation1
        backupLocation2  = try c.decodeIfPresent(String.self, forKey: .backupLocation2) ?? d.backupLocation2
        justDump         = try c.decodeIfPresent(Bool.self, forKey: .justDump) ?? d.justDump
        autoTranscribe   = try c.decodeIfPresent(Bool.self, forKey: .autoTranscribe) ?? d.autoTranscribe
        githubToken      = try c.decodeIfPresent(String.self, forKey: .githubToken) ?? d.githubToken
        notionToken      = try c.decodeIfPresent(String.self, forKey: .notionToken) ?? d.notionToken
        notionProjectsDB = try c.decodeIfPresent(String.self, forKey: .notionProjectsDB) ?? d.notionProjectsDB
        documentsDB      = try c.decodeIfPresent(String.self, forKey: .documentsDB) ?? d.documentsDB
        whisperModel     = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        minClipSeconds   = try c.decodeIfPresent(Double.self, forKey: .minClipSeconds) ?? d.minClipSeconds
        lastFolder       = try c.decodeIfPresent(String.self, forKey: .lastFolder) ?? d.lastFolder
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("DITIngest/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return cfg
    }

    func save() {
        let url = Config.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url)
        }
    }
}
