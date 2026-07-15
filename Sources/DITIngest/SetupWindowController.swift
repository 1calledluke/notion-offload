import AppKit
import SwiftUI

/// Hosts the SwiftUI setup form in a real, native window. Multiple controllers
/// can exist at once (one per card). Closing the window does NOT stop a running
/// transfer — the model keeps working and reports via the menu bar.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: SetupModel
    private weak var appDelegate: AppDelegate?

    init(sourceURL: URL, appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
        self.model = SetupModel(sourceURL: sourceURL, appDelegate: appDelegate)
    }

    init(resumeRun: IncompleteRun, appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        self.model = SetupModel(resumeRun: resumeRun, appDelegate: appDelegate)
    }

    func show() {
        let view = SetupView(model: model) { [weak self] in self?.close() }
        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hosting)
        window.title = "DIT Media Ingest"
        window.styleMask = [.titled, .closable, .resizable]
        window.setFrame(NSRect(x: 0, y: 0, width: 680, height: 860), display: false)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()   // triggers windowWillClose for the cleanup
    }

    // Covers both the Cancel/Done buttons (via close()) and the red button.
    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        appDelegate?.setupWindowClosed(self)
    }
}
