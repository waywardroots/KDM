# License-key generation spec (for the website / AI builder)

This describes **exactly** how to generate Key Detector license keys so the plug-in
accepts them. The plug-in uses JUCE's `OnlineUnlockStatus`, which is **not** normal
RSA signing. Follow this literally.

Ready-to-use reference implementations live next to this file:
- `generate-licence-keys.mjs` (plain Node, run directly) — **verified** to unlock.
- `generate-licence-keys.ts` (TypeScript) — same algorithm.
- `sign_license.php` (PHP + gmp) — same algorithm.

## DO NOT (these are the mistakes that make keys fail)
1. **Do NOT hash** the payload (no SHA-1/SHA-256). JUCE signs the *entire XML*.
2. **Do NOT** emit standard RSA / PEM signatures. The key is JUCE's `"<d_hex>,<n_hex>"`.
3. **Do NOT** put the XML in the file as clear text. The file is `comment + "#" + hex`.
4. **Do NOT** use nested `<user>`/`<product>` elements. Use one flat `<key .../>`.
5. **Do NOT** leave `user` or `email` empty — the plug-in rejects those.

## Inputs
- `LICENSE_SIGNING_KEY` = `"<d_hex>,<n_hex>"` — the private key (server-side secret).
- `app` = `"Key Detector"` (must match the plug-in's product id).
- `email` = buyer's email (non-empty, varies per purchase).
- `name` = buyer's name or email (non-empty).
- `machine` = `"key-detector-license-v1"` — the fixed activation token (paste-only).

## Algorithm (must match byte-for-byte)
1. Build a **single-line** XML string, attributes on the root `<key>` element:
   ```
   <key user="NAME" email="EMAIL" mach="TOKEN" app="APP" date="HEXMILLIS"/>
   ```
   - `date` = current time in ms as lowercase hex (`Date.now().toString(16)`).
   - XML-escape `& < > "` in the values.
2. Encode that string as **UTF-8 bytes**.
3. Convert the bytes to a BigInteger **little-endian** (first byte = least significant).
4. Apply JUCE's RSA transform with the private key (`d`, `n`) — **block-wise in base n**:
   ```
   result = 0
   while value != 0:
       result  = result * n
       rem     = value mod n
       value   = value div n          # integer division
       result += (rem ** d) mod n     # modular exponentiation
   ```
   (Because the XML is usually larger than the 1024-bit modulus, this loop runs
   ~2 times and the hex output is ~**512** characters — not 256.)
5. `hex = result` in lowercase base-16.
6. Build the final key file text (CRLF line endings):
   ```
   Keyfile for APP
   User: NAME
   Email: EMAIL
   Machine numbers: TOKEN
   Created: <any date string>
   <blank line>
   #<hex, wrapped at 70 chars per line>
   <blank line>
   ```
   Only the part after the last `#` matters to the plug-in; the comment lines are
   cosmetic. Email the whole block to the buyer.

## Minimal reference (Node, no dependencies)
```js
function modPow(b, e, m){let r=1n;b%=m;while(e>0n){if(e&1n)r=r*b%m;e>>=1n;b=b*b%m;}return r;}
function applyToValue(v, d, n){let r=0n;while(v!==0n){r*=n;const q=v%n;v=v/n;r+=modPow(q,d,n);}return r;}
function bytesToBigIntLE(a){let v=0n;for(let i=a.length-1;i>=0;i--)v=(v<<8n)|BigInt(a[i]);return v;}
const esc=s=>String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");

export function generateKeyFile({app,email,name,machine}, privateKey){
  const i=privateKey.indexOf(","); const d=BigInt("0x"+privateKey.slice(0,i).trim()), n=BigInt("0x"+privateKey.slice(i+1).trim());
  const user=name||email; if(!user||!email) throw new Error("user/email required");
  const xml=`<key user="${esc(user)}" email="${esc(email)}" mach="${esc(machine)}" app="${esc(app)}" date="${Date.now().toString(16)}"/>`;
  const hex=applyToValue(bytesToBigIntLE(new TextEncoder().encode(xml)), d, n).toString(16);
  const lines=[`Keyfile for ${app}`,`User: ${user}`,`Email: ${email}`,`Machine numbers: ${machine}`,`Created: ${new Date().toUTCString()}`,""];
  const body="#"+hex; for(let k=0;k<body.length;k+=70) lines.push(body.slice(k,k+70)); lines.push("");
  return lines.join("\r\n")+"\r\n";
}
```

## Self-test (prove it before shipping)
A correct key for `app="Key Detector"`, `machine="key-detector-license-v1"`, a
non-empty email, signed with your private key:
- contains **no** cleartext `<key>` XML,
- has a `#` followed by **~512** hex chars,
- unlocks the plug-in when pasted into its Unlock screen.

If your output still looks like `<key><user .../><product .../></key>` + 256 hex
chars, the old code path is still running — replace it with the reference above.
