# Task: estimated time remaining on all transfer progress

App at `~/dit-ingest-app`. Build: `./build.sh install`.
Regression: `swift build && ./.build/debug/DITIngest --selftest` must pass (DEBUG binary — has asserts).
Touch ONLY `Sources/DITIngest/SetupView.swift`. No Engine/AppDelegate/detector changes.

## Helper (add to SetupView.swift, file scope or SetupModel extension)

```swift
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
```

## Wire-up

1. **Dump phase**: `SetupModel` gets `@Published var etaText: String = ""`. In `go()`'s dump
   progress closure (it already has `bytesCopied`, `grandTotal`, and `elapsed` via `startTime`),
   compute the eta and set it inside the existing `Task { @MainActor in }` block. Clear it (`""`)
   when the dump loop moves to the next card folder and when the run ends/errors.
   In `dumpPhaseView`, show it next to the speed:
   `84.3 MB/s  ·  ~12 min left` — the "left" suffix added in the view, `.callout`, `.secondary`,
   `.monospacedDigit()`. Hide when etaText is empty or speedText is "verifying…".

2. **Backup rows**: `BackupProgressState` gets `var etaText: String = ""`. Both backup progress
   closures (normal `go()` backups AND `resumeBackup()`) compute it the same way and store it
   when building the `BackupProgressState`. In `backupPhaseView`'s row HStack, show it after the
   percentage: `62%  ·  ~8 min` (`.caption`, `.secondary`, `.monospacedDigit()`). Hide when empty
   or when speedText is "verifying…"/"Done ✓"/"Failed".

3. **Menu bar**: in the dump progress closure, append the eta to the job status text (NOT the
   short title): e.g. `Dumping 01_X — 3/201 (290 MB/s, ~12 min left)`. Same for the backup
   status text: `Backing up 01_X — HC2 62% (~8 min), 2025 41% (~11 min)` — use each location's
   own eta. Keep the short menu-bar titles (⇩47% / ⇪62%) unchanged.

## Done criteria
- Build clean; DEBUG selftest passes untouched.
- During a dump: speed line shows `X MB/s · ~N min left`, menu dropdown includes eta.
- During backups: each drive row shows its own eta; both go()'s and resume's paths covered.
- ETA hidden during the first ~2 seconds, during verify, and when done/failed.
