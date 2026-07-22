import Foundation

enum WhisperTranscriber {

    /// Engine: whisper.cpp (whisper-cli) with Metal GPU — ~30x realtime on
    /// Apple Silicon (a 98s clip in ~3s). whisperx-on-CPU was ~1x realtime,
    /// unusable for interview days, so it's gone. whisper.cpp gives
    /// segment-level timestamps, which is plenty for scripting.
    static func transcribe(wavURL: URL, modelPath: String, outputBaseURL: URL) -> String? {
        transcribeWithCLI(wavURL: wavURL, modelPath: modelPath, outputBaseURL: outputBaseURL)
    }

    private static let whisperxPython = NSHomeDirectory() + "/venvs/whisperx/bin/python"

    /// Runs whisperx in its venv and reads SRT from stdout. Alignment gives
    /// every segment a word-accurate start time.
    private static func transcribeWithWhisperX(wavURL: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: whisperxPython) else { return nil }

        let script = """
        import sys, whisperx
        wav = sys.argv[1]
        model = whisperx.load_model("large-v3-turbo", "cpu", compute_type="int8", language="en")
        audio = whisperx.load_audio(wav)
        result = model.transcribe(audio, batch_size=8, language="en")
        align_model, meta = whisperx.load_align_model(language_code="en", device="cpu")
        result = whisperx.align(result["segments"], align_model, meta, audio, "cpu")

        def ts(t):
            t = max(0.0, float(t))
            h = int(t // 3600); m = int(t % 3600 // 60); s = int(t % 60)
            ms = int((t - int(t)) * 1000)
            return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

        out = []
        for i, seg in enumerate(result["segments"], 1):
            text = seg.get("text", "").strip()
            if not text:
                continue
            out.append(f"{i}\\n{ts(seg['start'])} --> {ts(seg['end'])}\\n{text}\\n")
        sys.stdout.write("\\n".join(out))
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: whisperxPython)
        proc.arguments = ["-c", script, wavURL.path]
        // The framework Python ships without SSL certs wired up; point model
        // downloads at the venv's certifi bundle or they die on first fetch.
        var env = ProcessInfo.processInfo.environment
        let certPath = NSHomeDirectory() + "/venvs/whisperx/lib/python3.13/site-packages/certifi/cacert.pem"
        if FileManager.default.fileExists(atPath: certPath) {
            env["SSL_CERT_FILE"] = certPath
        }
        proc.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            Log.write("whisperx launch failed: \(error) — falling back to whisper-cli")
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0,
              let srt = String(data: data, encoding: .utf8),
              srt.contains("-->") else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            Log.write("whisperx failed for \(wavURL.lastPathComponent) (code \(proc.terminationStatus)): \(err.suffix(300)) — falling back to whisper-cli")
            return nil
        }
        Log.write("transcribed with whisperx (aligned) -> \(wavURL.lastPathComponent)")
        return srt
    }

    private static func transcribeWithCLI(wavURL: URL, modelPath: String, outputBaseURL: URL) -> String? {
        let cliPath: String
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/whisper-cli") {
            cliPath = "/opt/homebrew/bin/whisper-cli"
        } else {
            cliPath = "whisper-cli"
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "-m", modelPath,
            "-f", wavURL.path,
            "-osrt",
            "-of", outputBaseURL.path,
            "-l", "en"
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let srtPath = outputBaseURL.path + ".srt"
            if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: srtPath) {
                let srtContent = try String(contentsOfFile: srtPath, encoding: .utf8)
                try? FileManager.default.removeItem(atPath: srtPath)
                return srtContent
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: data, encoding: .utf8) ?? ""
                Log.write("whisper-cli failed (code \(process.terminationStatus)) for \(wavURL.lastPathComponent): \(errStr)")
                return nil
            }
        } catch {
            Log.write("whisper-cli exception for \(wavURL.lastPathComponent): \(error)")
            return nil
        }
    }
}
