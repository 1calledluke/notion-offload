import SwiftUI
import AppKit
import ImageIO
import AVFoundation

struct BackupProgressState: Identifiable, Sendable {
    var id: String { label }
    let label: String
    var progressFraction: Double
    var speedText: String
    var currentFile: String
    var etaText: String = ""
}

/// "~45 sec", "~12 min", "~1h 05m" — nil when not enough signal yet.
func etaString(bytesDone: Int64, bytesTotal: Int64, elapsed: TimeInterval) -> String? {
    guard elapsed > 2, bytesDone > 0, bytesTotal > bytesDone else { return nil }
    let rate = Double(bytesDone) / elapsed
    guard rate > 0 else { return nil }
    let remaining = Double(bytesTotal - bytesDone) / rate
    if remaining < 60 { return "~\(Int(remaining.rounded())) sec" }
    if remaining < 3600 { return "~\(Int((remaining / 60).rounded())) min" }
    let h = Int(remaining) / 3600
    let m = (Int(remaining) % 3600) / 60
    return String(format: "~%dh %02dm", h, m)
}

struct BackupTaskResult {
    let backupDir: String
    let destFolder: URL
    let ok: Bool
    let failures: [String]
}



/// Backing state + actions for the setup window. Runs the Stage-1 ingest.
@MainActor
final class SetupModel: ObservableObject {
    let sourceURL: URL
    let jobID = UUID()   // identifies this run in the menu-bar job list
    weak var appDelegate: AppDelegate?

    @Published var projects: [String] = []
    @Published var filter: String = ""
    @Published var selectedProject: String?
    @Published var dumpLocation: String
    @Published var backup1: String
    @Published var backup2: String
    @Published var justDump: Bool

    // Run state
    @Published var isLoadingProjects = false
    @Published var isRunning = false
    @Published var progressText = ""
    @Published var progressFraction = 0.0
    @Published var speedText = ""
    @Published var etaText: String = ""
    @Published var finishedMessage: String?
    @Published var errorMessage: String?

    // Concurrency and live status state
    @Published var activeBackups: [String: BackupProgressState] = [:]
    @Published var currentCardName: String = ""
    @Published var resumeRun: IncompleteRun? = nil
    @Published var cardSummary: String = ""

    @Published var clockSuspect: Bool = false
    @Published var dateOverride: Date? = nil        // set only when the user corrects a bad clock
    @Published var suspectObservedMax: Date? = nil

    // File browser. `dumpFullCard` on (the default) copies everything and the
    // per-file selection is ignored; switch it off to hand-pick clips.
    @Published var dumpFullCard: Bool = true
    @Published var browserFiles: [URL] = []
    @Published var selectedFiles: Set<URL> = []
    @Published var isScanningCard: Bool = false

    // Browser appearance (persisted so it stays how the user likes it).
    @Published var thumbSize: Double = UserDefaults.standard.object(forKey: "browserThumbSize") as? Double ?? 100 {
        didSet { UserDefaults.standard.set(thumbSize, forKey: "browserThumbSize") }
    }
    @Published var browserListView: Bool = UserDefaults.standard.bool(forKey: "browserListView") {
        didSet { UserDefaults.standard.set(browserListView, forKey: "browserListView") }
    }

    /// What the run will actually copy: everything, or just the ticked clips.
    var effectiveSelection: Set<URL> {
        dumpFullCard ? Set(browserFiles) : selectedFiles
    }

    func toggleFile(_ url: URL) {
        if selectedFiles.contains(url) { selectedFiles.remove(url) }
        else { selectedFiles.insert(url) }
    }
    func selectAllFiles() { selectedFiles = Set(browserFiles) }
    func selectNoFiles() { selectedFiles = [] }

    /// Loads the browser's file list. Everything starts ticked, so switching
    /// "Dump full card" off leaves the same set selected until you change it.
    func loadFileBrowser() {
        let source = sourceURL
        isScanningCard = true
        Task.detached {
            let files = Engine.primaryMediaFiles(in: source)
            await MainActor.run {
                self.browserFiles = files
                self.selectedFiles = Set(files)
                self.isScanningCard = false
            }
        }
    }

    private var config: Config
    private var rawProjects: [Project] = []

    init(sourceURL: URL, appDelegate: AppDelegate?) {
        self.sourceURL = sourceURL
        self.appDelegate = appDelegate
        self.resumeRun = nil
        let cfg = Config.load()
        self.config = cfg
        self.dumpLocation = cfg.dumpLocation
        self.backup1 = cfg.backupLocation1
        self.backup2 = cfg.backupLocation2
        self.justDump = cfg.justDump

        refreshProjects()
        loadCardPreview()
        loadFileBrowser()
    }

    init(resumeRun: IncompleteRun, appDelegate: AppDelegate?) {
        self.sourceURL = resumeRun.ssdCardFolder
        self.appDelegate = appDelegate
        self.resumeRun = resumeRun
        let cfg = Config.load()
        self.config = cfg
        self.dumpLocation = cfg.dumpLocation
        self.backup1 = cfg.backupLocation1
        self.backup2 = cfg.backupLocation2
        self.justDump = cfg.justDump
    }

    /// Re-query Notion for the current project list. Safe to call any time,
    /// e.g. after creating a new project in Notion.
    func refreshProjects() {
        let cfg = self.config
        isLoadingProjects = true
        Task.detached { [cfg] in
            let rawList = Notion.listProjects(token: cfg.notionToken,
                                              databaseID: cfg.notionProjectsDB)
            let names = rawList.map { $0.name }
            await MainActor.run {
                let previouslySelected = self.selectedProject
                self.rawProjects = rawList
                self.projects = names
                // Keep the selection if it still exists.
                if let sel = previouslySelected, !names.contains(sel) {
                    self.selectedProject = nil
                }
                self.isLoadingProjects = false
            }
        }
    }

    var selectedProjectID: String {
        guard let name = selectedProject else { return "" }
        return rawProjects.last(where: { $0.name == name })?.id ?? ""
    }

    var selectedClientName: String {
        guard let name = selectedProject else { return "" }
        return rawProjects.last(where: { $0.name == name })?.clientName ?? ""
    }

    var selectedJobCode: String {
        guard let name = selectedProject else { return "" }
        return rawProjects.last(where: { $0.name == name })?.jobCode ?? ""
    }

    var filteredProjects: [String] {
        guard !filter.isEmpty else { return projects }
        return projects.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    func browse(_ binding: ReferenceWritableKeyPath<SetupModel, String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: self[keyPath: binding].isEmpty
                                 ? "/Volumes" : self[keyPath: binding])
        if panel.runModal() == .OK, let url = panel.url {
            self[keyPath: binding] = url.path
        }
    }

    func canGo() -> Bool {
        goBlockReason == nil
    }

    /// Why "Go" is disabled, or nil if it's ready. Backups are optional: a run
    /// needs only a project and a dump location. Whatever backup fields are
    /// filled in get used (zero, one, or two).
    var goBlockReason: String? {
        if selectedProject == nil { return "Pick a project from the list." }
        if dumpLocation.isEmpty { return "Choose a dump location." }
        return nil
    }

    /// Stage 1: dump + verify + manifest + eject + notify.
    /// Stage 2: backups + verification + backed-up manifests + notifications + Notion comments.
    func go() {
        guard let project = selectedProject else { return }

        // Persist choices for next time.
        config.dumpLocation = dumpLocation
        config.backupLocation1 = backup1
        config.backupLocation2 = backup2
        config.justDump = justDump
        config.save()

        isRunning = true
        errorMessage = nil
        speedText = ""
        activeBackups = [:]
        currentCardName = ""
        let clientName = selectedClientName
        let jobCode = selectedJobCode
        let source = sourceURL
        let dump = dumpLocation
        let b1 = backup1
        let b2 = backup2
        let projectID = selectedProjectID
        let token = config.notionToken

        let fullCard = dumpFullCard
        let chosen = selectedFiles
        let overrideDate = dateOverride

        Task.detached {
            var byType = Engine.filesByType(in: source)
            if !fullCard {
                // Ride-alongs (proxies, XML sidecars) follow their chosen clips.
                byType = Engine.filterSelection(byType, chosen: chosen)
            }
            if byType.isEmpty {
                await MainActor.run {
                    self.errorMessage = fullCard
                        ? "No media files found on the card."
                        : "No files selected — tick some clips or turn on “Dump full card”."
                    self.appDelegate?.clearJob(self.jobID)
                    self.isRunning = false
                    self.etaText = ""
                }
                return
            }

            var camera = Engine.detectDevice(in: source)
            if camera == nil {
                camera = await self.askCamera()
            }
            let cam = camera ?? "Unknown Camera"

            let dateStr = Self.dumpDateString()
            let yymm = String(dateStr.prefix(5))                     // "26.07"
            let projectFolderName = jobCode.isEmpty
                ? "\(yymm)_\(project)"
                : "\(yymm)_\(project)_\(jobCode)"

            let dumpRoot = URL(fileURLWithPath: dump)
            let projectRoot: URL
            if !clientName.isEmpty {
                projectRoot = dumpRoot.appendingPathComponent(clientName).appendingPathComponent(projectFolderName)
            } else {
                projectRoot = dumpRoot.appendingPathComponent(projectFolderName)  // fallback: no client folder
            }

            var doneNames: [String] = []
            var cardFolders: [(url: URL, cardName: String, relativePath: String, totalBytes: Int64)] = []

            for (mediaType, files) in byType.sorted(by: { $0.key < $1.key }) {
                await MainActor.run {
                    self.etaText = ""
                }
                let typeDir = projectRoot.appendingPathComponent(mediaType.capitalized)
                try? FileManager.default.createDirectory(at: typeDir,
                                                         withIntermediateDirectories: true)
                let cardName = Engine.nextCardFolderName(in: typeDir, camera: cam, date: dateStr)
                let cardFolder = typeDir.appendingPathComponent(cardName)

                // Safety: abort if destination already exists and is non-empty
                if FileManager.default.fileExists(atPath: cardFolder.path) {
                    let contents = (try? FileManager.default.contentsOfDirectory(atPath: cardFolder.path)) ?? []
                    if !contents.isEmpty {
                        Log.write("pre-flight ABORT: destination already exists -> \(cardFolder.path) (\(contents.count) items)")
                        await MainActor.run {
                            self.errorMessage = "⚠️ Destination already exists and is not empty:\n\(cardFolder.path)\n\nAborting to protect existing data. Move or rename that folder before retrying."
                            self.appDelegate?.clearJob(self.jobID)
                            self.isRunning = false
                            self.etaText = ""
                        }
                        return
                    }
                }

                // Log dump started
                Log.write("dump started -> card: \(cardName), dest: \(cardFolder.path), files: \(files.count)")

                let capDates = Engine.readCaptureDates(for: files)
                let startTime = Date()
                let result = Engine.copyAndVerify(source: source, files: files,
                                                  destFolder: cardFolder,
                                                  captureDates: capDates,
                                                  dateOverride: overrideDate) { i, total, name, bytesCopied, grandTotal in
                    let elapsed = Date().timeIntervalSince(startTime)
                    let mbps = elapsed > 0.1 ? Double(bytesCopied) / 1_000_000.0 / elapsed : 0.0
                    let speedStr = String(format: "%.1f MB/s", mbps)
                    let speedVal = Int(mbps.rounded())
                    let fraction = grandTotal > 0 ? Double(bytesCopied) / Double(grandTotal)
                                                  : Double(i) / Double(max(total, 1))
                    let etaTextVal = etaString(bytesDone: bytesCopied, bytesTotal: grandTotal, elapsed: elapsed) ?? ""

                    Task { @MainActor in
                        self.progressFraction = fraction
                        self.progressText = "\(cardName): \(i)/\(total) — \(name)"
                        self.speedText = fraction >= 1.0 ? "verifying…" : speedStr
                        self.etaText = etaTextVal
                        
                        let jobText: String
                        if !etaTextVal.isEmpty {
                            jobText = "Dumping \(cardName) — \(i)/\(total) (\(speedVal) MB/s, \(etaTextVal) left)"
                        } else {
                            jobText = "Dumping \(cardName) — \(i)/\(total) (\(speedVal) MB/s)"
                        }
                        
                        self.appDelegate?.updateJob(self.jobID,
                            text: jobText,
                            short: "⇩\(Int(fraction * 100))%")
                    }
                }

                if !result.ok {
                    Log.write("dump FAILED -> \(cardName), failures: \(result.failures.count)")
                    await MainActor.run {
                        self.errorMessage = "\(cardName): \(result.failures.count) file(s) failed to copy or verify. " +
                            "If this happened instantly, the card may have disconnected — reseat it and try again. " +
                            "Nothing was finalized."
                        self.appDelegate?.clearJob(self.jobID)
                        self.isRunning = false
                        self.etaText = ""
                    }
                    return
                }

                Log.write("dump verified -> \(cardName), files: \(result.fileCount), bytes: \(result.totalBytes)")

                let relPath = clientName.isEmpty
                    ? "\(projectFolderName)/\(mediaType.capitalized)/\(cardName)"
                    : "\(clientName)/\(projectFolderName)/\(mediaType.capitalized)/\(cardName)"
                let expectedBackupFolders = [b1, b2].filter { !$0.isEmpty }.map { dir -> URL in
                    URL(fileURLWithPath: dir).appendingPathComponent(relPath)
                }
                let dumpedManifestURL = Engine.writeDumpedManifest(in: cardFolder,
                                           mediaFileCount: result.fileCount,
                                           totalBytes: result.totalBytes,
                                           backupFolders: expectedBackupFolders)
                Log.write("dumped manifest written -> \(dumpedManifestURL.path)")
                // Record the backup plan NOW so a crash before backups begin
                // still leaves the resume detector something to find.
                for dir in [b1, b2] where !dir.isEmpty {
                    Log.write("backup planned -> \(dir) [src: \(cardFolder.path)]")
                }
                Engine.stampBrawIcons(in: cardFolder)
                doneNames.append(cardName)

                cardFolders.append((url: cardFolder, cardName: cardName, relativePath: relPath, totalBytes: result.totalBytes))
            }

            // Eject the card.
            Self.eject(source)
            Log.write("card ejected -> \(source.path)")

            // Mixed-media cards produce one card folder per type with the SAME
            // name — dedupe and note the types instead of repeating the name.
            var seenNames = Set<String>()
            let uniqueNames = doneNames.filter { seenNames.insert($0).inserted }
            let typeSuffix = byType.count > 1
                ? " (" + byType.keys.sorted().map { $0.capitalized }.joined(separator: " + ") + ")"
                : ""
            let names = uniqueNames.joined(separator: ", ") + typeSuffix
            await MainActor.run {
                self.appDelegate?.notify(title: "DIT Media Ingest",
                                         body: "\(names) dumped to SSD.")
            }

            // Stage 2: Backups
            let backupDirs = [b1, b2].filter { !$0.isEmpty }
            // Reserve every folder we're about to back up so the Pending panel
            // won't offer a "Retry" for a card whose initial backup is running.
            let reservedDests = cardFolders.map { $0.url.path }
            if !backupDirs.isEmpty {
                await MainActor.run { for d in reservedDests { self.appDelegate?.beginBackup(d) } }
            }
            defer { Task { @MainActor in for d in reservedDests { self.appDelegate?.endBackup(d) } } }

            for folderInfo in cardFolders {
                let ssdFolder = folderInfo.url
                let relPath = folderInfo.relativePath
                let totalBytes = folderInfo.totalBytes
                let cardName = folderInfo.cardName

                await MainActor.run {
                    self.currentCardName = cardName
                    self.activeBackups = [:]
                }

                var backupLocationsSucceeded: [URL] = []
                var failedBackupDirs: [String] = []
                var backupFailureDetails: [String] = []
                var backupAttempted = false

                if !backupDirs.isEmpty {
                    backupAttempted = true
                    let results = await self.runBackups(ssdFolder: ssdFolder, cardName: cardName,
                                                        backupDirs: backupDirs, relPath: relPath)
                    for res in results {
                        if res.ok {
                            backupLocationsSucceeded.append(res.destFolder)
                        } else {
                            failedBackupDirs.append(res.backupDir)
                            backupFailureDetails.append(contentsOf: res.failures)
                        }
                    }
                }

                // If any backup failed, surface the reason and open the
                // Pending Backups panel so retry is one click away.
                if !failedBackupDirs.isEmpty {
                    let failedNames = failedBackupDirs.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
                    let firstReason = backupFailureDetails.first ?? "unknown"
                    let failCount = backupFailureDetails.count
                    Log.flush()
                    await MainActor.run {
                        self.errorMessage = "Backup to \(failedNames) failed for \(cardName) " +
                            "(\(failCount) file(s)). First failure: \(firstReason)\n" +
                            "The SSD copy is safe — retry from the Pending Backups panel."
                        self.appDelegate?.clearJob(self.jobID)
                        self.isRunning = false
                        self.etaText = ""
                        let runs = ResumeDetector.findIncompleteRuns(logPath: Log.logFileURL)
                        if !runs.isEmpty { self.appDelegate?.showPendingBackups(runs) }
                    }
                    return
                }

                // If ALL configured backups for that card verified:
                // write one BU manifest next to each backup card folder (NOT to the SSD).
                if backupAttempted {
                    for destFolder in backupLocationsSucceeded {
                        let backupManifest = Engine.writeBackedUpManifest(
                            in: destFolder, dumpFolder: ssdFolder,
                            allBackupFolders: backupLocationsSucceeded, totalBytes: totalBytes)
                        Log.write("BU manifest written -> \(backupManifest.path)")
                        Engine.stampBrawIcons(in: destFolder)
                    }

                    // Fire the 2nd notification.
                    await MainActor.run {
                        self.appDelegate?.notify(title: "DIT Media Ingest",
                                                 body: "\(cardName) backed up to all locations.")
                        Log.write("2nd notification fired -> \(cardName) backed up to all locations")
                    }

                    // Per-folder completion marker for the resume detector
                    // (dest-based: mixed cards share a card name across types).
                    Log.write("backup complete -> dest: \(ssdFolder.path)")
                }

                // Notion comment
                if !projectID.isEmpty {
                    let commentText: String
                    if backupAttempted {
                        commentText = "\(cardName) dumped and backed up. Files stored at \(ssdFolder.path)/"
                    } else {
                        commentText = "\(cardName) dumped. Files stored at \(ssdFolder.path)/"
                    }

                    Log.write("Posting Notion comment for \(cardName)...")
                    let commentSuccess = Notion.postComment(token: token, pageID: projectID, text: commentText)
                    if commentSuccess {
                        Log.write("Successfully posted Notion comment for \(cardName).")
                    } else {
                        Log.write("Failed to post Notion comment for \(cardName).")
                    }
                }
            }

            Log.write("run complete")

            await MainActor.run {
                if backupDirs.isEmpty {
                    self.finishedMessage = "\(names) dumped and verified to SSD."
                } else {
                    self.finishedMessage = "\(names) dumped and backed up to \(backupDirs.count) location(s)."
                }
                self.appDelegate?.clearJob(self.jobID)
                self.isRunning = false
                self.etaText = ""
            }
        }
    }

    func resumeBackup() {
        guard let run = resumeRun else { return }
        let destKey = run.ssdCardFolder.path
        // Refuse a second concurrent backup of the same folder (impatient
        // re-clicks would otherwise race writers on the destination drive).
        if appDelegate?.isBackupActive(destKey) == true {
            errorMessage = "This folder is already backing up — watch the menu bar for progress."
            return
        }
        appDelegate?.beginBackup(destKey)
        isRunning = true
        errorMessage = nil
        activeBackups = [:]
        currentCardName = run.cardName
        let ssdFolder = run.ssdCardFolder
        let cardName = run.cardName
        let unverifiedDirs = run.backupDirs.filter { !run.verifiedDirs.contains($0) }
        let allBackupDirs = run.backupDirs
        let dumpRootPath = config.dumpLocation

        Task.detached {
            defer { Task { @MainActor in self.appDelegate?.endBackup(destKey) } }
            Log.write("resume backup started -> \(cardName)")

            // Determine totalBytes from the SSD folder for manifest + menu bar
            let totalBytes = Engine.mediaFiles(in: ssdFolder)
                .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }

            // Strip the configured dump root to get the path relative to the backup
            // volume root, comparing whole path components so /Volumes/SSD can't
            // falsely prefix-match /Volumes/SSD_Storage.
            let rootComps = URL(fileURLWithPath: dumpRootPath).standardizedFileURL.pathComponents
            let ssdComps = ssdFolder.standardizedFileURL.pathComponents
            guard !dumpRootPath.isEmpty,
                  ssdComps.count > rootComps.count,
                  Array(ssdComps.prefix(rootComps.count)) == rootComps else {
                Log.write("resume ABORT: dump location \(dumpRootPath) is not a parent of \(ssdFolder.path)")
                await MainActor.run {
                    self.errorMessage = "Can't work out the folder structure to resume (has the dump location changed?). The SSD copy is safe at:\n\(ssdFolder.path)\n\nPlease copy it to your backup drives manually."
                    self.appDelegate?.clearJob(self.jobID)
                    self.isRunning = false
                }
                return
            }
            let relPath = ssdComps.dropFirst(rootComps.count).joined(separator: "/")

            var backupLocationsSucceeded: [URL] = []
            var failedDirs: [String] = []

            let results = await self.runBackups(ssdFolder: ssdFolder, cardName: cardName,
                                                backupDirs: unverifiedDirs, relPath: relPath)

            for res in results {
                if res.ok { backupLocationsSucceeded.append(res.destFolder) }
                else { failedDirs.append(res.backupDir) }
            }

            if !failedDirs.isEmpty {
                let names = failedDirs.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
                let firstReason = results.first(where: { !$0.ok })?.failures.first ?? "unknown"
                Log.flush()
                await MainActor.run {
                    self.errorMessage = "Backup to \(names) failed. First failure: \(firstReason)\n" +
                        "SSD copy is safe — retry from the Pending Backups panel."
                    self.appDelegate?.clearJob(self.jobID)
                    self.isRunning = false
                    let runs = ResumeDetector.findIncompleteRuns(logPath: Log.logFileURL)
                    if !runs.isEmpty { self.appDelegate?.showPendingBackups(runs) }
                }
                return
            }

            // All succeeded — write BU manifests for EVERY backup location,
            // including ones that verified before the crash (they never got
            // their manifest: the original run crashed before writing it).
            var allDestFolders: [URL] = []
            for dir in allBackupDirs {
                let dest = URL(fileURLWithPath: dir).appendingPathComponent(relPath)
                if FileManager.default.fileExists(atPath: dest.path) {
                    allDestFolders.append(dest)
                }
            }
            for dest in allDestFolders {
                let m = Engine.writeBackedUpManifest(in: dest, dumpFolder: ssdFolder,
                                                      allBackupFolders: allDestFolders,
                                                      totalBytes: totalBytes)
                Log.write("BU manifest written -> \(m.path)")
                Engine.stampBrawIcons(in: dest)
            }

            await MainActor.run {
                self.appDelegate?.notify(title: "DIT Media Ingest", body: "\(cardName) backup complete.")
            }
            // NOTE: deliberately no "run complete" here — that marker completes
            // ALL cards in the detector, which would mask OTHER cards whose
            // backups are still unfinished. The per-folder marker is enough.
            Log.write("backup complete -> dest: \(ssdFolder.path)")

            await MainActor.run {
                self.finishedMessage = "\(cardName) backed up successfully."
                self.appDelegate?.clearJob(self.jobID)
                self.isRunning = false
            }
        }
    }

    /// Backs up `ssdFolder` to each backup dir SEQUENTIALLY, one physical drive
    /// at a time, each guarded by the global per-drive lock so a concurrently
    /// dumping card can't collide on a shared drive. Runs off the main actor;
    /// hops to MainActor only for UI. Returns per-dir results.
    nonisolated func runBackups(ssdFolder: URL, cardName: String,
                                backupDirs: [String], relPath: String) async -> [BackupTaskResult] {
        var results: [BackupTaskResult] = []
        for backupDir in backupDirs {
            let backupURL = URL(fileURLWithPath: backupDir)
            let destFolder = backupURL.appendingPathComponent(relPath)
            let volumeName = (try? backupURL.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
            let label = volumeName ?? (backupURL.lastPathComponent.isEmpty ? "Backup" : backupURL.lastPathComponent)
            let volume = BackupCoordinator.volumeRoot(of: destFolder.path)

            // Wait our turn on this drive, then show a "queued→starting" row.
            await MainActor.run {
                self.activeBackups[backupDir] = BackupProgressState(
                    label: label, progressFraction: 0, speedText: "waiting for drive…",
                    currentFile: "", etaText: "")
            }
            await BackupCoordinator.shared.acquire(volume: volume)
            Log.write("backup started -> \(backupDir) [src: \(ssdFolder.path)]")

            let startTime = Date()
            let result = Engine.backUpAndVerify(ssdCardFolder: ssdFolder, to: destFolder) { i, total, name, bytesCopied, grandTotal in
                let elapsed = Date().timeIntervalSince(startTime)
                let mbps = elapsed > 0.1 ? Double(bytesCopied) / 1_000_000.0 / elapsed : 0.0
                let speedStr = String(format: "%.1f MB/s", mbps)
                let fraction = grandTotal > 0 ? Double(bytesCopied) / Double(grandTotal)
                                              : Double(i) / Double(max(total, 1))
                let etaTextVal = etaString(bytesDone: bytesCopied, bytesTotal: grandTotal, elapsed: elapsed) ?? ""
                Task { @MainActor in
                    self.activeBackups[backupDir] = BackupProgressState(
                        label: label, progressFraction: fraction,
                        speedText: fraction >= 1.0 ? "verifying…" : speedStr,
                        currentFile: name, etaText: etaTextVal)
                    self.refreshBackupStatus(cardName: cardName)
                }
            }
            await BackupCoordinator.shared.release(volume: volume)

            Log.write(result.ok
                ? "backup verified -> \(backupDir) [src: \(ssdFolder.path)]"
                : "backup FAILED -> \(backupDir) [src: \(ssdFolder.path)]")
            let finalOK = result.ok
            await MainActor.run {
                self.activeBackups[backupDir]?.progressFraction = 1.0
                self.activeBackups[backupDir]?.speedText = finalOK ? "Done ✓" : "Failed"
                self.activeBackups[backupDir]?.currentFile = ""
                self.activeBackups[backupDir]?.etaText = ""
                self.refreshBackupStatus(cardName: cardName)
            }
            results.append(BackupTaskResult(backupDir: backupDir, destFolder: destFolder,
                                            ok: result.ok, failures: result.failures))
        }
        return results
    }

    /// Recomputes the overall bar + menu-bar text from all active backup rows.
    @MainActor private func refreshBackupStatus(cardName: String) {
        let fractions = self.activeBackups.values.map { $0.progressFraction }
        if !fractions.isEmpty {
            self.progressFraction = fractions.reduce(0.0, +) / Double(fractions.count)
        }
        let avgPercent = Int((self.progressFraction * 100).rounded())
        let statuses = self.activeBackups.values
            .sorted(by: { $0.label < $1.label })
            .map { backup -> String in
                let percent = Int((backup.progressFraction * 100).rounded())
                let hasEta = !backup.etaText.isEmpty && backup.speedText != "verifying…"
                    && backup.speedText != "Done ✓" && backup.speedText != "Failed"
                return hasEta ? "\(backup.label) \(percent)% (\(backup.etaText))"
                              : "\(backup.label) \(percent)%"
            }
            .joined(separator: ", ")
        self.appDelegate?.updateJob(self.jobID,
            text: "Backing up \(cardName) — \(statuses)", short: "⇪\(avgPercent)%")
    }

    private func askCamera() async -> String? {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "What camera was this shot on?"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                let v = field.stringValue.trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            return nil
        }
    }

    /// Recomputes the summary line a beat after the user stops ticking clips, so
    /// rapid clicking doesn't kick off a scan per click.
    private var previewRefreshTask: Task<Void, Never>?
    func scheduleSelectivePreviewRefresh() {
        previewRefreshTask?.cancel()
        previewRefreshTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            let selection = await MainActor.run { self.effectiveSelection }
            await self.loadCardPreview(restrictTo: selection)
        }
    }

    /// Builds the "12 videos, 2 stills • 290GB • Jun 4 – Jun 30" summary.
    /// `restrictTo` scopes it to the ticked clips; nil means the whole card.
    /// Thumbnails are NOT produced here — the file browser renders those lazily.
    func loadCardPreview(restrictTo: Set<URL>? = nil) {
        let source = self.sourceURL
        Task.detached {
            var byType = Engine.filesByType(in: source)
            if let allowed = restrictTo {
                byType = Engine.filterSelection(byType, chosen: allowed)
            }
            
            // Count per type + total bytes
            var typeCounts: [String] = []
            var allMediaFiles: [URL] = []
            
            // Exclude proxy copies from the count/strip — they'd double-count
            // their originals (they're still used for BRAW thumb generation).
            let videos = (byType["video"] ?? []).filter {
                $0.pathExtension.lowercased() != "xml" && !$0.path.lowercased().contains("/proxy/")
            }
            let stills = (byType["stills"] ?? []).filter { $0.pathExtension.lowercased() != "xml" }
            let audios = (byType["audio"] ?? []).filter { $0.pathExtension.lowercased() != "xml" }
            
            if !videos.isEmpty {
                typeCounts.append("\(videos.count) video\(videos.count == 1 ? "" : "s")")
                allMediaFiles.append(contentsOf: videos)
            }
            if !stills.isEmpty {
                typeCounts.append("\(stills.count) still\(stills.count == 1 ? "" : "s")")
                allMediaFiles.append(contentsOf: stills)
            }
            if !audios.isEmpty {
                typeCounts.append("\(audios.count) audio")
                allMediaFiles.append(contentsOf: audios)
            }
            
            let countsStr = typeCounts.joined(separator: ", ")
            
            var totalBytes: Int64 = 0
            for file in allMediaFiles {
                if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    totalBytes += Int64(size)
                }
            }
            let sizeStr = Engine.humanSize(totalBytes)
            
            // Capture-date or modification-date range
            let caps = Engine.readCaptureDates(for: allMediaFiles)
            var dates: [Date] = []
            for file in allMediaFiles {
                if let emb = caps[file.path] {
                    if Engine.isPlausibleDate(emb) {
                        dates.append(emb)
                    }
                } else if let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    dates.append(date)
                }
            }

            let maxD = caps.values.max()
            let clkSuspect = maxD.map { !Engine.isPlausibleDate($0) } ?? false
            let clkBestGuess = Date()
            
            var dateStr = ""
            if !dates.isEmpty {
                if let minDate = dates.min(), let maxDate = dates.max() {
                    let calendar = Calendar.current
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    
                    if calendar.isDate(minDate, inSameDayAs: maxDate) {
                        formatter.dateFormat = "MMM d"
                        dateStr = formatter.string(from: minDate)
                    } else {
                        let minMonth = calendar.component(.month, from: minDate)
                        let maxMonth = calendar.component(.month, from: maxDate)
                        let minYear = calendar.component(.year, from: minDate)
                        let maxYear = calendar.component(.year, from: maxDate)
                        
                        if minYear == maxYear {
                            if minMonth == maxMonth {
                                formatter.dateFormat = "MMM d"
                                let start = formatter.string(from: minDate)
                                formatter.dateFormat = "d"
                                let end = formatter.string(from: maxDate)
                                dateStr = "\(start)–\(end)"
                            } else {
                                formatter.dateFormat = "MMM d"
                                let start = formatter.string(from: minDate)
                                let end = formatter.string(from: maxDate)
                                dateStr = "\(start) – \(end)"
                            }
                        } else {
                            formatter.dateFormat = "MMM d, yyyy"
                            let start = formatter.string(from: minDate)
                            let end = formatter.string(from: maxDate)
                            dateStr = "\(start) – \(end)"
                        }
                    }
                }
            }
            
            var summaryParts: [String] = []
            if !countsStr.isEmpty {
                summaryParts.append(countsStr)
            }
            if !sizeStr.isEmpty {
                summaryParts.append(sizeStr.uppercased())
            }
            if !dateStr.isEmpty {
                summaryParts.append(dateStr)
            }
            let summaryText = summaryParts.joined(separator: " • ")

            await MainActor.run {
                self.cardSummary = summaryText
                self.clockSuspect = clkSuspect
                self.suspectObservedMax = maxD
                if clkSuspect && self.dateOverride == nil { self.dateOverride = clkBestGuess }
            }
        }
    }

    nonisolated private static func dumpDateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yy.MM.dd"
        return f.string(from: Date())
    }

    nonisolated private static func eject(_ url: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["eject", url.path]
        try? proc.run()
        proc.waitUntilExit()
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var onClose: () -> Void

    private var formattedSuspectObservedMax: String {
        guard let maxD = model.suspectObservedMax else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: maxD)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            VStack(spacing: 0) {
                if let done = model.finishedMessage {
                    resultView(done, success: true)
                } else if model.isRunning {
                    runningView
                } else if model.resumeRun != nil {
                    resumeReadyView
                } else {
                    formView
                }
            }
            .padding(16)
            .frame(maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: model.isRunning)
            .animation(.easeInOut(duration: 0.2), value: model.finishedMessage != nil)
        }
        .frame(minWidth: 540, idealWidth: 680, maxWidth: .infinity,
               minHeight: 600, idealHeight: 860, maxHeight: .infinity)
    }

    private var resumeReadyView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            
            VStack(spacing: 4) {
                Text("Resume Backup")
                    .font(.title3)
                    .bold()
                if let run = model.resumeRun {
                    Text(run.displayName)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("The SSD copy is verified and safe.")
                    .font(.body)
                    .bold()
                
                Text("Backup will resume to:")
                    .font(.body)
                    .foregroundStyle(.secondary)
                
                if let run = model.resumeRun {
                    let unverified = run.backupDirs.filter { !run.verifiedDirs.contains($0) }
                    ForEach(unverified, id: \.self) { dir in
                        HStack(alignment: .top, spacing: 4) {
                            Text("•")
                            Text(URL(fileURLWithPath: dir).lastPathComponent)
                        }
                        .font(.body)
                    }
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Spacer()
            
            // Bottom Bar
            VStack(spacing: 12) {
                Divider()
                
                HStack {
                    if let err = model.errorMessage {
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    
                    Spacer()
                    
                    Button("Cancel", action: onClose)
                        .buttonStyle(.plain)
                    
                    Button("Resume Backup ▶") {
                        model.resumeBackup()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var headerView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "externaldrive.fill.badge.plus")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("DIT Media Ingest")
                        .font(.title3)
                        .bold()
                    Text("Ingest media from card to project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Text(model.sourceURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                    )
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            
            Divider()
        }
    }

    /// The card's files as a thumbnail grid. Cells render lazily — only what you
    /// scroll to gets decoded — so a 200-clip BRAW card opens instantly.
    private var fileBrowserSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("CARD")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if !model.cardSummary.isEmpty {
                    Text(model.cardSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !model.dumpFullCard && !model.browserFiles.isEmpty {
                    Text("\(model.selectedFiles.count) of \(model.browserFiles.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("All") { model.selectAllFiles(); model.scheduleSelectivePreviewRefresh() }
                        .buttonStyle(.link)
                        .font(.caption)
                    Button("None") { model.selectNoFiles(); model.scheduleSelectivePreviewRefresh() }
                        .buttonStyle(.link)
                        .font(.caption)
                    Divider().frame(height: 14)
                }

                // Thumbnail size (grid only), then grid/list toggle.
                if !model.browserListView {
                    Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $model.thumbSize, in: 70...220)
                        .frame(width: 90)
                        .controlSize(.mini)
                        .help("Thumbnail size")
                }
                Picker("", selection: $model.browserListView) {
                    Image(systemName: "square.grid.2x2").tag(false)
                    Image(systemName: "list.bullet").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 76)
                .labelsHidden()
            }

            if model.isScanningCard {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading card…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if model.browserFiles.isEmpty {
                Text("No media files found on this card.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    if model.browserListView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.browserFiles, id: \.self) { url in
                                FileRow(url: url, source: model.sourceURL,
                                        isSelected: model.dumpFullCard || model.selectedFiles.contains(url),
                                        isPickable: !model.dumpFullCard,
                                        onTap: { model.toggleFile(url); model.scheduleSelectivePreviewRefresh() })
                            }
                        }
                        .padding(6)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: model.thumbSize + 12), spacing: 10)],
                                  spacing: 10) {
                            ForEach(model.browserFiles, id: \.self) { url in
                                FileCell(
                                    url: url,
                                    source: model.sourceURL,
                                    size: model.thumbSize,
                                    isSelected: model.dumpFullCard || model.selectedFiles.contains(url),
                                    // In full-card mode the ticks are informational only.
                                    isPickable: !model.dumpFullCard,
                                    onTap: {
                                        model.toggleFile(url)
                                        model.scheduleSelectivePreviewRefresh()
                                    }
                                )
                            }
                        }
                        .padding(8)
                    }
                }
                .frame(minHeight: 200, maxHeight: .infinity)
                .background(.background)
                .border(.separator)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 16) {
            fileBrowserSection

            // Section: Project
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    Text("PROJECT")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    if model.isLoadingProjects {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    
                    Spacer()
                    
                    Button {
                        model.refreshProjects()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh from Notion")
                    .disabled(model.isLoadingProjects)
                }
                
                TextField("Filter projects…", text: $model.filter)
                    .textFieldStyle(.roundedBorder)
                
                List(model.filteredProjects, id: \.self, selection: $model.selectedProject) { name in
                    Text(name)
                }
                .listStyle(.inset)
                .frame(height: 120)
                .border(.separator)
            }
            
            // Section: Destinations
            VStack(alignment: .leading, spacing: 8) {
                Text("DESTINATIONS")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                
                VStack(spacing: 6) {
                    folderRow(
                        Text("Dump location ") + Text("*").foregroundColor(.red),
                        text: $model.dumpLocation,
                        key: \.dumpLocation
                    )
                    folderRow(
                        Text("Backup 1 (optional)"),
                        text: $model.backup1,
                        key: \.backup1
                    )
                    folderRow(
                        Text("Backup 2 (optional)"),
                        text: $model.backup2,
                        key: \.backup2
                    )
                }
            }

            Toggle("Dump full card", isOn: $model.dumpFullCard)
                .font(.callout)
                .onChange(of: model.dumpFullCard) { _, _ in
                    model.scheduleSelectivePreviewRefresh()
                }

            if model.clockSuspect {
                HStack(alignment: .center, spacing: 6) {
                    Text("⚠️ This card's clock looks wrong — it reads ") +
                    Text(formattedSuspectObservedMax).bold() +
                    Text(", which isn't a real shoot date. Files will be dated: ")
                    
                    DatePicker("", selection: Binding(
                        get: { model.dateOverride ?? Date() },
                        set: { model.dateOverride = $0 }),
                        displayedComponents: .date)
                    .labelsHidden()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            
            // Bottom Bar
            VStack(spacing: 12) {
                Divider()
                
                HStack {
                    if let err = model.errorMessage {
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    } else if let reason = model.goBlockReason {
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    
                    Spacer()
                    
                    Button("Cancel", action: onClose)
                        .buttonStyle(.plain)
                    
                    Button("Begin Ingest") {
                        model.go()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canGo())
                }
            }
        }
    }

    private var parsedProgress: (cardName: String, filesInfo: String, currentFile: String) {
        let text = model.progressText
        guard let colonRange = text.range(of: ": ") else {
            return (text, "", "")
        }
        let card = String(text[..<colonRange.lowerBound])
        let remaining = text[colonRange.upperBound...]
        
        if let dashRange = remaining.range(of: " — ") {
            let countPart = String(remaining[..<dashRange.lowerBound])
            let filePart = String(remaining[dashRange.upperBound...])
            let info = countPart.replacingOccurrences(of: "/", with: " of ") + " files"
            return (card, info, filePart)
        } else {
            let info = remaining.replacingOccurrences(of: "/", with: " of ") + " files"
            return (card, info, "")
        }
    }

    private var runningView: some View {
        VStack(spacing: 0) {
            if model.activeBackups.isEmpty {
                dumpPhaseView
            } else {
                backupPhaseView
            }
        }
    }

    private var dumpPhaseView: some View {
        let parsed = parsedProgress
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Dumping to SSD")
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(parsed.cardName)
                    .font(.body)
                    .bold()
                if !parsed.filesInfo.isEmpty {
                    Text(parsed.filesInfo)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            
            HStack(spacing: 12) {
                ProgressView(value: model.progressFraction)
                
                Text("\(Int((model.progressFraction * 100).rounded()))%")
                    .font(.body)
                    .monospacedDigit()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                if !model.speedText.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(model.speedText)
                            .font(.title3)
                            .bold()
                            .monospacedDigit()
                        
                        if !model.etaText.isEmpty && model.speedText != "verifying…" {
                            Text("·")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text("\(model.etaText) left")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                if !parsed.currentFile.isEmpty {
                    Text(parsed.currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
        }
    }

    private var backupPhaseView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Backing up")
                    .font(.headline)
            }
            
            Text(model.currentCardName)
                .font(.body)
                .bold()
            
            VStack(spacing: 12) {
                ForEach(model.activeBackups.values.sorted(by: { $0.label < $1.label })) { backup in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "externaldrive.fill")
                                .foregroundStyle(.secondary)
                            Text(backup.label)
                                .bold()
                            Spacer()
                            if !backup.speedText.isEmpty {
                                Text(backup.speedText)
                                    .bold()
                                    .monospacedDigit()
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(Int((backup.progressFraction * 100).rounded()))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                
                                let hasEta = !backup.etaText.isEmpty && backup.speedText != "verifying…" && backup.speedText != "Done ✓" && backup.speedText != "Failed"
                                if hasEta {
                                    Text("·")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(backup.etaText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                        
                        ProgressView(value: backup.progressFraction)
                            .controlSize(.small)
                    }
                }
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                ProgressView(value: model.progressFraction)
                    .controlSize(.large)
                
                Text("\(Int((model.progressFraction * 100).rounded()))% overall")
                    .font(.body)
                    .monospacedDigit()
            }
        }
    }

    private func resultView(_ message: String, success: Bool) -> some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(success ? .green : .red)
            
            Text(message)
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            
            Spacer()
            
            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func folderRow(_ label: Text, text: Binding<String>,
                           key: ReferenceWritableKeyPath<SetupModel, String>) -> some View {
        HStack(alignment: .center) {
            label
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
            
            Button("Browse…") {
                model.browse(key)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// One clip in the browser grid: a lazily-loaded thumbnail (sized by the
    /// slider) with the filename and a selection tick. Tap toggles selection.
    struct FileCell: View {
        let url: URL
        let source: URL
        let size: Double
        let isSelected: Bool
        let isPickable: Bool
        let onTap: () -> Void

        @State private var image: NSImage?
        @State private var didLoad = false

        var body: some View {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let img = image {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.quaternary)
                                .overlay(
                                    Group {
                                        if didLoad {
                                            Image(systemName: FileIcon.symbol(for: url))
                                                .font(.title2)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            ProgressView().controlSize(.small)
                                        }
                                    }
                                )
                        }
                    }
                    .frame(width: size, height: size * 0.75)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                    .opacity(isPickable && !isSelected ? 0.4 : 1.0)

                    if isPickable {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.body)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.8))
                            .background(Circle().fill(.black.opacity(0.35)))
                            .padding(4)
                    }
                }

                Text(url.lastPathComponent)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .frame(width: size)
            }
            .contentShape(Rectangle())
            .onTapGesture { if isPickable { onTap() } }
            .task(id: url) {
                image = await ThumbnailCache.shared.thumbnail(for: url, source: source)
                didLoad = true
            }
        }
    }

    /// One clip as a compact list row: small thumbnail + full filename.
    struct FileRow: View {
        let url: URL
        let source: URL
        let isSelected: Bool
        let isPickable: Bool
        let onTap: () -> Void

        @State private var image: NSImage?
        @State private var didLoad = false

        var body: some View {
            HStack(spacing: 8) {
                if isPickable {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                Group {
                    if let img = image {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                            .overlay(Image(systemName: FileIcon.symbol(for: url))
                                .font(.caption2).foregroundStyle(.secondary))
                    }
                }
                .frame(width: 44, height: 33)
                .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .opacity(isPickable && !isSelected ? 0.45 : 1.0)
            .contentShape(Rectangle())
            .onTapGesture { if isPickable { onTap() } }
            .task(id: url) {
                image = await ThumbnailCache.shared.thumbnail(for: url, source: source)
                didLoad = true
            }
        }
    }
}

enum FileIcon {
    static func symbol(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if Engine.videoExts.contains(ext) || ext == "braw" { return "film" }
        if Engine.audioExts.contains(ext) { return "waveform" }
        return "photo"
    }
}
