# Task: stamp real capture dates on ingest (kill FAT-epoch + bad-clock dates)

App at `~/dit-ingest-app`. Build: `./build.sh install`.
Regression: `swift build && ./.build/debug/DITIngest --selftest` must pass (asserts fire only in the DEBUG binary).
Touch ONLY: `Sources/DITIngest/Engine.swift`, `Sources/DITIngest/SetupView.swift`.
Do NOT change: ResumeDetector.swift, AppDelegate.swift, BackupCoordinator.swift, Notion.swift, streamCopy's internals beyond what's specified.

## Background / the bug

`streamCopy` (Engine.swift ~line 500) copies the **source file's filesystem mod/create date**
onto the dumped copy. That date is frequently a lie:

1. **FAT/exFAT epoch** — Sony cards report `1980-01-01` (or `1979-12-31 23:00`) as the fs mod
   date. The file's *embedded EXIF* date is correct (e.g. `2024-10-19`). exiftool can recover it.
2. **Bad camera clock** — a Blackmagic body with a dead clock battery writes a wrong date into
   the file itself (we have BRAW stamped `2027-04-25`, a future date). EXIF **cannot** fix this;
   the user must supply the real shoot date.

Result: hundreds of Dropbox files with dates 46 years off, or in the future. This fixes it for all
**future** ingests. (Existing files are handled separately — out of scope here.)

## Design (locked — do not improvise the date logic)

**Per-file date priority, applied to the dumped copy after verify:**
1. If a card-level `dateOverride` was supplied (user corrected a bad clock): use it. Take Y/M/D
   from the override, keep H:M:S from the file's existing source mod date (so clips keep their
   within-day order). If the source time is itself implausible, use 12:00:00.
2. Else the embedded capture date (`DateTimeOriginal` ?? `CreateDate` ?? `MediaCreateDate`) **if
   plausible**.
3. Else leave whatever streamCopy already set (don't make it worse).

**Plausibility:** a date is implausible if `year < 2005` OR it is later than `now + 2 days`.

**Backups are already correct** — they copy from the SSD (whose dates we just fixed) and
streamCopy preserves source dates. So ONLY the dump path changes. Backup call site
(Engine.swift:606) and SelfTest (SelfTest.swift:68) pass the new params as nil — leave them.

---

## Change 1 — Engine.swift: read embedded capture dates

Add a batched exiftool reader (mirror the existing `detectDevice` at line 127 — same Process
pattern, same `exiftoolPath()` helper).

```swift
/// Real capture date per file, read from embedded metadata via one exiftool pass.
/// Keyed by absolute source path. Files with no embedded date are absent from the map.
static func readCaptureDates(for files: [URL]) -> [String: Date] {
    guard !files.isEmpty, let exiftool = exiftoolPath() else { return [:] }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: exiftool)
    proc.arguments = ["-json", "-api", "QuickTimeUTC",
                      "-DateTimeOriginal", "-CreateDate", "-MediaCreateDate",
                      "-SourceFile"] + files.map { $0.path }
    let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
    do { try proc.run() } catch { return [:] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [:] }

    var out: [String: Date] = [:]
    for entry in entries {
        guard let src = entry["SourceFile"] as? String else { continue }
        for key in ["DateTimeOriginal", "CreateDate", "MediaCreateDate"] {
            if let raw = entry[key] as? String, let d = parseExifDate(raw) {
                out[src] = d          // first (highest-priority) hit wins
                break
            }
        }
    }
    return out
}

/// exiftool emits "YYYY:MM:DD HH:MM:SS" (optionally with fractional secs / TZ). Parse leniently.
static func parseExifDate(_ s: String) -> Date? {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed.hasPrefix("0000") { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    for fmt in ["yyyy:MM:dd HH:mm:ssZZZZZ", "yyyy:MM:dd HH:mm:ss", "yyyy:MM:dd"] {
        f.dateFormat = fmt
        // strip a trailing ".sss" fractional-seconds block if present
        let candidate = trimmed.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        if let d = f.date(from: candidate) { return d }
    }
    return nil
}

static func isPlausibleDate(_ d: Date) -> Bool {
    let cutoff = Calendar.current.date(from: DateComponents(year: 2005))!
    let ceiling = Date().addingTimeInterval(2 * 86_400)
    return d >= cutoff && d <= ceiling
}
```

## Change 2 — Engine.swift: assess a card's clock (for the UI prompt)

```swift
struct ClockAssessment {
    let suspect: Bool          // clock looks wrong → prompt user
    let bestGuess: Date        // prefill for the date picker
    let observedMax: Date?     // what the card thinks the newest date is
}

/// Only flags a genuinely wrong *embedded* clock (the Blackmagic case). FAT-epoch cards
/// have good embedded dates and are fixed silently — they do NOT flag here.
static func assessClock(for files: [URL]) -> ClockAssessment {
    let dates = Array(readCaptureDates(for: files).values)
    guard let maxD = dates.max() else {
        return ClockAssessment(suspect: false, bestGuess: Date(), observedMax: nil)
    }
    let suspect = !isPlausibleDate(maxD)      // newest embedded date is impossible
    return ClockAssessment(suspect: suspect, bestGuess: Date(), observedMax: maxD)
}
```

## Change 3 — Engine.swift: apply the date in copyAndVerify

Add two optional params (default nil ⇒ existing behavior, so backup/selftest callers are
untouched):

```swift
static func copyAndVerify(source: URL, files: [URL], destFolder: URL,
                          healMismatched: Bool = false,
                          captureDates: [String: Date]? = nil,   // NEW: src path → embedded date
                          dateOverride: Date? = nil,             // NEW: user-corrected card date
                          progress: ((Int, Int, String, Int64, Int64) -> Void)? = nil) -> CopyResult {
```

After a file successfully copies+verifies (both the "already exists & matches" branch at ~line 310
and the fresh-copy success branch at ~line 349), stamp the destination:

```swift
applyCaptureDate(to: dstFile, source: srcFile,
                 captureDates: captureDates, override: dateOverride)
```

Helper:
```swift
private static func applyCaptureDate(to dst: URL, source src: URL,
                                     captureDates: [String: Date]?, override: Date?) {
    let fm = FileManager.default
    let srcMod = (try? fm.attributesOfItem(atPath: src.path)[.modificationDate]) as? Date

    let final: Date?
    if let ov = override {
        // Keep the source time-of-day, replace the Y/M/D with the corrected date.
        var cal = Calendar.current
        let ymd = cal.dateComponents([.year, .month, .day], from: ov)
        let base = (srcMod.map(isPlausibleTimeOfDay) == true) ? srcMod! : ov
        var t = cal.dateComponents([.hour, .minute, .second], from: base)
        t.year = ymd.year; t.month = ymd.month; t.day = ymd.day
        final = cal.date(from: t)
    } else if let emb = captureDates?[src.path], isPlausibleDate(emb) {
        final = emb
    } else {
        final = nil   // leave streamCopy's value alone
    }
    guard let d = final else { return }
    try? fm.setAttributes([.modificationDate: d, .creationDate: d], ofItemAtPath: dst.path)
}

// A time-of-day is "plausible" if its whole date is; used only to decide whether to keep it.
private static func isPlausibleTimeOfDay(_ d: Date) -> Bool { isPlausibleDate(d) }
```

## Change 4 — SetupView.swift: wire it into the dump

### 4a. SetupModel (class at line 39) — add state:
```swift
@Published var clockSuspect: Bool = false
@Published var dateOverride: Date? = nil        // set only when the user corrects a bad clock
@Published var suspectObservedMax: Date? = nil
```

### 4b. Preview scan — assess the clock and fix the summary date range.
The summary builder (~line 719-768) currently reads `contentModificationDate` for its
"Jun 4 – Jun 30" range — that's the *bad* fs date. Change it to use embedded capture dates so the
preview stops showing 1979/2027 ranges:

- Compute `let caps = Engine.readCaptureDates(for: <the media files being summarized>)` once.
- Use `caps.values` (filtered to plausible) for the min/max date range; fall back to fs date only
  when a file has no embedded date.
- Also compute `let clk = Engine.assessClock(for: <same files>)` and, back on the main actor:
  ```swift
  self.clockSuspect = clk.suspect
  self.suspectObservedMax = clk.observedMax
  if clk.suspect && self.dateOverride == nil { self.dateOverride = clk.bestGuess }
  ```
(One exiftool pass is fine — `detectDevice` already runs one at this stage. If convenient, reuse a
single `readCaptureDates` result for both the summary range and `assessClock` rather than calling
twice.)

### 4c. UI — a non-blocking warning + date picker.
In the form body, when `model.clockSuspect`, show a warning row **above the Start button** (do NOT
disable the button — ingest must never be blocked):

> ⚠️ This card's clock looks wrong — it reads **{suspectObservedMax, medium date}**, which isn't a
> real shoot date. Files will be dated: **[DatePicker bound to dateOverride]**

DatePicker binding (dateOverride is non-nil whenever suspect, per 4b):
```swift
DatePicker("", selection: Binding(
    get: { model.dateOverride ?? Date() },
    set: { model.dateOverride = $0 }),
    displayedComponents: .date)
.labelsHidden()
```
Style it like the existing warning/status rows in this view.

### 4d. go() — pass the dates into the dump.
At the dump call (`Engine.copyAndVerify(source: source, files: files, ...)` ~line 306):
```swift
let capDates = Engine.readCaptureDates(for: files)
let result = Engine.copyAndVerify(source: source, files: files,
                                  destFolder: /* unchanged */,
                                  captureDates: capDates,
                                  dateOverride: model.dateOverride,
                                  progress: /* unchanged */)
```
`dateOverride` is nil unless the user corrected a suspect card → normal cards get the silent
EXIF fix, bad-clock cards get the corrected date.

## Verification (must do before returning)
1. `swift build` clean.
2. `./.build/debug/DITIngest --selftest` passes (the new copyAndVerify params default to nil, so
   the existing selftest call is unaffected — confirm it still builds and passes).
3. Add a selftest assertion in SelfTest.swift ONLY IF trivial: after the existing dump, if any
   source file has a readable embedded date, assert the dumped copy's mod date matches it (±1 day).
   If this can't be done cleanly with the selftest's synthetic files, skip it and say so.
4. Report: confirm the backup call site (Engine.swift:606) and SelfTest call were left passing nil.
