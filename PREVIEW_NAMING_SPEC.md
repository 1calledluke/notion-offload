# Task: card thumbnails in ingest window + project folder naming

App at `~/dit-ingest-app`. Build: `./build.sh install`.
Regression: `swift build && ./.build/debug/DITIngest --selftest` must pass (it contains asserts — run the DEBUG binary).
Touch ONLY: `Sources/DITIngest/Notion.swift`, `Sources/DITIngest/SetupView.swift`, `Sources/DITIngest/SelfTest.swift`.
Do NOT change Engine.swift, ResumeDetector.swift, AppDelegate.swift.

---

## Change 1 — Project folder named `yy.mm_ProjectName_JobCode`

### 1a. Notion.swift — pull the "Job Code" property

The projects database has a formula property named **"Job Code"** (a zero-padded string
like "0042"). Add it to the Project struct:

```swift
struct Project {
    let name: String
    let id: String
    let clientName: String
    let jobCode: String    // "" if missing
}
```

In `listProjects` parsing, for each page extract it from `properties["Job Code"]`:
```json
"Job Code": { "type": "formula", "formula": { "type": "string", "string": "0042" } }
```
Handle both `"string"` and `"number"` formula results (format number with no decimals).
Add a helper `extractJobCode(_ page:)` similar to the existing extractors. Empty string on any miss.
Update the `placeholder` constant and the `Project(...)` constructions for the new field.

### 1b. SetupView.swift — use it in the folder name

`SetupModel` gets:
```swift
var selectedJobCode: String {
    guard let name = selectedProject else { return "" }
    return rawProjects.last(where: { $0.name == name })?.jobCode ?? ""
}
```

In `go()`, capture `let jobCode = selectedJobCode` next to the other captures (before Task.detached).

Inside the task, the project FOLDER name changes (dateStr is "yy.MM.dd"; use its first 5 chars "yy.MM"):
```swift
let yymm = String(dateStr.prefix(5))                     // "26.07"
let projectFolderName = jobCode.isEmpty
    ? "\(yymm)_\(project)"
    : "\(yymm)_\(project)_\(jobCode)"                    // "26.07_Equip Videos_0042"
```

Use `projectFolderName` in BOTH places that currently use `project` as a path component:
- `projectRoot = dumpRoot.appendingPathComponent(clientName).appendingPathComponent(projectFolderName)`
  (and the no-client fallback)
- `relPath = "\(clientName)/\(projectFolderName)/\(mediaType.capitalized)/\(cardName)"`
  (and its no-client variant)

The Notion comment text and UI messages keep using the plain `project` name.

---

## Change 2 — Card preview thumbnails in the ingest window

Goal: before clicking Begin Ingest, the user sees WHAT is on the card so they never
dump the wrong one.

### Model (SetupModel)

```swift
struct CardThumb: Identifiable {
    let id = UUID()
    let image: NSImage?     // nil -> show placeholder icon
    let filename: String
}
@Published var cardThumbs: [CardThumb] = []
@Published var cardSummary: String = ""   // e.g. "3 videos • 44.4 GB • Jul 3–10"
```

In the normal `init(sourceURL:...)` (NOT the resume init), after `refreshProjects()`, call a new
`loadCardPreview()` method that does everything in a `Task.detached` and publishes on MainActor.

### loadCardPreview() logic

1. `let byType = Engine.filesByType(in: source)` — reuse the engine's classification.
2. Summary: count per type + total bytes (use `Engine.humanSize`) + modification-date range of
   the media files (`.contentModificationDateKey`), formatted like "Jul 3–10" or single date.
   Example: `"3 videos, 12 stills • 44.4 GB • Jul 3–10"`.
3. Thumbnails: take up to **8** files, interleaving types (videos first, then stills, then audio).
   For each, generate a small image entirely OFF the main thread:
   - **Stills** (jpg/jpeg/png/heic/tif/tiff — skip raw formats arw/dng/cr2/nef unless
     CGImageSource handles them, which it usually does on macOS): use CGImageSource:
     ```swift
     let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                  kCGImageSourceThumbnailMaxPixelSize: 320,
                                  kCGImageSourceCreateThumbnailWithTransform: true]
     if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
         image = NSImage(cgImage: cg, size: .zero)
     }
     ```
   - **Video** (mp4/mov/m4v/mts/m2ts/avi/mxf): AVFoundation (`import AVFoundation`):
     ```swift
     let asset = AVURLAsset(url: url)
     let gen = AVAssetImageGenerator(asset: asset)
     gen.appliesPreferredTrackTransform = true
     gen.maximumSize = CGSize(width: 320, height: 320)
     let cg = try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
     ```
   - **BRAW** (.braw — AVFoundation canNOT decode it): look for a proxy on the card:
     a file named `<same basename>.mp4` or `.mov` under any folder named "Proxy"
     (case-insensitive). If found, generate the video thumbnail from the proxy instead.
     If not, `image = nil` (placeholder).
   - **Audio**: `image = nil` (placeholder).
4. Publish results to `cardThumbs` / `cardSummary` on the MainActor as they're ready
   (publishing once at the end is fine too).
5. Everything failure-tolerant: card may eject mid-scan — any error just yields a nil image
   or empty state, never a crash.

### View (formView)

Add a "CARD PREVIEW" section between the header and PROJECT sections (same section-header
style as PROJECT/DESTINATIONS: caption2, secondary, uppercase):

- If `cardSummary` non-empty, show it in `.callout` `.secondary`.
- Horizontal `ScrollView` of `cardThumbs`: each is a VStack of the image (72pt tall,
  `.aspectRatio(contentMode: .fill)`, clipped, 6pt corner radius) over the filename
  (`.caption2`, `.secondary`, lineLimit 1, max width ~96).
  For nil images show a RoundedRectangle `.fill(.quaternary)` 96×72 with an SF Symbol
  overlay: "video" for video files, "waveform" for audio, "photo" otherwise.
- While `cardThumbs` is empty AND `cardSummary` is empty, show a small
  `ProgressView().controlSize(.small)` with "Reading card…" caption.
- The window is 600 tall; if vertical space gets tight, reduce the project List height
  from 150 to 120.

---

## Change 3 — SelfTest additions

In SelfTest, after `filesByType`, add:
```swift
// Naming: yy.mm project folder format
let jobFolderName = "26.07" + "_TestProject_" + "0042"
assert(jobFolderName == "26.07_TestProject_0042", "sanity")
```
(Thumbnails are UI/AVFoundation — not selftested. Do not add AVFoundation to SelfTest.)

Do not break the existing asserts (video count 7, Proxy preservation, C0001_2.MP4, ResumeDetector cases).

---

## Done criteria

- `swift build` clean; DEBUG `--selftest` passes all asserts.
- Project list still loads; picking a project + dumping creates
  `<dump>/<Client>/26.07_<Project>_<JobCode>/Video/01_..._26.07.10/` and backups mirror it.
- Projects with no Job Code fall back to `26.07_<Project>`.
- Ingest window shows a thumbnail strip + summary for the inserted card before Go is pressed;
  BRAW cards show proxy-derived thumbs when a Proxy folder exists.
- `./build.sh install` succeeds.
