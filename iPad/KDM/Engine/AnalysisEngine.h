// Key Detector - a Fuzzy Audio plug-in.  (c) 2026 Fuzzy Audio LLC. All rights reserved.
// This software is licensed, not sold; use is governed by the End User License
// Agreement (see the EULA PDF in the repository root). Unauthorised copying,
// distribution, or modification is prohibited.

#pragma once

#include <array>
#include <atomic>
#include <mutex>
#include <vector>

#include "ChromaKeyDetector.h"
#include "PitchDetector.h"
#include "TempoEstimator.h"

/**
    JUCE-free version of the plug-in's analysis pipeline, for the iPad app.

    It runs exactly the same chain as KeyDetectorAudioProcessor (mono sum ->
    8192-point FIFO with 75% overlap -> Hann -> FFT -> chroma/key, YIN tuner,
    audio tempo) using the shared ChromaKeyDetector / PitchDetector /
    TempoEstimator code in ../../../Source, plus an input level meter.

    Threading: process() is called from the audio thread; everything else
    (getSnapshot(), settings) from the UI thread. Results are handed over through
    atomics and a try-lock, so the audio thread never waits on the UI.
*/
class AnalysisEngine
{
public:
    static constexpr int fftOrder    = 13;
    static constexpr int fftSize     = 1 << fftOrder;  // 8192
    static constexpr int numBins     = fftSize / 2;    // 4096
    static constexpr int hopSize     = fftSize / 4;    // 75% overlap
    static constexpr int pitchWindow = 4096;

    enum class TunerMode { Auto = 0, Pitch = 1, Peak = 2 };

    /** Per-channel input level since the previous getSnapshot() call. */
    struct ChannelLevel
    {
        float peak = 0.0f;   // linear, 0..1 (1 = 0 dBFS)
        float rms  = 0.0f;   // linear
        bool  clipped = false; // a sample reached >= 0.999 (about -0.01 dBFS)
    };

    struct Snapshot
    {
        // Key
        int   keyPitchClass   = -1;   // 0 = C … 11 = B, -1 = none yet
        bool  keyIsMinor      = false;
        float keyCorrelation  = 0.0f; // -1..1 (low = atonal / "no clear key")
        float keyConfidence   = 0.0f; // 0..1
        std::array<float, 12> chroma {};

        // Tempo
        float bpm             = 0.0f;
        float bpmConfidence   = 0.0f;

        // Tuner (0 Hz = nothing to show)
        float tunerFrequency  = 0.0f;
        float tunerClarity    = 0.0f;
        bool  tunerIsPitch    = true;

        // Input meter (index 0 = left / mono, 1 = right)
        std::array<ChannelLevel, 2> levels {};
        int   numChannels     = 0;
    };

    AnalysisEngine();

    /** Call before the first process(), and whenever the sample rate changes.
        Not real-time safe (allocates); call while audio is stopped. */
    void prepare (double sampleRate, int maxBlockSize);

    /** Audio thread. `left` is required; pass `right` = nullptr for mono input. */
    void process (const float* left, const float* right, int numSamples) noexcept;

    /** UI thread. Fills `out` with the latest results and resets the meter peaks. */
    void getSnapshot (Snapshot& out);

    /** Latest magnitude spectrum (numBins values), for a spectrum display. */
    void getSpectrum (std::vector<float>& dest);

    // --- Settings (UI thread, take effect on the next analysis frame) ---------
    void setSmoothing (float smoothing01) noexcept { smoothing.store (smoothing01); }   // 0..0.99, default 0.85
    void setFrozen    (bool shouldFreeze) noexcept { frozen.store (shouldFreeze); }
    void setTunerMode (TunerMode m)       noexcept { tunerMode.store ((int) m); }
    /** The desktop plug-in shows major keys only. Turn this off to also report minor
        keys (needed for Camelot notation, e.g. 8A vs 8B). */
    void setMajorOnly (bool majorOnly)    noexcept { majorOnlyRequested.store (majorOnly); }
    void requestReset()                   noexcept { resetRequested.store (true); }

    double getSampleRate() const noexcept { return sampleRate; }

private:
    void pushSample (float sample) noexcept;
    void analyseFrame() noexcept;
    float dominantPeakHz (const float* mags, int numMagBins) const noexcept;
    void updateTuner (float rawFreq, bool rawIsPitch, bool valid, float clarity) noexcept;
    void magnitudeSpectrum (float* data) noexcept;   // in place: data[0..numBins) = |X[k]|

    double sampleRate = 48000.0;

    ChromaKeyDetector detector;
    PitchDetector     pitchDetector;
    TempoEstimator    tempoEstimator;

    // FFT (radix-2, precomputed twiddles + bit reversal).
    std::vector<float> window;            // Hann, normalised like juce::dsp::WindowingFunction
    std::vector<float> twiddleRe, twiddleIm;
    std::vector<int>   bitReverse;
    std::vector<float> fftRe, fftIm;

    std::array<float, fftSize> fifo {};
    std::array<float, fftSize> frame {};
    int writePos     = 0;
    int hopCountdown = fftSize;
    std::vector<float> monoScratch;

    // Tuner display state (audio thread only).
    int    tunerDisplayMidi    = -1;
    bool   tunerDisplayIsPitch = true;
    int    tunerCandMidi       = -1;
    bool   tunerCandIsPitch    = true;
    int    tunerCandCount      = 0;
    double tunerSmoothedFreq   = 0.0;
    int    tunerSilenceCount   = 0;

    // Settings.
    std::atomic<float> smoothing { 0.85f };
    std::atomic<bool>  frozen    { false };
    std::atomic<int>   tunerMode { 0 };
    std::atomic<bool>  majorOnlyRequested { true };
    std::atomic<bool>  resetRequested { false };

    // Published results.
    std::array<std::atomic<float>, 12> publishedChroma {};
    std::atomic<int>   publishedKeyPc    { -1 };
    std::atomic<bool>  publishedKeyMinor { false };
    std::atomic<float> publishedCorr     { 0.0f };
    std::atomic<float> publishedConf     { 0.0f };
    std::atomic<float> publishedBpm      { 0.0f };
    std::atomic<float> publishedBpmConf  { 0.0f };
    std::atomic<float> publishedFreq     { 0.0f };
    std::atomic<float> publishedClarity  { 0.0f };
    std::atomic<bool>  publishedTunerIsPitch { true };

    // Meter: max peak / sum of squares accumulated since the last snapshot.
    std::array<std::atomic<float>, 2> meterPeak {};
    std::array<std::atomic<float>, 2> meterSumSq {};
    std::atomic<int>   meterSamples  { 0 };
    std::array<std::atomic<bool>, 2>  meterClip {};
    std::atomic<int>   meterChannels { 0 };

    std::mutex         spectrumLock;
    std::vector<float> publishedSpectrum;
};
