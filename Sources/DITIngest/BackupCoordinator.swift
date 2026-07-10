import Foundation

/// Serializes backup writes per physical drive across the whole app. Only one
/// backup ever writes to a given volume at a time — so you can dump the next
/// card while a previous card's backups run, and if both target the same drive
/// the second simply queues instead of colliding. Two writers on one
/// non-journaled ExFAT/NTFS volume is exactly what corrupts these drives.
actor BackupCoordinator {
    static let shared = BackupCoordinator()

    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// The `/Volumes/<name>` root a path lives on — the unit we serialize by.
    nonisolated static func volumeRoot(of path: String) -> String {
        let comps = (path as NSString).pathComponents   // ["/", "Volumes", "Name", ...]
        if comps.count >= 3, comps[1] == "Volumes" {
            return "/\(comps[1])/\(comps[2])"
        }
        return path   // non-/Volumes target: serialize on the path itself
    }

    /// Wait until this volume is free, then mark it busy. Pair with `release`.
    func acquire(volume: String) async {
        if busy.contains(volume) {
            await withCheckedContinuation { cont in
                waiters[volume, default: []].append(cont)
            }
            // Resumed by release(): the volume is handed to us still-busy.
        } else {
            busy.insert(volume)
        }
    }

    func release(volume: String) {
        if var queue = waiters[volume], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[volume] = queue.isEmpty ? nil : queue
            next.resume()   // volume stays busy, passed to the next waiter
        } else {
            busy.remove(volume)
        }
    }
}
