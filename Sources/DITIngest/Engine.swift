import Foundation
import CryptoKit
import AppKit

/// The ingest engine: scanning a card, detecting camera + media types, naming
/// the card folder, and copying with checksum verification. Nothing here ever
/// deletes or overwrites existing media.
enum Engine {

    // MARK: - Media types

    static let videoExts: Set<String> = ["mp4", "mov", "mxf", "avi", "m4v", "braw", "mts", "m2ts"]
    static let stillsExts: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "arw", "dng", "raw", "heic", "cr2", "nef"]
    static let audioExts: Set<String> = ["wav", "aif", "aiff", "mp3", "flac", "m4a"]

    /// All real files on the card (skips hidden/system files).
    static func mediaFiles(in source: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { out.append(url) }
        }
        return out
    }

    static func type(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if videoExts.contains(ext) { return "video" }
        if stillsExts.contains(ext) { return "stills" }
        if audioExts.contains(ext) { return "audio" }
        return nil
    }

    /// Which media types are present, mapped to the files of each type.
    /// Strips video thumbnail sidecars (same base name + directory as a video file).
    /// XML metadata sidecars (e.g. Sony C0001M01.XML) ride along with their clip's bucket.
    static func filesByType(in source: URL) -> [String: [URL]] {
        var result: [String: [URL]] = [:]
        var xmlFiles: [URL] = []
        for file in mediaFiles(in: source) {
            if file.pathExtension.lowercased() == "xml" { xmlFiles.append(file) }
            else if let t = type(of: file) { result[t, default: []].append(file) }
        }
        if let stills = result["stills"], let videos = result["video"] {
            let videoBasenames = Set(videos.map { $0.deletingPathExtension().lastPathComponent.lowercased() })
            let videoParentPaths = Set(videos.map { $0.deletingLastPathComponent().path })
            result["stills"] = stills.filter { stillURL in
                let base = stillURL.deletingPathExtension().lastPathComponent.lowercased()
                let parent = stillURL.deletingLastPathComponent().path
                // Exact-name sidecar next to the video (C0001.JPG beside C0001.MP4).
                if videoBasenames.contains(base) && videoParentPaths.contains(parent) { return false }
                // Dedicated thumbnail folders in Sony/Panasonic card layouts.
                if stillURL.path.lowercased().contains("/thmbnl/") { return false }
                // Sony-style thumbnail names: C0001T01.JPG belongs to clip C0001
                // (may live in a different folder than the clip itself).
                for vb in videoBasenames where base.hasPrefix(vb) && base.count > vb.count {
                    let suffix = base.dropFirst(vb.count)
                    if let first = suffix.first, first == "t" || first == "m" {
                        let digits = suffix.dropFirst()
                        if !digits.isEmpty && digits.allSatisfy({ $0.isNumber }) { return false }
                    }
                }
                return true
            }
            if result["stills"]?.isEmpty == true { result.removeValue(forKey: "stills") }
        }

        // Attach XML sidecars to the bucket whose media file they describe.
        // Sony names them {clipBase}M01.XML (C0001M01.XML for C0001.MP4); also
        // accept an exact base-name match. Unmatched XMLs are left behind.
        if !xmlFiles.isEmpty {
            var basenamesByType: [String: Set<String>] = [:]
            for (t, files) in result {
                basenamesByType[t] = Set(files.map { $0.deletingPathExtension().lastPathComponent.lowercased() })
            }
            for xml in xmlFiles {
                let base = xml.deletingPathExtension().lastPathComponent.lowercased()
                var stripped = base
                // Strip a trailing M01/T01-style suffix to find the owning clip.
                let trailingDigits = base.reversed().prefix(while: { $0.isNumber }).count
                if trailingDigits > 0, base.count > trailingDigits + 1 {
                    let cut = base.index(base.endIndex, offsetBy: -(trailingDigits + 1))
                    if base[cut] == "m" || base[cut] == "t" { stripped = String(base[..<cut]) }
                }
                for (t, basenames) in basenamesByType {
                    if basenames.contains(base) || basenames.contains(stripped) {
                        result[t]?.append(xml)
                        break
                    }
                }
            }
        }
        return result
    }

    // MARK: - Camera detection

    static let cameraNameMap: [String: String] = [
        "ILCE-7M4": "Sony A7IV",
        "Blackmagic Pocket Cinema Camera 6K": "Pocket 6K",
        "Blackmagic Pocket Cinema Camera 6K G2": "Pocket 6K",
        "Blackmagic Pocket Cinema Camera 6K Pro": "Pocket 6K",
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
    ]

    /// Reads camera model with exiftool. Returns a friendly name, or nil if
    /// nothing usable was found (caller then asks the user).
    static func detectDevice(in source: URL) -> String? {
        let files = Array(mediaFiles(in: source).prefix(25))
        if files.isEmpty { return nil }

        guard let exiftool = exiftoolPath() else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exiftool)
        proc.arguments = ["-json", "-Model", "-CameraModelName",
                          "-DeviceModelName", "-UniqueCameraModel",
                          "-Originator", "-OriginatorReference",
                          "-Make", "-Product"]
            + files.map { $0.path }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let keys = ["Model", "CameraModelName", "UniqueCameraModel", "DeviceModelName",
                    "Originator", "Make", "Product"]
        for entry in entries {
            for key in keys {
                if let raw = entry[key] as? String, !raw.isEmpty {
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    return cameraNameMap[trimmed] ?? sanitize(trimmed)
                }
            }
        }
        return nil
    }

    private static func exiftoolPath() -> String? {
        for path in ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func sanitize(_ name: String) -> String {
        let bad = Set("/\\:*?\"<>|")
        let cleaned = String(name.filter { !bad.contains($0) }).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Unknown Camera" : cleaned
    }

    // MARK: - Card folder naming

    /// A card folder counts as finished only if a sibling "DUMP-" manifest exists next to it.
    private static func isComplete(_ dir: URL) -> Bool {
        let parent = dir.deletingLastPathComponent()
        let baseName = dir.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.contains { $0.hasPrefix(baseName + "-DUMP-") && $0.hasSuffix(".txt") }
    }

    /// Helper to extract the base number of a card folder under the new format.
    /// E.g., "01_SonyA7IV" -> 1, "02B_SonyA7IV" -> 2.
    /// Returns nil if it doesn't match the format.
    static func parseCardNumber(from folderName: String) -> Int? {
        let parts = folderName.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let prefix = String(parts[0])
        // The prefix should be like "01" or "02B". Let's get the leading digits.
        let digits = prefix.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// Next number after the last COMPLETED card; if that folder already exists
    /// as a leftover failed partial, append a letter -> "02B_SonyA7IV".
    static func nextCardFolderName(in parentDir: URL, camera: String, date: String) -> String {
        let fm = FileManager.default
        let allDirs = ((try? fm.contentsOfDirectory(at: parentDir,
            includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let existing = Set(allDirs.map { $0.lastPathComponent })

        var completedCardNumbers: [Int] = []
        for dir in allDirs {
            if let num = parseCardNumber(from: dir.lastPathComponent), isComplete(dir) {
                completedCardNumbers.append(num)
            }
        }

        let nextNum: Int
        if completedCardNumbers.isEmpty {
            nextNum = 1
        } else {
            nextNum = (completedCardNumbers.max() ?? 0) + 1
        }

        let cleanCamera = camera.filter { $0 != " " }
        let formattedNumber = String(format: "%02d", nextNum)
        let base = "\(formattedNumber)_\(cleanCamera)_\(date)"

        if existing.contains(base) {
            for letter in "BCDEFGHIJKLMNOPQRSTUVWXYZ" {
                let candidate = "\(formattedNumber)\(letter)_\(cleanCamera)_\(date)"
                if !existing.contains(candidate) { return candidate }
            }
        }
        return base
    }

    // MARK: - Copy + verify

    struct CopyResult {
        var ok: Bool
        var fileCount: Int
        var totalBytes: Int64
        var failures: [String]
    }

    /// Copy `files` (each under `source`) flat into `destFolder`, then verify
    /// each with an MD5 comparison of source vs destination.
    /// Progress: (fileIndex, fileCount, fileName, bytesDone, bytesGrandTotal).
    ///
    /// `healMismatched`: when a destination file already exists but its MD5
    /// doesn't match the source, replace it (delete + re-copy) rather than
    /// failing. Use TRUE for backups/resumes — the source is verified truth and
    /// a wrong file in the mirror is stale/partial and must be corrected. Use
    /// FALSE for the card→SSD dump, where an existing mismatched file is an
    /// unexpected collision we'd rather surface than silently overwrite.
    static func copyAndVerify(source: URL, files: [URL], destFolder: URL,
                               healMismatched: Bool = false,
                               progress: ((Int, Int, String, Int64, Int64) -> Void)? = nil) -> CopyResult {
        let fm = FileManager.default
        try? fm.createDirectory(at: destFolder, withIntermediateDirectories: true)

        // Total bytes up front so callers can show byte-accurate progress.
        let grandTotal = files.reduce(Int64(0)) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }

        var totalBytes: Int64 = 0
        var totalBytesCopied: Int64 = 0
        var failures: [String] = []
        var copied = 0
        // Flattening the card layout can collide names (Sony rolls over DCIM
        // folders: 100MSDCF/DSC00001.JPG and 101MSDCF/DSC00001.JPG). Track the
        // names used this run and disambiguate instead of failing.
        var usedNames: Set<String> = []

        for (i, srcFile) in files.enumerated() {
            var rel = flattenedRelPath(of: srcFile, under: source)
            if usedNames.contains(rel) {
                let dir = (rel as NSString).deletingLastPathComponent
                let name = (rel as NSString).lastPathComponent
                let base = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                var n = 2
                func candidate(_ n: Int) -> String {
                    let newName = ext.isEmpty ? "\(base)_\(n)" : "\(base)_\(n).\(ext)"
                    return dir.isEmpty ? newName : "\(dir)/\(newName)"
                }
                while usedNames.contains(candidate(n)) { n += 1 }
                rel = candidate(n)
            }
            usedNames.insert(rel)
            let dstFile = destFolder.appendingPathComponent(rel)
            if rel.contains("/") {
                let parentDir = dstFile.deletingLastPathComponent()
                do {
                    try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                } catch {
                    let msg = "\(rel) — can't create subfolder '\(parentDir.lastPathComponent)': \(error.localizedDescription)"
                    Log.write("mkdir FAILED -> \(parentDir.path): \(error.localizedDescription)")
                    failures.append(msg)
                    continue
                }
            }

            progress?(i + 1, files.count, rel, totalBytesCopied, grandTotal)

            let size = (try? srcFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

            if fm.fileExists(atPath: dstFile.path) {
                // File already exists — verify MD5 matches (resume-safe).
                if md5(of: srcFile) == md5(of: dstFile) {
                    copied += 1
                    totalBytes += Int64(size)
                    totalBytesCopied += Int64(size)
                    progress?(i + 1, files.count, rel, totalBytesCopied, grandTotal)
                    continue
                } else if healMismatched {
                    // Backup/resume: destination file is stale or partial (e.g.
                    // left by an interrupted run). Replace it from the source.
                    Log.write("healing mismatched file -> \(rel)")
                    try? fm.removeItem(at: dstFile)
                    // fall through to the copy below
                } else {
                    Log.write("verify FAILED -> \(rel): existing destination file doesn't match source")
                    failures.append("\(rel) — existing file at destination doesn't match source")
                    progress?(i + 1, files.count, rel, totalBytesCopied, grandTotal)
                    continue
                }
            }

            // Stream the file data ourselves instead of FileManager.copyItem:
            // some camera cards (seen on Blackmagic exFAT) carry corrupt extended
            // attributes that make copyItem abort instantly with ENOATTR. We only
            // care about the data — and hashing the source while copying saves a
            // full read pass on multi-GB clips.
            let baseBytes = totalBytesCopied
            let copyResult = streamCopy(from: srcFile, to: dstFile, onProgress: { written in
                progress?(i + 1, files.count, rel, baseBytes + written, grandTotal)
            })
            guard let srcHash = copyResult.md5 else {
                let reason = copyResult.failReason ?? "unknown error"
                Log.write("copy FAILED -> \(rel): \(reason)")
                failures.append("\(rel) — \(reason)")
                progress?(i + 1, files.count, rel, totalBytesCopied, grandTotal)
                continue
            }

            totalBytes += Int64(size)

            if let dstHash = md5(of: dstFile), dstHash == srcHash {
                copied += 1
                totalBytesCopied += Int64(size)
            } else {
                Log.write("verify FAILED -> \(rel): checksum mismatch after copy")
                failures.append("\(rel) — checksum mismatch after copy")
            }

            progress?(i + 1, files.count, rel, totalBytesCopied, grandTotal)
        }

        return CopyResult(ok: failures.isEmpty, fileCount: copied,
                          totalBytes: totalBytes, failures: failures)
    }

    // MARK: - Selective copy

    /// The files the user actually chooses between in the browser: real media
    /// only. Proxy copies and XML sidecars are deliberately absent — they aren't
    /// independent choices, they ride along with the clip they belong to.
    static func primaryMediaFiles(in source: URL) -> [URL] {
        let byType = filesByType(in: source)
        var out: [URL] = []
        for key in ["video", "stills", "audio"] {
            let files = (byType[key] ?? []).filter {
                $0.pathExtension.lowercased() != "xml"
                    && !$0.path.lowercased().contains("/proxy/")
            }
            out.append(contentsOf: files.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            })
        }
        return out
    }

    /// Narrows `byType` to the chosen clips plus their ride-alongs: the proxy
    /// copy and the XML sidecar belonging to each chosen clip travel with it, so
    /// picking C0002.braw also brings Proxy/C0002.mp4 and C0002M01.XML.
    static func filterSelection(_ byType: [String: [URL]], chosen: Set<URL>) -> [String: [URL]] {
        guard !chosen.isEmpty else { return [:] }
        let bases = Set(chosen.map { $0.deletingPathExtension().lastPathComponent.lowercased() })

        func belongs(_ f: URL) -> Bool {
            if chosen.contains(f) { return true }
            let b = f.deletingPathExtension().lastPathComponent.lowercased()
            if bases.contains(b) { return true }   // proxy copy / exact-name sidecar
            // Sony-style suffixes: C0001M01.XML and C0001T01.JPG belong to C0001.
            for base in bases where b.hasPrefix(base) && b.count > base.count {
                let suffix = b.dropFirst(base.count)
                guard let first = suffix.first, first == "m" || first == "t" else { continue }
                let digits = suffix.dropFirst()
                if !digits.isEmpty && digits.allSatisfy({ $0.isNumber }) { return true }
            }
            return false
        }

        return byType.mapValues { $0.filter(belongs) }.filter { !$0.value.isEmpty }
    }

    // MARK: - BRAW Finder icons

    /// Stamps each .braw file's first frame onto the file as its Finder icon,
    /// giving Finder previews that macOS can't provide natively (it dropped
    /// legacy Quick Look plugins and Blackmagic hasn't shipped a modern one).
    /// The icon lives in the resource fork / FinderInfo xattrs — the footage
    /// data is untouched, so MD5 receipts stay valid. Best-effort: requires the
    /// bundled `brawthumb` tool and an installed Blackmagic RAW library.
    static func stampBrawIcons(in folder: URL) {
        let fm = FileManager.default
        let braws = mediaFiles(in: folder).filter { $0.pathExtension.lowercased() == "braw" }
        guard !braws.isEmpty else { return }
        guard let tool = Bundle.main.path(forResource: "brawthumb", ofType: nil),
              fm.isExecutableFile(atPath: tool) else {
            Log.write("braw icons skipped -> brawthumb tool not bundled")
            return
        }

        var stamped = 0
        for braw in braws {
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? fm.removeItem(at: tmp) }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tool)
            proc.arguments = [braw.path, tmp.path, "512"]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do { try proc.run() } catch { continue }
            proc.waitUntilExit()

            guard proc.terminationStatus == 0, let img = NSImage(contentsOf: tmp) else { continue }
            let path = braw.path
            DispatchQueue.main.async {
                NSWorkspace.shared.setIcon(img, forFile: path)
            }
            stamped += 1
        }
        Log.write("braw icons stamped -> \(folder.path) (\(stamped)/\(braws.count) clips)")
    }

    /// Flattening rule: everything copies flat into the card folder EXCEPT
    /// anything under a "Proxy" folder — that level is preserved (Blackmagic
    /// writes proxies beside the originals with the SAME file names; editors
    /// need `Proxy/<name>` intact to auto-attach them).
    private static func flattenedRelPath(of srcFile: URL, under source: URL) -> String {
        let baseCount = source.standardizedFileURL.pathComponents.count
        let relComps = Array(srcFile.standardizedFileURL.pathComponents.dropFirst(baseCount))
        if let idx = relComps.lastIndex(where: { $0.lowercased() == "proxy" }),
           idx < relComps.count - 1 {
            return relComps[idx...].joined(separator: "/")
        }
        return srcFile.lastPathComponent
    }

    /// Copies file DATA only, in 8MB chunks, hashing the source as it goes.
    /// Returns the source's MD5, or nil on any read/write failure (partial
    /// destination is removed). Deliberately skips extended attributes —
    /// corrupt xattrs on camera cards break FileManager.copyItem (ENOATTR),
    /// and camera metadata lives inside the media files anyway. The original
    /// creation/modification dates are preserved on the copy.
    static func streamCopy(from src: URL, to dst: URL,
                           onProgress: ((Int64) -> Void)? = nil) -> (md5: String?, failReason: String?) {
        let fm = FileManager.default
        // Write to a temporary sibling and rename into place only on success.
        // On a crash/kill mid-write, a discardable ".partial" is the worst that
        // survives — the real filename never appears half-written, and rename is
        // the sole metadata mutation on it. Critical on non-journaled ExFAT/NTFS
        // backup drives, where an interrupted direct write corrupts the volume.
        let tmp = dst.deletingLastPathComponent()
            .appendingPathComponent("." + dst.lastPathComponent + ".partial")
        try? fm.removeItem(at: tmp)   // clear any leftover from a prior crash

        guard let input = try? FileHandle(forReadingFrom: src) else {
            return (nil, "can't open source for reading")
        }
        defer { try? input.close() }
        // Ensure the parent directory exists — callers should have pre-created it,
        // but network/ExFAT volumes can silently drop createDirectory; retry here.
        let parentDir = tmp.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            do {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            } catch {
                return (nil, "can't create parent folder '\(parentDir.lastPathComponent)': \(error.localizedDescription)")
            }
        }
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            return (nil, "can't create destination file in '\(parentDir.lastPathComponent)' (permission denied?)")
        }
        guard let output = try? FileHandle(forWritingTo: tmp) else {
            return (nil, "can't open destination for writing")
        }

        var hasher = Insecure.MD5()
        var written: Int64 = 0
        var chunkCount = 0
        var failReason: String? = nil
        var finished = false

        while !finished && failReason == nil {
            autoreleasepool {
                var chunk: Data
                do {
                    guard let c = try input.read(upToCount: 8 * 1024 * 1024), !c.isEmpty else {
                        finished = true
                        return
                    }
                    chunk = c
                } catch {
                    failReason = "read error: \(error.localizedDescription)"
                    return
                }
                hasher.update(data: chunk)
                do {
                    try output.write(contentsOf: chunk)
                } catch {
                    failReason = "write error: \(error.localizedDescription)"
                    return
                }
                written += Int64(chunk.count)
                chunkCount += 1
                // Report every ~128MB so huge clips show live progress
                // without flooding the UI.
                if chunkCount % 16 == 0 { onProgress?(written) }
            }
        }
        // Flush to the physical device before we trust the rename.
        try? output.synchronize()
        try? output.close()

        if let reason = failReason {
            try? fm.removeItem(at: tmp)   // never leave a partial file behind
            return (nil, reason)
        }

        // Keep the original capture dates on the copy.
        if let attrs = try? fm.attributesOfItem(atPath: src.path) {
            var keep: [FileAttributeKey: Any] = [:]
            if let m = attrs[.modificationDate] { keep[.modificationDate] = m }
            if let c = attrs[.creationDate] { keep[.creationDate] = c }
            if !keep.isEmpty { try? fm.setAttributes(keep, ofItemAtPath: tmp.path) }
        }

        // Atomic publish: replace any existing dst, then rename temp → final.
        try? fm.removeItem(at: dst)
        do {
            try fm.moveItem(at: tmp, to: dst)
        } catch {
            try? fm.removeItem(at: tmp)
            return (nil, "rename into place failed: \(error.localizedDescription)")
        }

        onProgress?(written)
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), nil)
    }

    private static func relativePath(of url: URL, under base: URL) -> String {
        let baseComps = base.standardizedFileURL.pathComponents
        let urlComps = url.standardizedFileURL.pathComponents
        if Array(urlComps.prefix(baseComps.count)) == baseComps {
            return urlComps.dropFirst(baseComps.count).joined(separator: "/")
        }
        return url.lastPathComponent
    }

    /// Streaming MD5 so we never load a whole clip into memory. Each chunk is
    /// drained via autoreleasepool — without it, a 15GB clip balloons ~15GB of
    /// autoreleased buffers and macOS SIGKILLs the app under memory pressure.
    static func md5(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        var finished = false
        var failed = false
        while !finished && !failed {
            autoreleasepool {
                do {
                    guard let chunk = try handle.read(upToCount: 8 * 1024 * 1024),
                          !chunk.isEmpty else {
                        finished = true
                        return
                    }
                    hasher.update(data: chunk)
                } catch {
                    failed = true
                }
            }
        }
        if failed { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Backup + Manifest

    static func backUpAndVerify(ssdCardFolder: URL, to backupCardFolder: URL,
                                progress: ((Int, Int, String, Int64, Int64) -> Void)? = nil) -> CopyResult {
        let files = mediaFiles(in: ssdCardFolder)
        return copyAndVerify(source: ssdCardFolder, files: files, destFolder: backupCardFolder,
                             healMismatched: true, progress: progress)
    }

    static func finderItemCount(of folder: URL) -> Int {
        guard let en = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var count = 0
        for case let url as URL in en {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isRegularFile == true || values?.isDirectory == true {
                count += 1
            }
        }
        return count
    }

    static func humanSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return "\(Int(gb.rounded()))gb" }
        let mb = Double(bytes) / 1_000_000
        return "\(Int(mb.rounded()))mb"
    }

    /// Writes the DUMP receipt as a sibling of the card folder. Lists all backup locations.
    @discardableResult
    static func writeDumpedManifest(in destFolder: URL, mediaFileCount: Int,
                                    totalBytes: Int64, backupFolders: [URL] = []) -> URL {
        let count = finderItemCount(of: destFolder)
        let size = humanSize(totalBytes)
        let cardName = destFolder.lastPathComponent
        let name = "\(cardName)-DUMP-\(count)-files-\(size).txt"
        let url = destFolder.deletingLastPathComponent().appendingPathComponent(name)

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        let formattedBytes = formatter.string(from: NSNumber(value: totalBytes)) ?? "\(totalBytes)"

        var lines = ["Primary dump: \(destFolder.path)"]
        for (i, bu) in backupFolders.enumerated() {
            lines.append("Backup \(i + 1): \(bu.path)")
        }
        lines += ["Media files: \(mediaFileCount)",
                  "Total files: \(count)",
                  "Total size: \(size) (\(formattedBytes) bytes)"]
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Writes a BU receipt as a sibling of the backup card folder. Lists all locations.
    /// Written once per backup location — NOT also written to the SSD folder.
    @discardableResult
    static func writeBackedUpManifest(in folder: URL, dumpFolder: URL,
                                      allBackupFolders: [URL] = [], totalBytes: Int64) -> URL {
        let count = finderItemCount(of: folder)
        let size = humanSize(totalBytes)
        let cardName = folder.lastPathComponent
        let name = "\(cardName)-BU-\(count)-files-\(size).txt"
        let url = folder.deletingLastPathComponent().appendingPathComponent(name)

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        let formattedBytes = formatter.string(from: NSNumber(value: totalBytes)) ?? "\(totalBytes)"

        var lines = ["Primary dump: \(dumpFolder.path)",
                     "This backup: \(folder.path)"]
        let others = allBackupFolders.filter { $0.path != folder.path }
        for other in others {
            lines.append("Also backed up to: \(other.path)")
        }
        lines += ["Total files: \(count)",
                  "Total size: \(size) (\(formattedBytes) bytes)"]
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
