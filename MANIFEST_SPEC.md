# Task: 3 changes to DIT Media Ingest app (Swift menu-bar app)

App at `~/dit-ingest-app`. Build/install: `./build.sh install`.
Regression check after changes: `./.build/release/DITIngest --selftest` must still print ok=true.
Do NOT break Stage 1 or Stage 2. Files to touch: `Sources/DITIngest/Engine.swift`,
`Sources/DITIngest/SetupView.swift`, `Sources/DITIngest/SelfTest.swift`.

---

## Change 1 — Filter video thumbnail sidecars out of the Stills bucket

Sony (and other) cameras write a `.JPG` thumbnail file alongside every `.MP4` clip, sharing the
same base filename (`C0001.MP4` + `C0001.JPG` in the same directory). These thumbnails get
incorrectly sorted into the "stills" media bucket and end up in the Stills folder.

In `Engine.filesByType(in:)`, after building `result`, add a filter:

```swift
if let stills = result["stills"], let videos = result["video"] {
    let videoBasenames = Set(videos.map { $0.deletingPathExtension().lastPathComponent.lowercased() })
    let videoParentPaths = Set(videos.map { $0.deletingLastPathComponent().path })
    result["stills"] = stills.filter { stillURL in
        let base = stillURL.deletingPathExtension().lastPathComponent.lowercased()
        let parent = stillURL.deletingLastPathComponent().path
        return !(videoBasenames.contains(base) && videoParentPaths.contains(parent))
    }
    if result["stills"]?.isEmpty == true { result.removeValue(forKey: "stills") }
}
```

This only removes a still if it shares both a parent directory AND a base name with a video file —
so real mixed-media cards (different filenames) are unaffected.

---

## Change 2 — Move manifests to sit NEXT TO the card folder, named with the card folder name

**Current behavior:** manifests are written INSIDE the card folder, e.g.:
```
dateDir/
  01_SonyA7IV/
    DCIM/100MSDCF/
      C0001.MP4
    dumped-442-files-20gb.txt        ← inside card folder
```

**New behavior:** manifests sit next to the card folder (sibling), prefixed with the card folder name:
```
dateDir/
  01_SonyA7IV/
    DCIM/100MSDCF/
      C0001.MP4
  01_SonyA7IV-dumped-441-files-20gb.txt    ← NEXT TO card folder
```

### Engine.swift — `writeDumpedManifest`

Change the output path so the file is written to `destFolder.deletingLastPathComponent()` and
named `{destFolder.lastPathComponent}-dumped-{count}-files-{size}.txt`.

Count is now `finderItemCount(of: destFolder)` with NO +1 (the manifest is no longer inside the
folder, so it doesn't need to be pre-counted). Keep the rest of the body the same.

```swift
@discardableResult
static func writeDumpedManifest(in destFolder: URL, mediaFileCount: Int,
                                totalBytes: Int64) -> URL {
    let count = finderItemCount(of: destFolder)   // no +1
    let size = humanSize(totalBytes)
    let cardName = destFolder.lastPathComponent
    let name = "\(cardName)-dumped-\(count)-files-\(size).txt"
    let url = destFolder.deletingLastPathComponent().appendingPathComponent(name)  // NEXT TO folder

    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    let formattedBytes = formatter.string(from: NSNumber(value: totalBytes)) ?? "\(totalBytes)"

    let body = """
    Dumped to: \(destFolder.path)
    Media files: \(mediaFileCount)
    Total files: \(count)
    Total size: \(size)
    Total size: \(formattedBytes) bytes
    """
    try? body.write(to: url, atomically: true, encoding: .utf8)
    return url
}
```

### Engine.swift — `isComplete`

Since the dumped manifest is now a sibling of the card folder (not inside it), update `isComplete`
to look in the PARENT directory for a file matching `{dir.lastPathComponent}-dumped-*.txt`:

```swift
private static func isComplete(_ dir: URL) -> Bool {
    let parent = dir.deletingLastPathComponent()
    let baseName = dir.lastPathComponent
    let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
    return names.contains { $0.hasPrefix(baseName + "-dumped-") && $0.hasSuffix(".txt") }
}
```

---

## Change 3 — Single backup manifest: next to the backup card folder, includes dump location

**Current behavior:** after a successful backup, TWO backed-up manifests are written — one inside
the SSD card folder and one inside the backup card folder.

**New behavior:** write exactly ONE backed-up manifest, next to the backup card folder (sibling),
named `{cardFolderName}-backed-up-{count}-files-{size}.txt`. Its content includes the primary dump
path so you always know where the original lives. No file written into or next to the SSD folder.

### Engine.swift — `writeBackedUpManifest`

Add a `dumpFolder: URL` parameter. Write next to `folder` (not inside it). Count = `finderItemCount(of: folder)` with NO +1. Content includes the dump path.

```swift
@discardableResult
static func writeBackedUpManifest(in folder: URL, dumpFolder: URL, totalBytes: Int64) -> URL {
    let count = finderItemCount(of: folder)   // no +1
    let size = humanSize(totalBytes)
    let cardName = folder.lastPathComponent
    let name = "\(cardName)-backed-up-\(count)-files-\(size).txt"
    let url = folder.deletingLastPathComponent().appendingPathComponent(name)  // NEXT TO folder

    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    let formattedBytes = formatter.string(from: NSNumber(value: totalBytes)) ?? "\(totalBytes)"

    let body = """
    Backed up to: \(folder.path)
    Primary dump: \(dumpFolder.path)
    Total files: \(count)
    Total size: \(size)
    Total size: \(formattedBytes) bytes
    """
    try? body.write(to: url, atomically: true, encoding: .utf8)
    return url
}
```

### SetupView.swift — `go()`

Find the block that currently writes two backed-up manifests (around line 340):

```swift
// CURRENT (delete both of these):
let ssdManifest = Engine.writeBackedUpManifest(in: ssdFolder, totalBytes: totalBytes)
Log.write("backed-up manifest written -> \(ssdManifest.path)")
for destFolder in backupLocationsSucceeded {
    let backupManifest = Engine.writeBackedUpManifest(in: destFolder, totalBytes: totalBytes)
    Log.write("backed-up manifest written -> \(backupManifest.path)")
}
```

Replace with ONE write per backup location, passing `ssdFolder` as `dumpFolder`:

```swift
// NEW:
for destFolder in backupLocationsSucceeded {
    let backupManifest = Engine.writeBackedUpManifest(in: destFolder, dumpFolder: ssdFolder, totalBytes: totalBytes)
    Log.write("backed-up manifest written -> \(backupManifest.path)")
}
```

### SelfTest.swift

Update the `writeBackedUpManifest` calls to pass the `dumpFolder:` argument (the SSD card folder):

```swift
Engine.writeBackedUpManifest(in: dest, dumpFolder: cardFolder, totalBytes: r.totalBytes)
```

Remove the line that writes `writeBackedUpManifest` into the SSD card folder itself (if present):
```swift
Engine.writeBackedUpManifest(in: cardFolder, totalBytes: r.totalBytes)  // DELETE THIS LINE
```

---

## Done criteria

- `./build.sh install` compiles clean.
- `--selftest` passes: ok=true, manifest files appear NEXT TO card folders (not inside them), named
  `{cardName}-dumped-*.txt` and `{cardName}-backed-up-*.txt`. One backed-up manifest per backup
  location (not also in the SSD folder).
- A Sony card with `.MP4` + `.JPG` sidecars: only video goes in `Video/`, stills folder not created
  (or only contains real stills if the card also has distinct stills).
- File counts in manifests reflect actual media files + subfolders in the card folder only (no +1).
- `isComplete` correctly identifies completed card folders by checking for the sibling manifest.
