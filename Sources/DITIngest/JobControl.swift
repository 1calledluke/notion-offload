import Foundation

/// Cooperative pause/cancel for a running ingest. The copy engine calls
/// `checkpoint()` between chunks: pause blocks right there (mid-file, safely —
/// nothing is half-written thanks to the .partial scheme), cancel throws and
/// unwinds through the normal failure paths, which already clean up partials
/// and leave the resume system able to pick up later.
final class JobControl: @unchecked Sendable {
    enum Cancelled: Error { case byUser }

    private let lock = NSCondition()
    private var paused = false
    private var cancelled = false

    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func pause()  { lock.lock(); paused = true;  lock.unlock() }
    func resume() { lock.lock(); paused = false; lock.signal(); lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; paused = false; lock.signal(); lock.unlock() }

    /// Blocks while paused; throws once cancelled. Call between work units.
    func checkpoint() throws {
        lock.lock()
        while paused && !cancelled { lock.wait() }
        let dead = cancelled
        lock.unlock()
        if dead { throw Cancelled.byUser }
    }
}
