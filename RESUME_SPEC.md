# Task: Crash-recovery / resume incomplete backup

App at `~/dit-ingest-app`. Build: `./build.sh install`.
Touch: `Sources/DITIngest/AppDelegate.swift`, `Sources/DITIngest/SetupView.swift`,
`Sources/DITIngest/Logger.swift` (read-only reference), `Sources/DITIngest/Engine.swift` (read-only reference).
Do NOT change Engine logic, disk-watcher, or any copy/verify functions.

---

## Background

The log file at `~/Library/Application Support/DITIngest/app.log` records every step of an ingest run.
A completed run looks like:
```
dump started -> card: 01_SonyA7IV_26.06.30, dest: /Volumes/SSD/.../Stills/01_SonyA7IV_26.06.30, files: 479
dump verified -> 01_SonyA7IV_26.06.30, ...
dumped manifest written -> ...
card ejected -> /Volumes/Untitled
backup started -> /Volumes/Hope Church 2
backup started -> /Volumes/2025 Backup
backup verified -> /Volumes/Hope Church 2
backup verified -> /Volumes/2025 Backup
BU manifest written -> ...
2nd notification fired -> ...
run complete
```

An INCOMPLETE run (app quit/crashed during backup) ends like:
```
card ejected -> /Volumes/Untitled
backup started -> /Volumes/Hope Church 2
backup started -> /Volumes/2025 Backup
```
...and then nothing. No `run complete`, no `backup verified` for at least one location.

---

## Change 1 — Log parser (new file: Sources/DITIngest/ResumeDetector.swift)

Create a new enum `ResumeDetector` with one static method:

```swift
struct IncompleteRun {
    let cardName: String          // e.g. "01_SonyA7IV_26.06.30"
    let ssdCardFolder: URL        // the dump destination from "dump started" line
    let backupDirs: [String]      // all "backup started" paths that appeared
    let verifiedDirs: [String]    // "backup verified" paths that appeared before crash
}

enum ResumeDetector {
    static func findIncompleteRun(logPath: URL) -> IncompleteRun?
}
```

### Parsing logic:

Read the log file line by line. Track state by scanning for the LAST run's lines
(lines after the last `App launched` entry, or the last `run complete` entry — whichever is more recent).

Within that window, look for:
- `dump started -> card: {cardName}, dest: {destPath}, files: ...`
  → extract cardName and destPath (the full SSD card folder path)
- `card ejected ->` → confirm card is gone (dump is done, can't go back)
- `backup started -> {dir}` → collect backup dirs
- `backup verified -> {dir}` → collect verified dirs
- `run complete` → this run is done, not incomplete

A run is incomplete if ALL of these are true:
1. `dump verified` line exists for the card
2. `card ejected` line exists
3. At least one `backup started` line exists
4. `run complete` is ABSENT from the current run window

If incomplete, return an `IncompleteRun`. Otherwise return nil.

### Edge cases:
- If the SSD card folder no longer exists on disk, return nil (can't resume).
- If ALL backup dirs were verified (verifiedDirs == backupDirs), return nil (already done).
- Only detect ONE incomplete run (the most recent one). Ignore older ones.

---

## Change 2 — Resume prompt on launch (AppDelegate.swift)

In `applicationDidFinishLaunching`, after `diskWatcher.start()`, add:

```swift
checkForIncompleteRun()
```

Implement `checkForIncompleteRun()` as a private method on AppDelegate:

```swift
private func checkForIncompleteRun() {
    let logPath = Log.logFileURL  // add this static property to Logger.swift (see below)
    guard let incomplete = ResumeDetector.findIncompleteRun(logPath: logPath) else { return }

    let unverified = incomplete.backupDirs.filter { !incomplete.verifiedDirs.contains($0) }
    let locationNames = unverified.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")

    let alert = NSAlert()
    alert.messageText = "Incomplete backup detected"
    alert.informativeText = "The last ingest run for \"\(incomplete.cardName)\" was interrupted before backups finished.\n\nMissing backups: \(locationNames)\n\nThe SSD copy is safe. Resume backups from the SSD now?"
    alert.addButton(withTitle: "Resume Backup")
    alert.addButton(withTitle: "Dismiss")
    NSApp.activate(ignoringOtherApps: true)

    if alert.runModal() == .alertFirstButtonReturn {
        openResume(incomplete)
    }
}

private func openResume(_ run: IncompleteRun) {
    let controller = SetupWindowController(resumeRun: run, appDelegate: self)
    setupController = controller
    controller.show()
}
```

---

## Change 3 — Log.logFileURL (Logger.swift)

Add a static property so AppDelegate can reference the log path without duplicating the string:

```swift
static var logFileURL: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return support.appendingPathComponent("DITIngest/app.log")
}
```

(The existing `write` method already builds this path internally — just expose it.)

---

## Change 4 — Resume path in SetupWindowController + SetupModel

`SetupWindowController` currently only takes a `sourceURL`. Add a second init for the resume path.

In `SetupWindowController`:
```swift
// Existing init stays:
init(sourceURL: URL, appDelegate: AppDelegate)

// New resume init:
init(resumeRun: IncompleteRun, appDelegate: AppDelegate)
```

The resume init creates a `SetupModel` in resume mode instead of normal mode.

### SetupModel resume mode

Add an init overload:

```swift
init(resumeRun: IncompleteRun, appDelegate: AppDelegate?)
```

In this mode:
- `sourceURL` = the SSD card folder URL (so the window title shows the card name)
- Add a `@Published var resumeRun: IncompleteRun?` property
- On init, set `resumeRun = run`, skip `refreshProjects()` (not needed)
- `isRunning` starts false; show a special "ready to resume" UI state

### Resume UI in SetupView

When `model.resumeRun != nil`, replace the formView with a minimal `resumeReadyView`:

```
[arrow.clockwise.circle.fill icon — accent, 40pt]

Resume Backup
01_SonyA7IV_26.06.30

The SSD copy is verified and safe.
Backup will resume to:
  • Hope Church 2
  • 2025 Backup

                        [Cancel]  [Resume Backup ▶]
```

"Resume Backup" button calls `model.resumeBackup()`.

### SetupModel.resumeBackup()

```swift
func resumeBackup() {
    guard let run = resumeRun else { return }
    isRunning = true
    errorMessage = nil
    activeBackups = [:]
    let ssdFolder = run.ssdCardFolder
    let cardName = run.cardName
    let unverifiedDirs = run.backupDirs.filter { !run.verifiedDirs.contains($0) }
    let token = config.notionToken
    // Derive projectID from config or leave empty — Notion comment is best-effort
    let projectID = ""

    Task.detached {
        Log.write("resume backup started -> \(cardName)")

        // Determine totalBytes from the SSD folder for manifest + menu bar
        let totalBytes = Engine.mediaFiles(in: ssdFolder)
            .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }

        // Build relPath from ssdFolder structure: strip the dump root prefix
        // ssdFolder is e.g. /Volumes/SSD/ClientName/ProjectName/Video/01_SonyA7IV_26.06.30
        // relPath for backup dest = ClientName/ProjectName/Video/01_SonyA7IV_26.06.30
        // We can't know the dump root here, so derive relPath from the last 4 path components:
        let comps = ssdFolder.pathComponents
        let relPath = comps.suffix(4).joined(separator: "/")  // Client/Project/MediaType/CardFolder

        var backupLocationsSucceeded: [URL] = []
        var failedDirs: [String] = []

        let results = await withTaskGroup(of: BackupTaskResult.self) { group in
            for dir in unverifiedDirs {
                let backupURL = URL(fileURLWithPath: dir)
                let destFolder = backupURL.appendingPathComponent(relPath)
                let volumeName = (try? backupURL.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? backupURL.lastPathComponent
                let label = volumeName

                group.addTask {
                    Log.write("resume backup started -> \(dir)")
                    let startTime = Date()
                    let result = Engine.backUpAndVerify(ssdCardFolder: ssdFolder, to: destFolder) { i, total, name, bytesCopied in
                        let elapsed = Date().timeIntervalSince(startTime)
                        let mbps = elapsed > 0.1 ? Double(bytesCopied) / 1_000_000.0 / elapsed : 0.0
                        let fraction = Double(i) / Double(max(total, 1))
                        Task { @MainActor in
                            self.activeBackups[dir] = BackupProgressState(
                                label: label, progressFraction: fraction,
                                speedText: String(format: "%.1f MB/s", mbps), currentFile: name)
                            let avg = self.activeBackups.values.map { $0.progressFraction }.reduce(0, +) / Double(max(self.activeBackups.count, 1))
                            self.appDelegate?.setMenuBarTitle(" ⇪\(Int(avg * 100))%")
                        }
                    }
                    if result.ok { Log.write("resume backup verified -> \(dir)") }
                    else { Log.write("resume backup FAILED -> \(dir)") }
                    return BackupTaskResult(backupDir: dir, destFolder: destFolder, ok: result.ok, failures: result.failures)
                }
            }
            var list: [BackupTaskResult] = []
            for await r in group { list.append(r) }
            return list
        }

        for res in results {
            if res.ok { backupLocationsSucceeded.append(res.destFolder) }
            else { failedDirs.append(res.backupDir) }
        }

        if !failedDirs.isEmpty {
            let names = failedDirs.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
            await MainActor.run {
                self.errorMessage = "Backup to \(names) failed. SSD copy is safe; retry manually."
                self.appDelegate?.setMenuBarTitle("")
                self.appDelegate?.setStatus("Idle")
                self.isRunning = false
            }
            return
        }

        // All succeeded — write BU manifests
        for dest in backupLocationsSucceeded {
            let m = Engine.writeBackedUpManifest(in: dest, dumpFolder: ssdFolder,
                                                  allBackupFolders: backupLocationsSucceeded,
                                                  totalBytes: totalBytes)
            Log.write("BU manifest written -> \(m.path)")
        }

        await MainActor.run {
            self.appDelegate?.notify(title: "DIT Media Ingest", body: "\(cardName) backup complete.")
        }
        Log.write("run complete")

        await MainActor.run {
            self.finishedMessage = "\(cardName) backed up successfully."
            self.appDelegate?.setMenuBarTitle("")
            self.appDelegate?.setStatus("Idle")
            self.isRunning = false
        }
    }
}
```

---

## Done criteria

- `./build.sh install` compiles clean.
- `--selftest` still passes (ResumeDetector is not exercised by selftest — that's fine).
- On launch after a crashed backup run, the app shows the "Incomplete backup detected" alert.
- Clicking "Resume Backup" opens the window in resume mode showing the card name + missing locations.
- Clicking "Resume Backup ▶" runs only the missing backup locations (not re-dumping to SSD).
- On success: BU manifests written, notification fired, "run complete" logged.
- On dismiss or if no incomplete run found: app behaves exactly as before.
