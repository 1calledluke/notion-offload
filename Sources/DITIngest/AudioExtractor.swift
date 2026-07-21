import Foundation
import AVFoundation

enum AudioExtractor {

    /// Video containers (Sony XAVC-S MP4s, MXF, etc.) go through AVFoundation —
    /// afconvert is an AUDIO-file tool and cannot open them at all. Pure audio
    /// files take the cheap afconvert path, with AVFoundation as the backstop.
    /// BRAW has no system decoder: the Blackmagic SDK reads its audio directly.
    static func extractAudio(from inputURL: URL, to outputWavURL: URL) -> Bool {
        let ext = inputURL.pathExtension.lowercased()
        if ext == "braw" {
            return extractFromBraw(from: inputURL, to: outputWavURL)
        }
        let audioOnly: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "flac", "caf"]
        if audioOnly.contains(ext) {
            if extractWithAfconvert(from: inputURL, to: outputWavURL) { return true }
        }
        return extractWithAVFoundation(from: inputURL, to: outputWavURL)
    }

    /// Bundled brawthumb --audio -> raw WAV, then afconvert down to 16k mono
    /// (whisper's expected input). Tool ships in this app's Resources, or the
    /// DIT Media Ingest app's, or the dev tree.
    private static func extractFromBraw(from inputURL: URL, to outputWavURL: URL) -> Bool {
        let candidates = [
            Bundle.main.path(forResource: "brawthumb", ofType: nil),
            "/Applications/DIT Media Ingest.app/Contents/Resources/brawthumb",
            NSHomeDirectory() + "/dit-ingest-app/tools/brawthumb",
        ].compactMap { $0 }
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            Log.write("BRAW audio skipped for \(inputURL.lastPathComponent): brawthumb tool not found")
            return false
        }

        let rawWav = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: rawWav) }

        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: tool)
        extract.arguments = ["--audio", inputURL.path, rawWav.path]
        extract.standardOutput = Pipe()
        extract.standardError = Pipe()
        do { try extract.run() } catch { return false }
        extract.waitUntilExit()
        guard extract.terminationStatus == 0,
              FileManager.default.fileExists(atPath: rawWav.path) else {
            Log.write("BRAW audio extraction failed for \(inputURL.lastPathComponent)")
            return false
        }
        // Downsample to whisper's 16k mono.
        return extractWithAfconvert(from: rawWav, to: outputWavURL)
    }

    private static func extractWithAfconvert(from inputURL: URL, to outputWavURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                             inputURL.path, outputWavURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
                && FileManager.default.fileExists(atPath: outputWavURL.path)
        } catch {
            return false
        }
    }

    /// Reads the first audio track with AVAssetReader, downmixed to 16kHz mono
    /// 16-bit PCM, and writes a standard WAV. Handles anything QuickTime plays.
    private static func extractWithAVFoundation(from inputURL: URL, to outputWavURL: URL) -> Bool {
        let asset = AVURLAsset(url: inputURL)

        // Synchronous bridge: the pipeline runs on its own worker already.
        let sema = DispatchSemaphore(value: 0)
        var tracks: [AVAssetTrack] = []
        Task {
            tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            sema.signal()
        }
        sema.wait()
        guard let track = tracks.first else {
            Log.write("no audio track in \(inputURL.lastPathComponent)")
            return false
        }

        guard let reader = try? AVAssetReader(asset: asset) else {
            Log.write("AVAssetReader init failed for \(inputURL.lastPathComponent)")
            return false
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else {
            Log.write("AVAssetReader start failed for \(inputURL.lastPathComponent): \(reader.error?.localizedDescription ?? "?")")
            return false
        }

        var pcm = Data()
        while let sample = output.copyNextSampleBuffer() {
            autoreleasepool {
                if let block = CMSampleBufferGetDataBuffer(sample) {
                    var length = 0
                    var pointer: UnsafeMutablePointer<Int8>? = nil
                    if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                   totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                       let p = pointer {
                        pcm.append(UnsafeBufferPointer(start: UnsafeRawPointer(p)
                            .assumingMemoryBound(to: UInt8.self), count: length))
                    }
                }
            }
        }
        guard reader.status == .completed, !pcm.isEmpty else {
            Log.write("AVFoundation audio read failed for \(inputURL.lastPathComponent) (status \(reader.status.rawValue))")
            return false
        }

        return writeWav(pcm: pcm, sampleRate: 16000, channels: 1, to: outputWavURL)
    }

    private static func writeWav(pcm: Data, sampleRate: UInt32, channels: UInt16, to url: URL) -> Bool {
        var header = Data()
        let byteRate = sampleRate * UInt32(channels) * 2
        let blockAlign = channels * 2
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { header.append(contentsOf: $0) } }
        header.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + pcm.count).littleEndian)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        append(UInt32(16).littleEndian)          // fmt chunk size
        append(UInt16(1).littleEndian)           // PCM
        append(channels.littleEndian)
        append(sampleRate.littleEndian)
        append(byteRate.littleEndian)
        append(blockAlign.littleEndian)
        append(UInt16(16).littleEndian)          // bits per sample
        header.append(contentsOf: "data".utf8)
        append(UInt32(pcm.count).littleEndian)
        do {
            try (header + pcm).write(to: url)
            return true
        } catch {
            Log.write("wav write failed: \(error)")
            return false
        }
    }
}
