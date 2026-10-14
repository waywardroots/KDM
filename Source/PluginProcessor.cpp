// Key Detector - a Fuzzy Audio plug-in.  (c) 2026 Fuzzy Audio LLC. All rights reserved.
// This software is licensed, not sold; use is governed by the End User License
// Agreement (see the EULA PDF in the repository root). Unauthorised copying,
// distribution, or modification is prohibited.

#include "PluginProcessor.h"
#include "PluginEditor.h"

#include <cmath>

//==============================================================================
#if KEYDETECTOR_USE_LICENSING
namespace
{
    // Builds the licensing configuration for this product. To reuse the licensing
    // module in another plug-in, copy this and change the product name + public
    // key. The matching RSA *private* key lives only on your server (keygen tool);
    // this embedded PUBLIC key can only *verify* keys, never create them.
    fuzzyaudio::LicenseManager::Config makeLicenseConfig()
    {
        fuzzyaudio::LicenseManager::Config c;
        c.productId   = "Key Detector";
        c.publicKey   = "5,8598c288e14265057f8aadf9fbdf54184fa5ae012829eddbe4825293ace2cdde"
                        "1044ee631478b021ad22b028d9a75dd1dfe145e48fea53ad9d67da19394d4c97"
                        "ddfed409ccb63ee14a9a0a43c117fb5af10f67d3adc33b01a2d009cffe38fe30"
                        "e2e67b41c7e74ff0cab6e07079b1eca596d7bb22b638c194d4bfe7eb8437f083";
        c.vendorName  = "Fuzzy Audio";
        c.appName     = "Key Detector";
        c.websiteName = "fuzzyaudio.example";
        c.websiteURL  = juce::URL ("https://fuzzyaudio.example");
        // Paste-only licensing: every key is signed with this fixed token, so a key
        // activates on any machine (no machine-ID step). Your website must sign keys
        // using this exact string as the "machine id".
        c.activationToken = "key-detector-license-v1";
        return c;
    }
}
#endif

//==============================================================================
KeyDetectorAudioProcessor::KeyDetectorAudioProcessor()
    : AudioProcessor (BusesProperties()
                          .withInput  ("Input",  juce::AudioChannelSet::stereo(), true)
                          .withOutput ("Output", juce::AudioChannelSet::stereo(), true)),
      apvts (*this, nullptr, "PARAMS", createParameterLayout())
     #if KEYDETECTOR_USE_LICENSING
      , license (makeLicenseConfig())
     #endif
{
    smoothingParam = apvts.getRawParameterValue ("smoothing");
    freezeParam    = apvts.getRawParameterValue ("freeze");
    tunerModeParam = apvts.getRawParameterValue ("tunerMode");

    publishedSpectrum.assign ((size_t) numBins, 0.0f);
}

KeyDetectorAudioProcessor::~KeyDetectorAudioProcessor() = default;

//==============================================================================
juce::AudioProcessorValueTreeState::ParameterLayout
KeyDetectorAudioProcessor::createParameterLayout()
{
    using namespace juce;
    AudioProcessorValueTreeState::ParameterLayout layout;

    // Smoothing = the EMA coefficient applied to the chroma each frame.
    // Higher = steadier reading, slower to react to key changes.
    layout.add (std::make_unique<AudioParameterFloat> (
        ParameterID { "smoothing", 1 }, "Smoothing",
        NormalisableRange<float> (0.0f, 0.99f, 0.001f), 0.85f));

    // Freeze = hold the current chroma / key (stop accumulating).
    layout.add (std::make_unique<AudioParameterBool> (
        ParameterID { "freeze", 1 }, "Freeze", false));

    // Tuner mode: Auto = pitch when a clear note is present else loudest peak;
    // Pitch = always the YIN fundamental; Peak = always the loudest spectral peak.
    layout.add (std::make_unique<AudioParameterChoice> (
        ParameterID { "tunerMode", 1 }, "Tuner Mode",
        juce::StringArray { "Auto", "Pitch", "Peak" }, 0));

    // Tempo octave multiplier for the BPM read-out (fixes half/double-time).
    layout.add (std::make_unique<AudioParameterChoice> (
        ParameterID { "tempoMult", 1 }, "Tempo x",
        juce::StringArray { "x0.5", "x1", "x2" }, 1));

    return layout;
}

//==============================================================================
void KeyDetectorAudioProcessor::prepareToPlay (double sampleRate, int samplesPerBlock)
{
    currentSampleRate = sampleRate;
    detector.prepare (sampleRate, fftSize);
    detector.setMajorOnly (true);   // GUI shows major keys only (never minor)
    // Krumhansl–Schmuckler correlation: correctly identifies the tonic even when the
    // loudest pitch class is the fifth (a chord's root is usually NOT its loudest
    // note, because the root's 3rd harmonic reinforces the fifth).  With the
    // peak-based chroma + smoothing + hysteresis this is now both accurate and steady.
    detector.setKeyMethod (ChromaKeyDetector::KeyMethod::Correlation);
    detector.setKeyHoldTime (0.7f); // a new key must persist ~0.7 s before it's shown

    pitchDetector.prepare (sampleRate, pitchWindow);
    pitchDetector.setFrequencyRange (40.0, 1500.0);
    tunerDisplayMidi  = -1;
    tunerCandMidi     = -1;
    tunerCandCount    = 0;
    tunerSmoothedFreq = 0.0;
    tunerSilenceCount = 0;

    tempoEstimator.prepare (sampleRate);
    monoScratch.assign ((size_t) juce::jmax (1, samplesPerBlock), 0.0f);

    fifo.fill (0.0f);
    fftData.fill (0.0f);
    writePos     = 0;
    hopCountdown = fftSize; // wait for one full window before the first analysis

    for (auto& c : publishedChroma)
        c.store (0.0f);

    const juce::SpinLock::ScopedLockType sl (spectrumLock);
    std::fill (publishedSpectrum.begin(), publishedSpectrum.end(), 0.0f);
}

void KeyDetectorAudioProcessor::releaseResources() {}

bool KeyDetectorAudioProcessor::isBusesLayoutSupported (const BusesLayout& layouts) const
{
    // Accept mono or stereo, as long as input and output layouts match.
    const auto& out = layouts.getMainOutputChannelSet();

    if (out != juce::AudioChannelSet::mono() && out != juce::AudioChannelSet::stereo())
        return false;

    return layouts.getMainInputChannelSet() == out;
}

//==============================================================================
void KeyDetectorAudioProcessor::pushSampleToFifo (float sample) noexcept
{
    // Circular write.  After the buffer is first filled we run an analysis every
    // hopSize samples (overlapping windows), which is what makes the display update
    // smoothly at high FFT sizes.
    fifo[(size_t) writePos] = sample;
    writePos = (writePos + 1) % fftSize;

    if (--hopCountdown <= 0)
    {
        analyseFrame();
        hopCountdown = hopSize;
    }
}

void KeyDetectorAudioProcessor::analyseFrame()
{
    // Reconstruct the last fftSize samples in time order (oldest first).  After the
    // most recent write, writePos points at the oldest sample in the ring.
    for (int i = 0; i < fftSize; ++i)
        fftData[(size_t) i] = fifo[(size_t) ((writePos + i) % fftSize)];

    // --- Tuner step 1: monophonic pitch on the most recent, *un-windowed* samples -
    // (Percussion / inharmonic sounds fall back to the loudest spectral peak below.)
    const float* recent = fftData.data() + (fftSize - pitchWindow);
    const auto pitchResult = pitchDetector.process (recent, pitchWindow);

    double rms = 0.0;
    for (int i = 0; i < pitchWindow; ++i)
        rms += (double) recent[i] * recent[i];
    rms = std::sqrt (rms / pitchWindow);

    if (resetRequested.exchange (false))
    {
        detector.reset();
        for (auto& c : publishedChroma)
            c.store (0.0f);
    }

    // Apply live parameter values.  The "smoothing" knob (0..1) is mapped to a
    // *time constant* rather than a raw per-frame coefficient, so the amount of
    // averaging doesn't change when the frame/overlap rate changes.
    const double hopSeconds = (double) hopSize / currentSampleRate;
    const float  smoothing01 = smoothingParam != nullptr ? smoothingParam->load() : 0.85f;
    const double tau = 0.1 + (double) smoothing01 * 3.9;              // 0.1 s .. ~4 s
    const double alpha = std::exp (-hopSeconds / tau);               // EMA coefficient
    detector.setSmoothing ((float) alpha);
    detector.setFrozen   (freezeParam != nullptr && freezeParam->load() > 0.5f);

    // 1) Window the frame (Hann) to reduce spectral leakage, then take the FFT.
    //    performFrequencyOnlyForwardTransform leaves |X[k]| in fftData[0..fftSize/2].
    window.multiplyWithWindowingTable (fftData.data(), (size_t) fftSize);
    forwardFFT.performFrequencyOnlyForwardTransform (fftData.data());

    // --- Tuner step 2: choose the raw reading (per Tuner Mode), then stabilise ----
    //   Auto  = YIN pitch when a clear note is present, else the loudest peak.
    //   Pitch = always the YIN fundamental (the played note, cents-accurate).
    //   Peak  = always the loudest spectral peak (good for percussion / SFX).
    const bool silent = rms < 1.0e-3;
    const int  tunerMode = tunerModeParam != nullptr ? (int) (tunerModeParam->load() + 0.5f) : 0;

    float rawFreq = 0.0f;
    bool  rawIsPitch = true;
    bool  valid = false;

    if (! silent)
    {
        bool usePitch;
        if      (tunerMode == 1) usePitch = true;   // Pitch
        else if (tunerMode == 2) usePitch = false;  // Peak
        else                     usePitch = (pitchResult.frequency > 0.0f && pitchResult.clarity >= 0.6f);

        if (usePitch && pitchResult.frequency > 0.0f)
        {
            rawFreq = pitchResult.frequency;
            rawIsPitch = true;
            valid = true;
        }
        else if (! usePitch || tunerMode == 0) // Peak, or Auto falling back to peak
        {
            const float peakHz = dominantPeakHz (fftData.data(), numBins);
            if (peakHz > 0.0f) { rawFreq = peakHz; rawIsPitch = false; valid = true; }
        }
    }

    updateTuner (rawFreq, rawIsPitch, valid, pitchResult.clarity);

    // 2) Update chroma + key estimate from the magnitude spectrum.
    detector.processSpectrum (fftData.data(), numBins);

    const auto est    = detector.estimateStableKey (hopSeconds);
    const auto chroma = detector.getChroma();

    // 3) Publish for the GUI (lock-free where possible).
    for (int i = 0; i < 12; ++i)
        publishedChroma[(size_t) i].store (chroma[(size_t) i]);

    publishedKeyPc.store    (est.pitchClass);
    publishedKeyMinor.store (est.isMinor);
    publishedCorr.store     (est.correlation);
    publishedConf.store     (est.confidence);

    // Spectrum is larger, so publish it under a try-lock (GUI copies it out).
    const juce::SpinLock::ScopedTryLockType sl (spectrumLock);
    if (sl.isLocked())
        std::copy (fftData.begin(), fftData.begin() + numBins, publishedSpectrum.begin());
}

float KeyDetectorAudioProcessor::dominantPeakHz (const float* mags, int numMagBins) const
{
    // Loudest bin in a sensible range (skip DC / very low rumble and ultrasonics).
    const int kLo = std::max (1, (int) std::floor (30.0 * fftSize / currentSampleRate));
    const int kHi = std::min (numMagBins - 2, (int) std::ceil (12000.0 * fftSize / currentSampleRate));

    int   kMax = kLo;
    float mMax = 0.0f;
    for (int k = kLo; k <= kHi; ++k)
        if (mags[k] > mMax) { mMax = mags[k]; kMax = k; }

    if (mMax <= 0.0f)
        return 0.0f;

    // Parabolic interpolation (log-magnitude) for a sub-bin frequency estimate.
    const double a = std::log ((double) mags[kMax - 1] + 1.0e-12);
    const double b = std::log ((double) mags[kMax]     + 1.0e-12);
    const double c = std::log ((double) mags[kMax + 1] + 1.0e-12);
    const double denom = a - 2.0 * b + c;
    const double delta = std::abs (denom) > 1.0e-12 ? 0.5 * (a - c) / denom : 0.0;

    return (float) (((double) kMax + delta) * currentSampleRate / (double) fftSize);
}

void KeyDetectorAudioProcessor::updateTuner (float rawFreq, bool rawIsPitch, bool valid, float clarity)
{
    const double hopSeconds = (double) hopSize / currentSampleRate;

    // How long a new note must persist before the display switches (short, so it is
    // still responsive), and how long the last note lingers after the sound stops.
    const int noteHoldFrames = std::max (1, (int) std::lround (0.12 / hopSeconds));
    const int releaseFrames  = std::max (1, (int) std::lround (0.30 / hopSeconds));
    const double centsAlpha   = std::exp (-hopSeconds / 0.12); // needle smoothing (~120 ms)

    if (valid && rawFreq > 0.0f)
    {
        tunerSilenceCount = 0;

        int midi, pc, oct; double cents;
        PitchDetector::frequencyToNote ((double) rawFreq, midi, pc, oct, cents);

        if (tunerDisplayMidi < 0)
        {
            // First reading: adopt immediately.
            tunerDisplayMidi    = midi;
            tunerDisplayIsPitch = rawIsPitch;
            tunerSmoothedFreq   = rawFreq;
            tunerCandMidi = midi; tunerCandCount = 0;
        }
        else if (midi == tunerDisplayMidi)
        {
            // Same note: smooth the frequency so the cents needle glides.
            tunerDisplayIsPitch = rawIsPitch;
            tunerCandMidi = midi; tunerCandCount = 0;
            tunerSmoothedFreq = std::exp (centsAlpha * std::log (tunerSmoothedFreq)
                                        + (1.0 - centsAlpha) * std::log ((double) rawFreq));
        }
        else
        {
            // Different note: only switch after it persists for the hold time.
            if (midi == tunerCandMidi) ++tunerCandCount;
            else { tunerCandMidi = midi; tunerCandCount = 1; tunerCandIsPitch = rawIsPitch; }

            if (tunerCandCount >= noteHoldFrames)
            {
                tunerDisplayMidi    = tunerCandMidi;
                tunerDisplayIsPitch = tunerCandIsPitch;
                tunerSmoothedFreq   = rawFreq;
                tunerCandCount = 0;
            }
            // else: keep holding the current note (needle stays put).
        }

        publishedFreq.store ((float) tunerSmoothedFreq);
        publishedClarity.store (tunerDisplayIsPitch ? clarity : 1.0f);
        publishedTunerIsPitch.store (tunerDisplayIsPitch);
    }
    else
    {
        // No reading this frame: hold the last note briefly, then clear.
        if (++tunerSilenceCount >= releaseFrames)
        {
            tunerDisplayMidi = -1;
            tunerCandMidi = -1;
            tunerCandCount = 0;
            tunerSmoothedFreq = 0.0;
            publishedFreq.store (0.0f);
            publishedClarity.store (0.0f);
        }
        // else: leave the previously-published values in place (note lingers).
    }
}

void KeyDetectorAudioProcessor::processBlock (juce::AudioBuffer<float>& buffer,
                                              juce::MidiBuffer&)
{
    juce::ScopedNoDenormals noDenormals;

    const int numSamples  = buffer.getNumSamples();
    const int numChannels = buffer.getNumChannels();

    // Mono-sum the input frame by frame and feed the analyser.  The audio itself is
    // passed through untouched (this is an analyser, not an effect).
    if (numChannels > 0)
    {
        const float* ch0 = buffer.getReadPointer (0);
        const float* ch1 = numChannels > 1 ? buffer.getReadPointer (1) : nullptr;

        if ((int) monoScratch.size() < numSamples)
            monoScratch.resize ((size_t) numSamples);

        for (int n = 0; n < numSamples; ++n)
        {
            const float mono = ch1 != nullptr ? 0.5f * (ch0[n] + ch1[n]) : ch0[n];
            monoScratch[(size_t) n] = mono;
            pushSampleToFifo (mono);
        }

        // Estimate tempo (BPM) from the audio itself (not the host clock).  The
        // ×½/×1/×2 multiplier and fine-tune are applied in the editor so they can
        // also modify a held value.
        tempoEstimator.processMono (monoScratch.data(), numSamples);
        publishedBpm.store     ((double) tempoEstimator.getBpm());
        publishedBpmConf.store (tempoEstimator.getConfidence());
    }

   #if JUCE_IOS
    // In the iPad standalone app the input is the microphone and the output is the
    // speaker: passing audio through would howl. Output silence there; as an AUv3
    // effect inside a host the audio still passes through untouched.
    if (wrapperType == wrapperType_Standalone)
        buffer.clear();
   #endif
}

//==============================================================================
ChromaKeyDetector::KeyEstimate KeyDetectorAudioProcessor::getKeyEstimate() const
{
    ChromaKeyDetector::KeyEstimate e;
    e.pitchClass  = publishedKeyPc.load();
    e.isMinor     = publishedKeyMinor.load();
    e.correlation = publishedCorr.load();
    e.confidence  = publishedConf.load();
    return e;
}

std::array<float, 12> KeyDetectorAudioProcessor::getChromaSnapshot() const
{
    std::array<float, 12> out {};
    for (int i = 0; i < 12; ++i)
        out[(size_t) i] = publishedChroma[(size_t) i].load();
    return out;
}

bool KeyDetectorAudioProcessor::copySpectrum (std::vector<float>& dest) const
{
    const juce::SpinLock::ScopedTryLockType sl (spectrumLock);
    if (! sl.isLocked())
        return false;

    dest.resize (publishedSpectrum.size());
    std::copy (publishedSpectrum.begin(), publishedSpectrum.end(), dest.begin());
    return true;
}

//==============================================================================
void KeyDetectorAudioProcessor::getStateInformation (juce::MemoryBlock& destData)
{
    if (auto xml = apvts.copyState().createXml())
        copyXmlToBinary (*xml, destData);
}

void KeyDetectorAudioProcessor::setStateInformation (const void* data, int sizeInBytes)
{
    if (auto xml = getXmlFromBinary (data, sizeInBytes))
        if (xml->hasTagName (apvts.state.getType()))
            apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

//==============================================================================
juce::AudioProcessorEditor* KeyDetectorAudioProcessor::createEditor()
{
    return new KeyDetectorAudioProcessorEditor (*this);
}

//==============================================================================
// This creates new instances of the plugin.
juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new KeyDetectorAudioProcessor();
}
