// Key Detector - a Fuzzy Audio plug-in.  (c) 2026 Fuzzy Audio LLC. All rights reserved.
// This software is licensed, not sold; use is governed by the End User License
// Agreement (see the EULA PDF in the repository root). Unauthorised copying,
// distribution, or modification is prohibited.

#pragma once

#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_dsp/juce_dsp.h>

#include <array>
#include <atomic>
#include <vector>

#include "ChromaKeyDetector.h"
#include "PitchDetector.h"
#include "TempoEstimator.h"

#include <fuzzyaudio_licensing/fuzzyaudio_licensing.h>

//==============================================================================
/**
    KeyDetectorAudioProcessor
    -------------------------
    An audio-analysis plugin: it listens to the incoming audio, runs a short-time
    FFT, folds the spectrum into a 12-bin chroma vector and estimates the musical
    key by correlating that chroma against the Krumhansl–Schmuckler key profiles.

    The audio is passed through untouched — this is an analyser, so it behaves like
    an insert effect that also happens to display the detected key.

    Threading:
      * The FFT + chroma + key estimation run on the audio thread once per
        `fftSize` samples (an FFT of 4096 points is cheap relative to a block).
      * Results are *published* into atomics / a spin-locked buffer that the editor
        polls from a Timer, so the GUI never blocks the audio thread.
*/
class KeyDetectorAudioProcessor : public juce::AudioProcessor
{
public:
    //==============================================================================
    // FFT configuration.
    //   fftOrder = 13  ->  fftSize = 8192 samples.
    //   At 48 kHz that is ~5.9 Hz/bin.  We analyse with 75% overlap (hopSize =
    //   fftSize/4), so a new spectrum/key frame is produced every ~43 ms even
    //   though the window is ~171 ms long.  The larger window sharpens low-end
    //   resolution (bass notes / their partials land in distinct bins) while the
    //   overlap keeps the display responsive and gives the key detector 4x more
    //   frames to average.  Lower notes are also reinforced by their higher
    //   harmonics, which is why octave-collapsed chroma stays robust.
    static constexpr int fftOrder = 13;
    static constexpr int fftSize  = 1 << fftOrder; // 8192
    static constexpr int numBins  = fftSize / 2;   // 4096 usable magnitude bins
    static constexpr int hopSize  = fftSize / 4;   // 75% overlap

    //==============================================================================
    KeyDetectorAudioProcessor();
    ~KeyDetectorAudioProcessor() override;

    //==============================================================================
    void prepareToPlay (double sampleRate, int samplesPerBlock) override;
    void releaseResources() override;
    bool isBusesLayoutSupported (const BusesLayout& layouts) const override;
    void processBlock (juce::AudioBuffer<float>&, juce::MidiBuffer&) override;
    using juce::AudioProcessor::processBlock; // keep the double-precision overload visible

    //==============================================================================
    juce::AudioProcessorEditor* createEditor() override;
    bool hasEditor() const override { return true; }

    //==============================================================================
    const juce::String getName() const override { return JucePlugin_Name; }

    bool acceptsMidi() const override  { return false; }
    bool producesMidi() const override { return false; }
    bool isMidiEffect() const override { return false; }
    double getTailLengthSeconds() const override { return 0.0; }

    //==============================================================================
    int getNumPrograms() override { return 1; }
    int getCurrentProgram() override { return 0; }
    void setCurrentProgram (int) override {}
    const juce::String getProgramName (int) override { return {}; }
    void changeProgramName (int, const juce::String&) override {}

    //==============================================================================
    void getStateInformation (juce::MemoryBlock& destData) override;
    void setStateInformation (const void* data, int sizeInBytes) override;

    //==============================================================================
    // ---- GUI-facing accessors (lock-free / cheap, safe to call from the editor) --

    /** Latest key estimate, assembled from published atomics. */
    ChromaKeyDetector::KeyEstimate getKeyEstimate() const;

    /** Snapshot of the latest smoothed chroma vector (12 values, sums to ~1). */
    std::array<float, 12> getChromaSnapshot() const;

    /** Copy the latest magnitude spectrum into `dest` (resized to numBins).
        Returns false if the buffer was busy (caller keeps its previous frame). */
    bool copySpectrum (std::vector<float>& dest) const;

    /** Latest monophonic tuner reading: fundamental frequency in Hz (0 if none)
        and clarity 0..1 (only trust it when clarity is high, e.g. > 0.6). */
    float getTunerFrequency() const noexcept { return publishedFreq.load(); }
    float getTunerClarity()   const noexcept { return publishedClarity.load(); }

    /** True when the tuner reading is a harmonic pitch (YIN); false when it is the
        loudest spectral peak fallback (e.g. for percussion / inharmonic sounds). */
    bool getTunerIsPitch() const noexcept { return publishedTunerIsPitch.load(); }

    /** Ask the audio thread to clear the accumulated chroma at the next frame. */
    void requestReset() noexcept { resetRequested.store (true); }

    double getCurrentSampleRate() const noexcept { return currentSampleRate; }

    /** Tempo (BPM) estimated from the audio on this channel, or 0 if none yet. */
    double getBpm() const noexcept { return publishedBpm.load(); }

    /** Confidence (0..1) of the audio tempo estimate; low = no clear pulse. */
    float getBpmConfidence() const noexcept { return publishedBpmConf.load(); }

    juce::AudioProcessorValueTreeState apvts;

    /** Offline, machine-locked licensing for this plug-in. The editor shows an
        UnlockGate over the UI until a valid key is applied. */
    fuzzyaudio::LicenseManager license;

private:
    //==============================================================================
    static juce::AudioProcessorValueTreeState::ParameterLayout createParameterLayout();

    void pushSampleToFifo (float sample) noexcept;
    void analyseFrame();

    /** Frequency (Hz) of the single loudest spectral peak, parabolic-interpolated,
        or 0 if none.  Works for any signal (used as the tuner's percussion fallback). */
    float dominantPeakHz (const float* magnitudes, int numMagBins) const;

    /** Stabilise + publish the tuner reading: holds the displayed note (hysteresis),
        smooths the cents needle, and briefly holds the last note, so the read-out is
        steady and easy to read instead of flickering frame-to-frame. */
    void updateTuner (float rawFreq, bool rawIsPitch, bool valid, float clarity);

    //==============================================================================
    juce::dsp::FFT forwardFFT { fftOrder };
    juce::dsp::WindowingFunction<float> window { (size_t) fftSize,
                                                 juce::dsp::WindowingFunction<float>::hann };

    std::array<float, fftSize>      fifo {};       // circular buffer of mono samples
    std::array<float, fftSize * 2>  fftData {};    // real input + FFT workspace
    int  writePos      = 0;                        // next write index into fifo
    int  hopCountdown  = fftSize;                  // samples until next analysis frame

    ChromaKeyDetector detector;
    double currentSampleRate = 44100.0;

    // Audio-based tempo (BPM) estimation from the channel's signal.
    TempoEstimator      tempoEstimator;
    std::vector<float>  monoScratch;

    // Monophonic tuner (YIN).  Runs on the most recent `pitchWindow` samples.
    static constexpr int pitchWindow = 4096;
    PitchDetector pitchDetector;

    // Tuner display-stabilisation state (see updateTuner).
    int    tunerDisplayMidi   = -1;    // currently shown note (-1 = none)
    bool   tunerDisplayIsPitch = true;
    double tunerSmoothedFreq  = 0.0;   // smoothed frequency -> steady cents needle
    int    tunerCandMidi      = -1;    // challenger note awaiting the hold time
    int    tunerCandCount     = 0;
    bool   tunerCandIsPitch   = true;
    int    tunerSilenceCount  = 0;

    // Cached parameter handles.
    std::atomic<float>* smoothingParam = nullptr;
    std::atomic<float>* freezeParam    = nullptr;
    std::atomic<float>* tunerModeParam = nullptr; // 0=Auto, 1=Pitch, 2=Peak
    // (tempoMult is applied in the editor so it can also modify a held BPM.)

    // ---- Published analysis state (audio thread -> GUI thread) ------------------
    std::array<std::atomic<float>, 12> publishedChroma {};
    std::atomic<int>   publishedKeyPc   { 0 };
    std::atomic<bool>  publishedKeyMinor { false };
    std::atomic<float> publishedCorr    { 0.0f };
    std::atomic<float> publishedConf    { 0.0f };
    std::atomic<float> publishedFreq    { 0.0f };  // tuner: fundamental Hz
    std::atomic<float> publishedClarity { 0.0f };  // tuner: 0..1
    std::atomic<bool>  publishedTunerIsPitch { true }; // pitch (YIN) vs peak fallback
    std::atomic<double> publishedBpm { 0.0 };          // tempo estimated from audio
    std::atomic<float>  publishedBpmConf { 0.0f };     // tempo estimate confidence

    mutable juce::SpinLock spectrumLock;
    std::vector<float>     publishedSpectrum;      // numBins magnitudes

    std::atomic<bool> resetRequested { false };

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (KeyDetectorAudioProcessor)
};
