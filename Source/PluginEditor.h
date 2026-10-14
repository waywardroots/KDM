// Key Detector - a Fuzzy Audio plug-in.  (c) 2026 Fuzzy Audio LLC. All rights reserved.
// This software is licensed, not sold; use is governed by the End User License
// Agreement (see the EULA PDF in the repository root). Unauthorised copying,
// distribution, or modification is prohibited.

#pragma once

#include <juce_audio_processors/juce_audio_processors.h>

#include "PluginProcessor.h"
#include "SpectrumAnalyzer.h"
#include "ConsoleLookAndFeel.h"

//==============================================================================
/** GUI: a spectrum analyser, a chroma bar display, the detected key, plus the
    smoothing / freeze / reset controls.  A Timer polls the processor so the audio
    thread is never blocked by the GUI. */
class KeyDetectorAudioProcessorEditor : public juce::AudioProcessorEditor,
                                        private juce::Timer
{
public:
    explicit KeyDetectorAudioProcessorEditor (KeyDetectorAudioProcessor&);
    ~KeyDetectorAudioProcessorEditor() override;

    void paint (juce::Graphics&) override;
    void resized() override;

private:
    void timerCallback() override;
    void layoutContent();             // lay children out in design coordinates
    double tempoMultFactor() const;   // 0.5 / 1 / 2 from the selector
    void showUnlockGateIfLocked();    // overlay the UI until a valid key is applied

    // The UI is laid out at a fixed "design size" and the whole thing is scaled to
    // fill the (resizable) editor, so every element — including fonts — scales.
    static constexpr int designWidth  = 640;
    static constexpr int designHeight = 500;

    // A plain container whose painting is delegated to a lambda (draws the
    // background + title); it holds every child and is scaled by the editor.
    struct Content : juce::Component
    {
        std::function<void (juce::Graphics&)> onPaint;
        void paint (juce::Graphics& g) override { if (onPaint) onPaint (g); }
    };

    KeyDetectorAudioProcessor& processorRef;
    ConsoleLookAndFeel consoleLnf;   // declared early so it outlives the widgets
    juce::Image logo;                // embedded logo (loaded in the constructor)
    Content content;

    SpectrumDisplay spectrum;
    ChromaDisplay   chroma;
    TunerDisplay    tuner;
    juce::TextButton spectrumFreezeButton { "Freeze" }; // holds the spectrum display

    juce::Label keyLabel;        // big "F# minor"
    juce::Label detailLabel;     // correlation / confidence
    juce::Label bpmLabel;        // host tempo readout

    juce::Slider      smoothingSlider;
    juce::ToggleButton freezeButton { "Freeze" };
    juce::TextButton   resetButton  { "Reset" };
    juce::Label        smoothingLabel { {}, "SMOOTHING" };
    juce::Label        freezeLabel    { {}, "FREEZE" };
    juce::Label        resetLabel     { {}, "RESET" };

    juce::ComboBox     tunerModeBox;
    juce::Label        tunerModeLabel { {}, "Tuner" };
    juce::ComboBox     tempoMultBox;   // BPM ×½ / ×1 / ×2
    juce::TextButton   tapButton  { "Tap" };
    juce::TextButton   holdButton { "Hold" };
    juce::TextButton   bpmDownButton { "-" };
    juce::TextButton   bpmUpButton   { "+" };

    using SliderAttachment = juce::AudioProcessorValueTreeState::SliderAttachment;
    using ButtonAttachment = juce::AudioProcessorValueTreeState::ButtonAttachment;
    using ComboBoxAttachment = juce::AudioProcessorValueTreeState::ComboBoxAttachment;
    std::unique_ptr<SliderAttachment> smoothingAttachment;
    std::unique_ptr<ButtonAttachment> freezeAttachment;
    std::unique_ptr<ComboBoxAttachment> tunerModeAttachment;
    std::unique_ptr<ComboBoxAttachment> tempoMultAttachment;

    std::vector<float> spectrumScratch; // reused each timer tick

   #if KEYDETECTOR_USE_LICENSING
    std::unique_ptr<fuzzyaudio::UnlockGate> unlockGate; // shown while unlicensed
   #endif

    // Tap-tempo + BPM hold/fine-tune state (UI-side).
    std::vector<double> tapTimes;        // recent tap timestamps (ms)
    double  lastTapMs       = 0.0;
    double  tappedBpm       = 0.0;
    double  currentLiveBase = 0.0;       // latest live (pre-multiplier) BPM
    double  heldBaseBpm     = 0.0;       // base captured when Hold engaged
    double  fineOffset      = 0.0;       // +/- fine-tune added while held

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (KeyDetectorAudioProcessorEditor)
};
