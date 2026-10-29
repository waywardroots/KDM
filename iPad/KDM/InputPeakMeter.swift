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
    private var stalls = 0
    private var longestGapMs: Double = 0
    private var lastFrames = 0
    /// Set by the audio manager; used to tell a late buffer from a big one.
    var sampleRate: Double = 48000
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000   // ticks -> ms
    }()

    struct Health {
        var buffersPerSecond: Double
        var gaps: Int            // a buffer later than 2.5× its own length (since start)
        var stalls: Int          // no audio at all for over a second
        var longestGapMs: Double
        var framesPerBuffer: Int
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
            let bufferMs = Double(frames) / max(sampleRate, 1) * 1000
            if ms > max(50, bufferMs * 2.5) { gaps += 1 }
            if ms > 1000 { stalls += 1 }
            if ms > longestGapMs && ms < 60_000 { longestGapMs = ms }
        }
        lastBuffer = now
        lastFrames = frames
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
        let h = Health(buffersPerSecond: rate, gaps: gaps, stalls: stalls, longestGapMs: longestGapMs, framesPerBuffer: lastFrames)
        os_unfair_lock_unlock(&lock)
        return h
    }

    /// How long since the last buffer arrived (0 before the first one).
    func msSinceLastBuffer() -> Double {
        os_unfair_lock_lock(&lock)
        let last = lastBuffer
        os_unfair_lock_unlock(&lock)
        guard last != 0 else { return 0 }
        return Double(mach_absolute_time() - last) * Self.timebase
    }

    /// After an engine restart: forget when the last buffer came (the restart
    /// itself isn't a stall), but keep the counts so stalls stay visible.
    func resetHealth() {
        os_unfair_lock_lock(&lock)
        buffers = 0; healthBuffers = 0; lastBuffer = 0
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
