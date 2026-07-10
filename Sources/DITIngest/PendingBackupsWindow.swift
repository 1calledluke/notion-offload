import AppKit
import SwiftUI
import Foundation

@MainActor
final class PendingBackupsModel: ObservableObject {
    @Published var runs: [IncompleteRun]
    weak var appDelegate: AppDelegate?
    weak var controller: PendingBackupsController?

    init(runs: [IncompleteRun], appDelegate: AppDelegate?, controller: PendingBackupsController?) {
        self.runs = runs
        self.appDelegate = appDelegate
        self.controller = controller
    }

    func retry(_ run: IncompleteRun) {
        appDelegate?.openResume(run)
        // Only drop the row — the resume itself logs "backup complete" when it
        // actually succeeds. Writing the marker here would mask a failed retry.
        dropRow(run)
    }

    func remove(_ run: IncompleteRun) {
        Log.write("user marked card folder as handled -> \(run.ssdCardFolder.path)")
        Log.write("backup complete -> dest: \(run.ssdCardFolder.path)")
        Log.flush()
        dropRow(run)
    }

    private func dropRow(_ run: IncompleteRun) {
        // Key by folder path: a mixed card's Stills and Video rows share a name.
        runs.removeAll { $0.ssdCardFolder.path == run.ssdCardFolder.path }
        if runs.isEmpty {
            controller?.close()
        }
    }

    func close() {
        controller?.close()
    }
}

@MainActor
final class PendingBackupsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: PendingBackupsModel
    private weak var appDelegate: AppDelegate?

    init(runs: [IncompleteRun], appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        self.model = PendingBackupsModel(runs: runs, appDelegate: appDelegate, controller: nil)
        super.init()
        self.model.controller = self
    }

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PendingBackupsView(model: model)
        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Pending Backups"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 320))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func updateRuns(_ newRuns: [IncompleteRun]) {
        model.runs = newRuns
        show()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        appDelegate?.pendingBackupsWindowClosed()
    }
}

struct PendingBackupsView: View {
    @ObservedObject var model: PendingBackupsModel

    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            VStack(spacing: 0) {
                if model.runs.isEmpty {
                    emptyView
                } else {
                    listView
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 460, height: 320)
    }

    private var headerView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "externaldrive.fill.badge.plus")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pending Backups")
                        .font(.title3)
                        .bold()
                    Text("Resolve interrupted media ingest runs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            
            Divider()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("No pending backups. 🎉")
                .font(.body)
                .foregroundStyle(.secondary)
            
            Button("Close") {
                model.close()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listView: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(model.runs, id: \.ssdCardFolder.path) { run in
                    runRow(run)
                }
            }
            .padding(16)
        }
    }

    private func runRow(_ run: IncompleteRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(run.displayName)
                .font(.headline)
            
            let missingDirs = run.backupDirs.filter { !run.verifiedDirs.contains($0) }
            let missingLocations = missingDirs.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
            Text("Missing: \(missingLocations)")
                .font(.callout)
                .foregroundStyle(.secondary)
            
            Text("SSD copy: \(run.ssdCardFolder.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(run.ssdCardFolder.path)
            
            HStack {
                Spacer()
                
                Button("Remove") {
                    model.remove(run)
                }
                .buttonStyle(.bordered)
                
                Button("Retry ▶") {
                    model.retry(run)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
}
