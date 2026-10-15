// Key Detector - a Fuzzy Audio plug-in.  (c) 2026 Fuzzy Audio LLC. All rights reserved.
// This software is licensed, not sold; use is governed by the End User License
// Agreement (see the EULA PDF in the repository root). Unauthorised copying,
// distribution, or modification is prohibited.

#include "AnalysisEngine.h"

#include <algorithm>
#include <cmath>

namespace
{
    constexpr double kPi = 3.14159265358979323846;

    void atomicMax (std::atomic<float>& a, float v) noexcept
    {
        float cur = a.load (std::memory_order_relaxed);
        while (v > cur && ! a.compare_exchange_weak (cur, v, std::memory_order_relaxed)) {}
    }

    void atomicAdd (std::atomic<float>& a, float v) noexcept
    {
        float cur = a.load (std::memory_order_relaxed);
        while (! a.compare_exchange_weak (cur, cur + v, std::memory_order_relaxed)) {}
    }
}

//==============================================================================
AnalysisEngine::AnalysisEngine()
{
    // Hann window, identical to juce::dsp::WindowingFunction<float>(fftSize, hann)
    // (symmetric, normalised so its sum equals its length) so the magnitudes match
    // the desktop plug-in exactly.
    window.resize ((size_t) fftSize);
    double sum = 0.0;
    for (int i = 0; i < fftSize; ++i)
    {
        window[(size_t) i] = (float) (0.5 - 0.5 * std::cos (2.0 * kPi * i / (fftSize - 1)));
        sum += window[(size_t) i];
    }
    const float factor = (float) (fftSize / sum);
    for (auto& w : window)
        w *= factor;

    twiddleRe.resize ((size_t) fftSize / 2);
    twiddleIm.resize ((size_t) fftSize / 2);
    for (int k = 0; k < fftSize / 2; ++k)
    {
        twiddleRe[(size_t) k] = (float) std::cos (-2.0 * kPi * k / fftSize);
        twiddleIm[(size_t) k] = (float) std::sin (-2.0 * kPi * k / fftSize);
    }

    bitReverse.resize ((size_t) fftSize);
    for (int i = 0; i < fftSize; ++i)
    {
        int r = 0;
        for (int b = 0; b < fftOrder; ++b)
            if (i & (1 << b))
                r |= 1 << (fftOrder - 1 - b);
        bitReverse[(size_t) i] = r;
    }

    fftRe.resize ((size_t) fftSize);
    fftIm.resize ((size_t) fftSize);
    publishedSpectrum.assign ((size_t) numBins, 0.0f);

    prepare (sampleRate, 4096);
}

void AnalysisEngine::prepare (double newSampleRate, int maxBlockSize)
{
    sampleRate = newSampleRate > 0.0 ? newSampleRate : 48000.0;

    detector.prepare (sampleRate, fftSize);
    detector.setMajorOnly (majorOnlyRequested.load());
    detector.setKeyMethod (ChromaKeyDetector::KeyMethod::Correlation);
    detector.setKeyHoldTime (0.7f);

    pitchDetector.prepare (sampleRate, pitchWindow);
    pitchDetector.setFrequencyRange (40.0, 1500.0);
    tunerDisplayMidi  = -1;
    tunerCandMidi     = -1;
    tunerCandCount    = 0;
    tunerSmoothedFreq = 0.0;
    tunerSilenceCount = 0;

    tempoEstimator.prepare (sampleRate);
    monoScratch.assign ((size_t) std::max (1, maxBlockSize), 0.0f);

    fifo.fill (0.0f);
    writePos     = 0;
    hopCountdown = fftSize; // wait for one full window before the first analysis

    for (auto& c : publishedChroma) c.store (0.0f);
    publishedKeyPc.store (-1);
    publishedCorr.store (0.0f);
    publishedConf.store (0.0f);
    publishedBpm.store (0.0f);
    publishedBpmConf.store (0.0f);
    publishedFreq.store (0.0f);
    publishedClarity.store (0.0f);

    std::lock_guard<std::mutex> lock (spectrumLock);
    std::fill (publishedSpectrum.begin(), publishedSpectrum.end(), 0.0f);
}

//==============================================================================
void AnalysisEngine::process (const float* left, const float* right, int numSamples) noexcept
{
    if (left == nullptr || numSamples <= 0)
        return;

    // --- Input meter ----------------------------------------------------------
    const int numCh = right != nullptr ? 2 : 1;
    const float* chans[2] = { left, right };
    for (int c = 0; c < numCh; ++c)
    {
        float pk = 0.0f, sq = 0.0f;
        for (int n = 0; n < numSamples; ++n)
        {
            const float s = chans[c][n];
            pk = std::max (pk, std::abs (s));
            sq += s * s;
        }
        atomicMax (meterPeak[(size_t) c], pk);
        atomicAdd (meterSumSq[(size_t) c], sq);
        if (pk >= 0.999f)
            meterClip[(size_t) c].store (true, std::memory_order_relaxed);
    }
    meterSamples.fetch_add (numSamples, std::memory_order_relaxed);
    meterChannels.store (numCh, std::memory_order_relaxed);

    // --- Analysis (same as the plug-in's processBlock) -------------------------
    // Process in chunks of the scratch size so an unexpectedly large buffer never
    // needs an allocation on the audio thread.
    int offset = 0;
    while (offset < numSamples)
    {
        const int n = std::min (numSamples - offset, (int) monoScratch.size());
        for (int i = 0; i < n; ++i)
        {
            const float mono = right != nullptr ? 0.5f * (left[offset + i] + right[offset + i])
                                                 : left[offset + i];
            monoScratch[(size_t) i] = mono;
            pushSample (mono);
        }

        tempoEstimator.processMono (monoScratch.data(), n);
        offset += n;
    }

    publishedBpm.store     (tempoEstimator.getBpm());
    publishedBpmConf.store (tempoEstimator.getConfidence());
}

void AnalysisEngine::pushSample (float sample) noexcept
{
    fifo[(size_t) writePos] = sample;
    writePos = (writePos + 1) % fftSize;

    if (--hopCountdown <= 0)
    {
        analyseFrame();
        hopCountdown = hopSize;
    }
}

void AnalysisEngine::magnitudeSpectrum (float* data) noexcept
{
    // Complex radix-2 FFT of the (real) windowed frame, then |X[k]| for k < N/2.
    // Unnormalised, matching juce::dsp::FFT::performFrequencyOnlyForwardTransform.
    for (int i = 0; i < fftSize; ++i)
    {
        fftRe[(size_t) bitReverse[(size_t) i]] = data[i];
        fftIm[(size_t) i] = 0.0f;
    }

    for (int size = 2; size <= fftSize; size <<= 1)
    {
        const int half = size / 2;
        const int step = fftSize / size;
        for (int start = 0; start < fftSize; start += size)
        {
            for (int k = 0; k < half; ++k)
            {
                const float wr = twiddleRe[(size_t) (k * step)];
                const float wi = twiddleIm[(size_t) (k * step)];
                const size_t a = (size_t) (start + k);
                const size_t b = a + (size_t) half;
                const float tr = wr * fftRe[b] - wi * fftIm[b];
                const float ti = wr * fftIm[b] + wi * fftRe[b];
                fftRe[b] = fftRe[a] - tr;
                fftIm[b] = fftIm[a] - ti;
                fftRe[a] += tr;
                fftIm[a] += ti;
            }
        }
    }

    for (int k = 0; k < numBins; ++k)
        data[k] = std::sqrt (fftRe[(size_t) k] * fftRe[(size_t) k] + fftIm[(size_t) k] * fftIm[(size_t) k]);
}

void AnalysisEngine::analyseFrame() noexcept
{
    for (int i = 0; i < fftSize; ++i)
        frame[(size_t) i] = fifo[(size_t) ((writePos + i) % fftSize)];

    // Tuner step 1: YIN on the most recent, un-windowed samples (skipped when the
    // tuner is off).
    const bool tunerOn = tunerEnabled.load();
    const float* recent = frame.data() + (fftSize - pitchWindow);
    PitchDetector::Result pitchResult;
    double rms = 0.0;
    if (tunerOn)
    {
        pitchResult = pitchDetector.process (recent, pitchWindow);
        for (int i = 0; i < pitchWindow; ++i)
            rms += (double) recent[i] * recent[i];
        rms = std::sqrt (rms / pitchWindow);
    }

    if (resetRequested.exchange (false))
    {
        detector.reset();
        tempoEstimator.reset();
        for (auto& c : publishedChroma)
            c.store (0.0f);
    }

    const double hopSeconds = (double) hopSize / sampleRate;
    const double tau   = 0.1 + (double) smoothing.load() * 3.9;   // 0.1 s .. ~4 s
    detector.setSmoothing ((float) std::exp (-hopSeconds / tau));
    detector.setFrozen    (frozen.load());
    detector.setMajorOnly (majorOnlyRequested.load());

    for (int i = 0; i < fftSize; ++i)
        frame[(size_t) i] *= window[(size_t) i];
    magnitudeSpectrum (frame.data());

    // Tuner step 2 (see KeyDetectorAudioProcessor::analyseFrame).
    const bool silent = ! tunerOn || rms < 1.0e-3;
    const int  mode   = tunerMode.load();

    float rawFreq = 0.0f;
    bool  rawIsPitch = true;
    bool  valid = false;

    if (! silent)
    {
        bool usePitch;
        if      (mode == 1) usePitch = true;
        else if (mode == 2) usePitch = false;
        else                usePitch = (pitchResult.frequency > 0.0f && pitchResult.clarity >= 0.6f);

        if (usePitch && pitchResult.frequency > 0.0f)
        {
            rawFreq = pitchResult.frequency; rawIsPitch = true; valid = true;
        }
        else if (! usePitch || mode == 0)
        {
            const float peakHz = dominantPeakHz (frame.data(), numBins);
            if (peakHz > 0.0f) { rawFreq = peakHz; rawIsPitch = false; valid = true; }
        }
    }

    updateTuner (rawFreq, rawIsPitch, valid, pitchResult.clarity);

    detector.processSpectrum (frame.data(), numBins);
    const auto est    = detector.estimateStableKey (hopSeconds);
    const auto chroma = detector.getChroma();

    for (int i = 0; i < 12; ++i)
        publishedChroma[(size_t) i].store (chroma[(size_t) i]);

    publishedKeyPc.store    (est.pitchClass);
    publishedKeyMinor.store (est.isMinor);
    publishedCorr.store     (est.correlation);
    publishedConf.store     (est.confidence);

    std::unique_lock<std::mutex> lock (spectrumLock, std::try_to_lock);
    if (lock.owns_lock())
        std::copy (frame.begin(), frame.begin() + numBins, publishedSpectrum.begin());
}

float AnalysisEngine::dominantPeakHz (const float* mags, int numMagBins) const noexcept
{
    const int kLo = std::max (1, (int) std::floor (30.0 * fftSize / sampleRate));
    const int kHi = std::min (numMagBins - 2, (int) std::ceil (12000.0 * fftSize / sampleRate));

    int   kMax = kLo;
    float mMax = 0.0f;
    for (int k = kLo; k <= kHi; ++k)
        if (mags[k] > mMax) { mMax = mags[k]; kMax = k; }

    if (mMax <= 0.0f)
        return 0.0f;

    const double a = std::log ((double) mags[kMax - 1] + 1.0e-12);
    const double b = std::log ((double) mags[kMax]     + 1.0e-12);
    const double c = std::log ((double) mags[kMax + 1] + 1.0e-12);
    const double denom = a - 2.0 * b + c;
    const double delta = std::abs (denom) > 1.0e-12 ? 0.5 * (a - c) / denom : 0.0;

    return (float) (((double) kMax + delta) * sampleRate / (double) fftSize);
}

void AnalysisEngine::updateTuner (float rawFreq, bool rawIsPitch, bool valid, float clarity) noexcept
{
    const double hopSeconds = (double) hopSize / sampleRate;
    const int noteHoldFrames = std::max (1, (int) std::lround (0.12 / hopSeconds));
    const int releaseFrames  = std::max (1, (int) std::lround (0.30 / hopSeconds));
    const double centsAlpha   = std::exp (-hopSeconds / 0.12);

    if (valid && rawFreq > 0.0f)
    {
        tunerSilenceCount = 0;

        int midi, pc, oct; double cents;
        PitchDetector::frequencyToNote ((double) rawFreq, midi, pc, oct, cents);

        if (tunerDisplayMidi < 0)
        {
            tunerDisplayMidi    = midi;
            tunerDisplayIsPitch = rawIsPitch;
            tunerSmoothedFreq   = rawFreq;
            tunerCandMidi = midi; tunerCandCount = 0;
        }
        else if (midi == tunerDisplayMidi)
        {
            tunerDisplayIsPitch = rawIsPitch;
            tunerCandMidi = midi; tunerCandCount = 0;
            tunerSmoothedFreq = std::exp (centsAlpha * std::log (tunerSmoothedFreq)
                                        + (1.0 - centsAlpha) * std::log ((double) rawFreq));
        }
        else
        {
            if (midi == tunerCandMidi) ++tunerCandCount;
            else { tunerCandMidi = midi; tunerCandCount = 1; tunerCandIsPitch = rawIsPitch; }

            if (tunerCandCount >= noteHoldFrames)
            {
                tunerDisplayMidi    = tunerCandMidi;
                tunerDisplayIsPitch = tunerCandIsPitch;
                tunerSmoothedFreq   = rawFreq;
                tunerCandCount = 0;
            }
        }

        publishedFreq.store ((float) tunerSmoothedFreq);
        publishedClarity.store (tunerDisplayIsPitch ? clarity : 1.0f);
        publishedTunerIsPitch.store (tunerDisplayIsPitch);
    }
    else if (++tunerSilenceCount >= releaseFrames)
    {
        tunerDisplayMidi = -1;
        tunerCandMidi = -1;
        tunerCandCount = 0;
        tunerSmoothedFreq = 0.0;
        publishedFreq.store (0.0f);
        publishedClarity.store (0.0f);
    }
}

//==============================================================================
void AnalysisEngine::getSnapshot (Snapshot& out)
{
    out.keyPitchClass  = publishedKeyPc.load();
    out.keyIsMinor     = publishedKeyMinor.load();
    out.keyCorrelation = publishedCorr.load();
    out.keyConfidence  = publishedConf.load();
    for (int i = 0; i < 12; ++i)
        out.chroma[(size_t) i] = publishedChroma[(size_t) i].load();

    out.bpm           = publishedBpm.load();
    out.bpmConfidence = publishedBpmConf.load();

    out.tunerFrequency = publishedFreq.load();
    out.tunerClarity   = publishedClarity.load();
    out.tunerIsPitch   = publishedTunerIsPitch.load();

    const int samples = meterSamples.exchange (0);
    out.numChannels   = meterChannels.load();
    for (size_t c = 0; c < 2; ++c)
    {
        const float sq = meterSumSq[c].exchange (0.0f);
        out.levels[c].peak    = meterPeak[c].exchange (0.0f);
        out.levels[c].rms     = samples > 0 ? std::sqrt (sq / (float) samples) : 0.0f;
        out.levels[c].clipped = meterClip[c].exchange (false);
    }
}

void AnalysisEngine::getSpectrum (std::vector<float>& dest)
{
    std::lock_guard<std::mutex> lock (spectrumLock);
    dest = publishedSpectrum;
}
