# Task: Media Log Notion database — the reporting spine

App at `~/dit-ingest-app` (Swift package, macOS menu-bar app "DIT Media Ingest").
Build: `swift build`. Regression: `./.build/debug/DITIngest --selftest` must pass.
Add ONE new file `Sources/DITIngest/MediaLog.swift`. Touch `Config.swift` only to
add two fields (below). Do NOT change any other file.

## Purpose
A Notion database that logs every card dump as a row: where the footage lives
(dump + backups), what it is (camera, type, dates, size), and its transcription
status + transcript link. This becomes the studio's "where is my footage / is it
backed up / is it transcribed" lookup.

## Config additions (Config.swift)
Add these two stored properties (Config already has a tolerant `init(from:)` that
uses `decodeIfPresent` — ADD matching lines there too so they decode):
```swift
var mediaDB: String = ""            // Media Log database id, filled after first create
var mediaParentPage: String = ""    // page id the user shared; DB is created inside it
```
In `init(from:)` add:
```swift
mediaDB          = try c.decodeIfPresent(String.self, forKey: .mediaDB) ?? d.mediaDB
mediaParentPage  = try c.decodeIfPresent(String.self, forKey: .mediaParentPage) ?? d.mediaParentPage
```

## MediaLog.swift — a Notion client (mirror the sync style of NotionClient.swift:
DispatchSemaphore + URLSession, `Bearer <token>`, `Notion-Version: 2022-06-28`)

### Database schema (properties)
- **Card** (title) — e.g. "01_Pocket6K_26.07.21"
- **Project** (relation → Config.notionProjectsDB)
- **Camera** (rich_text)
- **Type** (select: Video / Stills / Audio)
- **Dates** (rich_text) — capture-date range string
- **Files** (number)
- **Size** (rich_text) — human size like "148 GB"
- **Dump Location** (rich_text) — SSD path
- **Backup 1** (rich_text) · **Backup 2** (rich_text) — paths ("" if none)
- **Transcription** (select: N/A / Pending / Done)
- **Transcript** (url) — link to the transcript doc (blank until done)
- **Dumped** (date) — today

### Functions
```swift
enum MediaLog {
    /// Returns a usable Media DB id, creating the database if needed.
    /// 1) If Config.mediaDB is set and still valid (GET succeeds) -> return it.
    /// 2) Else search for an existing database titled "Media Log" the
    ///    integration can see -> save its id to Config, return it.
    /// 3) Else, if Config.mediaParentPage is set -> POST /v1/databases with
    ///    parent {type:"page_id", page_id: mediaParentPage} and the schema
    ///    above -> save id to Config, return it.
    /// 4) Else return nil and Log.write a one-time instruction:
    ///    "Media Log: create a Notion page, share it with the integration, and
    ///     put its id in config (mediaParentPage) — then dumps will be logged."
    static func ensureDatabase(config: Config) -> String?

    /// Create or update the row for a card dump (idempotent by Card title:
    /// query the DB for an existing page with equal Card title; update it if
    /// found, else create). Returns the page id.
    @discardableResult
    static func upsertDump(card: String, projectPageId: String?, camera: String,
                           type: String, dates: String, files: Int, size: String,
                           dumpLocation: String, backup1: String, backup2: String,
                           config: Config) -> String?

    /// Update just the transcription status + transcript link for a card row.
    static func setTranscription(card: String, status: String, transcriptURL: String?,
                                 config: Config)
}
```

Notes:
- Creating a database: `POST https://api.notion.com/v1/databases` with
  `{ "parent": {"type":"page_id","page_id": <mediaParentPage>},
     "title":[{"type":"text","text":{"content":"Media Log"}}],
     "properties": { ...schema... } }`. Relation property shape:
  `{"relation":{"database_id": <projectsDB>, "single_property":{}}}`.
- Searching for the DB: `POST /v1/search` with
  `{"query":"Media Log","filter":{"value":"database","property":"object"}}`,
  match a result whose title text == "Media Log".
- Saving the created id back into Config: `var cfg = Config.load(); cfg.mediaDB = id; cfg.save()`.
- Be resilient: every network call behind a 15s semaphore timeout; on any
  failure Log.write a clear line and return nil/no-op (never crash a dump).

## CLI selftest hook (main.swift)
Add: `DITIngest --mediadb-test` → calls `MediaLog.ensureDatabase(config: .load())`,
prints the resulting db id (or the instruction), then if a db exists, calls
`upsertDump(card:"TEST_CARD_zz", ...dummy..., config:)` and prints the page id,
then exits. This lets us verify against real Notion without the GUI.

## Done criteria
- `swift build` clean; `--selftest` still passes.
- With `mediaParentPage` set in config, `--mediadb-test` creates the "Media Log"
  database (correct columns) and a TEST_CARD_zz row, printing both ids.
- Re-running `--mediadb-test` reuses the same DB and updates the same row (no dup).
- Do NOT wire it into the ingest/transcription flow — Claude will do that review
  step. Only build MediaLog.swift + the Config fields + the CLI hook.
