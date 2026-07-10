import Foundation

struct IncompleteRun {
    let cardName: String          // e.g. "01_BM6kFF_26.07.10"
    let ssdCardFolder: URL        // the dump destination from "dump started" line
    let backupDirs: [String]      // all backup locations this card folder was headed to
    let verifiedDirs: [String]    // locations that verified before the failure

    /// "01_BM6kFF_26.07.10 (Stills)" — a mixed card produces Stills + Video
    /// folders with the SAME card name, so show the media type to tell them apart.
    var displayName: String {
        let type = ssdCardFolder.deletingLastPathComponent().lastPathComponent
        return "\(cardName) (\(type))"
    }
}

/// Reads app.log and finds every card FOLDER whose backups never finished.
///
/// Records are keyed by the dump DESTINATION PATH, not the card name: a mixed
/// card creates Stills + Video folders that share one card name, and they must
/// be tracked independently. Newer backup log lines carry a "[src: <path>]" tag
/// for exact attribution; older "[card: X]" tags map to the most recent record
/// with that card name; untagged (oldest) lines map to the last-dumped record.
enum ResumeDetector {
    private struct CardRecord {
        var cardName: String
        var dumpVerified = false
        var ejected = false
        var backupDirs: [String] = []
        var verifiedDirs: [String] = []
        var complete = false
    }

    /// Splits "…dir [tagName: X]" into (dir, X). Tag absent -> (dir, nil).
    private static func splitTag(_ s: String, tagName: String) -> (String, String?) {
        guard let r = s.range(of: " [\(tagName): "), s.hasSuffix("]") else { return (s, nil) }
        return (String(s[..<r.lowerBound]), String(s[r.upperBound...].dropLast()))
    }

    static func findIncompleteRuns(logPath: URL) -> [IncompleteRun] {
        let fm = FileManager.default
        guard let content = try? String(contentsOf: logPath, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var records: [String: CardRecord] = [:]   // key: dest path
        var order: [String] = []
        var currentDest: String? = nil
        var pendingEject: [String] = []            // dests dumped since the last eject

        // Resolve a backup line to a record key: [src:] tag wins, then [card:]
        // (most recent record with that name), then the current dest.
        func resolveKey(srcTag: String?, cardTag: String?) -> String? {
            if let src = srcTag, records[src] != nil { return src }
            if let card = cardTag {
                for dest in order.reversed() where records[dest]?.cardName == card { return dest }
                return nil
            }
            return currentDest
        }

        for line in lines {
            if let range = line.range(of: "dump started -> card: ") {
                let remainder = line[range.upperBound...]
                if let destRange = remainder.range(of: ", dest: "),
                   let filesRange = remainder[destRange.upperBound...].range(of: ", files: ") {
                    let card = remainder[..<destRange.lowerBound].trimmingCharacters(in: .whitespaces)
                    let dest = remainder[destRange.upperBound..<filesRange.lowerBound]
                        .trimmingCharacters(in: .whitespaces)
                    if records[dest] != nil { order.removeAll { $0 == dest } }  // re-dump: latest wins
                    records[dest] = CardRecord(cardName: card)
                    order.append(dest)
                    currentDest = dest
                    pendingEject.append(dest)
                }
            }

            if let dest = currentDest, let card = records[dest]?.cardName,
               line.contains("dump verified -> \(card)") {
                records[dest]?.dumpVerified = true
            }

            if line.contains("card ejected ->") {
                for dest in pendingEject { records[dest]?.ejected = true }
                pendingEject = []
            }

            // Planned backups are logged right after a dump verifies, so a run
            // that dies BEFORE backups begin is still detectable.
            if let range = line.range(of: "] backup planned -> ") {
                let raw = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let (afterSrc, srcTag) = splitTag(raw, tagName: "src")
                let (dir, cardTag) = splitTag(afterSrc, tagName: "card")
                if let key = resolveKey(srcTag: srcTag, cardTag: cardTag),
                   records[key] != nil, !records[key]!.backupDirs.contains(dir) {
                    records[key]!.backupDirs.append(dir)
                }
            }

            // "] " prefix keeps "resume backup started" from matching here.
            if let range = line.range(of: "] backup started -> ") {
                let raw = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let (afterSrc, srcTag) = splitTag(raw, tagName: "src")
                let (dir, cardTag) = splitTag(afterSrc, tagName: "card")
                if let key = resolveKey(srcTag: srcTag, cardTag: cardTag),
                   records[key] != nil, !records[key]!.backupDirs.contains(dir) {
                    records[key]!.backupDirs.append(dir)
                }
            }

            // Accept both normal and resume verifications.
            if let range = line.range(of: "] backup verified -> ")
                ?? line.range(of: "] resume backup verified -> ") {
                let raw = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let (afterSrc, srcTag) = splitTag(raw, tagName: "src")
                let (dir, cardTag) = splitTag(afterSrc, tagName: "card")
                if let key = resolveKey(srcTag: srcTag, cardTag: cardTag),
                   records[key] != nil, !records[key]!.verifiedDirs.contains(dir) {
                    records[key]!.verifiedDirs.append(dir)
                }
            }

            // New precise per-folder marker.
            if let range = line.range(of: "backup complete -> dest: ") {
                let dest = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                records[dest]?.complete = true
            }

            // Legacy per-card-name marker (also used by "Mark as Handled" for a
            // whole card): completes every record sharing that name.
            if let range = line.range(of: "backup complete -> card: ") {
                let card = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                for (dest, rec) in records where rec.cardName == card {
                    records[dest]?.complete = true
                }
            }

            if line.contains("run complete") {
                for k in records.keys { records[k]?.complete = true }
            }
        }

        var results: [IncompleteRun] = []
        for dest in order.reversed() {
            guard let rec = records[dest],
                  rec.dumpVerified, rec.ejected, !rec.complete, !rec.backupDirs.isEmpty
            else { continue }
            let unverified = rec.backupDirs.filter { !rec.verifiedDirs.contains($0) }
            guard !unverified.isEmpty else { continue }
            guard fm.fileExists(atPath: dest) else { continue }
            results.append(IncompleteRun(cardName: rec.cardName,
                                         ssdCardFolder: URL(fileURLWithPath: dest),
                                         backupDirs: rec.backupDirs,
                                         verifiedDirs: rec.verifiedDirs))
        }
        return results
    }

    static func findIncompleteRun(logPath: URL) -> IncompleteRun? {
        return findIncompleteRuns(logPath: logPath).first
    }
}
