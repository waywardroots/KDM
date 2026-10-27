import Foundation
import Accelerate
import os

/// Peak level of every input channel, written by the audio tap and read by the
/// UI (~30 times a second). Used for the "All USB inputs" meters in Inputs, to
/// see which pair carries which mixer channel.
final class InputPeakMeter: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var peaks = [Float](repeating: 0, count: 32)

    // Audio health: are buffers arriving steadily?
    private var buffers = 0
    private var lastBuffer: UInt64 = 0
    private var gaps = 0
    private var longestGapMs: Double = 0
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000   // ticks -> ms
    }()

    struct Health {
        var buffersPerSecond: Double
        var gaps: Int            // pauses of more than 3 expected buffer lengths, since start
        var longestGapMs: Double
    }

    /// From the audio thread: the loudest sample per channel in this buffer.
    /// No allocation and only a brief lock, so it can't hold up the audio.
    func update(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, frames: Int) {
        let n = min(channels, 32)
        let now = mach_absolute_time()
        os_unfair_lock_lock(&lock)
        buffers += 1
        if lastBuffer != 0 {
            let ms = Double(now - lastBuffer) * Self.timebase
            if ms > 100 { gaps += 1 }
            if ms > longestGapMs && ms < 60_000 { longestGapMs = ms }
        }
        lastBuffer = now
        peaks.withUnsafeMutableBufferPointer { p in
            for c in 0..<n {
                var m: Float = 0
                vDSP_maxmgv(data[c], 1, &m, vDSP_Length(frames))
                if m > p[c] { p[c] = m }
            }
        }
        os_unfair_lock_unlock(&lock)
    }

    private var healthStart = mach_absolute_time()
    private var healthBuffers = 0

    /// Buffers per second since the last call, and gaps since start.
    func health() -> Health {
        os_unfair_lock_lock(&lock)
        let now = mach_absolute_time()
        let seconds = Double(now - healthStart) * Self.timebase / 1000
        let rate = seconds > 0 ? Double(buffers - healthBuffers) / seconds : 0
        healthStart = now
        healthBuffers = buffers
        let h = Health(buffersPerSecond: rate, gaps: gaps, longestGapMs: longestGapMs)
        os_unfair_lock_unlock(&lock)
        return h
    }

    func resetHealth() {
        os_unfair_lock_lock(&lock)
        buffers = 0; healthBuffers = 0; gaps = 0; longestGapMs = 0; lastBuffer = 0
        healthStart = mach_absolute_time()
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
