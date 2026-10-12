# Licensing (offline, paste-only license keys)

Fuzzy Audio plug-ins are protected with an **offline license key** built on JUCE's
`juce_product_unlocking`. Your website signs a key with your RSA **private** key;
the plug-in verifies it with the embedded **public** key. No runtime server is
required - the buyer just **pastes the key** they were sent after purchase.

The reusable implementation lives in [`modules/fuzzyaudio_licensing`](../modules/fuzzyaudio_licensing),
so the same system drops into every plug-in you build.

> **Machine locking:** this is configured *paste-only* via
> `LicenseManager::Config::activationToken`. Every key is signed with that fixed
> token, so a key activates on **any** computer - track the "1 key = 1 purchase"
> rule on your website. (To hard-lock each key to one physical machine instead,
> set `activationToken` empty and sign keys with the buyer's Machine ID.)

---

## How activation works (buyer's point of view)

1. Buyer purchases on your website.
2. Your website **generates a key file** and emails it to the buyer (no machine
   info needed).
3. Buyer installs and opens the plug-in; it shows the **Unlock** screen.
4. Buyer **pastes the key** and clicks **Unlock**. Done.

---

## Key file format

A key file is plain text: human-readable comment lines, a blank line, then a
single `#` followed by a long hex string wrapped at 70 chars/line:

```
Keyfile for Key Detector
User: Jane Doe
Email: jane@example.com
Machine numbers: key-detector-license-v1
Created: 12 Oct 2026 7:36:56pm

#A1B2C3...(hex)...
```

The hex is the RSA transform of this **single-line XML** payload:

```xml
<key user="Jane Doe" email="jane@example.com" mach="key-detector-license-v1" app="Key Detector" date="18f..."/>
```

- `user` and `email` **must be non-empty** (the plug-in rejects the key otherwise).
- `mach` is the **activation token** the plug-in expects. For Key Detector that is
  `key-detector-license-v1` (set in `makeLicenseConfig()` in `PluginProcessor.cpp`).
- `app` must equal the plug-in's product id (`Key Detector`).
- `date` is `toHexString` of the current time in milliseconds.

Transform: take the XML bytes as a big integer, apply the RSA **private** key with
JUCE's block algorithm, and emit the result as hex. The plug-in reverses it with
the public key.

---

## Generating keys on your website

> **Key format gotcha:** JUCE keys are **not** PEM/PKCS. A key is the two hex
> halves `part1,part2` from `keydetector-keygen makepair`. A standard RSA library
> will reject it as "not a valid private key" - you must sign with JUCE's own
> `applyToValue` routine (both options below do this correctly).

### Option A - PHP signer (tested, drop-in)

[`tools/website/sign_license.php`](../tools/website/sign_license.php) is a complete,
dependency-light signer (needs the `gmp` PHP extension). It was verified to produce
keys the plug-in accepts. Call it from your purchase webhook:

```php
require 'sign_license.php';
$key = generate_key_file(
    'Key Detector',
    $buyerEmail,
    $buyerName,
    'key-detector-license-v1',   // the activation token
    $PRIVATE_KEY                  // "part1,part2", server-side secret
);
// email $key to the buyer
```

or from the command line:

```sh
php sign_license.php "Key Detector" "jane@example.com" "Jane Doe" \
    "key-detector-license-v1" "<PRIVATE_KEY>"
```

### Option B - the bundled C++ generator

Build the headless CLI once and call it from any backend (`exec`):

```sh
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DKEYDETECTOR_BUILD_KEYGEN=ON
cmake --build build --target KeyDetectorKeygen
# -> build/KeyDetectorKeygen_artefacts/Release/KeyDetectorKeygen

keydetector-keygen makepair 1024                 # one-time: create your key pair
keydetector-keygen sign "Key Detector" "jane@example.com" "key-detector-license-v1" "<PRIVATE_KEY>" "Jane Doe"
keydetector-keygen verify "Key Detector" "<PUBLIC_KEY>" "key-detector-license-v1" key.txt   # test
```

Whichever you use, embed the matching **public** key in the plug-in
(`makeLicenseConfig()` in `Source/PluginProcessor.cpp`) and keep the **private**
key server-side only.

---

## Reusing this in another plug-in (the repeatable part)

The licensing is a self-contained JUCE module, so adding it to a new plug-in is:

1. Copy `modules/fuzzyaudio_licensing/` into the new project (or share it via a
   git submodule).
2. In CMake: `juce_add_module(.../fuzzyaudio_licensing)` and add
   `fuzzyaudio_licensing` to the plug-in's `target_link_libraries`.
3. Generate a **per-product key pair** (`keydetector-keygen makepair`) and give the
   new product its own `app` id.
4. Construct a `LicenseManager` with that product's name + public key (see
   `makeLicenseConfig()` in `Source/PluginProcessor.cpp`), and store it on the
   processor.
5. In the editor, show the gate when locked:

```cpp
if (! processor.license.isActivated())
{
    gate = std::make_unique<fuzzyaudio::UnlockGate> (processor.license);
    gate->onUnlockSucceeded = [this] { gate.reset(); };
    addAndMakeVisible (*gate);
    gate->setBounds (getLocalBounds());   // also in resized()
}
```

Everything else (key format, verification, machine locking, persistence) is shared.

---

## Security notes

- The **public** key is safe to embed in the plug-in and commit publicly - it can
  only *verify* keys, never create them.
- The **private** key lives **only on your server**. Never put it in the plug-in,
  the repo, or anywhere a user can reach it. If it leaks, anyone can mint keys.
- Like any software license check, this deters casual sharing but is not
  crack-proof. For stronger protection use a wrapped/hardware scheme (PACE/iLok).
- Regenerate your production key pair yourself (don't reuse a pair that was created
  anywhere untrusted), then update the embedded public key.
