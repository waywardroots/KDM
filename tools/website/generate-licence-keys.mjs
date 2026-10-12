/*
 * generate-licence-keys.mjs  -  standalone, runnable with: node generate-licence-keys.mjs
 * ---------------------------------------------------------------------------
 * JUCE-compatible offline licence-key generator (pure BigInt, no OpenSSL/PEM).
 *
 * This is the SAME algorithm as generate-licence-keys.ts, as a dependency-free
 * script so you can run it directly and compare its output to your website's.
 *
 * A CORRECT key looks like this (NOTE: no cleartext <key> XML, there is a '#',
 * and the hex is ~512 chars because the whole XML is signed, not a SHA-1 hash):
 *
 *     Keyfile for Key Detector
 *     User: buyer@example.com
 *     Email: buyer@example.com
 *     Machine numbers: key-detector-license-v1
 *     Created: ...
 *
 *     #<~512 hex chars, wrapped at 70>
 *
 * Usage:
 *   LICENSE_SIGNING_KEY="<d_hex>,<n_hex>" \
 *     node generate-licence-keys.mjs "Key Detector" buyer@example.com key-detector-license-v1 "Buyer Name"
 */

function modPow(base, exp, m) {
  let result = 1n;
  base %= m;
  while (exp > 0n) {
    if (exp & 1n) result = (result * base) % m;
    exp >>= 1n;
    base = (base * base) % m;
  }
  return result;
}

// Mirrors juce::RSAKey::applyToValue - block-wise in base "part2".
function applyToValue(value, part1, part2) {
  let result = 0n;
  while (value !== 0n) {
    result *= part2;
    const remainder = value % part2;
    value = value / part2;
    result += modPow(remainder, part1, part2);
  }
  return result;
}

// UTF-8 bytes -> little-endian BigInt (matches juce BigInteger::loadFromMemoryBlock).
function bytesToBigIntLE(bytes) {
  let v = 0n;
  for (let i = bytes.length - 1; i >= 0; i--) v = (v << 8n) | BigInt(bytes[i]);
  return v;
}

const xmlAttr = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;")
           .replace(/>/g, "&gt;").replace(/"/g, "&quot;");

export function generateKeyFile({ app, email, name, machine }, privateKey) {
  const comma = privateKey.indexOf(",");
  if (comma < 0) throw new Error('Invalid JUCE private key (expected "<d_hex>,<n_hex>").');
  const d = BigInt("0x" + privateKey.slice(0, comma).trim());
  const n = BigInt("0x" + privateKey.slice(comma + 1).trim());

  const user = (name && name.length) ? name : email;
  if (!user || !email) throw new Error("user/name and email must be non-empty.");

  const xml =
    `<key user="${xmlAttr(user)}"` +
    ` email="${xmlAttr(email)}"` +
    ` mach="${xmlAttr(machine)}"` +
    ` app="${xmlAttr(app)}"` +
    ` date="${Date.now().toString(16)}"/>`;

  const hex = applyToValue(bytesToBigIntLE(new TextEncoder().encode(xml)), d, n).toString(16);

  const lines = [
    `Keyfile for ${app}`,
    `User: ${user}`,
    `Email: ${email}`,
    `Machine numbers: ${machine}`,
    `Created: ${new Date().toUTCString()}`,
    "",
  ];
  const body = "#" + hex;
  for (let i = 0; i < body.length; i += 70) lines.push(body.slice(i, i + 70));
  lines.push("");
  return lines.join("\r\n") + "\r\n";
}

// Run directly?
import { pathToFileURL } from "node:url";
if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const [, , app, email, machine, name] = process.argv;
  const key = process.env.LICENSE_SIGNING_KEY;
  if (!key || !app || !email || !machine) {
    console.error('usage: LICENSE_SIGNING_KEY="d,n" node generate-licence-keys.mjs <app> <email> <machine> [name]');
    process.exit(1);
  }
  process.stdout.write(generateKeyFile({ app, email, machine, name }, key));
}
