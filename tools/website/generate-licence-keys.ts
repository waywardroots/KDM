/*
 * generate-licence-keys.ts
 * ---------------------------------------------------------------------------
 * JUCE-compatible offline licence-key generator for Fuzzy Audio plug-ins.
 *
 * IMPORTANT - this is NOT standard RSA signing:
 *   - JUCE does NOT hash the payload (no SHA-1). It treats the whole XML as a
 *     big integer m and computes the RSA transform block-by-block in base-n.
 *   - The plug-in RECOVERS the XML by applying the public key to the hex blob,
 *     so the XML is NOT written in clear text - only the "#"+hex block is read.
 *   - Bytes are interpreted LITTLE-ENDIAN (first byte = least significant).
 *   - The XML is a single <key> element with attributes on the root:
 *         <key user="..." email="..." mach="..." app="..." date="..."/>
 *
 * Key format: LICENSE_SIGNING_KEY = "<d_hex>,<n_hex>"  (the JUCE private key from
 * `keydetector-keygen makepair`; it is NOT a PEM key).
 *
 * No OpenSSL / no PEM / pure BigInt.
 */

export interface LicenceInfo {
  app: string;       // product id, must equal the plug-in's (e.g. "Key Detector")
  email: string;     // buyer email (per purchase)
  name?: string;     // buyer name; defaults to email. Must be non-empty.
  machine: string;   // activation token (paste-only) e.g. "key-detector-license-v1"
}

/** base^exp mod m for BigInt. */
function modPow(base: bigint, exp: bigint, m: bigint): bigint {
  let result = 1n;
  base %= m;
  while (exp > 0n) {
    if (exp & 1n) result = (result * base) % m;
    exp >>= 1n;
    base = (base * base) % m;
  }
  return result;
}

/** Mirrors juce::RSAKey::applyToValue - a block-wise transform in base "part2". */
function applyToValue(value: bigint, part1: bigint, part2: bigint): bigint {
  let result = 0n;
  while (value !== 0n) {
    result *= part2;
    const remainder = value % part2;
    value = value / part2;
    result += modPow(remainder, part1, part2);
  }
  return result;
}

/** UTF-8 bytes -> little-endian BigInt (matches juce BigInteger::loadFromMemoryBlock). */
function bytesToBigIntLE(bytes: Uint8Array): bigint {
  let v = 0n;
  for (let i = bytes.length - 1; i >= 0; i--) v = (v << 8n) | BigInt(bytes[i]);
  return v;
}

function xmlAttr(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;")
          .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** Builds the full key-file text to send to the buyer. */
export function generateKeyFile(info: LicenceInfo, privateKey: string): string {
  const comma = privateKey.indexOf(",");
  if (comma < 0)
    throw new Error('Invalid JUCE private key (expected "<d_hex>,<n_hex>").');

  const d = BigInt("0x" + privateKey.slice(0, comma).trim());
  const n = BigInt("0x" + privateKey.slice(comma + 1).trim());

  const name = (info.name && info.name.length > 0) ? info.name : info.email;
  const dateHex = Date.now().toString(16);

  // Single-line XML, attributes on the root <key> element (order matches JUCE).
  const xml =
    `<key user="${xmlAttr(name)}"` +
    ` email="${xmlAttr(info.email)}"` +
    ` mach="${xmlAttr(info.machine)}"` +
    ` app="${xmlAttr(info.app)}"` +
    ` date="${dateHex}"/>`;

  const m = bytesToBigIntLE(new TextEncoder().encode(xml));
  const hex = applyToValue(m, d, n).toString(16);

  const lines: string[] = [];
  lines.push(`Keyfile for ${info.app}`);
  lines.push(`User: ${name}`);
  lines.push(`Email: ${info.email}`);
  lines.push(`Machine numbers: ${info.machine}`);
  lines.push(`Created: ${new Date().toUTCString()}`);
  lines.push("");
  const body = "#" + hex;
  for (let i = 0; i < body.length; i += 70) lines.push(body.slice(i, i + 70));
  lines.push("");

  return lines.join("\r\n") + "\r\n";
}

// --- CLI: node/ts-node generate-licence-keys.ts <app> <email> <machine> [name]
//     LICENSE_SIGNING_KEY env must hold "<d_hex>,<n_hex>".
if (typeof require !== "undefined" && require.main === module) {
  const [, , app, email, machine, name] = process.argv;
  const key = process.env.LICENSE_SIGNING_KEY;
  if (!key || !app || !email || !machine) {
    console.error('usage: LICENSE_SIGNING_KEY="d,n" node generate-licence-keys.ts <app> <email> <machine> [name]');
    process.exit(1);
  }
  process.stdout.write(generateKeyFile({ app, email, machine, name }, key));
}
