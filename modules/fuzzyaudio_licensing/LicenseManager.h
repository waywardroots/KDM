#pragma once

namespace fuzzyaudio
{

/**
    Offline, machine-locked license-key manager for a single product.

    This is a thin, reusable wrapper around juce::OnlineUnlockStatus configured for
    *offline* key files: your website signs a key file with your RSA private key
    (bound to the buyer's machine ID), and this class verifies it against the
    embedded public key.  No runtime server is contacted.

    To reuse in another plug-in, just construct it with that product's Config
    (product id + public key); nothing else is product-specific.

    The key file carries the allowed machine IDs, so a key issued for one machine
    unlocks only that machine - giving you the "1 licence = 1 computer" rule for
    free.
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
    };

    explicit LicenseManager (Config configToUse);

    /** True once a valid (non-expired, machine-matching) key has been applied. */
    bool isActivated();

    /** The single machine ID the user must send to your website so it can issue a
        key locked to this computer.  Empty only if the host blocks machine info. */
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
