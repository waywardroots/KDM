#pragma once

namespace fuzzyaudio
{

/**
    A full-panel overlay that asks the user to activate the product.

    It shows a box to paste the license key they were sent after purchase and an
    "Unlock" button.  On success it calls onUnlockSucceeded() so the host editor can
    reveal the real UI.

    It is product-agnostic: it reads everything it needs (product name, website)
    from the LicenseManager it is given, so the same component works in any plug-in.
*/
class UnlockGate : public juce::Component
{
public:
    explicit UnlockGate (LicenseManager& licenseToUse);

    /** Called once a valid key has been applied and the product is unlocked. */
    std::function<void()> onUnlockSucceeded;

    void paint (juce::Graphics&) override;
    void resized() override;

private:
    void tryUnlock();

    LicenseManager& license;

    juce::Label    titleLabel, infoLabel, keyCaption, statusLabel;
    juce::TextEditor keyEntry;
    juce::TextButton unlockButton { "Unlock" };

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (UnlockGate)
};

} // namespace fuzzyaudio
