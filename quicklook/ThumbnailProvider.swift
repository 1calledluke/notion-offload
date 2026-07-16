import QuickLookThumbnailing
import AppKit

/// System-wide Finder/QuickLook thumbnails for .braw, for ANY braw file on the
/// machine — including cards we never ingest and never write to. Decodes frame 0
/// with the `brawthumb` tool that ships in the host app's Resources.
@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {

    /// .../DIT Media Ingest.app/Contents/PlugIns/BrawThumbQL.appex → host Resources
    private var toolPath: String? {
        let contents = Bundle.main.bundleURL          // …/BrawThumbQL.appex
            .deletingLastPathComponent()              // …/PlugIns
            .deletingLastPathComponent()              // …/Contents
        let tool = contents.appendingPathComponent("Resources/brawthumb")
        return FileManager.default.isExecutableFile(atPath: tool.path) ? tool.path : nil
    }

    private func renderFrame(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let tool = toolPath else { return nil }
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

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let want = Int(max(request.maximumSize.width, request.maximumSize.height))
        guard let img = renderFrame(request.fileURL, maxPixel: max(want, 64)) else {
            handler(nil, NSError(domain: "BrawThumbQL", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "decode failed"]))
            return
        }

        // Fit the frame inside the requested box, preserving aspect (no stretch).
        let s = img.size
        let box = request.maximumSize
        let scale = min(box.width / s.width, box.height / s.height)
        let size = CGSize(width: max(s.width * scale, 1), height: max(s.height * scale, 1))

        handler(QLThumbnailReply(contextSize: size) { () -> Bool in
            img.draw(in: CGRect(origin: .zero, size: size))
            return true
        }, nil)
    }
}
