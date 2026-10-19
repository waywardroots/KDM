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
`com.fuzzyaudiollc.kdm` in the target's *General* tab to something unique.

## Testing with a mixer

Connect the mixer's USB (or the audio interface) to the iPad before or after
launching. Then:

Tap **Inputs** (top right) to open the input panel, then:

- **Source:** pick the mixer / interface. The built-in mic is listed too, which
  is handy for a quick test with music playing in the room.
- **Main output:** the channel pair with the mixer's master mix; its key and BPM
  are the big read-out. For a mixer the last pair is picked by default
  (Denon X1800: USB 9 + 10).
- **Mixer channels:** every other stereo pair is analysed too and shown as a
  card per channel (X1800 default: Ch 1–4 on USB 1+2 … 7+8). Turn it off in
  the Inputs panel if you only want the main output.
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
    ├── ContentView.swift         main screen (header, meter, key/BPM read-outs)
    ├── InputsPanel.swift         Inputs panel: source/channel pickers + audio diagnostics
    ├── NoteBarsView.swift        note bars (C…B energy, notes of the key highlighted)
    ├── MinimalView.swift         minimal view: key + note bars only
    ├── LevelMeterView.swift      dBFS meter with peak hold and clip lamp
    ├── KeyNotation.swift         Musical / Camelot key names
    ├── HarmonicMixing.swift      Camelot wheel moves: next keys + channel mix matching
    ├── Assets.xcassets           company logo (Logo) shown top-left
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
- **Analysis load:** key + BPM only (the tuner is off). Benchmarked at ~1.4% of
  one desktop CPU core per channel pair, ~5.5% for all 5 pairs of a 10-channel
  mixer (not yet measured on an iPad).
- **Minimal view:** the *Minimal* button (top right) switches to a full-screen
  view with just the key, the next keys to mix to and the note bars; *Full view*
  switches back. The
  choice is remembered.
- **Key notation:** Camelot ("8A") by default, or Musical ("A minor"); the other
  notation is shown small next to it. The choice is remembered.
- **Minor keys:** detected by default (needed for A codes and the relative /
  parallel moves). Can be switched off to report major keys only, like the
  desktop plug-in.
- **Next keys:** under the main output key, where the set can go on the Camelot
  wheel. Smooth (green): −1, +1, Relative (same number, A ↔ B). Energy
  (orange): +2 (whole step up), Semitone +1 (+7 on the wheel), Parallel (same
  root, minor ↔ major: −3 to A from B, +3 to B from A).
- **Channel matching:** each mixer channel card shows how its key mixes with the
  main output (Smooth / Energy + the move, or Clash), with a green or orange
  outline.
