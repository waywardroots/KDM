// Key Detector - a Fuzzy Audio plug-in.  (c) 2026 Fuzzy Audio LLC. All rights reserved.
// This software is licensed, not sold; use is governed by the End User License
// Agreement (see the EULA PDF in the repository root). Unauthorised copying,
// distribution, or modification is prohibited.

#pragma once

#include <juce_gui_basics/juce_gui_basics.h>

#include <array>
#include <vector>

//==============================================================================
/** A detailed FFT spectrum display.

    The raw magnitude spectrum is resampled into one column per horizontal pixel
    on a log-frequency axis, so every part of the range gets uniform detail (low
    frequencies are interpolated; high frequencies are peak-aggregated across the
    many bins that fall in each column).  Each column has fast-attack / slow-release
    smoothing plus a slowly-falling peak-hold trace, and the view has dB + frequency
    grids. */
class SpectrumDisplay : public juce::Component
{
public:
    SpectrumDisplay() = default;

    /** Feed the latest linear magnitudes (bin k = k * sampleRate / (2*numBins)).
        This advances the per-column smoothing/peak state and repaints. */
    void setSpectrum (const std::vector<float>& magnitudes, double sampleRate);

    void paint (juce::Graphics& g) override;
    void resized() override;

    void mouseMove  (const juce::MouseEvent& e) override;
    void mouseExit  (const juce::MouseEvent& e) override;
    // Touch screens have no hover: press/drag a finger on the spectrum to read
    // the peak under it, lift to hide it again.
    void mouseDown  (const juce::MouseEvent& e) override;
    void mouseDrag  (const juce::MouseEvent& e) override;
    void mouseUp    (const juce::MouseEvent& e) override;

    /** Force the hover read-out at a given x (used for tests / documentation shots). */
    void showHoverAt (int x) { hoverX = x; hovering = true; repaint(); }

private:
    void rebuildColumns();                 // resample mags -> per-pixel columns
    float freqToX (float hz) const noexcept;
    float xToFreq (float x)  const noexcept;
    float dbToY   (float db) const noexcept;
    void  paintHoverReadout (juce::Graphics& g);

    std::vector<float> mags;               // latest raw magnitudes
    double sampleRate = 44100.0;

    std::vector<float> colSmooth;          // per-pixel smoothed magnitude (linear)
    std::vector<float> colPeak;            // per-pixel peak-hold magnitude (linear)
    float dbRef = 2048.0f;                 // magnitude of a 0 dBFS tone (= fftSize/4)

    int  hoverX    = -1;                    // mouse x while hovering (-1 = none)
    bool hovering  = false;

    // Log frequency axis 20 Hz .. 20 kHz, dBFS scale with +12 dB of headroom.
    static constexpr float minFreq = 20.0f;
    static constexpr float maxFreq = 20000.0f;
    static constexpr float minDb   = -90.0f;
    static constexpr float maxDb   =  12.0f;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (SpectrumDisplay)
};

//==============================================================================
/** Draws the 12-bin chroma vector as labelled bars and highlights the tonic. */
class ChromaDisplay : public juce::Component
{
public:
    ChromaDisplay() = default;

    void setChroma (const std::array<float, 12>& newChroma) { chroma = newChroma; }
    void setTonic  (int pitchClass, bool minor) { tonicPc = pitchClass; isMinor = minor; }

    void paint (juce::Graphics& g) override;

private:
    std::array<float, 12> chroma {};
    int  tonicPc = -1;
    bool isMinor = false;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ChromaDisplay)
};

//==============================================================================
/** A guitar/instrument-style tuner: shows the nearest note name and a cents needle
    for the current monophonic pitch.  Blank unless a clear single note is playing. */
class TunerDisplay : public juce::Component
{
public:
    TunerDisplay() = default;

    /** freqHz = detected frequency (0 if none), isPitch = true for a harmonic pitch
        (YIN), false for the loudest-peak fallback (percussion / inharmonic).  The
        processor decides when a reading is valid, so this just needs the value. */
    void setReading (float freqHz, float /*clarity*/, bool isPitchIn) noexcept
    {
        frequency = freqHz;
        isPitch   = isPitchIn;
    }

    void paint (juce::Graphics& g) override;

private:
    float frequency = 0.0f;
    bool  isPitch   = true;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (TunerDisplay)
};
