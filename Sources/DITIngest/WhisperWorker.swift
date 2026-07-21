import Foundation

/// Persistent whisperx worker: ONE python process per job, models loaded once,
/// clips streamed through stdin/stdout. Kills the 15–20s per-clip model-reload
/// tax that made big cards feel eternal.
///
/// Protocol: we write `<wav>\t<srt-out>\n`; worker replies `OK <path>` or
/// `ERR <message>` one line per job. `stop()` closes stdin and the process
/// exits.
final class WhisperWorker {
    private var proc: Process?
    private var stdinPipe: Pipe?
    private var stdoutHandle: FileHandle?
    private var buffer = Data()

    private static let python = NSHomeDirectory() + "/venvs/whisperx/bin/python"

    private static let script = """
    import sys, whisperx
    sys.stderr.write("loading models...\\n"); sys.stderr.flush()
    model = whisperx.load_model("large-v3-turbo", "cpu", compute_type="int8", language="en")
    align_model, meta = whisperx.load_align_model(language_code="en", device="cpu")
    print("READY", flush=True)

    def ts(t):
        t = max(0.0, float(t))
        h = int(t // 3600); m = int(t % 3600 // 60); s = int(t % 60)
        ms = int((t - int(t)) * 1000)
        return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

    for line in sys.stdin:
        line = line.rstrip("\\n")
        if not line:
            continue
        try:
            wav, out_path = line.split("\\t", 1)
            audio = whisperx.load_audio(wav)
            result = model.transcribe(audio, batch_size=8, language="en")
            result = whisperx.align(result["segments"], align_model, meta, audio, "cpu")
            cues = []
            for i, seg in enumerate(result["segments"], 1):
                text = seg.get("text", "").strip()
                if not text:
                    continue
                cues.append(f"{i}\\n{ts(seg['start'])} --> {ts(seg['end'])}\\n{text}\\n")
            with open(out_path, "w") as f:
                f.write("\\n".join(cues))
            print(f"OK {out_path}", flush=True)
        except Exception as e:
            print(f"ERR {e}", flush=True)
    """

    /// Launches the worker and blocks until models are loaded (or fails).
    func start() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Self.python) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.python)
        p.arguments = ["-u", "-c", Self.script]
        var env = ProcessInfo.processInfo.environment
        let certPath = NSHomeDirectory() + "/venvs/whisperx/lib/python3.13/site-packages/certifi/cacert.pem"
        if FileManager.default.fileExists(atPath: certPath) { env["SSL_CERT_FILE"] = certPath }
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            Log.write("whisper worker launch failed: \(error)")
            return false
        }
        proc = p
        stdinPipe = inPipe
        stdoutHandle = outPipe.fileHandleForReading

        // Wait for READY (model load ~10-20s, once per job). whisperx sprays
        // its own log lines onto stdout — skip anything that isn't ours.
        guard expectLine(oneOf: ["READY"], timeout: 180) != nil else {
            Log.write("whisper worker never became ready — falling back to per-clip mode")
            stop()
            return false
        }
        Log.write("whisper worker ready (models loaded once for this job)")
        return true
    }

    /// Transcribes one wav; returns SRT text or nil (caller falls back).
    func transcribe(wavURL: URL) -> String? {
        guard let proc, proc.isRunning, let stdinPipe else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".srt")
        defer { try? FileManager.default.removeItem(at: out) }

        let cmd = "\(wavURL.path)\t\(out.path)\n"
        guard let data = cmd.data(using: .utf8) else { return nil }
        do { try stdinPipe.fileHandleForWriting.write(contentsOf: data) } catch { return nil }

        // Generous ceiling: an hour-long interview transcodes in well under this.
        guard let reply = expectLine(oneOf: ["OK", "ERR"], timeout: 1800) else { return nil }
        if reply.hasPrefix("OK") {
            return try? String(contentsOf: out, encoding: .utf8)
        }
        Log.write("whisper worker error: \(reply)")
        return nil
    }

    func stop() {
        try? stdinPipe?.fileHandleForWriting.close()
        proc?.terminate()
        proc = nil
    }

    /// Reads lines until one starts with an expected prefix (skips whisperx's
    /// own stdout chatter); nil on timeout or worker death.
    private func expectLine(oneOf prefixes: [String], timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let line = readLine(timeout: deadline.timeIntervalSinceNow) else { return nil }
            if prefixes.contains(where: { line.hasPrefix($0) }) { return line }
            // otherwise: whisperx log chatter — ignore
        }
        return nil
    }

    /// Reads one \n-terminated line from the worker's stdout.
    private func readLine(timeout: TimeInterval) -> String? {
        guard let handle = stdoutHandle else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                return String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let chunk = handle.availableData   // blocks until data or EOF
            if chunk.isEmpty { return nil }    // worker died
            buffer.append(chunk)
        }
        return nil
    }
}
