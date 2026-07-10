import AppKit

// Entry point. We run as an "accessory" app: no Dock icon, lives in the menu bar.
// Top-level code isn't automatically on the main actor, so we assert it here
// (this code does run on the main thread).
// Headless self-test path (no GUI): exercises the real engine and exits.
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
