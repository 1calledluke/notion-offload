import AppKit
import SwiftUI

@MainActor
final class ProgressController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    weak var appDelegate: AppDelegate?
    let model = ProgressModel()

    init(appDelegate: AppDelegate?) { self.appDelegate = appDelegate }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: TranscribeProgressView(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.title = "Transcription"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(NSSize(width: 440, height: 260))
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func beginJob(folder: URL) {
        model.folderName = folder.lastPathComponent
        model.line = "Scanning…"
        model.done = false
        model.log.removeAll()
    }

    func update(line: String) {
        model.line = line
        // Keep a short scrollback of clip lines.
        if line.hasPrefix("Transcribing ") {
            model.log.append(line)
            if model.log.count > 200 { model.log.removeFirst(model.log.count - 200) }
        }
    }

    func finishJob() {
        model.line = "Done ✓"
        model.done = true
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        appDelegate?.progressWindowClosed()
    }
}

final class ProgressModel: ObservableObject {
    @Published var folderName: String = ""
    @Published var line: String = "Idle"
    @Published var done: Bool = false
    @Published var log: [String] = []
}

struct TranscribeProgressView: View {
    @ObservedObject var model: ProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.done ? "checkmark.circle.fill" : "waveform")
                    .font(.title2)
                    .foregroundStyle(model.done ? .green : .accentColor)
                    .symbolEffect(.pulse, isActive: !model.done)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.folderName.isEmpty ? "Notion Transcribe" : model.folderName)
                        .font(.headline)
                        .lineLimit(1).truncationMode(.middle)
                    Text(model.line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }

            if !model.done {
                SwiftUI.ProgressView().progressViewStyle(.linear)
            }

            if !model.log.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(model.log.enumerated()), id: \.offset) { i, l in
                                Text(l)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                    .id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    .onChange(of: model.log.count) { _, n in
                        withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) }
                    }
                }
            }

            Spacer(minLength: 0)
            Text("Transcripts post to Notion as each clip finishes. You can close this window; the job keeps running in the menu bar.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 260)
    }
}
