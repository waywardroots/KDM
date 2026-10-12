# Licensing (offline, machine-locked license keys)

Fuzzy Audio plug-ins are protected with an **offline, machine-locked license key**
built on JUCE's `juce_product_unlocking`. Your website signs a key with your RSA
**private** key; the plug-in verifies it with the embedded **public** key. No
runtime server is required, and a key unlocks exactly **one machine**.

The reusable implementation lives in [`modules/fuzzyaudio_licensing`](../modules/fuzzyaudio_licensing),
so the same system drops into every plug-in you build.

---

## How activation works (buyer's point of view)

1. Buyer purchases on your website.
2. Buyer installs and opens the plug-in. Because it isn't licensed yet, it shows
   the **Unlock** screen, which displays a **Machine ID**.
3. Buyer copies that Machine ID and enters it on your website's activation page.
4. Your website **generates a key file** locked to that single Machine ID and
   returns/emails it.
5. Buyer pastes the key into the plug-in and clicks **Unlock**. Done - and the
   key will only ever unlock that one computer.

(If you'd rather avoid the copy/paste, you can later add online activation by
implementing `getServerAuthenticationURL()`/`readReplyFromWebserver()` so the
plug-in fetches the key itself. The offline flow above needs no server.)

---

## Key file format

A key file is plain text: human-readable comment lines, a blank line, then a
single `#` followed by a long hex string wrapped at 70 chars/line:

```
Keyfile for Key Detector
User: Jane Doe
Email: jane@example.com
Machine numbers: 3a7f9c...
Created: 12 Oct 2026 7:36:56pm

#A1B2C3...(hex)...
```

The hex is the RSA transform of this **single-line XML** payload:

```xml
<key user="Jane Doe" email="jane@example.com" mach="3a7f9c..." app="Key Detector" date="18f..."/>
```

- `user` and `email` **must be non-empty** (the plug-in rejects the key otherwise).
- `mach` is the **one** Machine ID this key unlocks (that's the 1-machine rule).
- `app` must equal the plug-in's product id (`Key Detector`).
- `date` is `toHexString` of the current time in milliseconds.

Transform: take the XML bytes as a big integer, apply the RSA **private** key with
JUCE's block algorithm, and emit the result as hex. The plug-in reverses it with
the public key. (This is exactly what `juce::KeyGeneration::generateKeyFile` does.)

---

## Generating keys on your website

### Option A - run the bundled generator (simplest, guaranteed compatible)

Build the headless CLI once and call it from your backend (e.g. PHP `exec`,
Node `child_process`):

```sh
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DKEYDETECTOR_BUILD_KEYGEN=ON
cmake --build build --target KeyDetectorKeygen
# -> build/KeyDetectorKeygen_artefacts/Release/KeyDetectorKeygen

# one-time: create your production key pair
keydetector-keygen makepair 1024
#   public:  5,....      <- embed in the plug-in (Source/PluginProcessor.cpp)
#   private: ....,....   <- keep SECRET on your server only

# per purchase: sign a key locked to the buyer's machine id
keydetector-keygen sign "Key Detector" "jane@example.com" "<MACHINE_ID>" "<PRIVATE_KEY>" "Jane Doe"

# testing: confirm a key unlocks a given machine
keydetector-keygen verify "Key Detector" "<PUBLIC_KEY>" "<MACHINE_ID>" key.txt
```

### Option B - implement it natively (e.g. PHP)

JUCE ships a reference `applyToValue` in `juce_RSAKey.h` (PHP and Java). The RSA
primitive you need is:

```php
// needs phpseclib's Math_BigInteger
function applyToValue($message, $key_part1, $key_part2) {
    $result = new Math_BigInteger();
    $zero   = new Math_BigInteger();
    $value  = new Math_BigInteger(strrev($message), 256);
    $part1  = new Math_BigInteger($key_part1, 16);
    $part2  = new Math_BigInteger($key_part2, 16);
    while (! $value->equals($zero)) {
        $result = $result->multiply($part2);
        list($value, $remainder) = $value->divide($part2);
        $result = $result->add($remainder->modPow($part1, $part2));
    }
    return $result;   // then render as hex for the key file
}
```

Build the single-line `<key .../>` XML shown above, run it through `applyToValue`
with your private key (`$key_part1,$key_part2` = the two halves of the private key
string, split on the comma), hex-encode the result, prepend the comment lines and
`#`. Note the `strrev`/base-256 handling matches JUCE's big-integer byte order -
get that wrong and the plug-in will report "Credentials are invalid", so if in
doubt use Option A.

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
