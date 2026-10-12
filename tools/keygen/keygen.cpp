/*
  ==============================================================================
   keydetector-keygen - offline license-key generator (headless)
  ------------------------------------------------------------------------------
   A tiny console tool that your website/back-office can run to (a) create an RSA
   key pair once, and (b) sign a machine-locked key file for each purchase. It is
   product-agnostic (pass the product name + keys as arguments), so the same tool
   serves every Fuzzy Audio plug-in.

   It links only juce_product_unlocking (+ juce_cryptography) - no GUI - so it
   builds and runs on a headless server.

   USAGE
     keydetector-keygen makepair [numBits=1024]
         -> prints a new "public:" and "private:" RSA key.
            Embed the public key in the plug-in; keep the private key secret
            on your server.

     keydetector-keygen sign <productName> <email> <machineID> <privateKey> [name]
         -> prints a key file locked to that single machine ID. Email/return it
            to the buyer.

     keydetector-keygen verify <productName> <publicKey> <machineID> <keyFilePath>
         -> checks a key file would unlock the given machine (for testing).

   Keep <privateKey> OUT of the plug-in and the public repo.
  ==============================================================================
*/

#include <juce_product_unlocking/juce_product_unlocking.h>
#include <iostream>

using namespace juce;

//==============================================================================
static int doMakePair (int numBits)
{
    RSAKey publicKey, privateKey;

    Random rng (Time::getHighResolutionTicks());
    Array<int> seeds;
    for (int i = 0; i < 64; ++i)
        seeds.add (rng.nextInt());

    RSAKey::createKeyPair (publicKey, privateKey, numBits,
                           seeds.getRawDataPointer(), seeds.size());

    std::cout << "public:  " << publicKey.toString()  << "\n"
              << "private: " << privateKey.toString() << "\n";
    return 0;
}

static int doSign (const StringArray& a)
{
    // a = { productName, email, machineID, privateKey, [userName] }
    const auto productName = a[0];
    const auto email       = a[1];
    const auto machineID   = a[2];           // exactly one -> "1 licence = 1 machine"
    const RSAKey privateKey (a[3]);
    // The key file must carry a non-empty licensee name AND email, otherwise
    // OnlineUnlockStatus::applyKeyFile rejects it as "Credentials are invalid".
    // Default the name to the email when the caller doesn't supply one.
    const auto userName    = a.size() > 4 && a[4].isNotEmpty() ? a[4] : email;

    if (! a[3].containsChar (','))
    {
        std::cerr << "error: not a valid RSA private key (expected \"part1,part2\")\n";
        return 1;
    }

    std::cout << KeyGeneration::generateKeyFile (productName, email, userName,
                                                 machineID, privateKey)
              << std::endl;
    return 0;
}

//==============================================================================
// A minimal OnlineUnlockStatus used only to verify a key offline during testing.
struct VerifierStatus final : public OnlineUnlockStatus
{
    String productID, publicKeyString, stateString;
    StringArray machineIDs;

    String getProductID() override                            { return productID; }
    bool doesProductIDMatch (const String& r) override        { return r == productID; }
    RSAKey getPublicKey() override                            { return RSAKey (publicKeyString); }
    void saveState (const String& s) override                 { stateString = s; }
    String getState() override                                { return stateString; }
    String getWebsiteName() override                          { return {}; }
    URL getServerAuthenticationURL() override                 { return URL(); }
    String readReplyFromWebserver (const String&, const String&) override { return {}; }
    StringArray getLocalMachineIDs() override                 { return machineIDs; }
};

static int doVerify (const StringArray& a)
{
    // a = { productName, publicKey, machineID, keyFilePath }
    VerifierStatus status;
    status.productID       = a[0];
    status.publicKeyString = a[1];
    status.machineIDs.add (a[2]);

    const auto keyText = File (a[3]).loadFileAsString();
    const auto result  = status.applyKeyFile (keyText);

    std::cout << "applyKeyFile: " << (result.wasOk() ? String ("ok") : result.getErrorMessage()) << "\n"
              << "isUnlocked:   " << (status.isUnlocked() ? "YES" : "no") << "\n";

    return status.isUnlocked() ? 0 : 2;
}

//==============================================================================
int main (int argc, char* argv[])
{
    StringArray args;
    for (int i = 1; i < argc; ++i)
        args.add (String::fromUTF8 (argv[i]));

    const auto usage = []
    {
        std::cerr << "usage:\n"
                  << "  keygen makepair [numBits=1024]\n"
                  << "  keygen sign   <productName> <email> <machineID> <privateKey> [name]\n"
                  << "  keygen verify <productName> <publicKey> <machineID> <keyFilePath>\n";
        return 1;
    };

    if (args.isEmpty())
        return usage();

    const auto cmd = args[0];
    args.remove (0);

    if (cmd == "makepair")
        return doMakePair (args.isEmpty() ? 1024 : args[0].getIntValue());

    if (cmd == "sign")
        return args.size() >= 4 ? doSign (args) : usage();

    if (cmd == "verify")
        return args.size() == 4 ? doVerify (args) : usage();

    return usage();
}
