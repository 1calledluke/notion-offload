import Foundation

struct MediaItem {
    let originalURL: URL
    let targetURL: URL
    let clipName: String // e.g. "C0012.mov" or "C0012.braw"
}

struct MediaScanResult {
    let items: [MediaItem]
    let skippedBrawCount: Int
}

enum MediaFinder {
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mxf", "mts", "m2ts"]
    private static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "flac"]

    static func findMedia(in folderURL: URL) -> MediaScanResult {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        
        guard let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return MediaScanResult(items: [], skippedBrawCount: 0)
        }
        
        var allFiles: [URL] = []
        
        for case let fileURL as URL in enumerator {
            let pathComponents = fileURL.pathComponents
            
            // Skip anything under /THMBNL/ (case-insensitive)
            if pathComponents.contains(where: { $0.caseInsensitiveCompare("THMBNL") == .orderedSame }) {
                continue
            }
            
            // Skip files starting with "._" or hidden files
            let fileName = fileURL.lastPathComponent
            if fileName.hasPrefix("._") || fileName.hasPrefix(".") {
                continue
            }
            
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
                allFiles.append(fileURL)
            }
        }
        
        // Build map of files in Proxy directories for quick lookup:
        var proxyMap: [String: URL] = [:] // key: "c0012.mp4" or "c0012.mov"
        var proxyURLsSet: Set<URL> = []
        
        for file in allFiles {
            let pathComponents = file.pathComponents
            if pathComponents.contains(where: { $0.caseInsensitiveCompare("Proxy") == .orderedSame }) {
                let key = file.lastPathComponent.lowercased()
                proxyMap[key] = file
                proxyURLsSet.insert(file)
            }
        }
        
        var rawItems: [MediaItem] = []
        var skippedBrawCount = 0
        var usedProxyURLs: Set<URL> = []
        
        // Process braw files first to assign proxy URLs
        for file in allFiles {
            let ext = file.pathExtension.lowercased()
            let baseName = file.deletingPathExtension().lastPathComponent
            let clipName = file.lastPathComponent
            
            if ext == "braw" {
                let mp4Key = "\(baseName).mp4".lowercased()
                let movKey = "\(baseName).mov".lowercased()
                
                if let proxyURL = proxyMap[mp4Key] ?? proxyMap[movKey] {
                    rawItems.append(MediaItem(originalURL: file, targetURL: proxyURL, clipName: clipName))
                    usedProxyURLs.insert(proxyURL)
                    Log.write("Using proxy \(proxyURL.lastPathComponent) for \(clipName)")
                } else {
                    // No proxy? Read audio straight out of the .braw via the
                    // Blackmagic SDK (brawthumb --audio). AudioExtractor detects
                    // the .braw target and handles it.
                    rawItems.append(MediaItem(originalURL: file, targetURL: file, clipName: clipName))
                    Log.write("No proxy for \(clipName) — will read audio from the .braw directly")
                }
            }
        }
        
        // Process other video and audio files
        for file in allFiles {
            let ext = file.pathExtension.lowercased()
            let clipName = file.lastPathComponent
            
            if ext != "braw" && (videoExtensions.contains(ext) || audioExtensions.contains(ext)) {
                if proxyURLsSet.contains(file) && usedProxyURLs.contains(file) {
                    continue
                }
                rawItems.append(MediaItem(originalURL: file, targetURL: file, clipName: clipName))
            }
        }
        
        // Deduplicate target paths
        var uniqueItems: [MediaItem] = []
        var seenTargetPaths: Set<String> = []
        for item in rawItems {
            if !seenTargetPaths.contains(item.targetURL.path) {
                seenTargetPaths.insert(item.targetURL.path)
                uniqueItems.append(item)
            }
        }
        
        return MediaScanResult(items: uniqueItems, skippedBrawCount: skippedBrawCount)
    }
}
