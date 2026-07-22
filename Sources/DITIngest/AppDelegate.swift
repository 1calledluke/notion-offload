import AppKit
import UserNotifications

/// The always-running brain of the app: owns the menu-bar icon and menu,
/// watches for inserted cards, and coordinates an ingest run.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var diskWatcher: DiskWatcher!
    private let statusMenuItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")

    // One window per card — multiple ingests can run at once.
    private var setupControllers: [SetupWindowController] = []
    private var pendingBackupsController: PendingBackupsController?

    // Live status per running job, keyed by the job's ID. The menu bar shows
    // the aggregate of all running jobs.
    private struct JobStatus { var text: String; var short: String }
    private var jobs: [UUID: JobStatus] = [:]

    // SSD card-folder paths whose backup is currently running. Prevents a
    // second concurrent backup of the same folder (e.g. impatient re-clicks of
    // Retry), which would race writers on the destination drive.
    private var activeBackupDests: Set<String> = []
    func beginBackup(_ dest: String) { activeBackupDests.insert(dest) }
    func endBackup(_ dest: String) { activeBackupDests.remove(dest) }
    func isBackupActive(_ dest: String) -> Bool { activeBackupDests.contains(dest) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("App launched")
        setupStatusItem()
        requestNotificationPermission()

        // Debug: `--show-setup <folder>` opens the ingest window directly for
        // UI/clipping inspection (regular activation so the window is visible).
        if let i = CommandLine.arguments.firstIndex(of: "--show-setup"),
           CommandLine.arguments.count > i + 1 {
            NSApp.setActivationPolicy(.regular)
            let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            openSetup(for: url)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Start watching for newly mounted volumes (cards, readers, SSDs).
        diskWatcher = DiskWatcher { [weak self] volumeURL in
            self?.handleInsertedVolume(volumeURL)
        }
        diskWatcher.start()
        checkForIncompleteRun()

        // Register to launch at login (quietly; ignored if already registered).
        LoginItem.enable()

        // Silent update check on launch (speaks only if a release is newer).
        UpdateChecker.check(interactive: false)
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "externaldrive.fill.badge.plus",
                                   accessibilityDescription: "DIT Media Ingest")
        }

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Run Ingest…",
                                action: #selector(runIngestManually),
                                keyEquivalent: "i"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Pending Backups…",
                                action: #selector(openPendingBackupsMenu),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Transcription Progress…",
                                action: #selector(showTranscriptionProgress),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Transcribe Folder…",
                                action: #selector(transcribeFolderMenu),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…",
                                action: #selector(openSettingsMenu),
                                keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Check for Updates…",
                                action: #selector(checkForUpdatesMenu),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DIT Media Ingest",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// Update (or add) a running job's status. The menu bar shows all jobs.
    func updateJob(_ id: UUID, text: String, short: String) {
        jobs[id] = JobStatus(text: text, short: short)
        renderJobs()
    }

    /// Remove a finished/failed job from the menu bar.
    func clearJob(_ id: UUID) {
        jobs.removeValue(forKey: id)
        renderJobs()
    }

    private func renderJobs() {
        if jobs.isEmpty {
            statusMenuItem.title = "Idle"
            statusItem.button?.title = ""
        } else {
            statusMenuItem.title = jobs.values.map { $0.text }.joined(separator: "   •   ")
            statusItem.button?.title = " " + jobs.values.map { $0.short }.joined(separator: " ")
        }
    }

    // MARK: - Triggers

    private func handleInsertedVolume(_ volumeURL: URL) {
        Log.write("Prompting for inserted volume: \(volumeURL.path)")
        // Ask the standard yes/no, then open setup if yes.
        let alert = NSAlert()
        alert.messageText = "Would you like to run media ingest?"
        alert.informativeText = volumeURL.lastPathComponent
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSetup(for: volumeURL)
        }
    }

    @objc private func runIngestManually() {
        // Manual path: let the user choose a volume/folder to ingest.
        let panel = NSOpenPanel()
        panel.title = "Select the card / volume to ingest"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            openSetup(for: url)
        }
    }

    private func openSetup(for volumeURL: URL) {
        let controller = SetupWindowController(sourceURL: volumeURL, appDelegate: self)
        setupControllers.append(controller)
        controller.show()
    }

    private func checkForIncompleteRun() {
        let runs = pendingRuns()
        guard !runs.isEmpty else { return }
        showPendingBackups(runs)
    }

    /// Incomplete runs, minus any whose backup is actively running right now, so
    /// the panel never offers a "Retry" for a job already in progress.
    private func pendingRuns() -> [IncompleteRun] {
        ResumeDetector.findIncompleteRuns(logPath: Log.logFileURL)
            .filter { !activeBackupDests.contains($0.ssdCardFolder.path) }
    }

    func showPendingBackups(_ runs: [IncompleteRun]) {
        let filtered = runs.filter { !activeBackupDests.contains($0.ssdCardFolder.path) }
        if let controller = pendingBackupsController {
            controller.updateRuns(filtered)
        } else {
            let controller = PendingBackupsController(runs: filtered, appDelegate: self)
            pendingBackupsController = controller
            controller.show()
        }
    }

    @objc private func openPendingBackupsMenu() {
        showPendingBackups(pendingRuns())
    }

    func pendingBackupsWindowClosed() {
        self.pendingBackupsController = nil
    }

    private var settingsController: SettingsController?

    @objc private func openSettingsMenu() {
        if settingsController == nil {
            settingsController = SettingsController(appDelegate: self)
        }
        settingsController?.show()
    }

    @objc private func checkForUpdatesMenu() {
        UpdateChecker.check(interactive: true)
    }

    func settingsWindowClosed() {
        self.settingsController = nil
    }

    // MARK: - Transcription (merged in — was a separate app)

    private var progressController: ProgressController?
    private var transcribeQueue: [URL] = []
    private var isTranscribing = false

    func progressWindowClosed() { progressController = nil }

    /// Queue a folder for transcription; runs serially, visible in the progress
    /// window. Called by the ingest flow after a dump verifies, and by the menu.
    func enqueueTranscription(_ folder: URL) {
        guard !transcribeQueue.contains(folder) else { return }
        transcribeQueue.append(folder)
        Log.write("queued for transcription: \(folder.path)")
        startNextTranscriptionIfIdle()
    }

    private func startNextTranscriptionIfIdle() {
        guard !isTranscribing, !transcribeQueue.isEmpty else { return }
        let folder = transcribeQueue.removeFirst()
        isTranscribing = true
        if progressController == nil { progressController = ProgressController(appDelegate: self) }
        progressController?.beginJob(folder: folder)
        let card = folder.lastPathComponent   // card-folder name == Media Log row
        Task.detached {
            let pipeline = TranscriptionPipeline()
            await pipeline.run(folderURL: folder) { [weak self] status in
                Task { @MainActor in self?.progressController?.update(line: status) }
            }
            // Mark the card's Media Log row transcribed.
            MediaLog.setTranscription(card: card, status: "Done", transcriptURL: nil,
                                      config: Config.load())
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progressController?.finishJob()
                self.isTranscribing = false
                self.startNextTranscriptionIfIdle()
            }
        }
    }

    @objc func showTranscriptionProgress() {
        if progressController == nil { progressController = ProgressController(appDelegate: self) }
        progressController?.show()
    }

    @objc func transcribeFolderMenu() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Transcribe"
        panel.message = "Select a folder of interview footage/audio to transcribe."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            enqueueTranscription(url)
            showTranscriptionProgress()
        }
    }

    func openResume(_ run: IncompleteRun) {
        let controller = SetupWindowController(resumeRun: run, appDelegate: self)
        setupControllers.append(controller)
        controller.show()
    }

    func setupWindowClosed(_ controller: SetupWindowController) {
        // The window is gone but any running transfer keeps going: the model
        // is retained by its own task and reports via the menu bar.
        setupControllers.removeAll { $0 === controller }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            // One-time self-test so we can confirm notifications work in a real
            // bundle — after the first successful launch it stays quiet.
            let key = "didRunNotificationSelfTest"
            if granted, !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                Task { @MainActor in
                    self.notify(title: "DIT Media Ingest",
                                body: "Notifications are working. You won't see this message again.")
                }
            }
        }
    }

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
