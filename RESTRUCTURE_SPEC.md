# Task: Folder structure + audio device detection

App at `~/dit-ingest-app`. Build: `./build.sh install`. Regression: `./.build/release/DITIngest --selftest`.
Touch: `Sources/DITIngest/Engine.swift`, `Sources/DITIngest/SetupView.swift`, `Sources/DITIngest/SelfTest.swift`.

---

## Change 1 — New card folder name: `01_SonyA7IV_26.06.26`

Currently `nextCardFolderName(in: dateDir, camera:)` returns `01_SonyA7IV`.
The date lives in a parent folder (`2026-06-24/`).

New format: embed the date in the card folder name using `yy.mm.dd` (two-digit year, dot-separated).
Remove the date folder level entirely. The date string is passed in from the caller.

New signature:
```swift
static func nextCardFolderName(in parentDir: URL, camera: String, date: String) -> String
```

Where `date` is `yy.mm.dd` (e.g. `"26.06.26"`). The folder name becomes `01_SonyA7IV_26.06.26`.
The retry letter stays the same: `02B_SonyA7IV_26.06.26`.

`isComplete` checks the PARENT directory for a sibling file starting with
`{dir.lastPathComponent}-DUMP-` — this is already correct from the prior change.

### In SetupView.swift `go()`:

Change `dumpDateString()` to return `yy.mm.dd` format (two-digit year):
```swift
f.dateFormat = "yy.MM.dd"
```

Remove the `dateStr` folder level. Currently:
```swift
let dateDir = projectRoot.appendingPathComponent(mediaType.capitalized)
    .appendingPathComponent(dateStr)
```

New (no date subfolder):
```swift
let typeDir = projectRoot.appendingPathComponent(mediaType.capitalized)
```

Pass `dateStr` into `nextCardFolderName`:
```swift
let cardName = Engine.nextCardFolderName(in: typeDir, camera: cam, date: dateStr)
let cardFolder = typeDir.appendingPathComponent(cardName)
```

Update `relPath` accordingly (no date component):
```swift
let relPath = "\(project)/\(mediaType.capitalized)/\(cardName)"
```

### In SelfTest.swift:

Update the `dateStr` to `yy.mm.dd` format and remove the date path component:
```swift
let dateStr = "26.06.24"
// ...
let rel = "TestProject/\(mediaType.capitalized)"
// ...
let cardName = Engine.nextCardFolderName(in: dateDir, camera: "Sony A7IV", date: dateStr)
```

---

## Change 2 — Flatten internal card structure (no DCIM subfolders)

Currently `copyAndVerify` preserves the full relative path from the card root
(e.g., `DCIM/100MSDCF/C0001.MP4`), recreating the DCIM folder hierarchy inside the card folder.

New behavior: copy all files FLAT into `destFolder` — just `C0001.MP4` directly inside the card folder.
No subdirectory structure from the source is preserved.

In `copyAndVerify`, change:
```swift
let rel = relativePath(of: srcFile, under: source)
let dstFile = destFolder.appendingPathComponent(rel)
try? fm.createDirectory(at: dstFile.deletingLastPathComponent(), withIntermediateDirectories: true)
```

To:
```swift
let dstFile = destFolder.appendingPathComponent(srcFile.lastPathComponent)
```

The `relativePath(of:under:)` helper can stay (it's used internally), but is no longer called from `copyAndVerify`.

Note: `backUpAndVerify` calls `copyAndVerify` too, so backup copies will also be flat — correct.

The `finderItemCount` function counts items in the card folder. With flat layout it will be just the
media files (no subfolders), so counts will be simpler and accurate.

---

## Change 3 — Audio device detection

`detectCamera(in:)` currently only looks for video/camera models.
Rename it `detectDevice(in:)` and add audio recorder mappings.

### New entries in `cameraNameMap`:
```swift
// Audio recorders — matched against BWF Originator, Model, Make, Product tags
"Wireless PRO":                      "Rode Wireless PRO",
"RodeWireless PRO":                  "Rode Wireless PRO",
"DJI Mic 2":                         "DJI Mic 2",
"DJI Pro 2":                         "DJI Mic 2",
"H4n":                               "Zoom H4n",
"H4n Pro":                           "Zoom H4n Pro",
"H5":                                "Zoom H5",
"H6":                                "Zoom H6",
"H8":                                "Zoom H8",
"DR-40":                             "Tascam DR-40",
"DR-40X":                            "Tascam DR-40X",
"DR-60D":                            "Tascam DR-60D",
"DR-100mkIII":                       "Tascam DR-100",
"TASCAM DR-40":                      "Tascam DR-40",
"TASCAM DR-60D":                     "Tascam DR-60D",
```

### Additional exiftool tags for audio files (add to the `-json` call args):
```
"-Originator",       // BWF header — most recorders write device name here
"-OriginatorReference",
"-Make",
"-Product",
```

### Tag search order in the results (add to `keys` array):
```swift
let keys = ["Model", "CameraModelName", "UniqueCameraModel", "DeviceModelName",
            "Originator", "Make", "Product"]
```

### Rename:
- `detectCamera(in:)` → `detectDevice(in:)` everywhere (Engine.swift + SetupView.swift)

---

## Done criteria

- `--selftest` passes: card folder name is `01_SonyA7IV_26.06.24`, files are flat inside
  (no DCIM subdirs), DUMP/BU manifests sit as siblings with correct counts.
- Resulting tree looks like:
  ```
  SSD/TestProject/Video/
    01_SonyA7IV_26.06.24/
      C0001.MP4
      C0002.MP4
      C0003.MP4
      C0004.MP4
    01_SonyA7IV_26.06.24-DUMP-4-files-4mb.txt
  NAS/TestProject/Video/
    01_SonyA7IV_26.06.24/
      C0001.MP4  (etc.)
    01_SonyA7IV_26.06.24-BU-4-files-4mb.txt
  ```
- `./build.sh install` succeeds.
- No date subfolder in any path.
- `detectDevice` is called in SetupView where `detectCamera` was.
