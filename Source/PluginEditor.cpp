// Key Detector - a Fuzzy Audio plug-in.  (c) 2026 Fuzzy Audio LLC. All rights reserved.
// This software is licensed, not sold; use is governed by the End User License
// Agreement (see the EULA PDF in the repository root). Unauthorised copying,
// distribution, or modification is prohibited.

#include "PluginEditor.h"
#include "BinaryData.h"

//==============================================================================
KeyDetectorAudioProcessorEditor::KeyDetectorAudioProcessorEditor (KeyDetectorAudioProcessor& p)
    : AudioProcessorEditor (&p), processorRef (p)
{
    setLookAndFeel (&consoleLnf);
    logo = juce::ImageCache::getFromMemory (BinaryData::logo_png, BinaryData::logo_pngSize);

    // Everything lives inside `content`, which is laid out at the fixed design size
    // and scaled to fill the (resizable) editor.
    addAndMakeVisible (content);
    content.onPaint = [this] (juce::Graphics& g)
    {
        const int W = designWidth, H = designHeight;

        // Brushed-metal panel gradient.
        g.setGradientFill (juce::ColourGradient (juce::Colour (console::bgTop), 0.0f, 0.0f,
                                                 juce::Colour (console::bgBottomC), 0.0f, (float) H, false));
        g.fillRect (0, 0, W, H);
        g.setColour (juce::Colours::white.withAlpha (0.012f));
        for (int y = 48; y < H; y += 2)
            g.drawHorizontalLine (y, 0.0f, (float) W);

        // Title bar.
        g.setGradientFill (juce::ColourGradient (juce::Colour (console::barTop), 0.0f, 0.0f,
                                                 juce::Colour (console::barBottom), 0.0f, 44.0f, false));
        g.fillRect (0, 0, W, 44);
        g.setColour (juce::Colour (console::accent));
        g.fillRect (0, 44, W, 2);
        g.setColour (juce::Colour (console::shadow));
        g.fillRect (0, 46, W, 1);

        // Logo image (falls back to a drawn mark if the image failed to load).
        const juce::Rectangle<float> logoBox (14.0f, 8.0f, 28.0f, 28.0f);
        if (logo.isValid())
            g.drawImage (logo, logoBox, juce::RectanglePlacement::centred);
        else
        {
            g.setColour (juce::Colour (console::accent));
            g.fillRoundedRectangle (logoBox, 3.0f);
        }

        g.setColour (juce::Colour (console::text));
        g.setFont (juce::Font (juce::FontOptions (15.0f, juce::Font::bold)));
        g.drawText ("KEY  DETECTOR", 50, 13, 200, 18, juce::Justification::centredLeft, false);

        // Copyright, bottom-right corner (clear of the resize grip).
        g.setColour (juce::Colour (console::textDim));
        g.setFont (juce::Font (juce::FontOptions (9.5f)));
        g.drawText (juce::String::fromUTF8 ("\xc2\xa9 2026 Fuzzy Audio"),
                    W - 196, H - 13, 170, 11, juce::Justification::centredRight, false);
    };

    content.addAndMakeVisible (spectrum);
    content.addAndMakeVisible (chroma);
    content.addAndMakeVisible (tuner);

    // --- Big detected-key readout ----------------------------------------------
    keyLabel.setJustificationType (juce::Justification::centred);
    keyLabel.setFont (juce::Font (juce::FontOptions (40.0f, juce::Font::bold)));
    keyLabel.setColour (juce::Label::textColourId, juce::Colours::white);
    keyLabel.setText ("--", juce::dontSendNotification);
    content.addAndMakeVisible (keyLabel);

    detailLabel.setJustificationType (juce::Justification::centred);
    detailLabel.setFont (juce::Font (juce::FontOptions (11.0f)));
    detailLabel.setColour (juce::Label::textColourId, juce::Colour (console::textDim));
    detailLabel.setText ("waiting...", juce::dontSendNotification);
    content.addAndMakeVisible (detailLabel);

    // Tempo readout (top-right of the header).
    bpmLabel.setJustificationType (juce::Justification::centredRight);
    bpmLabel.setFont (juce::Font (juce::FontOptions (18.0f, juce::Font::bold)));
    bpmLabel.setColour (juce::Label::textColourId, juce::Colour (0xff2bd1a4));
    bpmLabel.setText ("-- BPM", juce::dontSendNotification);
    content.addAndMakeVisible (bpmLabel);

    // BPM octave multiplier (fixes half/double-time; also rescales a held BPM).
    tempoMultBox.addItemList ({ "x0.5", "x1", "x2" }, 1);
    tempoMultBox.setTooltip ("Halve / double the BPM (also rescales a held value)");
    content.addAndMakeVisible (tempoMultBox);
    tempoMultAttachment = std::make_unique<ComboBoxAttachment> (
        processorRef.apvts, "tempoMult", tempoMultBox);

    // Tap tempo (shortcut: T): derive BPM from the spacing of button presses.
    tapButton.setTooltip ("Tap tempo (shortcut: T)");
    tapButton.addShortcut (juce::KeyPress ('t'));
    content.addAndMakeVisible (tapButton);
    tapButton.onClick = [this]
    {
        const double now = juce::Time::getMillisecondCounterHiRes();
        if (now - lastTapMs > 2000.0)   // long gap -> start a fresh tap session
            tapTimes.clear();
        lastTapMs = now;
        tapTimes.push_back (now);
        if (tapTimes.size() > 8)
            tapTimes.erase (tapTimes.begin());

        if (tapTimes.size() >= 2)
        {
            const double span = tapTimes.back() - tapTimes.front();
            const double avg  = span / (double) (tapTimes.size() - 1);
            if (avg > 0.0)
                tappedBpm = juce::jlimit (30.0, 300.0, 60000.0 / avg);
        }

        holdButton.setToggleState (false, juce::dontSendNotification);
    };

    // Hold (shortcut: H): freeze the BPM read-out; captures the current base value.
    holdButton.setClickingTogglesState (true);
    holdButton.setTooltip ("Freeze the BPM (shortcut: H). Then use -/+ and x0.5/x1/x2.");
    holdButton.addShortcut (juce::KeyPress ('h'));
    content.addAndMakeVisible (holdButton);
    holdButton.onClick = [this]
    {
        if (holdButton.getToggleState())
        {
            heldBaseBpm = currentLiveBase > 0.0 ? currentLiveBase
                        : (tappedBpm > 0.0 ? tappedBpm : 120.0);
            fineOffset  = 0.0;
        }
    };

    // Fine-tune -/+ (engages Hold if not already held).
    auto nudge = [this] (double delta)
    {
        if (! holdButton.getToggleState())
        {
            heldBaseBpm = currentLiveBase > 0.0 ? currentLiveBase
                        : (tappedBpm > 0.0 ? tappedBpm : 120.0);
            fineOffset  = 0.0;
            holdButton.setToggleState (true, juce::dontSendNotification);
        }
        fineOffset += delta;
    };
    bpmDownButton.setTooltip ("Fine-tune BPM down (-0.1)");
    bpmUpButton  .setTooltip ("Fine-tune BPM up (+0.1)");
    bpmDownButton.onClick = [nudge] { nudge (-0.1); };
    bpmUpButton  .onClick = [nudge] { nudge (+0.1); };
    content.addAndMakeVisible (bpmDownButton);
    content.addAndMakeVisible (bpmUpButton);

    setWantsKeyboardFocus (true); // so the T / H shortcuts are received

    // --- Controls (bottom strip) -----------------------------------------------
    // Small screened caption under each control, all on one baseline.
    auto styleCaption = [this] (juce::Label& l)
    {
        l.setJustificationType (juce::Justification::centred);
        l.setFont (juce::Font (juce::FontOptions (11.0f)));
        l.setColour (juce::Label::textColourId, juce::Colour (console::textDim));
        content.addAndMakeVisible (l);
    };

    smoothingSlider.setSliderStyle (juce::Slider::RotaryHorizontalVerticalDrag);
    smoothingSlider.setTextBoxStyle (juce::Slider::NoTextBox, false, 0, 0);
    content.addAndMakeVisible (smoothingSlider);
    smoothingAttachment = std::make_unique<SliderAttachment> (
        processorRef.apvts, "smoothing", smoothingSlider);
    styleCaption (smoothingLabel);

    freezeButton.setButtonText ({});           // LED only; caption is below
    content.addAndMakeVisible (freezeButton);
    freezeAttachment = std::make_unique<ButtonAttachment> (
        processorRef.apvts, "freeze", freezeButton);
    styleCaption (freezeLabel);

    resetButton.setButtonText ({});            // push button; caption is below
    resetButton.onClick = [this] { processorRef.requestReset(); };
    content.addAndMakeVisible (resetButton);
    styleCaption (resetLabel);

    // Tuner mode selector (Auto / Pitch / Peak).
    tunerModeBox.addItemList ({ "Auto", "Pitch", "Peak" }, 1);
    content.addAndMakeVisible (tunerModeBox);
    tunerModeAttachment = std::make_unique<ComboBoxAttachment> (
        processorRef.apvts, "tunerMode", tunerModeBox);
    styleCaption (tunerModeLabel);
    tunerModeLabel.setText ("TUNER", juce::dontSendNotification);

    spectrumScratch.reserve ((size_t) KeyDetectorAudioProcessor::numBins);

    // Freeze toggle for the spectrum analyser (holds the current trace so you can
    // hover/inspect it).  Sits in the top-right corner of the spectrum, on top.
    spectrumFreezeButton.setClickingTogglesState (true);
    spectrumFreezeButton.setTooltip ("Freeze the spectrum analyser display");
    spectrumFreezeButton.setColour (juce::TextButton::buttonOnColourId, juce::Colour (0xff2bd1a4));
    content.addAndMakeVisible (spectrumFreezeButton);

    // Make the editor resizable (corner grip + host edge-resize), keeping the
    // original aspect ratio so the scaled layout always fits.
    setResizable (true, true);
    setResizeLimits (designWidth * 3 / 4, designHeight * 3 / 4,  // 0.75x
                     designWidth * 2,     designHeight * 2);     // 2x
    if (auto* c = getConstrainer())
        c->setFixedAspectRatio ((double) designWidth / (double) designHeight);

    setSize (designWidth, designHeight);
    startTimerHz (30);

    showUnlockGateIfLocked();
}

void KeyDetectorAudioProcessorEditor::showUnlockGateIfLocked()
{
    if (processorRef.license.isActivated())
        return;

    unlockGate = std::make_unique<fuzzyaudio::UnlockGate> (processorRef.license);
    unlockGate->onUnlockSucceeded = [this]
    {
        unlockGate.reset();   // reveal the real UI once a valid key is applied
    };
    addAndMakeVisible (*unlockGate);
    unlockGate->setBounds (getLocalBounds());
}

KeyDetectorAudioProcessorEditor::~KeyDetectorAudioProcessorEditor()
{
    stopTimer();
    setLookAndFeel (nullptr);
}

//==============================================================================
void KeyDetectorAudioProcessorEditor::paint (juce::Graphics& g)
{
    g.fillAll (juce::Colour (console::bgBottomC)); // behind the scaled content
}

void KeyDetectorAudioProcessorEditor::resized()
{
    // Scale the fixed-size content to fill the current (resizable) editor.
    const float scale = (float) getWidth() / (float) designWidth;
    content.setBounds (0, 0, designWidth, designHeight);
    content.setTransform (juce::AffineTransform::scale (scale));
    layoutContent();

    if (unlockGate != nullptr)
        unlockGate->setBounds (getLocalBounds());
}

void KeyDetectorAudioProcessorEditor::layoutContent()
{
    auto area = juce::Rectangle<int> (0, 0, designWidth, designHeight).reduced (12);

    // Header row (top-right): [Tap][Hold]  [-] BPM [+]  [×½/×1/×2]
    {
        auto header = juce::Rectangle<int> (area.getX(), 10, area.getWidth(), 26);
        tempoMultBox.setBounds (header.removeFromRight (52));
        header.removeFromRight (6);
        bpmUpButton.setBounds (header.removeFromRight (24));
        bpmLabel.setBounds (header.removeFromRight (96));
        bpmDownButton.setBounds (header.removeFromRight (24));
        header.removeFromRight (8);
        holdButton.setBounds (header.removeFromRight (44));
        header.removeFromRight (4);
        tapButton.setBounds (header.removeFromRight (40));
    }

    area.removeFromTop (40); // header

    // Bottom control strip: a row of controls, each vertically centred in its own
    // column, with all captions aligned on one baseline underneath.
    auto strip = area.removeFromBottom (76);
    {
        auto captions = strip.removeFromBottom (14);
        strip.removeFromBottom (2);
        auto ctl = strip; // control row

        const int gap = 8;
        auto column = [&] (int wdt) -> std::pair<juce::Rectangle<int>, juce::Rectangle<int>>
        {
            auto c = ctl.removeFromLeft (wdt);
            auto p = captions.removeFromLeft (wdt);
            ctl.removeFromLeft (gap);
            captions.removeFromLeft (gap);
            return { c, p };
        };

        auto [sC, sP] = column (66);
        smoothingSlider.setBounds (sC.withSizeKeepingCentre (46, 46));
        smoothingLabel.setBounds (sP);

        auto [fC, fP] = column (58);
        freezeButton.setBounds (fC.withSizeKeepingCentre (30, 30));
        freezeLabel.setBounds (fP);

        auto [rC, rP] = column (58);
        resetButton.setBounds (rC.withSizeKeepingCentre (46, 26));
        resetLabel.setBounds (rP);

        auto [tC, tP] = column (94);
        tunerModeBox.setBounds (tC.withSizeKeepingCentre (92, 26));
        tunerModeLabel.setBounds (tP);

        // Key column takes the remainder.
        keyLabel.setBounds (ctl);
        detailLabel.setBounds (captions);
    }

    area.removeFromBottom (10);
    tuner.setBounds (area.removeFromBottom (68));
    area.removeFromBottom (10);
    chroma.setBounds (area.removeFromBottom (110));
    area.removeFromBottom (10);
    spectrum.setBounds (area);
    spectrumFreezeButton.setBounds (area.getRight() - 66, area.getY() + 4, 60, 18);
}

//==============================================================================
void KeyDetectorAudioProcessorEditor::timerCallback()
{
    // Update the spectrum unless it is frozen (then it holds the current trace).
    if (! spectrumFreezeButton.getToggleState())
        if (processorRef.copySpectrum (spectrumScratch))
            spectrum.setSpectrum (spectrumScratch, processorRef.getCurrentSampleRate());

    const auto ch = processorRef.getChromaSnapshot();
    chroma.setChroma (ch);

    const auto est = processorRef.getKeyEstimate();
    chroma.setTonic (est.pitchClass, est.isMinor);
    chroma.repaint();

    // Tempo read-out.  Colour: green = audio, blue = tapped, amber = held.
    // The ×½/×1/×2 multiplier and the -/+ fine-tune apply to whatever the base is
    // (live estimate/tap, or the value captured when Hold engaged).
    const double now      = juce::Time::getMillisecondCounterHiRes();
    const bool   tapValid = tappedBpm > 0.0 && (now - lastTapMs) < 5000.0;
    const double factor   = tempoMultFactor();

    const double audioBpm = processorRef.getBpm();
    const bool   audioOk  = audioBpm > 0.0 && processorRef.getBpmConfidence() >= 0.25f;
    currentLiveBase = tapValid ? tappedBpm : (audioOk ? audioBpm : 0.0);

    juce::String txt;
    juce::Colour bpmColour;
    if (holdButton.getToggleState())
    {
        const double v = juce::jlimit (20.0, 400.0, heldBaseBpm * factor + fineOffset);
        txt = juce::String (v, 1) + " BPM";
        bpmColour = juce::Colour (0xffffc857);            // amber = held
    }
    else if (currentLiveBase > 0.0)
    {
        txt = juce::String (currentLiveBase * factor, 1) + " BPM";
        bpmColour = tapValid ? juce::Colour (0xff6ea8ff)  // blue = tapped
                             : juce::Colour (0xff2bd1a4);  // green = audio
    }
    else
    {
        txt = "-- BPM";
        bpmColour = juce::Colours::white.withAlpha (0.4f);
    }
    bpmLabel.setText (txt, juce::dontSendNotification);
    bpmLabel.setColour (juce::Label::textColourId, bpmColour);

    // Tuner (falls back to the loudest spectral peak for percussion/inharmonic input).
    tuner.setReading (processorRef.getTunerFrequency(),
                      processorRef.getTunerClarity(),
                      processorRef.getTunerIsPitch());
    tuner.repaint();

    // Only show a key when the chroma is tonal enough.  Percussion / atonal input
    // gives a flat chroma that correlates poorly with any key profile, so show "--".
    float chromaSum = 0.0f;
    for (float v : ch)
        chromaSum += v;

    if (chromaSum > 1.0e-4f && est.correlation >= 0.6f)
    {
        keyLabel.setText (est.noteName(), juce::dontSendNotification);
        detailLabel.setText ("corr " + juce::String (est.correlation, 2)
                                 + "  /  conf " + juce::String (juce::roundToInt (est.confidence * 100.0f)) + "%",
                             juce::dontSendNotification);
    }
    else
    {
        keyLabel.setText ("--", juce::dontSendNotification);
        detailLabel.setText (chromaSum > 1.0e-4f ? "no clear key" : "waiting...",
                             juce::dontSendNotification);
    }
}

double KeyDetectorAudioProcessorEditor::tempoMultFactor() const
{
    switch (tempoMultBox.getSelectedId()) // ids: 1=x0.5, 2=x1, 3=x2
    {
        case 1:  return 0.5;
        case 3:  return 2.0;
        default: return 1.0;
    }
}
