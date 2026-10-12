/*
  ==============================================================================

   fuzzyaudio_licensing
   --------------------
   A small, reusable JUCE module that adds offline, machine-locked license-key
   unlocking to any Fuzzy Audio plug-in.  It is deliberately product-agnostic:
   drop the module into a new plug-in, construct a LicenseManager with that
   product's name + RSA public key, and show an UnlockGate when it is not yet
   unlocked.

   Keys are generated on your server with the matching RSA *private* key (see the
   headless key-generator in tools/keygen) and verified here with the embedded
   *public* key - no runtime server is required.

   BEGIN_JUCE_MODULE_DECLARATION

    ID:                 fuzzyaudio_licensing
    vendor:             FuzzyAudio
    version:            1.0.0
    name:               Fuzzy Audio licensing
    description:        Offline, machine-locked license-key unlocking for JUCE plug-ins.
    website:            https://fuzzyaudio.example
    license:            Proprietary
    minimumCppStandard: 17
    dependencies:       juce_product_unlocking juce_gui_extra

   END_JUCE_MODULE_DECLARATION

  ==============================================================================
*/

#pragma once
#define FUZZYAUDIO_LICENSING_H_INCLUDED 1

#include <juce_product_unlocking/juce_product_unlocking.h>
#include <juce_gui_extra/juce_gui_extra.h>

#include "LicenseManager.h"
#include "UnlockGate.h"
