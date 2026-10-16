# License keys

Spool costs EUR 0.99, one time. The buyer pays on https://1yc.dev/spool and gets
a license key by email. Spool checks the key on the Mac, with no network call.
This file is the contract between the two sides:

| Side | Repository | Does |
|---|---|---|
| Issuer | `fskroes/1yc` | Takes the payment, signs the key, emails it, sends it again on request |
| Verifier | `fskroes/Spool` | Checks the signature, stores the key, starts the window manager |

Both sides must pass every case in
[license-test-vectors.json](license-test-vectors.json). A change to this
format changes both sides in the same week and adds a new `v`.

## The key

```text
SPOOL-<payload>.<signature>
```

- `payload` is the UTF-8 bytes of one JSON object, encoded as base64url with no
  padding (RFC 4648, section 5).
- `signature` is the Ed25519 signature (RFC 8032) of exactly those payload
  bytes, 64 bytes, encoded as base64url with no padding.
- The prefix `SPOOL-` is part of the key.

The payload object:

| Field | Type | Value |
|---|---|---|
| `v` | number | `1` |
| `product` | string | `"spool"` |
| `id` | string | The order ID: the Stripe Checkout Session ID, or `comp-<date>-<n>` for a key the owner gives away |
| `email` | string | The buyer's email address, as Stripe received it |
| `issued` | string | The date of issue, `YYYY-MM-DD`, UTC |

The issuer writes the fields in this order, with no spaces. The verifier does
not depend on the order: it checks the signature on the bytes it received, and
only then reads the JSON.

## The verifier

1. Remove all white space (space, tab, CR, LF). Email clients wrap long lines.
2. The key must start with `SPOOL-` and hold exactly one `.` after it.
3. Decode both parts as base64url. A character outside `A-Z a-z 0-9 - _` is an
   error. The signature must be 64 bytes.
4. Check the signature with the public key. Stop if it is not valid.
5. Parse the payload as a JSON object. `v` must be `1`, `product` must be
   `"spool"`, and `id`, `email` and `issued` must be non-empty strings.

A key that fails any step is not valid. The app shows one message for all of
them: "This license key is not valid." It does not say which step failed.

A release build uses the public key of its `Info.plist` only when the app on
disk has a valid signature of the release team (`LicenseKeeper.releaseTeam`,
the same Team ID as `SPOOL_TEAM_ID`). An edited `Info.plist` or binary breaks
that signature, and a copy signed again (ad hoc or by someone else) has no
certificate of the team. Such a copy has no public key and stays unlicensed.
Only the E2E build (`make e2e`, compiled with `SPOOL_E2E`) skips this check;
it has a public test key, which `release.sh`, `install.sh` and `make-dmg.sh`
refuse.

## The keys of the owner

| Key | Where |
|---|---|
| Public key, 32 bytes, base64 | `SPOOL_LICENSE_PUBLIC_KEY` in `Packaging/updates.env`. `scripts/build-app.sh` writes it to `SpoolLicensePublicKey` in `Info.plist`. |
| Private key, the 32-byte Ed25519 seed, base64 | `SPOOL_LICENSE_SIGNING_KEY` in `~/1yc/.env` on the server of 1yc.dev, and a file on the owner's Mac (`~/.config/spool/license-signing.key`, mode 600). Never in a repository. |

`spool-license keygen` makes the pair once. `spool-license issue` signs a key
on the owner's Mac, for a gift or for support. See
[RELEASING.md](RELEASING.md), "License keys".

A new key pair makes every sold key invalid. Do not make a second pair. If the
private key leaks, the only fix is a new pair, a new release, and new keys for
all buyers.

## Sign a key in Node

The issuer runs on Node 22. Node signs Ed25519 with the built-in `crypto`
module:

```js
import crypto from "node:crypto";

const seed = Buffer.from(process.env.SPOOL_LICENSE_SIGNING_KEY, "base64");
const der = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]);
const privateKey = crypto.createPrivateKey({ key: der, format: "der", type: "pkcs8" });

export function issueLicense({ id, email, issued }) {
  const payload = Buffer.from(JSON.stringify({ v: 1, product: "spool", id, email, issued }), "utf8");
  const signature = crypto.sign(null, payload, privateKey);
  return `SPOOL-${payload.toString("base64url")}.${signature.toString("base64url")}`;
}
```

Ed25519 signatures are deterministic. With the test seed `seedA` of the
vectors and the payload of the case `valid`, this code returns exactly the
`key` of that case.

## Activate a key

The buyer can activate a key in three ways:

- Paste it in the window that Spool shows at its start, then click Activate.
- Click the link `spool://license?key=<key>` in the email. The key has only
  URL-safe characters, so the link needs no encoding.
- Run `spool license <key>` in a terminal.

Spool stores a valid key in `license.key` in its data folder
(`~/Library/Application Support/Spool`) and starts the window manager. The key
stays valid for every later version of Spool with the same public key.

## Test vectors

[license-test-vectors.json](license-test-vectors.json) holds two test key
pairs (`seedA`, `publicKeyA`, `publicKeyB`) and one case per rule above. Each
case gives a `key` and `valid`. Check every case with `publicKeyA`. The case
"signed by another key" has a valid signature of key B: it must fail with key
A.

The seeds are the bytes `0x00` to `0x1f` and `0x20` to `0x3f`. They are
public. A release never holds `publicKeyA`: `scripts/release.sh` stops when
`Packaging/updates.env` has it (or no valid key), and when the built app does not
have the public key of `Packaging/updates.env`. Only `make e2e` builds an app with
`publicKeyA`.
