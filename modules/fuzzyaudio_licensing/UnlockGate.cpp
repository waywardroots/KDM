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

    infoLabel.setText ("This product requires a license key. Copy your Machine ID below, "
                       "enter it on our website to generate your key, then paste the key here.",
                       juce::dontSendNotification);
    infoLabel.setJustificationType (juce::Justification::centredTop);
    infoLabel.setColour (juce::Label::textColourId, juce::Colour (0xffc8c8c8));
    infoLabel.setMinimumHorizontalScale (1.0f);
    addAndMakeVisible (infoLabel);

    machineCaption.setText ("Machine ID", juce::dontSendNotification);
    machineCaption.setColour (juce::Label::textColourId, juce::Colour (0xff9a9a9a));
    addAndMakeVisible (machineCaption);

    machineIdBox.setReadOnly (true);
    machineIdBox.setCaretVisible (false);
    machineIdBox.setText (license.getThisMachineID(), juce::dontSendNotification);
    machineIdBox.setColour (juce::TextEditor::backgroundColourId, juce::Colour (0xff202020));
    machineIdBox.setColour (juce::TextEditor::textColourId, juce::Colours::white);
    addAndMakeVisible (machineIdBox);

    copyIdButton.onClick = [this]
    {
        juce::SystemClipboard::copyTextToClipboard (license.getThisMachineID());
        statusLabel.setColour (juce::Label::textColourId, juce::Colour (0xff35d0a5));
        statusLabel.setText ("Machine ID copied to clipboard.", juce::dontSendNotification);
    };
    addAndMakeVisible (copyIdButton);

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

    buyButton.onClick = [this] { license.getConfig().websiteURL.launchInDefaultBrowser(); };
    addAndMakeVisible (buyButton);

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
    r.removeFromTop (6);
    infoLabel.setBounds (r.removeFromTop (54));
    r.removeFromTop (10);

    machineCaption.setBounds (r.removeFromTop (18));
    {
        auto row = r.removeFromTop (28);
        copyIdButton.setBounds (row.removeFromRight (80).reduced (0, 2));
        row.removeFromRight (8);
        machineIdBox.setBounds (row);
    }
    r.removeFromTop (12);

    keyCaption.setBounds (r.removeFromTop (18));
    keyEntry.setBounds (r.removeFromTop (juce::jmax (60, r.getHeight() - 96)));
    r.removeFromTop (10);

    {
        auto row = r.removeFromTop (30);
        unlockButton.setBounds (row.removeFromLeft (120));
        buyButton.setBounds (row.removeFromRight (160));
    }
    r.removeFromTop (8);
    statusLabel.setBounds (r.removeFromTop (20));
}

} // namespace fuzzyaudio
