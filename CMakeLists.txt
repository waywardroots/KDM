cmake_minimum_required(VERSION 3.22)

project(KeyDetector VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ==============================================================================
# Locate JUCE.
#   * By default we use a sibling JUCE checkout (../JUCE) via add_subdirectory.
#   * If it isn't there (or KEYDETECTOR_FETCH_JUCE=ON) we download a pinned
#     release with FetchContent so the project builds from a clean clone.
# ==============================================================================
option(KEYDETECTOR_FETCH_JUCE "Download JUCE via FetchContent instead of a local copy" OFF)
option(KEYDETECTOR_BUILD_TESTS "Build the standalone DSP unit test (no JUCE needed)"    ON)

if(NOT KEYDETECTOR_FETCH_JUCE AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../JUCE/CMakeLists.txt")
    message(STATUS "KeyDetector: using local JUCE at ${CMAKE_CURRENT_SOURCE_DIR}/../JUCE")
    add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../JUCE" "${CMAKE_BINARY_DIR}/JUCE")
else()
    message(STATUS "KeyDetector: fetching JUCE 8.0.9 via FetchContent")
    include(FetchContent)
    FetchContent_Declare(JUCE
        GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
        GIT_TAG        8.0.9
        GIT_SHALLOW    TRUE)
    FetchContent_MakeAvailable(JUCE)
endif()

# ==============================================================================
# Reusable licensing module (offline, machine-locked license keys).
# Lives in modules/fuzzyaudio_licensing so it can be dropped into any Fuzzy Audio
# plug-in; this project is just its first consumer.
# ==============================================================================
juce_add_module("${CMAKE_CURRENT_SOURCE_DIR}/modules/fuzzyaudio_licensing")

# ==============================================================================
# Optional AAX (Pro Tools) support.
#
# AAX requires Avid's proprietary AAX SDK, which you must obtain from Avid
# (https://developer.avid.com) - it cannot be auto-downloaded like JUCE, nor
# redistributed in this repo.  Point KEYDETECTOR_AAX_SDK_PATH at your local SDK
# checkout (or set the AAX_SDK_PATH environment variable) to add AAX to the build;
# leave it unset and the plugin builds AU/VST3/Standalone exactly as before.
#
# NOTE: a built .aaxplugin must still be signed with PACE's `wraptool` before
# retail Pro Tools will load it (see installer/README.md).
# ==============================================================================
set(KEYDETECTOR_AAX_SDK_PATH "" CACHE PATH "Path to the Avid AAX SDK (enables the AAX build)")
if(NOT KEYDETECTOR_AAX_SDK_PATH AND DEFINED ENV{AAX_SDK_PATH})
    set(KEYDETECTOR_AAX_SDK_PATH "$ENV{AAX_SDK_PATH}")
endif()

# ==============================================================================
# iPad build.
#
# Configure with  -G Xcode -DCMAKE_SYSTEM_NAME=iOS  and the same target becomes a
# standalone iPad app that analyses an external source (e.g. a DJ mixer's USB
# audio or a USB audio interface). See "iPad app" in README.md.
# ==============================================================================
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(KEYDETECTOR_IOS TRUE)
else()
    set(KEYDETECTOR_IOS FALSE)
endif()

# Desktop builds are unlocked with the offline license-key module. App Store apps
# must be sold through the App Store (paid app or In-App Purchase), so the key gate
# is compiled out of the iPad build by default.
if(KEYDETECTOR_IOS)
    option(KEYDETECTOR_USE_LICENSING "Require a Fuzzy Audio license key to unlock" OFF)
else()
    option(KEYDETECTOR_USE_LICENSING "Require a Fuzzy Audio license key to unlock" ON)
endif()

if(KEYDETECTOR_IOS)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "Minimum iPadOS version")
    # Your Apple Developer Team ID (10 characters, from developer.apple.com ->
    # Membership). Needed to sign and run on a real iPad; leave empty for a
    # compile-only (unsigned) build such as CI.
    set(KEYDETECTOR_IOS_TEAM_ID "" CACHE STRING "Apple Developer Team ID for code signing")
    if(KEYDETECTOR_IOS_TEAM_ID)
        set(CMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${KEYDETECTOR_IOS_TEAM_ID}")
        set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic")
    endif()
    set(KEYDETECTOR_FORMATS Standalone)
    # App icon. The App Store needs a 1024x1024 icon: drop one in as
    # Resources/AppIcon.png and it is used instead of the 256px logo.
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/Resources/AppIcon.png")
        set(KEYDETECTOR_IOS_ICON_ARGS ICON_BIG "${CMAKE_CURRENT_SOURCE_DIR}/Resources/AppIcon.png")
    else()
        set(KEYDETECTOR_IOS_ICON_ARGS ICON_BIG "${CMAKE_CURRENT_SOURCE_DIR}/Resources/logo.png")
    endif()
else()
    set(KEYDETECTOR_FORMATS AU VST3 Standalone)
endif()

if(NOT KEYDETECTOR_IOS AND KEYDETECTOR_AAX_SDK_PATH AND EXISTS "${KEYDETECTOR_AAX_SDK_PATH}")
    message(STATUS "KeyDetector: AAX enabled (SDK at ${KEYDETECTOR_AAX_SDK_PATH})")
    juce_set_aax_sdk_path("${KEYDETECTOR_AAX_SDK_PATH}")
    list(APPEND KEYDETECTOR_FORMATS AAX)
else()
    message(STATUS "KeyDetector: AAX disabled (set KEYDETECTOR_AAX_SDK_PATH to enable)")
endif()

# ==============================================================================
# The plugin target.
#
# IS_SYNTH is FALSE: a key detector must *receive* audio to analyse, so it is an
# analyser/effect (it appears on an audio track's insert chain and passes audio
# through unchanged).  A sound-generating "instrument" has no audio input, which
# is the opposite of what this plugin needs.  Flip IS_SYNTH/NEEDS_MIDI_INPUT if
# you specifically need it to register as a VSTi in your host.
# ==============================================================================
juce_add_plugin(KeyDetector
    PLUGIN_MANUFACTURER_CODE    Jatc
    PLUGIN_CODE                 Kdet
    COMPANY_NAME                "Fuzzy Audio"
    BUNDLE_ID                   com.jamesandthecat.keydetector
    IS_SYNTH                    FALSE
    NEEDS_MIDI_INPUT            FALSE
    NEEDS_MIDI_OUTPUT           FALSE
    IS_MIDI_EFFECT              FALSE
    EDITOR_WANTS_KEYBOARD_FOCUS TRUE
    COPY_PLUGIN_AFTER_BUILD     FALSE
    VST3_CATEGORIES             "Analyzer" "Fx"
    AU_MAIN_TYPE                "kAudioUnitType_Effect"
    AAX_CATEGORY                "AAX_ePlugInCategory_Effect"
    FORMATS                     ${KEYDETECTOR_FORMATS}
    PRODUCT_NAME                "Key Detector"
    # --- iPad-only settings (ignored by desktop builds) -------------------------
    TARGETED_DEVICE_FAMILY      "2"                  # iPad
    MICROPHONE_PERMISSION_ENABLED TRUE
    MICROPHONE_PERMISSION_TEXT  "Key Detector listens to incoming audio to detect its musical key, pitch and tempo. Audio is analysed on the device and never recorded or sent anywhere."
    BACKGROUND_AUDIO_ENABLED    TRUE                 # keep analysing when the app is backgrounded
    STATUS_BAR_HIDDEN           TRUE
    REQUIRES_FULL_SCREEN        FALSE                # allow Split View / Stage Manager
    IPAD_SCREEN_ORIENTATIONS    UIInterfaceOrientationLandscapeLeft
                                UIInterfaceOrientationLandscapeRight
                                UIInterfaceOrientationPortrait
                                UIInterfaceOrientationPortraitUpsideDown
    ${KEYDETECTOR_IOS_ICON_ARGS})

target_sources(KeyDetector PRIVATE
    Source/PluginProcessor.cpp
    Source/PluginEditor.cpp
    Source/SpectrumAnalyzer.cpp
    Source/ChromaKeyDetector.cpp
    Source/PitchDetector.cpp
    Source/TempoEstimator.cpp)

target_compile_definitions(KeyDetector PUBLIC
    JUCE_WEB_BROWSER=0            # avoids the webkit/gtk dependency
    JUCE_USE_CURL=0
    JUCE_VST3_CAN_REPLACE_VST2=0
    JUCE_DISPLAY_SPLASH_SCREEN=0)

# Embed images (logo etc.) so they are compiled into the plugin (no external
# files needed at runtime).  Drop replacement art into Resources/ with the same
# file name to swap it.
juce_add_binary_data(KeyDetectorAssets SOURCES Resources/logo.png)

if(KEYDETECTOR_USE_LICENSING)
    target_compile_definitions(KeyDetector PUBLIC KEYDETECTOR_USE_LICENSING=1)
    target_link_libraries(KeyDetector PRIVATE fuzzyaudio_licensing)
else()
    target_compile_definitions(KeyDetector PUBLIC KEYDETECTOR_USE_LICENSING=0)
endif()

target_link_libraries(KeyDetector
    PRIVATE
        KeyDetectorAssets
        juce::juce_audio_utils
        juce::juce_dsp
    PUBLIC
        juce::juce_recommended_config_flags
        juce::juce_recommended_lto_flags
        juce::juce_recommended_warning_flags)

# ==============================================================================
# License key generator (headless CLI) - OFF by default so normal/CI plug-in
# builds are unaffected. Enable with -DKEYDETECTOR_BUILD_KEYGEN=ON to build the
# tool you run on your server (or port to your website) to mint keys.
# ==============================================================================
option(KEYDETECTOR_BUILD_KEYGEN "Build the license key generator CLI" OFF)
if(KEYDETECTOR_BUILD_KEYGEN AND NOT KEYDETECTOR_IOS)
    juce_add_console_app(KeyDetectorKeygen PRODUCT_NAME "keydetector-keygen")
    target_sources(KeyDetectorKeygen PRIVATE tools/keygen/keygen.cpp)
    target_compile_definitions(KeyDetectorKeygen PRIVATE
        JUCE_WEB_BROWSER=0
        JUCE_USE_CURL=0
        JUCE_STANDALONE_APPLICATION=1)
    target_link_libraries(KeyDetectorKeygen PRIVATE
        juce::juce_product_unlocking
        juce::juce_data_structures
        juce::juce_recommended_config_flags
        juce::juce_recommended_warning_flags)
endif()

# ==============================================================================
# Standalone DSP unit test — pure C++17, links no JUCE, so it always builds and
# runs quickly (ctest).
# ==============================================================================
if(KEYDETECTOR_BUILD_TESTS AND NOT KEYDETECTOR_IOS)
    enable_testing()
    add_executable(ChromaKeyDetectorTest
        tests/ChromaKeyDetectorTest.cpp
        Source/ChromaKeyDetector.cpp)
    target_include_directories(ChromaKeyDetectorTest PRIVATE Source)
    add_test(NAME ChromaKeyDetectorTest COMMAND ChromaKeyDetectorTest)

    add_executable(PitchDetectorTest
        tests/PitchDetectorTest.cpp
        Source/PitchDetector.cpp)
    target_include_directories(PitchDetectorTest PRIVATE Source)
    add_test(NAME PitchDetectorTest COMMAND PitchDetectorTest)

    add_executable(TempoEstimatorTest
        tests/TempoEstimatorTest.cpp
        Source/TempoEstimator.cpp)
    target_include_directories(TempoEstimatorTest PRIVATE Source)
    add_test(NAME TempoEstimatorTest COMMAND TempoEstimatorTest)
endif()
