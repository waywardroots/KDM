#pragma once

namespace fuzzyaudio
{

/**
    Offline license-key manager for a single product.

    This is a thin, reusable wrapper around juce::OnlineUnlockStatus configured for
    *offline* key files: your website signs a key file with your RSA private key and
    this class verifies it against the embedded public key.  No runtime server is
    contacted - the user simply pastes the key they were sent.

    To reuse in another plug-in, just construct it with that product's Config
    (product id + public key); nothing else is product-specific.

    Machine locking is optional and controlled by Config::activationToken:
      * Non-empty (default) -> *paste-only*: every key is signed with this same
        fixed token, so a pasted key activates on any computer (track the "1 key =
        1 purchase" rule on your website). The user never has to find a machine ID.
      * Empty -> machine-locked: keys must carry the buyer's machine ID (from
        getThisMachineID()) and unlock only that computer.
*/
class LicenseManager : public juce::OnlineUnlockStatus
{
public:
    struct Config
    {
        juce::String productId;                 ///< Must match the key file's "app" field.
        juce::String publicKey;                 ///< RSA public key, "part1,part2" (from keygen).
        juce::String vendorName  { "Fuzzy Audio" };   ///< Settings folder / company name.
        juce::String appName;                   ///< Settings file name (defaults to productId).
        juce::String websiteName { "fuzzyaudio.example" }; ///< Shown to the user.
        juce::URL    websiteURL  { juce::URL ("https://fuzzyaudio.example") }; ///< "Buy" link.

        /** Fixed token used as the "machine number" for paste-only (non machine-
            locked) keys. Your website must sign every key with this exact string.
            Set to empty to switch to real machine-locking instead. */
        juce::String activationToken { "license" };
    };

    explicit LicenseManager (Config configToUse);

    /** True once a valid (non-expired) key has been applied. */
    bool isActivated();

    /** The machine ID to send to your website (only used when activationToken is
        empty, i.e. machine-locked mode). */
    juce::String getThisMachineID();

    /** Convenience: apply a pasted key file and persist the unlocked state.
        Returns ok() on success, otherwise a message describing the failure. */
    juce::Result applyKey (const juce::String& keyFileText);

    const Config& getConfig() const noexcept { return config; }

    //==============================================================================
    // juce::OnlineUnlockStatus - everything needed for offline key-file unlocking.
    juce::String getProductID() override                              { return config.productId; }
    bool doesProductIDMatch (const juce::String& returned) override   { return returned == config.productId; }
    juce::RSAKey getPublicKey() override                              { return juce::RSAKey (config.publicKey); }
    juce::StringArray getLocalMachineIDs() override;
    void saveState (const juce::String& state) override;
    juce::String getState() override;
    juce::String getWebsiteName() override                            { return config.websiteName; }
    juce::URL getServerAuthenticationURL() override                   { return config.websiteURL; }
    juce::String readReplyFromWebserver (const juce::String&, const juce::String&) override { return {}; }

private:
    juce::PropertiesFile* settings();

    Config config;
    juce::ApplicationProperties appProperties;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (LicenseManager)
};

} // namespace fuzzyaudio
