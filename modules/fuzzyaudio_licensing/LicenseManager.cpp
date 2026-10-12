namespace fuzzyaudio
{

LicenseManager::LicenseManager (Config configToUse)
    : config (std::move (configToUse))
{
    juce::PropertiesFile::Options options;
    options.applicationName     = config.appName.isNotEmpty() ? config.appName : config.productId;
    options.filenameSuffix      = "settings";
    options.folderName          = config.vendorName;
    options.osxLibrarySubFolder = "Application Support";
    appProperties.setStorageParameters (options);
}

juce::PropertiesFile* LicenseManager::settings()
{
    return appProperties.getUserSettings();
}

void LicenseManager::saveState (const juce::String& state)
{
    if (auto* s = settings())
    {
        s->setValue ("licenseKey", state);
        s->saveIfNeeded();
    }
}

juce::String LicenseManager::getState()
{
    if (auto* s = settings())
        return s->getValue ("licenseKey", {});

    return {};
}

bool LicenseManager::isActivated()
{
    return isUnlocked();
}

juce::String LicenseManager::getThisMachineID()
{
    auto ids = getLocalMachineIDs();
    return ids.isEmpty() ? juce::String() : ids[0];
}

juce::StringArray LicenseManager::getLocalMachineIDs()
{
    // Paste-only mode: report a fixed token so any key signed with that token
    // activates on any computer. Empty token -> fall back to real machine locking.
    if (config.activationToken.isNotEmpty())
        return juce::StringArray (config.activationToken);

    return juce::OnlineUnlockStatus::getLocalMachineIDs();
}

juce::Result LicenseManager::applyKey (const juce::String& keyFileText)
{
    return applyKeyFile (keyFileText.trim());
}

} // namespace fuzzyaudio
