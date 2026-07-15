import AppKit
import AVFoundation
import ImageIO

/// Renders one thumbnail. All calls are blocking and belong off the main thread.
enum ThumbnailRenderer {
    static let maxPixel = 320

    /// BRAW has no system decoder: prefer the card's proxy (cheap — it's just an
    /// MP4), and fall back to decoding frame 0 with the bundled `brawthumb`
    /// tool, which links Blackmagic's own SDK. Cards shot without proxies would
    /// otherwise show no preview at all.
    static func render(url: URL, proxyIndex: [String: URL]) -> NSImage? {
        let ext = url.pathExtension.lowercased()

        if ext == "braw" {
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            if let proxy = proxyIndex[base], let img = video(proxy) { return img }
            return brawDirect(url)
        }

        let videoExts = ["mp4", "mov", "m4v", "mts", "m2ts", "avi", "mxf"]
        if videoExts.contains(ext) { return video(url) }

        let stillExts = ["jpg", "jpeg", "png", "tif", "tiff", "arw", "dng",
                         "raw", "heic", "cr2", "nef"]
        if stillExts.contains(ext) { return still(url) }

        return nil
    }

    /// Scans the card once for a Proxy folder so per-file lookups are a dict hit
    /// instead of re-walking the whole tree for every clip.
    static func buildProxyIndex(source: URL) -> [String: URL] {
        let fm = FileManager.default
        var index: [String: URL] = [:]
        guard let en = fm.enumerator(at: source,
                                     includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles]) else { return index }
        for case let url as URL in en {
            guard url.lastPathComponent.caseInsensitiveCompare("Proxy") == .orderedSame,
                  let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            else { continue }
            for file in files {
                let ext = file.pathExtension.lowercased()
                guard ext == "mp4" || ext == "mov" else { continue }
                index[file.deletingPathExtension().lastPathComponent.lowercased()] = file
            }
        }
        return index
    }

    private static func still(_ url: URL) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    private static func video(_ url: URL) -> NSImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // A 1s seek fails on very short clips — fall back to the first frame.
        for t in [CMTime(seconds: 1, preferredTimescale: 600), .zero] {
            if let cg = try? gen.copyCGImage(at: t, actualTime: nil) {
                return NSImage(cgImage: cg, size: .zero)
            }
        }
        return nil
    }

    private static func brawDirect(_ url: URL) -> NSImage? {
        guard let tool = Bundle.main.path(forResource: "brawthumb", ofType: nil),
              FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = [url.path, tmp.path, String(maxPixel)]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return NSImage(contentsOf: tmp)
    }
}

/// Lazily produces thumbnails for the file browser and remembers the results.
/// Only cells the user has actually scrolled to ask for an image, and at most
/// `limit` renders run at once — so a 200-clip BRAW card stays responsive
/// instead of spawning 200 decoders.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    /// A cached `nil` means "we tried and there's no preview" — don't retry it.
    private var cache: [URL: NSImage?] = [:]
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private var proxyIndexes: [URL: [String: URL]] = [:]

    private let limit = 3
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquireSlot() async {
        if active < limit { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }   // slot handed over
    }

    private func releaseSlot() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }

    private func proxyIndex(for source: URL) -> [String: URL] {
        if let hit = proxyIndexes[source] { return hit }
        let built = ThumbnailRenderer.buildProxyIndex(source: source)
        proxyIndexes[source] = built
        return built
    }

    func thumbnail(for url: URL, source: URL) async -> NSImage? {
        if let hit = cache[url] { return hit }
        if let running = inFlight[url] { return await running.value }

        let index = proxyIndex(for: source)
        let task = Task<NSImage?, Never> { [weak self] in
            guard let self else { return nil }
            await self.acquireSlot()
            let img = await Task.detached(priority: .utility) {
                ThumbnailRenderer.render(url: url, proxyIndex: index)
            }.value
            await self.releaseSlot()
            return img
        }
        inFlight[url] = task

        let img = await task.value
        cache[url] = img
        inFlight.removeValue(forKey: url)
        return img
    }
}
