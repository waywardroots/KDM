# StageLinQ

Reads what Denon DJ / Engine DJ gear reports on the local network — each deck's
track, artist, **key** and **BPM**, play state, and the mixer's fader positions —
for KDM. Works with SC6000 / SC5000 players, Prime units and X1800 / X1850
mixers.

StageLinQ isn't officially documented. This implementation follows the
community's reverse-engineering work (all MIT licensed):
[icedream/go-stagelinq](https://github.com/icedream/go-stagelinq),
[chrisle/StageLinq](https://github.com/chrisle/StageLinq),
[Jaxc/PyStageLinQ](https://github.com/Jaxc/PyStageLinQ). The tests use message
captures published with go-stagelinq.

## Try it on a Mac (before the iPad build is allowed to)

1. Connect the SC6000s and the X1800 to a router or switch, and your Mac to the
   same network (Wi-Fi or Ethernet). Turn the players on and load tracks.
2. Quit Engine DJ, SoundSwitch or anything else that talks StageLinQ.
3. In Terminal:

   ```bash
   cd KDM/iPad/StageLinQ
   swift run stagelinq-monitor          # deck summary
   swift run stagelinq-monitor --raw    # plus every state update
   ```

   If macOS asks whether to allow incoming connections, allow it.

The monitor prints each deck (track, key as Engine shows it plus its Camelot
code, BPM, play state, fader) and the mixer's faders, and saves every update to
`stagelinq-log.txt` in the folder you ran it from.

## How it works

1. **Discovery** (UDP 51337): devices broadcast "airD" announcements once a
   second; we announce ourselves too (they only talk to peers that do).
2. **Main connection** (TCP, port from the announcement): we request the
   device's services and send a keep-alive every 250 ms.
3. **StateMap** (TCP, port announced by the device): we subscribe to state paths
   such as `/Engine/Deck1/Track/CurrentKey` and receive JSON values when they
   change.

The key is read from `Track/CurrentKey` — text in whatever notation the player
is set to (Camelot "8A", Open Key "1m", or musical "Am") — and parsed into a
key. `CurrentKeyIndex` is logged but not used: its numbering isn't documented.

## On iPad

Discovery uses UDP broadcast, which iPadOS only allows for apps with Apple's
`com.apple.developer.networking.multicast` entitlement (requested from the
Apple Developer account). Until that's granted the package builds for iPad but
won't find devices there.
