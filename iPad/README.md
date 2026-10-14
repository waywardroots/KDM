# KDM — iPad app

A SwiftUI iPad app that listens to an external audio source (a DJ mixer over USB,
or a USB audio interface fed from the mixer) and detects the musical key and
tempo. It uses the same C++ analysis code as the desktop Key Detector plug-in.

## Open and run it

1. On your Mac, clone the repo and open **`iPad/KDM.xcodeproj`** in Xcode.
2. Select the **KDM** target → *Signing & Capabilities* → pick your **Team**
   (a free Apple ID works for your own iPad).
3. Plug in your iPad, choose it as the run destination at the top of the window,
   and press **Run** (⌘R).
4. The first launch asks for permission to use audio input. iPadOS calls this
   the microphone permission; it is also what allows USB audio.

If Xcode says the bundle identifier is taken, change
`com.jamesandthecat.kdm` in the target's *General* tab to something unique.

## Testing with a mixer

Connect the mixer's USB (or the audio interface) to the iPad before or after
launching. Then:

- **Source:** pick the mixer / interface. The built-in mic is listed too, which
  is handy for a quick test with music playing in the room.
- **Channels:** pick the channel pair carrying the audio you want analysed. USB
  mixers usually send several pairs (e.g. master plus each deck), and iPadOS is
  asked to open all of them, so try each pair until the meter moves.
- **Level:** aim for peaks between −18 and −6 dBFS. The red lamp means clipping.

If a mixer doesn't appear as a source at all, iPadOS doesn't support it without
a driver. Use the fallback that works with any mixer: its **booth** or
**record/master** output into a class-compliant USB audio interface plugged
into the iPad.

The app remembers the last source, and the channel pair for each device.

## How it's put together

```
iPad/
├── KDM.xcodeproj                 Xcode project (iPadOS 16+, iPad only)
└── KDM/
    ├── KDMApp.swift              app entry point
    ├── AudioInputManager.swift   audio session, input/channel picking, AVAudioEngine tap
    ├── AnalysisViewModel.swift   polls results ~30×/s; meter ballistics, key/BPM text
    ├── ContentView.swift         test screen (input picker, meters, read-outs)
    ├── LevelMeterView.swift      dBFS meter with peak hold and clip lamp
    ├── KeyNotation.swift         Musical / Camelot key names
    ├── Bridge/                   Objective-C++ wrapper so Swift can call the C++ engine
    └── Engine/AnalysisEngine.*   JUCE-free version of the plug-in's analysis pipeline
../Source/{ChromaKeyDetector,PitchDetector,TempoEstimator}.*   shared with the plug-in
../tests/AnalysisEngineTest.cpp   engine tests (run on any machine: ctest)
```

- **Audio session:** record-only (nothing is played back, so there's no feedback)
  in *measurement* mode, which turns off iPadOS's voice processing and automatic
  gain so the mixer's level reaches the analyser unchanged.
- **Hot-plugging:** connecting or removing a device, interruptions (calls, Siri)
  and media-server resets rebuild the audio graph automatically.
- **Background:** audio keeps running when another app is in front.
- **Key notation:** choose *Musical* ("C major") or *Camelot* ("8B") in the
  Analysis panel; the other notation is shown small next to it. The choice is
  remembered.
- **Minor keys:** major keys only by default, matching the desktop plug-in, so
  Camelot codes are all "B" until *Detect minor keys* is turned on (also
  remembered).
