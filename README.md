# Key Detector — JUCE VST3 chroma key-estimation plugin

A JUCE / C++ audio plugin that listens to incoming audio, computes its short-time
FFT spectrum, folds it into a 12-bin **chroma** vector (pitch-class energy) and
estimates the musical **key** by correlating the chroma against the
Krumhansl–Schmuckler key profiles. It also includes a **monophonic tuner** (YIN
pitch detection) that shows the nearest note and cents deviation when a single note
is played. The UI shows a live spectrum analyser, the chroma bars, the tuner, the
detected key with a confidence read-out, and the **tempo (BPM) estimated from the
audio** on the channel.

Builds as **VST3**, **AU** (macOS) and **Standalone** (Windows / macOS / Linux), and
as an **iPad app** (AUv3 + Standalone) — see [iPad (AUv3 + Standalone)](#ipad-auv3--standalone).

![Key Detector UI](docs/ui.png)

The window is **resizable** — drag the bottom-right corner (or the window edge in
hosts that allow it) and the whole UI scales uniformly (a fixed aspect ratio is
kept, from 0.75× to 2×):

![Resized](docs/resized.png)

The tuner lights up when a single note is played (it stays idle on full mixes):

![Tuner](docs/tuner.png)


```
audio in ─► mono sum ─► FIFO(8192, 75% overlap) ─► Hann ─► FFT ─► |X[k]|
        ─► peak-picking + parabolic interp ─► 12-bin chroma ─► EMA
        ─► Krumhansl–Schmuckler correlation (24 keys) + hysteresis ─► key
        └► YIN autocorrelation on the same buffer ─► note + cents (tuner)
```

## Instrument vs. effect (design note)

The task asked for an "instrument" plugin, but a key detector must **receive**
audio to analyse it, whereas a sound-generating instrument (VSTi) has no audio
input. So this is built as an **analyser/effect** (`IS_SYNTH FALSE`,
`VST3_CATEGORIES "Analyzer" "Fx"`): drop it on an audio track's insert chain; it
passes the audio through untouched and displays the key. To force host
registration as a synth, flip `IS_SYNTH`/`NEEDS_MIDI_INPUT` in `CMakeLists.txt`.

## Project layout

```
KeyDetector/
├── CMakeLists.txt              # JUCE plugin target + standalone DSP test
├── Source/
│   ├── ChromaKeyDetector.h/.cpp  # DSP core (NO JUCE dependency, unit-testable)
│   ├── PitchDetector.h/.cpp      # YIN monophonic pitch detector (tuner, no JUCE)
│   ├── TempoEstimator.h/.cpp     # audio BPM estimation (onset + autocorrelation)
│   ├── PluginProcessor.h/.cpp    # audio thread: FIFO → FFT → chroma → publish
│   ├── PluginEditor.h/.cpp       # GUI + 30 Hz timer polling the processor
│   ├── SpectrumAnalyzer.h/.cpp   # spectrum + chroma + tuner display components
│   └── ConsoleLookAndFeel.h      # dark "mixing console" theme (knobs/LEDs/buttons)
└── tests/
    ├── ChromaKeyDetectorTest.cpp # pure-C++17 sanity tests (ctest)
    ├── PitchDetectorTest.cpp     # YIN accuracy tests (ctest)
    └── TempoEstimatorTest.cpp    # tempo accuracy tests (ctest)
```

## Algorithmic choices (and why)

- **FFT size = 8192 (order 13), Hann window, 75% overlap.** ~5.9 Hz/bin @ 48 kHz
  for sharp low-end resolution, with a new frame every ~43 ms (hop = 2048) so the
  display stays responsive and the key detector gets 4x more frames to average.
  The Hann window suppresses spectral leakage so pitch energy stays in the right
  bins. Low notes are reinforced by their **harmonics** in well-resolved higher
  bins, which keeps octave-collapsed chroma robust.
- **Spectrum display** resamples the magnitude spectrum into one column per pixel
  on a **log 20 Hz – 20 kHz** frequency axis (interpolating at the low end,
  peak-aggregating at the high end) with fast-attack / slow-release smoothing and a
  peak-hold trace. The amplitude scale is **dBFS** with **+12 dB** of headroom at
  the top (0 dB is a calibrated full-scale reference; a 0 dBFS sine peaks on the
  0 dB line). **Hover** the mouse over the spectrum to snap to the nearest peak and
  read its note (with octave), frequency and cents:

  ![Spectrum hover](docs/hover.png)
- **Peak-based chroma (Harmonic Pitch-Class Profile).** Instead of dumping every
  FFT bin into a pitch class (which lets the broadband noise floor between partials
  dilute the result), only **spectral peaks** (local maxima above a relative
  threshold) are used. Each peak's frequency is refined with **parabolic
  interpolation** (sub-bin accuracy), snapped to the nearest note on the supplied
  A440 table, and rejected if it's more than a quarter-tone from any note. This is
  what makes the key read cleanly on real material. Each frame is L1-normalised
  (so loudness doesn't bias it) and folded into a running EMA for stability.
- **Key selection.** Two methods are available:
  * **Krumhansl–Schmuckler correlation (default)** — the chroma is correlated
    (Pearson) with all 12 major (and 12 minor) key-profile rotations and the best
    match wins; confidence is the margin over the runner-up. This correctly
    identifies the tonic even when the loudest pitch class is the fifth (on a chord
    the root is usually *not* the loudest note, because the root's 3rd harmonic
    reinforces the fifth's pitch class).
  * **Dominant pitch** — simply the loudest pitch class (its major). Direct, but on
    chords it tends to report the fifth rather than the root; select it via
    `ChromaKeyDetector::setKeyMethod` if you want raw prominence.
- **Stability.** The chroma smoothing is defined by a **time constant** (the
  Smoothing knob maps to ~0.1–4 s), so the amount of averaging is independent of
  the FFT overlap/frame rate. On top of that, the reported key uses **hysteresis**:
  a new key only replaces the current one after it has been the instantaneous
  winner for ~0.7 s of continuous frames, so momentary frames can't make the
  readout flicker while genuine key changes still register within about a second.
- **Tuner (YIN + peak fallback).** A time-domain **YIN** detector estimates the
  monophonic fundamental to within a few cents for harmonic notes. When there is no
  clear harmonic pitch (e.g. **percussion / inharmonic / drums**), the tuner falls
  back to the **loudest spectral peak** (parabolic-interpolated) so it still reports
  the dominant frequency, labelled `PEAK` instead of `PITCH`. The reading maps to
  the nearest note (A440) with a cents needle.
- **Readable tuner display.** The reading is stabilised before display: the shown
  note is held with a short hysteresis (a new note must persist ~120 ms to take
  over), the cents needle is smoothed, and the last note lingers ~300 ms after the
  sound stops. This keeps the read-out steady instead of flickering frame-to-frame
  (important in the peak/percussion mode, where the loudest bin hops around).
- **Atonal gating.** The key read-out only appears when the chroma correlates well
  enough with a key profile. Percussion / atonal input gives a flat chroma (low
  correlation), so it shows **"no clear key"** rather than a spurious key.

## Controls

- **Smoothing** – EMA coefficient (0 = instant, ~0.85 = steady). Saved with state.
- **Freeze** – hold the current chroma/key (stop accumulating).
- **Reset** – clear the accumulated chroma and start estimating from scratch.
- **Tuner** – selects the tuner source: **Auto** (YIN pitch when a clear note is
  present, else the loudest peak), **Pitch** (always the YIN fundamental), or
  **Peak** (always the loudest spectral peak — best for percussion / SFX).

## BPM read-out

The header shows the tempo **estimated from the audio on the channel** (not the
host clock). The onset-detection function is **spectral flux** from a 4096-point
STFT (so steady tones barely register, while note/chord changes and drum hits
produce clear onsets — it can therefore read a BPM even with no percussive
"beat"). The onset envelope is mean-removed and auto-correlated over a musical lag
range, gated by an onset-activity (crest) test so sustained material reads
`-- BPM` instead of a spurious tempo.

Controls next to the read-out:
- **Tap** *(shortcut: T)* – tap in time; the BPM is derived from your tap spacing
  (overrides the estimate for ~5 s; blue text).
- **Hold** *(shortcut: H)* – freeze the read-out at its current value (amber text).
- **− / +** – fine-tune the BPM by ±0.1 (engages Hold automatically).
- **×½ / ×1 / ×2** – rescale the BPM (fixes half/double-time); while held, this
  rescales the held value too.

Colour code: green = estimated from audio, blue = tapped, amber = held. See
`Source/TempoEstimator.*` and `tests/TempoEstimatorTest.cpp`.

## Building

Requires CMake ≥ 3.22 and a C++17 compiler.

```bash
# From the KeyDetector/ directory. If a JUCE checkout sits at ../JUCE it is used
# automatically; otherwise pass -DKEYDETECTOR_FETCH_JUCE=ON to download JUCE 8.0.9.
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build

# Run the DSP unit tests
ctest --test-dir build --output-on-failure
```

### Linux build dependencies

```bash
sudo apt-get install libasound2-dev libx11-dev libxext-dev libxrandr-dev \
    libxcursor-dev libxinerama-dev libfreetype-dev libfontconfig1-dev \
    libcurl4-openssl-dev libxrender-dev libxcomposite-dev
```

Build artefacts land in
`build/KeyDetector_artefacts/Release/VST3/Key Detector.vst3` and
`.../Standalone/Key Detector`.

## iPad (AUv3 + Standalone)

The same project builds an iPad app. One install gives you both:

- **Key Detector app** — runs on its own and analyses the iPad's microphone (or a
  connected audio interface). It outputs silence so the mic can't feed back
  through the speaker, and the input is switched on automatically.
- **Key Detector AUv3 effect** — appears in AUv3 hosts (GarageBand, AUM, Logic Pro
  for iPad, Cubasis…) as an audio effect; insert it on a track and it analyses the
  track and passes the audio through unchanged, like the desktop plug-in.

What's different on iPad:

- **Touch read-out:** press and drag a finger on the spectrum to read the peak
  under it (desktop shows this on mouse hover); lift to hide it.
- **Layout:** the UI scales to fit any screen or host window size, centred, in
  landscape or portrait, including Split View / Stage Manager.
- **No license-key gate:** App Store apps must be sold through the App Store
  (paid app or In-App Purchase), so the offline key check is compiled out
  (`KEYDETECTOR_USE_LICENSING=OFF` by default on iOS).

### Build and run on your iPad

You need a Mac with Xcode, CMake ≥ 3.22 and an Apple ID (free is fine for your own
iPad; a paid Apple Developer account is needed for TestFlight / App Store).

```bash
cmake -B build-ios -G Xcode \
      -DCMAKE_SYSTEM_NAME=iOS \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
      -DKEYDETECTOR_IOS_TEAM_ID=YOURTEAMID    # Xcode > Settings > Accounts, or developer.apple.com > Membership
open build-ios/KeyDetector.xcodeproj
```

In Xcode choose the **KeyDetector_Standalone** scheme, pick your iPad as the run
destination, and press Run. The AUv3 extension is built and embedded
automatically. If signing complains, open the *Signing & Capabilities* tab of both
the `KeyDetector_Standalone` and `KeyDetector_AUv3` targets and pick your team.

The first time it launches, iPadOS asks for microphone permission. To use the
AUv3, open a host (e.g. GarageBand → Audio Recorder → plug-ins, or AUM) and look
for **Fuzzy Audio → Key Detector** in its effect list.

### Before the App Store

- **Icon:** add a 1024×1024 PNG as `Resources/AppIcon.png` (the 256 px logo is used
  until then, which App Store Connect will reject as too small).
- **Bundle ID:** `com.jamesandthecat.keydetector` (the AUv3 is
  `…keydetector.keydetectorAUv3`). Register it in App Store Connect, or change
  `BUNDLE_ID` in `CMakeLists.txt` first.
- **Selling:** price it as a paid app, or add In-App Purchase if you want a free
  download with an unlock.
- Archive in Xcode (*Product → Archive*) and upload from the Organizer.

The **Build iPad AUv3 + Standalone** GitHub Action compiles the iPad app (unsigned)
on every push so build breaks are caught early.

## License / Copyright

Key Detector is **developed, owned, and licensed by Fuzzy Audio LLC**. **© 2026
Fuzzy Audio LLC. All rights reserved.** The Software is licensed, not sold;
end-user use is governed by the **End User License Agreement** in
[`End User License Agreement - FuzzyAudio - Key Detector.pdf`](End%20User%20License%20Agreement%20-%20FuzzyAudio%20-%20Key%20Detector.pdf)
(plain-text and RTF versions for the installers live in [`installer/`](installer)).
It is built with third-party components (JUCE, the Steinberg VST 3 SDK, Apple
Audio Units) under their respective licenses — if you distribute binaries, make
sure you comply with those (e.g. the applicable JUCE and VST 3 SDK licenses).
The EULA is not legal advice; have a lawyer review it before shipping.

## Windows build (for Ableton Live)

### About the file type — `.vst3`, not `.dll`

Modern plugins for Ableton on Windows are **VST3** (`Key Detector.vst3`), which is
a DLL-format binary in a small bundle folder. The old VST2 `.dll` format can't be
built anymore because Steinberg discontinued the VST2 SDK. Live 10.1+ loads VST3
natively.

> A Windows VST3 must be compiled with **MSVC** (Visual Studio) — that's the
> toolchain JUCE officially supports. JUCE 8's Windows renderer requires the
> Direct2D/DirectWrite SDK headers, so it cannot be cross-compiled from Linux with
> MinGW. Both options below build on Windows with MSVC.

### Option A — build on your Windows PC

1. Install **Visual Studio 2022** (Community is free) with the *Desktop
   development with C++* workload, plus **CMake** and **Git**.
2. Double-click **`build-windows.bat`** (or run it in a terminal). It downloads
   JUCE automatically and produces:
   `build\KeyDetector_artefacts\Release\VST3\Key Detector.vst3`

### Option B — let GitHub build it for you (no local compiler)

Push this project to a GitHub repo. The included workflow
`.github/workflows/windows-vst3.yml` builds the VST3 on a Windows runner; open the
**Actions** tab and download the **KeyDetector-VST3-Windows** artifact.

### Install & use in Ableton Live

1. Copy the `Key Detector.vst3` folder into `C:\Program Files\Common Files\VST3\`.
2. In Live: *Preferences → Plug-Ins →* enable **Use VST3 Plug-In System Folders**,
   then **Rescan**. "Key Detector" appears under *Plug-Ins*.
3. This is an **analyser** (it needs audio to analyse), so drop it on an **audio
   track** (or the Master) that is playing the material you want to key-detect. It
   passes the audio through and shows the detected key. It is *not* a
   sound-generating instrument — an instrument has no audio input and would have
   nothing to analyse.
