import Foundation
import DiskArbitration

/// Watches for newly mounted volumes (SD cards, card readers, SSDs) and calls
/// back with the volume's mount path.
///
/// Key detail: a freshly inserted card first "appears" UNMOUNTED, then macOS
/// mounts it a moment later. So we listen for the *description change* where a
/// volume's mount path goes from nothing to a real path — that's the true
/// "card was just inserted and is ready" signal. This also avoids the trap that
/// the "appeared" callback replays every already-mounted drive at startup.
final class DiskWatcher {
    private var session: DASession?
    private let onMount: (URL) -> Void

    // Avoid double-firing for the same volume path.
    private var recentlyHandled: Set<String> = []

    private let ignoredPaths: Set<String> = ["/", "/System/Volumes/Data"]

    init(onMount: @escaping (URL) -> Void) {
        self.onMount = onMount
    }

    func start() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            Log.write("DiskWatcher: failed to create DA session")
            return
        }
        self.session = session

        let context = Unmanaged.passUnretained(self).toOpaque()

        // Watch for the volume-path key changing (i.e. a mount happening).
        let watchKeys = [kDADiskDescriptionVolumePathKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(
            session,
            nil,        // match all disks
            watchKeys,  // only notify when the mount path changes
            { disk, _, context in
                guard let context = context else { return }
                let watcher = Unmanaged<DiskWatcher>.fromOpaque(context).takeUnretainedValue()
                watcher.diskChanged(disk)
            },
            context
        )

        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(),
                                     CFRunLoopMode.defaultMode.rawValue)
        Log.write("DiskWatcher: started, listening for mounts")
    }

    private func diskChanged(_ disk: DADisk) {
        guard let desc = DADiskCopyDescription(disk) as? [CFString: Any] else { return }

        // A mount path is only present once the volume is actually mounted.
        guard let volPathValue = desc[kDADiskDescriptionVolumePathKey],
              CFGetTypeID(volPathValue as CFTypeRef) == CFURLGetTypeID() else {
            return  // path went away (an unmount) — nothing to do
        }
        let url = volPathValue as! URL
        let path = url.standardizedFileURL.path

        if ignoredPaths.contains(path) { return }
        if path.hasPrefix("/System/") { return }
        if !isRealExternalMedia(desc: desc, path: path) { return }
        if recentlyHandled.contains(path) { return }

        recentlyHandled.insert(path)
        // Allow the same path to trigger again later (e.g. eject + reinsert).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.recentlyHandled.remove(path)
        }

        let name = url.lastPathComponent
        Log.write("DiskWatcher: volume mounted -> \(path) (\(name))")
        DispatchQueue.main.async { self.onMount(url) }
    }

    /// Only treat a mount as an ingest candidate if it's real external media:
    /// mounted under /Volumes, not a network share, and not a disk image (DMG).
    /// This filters out tmp/system mounts, mounted .dmg installers, and NAS shares.
    private func isRealExternalMedia(desc: [CFString: Any], path: String) -> Bool {
        // Real removable media mounts under /Volumes; tmp/system mounts don't.
        guard path.hasPrefix("/Volumes/") else {
            Log.write("DiskWatcher: skipping non-/Volumes mount -> \(path)")
            return false
        }

        // Skip network volumes (e.g. the NAS itself appearing as a share).
        if let isNetwork = desc[kDADiskDescriptionVolumeNetworkKey] as? Bool, isNetwork {
            Log.write("DiskWatcher: skipping network volume -> \(path)")
            return false
        }

        // Skip disk images (mounted .dmg files report model "Disk Image").
        if let model = desc[kDADiskDescriptionDeviceModelKey] as? String,
           model.localizedCaseInsensitiveContains("Disk Image") {
            Log.write("DiskWatcher: skipping disk image -> \(path)")
            return false
        }

        return true
    }

    deinit {
        if let session = session {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(),
                                           CFRunLoopMode.defaultMode.rawValue)
        }
    }
}
