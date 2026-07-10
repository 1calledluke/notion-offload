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

struct CardThumb: Identifiable, @unchecked Sendable {
    let id = UUID()
    let image: NSImage?     // nil -> show placeholder icon
    let filename: String
}

final class FileNode: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let children: [FileNode]   // empty array for files
    var isChecked: Bool = true // for files only; dirs derive from children
    var isExpanded: Bool = true

    init(url: URL, name: String, isDirectory: Bool, children: [FileNode] = []) {
        self.url = url; self.name = name
        self.isDirectory = isDirectory; self.children = children
    }

    enum CheckState { case on, off, mixed }
    var checkState: CheckState {
        guard isDirectory else { return isChecked ? .on : .off }
        let leaves = leafFiles()
        guard !leaves.isEmpty else { return .on }
        let n = leaves.filter { $0.isChecked }.count
        if n == leaves.count { return .on }
        return n == 0 ? .off : .mixed
    }

    func leafFiles() -> [FileNode] {
        isDirectory ? children.flatMap { $0.leafFiles() } : [self]
    }

    func toggle() { setAll(checkState != .on) }

    func setAll(_ val: Bool) {
        isChecked = val
        children.forEach { $0.setAll(val) }
    }

    func selectedURLs() -> [URL] {
        isDirectory ? children.flatMap { $0.selectedURLs() }
                    : (isChecked ? [url] : [])
    }
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
    @Published var cardThumbs: [CardThumb] = []
    @Published var cardSummary: String = ""

    @Published var selectiveMode: Bool = false
    @Published var fileTree: FileNode? = nil
    @Published var fileTreeRevision: Int = 0

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

        let isSelective = selectiveMode
        let selectedPaths: Set<String>? = isSelective
            ? Set((fileTree?.selectedURLs() ?? []).map { $0.path })
            : nil

        Task.detached {
            var byType = Engine.filesByType(in: source)
            if let paths = selectedPaths, !paths.isEmpty {
                byType = byType.mapValues { $0.filter { paths.contains($0.path) } }
                               .filter { !$0.value.isEmpty }
            }
            if byType.isEmpty {
                await MainActor.run {
                    self.errorMessage = "No media files found on the card."
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

                let startTime = Date()
                let result = Engine.copyAndVerify(source: source, files: files,
                                                  destFolder: cardFolder) { i, total, name, bytesCopied, grandTotal in
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

    func loadCardPreview() {
        let source = self.sourceURL
        Task.detached {
            let byType = Engine.filesByType(in: source)
            
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
            
            // Modification-date range
            var dates: [Date] = []
            for file in allMediaFiles {
                if let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    dates.append(date)
                }
            }
            
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
            
            // Interleave files (videos first, then stills, then audio)
            func interleave(videos: [URL], stills: [URL], audios: [URL]) -> [URL] {
                var result: [URL] = []
                var vIdx = 0
                var sIdx = 0
                var aIdx = 0
                while vIdx < videos.count || sIdx < stills.count || aIdx < audios.count {
                    if vIdx < videos.count {
                        result.append(videos[vIdx])
                        vIdx += 1
                    }
                    if sIdx < stills.count {
                        result.append(stills[sIdx])
                        sIdx += 1
                    }
                    if aIdx < audios.count {
                        result.append(audios[aIdx])
                        aIdx += 1
                    }
                }
                return result
            }
            
            let interleaved = interleave(videos: videos, stills: stills, audios: audios)
            let targetFiles = Array(interleaved.prefix(8))
            
            var thumbs: [CardThumb] = []
            for file in targetFiles {
                let img = Self.generateThumbnail(for: file, in: source)
                thumbs.append(CardThumb(image: img, filename: file.lastPathComponent))
            }
            let finalThumbs = thumbs
            await MainActor.run {
                self.cardSummary = summaryText
                self.cardThumbs = finalThumbs
            }
        }
    }

    func buildFileTree() {
        let source = sourceURL
        Task.detached {
            func node(for url: URL) -> FileNode {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    let contents = (try? FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: [.isDirectoryKey],
                        options: .skipsHiddenFiles)) ?? []
                    let sorted = contents.sorted { a, b in
                        let aD = (try? a.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                        let bD = (try? b.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                        if aD != bD { return aD }
                        return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
                    }
                    return FileNode(url: url, name: url.lastPathComponent, isDirectory: true,
                                    children: sorted.map { node(for: $0) })
                } else {
                    return FileNode(url: url, name: url.lastPathComponent, isDirectory: false)
                }
            }
            let tree = node(for: source)
            await MainActor.run {
                self.fileTree = tree
                self.fileTreeRevision += 1
            }
        }
    }

    nonisolated private static func findProxyFile(basename: String, source: URL) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        
        for case let url as URL in en {
            if url.lastPathComponent.caseInsensitiveCompare("Proxy") == .orderedSame {
                if let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    for file in files {
                        let fileBase = file.deletingPathExtension().lastPathComponent
                        let fileExt = file.pathExtension.lowercased()
                        if fileBase.caseInsensitiveCompare(basename) == .orderedSame && (fileExt == "mp4" || fileExt == "mov") {
                            return file
                        }
                    }
                }
            }
        }
        return nil
    }

    nonisolated private static func generateStillThumbnail(for url: URL) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return NSImage(cgImage: cg, size: .zero)
        }
        return nil
    }

    nonisolated private static func generateVideoThumbnail(for url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 320)
        if let cg = try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil) {
            return NSImage(cgImage: cg, size: .zero)
        }
        return nil
    }

    nonisolated private static func generateThumbnail(for url: URL, in source: URL) -> NSImage? {
        let ext = url.pathExtension.lowercased()
        
        if ext == "braw" {
            let basename = url.deletingPathExtension().lastPathComponent
            if let proxyURL = findProxyFile(basename: basename, source: source) {
                return generateVideoThumbnail(for: proxyURL)
            }
            return nil
        }
        
        let videoExts = ["mp4", "mov", "m4v", "mts", "m2ts", "avi", "mxf"]
        if videoExts.contains(ext) {
            return generateVideoThumbnail(for: url)
        }
        
        let stillExts = ["jpg", "jpeg", "png", "tif", "tiff", "arw", "dng", "raw", "heic", "cr2", "nef"]
        if stillExts.contains(ext) {
            return generateStillThumbnail(for: url)
        }
        
        return nil
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
        .frame(width: 540, height: 600)
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

    private var formView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section: Card Preview
            VStack(alignment: .leading, spacing: 8) {
                Text("CARD PREVIEW")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                
                if model.cardThumbs.isEmpty && model.cardSummary.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reading card…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if !model.cardSummary.isEmpty {
                            Text(model.cardSummary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(model.cardThumbs) { thumb in
                                    VStack(alignment: .center, spacing: 4) {
                                        if let img = thumb.image {
                                            Image(nsImage: img)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 96, height: 72)
                                                .clipped()
                                                .cornerRadius(6)
                                        } else {
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(.quaternary)
                                                .frame(width: 96, height: 72)
                                                .overlay(
                                                    Image(systemName: placeholderSymbol(for: thumb.filename))
                                                        .font(.title2)
                                                        .foregroundColor(.secondary)
                                                )
                                        }
                                        
                                        Text(thumb.filename)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .frame(maxWidth: 96)
                                    }
                                }
                            }
                        }
                    }
                }
            }

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

            // Section: Selective Copy
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Let me decide what to copy", isOn: $model.selectiveMode)
                    .font(.callout)
                    .onChange(of: model.selectiveMode) { _, enabled in
                        if enabled && model.fileTree == nil {
                            model.buildFileTree()
                        }
                    }

                if model.selectiveMode {
                    Group {
                        if let tree = model.fileTree {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(tree.children) { child in
                                        FileTreeNodeView(node: child, onToggle: { model.fileTreeRevision += 1 })
                                    }
                                }
                                .padding(6)
                            }
                            .id(model.fileTreeRevision)
                            .frame(height: 200)
                            .background(.background)
                            .border(.separator)
                        } else {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Scanning card…").font(.callout).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 60)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.2), value: model.fileTree != nil)
                }
            }
            
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

    private func placeholderSymbol(for filename: String) -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let videoExts = ["mp4", "mov", "mxf", "avi", "m4v", "braw", "mts", "m2ts"]
        let audioExts = ["wav", "aif", "aiff", "mp3", "flac", "m4a"]
        if videoExts.contains(ext) {
            return "video"
        } else if audioExts.contains(ext) {
            return "waveform"
        } else {
            return "photo"
        }
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

    struct FileTreeNodeView: View {
        let node: FileNode
        let onToggle: () -> Void
        @State private var isExpanded: Bool

        init(node: FileNode, onToggle: @escaping () -> Void) {
            self.node = node
            self.onToggle = onToggle
            self._isExpanded = State(initialValue: node.isExpanded)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if node.isDirectory && !node.children.isEmpty {
                        Button {
                            isExpanded.toggle()
                            node.isExpanded = isExpanded
                        } label: {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .frame(width: 10)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    } else {
                        Spacer().frame(width: 10)
                    }

                    Button {
                        node.toggle()
                        onToggle()
                    } label: {
                        Image(systemName: checkboxSymbol)
                            .foregroundStyle(checkboxColor)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)

                    Image(systemName: iconName)
                        .font(.caption)
                        .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)

                    Text(node.name)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(node.checkState == .off ? Color.secondary : Color.primary)

                    Spacer()
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())

                if node.isDirectory && isExpanded && !node.children.isEmpty {
                    ForEach(node.children) { child in
                        FileTreeNodeView(node: child, onToggle: onToggle)
                            .padding(.leading, 16)
                    }
                }
            }
        }

        var checkboxSymbol: String {
            switch node.checkState {
            case .on:    return "checkmark.square.fill"
            case .off:   return "square"
            case .mixed: return "minus.square.fill"
            }
        }
        var checkboxColor: Color { node.checkState == .off ? .secondary : .accentColor }
        var iconName: String {
            if node.isDirectory { return "folder.fill" }
            let ext = node.url.pathExtension.lowercased()
            if Engine.videoExts.contains(ext) { return "film" }
            if Engine.stillsExts.contains(ext) { return "photo" }
            if Engine.audioExts.contains(ext) { return "waveform" }
            return "doc"
        }
    }
}
