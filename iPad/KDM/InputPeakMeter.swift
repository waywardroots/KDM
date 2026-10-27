import Foundation
import Accelerate
import os

/// Peak level of every input channel, written by the audio tap and read by the
/// UI (~30 times a second). Used for the "All USB inputs" meters in Inputs, to
/// see which pair carries which mixer channel.
final class InputPeakMeter: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var peaks = [Float](repeating: 0, count: 32)

    /// From the audio thread: the loudest sample per channel in this buffer.
    func update(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, frames: Int) {
        let n = min(channels, peaks.count)
        var local = [Float](repeating: 0, count: n)
        for c in 0..<n {
            vDSP_maxmgv(data[c], 1, &local[c], vDSP_Length(frames))
        }
        os_unfair_lock_lock(&lock)
        for c in 0..<n { peaks[c] = max(peaks[c], local[c]) }
        os_unfair_lock_unlock(&lock)
    }

    /// Peaks since the last call (linear 0…1), then reset.
    func take(channels: Int) -> [Float] {
        os_unfair_lock_lock(&lock)
        let n = min(channels, peaks.count)
        let out = Array(peaks[0..<n])
        for c in 0..<n { peaks[c] = 0 }
        os_unfair_lock_unlock(&lock)
        return out
    }
}
