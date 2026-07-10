# Task: "Pending Backups" panel (replaces the one-at-a-time resume alert)

App at `~/dit-ingest-app`. Build: `./build.sh install`.
Regression: `swift build && ./.build/debug/DITIngest --selftest` must pass (DEBUG binary — it has asserts).
Touch: `Sources/DITIngest/ResumeDetector.swift`, `Sources/DITIngest/AppDelegate.swift`,
new file `Sources/DITIngest/PendingBackupsWindow.swift`.
Do NOT change Engine.swift or the resume execution logic in SetupView.swift.

## Background

Today, `ResumeDetector.findIncompleteRun` returns only the MOST RECENT incomplete card, and
AppDelegate shows a 3-button NSAlert per card at launch. The user wants instead: one panel
listing ALL incomplete card runs, each with Retry and Remove.

## Change 1 — ResumeDetector: return ALL incomplete runs

Add:
```swift
static func findIncompleteRuns(logPath: URL) -> [IncompleteRun]
```
Same parsing as today, but instead of returning the first hit from `order.reversed()`,
collect EVERY card that meets the incomplete criteria (dumpVerified, ejected, not complete,
has unverified dirs, SSD folder still exists on disk), ordered most-recent-first.

Refactor `findIncompleteRun` to `return findIncompleteRuns(logPath: logPath).first` so the
existing selftest cases keep passing unchanged.

## Change 2 — PendingBackupsWindow.swift (new)

A small `@MainActor` window controller + SwiftUI view, styled like the rest of the app
(same header pattern as SetupView: icon + title "Pending Backups", divider, then content).

```swift
@MainActor
final class PendingBackupsController: NSObject, NSWindowDelegate {
    init(runs: [IncompleteRun], appDelegate: AppDelegate)
    func show()
}
```

View: one row per IncompleteRun:
```
┌───────────────────────────────────────────────────────┐
│ 01_BMP6K_26.07.10                                     │
│ Missing: Hope Church 2, 2025 Backup                   │
│ SSD copy: …/26.07_Equip Videos_0118/Video/01_BMP6K…   │
│                                   [Remove]  [Retry ▶] │
└───────────────────────────────────────────────────────┘
```
- Card name: `.headline`
- Missing locations: volume last-path-components, `.callout` `.secondary`
- SSD path: `.caption` `.secondary`, truncated middle, `.help(fullPath)`
- Retry: `.borderedProminent`, calls `appDelegate.openResume(run)` (make that method
  internal instead of private) and removes the row from the list.
- Remove: `.bordered`, writes the handled markers exactly like the current alert does:
  ```swift
  Log.write("user marked card as handled -> \(run.cardName)")
  Log.write("backup complete -> card: \(run.cardName)")
  Log.flush()
  ```
  then removes the row.
- When the last row is removed/retried, close the window.
- Empty state (if opened manually with nothing pending): centered "No pending backups. 🎉"
  with a Close button.
- Window: titled+closable, ~460×320, `isReleasedWhenClosed = false`, delegate cleanup like
  SetupWindowController (windowWillClose → notify appDelegate to drop the reference).

## Change 3 — AppDelegate wiring

- Replace `checkForIncompleteRun()`'s NSAlert with:
  ```swift
  let runs = ResumeDetector.findIncompleteRuns(logPath: Log.logFileURL)
  guard !runs.isEmpty else { return }
  showPendingBackups(runs)
  ```
- `showPendingBackups(_ runs:)` creates/keeps a `PendingBackupsController` (single instance,
  stored property; if already open, bring to front with refreshed runs).
- Menu: add "Pending Backups…" item between "Run Ingest…" and Quit (with a separator),
  action recomputes `findIncompleteRuns` and opens the panel (empty state allowed).
- `openResume(_:)` becomes internal (drop `private`) so the panel can call it.
- Keep everything else (jobs dict, controllers array) as-is.

## Done criteria

- DEBUG `--selftest` passes (existing ResumeDetector cases unchanged via the .first refactor).
- On launch with 2+ incomplete cards, ONE panel lists them all; Retry opens the normal
  resume window for that card; Remove silences that card permanently.
- "Pending Backups…" menu item opens the panel any time.
- `./build.sh install` succeeds.
