# Task: 3 changes to the DIT Media Ingest app (native Swift menu-bar app)

App at `~/dit-ingest-app`. Build/install: `./build.sh install`. Headless regression check:
`./.build/release/DITIngest --selftest` (must still print ok=true and correct manifest counts).
Do NOT break Stage 1 or Stage 2 (both work end-to-end). Files: `Sources/DITIngest/SetupView.swift`,
`AppDelegate.swift`, `Engine.swift`. After building, do NOT pkill/relaunch — the user manages that.

## Change 1 — Capitalize media-type folders: Video / Stills / Audio
The media type is currently the lowercase string ("video"/"stills"/"audio") used BOTH as an internal
key AND as a path component, in `SetupModel.go()` (in SetupView.swift): the dump path
(`projectRoot/mediaType/dateStr/cardName`) and the backup relative path
(`"\(project)/\(mediaType)/\(dateStr)/\(cardName)"`).
Capitalize the FOLDER name (`Video`, `Stills`, `Audio`) consistently in BOTH the dump path and the
backup relative path so dump and backups still match. Keep internal dictionary keys as-is if easier;
just ensure the on-disk folder component is capitalized everywhere it's used. Use `.capitalized`.

## Change 2 — Parallel backups (currently sequential)
In `SetupModel.go()`, the backups for a card currently run in a `for backupDir in backupDirs` loop,
one after another. Make the 1–2 backup locations run CONCURRENTLY (the user's targets are independent
devices: a NAS + a local drive). Use a TaskGroup (async let / withTaskGroup) to run each location's
`Engine.backUpAndVerify` at the same time, then await all. Requirements:
- Still verify each location independently; collect per-location success/failure.
- If ANY location fails verification, set an errorMessage naming which location(s) failed and that the
  SSD copy is safe / retry from SSD, set isRunning=false, and do NOT write the backed-up manifest or
  fire the 2nd notification for that card. (Let the other location finish; report which failed.)
- Only when ALL configured locations for the card succeed: write the backed-up manifest into the SSD
  folder AND each backup folder (each with its own path), fire the 2nd notification, post the Notion
  comment (keep the existing dump-only vs backed-up comment logic).
- Progress UI: the running view shows a single progress bar + speedText. Since two streams run at once,
  show BOTH clearly — e.g. a per-location line each with its own MB/s, OR an aggregate (combined MB/s
  across active streams) with a label listing the active locations. Keep it clean and readable. Add
  whatever @Published fields you need to SetupModel and update SetupView.runningView accordingly.
- Preserve all the logging that the previous task added (dump/backup start/verified/eject/manifest).
  Log each location's backup start/verified/failed independently.

## Change 3 — Menu-bar progress indicator
The menu-bar dropdown has a static "Idle" item (statusMenuItem) updated via `AppDelegate.setStatus`.
It is never updated during a run, so it always says "Idle". Wire it to live status:
- During dump: show e.g. "Dumping 01_SonyA7IV — 207/441 (84 MB/s)".
- During backups: show e.g. "Backing up 01_SonyA7IV — NAS 62%, Spinner 40%" (or aggregate MB/s).
- Also set the NSStatusItem button's TITLE (next to the icon) to a short live form like " 47%" during
  dump and " ⇪62%" during backup, so it's visible even when the user is full-screen. Clear the title
  (back to icon only) and set the dropdown back to "Idle" when the run finishes or errors.
- `SetupModel` has a `weak var appDelegate`. Call appDelegate.setStatus(...) and a new
  appDelegate method (e.g. `setMenuBarTitle(_:)`) from the run loop's progress callbacks. Make sure all
  UI updates happen on the main actor. Add `setMenuBarTitle` to AppDelegate (sets
  `statusItem.button?.title`); reset it to "" at run end.

## Change 4 — Full pipeline logging (a prior task doing this was interrupted; do it here)
In `SetupModel.go()` add `Log.write(...)` calls (existing `Log` enum in Logger.swift) covering the
whole run with detail (card name, paths, counts, bytes, location): dump started; dump verified (or
dump FAILED with failure count); dumped manifest written; card ejected; for EACH backup location:
'backup started -> <location>' before copying and 'backup verified -> <location>' after (or
'backup FAILED -> <location>'); backed-up manifest written; 2nd notification fired; run complete.
Keep the existing Notion comment logging. Logging only — no behavior change beyond the other changes.

## Done criteria
- `./build.sh install` builds; `--selftest` still passes (ok=true, dumped/backed-up counts correct).
- New dumps create `Video`/`Stills`/`Audio` (capitalized) folders, matched between dump and backups.
- Two backup locations run at the same time; failure of one is reported clearly and doesn't fake success.
- Menu bar shows live progress (dropdown + icon title) during a run and returns to Idle after.
