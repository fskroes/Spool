#!/usr/bin/env bash
# Creates a self-signed code signing identity "Striple Local Signing" in its own keychain,
# ~/Library/Keychains/striple-signing.keychain-db.
#
# Why: an ad hoc signature changes on every build, so macOS forgets the Accessibility
# permission after each rebuild. With this identity the designated requirement of the app
# (bundle ID + certificate hash) stays the same, so the permission stays.
# scripts/build-app.sh uses this identity automatically when it exists.
#
# Why its own keychain: codesign needs no trust setting for a self-signed certificate, and a
# keychain with a known password lets codesign use the key with no prompt. The password is
# random and stays in your login keychain (item "Striple Local Signing keychain").
# Nothing asks for your login password, and the login keychain trust settings do not change.
#
# Usage: scripts/make-signing-cert.sh [--dry-run]
#   --dry-run  print the steps. The keychains are not changed.
#
# Remove the identity later with: scripts/make-signing-cert.sh --remove
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=signing-env.sh
source "$ROOT/scripts/signing-env.sh"
readonly OPENSSL=/usr/bin/openssl   # LibreSSL: its PKCS#12 output is what `security import` accepts.
readonly WORK="$ROOT/.build/signing-cert"
readonly DAYS=3650

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

MODE=make
case "${1:-}" in
    "") ;;
    --dry-run) MODE=dry ;;
    --remove) MODE=remove ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
esac

for tool in "$OPENSSL" security codesign; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done

if [[ $MODE == remove ]]; then
    striple_signing_remove_from_search_list
    if [[ -f "$STRIPLE_SIGNING_KEYCHAIN" ]]; then
        security delete-keychain "$STRIPLE_SIGNING_KEYCHAIN"
        say "Deleted $STRIPLE_SIGNING_KEYCHAIN"
    fi
    security delete-generic-password -s "$STRIPLE_SIGNING_PASSWORD_ITEM" -a "$USER" >/dev/null 2>&1 \
        && say "Deleted the password item \"$STRIPLE_SIGNING_PASSWORD_ITEM\" from the login keychain"
    say "Done. The next 'make app' signs ad hoc."
    exit 0
fi

if HASH=$(striple_signing_identity 2>/dev/null); then
    say "The identity \"$STRIPLE_SIGNING_NAME\" is ready in $STRIPLE_SIGNING_KEYCHAIN ($HASH). Nothing to do."
    exit 0
fi
if [[ -f "$STRIPLE_SIGNING_KEYCHAIN" ]]; then
    die "$STRIPLE_SIGNING_KEYCHAIN exists, but it has no usable identity or its password item is missing.
Remove it with: scripts/make-signing-cert.sh --remove
Then run this script again."
fi

if [[ $MODE == dry ]]; then
    cat <<STEPS
[dry-run] 1. openssl: make an RSA 2048 key and a certificate "CN=$STRIPLE_SIGNING_NAME" with the codeSigning usage ($DAYS days)
[dry-run] 2. security create-keychain $STRIPLE_SIGNING_KEYCHAIN with a random password (no auto-lock)
[dry-run] 3. security add-generic-password -s "$STRIPLE_SIGNING_PASSWORD_ITEM" -a $USER (the password, in the login keychain)
[dry-run] 4. security import the identity into the new keychain, usable by /usr/bin/codesign only
[dry-run] 5. security set-key-partition-list (so codesign signs with no prompt)
[dry-run] 6. security list-keychains -d user -s <current list> $STRIPLE_SIGNING_KEYCHAIN
[dry-run] 7. sign a test file and check that its designated requirement names the certificate hash
STEPS
    exit 0
fi

# The private key is written here for a moment. Delete it on every exit path.
case "$WORK" in */.build/signing-cert) ;; *) die "unexpected work directory: $WORK" ;; esac
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
rm -rf "$WORK"
mkdir -p "$WORK"
chmod 700 "$WORK"

cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $STRIPLE_SIGNING_NAME

[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

say "Making the certificate"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
    -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
P12_PASS=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -name "$STRIPLE_SIGNING_NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$P12_PASS" -out "$WORK/identity.p12"

say "Making the keychain $STRIPLE_SIGNING_KEYCHAIN"
KC_PASS=$("$OPENSSL" rand -hex 24)
security create-keychain -p "$KC_PASS" "$STRIPLE_SIGNING_KEYCHAIN"
security set-keychain-settings "$STRIPLE_SIGNING_KEYCHAIN"
security unlock-keychain -p "$KC_PASS" "$STRIPLE_SIGNING_KEYCHAIN"
security add-generic-password -U -s "$STRIPLE_SIGNING_PASSWORD_ITEM" -a "$USER" -w "$KC_PASS" \
    -T /usr/bin/security -j "Unlocks $STRIPLE_SIGNING_KEYCHAIN for Striple builds"

say "Adding the identity (codesign only)"
security import "$WORK/identity.p12" -k "$STRIPLE_SIGNING_KEYCHAIN" -f pkcs12 -P "$P12_PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$STRIPLE_SIGNING_KEYCHAIN" >/dev/null
striple_signing_add_to_search_list

HASH=$(striple_signing_identity) || die "the identity is not usable after the import"
cp /usr/bin/true "$WORK/probe"
codesign --force --sign "$HASH" --identifier com.fskroes.Striple.probe "$WORK/probe" 2>/dev/null \
    || die "codesign could not sign with the new identity"
[[ "$(codesign -d -r - "$WORK/probe" 2>&1)" == *"certificate leaf = H\"$(tr 'A-F' 'a-f' <<<"$HASH")\""* ]] \
    || die "the designated requirement does not name the certificate"
say "The identity \"$STRIPLE_SIGNING_NAME\" ($HASH) signs with no prompt."

cat <<NEXT

Done. Next steps:
  1. make install    (build-app.sh now signs with "$STRIPLE_SIGNING_NAME")
  2. Give Accessibility permission to Striple one more time. Later rebuilds keep it.
NEXT
