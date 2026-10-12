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

juce::Result LicenseManager::applyKey (const juce::String& keyFileText)
{
    return applyKeyFile (keyFileText.trim());
}

} // namespace fuzzyaudio
