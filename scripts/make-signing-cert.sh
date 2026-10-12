#!/usr/bin/env bash
# Creates a self-signed code signing identity "Striple Local Signing" in its own keychain,
# ~/Library/Keychains/striple-signing.keychain-db, and writes an encrypted backup of it.
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
# Passwords go to `security` and `openssl` on stdin or in the environment, never as arguments.
#
# Usage: scripts/make-signing-cert.sh [--dry-run]
#          Make the identity. The backup goes to ~/Striple-signing-identity.p12
#          (STRIPLE_SIGNING_BACKUP sets another path) and its passphrase is printed once.
#        scripts/make-signing-cert.sh --import FILE
#          Restore the identity from a backup. The passphrase is read from the terminal, or
#          from STRIPLE_SIGNING_P12_PASSWORD.
#        scripts/make-signing-cert.sh --remove --yes
#          Delete the identity, its keychain and its password item. Back it up first.
#   --dry-run  print the steps. Nothing is read from or written to a keychain.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=signing-env.sh
source "$ROOT/scripts/signing-env.sh"
readonly OPENSSL=/usr/bin/openssl   # LibreSSL: its PKCS#12 output is what `security import` accepts.
readonly WORK="$ROOT/.build/signing-cert"
readonly DAYS=3650
readonly BACKUP="${STRIPLE_SIGNING_BACKUP:-$HOME/Striple-signing-identity.p12}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

MODE=make
YES=0
IMPORT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) MODE=dry ;;
        --remove) MODE=remove ;;
        --yes) YES=1 ;;
        --import) [[ $# -ge 2 ]] || die "--import needs a file"; MODE=import; IMPORT=$2; shift ;;
        -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done
[[ $YES -eq 0 || $MODE == remove ]] || die "--yes is only for --remove"

for tool in "$OPENSSL" security codesign; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done
[[ "$STRIPLE_SIGNING_KEYCHAIN" != *'"'* && "$STRIPLE_SIGNING_PASSWORD_ITEM" != *'"'* ]] \
    || die "the keychain path and the item name must not contain a double quote"

if [[ $MODE == dry ]]; then
    if [[ -f "$STRIPLE_SIGNING_KEYCHAIN" ]]; then
        say "[dry-run] $STRIPLE_SIGNING_KEYCHAIN exists. Without --dry-run the script unlocks it, puts it on the"
        say "[dry-run] keychain search list if it is not there, and checks the identity. It makes nothing new."
        exit 0
    fi
    cat <<STEPS
[dry-run] 1. openssl: make an RSA 2048 key and a certificate "CN=$STRIPLE_SIGNING_NAME" with the codeSigning usage ($DAYS days)
[dry-run] 2. security create-keychain $STRIPLE_SIGNING_KEYCHAIN with a random password (no auto-lock)
[dry-run] 3. security add-generic-password -s "$STRIPLE_SIGNING_PASSWORD_ITEM" -a $USER (the password, in the login keychain)
[dry-run] 4. security import the identity into the new keychain, usable by /usr/bin/codesign only
[dry-run] 5. security set-key-partition-list (so codesign signs with no prompt)
[dry-run] 6. security list-keychains -d user -s <current list> $STRIPLE_SIGNING_KEYCHAIN
[dry-run] 7. sign a test file and check that its designated requirement names the certificate hash
[dry-run] 8. write the backup $BACKUP (PKCS#12, encrypted with a random passphrase that is printed once)
STEPS
    exit 0
fi

if [[ $MODE == remove ]]; then
    if [[ $YES -eq 0 ]]; then
        cat >&2 <<WARN
This deletes the private key of "$STRIPLE_SIGNING_NAME" for good.
Installed copies of Striple and published releases are signed with it. An update signed with
another identity makes macOS ask for the Accessibility permission again on every Mac.
Only the backup brings it back: scripts/make-signing-cert.sh --import <backup file>
To delete it, run: scripts/make-signing-cert.sh --remove --yes
WARN
        exit 1
    fi
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
Remove it with: scripts/make-signing-cert.sh --remove --yes
Then run this script again (with --import <backup file> to keep the identity of your releases)."
fi
if [[ $MODE == make && -e "$BACKUP" ]]; then
    die "$BACKUP exists. Move it away, or restore it: scripts/make-signing-cert.sh --import $BACKUP"
fi

# The private key is written here for a moment. Delete it on every exit path.
case "$WORK" in */.build/signing-cert) ;; *) die "unexpected work directory: $WORK" ;; esac
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
rm -rf "$WORK"
mkdir -p "$WORK"
chmod 700 "$WORK"

if [[ $MODE == import ]]; then
    [[ -f "$IMPORT" ]] || die "no such file: $IMPORT"
    if [[ -z "${STRIPLE_SIGNING_P12_PASSWORD:-}" ]]; then
        [[ -r /dev/tty ]] || die "no terminal: set STRIPLE_SIGNING_P12_PASSWORD"
        printf 'Passphrase of %s: ' "$IMPORT" > /dev/tty
        IFS= read -rs STRIPLE_SIGNING_P12_PASSWORD < /dev/tty
        printf '\n' > /dev/tty
    fi
    export STRIPLE_SIGNING_P12_PASSWORD
    [[ "$STRIPLE_SIGNING_P12_PASSWORD" != *'"'* ]] || die "the passphrase must not contain a double quote"
    "$OPENSSL" pkcs12 -in "$IMPORT" -passin env:STRIPLE_SIGNING_P12_PASSWORD -nokeys -out "$WORK/cert.pem" 2>/dev/null \
        || die "cannot read $IMPORT: wrong passphrase, or not a PKCS#12 file"
    SUBJECT=$("$OPENSSL" x509 -in "$WORK/cert.pem" -noout -subject)
    [[ "$SUBJECT" == *"CN=$STRIPLE_SIGNING_NAME"* || "$SUBJECT" == *"CN = $STRIPLE_SIGNING_NAME"* ]] \
        || die "$IMPORT is not a \"$STRIPLE_SIGNING_NAME\" identity ($SUBJECT)"
    cp "$IMPORT" "$WORK/identity.p12"
else
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
    # The same file is imported and kept as the backup, so the backup is what the keychain has.
    STRIPLE_SIGNING_P12_PASSWORD=$("$OPENSSL" rand -hex 16)
    export STRIPLE_SIGNING_P12_PASSWORD
    "$OPENSSL" pkcs12 -export -name "$STRIPLE_SIGNING_NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -passout env:STRIPLE_SIGNING_P12_PASSWORD -out "$WORK/identity.p12"
fi
P12_PASS=$STRIPLE_SIGNING_P12_PASSWORD

say "Making the keychain $STRIPLE_SIGNING_KEYCHAIN"
KC_PASS=$("$OPENSSL" rand -hex 24)
KC="\"$STRIPLE_SIGNING_KEYCHAIN\""
striple_security_secret "create-keychain -p $KC_PASS $KC"
security set-keychain-settings "$STRIPLE_SIGNING_KEYCHAIN"
striple_security_secret "unlock-keychain -p $KC_PASS $KC"
striple_security_secret "add-generic-password -U -s \"$STRIPLE_SIGNING_PASSWORD_ITEM\" -a \"$USER\" -w $KC_PASS -T /usr/bin/security -j \"Unlocks $STRIPLE_SIGNING_KEYCHAIN for Striple builds\""

say "Adding the identity (codesign only)"
striple_security_secret "import \"$WORK/identity.p12\" -k $KC -f pkcs12 -P \"$P12_PASS\" -T /usr/bin/codesign" >/dev/null
striple_security_secret "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $KC_PASS $KC" >/dev/null
striple_signing_add_to_search_list

HASH=$(striple_signing_identity) || die "the identity is not usable after the import"
cp /usr/bin/true "$WORK/probe"
codesign --force --sign "$HASH" --identifier com.fskroes.Striple.probe "$WORK/probe" 2>/dev/null \
    || die "codesign could not sign with the new identity"
[[ "$(codesign -d -r - "$WORK/probe" 2>&1)" == *"certificate leaf = H\"$(tr 'A-F' 'a-f' <<<"$HASH")\""* ]] \
    || die "the designated requirement does not name the certificate"
say "The identity \"$STRIPLE_SIGNING_NAME\" ($HASH) signs with no prompt."

if [[ $MODE == make ]]; then
    (umask 077 && cp "$WORK/identity.p12" "$BACKUP")
    cat <<BACKUP_NOTE

Back up the identity now. Without the backup, a new Mac or a lost keychain means a new identity,
and every installed Striple asks for the Accessibility permission again after the next update.
  File:       $BACKUP
  Passphrase: $P12_PASS
  SHA-1:      $HASH
Put the file and the passphrase in your password manager, then delete the file: rm "$BACKUP"
Restore it with: scripts/make-signing-cert.sh --import <file>
BACKUP_NOTE
fi

cat <<NEXT

Done. Next steps:
  1. Set STRIPLE_SIGNING_CERT_SHA1=$HASH in Packaging/updates.env if releases use this identity.
  2. make install    (build-app.sh now signs with "$STRIPLE_SIGNING_NAME")
  3. Give Accessibility permission to Striple one more time. Later rebuilds keep it.
NEXT
