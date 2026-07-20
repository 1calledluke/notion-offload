import AppKit
import SwiftUI

/// Menu-bar "Settings…" window: lets a fresh install (e.g. a coworker's copied
/// .app) paste the Notion integration token without touching config files.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        appDelegate?.settingsWindowClosed()
    }
}

struct SettingsView: View {
    @State private var token: String
    @State private var projectsDB: String
    @State private var showToken = false
    @State private var testResult: String? = nil
    @State private var testing = false
    @State private var saved = false

    init() {
        let cfg = Config.load()
        _token = State(initialValue: cfg.notionToken)
        _projectsDB = State(initialValue: cfg.notionProjectsDB)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NOTION")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Integration token")
                    .font(.callout)
                HStack(spacing: 6) {
                    Group {
                        if showToken {
                            TextField("ntn_…", text: $token)
                        } else {
                            SecureField("ntn_…", text: $token)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    Button {
                        showToken.toggle()
                    } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .help(showToken ? "Hide token" : "Show token")
                }
                Text("Create one at notion.so/my-integrations, share the Projects database with it, then paste the token here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Projects database ID")
                    .font(.callout)
                TextField("", text: $projectsDB)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            HStack(spacing: 10) {
                Button(testing ? "Testing…" : "Test Connection") {
                    testConnection()
                }
                .disabled(testing || token.isEmpty)

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("✓") ? .green : .red)
                }

                Spacer()

                if saved {
                    Text("Saved ✓")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Button("Save") {
                    var cfg = Config.load()
                    cfg.notionToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    cfg.notionProjectsDB = projectsDB.trimmingCharacters(in: .whitespacesAndNewlines)
                    cfg.save()
                    saved = true
                    Log.write("settings saved (Notion token \(token.isEmpty ? "cleared" : "updated"))")
                }
                .buttonStyle(.borderedProminent)
                .disabled(token.isEmpty && projectsDB.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onChange(of: token) { _, _ in saved = false; testResult = nil }
        .onChange(of: projectsDB) { _, _ in saved = false; testResult = nil }
    }

    private func testConnection() {
        testing = true
        testResult = nil
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let db = projectsDB.trimmingCharacters(in: .whitespacesAndNewlines)
        Task.detached {
            let projects = Notion.listProjects(token: t, databaseID: db)
            let ok = !projects.isEmpty && projects.first?.id != ""
            await MainActor.run {
                testing = false
                testResult = ok
                    ? "✓ Connected — \(projects.count) projects found"
                    : "✗ No projects returned — check the token and that the database is shared with the integration"
            }
        }
    }
}
