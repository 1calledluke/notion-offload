import Foundation

/// Headless end-to-end exercise of the real Stage 1 + Stage 2 engine code,
/// run via `DITIngest --selftest`. Builds a fake card, dumps it, backs it up to
/// two locations, writes all manifests, and prints the resulting trees + counts
/// so we can verify behavior without the GUI or real hardware.
enum SelfTest {
    static func run() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dit_selftest_\(UUID().uuidString)")
        let card = root.appendingPathComponent("CARD")
        let dump = root.appendingPathComponent("SSD")
        let backup1 = root.appendingPathComponent("NAS")
        let backup2 = root.appendingPathComponent("SPINNER")

        // Build a fake card: 4 video files + a rollover-folder name collision
        // + a Sony-style video thumbnail + a hidden file.
        let clipsDir = card.appendingPathComponent("DCIM/100MSDCF")
        try? fm.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        for n in 1...4 {
            let data = Data((0..<(1_000_000)).map { _ in UInt8.random(in: 0...255) })
            try? data.write(to: clipsDir.appendingPathComponent(String(format: "C%04d.MP4", n)))
        }
        // Sony folder rollover: same filename in a second DCIM folder.
        let clips2Dir = card.appendingPathComponent("DCIM/101MSDCF")
        try? fm.createDirectory(at: clips2Dir, withIntermediateDirectories: true)
        try? Data((0..<500_000).map { _ in UInt8.random(in: 0...255) })
            .write(to: clips2Dir.appendingPathComponent("C0001.MP4"))
        // Sony-style thumbnail for clip C0001 — must NOT count as a still.
        try? Data([0xFF, 0xD8, 0xFF]).write(to: clipsDir.appendingPathComponent("C0001T01.JPG"))
        // Sony-style XML metadata sidecar for clip C0002 — must ride along with video.
        try? "<xml/>".data(using: .utf8)!.write(to: clipsDir.appendingPathComponent("C0002M01.XML"))
        // Blackmagic-style Proxy folder — its structure must be PRESERVED, and
        // its files share names with the originals without colliding.
        let proxyDir = card.appendingPathComponent("Proxy")
        try? fm.createDirectory(at: proxyDir, withIntermediateDirectories: true)
        try? Data((0..<100_000).map { _ in UInt8.random(in: 0...255) })
            .write(to: proxyDir.appendingPathComponent("C0002.MP4"))
        // An unrelated XML — must be left behind.
        try? "<xml/>".data(using: .utf8)!.write(to: card.appendingPathComponent("MEDIAPRO.XML"))
        try? "junk".data(using: .utf8)!.write(to: card.appendingPathComponent(".DS_Store"))

        print("=== SELF TEST ===")
        let byType = Engine.filesByType(in: card)
        
        // Naming: yy.mm project folder format
        let jobFolderName = "26.07" + "_TestProject_" + "0042"
        assert(jobFolderName == "26.07_TestProject_0042", "sanity")

        print("media types: \(byType.keys.sorted())")
        assert(byType["stills"] == nil, "video thumbnail should be filtered out of stills")
        assert(byType["video"]?.count == 7, "expected 7 video files (4 + rollover duplicate + proxy + XML sidecar)")
        assert(byType["video"]?.contains(where: { $0.lastPathComponent == "C0002M01.XML" }) == true,
               "XML sidecar should ride along with the video bucket")
        assert(byType["video"]?.contains(where: { $0.lastPathComponent == "MEDIAPRO.XML" }) != true,
               "unrelated XML should be left behind")

        let dateStr = "26.06.24"
        for (mediaType, files) in byType.sorted(by: { $0.key < $1.key }) {
            let rel = "TestProject/\(mediaType.capitalized)"
            let dateDir = dump.appendingPathComponent(rel)
            try? fm.createDirectory(at: dateDir, withIntermediateDirectories: true)
            let cardName = Engine.nextCardFolderName(in: dateDir, camera: "Sony A7IV", date: dateStr)
            print("card folder name: \(cardName)")
            let cardFolder = dateDir.appendingPathComponent(cardName)

            // Stage 1: dump + verify + manifest
            let r = Engine.copyAndVerify(source: card, files: files, destFolder: cardFolder)
            print("dump ok=\(r.ok) files=\(r.fileCount) bytes=\(r.totalBytes) failures=\(r.failures)")
            assert(r.ok, "dump should succeed despite the filename collision")
            assert(fm.fileExists(atPath: cardFolder.appendingPathComponent("C0001_2.MP4").path),
                   "colliding filename should be disambiguated to C0001_2.MP4")
            assert(fm.fileExists(atPath: cardFolder.appendingPathComponent("Proxy/C0002.MP4").path),
                   "Proxy folder structure must be preserved, not flattened")
            Engine.writeDumpedManifest(in: cardFolder, mediaFileCount: r.fileCount, totalBytes: r.totalBytes)

            // Stage 2: back up to both locations + verify + manifests
            var succeededBackupFolders: [URL] = []
            for (label, backup) in [("NAS", backup1), ("SPINNER", backup2)] {
                let dest = backup.appendingPathComponent("\(rel)/\(cardName)")
                let br = Engine.backUpAndVerify(ssdCardFolder: cardFolder, to: dest)
                print("backup[\(label)] ok=\(br.ok) files=\(br.fileCount) failures=\(br.failures)")
                if br.ok { succeededBackupFolders.append(dest) }
            }
            for dest in succeededBackupFolders {
                Engine.writeBackedUpManifest(in: dest, dumpFolder: cardFolder,
                                             allBackupFolders: succeededBackupFolders,
                                             totalBytes: r.totalBytes)
            }
        }

        // Print resulting trees + Finder-style counts.
        for (label, base) in [("SSD", dump), ("NAS", backup1), ("SPINNER", backup2)] {
            print("\n--- \(label) tree ---")
            if let en = fm.enumerator(at: base, includingPropertiesForKeys: nil) {
                for case let url as URL in en where !url.lastPathComponent.hasPrefix(".") {
                    print("  " + url.path.replacingOccurrences(of: base.path + "/", with: ""))
                }
            }
        }

        // Test ResumeDetector
        print("\n=== TEST RESUME DETECTOR ===")
        let tempLog = root.appendingPathComponent("test_app.log")
        let dummySSD = root.appendingPathComponent("SSD_Dummy_Card")
        try? fm.createDirectory(at: dummySSD, withIntermediateDirectories: true)
        try? "media".write(to: dummySSD.appendingPathComponent("clip1.mp4"), atomically: true, encoding: .utf8)
        
        let testLogContent = """
        [2026-07-01 10:00:00] App launched
        [2026-07-01 10:01:00] dump started -> card: 02_SonyA7IV_26.06.30, dest: \(dummySSD.path), files: 12
        [2026-07-01 10:02:00] dump verified -> 02_SonyA7IV_26.06.30, files: 12, bytes: 1000
        [2026-07-01 10:02:30] card ejected -> /Volumes/Untitled
        [2026-07-01 10:03:00] backup started -> /Volumes/Backup1
        [2026-07-01 10:03:10] backup started -> /Volumes/Backup2
        [2026-07-01 10:04:00] backup verified -> /Volumes/Backup1
        [2026-07-01 16:19:46] App launched
        """
        
        try? testLogContent.write(to: tempLog, atomically: true, encoding: .utf8)
        
        if let run = ResumeDetector.findIncompleteRun(logPath: tempLog) {
            print("Successfully detected incomplete run!")
            print("  Card Name: \(run.cardName)")
            print("  SSD Path: \(run.ssdCardFolder.path)")
            print("  Backup Dirs: \(run.backupDirs)")
            print("  Verified Dirs: \(run.verifiedDirs)")
        } else {
            print("FAILED to detect incomplete run!")
        }

        // Test edge cases:
        // Case 1: SSD folder missing
        try? fm.removeItem(at: dummySSD)
        let missingSSDRun = ResumeDetector.findIncompleteRun(logPath: tempLog)
        assert(missingSSDRun == nil, "Should return nil if SSD folder doesn't exist")
        
        // Recreate SSD folder
        try? fm.createDirectory(at: dummySSD, withIntermediateDirectories: true)
        try? "media".write(to: dummySSD.appendingPathComponent("clip1.mp4"), atomically: true, encoding: .utf8)
        
        // Case 2: All backup locations verified
        let allVerifiedLogContent = """
        [2026-07-01 10:00:00] App launched
        [2026-07-01 10:01:00] dump started -> card: 02_SonyA7IV_26.06.30, dest: \(dummySSD.path), files: 12
        [2026-07-01 10:02:00] dump verified -> 02_SonyA7IV_26.06.30, files: 12, bytes: 1000
        [2026-07-01 10:02:30] card ejected -> /Volumes/Untitled
        [2026-07-01 10:03:00] backup started -> /Volumes/Backup1
        [2026-07-01 10:03:10] backup started -> /Volumes/Backup2
        [2026-07-01 10:04:00] backup verified -> /Volumes/Backup1
        [2026-07-01 10:04:10] backup verified -> /Volumes/Backup2
        [2026-07-01 16:19:46] App launched
        """
        try? allVerifiedLogContent.write(to: tempLog, atomically: true, encoding: .utf8)
        let allVerifiedRun = ResumeDetector.findIncompleteRun(logPath: tempLog)
        assert(allVerifiedRun == nil, "Should return nil if all backups are verified")
        
        // Case 3: run complete present in window
        let completedLogContent = """
        [2026-07-01 10:00:00] App launched
        [2026-07-01 10:01:00] dump started -> card: 02_SonyA7IV_26.06.30, dest: \(dummySSD.path), files: 12
        [2026-07-01 10:02:00] dump verified -> 02_SonyA7IV_26.06.30, files: 12, bytes: 1000
        [2026-07-01 10:02:30] card ejected -> /Volumes/Untitled
        [2026-07-01 10:03:00] backup started -> /Volumes/Backup1
        [2026-07-01 10:04:00] backup verified -> /Volumes/Backup1
        [2026-07-01 10:05:00] run complete
        [2026-07-01 16:19:46] App launched
        """
        try? completedLogContent.write(to: tempLog, atomically: true, encoding: .utf8)
        let completedRun = ResumeDetector.findIncompleteRun(logPath: tempLog)
        assert(completedRun == nil, "Should return nil if run complete is present")
        
        // Case 4: mixed-media card — per-card attribution via [card: X] tags.
        // Stills card's backups verified + completed; video card's backup to the
        // SAME location crashed. The stills verification must not mask it.
        let mixedLogContent = """
        [2026-07-01 10:00:00] App launched
        [2026-07-01 10:01:00] dump started -> card: 01_Stills, dest: \(dummySSD.path), files: 10
        [2026-07-01 10:01:30] dump verified -> 01_Stills, files: 10, bytes: 1000
        [2026-07-01 10:02:00] dump started -> card: 01_Video, dest: \(dummySSD.path), files: 4
        [2026-07-01 10:02:30] dump verified -> 01_Video, files: 4, bytes: 4000
        [2026-07-01 10:03:00] card ejected -> /Volumes/Untitled
        [2026-07-01 10:04:00] backup started -> /Volumes/Backup1 [card: 01_Stills]
        [2026-07-01 10:05:00] backup verified -> /Volumes/Backup1 [card: 01_Stills]
        [2026-07-01 10:05:10] backup complete -> card: 01_Stills
        [2026-07-01 10:05:20] backup started -> /Volumes/Backup1 [card: 01_Video]
        """
        try? mixedLogContent.write(to: tempLog, atomically: true, encoding: .utf8)
        let mixedRun = ResumeDetector.findIncompleteRun(logPath: tempLog)
        assert(mixedRun?.cardName == "01_Video",
               "should detect the video card as incomplete, not be masked by the stills card")
        assert(mixedRun?.verifiedDirs.isEmpty == true,
               "stills verification must not count for the video card")

        // Case 5: multiple incomplete runs
        let multiSSD = root.appendingPathComponent("SSD_Dummy_Card2")
        try? fm.createDirectory(at: multiSSD, withIntermediateDirectories: true)
        try? "media".write(to: multiSSD.appendingPathComponent("clip2.mp4"), atomically: true, encoding: .utf8)
        try? fm.createDirectory(at: dummySSD, withIntermediateDirectories: true)
        try? "media".write(to: dummySSD.appendingPathComponent("clip1.mp4"), atomically: true, encoding: .utf8)

        let multiLogContent = """
        [2026-07-01 10:00:00] App launched
        [2026-07-01 10:01:00] dump started -> card: 01_FirstCard, dest: \(dummySSD.path), files: 1
        [2026-07-01 10:01:30] dump verified -> 01_FirstCard
        [2026-07-01 10:02:00] dump started -> card: 02_SecondCard, dest: \(multiSSD.path), files: 1
        [2026-07-01 10:02:30] dump verified -> 02_SecondCard
        [2026-07-01 10:03:00] card ejected -> /Volumes/Untitled
        [2026-07-01 10:04:00] backup started -> /Volumes/Backup1 [card: 01_FirstCard]
        [2026-07-01 10:05:00] backup started -> /Volumes/Backup1 [card: 02_SecondCard]
        """
        try? multiLogContent.write(to: tempLog, atomically: true, encoding: .utf8)
        let runs = ResumeDetector.findIncompleteRuns(logPath: tempLog)
        assert(runs.count == 2, "should detect both cards as incomplete")
        assert(runs[0].cardName == "02_SecondCard", "ordered most-recent-first")
        assert(runs[1].cardName == "01_FirstCard", "ordered most-recent-first")
        try? fm.removeItem(at: multiSSD)

        // Case 6: mixed card where Stills and Video folders share the SAME card
        // name (the real-world default) — records must be tracked by dest path.
        let dummySSD2 = root.appendingPathComponent("SSD_Dummy_Card_B")
        try? fm.createDirectory(at: dummySSD2, withIntermediateDirectories: true)
        try? "media".write(to: dummySSD2.appendingPathComponent("clip2.mp4"), atomically: true, encoding: .utf8)
        let sameNameLog = """
        [2026-07-10 09:00:00] App launched
        [2026-07-10 09:01:00] dump started -> card: 01_MIX, dest: \(dummySSD.path), files: 2
        [2026-07-10 09:01:10] dump verified -> 01_MIX, files: 2, bytes: 10
        [2026-07-10 09:02:00] dump started -> card: 01_MIX, dest: \(dummySSD2.path), files: 4
        [2026-07-10 09:02:30] dump verified -> 01_MIX, files: 4, bytes: 40
        [2026-07-10 09:03:00] card ejected -> /Volumes/Untitled
        [2026-07-10 09:04:00] backup started -> /Volumes/B1 [src: \(dummySSD.path)]
        [2026-07-10 09:04:30] backup verified -> /Volumes/B1 [src: \(dummySSD.path)]
        [2026-07-10 09:04:31] backup complete -> dest: \(dummySSD.path)
        [2026-07-10 09:05:00] backup started -> /Volumes/B1 [src: \(dummySSD2.path)]
        """
        try? sameNameLog.write(to: tempLog, atomically: true, encoding: .utf8)
        let sameNameRuns = ResumeDetector.findIncompleteRuns(logPath: tempLog)
        assert(sameNameRuns.count == 1, "exactly one folder should be incomplete")
        assert(sameNameRuns.first?.ssdCardFolder.path == dummySSD2.path,
               "the SECOND same-named folder must be detected, not masked by the first")

        // Case 7: run died BEFORE backups started — the planned lines make it detectable.
        let plannedLog = """
        [2026-07-10 12:00:00] App launched
        [2026-07-10 12:01:00] dump started -> card: 03_PLAN, dest: \(dummySSD.path), files: 4
        [2026-07-10 12:02:00] dump verified -> 03_PLAN, files: 4, bytes: 40
        [2026-07-10 12:02:01] backup planned -> /Volumes/B1 [src: \(dummySSD.path)]
        [2026-07-10 12:02:01] backup planned -> /Volumes/B2 [src: \(dummySSD.path)]
        [2026-07-10 12:02:05] card ejected -> /Volumes/Untitled
        """
        try? plannedLog.write(to: tempLog, atomically: true, encoding: .utf8)
        let plannedRuns = ResumeDetector.findIncompleteRuns(logPath: tempLog)
        assert(plannedRuns.count == 1 && plannedRuns.first?.backupDirs.count == 2,
               "planned-but-never-started backups must be detected")

        print("All ResumeDetector edge cases verified successfully!")

        try? fm.removeItem(at: root)
        print("\n=== SELF TEST DONE ===")
    }
}
