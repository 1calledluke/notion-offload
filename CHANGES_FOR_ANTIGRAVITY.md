# Task: 3 changes to the DIT Media Ingest app

This is a native Swift menu-bar macOS app at `~/dit-ingest-app`. Build/install with
`./build.sh install` (uses Swift Package Manager + assembles a signed .app into
/Applications). After building, relaunch to test:
`pkill -9 -f DITIngest; sleep 1; open "/Applications/DIT Media Ingest.app"`.
A log file is at `~/Library/Application Support/DITIngest/app.log`.
exiftool is at /opt/homebrew/bin/exiftool. Do NOT change anything outside the 3 tasks below.

Key files:
- `Sources/DITIngest/Engine.swift` — copy/verify, camera detection, card-folder naming, manifest.
- `Sources/DITIngest/SetupView.swift` — SwiftUI setup window + the ingest run loop (progress UI).

## Change 1 — Card folder naming
Currently card folders are named `Card One Sony A7IV`, `Card Two B Sony A7IV` (see
`Engine.nextCardFolderName` and the `ordinals` array). Change to:
- `01_SonyA7IV` — a **two-digit zero-padded number**, underscore, then the camera name
  **with all spaces removed** (`Sony A7IV` -> `SonyA7IV`, `Pocket 6K` -> `Pocket6K`).
- Numbering still counts only COMPLETED cards (folders containing a `dumped-*.txt` manifest),
  same logic as today — just numeric (01, 02, 03 …) instead of words.
- Retry of a failed card (folder already exists for that number with no manifest): append a
  capital letter directly after the number -> `02B_SonyA7IV`, then `02C_…` etc.
- Update `isComplete` detection if needed; keep the "complete = has dumped manifest" rule.

## Change 2 — Manifest count must match Finder
Finder counts a folder's items as: **all non-hidden files PLUS all non-hidden subfolders,
recursively** (hidden = names starting with `.`). The current manifest only counts media
files + itself, so it under-counts by the number of subfolders.

Fix `Engine.writeDumpedManifest` (and its caller in SetupView) so the count =
`(non-hidden files, recursive, INCLUDING the manifest itself) + (non-hidden subfolders, recursive)`.
Compute it by walking the destination card folder. Since the manifest is written last, compute:
`mediaFilesCopied + subfolderCount + 1`. Verify: 441 media + 3 subfolders + 1 manifest = 445.
- The filename keeps the form `dumped-<count>-files-<size>.txt`.
- Also add an exact byte count line to the manifest BODY, e.g.
  `Total size: 256,512,345,678 bytes` (comma-grouped), in addition to the existing GB line,
  so it can be matched against Finder Get Info.

## Change 3 — Live transfer speed (MB/s)
During the dump, show a live MB/s readout in the progress view (`SetupView.runningView`).
The copy loop is in `Engine.copyAndVerify` with a `progress` callback and in `SetupModel.go`.
- Track bytes copied over elapsed time and surface current MB/s (a rolling/recent average is
  fine; simplest acceptable: total bytes so far / elapsed seconds).
- Add a `@Published var speedText` (or similar) to `SetupModel`, update it from the progress
  callback, and display it under the ProgressView. MB = 1,000,000 bytes.

## Done criteria
- App builds with `./build.sh install` and runs.
- A test dump (you can simulate with a folder of files chosen via "Run Ingest…" from the menu,
  or mount a disk image) produces a card folder named like `01_SonyA7IV`, a manifest whose
  count equals Finder's item count for that folder, and shows MB/s while copying.
- Do not implement backups (Stage 2) — that's handled separately.
