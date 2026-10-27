import Foundation
import os

/// Runs the key / tempo analysis on its own queue so the audio tap only copies
/// samples and returns at once. With the main output plus four mixer channels
/// analysed, doing the work inside the tap could take longer than a buffer and
/// make iPadOS drop the input stream.
final class AnalysisWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "kdm.analysis", qos: .userInitiated)
    private var lock = os_unfair_lock()
    private var pending = 0
    private var droppedCount = 0

    /// Buffers skipped because the analysis fell behind (since the last reset).
    var dropped: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return droppedCount
    }

    /// Queues work; skips it if ~0.4 s of audio is already waiting, so a slow
    /// moment never backs up into the audio input.
    func submit(_ work: @escaping () -> Void) {
        os_unfair_lock_lock(&lock)
        if pending >= 16 {
            droppedCount += 1
            os_unfair_lock_unlock(&lock)
            return
        }
        pending += 1
        os_unfair_lock_unlock(&lock)
        queue.async { [self] in
            work()
            os_unfair_lock_lock(&lock)
            pending -= 1
            os_unfair_lock_unlock(&lock)
        }
    }

    /// Waits for queued work to finish (before engines are re-prepared).
    func drain() { queue.sync {} }

    func resetStats() {
        os_unfair_lock_lock(&lock)
        droppedCount = 0
        os_unfair_lock_unlock(&lock)
    }
}
