# Task: Build Stage 2 (backups + Notion comment) for the DIT Media Ingest app

Native Swift menu-bar app at `~/dit-ingest-app`. Build/install: `./build.sh install`.
Relaunch to test: `pkill -9 -f DITIngest; sleep 1; open "/Applications/DIT Media Ingest.app"`.
Log: `~/Library/Application Support/DITIngest/app.log`. Config (incl. Notion token):
`~/Library/Application Support/DITIngest/config.json`.

Do NOT break Stage 1 (dump + verify + manifest + eject + first notification), which already works.
Do NOT implement crash-recovery/resume — that's a separate later task.

Key files: `Sources/DITIngest/Engine.swift`, `Sources/DITIngest/SetupView.swift` (SetupModel.go is
the run loop), `Sources/DITIngest/Notion.swift`, `Sources/DITIngest/AppDelegate.swift` (has `notify`).

## Context: how a dump is currently laid out
For each media type present, Stage 1 creates:
`<dumpLocation>/<project>/<mediaType>/<YYYY-MM-DD>/<cardName>/` (e.g. `…/video/2026-06-24/01_SonyA7IV/`)
containing the media (with subfolders preserved) plus a `dumped-<n>-files-<size>.txt` manifest.
Backups are OPTIONAL: 0, 1, or 2 locations (`backup1`, `backup2` in SetupModel; empty string = unset).

## Change A — Notion returns page IDs, and a comment-posting call
In `Notion.swift`:
1. Change `listProjects` to return both name AND Notion page id for each project. Suggested:
   define `struct Project { let name: String; let id: String }` and return `[Project]`
   (still sorted by name; still fall back to a single placeholder Project with empty id on failure).
   The page id is each result's top-level `id` field from the query response.
2. Add `static func postComment(token: String, pageID: String, text: String) -> Bool`.
   POST `https://api.notion.com/v1/comments` with headers Authorization `Bearer <token>`,
   `Notion-Version: 2022-06-28`, `Content-Type: application/json`, body:
   `{"parent":{"page_id":"<pageID>"},"rich_text":[{"text":{"content":"<text>"}}]}`.
   Return true on HTTP 200. Do it synchronously (semaphore) like listProjects does.

In `SetupView.swift` (SetupModel): the project list/picker currently uses `[String]` names. Keep the
picker working on names, but also keep a lookup from selected name -> page id (e.g. store the
`[Project]` and derive a `selectedProjectID`). If two projects share a name, last one wins (fine).

## Change B — Backups in Engine
Add to `Engine.swift`:
- `backUpAndVerify(ssdCardFolder: URL, to backupCardFolder: URL, progress:...) -> CopyResult`
  that copies every non-hidden file from `ssdCardFolder` (this INCLUDES the dumped manifest)
  into `backupCardFolder`, preserving layout, and verifies each by MD5 against the SSD copy.
  Reuse the existing `copyAndVerify(source:files:destFolder:)` (source = ssdCardFolder,
  files = all non-hidden files under it). Never overwrite; never touch the original card.
- A shared item-count helper so manifests match Finder: `finderItemCount(of folder: URL) -> Int`
  = (non-hidden files, recursive) + (non-hidden subfolders, recursive). Refactor the existing
  dumped-manifest counting to use it where sensible.
- `writeBackedUpManifest(in folder: URL, totalBytes: Int64) -> URL`: filename
  `backed-up-<count>-files-<size>.txt` where count = `finderItemCount(of: folder) + 1`
  (the +1 is this manifest itself, which isn't written yet). Body must include **that folder's own
  path** (so the SSD copy says the SSD path, each backup copy says its own path), plus the same
  size lines as the dumped manifest (human size + exact comma-grouped bytes).

## Change C — Wire Stage 2 into SetupModel.go
After Stage 1 finishes successfully for all media types (you currently have the SSD card folders),
for EACH dumped card folder:
1. Compute its path components relative to dumpLocation: `<project>/<mediaType>/<date>/<cardName>`.
2. For each NON-EMPTY backup location (backup1, backup2): backup dest =
   `<backupLocation>/<project>/<mediaType>/<date>/<cardName>`. Run `backUpAndVerify`.
   - If any backup fails verification: set an error message naming which location failed and that
     the SSD copy is safe / retry from SSD; stop (do not post Notion, do not write backed-up manifest
     for that card). Keep it simple — surface the failure clearly.
3. If ALL configured backups for that card verified: write the backed-up manifest into the SSD card
   folder AND each backup card folder (each with its own path). 
4. Notifications:
   - Keep the existing Stage-1 "dumped to SSD" notification.
   - If backups were configured and all succeeded, fire a 2nd notification:
     `"<cardName> backed up to all locations."`
5. Show backup progress + MB/s in the running view too (reuse the speedText/progress mechanism),
   with a label indicating it's backing up (e.g. progressText "Backing up <cardName> → <location>…").

Run backups on the existing background Task in `go()` (it already runs detached and retains self, so
it continues even if the window is closed). Update `finishedMessage` at the very end to reflect
whether backups ran (e.g. "… dumped and backed up to N location(s)." vs "… dumped to SSD.").

## Change D — Notion comment (fixes "no Notion feedback")
After the whole run for a card is done:
- If backups were configured & succeeded: post a Notion comment to the project page:
  `"<cardName> dumped and backed up. Files stored at <ssdCardFolderPath>/"`.
- If it was a dump-only run (no backups): still post a comment:
  `"<cardName> dumped. Files stored at <ssdCardFolderPath>/"`.
- Use `selectedProjectID`; skip silently if the id is empty (placeholder). Log success/failure to app.log.

## Done criteria
- Builds with `./build.sh install`, Stage 1 still works.
- A dump with 1–2 backup locations set actually copies & verifies to those locations, writes
  backed-up manifests (each with its own path), and fires the 2nd notification.
- A dump-only run (no backups) still posts a Notion comment.
- Notion comment appears on the selected project's page with the SSD path.
- Manifest counts still match Finder (files + subfolders + the manifest itself).
