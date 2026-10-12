<?php
/*
 * JUCE-compatible offline license-key generator for Fuzzy Audio plug-ins.
 * ---------------------------------------------------------------------------
 * IMPORTANT: JUCE does NOT use standard (PEM/PKCS) RSA keys. A key here is the
 * two hex halves "part1,part2" produced by `keydetector-keygen makepair`. A
 * generic RSA library will reject it as "not a valid private key" - you must
 * sign with the small routine below (this mirrors juce::RSAKey::applyToValue).
 *
 * Needs the GMP extension (php-gmp).
 *
 * CLI usage:
 *   php sign_license.php <app> <email> <name> <machine> <privateKey>
 *
 * For Key Detector (paste-only, non machine-locked), <machine> is the fixed
 * activation token embedded in the plug-in:  key-detector-license-v1
 *
 *   php sign_license.php "Key Detector" "buyer@example.com" "Jane Doe" \
 *       "key-detector-license-v1" "<PRIVATE_KEY>"
 *
 * Call it from your purchase webhook (PHP exec, or paste this function into your
 * backend) and email the printed key to the buyer.
 */

/** The RSA transform JUCE uses - works on the whole message in base-"modulus"
 *  blocks, so the key size doesn't limit the payload length. */
function juce_applyToValue(GMP $value, GMP $part1, GMP $part2): GMP
{
    $result = gmp_init(0);
    while (gmp_cmp($value, 0) !== 0) {
        $result    = gmp_mul($result, $part2);
        $remainder = gmp_mod($value, $part2);
        $value     = gmp_div_q($value, $part2);
        $result    = gmp_add($result, gmp_powm($remainder, $part1, $part2));
    }
    return $result;
}

function xml_attr(string $s): string
{
    return str_replace(['&', '<', '>', '"'],
                       ['&amp;', '&lt;', '&gt;', '&quot;'], $s);
}

/** Returns the full key-file text to send to the buyer. */
function generate_key_file(string $app, string $email, string $name,
                           string $machine, string $privateKey): string
{
    if (strpos($privateKey, ',') === false)
        throw new InvalidArgumentException('Invalid JUCE private key (expected "part1,part2").');

    [$p1, $p2] = explode(',', $privateKey, 2);
    $part1 = gmp_init(trim($p1), 16);
    $part2 = gmp_init(trim($p2), 16);

    $dateHex = dechex((int) round(microtime(true) * 1000));

    // Single-line XML payload. user + email must be non-empty.
    $xml = '<key user="' . xml_attr($name)
         . '" email="' . xml_attr($email)
         . '" mach="'  . xml_attr($machine)
         . '" app="'   . xml_attr($app)
         . '" date="'  . $dateHex . '"/>';

    // Bytes -> little-endian big integer (matches juce BigInteger::loadFromMemoryBlock).
    $value     = gmp_import($xml, 1, GMP_LSW_FIRST | GMP_LITTLE_ENDIAN);
    $encrypted = juce_applyToValue($value, $part1, $part2);
    $hex       = gmp_strval($encrypted, 16);

    $lines   = [];
    $lines[] = "Keyfile for $app";
    if ($name !== '') $lines[] = "User: $name";
    $lines[] = "Email: $email";
    $lines[] = "Machine numbers: $machine";
    $lines[] = "Created: " . gmdate('d M Y H:i:s');
    $lines[] = "";
    foreach (str_split('#' . $hex, 70) as $chunk)
        $lines[] = $chunk;
    $lines[] = "";

    return implode("\r\n", $lines) . "\r\n";
}

// --- CLI entry point --------------------------------------------------------
if (PHP_SAPI === 'cli' && isset($argv) && realpath($argv[0]) === realpath(__FILE__)) {
    if ($argc < 6) {
        fwrite(STDERR, "usage: php sign_license.php <app> <email> <name> <machine> <privateKey>\n");
        exit(1);
    }
    echo generate_key_file($argv[1], $argv[2], $argv[3], $argv[4], $argv[5]);
}
