import AppKit

// Entry point. We run as an "accessory" app: no Dock icon, lives in the menu bar.
// Top-level code isn't automatically on the main actor, so we assert it here
// (this code does run on the main thread).
// Headless self-test path (no GUI): exercises the real engine and exits.
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

// Headless detection check: `DITIngest --detect /path/to/card-or-folder`
// prints what the camera detector would decide. Handy for tuning.
if let i = CommandLine.arguments.firstIndex(of: "--detect"),
   CommandLine.arguments.count > i + 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    print(Engine.detectDevice(in: url) ?? "(no detection)")
    exit(0)
}

// Headless transcription: `DITIngest --transcribe /path/to/folder`.
if let i = CommandLine.arguments.firstIndex(of: "--transcribe"),
   CommandLine.arguments.count > i + 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let sema = DispatchSemaphore(value: 0)
    Task.detached {
        await TranscriptionPipeline().run(folderURL: url) { print("status: \($0)"); fflush(stdout) }
        sema.signal()
    }
    sema.wait()
    Log.flush()   // async logger — flush before the process exits
    exit(0)
}

// Headless Media Log check: `DITIngest --mediadb-test`
if CommandLine.arguments.contains("--mediadb-test") {
    let cfg = Config.load()
    if let db = MediaLog.ensureDatabase(config: cfg) {
        print("Media Log DB: \(db)")
        let row = MediaLog.upsertDump(card: "TEST_CARD_zz", projectPageId: nil,
                                      camera: "Test Cam", type: "Video",
                                      dates: "Jul 21", files: 3, size: "148 GB",
                                      dumpLocation: "/Volumes/SSD/test",
                                      backup1: "/Volumes/Backup1/test", backup2: "",
                                      config: cfg)
        print("row: \(row ?? "(failed)")")
    } else {
        print("No Media Log DB — set mediaParentPage in config (share a Notion page with the integration).")
    }
    Log.flush()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
