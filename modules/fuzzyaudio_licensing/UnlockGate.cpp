namespace fuzzyaudio
{

UnlockGate::UnlockGate (LicenseManager& licenseToUse)
    : license (licenseToUse)
{
    const auto productName = license.getConfig().productId;

    titleLabel.setText (productName, juce::dontSendNotification);
    titleLabel.setFont (juce::Font (juce::FontOptions (22.0f, juce::Font::bold)));
    titleLabel.setJustificationType (juce::Justification::centred);
    titleLabel.setColour (juce::Label::textColourId, juce::Colours::white);
    addAndMakeVisible (titleLabel);

    infoLabel.setText ("This product requires a license key. Paste the key you were "
                       "sent after purchase below, then click Unlock.",
                       juce::dontSendNotification);
    infoLabel.setJustificationType (juce::Justification::centredTop);
    infoLabel.setColour (juce::Label::textColourId, juce::Colour (0xffc8c8c8));
    infoLabel.setMinimumHorizontalScale (1.0f);
    addAndMakeVisible (infoLabel);

    keyCaption.setText ("License key", juce::dontSendNotification);
    keyCaption.setColour (juce::Label::textColourId, juce::Colour (0xff9a9a9a));
    addAndMakeVisible (keyCaption);

    keyEntry.setMultiLine (true);
    keyEntry.setReturnKeyStartsNewLine (true);
    keyEntry.setTextToShowWhenEmpty ("Paste your key file here...", juce::Colour (0xff707070));
    keyEntry.setColour (juce::TextEditor::backgroundColourId, juce::Colour (0xff202020));
    keyEntry.setColour (juce::TextEditor::textColourId, juce::Colours::white);
    addAndMakeVisible (keyEntry);

    unlockButton.onClick = [this] { tryUnlock(); };
    addAndMakeVisible (unlockButton);

    statusLabel.setJustificationType (juce::Justification::centred);
    statusLabel.setColour (juce::Label::textColourId, juce::Colour (0xffe0675c));
    addAndMakeVisible (statusLabel);
}

void UnlockGate::tryUnlock()
{
    const auto result = license.applyKey (keyEntry.getText());

    if (result.wasOk() && license.isActivated())
    {
        statusLabel.setColour (juce::Label::textColourId, juce::Colour (0xff35d0a5));
        statusLabel.setText ("License accepted - thank you!", juce::dontSendNotification);

        if (onUnlockSucceeded != nullptr)
            onUnlockSucceeded();

        return;
    }

    statusLabel.setColour (juce::Label::textColourId, juce::Colour (0xffe0675c));
    statusLabel.setText (result.wasOk() ? "That key is not valid for this computer."
                                        : result.getErrorMessage(),
                         juce::dontSendNotification);
}

void UnlockGate::paint (juce::Graphics& g)
{
    g.fillAll (juce::Colour (0xf0101216));   // near-opaque dark cover

    auto panel = getLocalBounds().reduced (24).toFloat();
    g.setColour (juce::Colour (0xff17191e));
    g.fillRoundedRectangle (panel, 10.0f);
    g.setColour (juce::Colour (0xff2b2f37));
    g.drawRoundedRectangle (panel, 10.0f, 1.0f);
}

void UnlockGate::resized()
{
    auto r = getLocalBounds().reduced (44, 36);

    titleLabel.setBounds (r.removeFromTop (30));
    r.removeFromTop (8);
    infoLabel.setBounds (r.removeFromTop (48));
    r.removeFromTop (14);

    keyCaption.setBounds (r.removeFromTop (18));
    keyEntry.setBounds (r.removeFromTop (juce::jmax (80, r.getHeight() - 70)));
    r.removeFromTop (12);

    unlockButton.setBounds (r.removeFromTop (30).removeFromLeft (120));
    r.removeFromTop (8);
    statusLabel.setBounds (r.removeFromTop (20));
}

} // namespace fuzzyaudio
