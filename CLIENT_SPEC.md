# Task: Client folder + pre-flight safety check

App at `~/dit-ingest-app`. Build: `./build.sh install`. Regression: `./.build/release/DITIngest --selftest`.
Touch: `Sources/DITIngest/Notion.swift`, `Sources/DITIngest/SetupView.swift`.

---

## Change 1 — Add client name to Project (Notion.swift)

### Struct change

```swift
struct Project {
    let name: String
    let id: String
    let clientName: String   // "" if no client relation exists
}
```

### In `listProjects`:

After building the project list, for each project page:
1. Look for a property of type `"relation"` named `"Client"` (case-insensitive key search is fine).
2. Extract the first related page's ID from the relation array:
   ```json
   "Client": { "type": "relation", "relation": [{"id": "some-page-id"}] }
   ```
3. Collect all unique client page IDs across all projects.
4. For each unique client ID, fetch the page title with a synchronous GET request:
   `GET https://api.notion.com/v1/pages/{page_id}`
   Same headers (Authorization, Notion-Version). Extract the title the same way
   `extractTitle` works (look for property of type "title", join plain_text).
5. Build a `[String: String]` map of `clientPageID → clientName`.
6. Assign `clientName` on each `Project` from the map (empty string if no relation or fetch fails).

Add a private helper:
```swift
private static func fetchPageTitle(token: String, pageID: String) -> String? {
    let url = URL(string: "https://api.notion.com/v1/pages/\(pageID)")!
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(version, forHTTPHeaderField: "Notion-Version")
    let sem = DispatchSemaphore(value: 0)
    var title: String? = nil
    URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        title = extractTitle(json)
    }.resume()
    _ = sem.wait(timeout: .now() + 15)
    return title
}
```

Deduplicate client page IDs before fetching — if 10 projects share one client, make only 1 API call.

---

## Change 2 — Use client name in folder path (SetupView.swift)

In `SetupModel.go()`, update the project root to include the client folder:

```swift
// CURRENT:
let projectRoot = URL(fileURLWithPath: dump).appendingPathComponent(project)

// NEW:
let clientName = /* look up from rawProjects / selectedProject */ ...
let dumpRoot = URL(fileURLWithPath: dump)
let projectRoot: URL
if !clientName.isEmpty {
    projectRoot = dumpRoot.appendingPathComponent(clientName).appendingPathComponent(project)
} else {
    projectRoot = dumpRoot.appendingPathComponent(project)  // fallback: no client folder
}
```

To get the client name in `go()`, derive it from `rawProjects` using the selected project name.
`SetupModel` already has `rawProjects: [Project]` (private). Add a computed property:

```swift
var selectedClientName: String {
    guard let name = selectedProject else { return "" }
    return rawProjects.last(where: { $0.name == name })?.clientName ?? ""
}
```

Then in the detached task, capture it:
```swift
let clientName = selectedClientName  // capture before detach
```

The backup `relPath` must also include the client:
```swift
// CURRENT:
let relPath = "\(project)/\(mediaType.capitalized)/\(cardName)"

// NEW:
let relPath = clientName.isEmpty
    ? "\(project)/\(mediaType.capitalized)/\(cardName)"
    : "\(clientName)/\(project)/\(mediaType.capitalized)/\(cardName)"
```

---

## Change 3 — Pre-flight safety check (SetupView.swift)

**Before starting any copy**, check that the destination card folder does not already exist.
This runs after camera detection and card naming, but BEFORE `Engine.copyAndVerify`.

In `go()`, inside the `for (mediaType, files) in byType` loop, immediately after computing
`cardFolder`, add:

```swift
// Safety: abort if destination already exists and is non-empty
if FileManager.default.fileExists(atPath: cardFolder.path) {
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: cardFolder.path)) ?? []
    if !contents.isEmpty {
        Log.write("pre-flight ABORT: destination already exists -> \(cardFolder.path) (\(contents.count) items)")
        await MainActor.run {
            self.errorMessage = "⚠️ Destination already exists and is not empty:\n\(cardFolder.path)\n\nAborting to protect existing data. Move or rename that folder before retrying."
            self.appDelegate?.setMenuBarTitle("")
            self.appDelegate?.setStatus("Idle")
            self.isRunning = false
        }
        return
    }
}
```

This check runs per media type. If the Stills destination is clean but Video conflicts,
it aborts on the Video check before copying any Video files.

**Important:** this check is for the CARD FOLDER specifically (e.g., `01_SonyA7IV_26.06.30/`),
not the client or project folder. Creating a new subfolder inside an existing client/project
folder is safe and expected. Only a collision on the final card folder warrants an abort.

---

## Done criteria

- `./build.sh install` compiles clean.
- `--selftest` passes (selftest has no Notion; clientName will be "" → path unchanged, still correct).
- On a real run, the path is `<dump>/<clientName>/<projectName>/Video/01_SonyA7IV_26.06.30/`.
- If no client relation exists on a project, falls back gracefully to `<dump>/<projectName>/...`.
- If the destination card folder already exists and is non-empty, the run aborts immediately
  with a clear error message before copying any files.
- Log records the pre-flight abort with the conflicting path.
