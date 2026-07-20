import AppKit

/// Checks the private GitHub repo for a newer release and self-updates.
///
/// Auth, in order: the gh CLI's keyring token (Luke's machine), then a
/// read-only token in config.json's `githubToken` (coworker machines).
/// No token -> the check quietly does nothing.
enum UpdateChecker {
    static let repo = "1calledluke/notion-offload"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func githubToken() -> String? {
        // gh CLI keyring first
        for gh in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: gh) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: gh)
            proc.arguments = ["auth", "token"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            if (try? proc.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus == 0,
                   let t = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    return t
                }
            }
        }
        let cfgToken = Config.load().githubToken
        return cfgToken.isEmpty ? nil : cfgToken
    }

    private static func request(_ url: URL, token: String, accept: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return req
    }

    /// True when a is a newer semantic version than b.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// `interactive`: menu-item invocation — also reports "you're up to date"
    /// and errors. The silent launch check only ever speaks when there IS one.
    static func check(interactive: Bool) {
        Task.detached {
            guard let token = githubToken() else {
                if interactive {
                    await alert("No GitHub access",
                                "Install the gh CLI and run `gh auth login`, or paste a read-only GitHub token in Settings.")
                }
                return
            }
            let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
            guard let (data, resp) = try? await URLSession.shared.data(
                    for: request(api, token: token, accept: "application/vnd.github+json")),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if interactive { await alert("Update check failed", "Couldn't reach GitHub releases for \(repo).") }
                return
            }

            guard isNewer(tag, than: currentVersion) else {
                Log.write("update check: \(currentVersion) is current (latest \(tag))")
                if interactive { await alert("Up to date", "Version \(currentVersion) is the latest.") }
                return
            }

            let assets = (json["assets"] as? [[String: Any]]) ?? []
            guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                  let assetURLString = zip["url"] as? String,
                  let assetURL = URL(string: assetURLString) else {
                if interactive { await alert("Update found (\(tag))", "But the release has no .zip asset to install.") }
                return
            }

            let notes = (json["body"] as? String) ?? ""
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "Update available: \(tag)"
                alert.informativeText = "You have \(currentVersion).\n\n\(notes.prefix(400))"
                alert.addButton(withTitle: "Install & Relaunch")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                Task.detached { await install(assetURL: assetURL, token: token, tag: tag) }
            }
        }
    }

    private static func install(assetURL: URL, token: String, tag: String) async {
        Log.write("update: downloading \(tag)…")
        guard let (data, resp) = try? await URLSession.shared.data(
                for: request(assetURL, token: token, accept: "application/octet-stream")),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            await alert("Update failed", "Couldn't download the release asset.")
            return
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("dit-update-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let zipPath = work.appendingPathComponent("update.zip")
        do { try data.write(to: zipPath) } catch {
            await alert("Update failed", "Couldn't write the download: \(error.localizedDescription)")
            return
        }

        // ditto preserves signatures/xattrs, unlike unzip.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipPath.path, work.path]
        try? unzip.run(); unzip.waitUntilExit()

        guard let newApp = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else {
            await alert("Update failed", "The release zip didn't contain an .app.")
            return
        }

        let dest = URL(fileURLWithPath: "/Applications/DIT Media Ingest.app")
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // ditto over the top: running binary keeps executing from its old inode.
        swap.arguments = [newApp.path, dest.path]
        try? swap.run(); swap.waitUntilExit()
        guard swap.terminationStatus == 0 else {
            await alert("Update failed", "Couldn't replace the app in /Applications.")
            return
        }

        Log.write("update: installed \(tag), relaunching")
        await MainActor.run {
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; open '\(dest.path)'"]
            try? relaunch.run()
            NSApp.terminate(nil)
        }
    }

    @MainActor private static func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
