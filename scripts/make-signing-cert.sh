#!/usr/bin/env bash
# Creates a self-signed code signing identity "Striple Local Signing" in its own keychain,
# ~/Library/Keychains/striple-signing.keychain-db, and writes an encrypted backup of it.
#
# Why: an ad hoc signature changes on every build, so after each rebuild the Accessibility
# entry no longer matches (the switch still shows on). With this identity the designated requirement of the app
# (bundle ID + certificate hash) stays the same, so the permission stays.
# scripts/build-app.sh uses this identity automatically when it exists.
#
# Why its own keychain: codesign needs no trust setting for a self-signed certificate, and a
# keychain with a known password lets codesign use the key with no prompt. The password is
# random and stays in your login keychain (item "Striple Local Signing keychain").
# Nothing asks for your login password, and the login keychain trust settings do not change.
# Passwords go to `security` and `openssl` on stdin or in the environment, never as arguments.
#
# The pin: STRIPLE_SIGNING_CERT_SHA1 in Packaging/updates.env (STRIPLE_UPDATES_ENV sets another
# file) names the identity of the releases. When it is set, the script accepts only that identity:
# it does not make a new one, and it imports or keeps only a backup with that SHA-1.
#
# Usage: scripts/make-signing-cert.sh [--dry-run] [--new-identity]
#          Make the identity. The backup goes to ~/Striple-signing-identity.p12
#          (STRIPLE_SIGNING_BACKUP sets another path), and its passphrase to a file next to it,
#          ~/Striple-signing-identity-passphrase.txt. Only you can read both files.
#          When a pin is set, this stops: restore the backup with --import.
#          --new-identity makes a new identity anyway, to change the identity of the
#          releases on purpose. Installed copies then lose the Accessibility permission after the
#          next update, while the switch still shows on (fix: Settings > Mac Setup > Reset Permission).
#        scripts/make-signing-cert.sh --import FILE
#          Restore the identity from a backup. The passphrase is read from the terminal, or
#          from STRIPLE_SIGNING_P12_PASSWORD.
#        scripts/make-signing-cert.sh --remove --yes [--backup FILE]
#          Delete the identity, its keychain and its password item. When the keychain has the
#          pinned identity, give its backup with --backup. The script reads the backup (same
#          passphrase rules as --import) and deletes only when its SHA-1 is the pin.
#   --dry-run  print the steps. Nothing is read from or written to a keychain.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=signing-env.sh
source "$ROOT/scripts/signing-env.sh"
# shellcheck source=release-lib.sh
source "$ROOT/scripts/release-lib.sh"
readonly OPENSSL=/usr/bin/openssl   # LibreSSL: its PKCS#12 output is what `security import` accepts.
readonly WORK="$ROOT/.build/signing-cert"
readonly DAYS=3650
readonly BACKUP="${STRIPLE_SIGNING_BACKUP:-$HOME/Striple-signing-identity.p12}"
# The passphrase goes to a file, not to the terminal: terminal output is kept in scrollback and logs.
readonly PASSPHRASE_FILE="${BACKUP%.p12}-passphrase.txt"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

MODE=make
YES=0
IMPORT=""
NEW_IDENTITY=0
REMOVE_BACKUP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) MODE=dry ;;
        --remove) MODE=remove ;;
        --yes) YES=1 ;;
        --import) [[ $# -ge 2 ]] || die "--import needs a file"; MODE=import; IMPORT=$2; shift ;;
        --new-identity) NEW_IDENTITY=1 ;;
        --backup) [[ $# -ge 2 ]] || die "--backup needs a file"; REMOVE_BACKUP=$2; shift ;;
        -h|--help) sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done
[[ $YES -eq 0 || $MODE == remove ]] || die "--yes is only for --remove"
[[ -z "$REMOVE_BACKUP" || $MODE == remove ]] || die "--backup is only for --remove"
[[ $NEW_IDENTITY -eq 0 || $MODE == make || $MODE == dry ]] || die "--new-identity is only for making an identity"

readonly UPDATES_ENV="${STRIPLE_UPDATES_ENV:-$ROOT/Packaging/updates.env}"
# A missing file would read as "no pin" and turn the pin off.
striple_updates_env_usable "$UPDATES_ENV" || die "$UPDATES_ENV not found. Set STRIPLE_UPDATES_ENV to the settings file. Nothing was changed."
PIN=$(striple_updates_value "$UPDATES_ENV" STRIPLE_SIGNING_CERT_SHA1)
if [[ -n "$PIN" ]]; then
    striple_sha1_equal "$PIN" "$PIN" || die "STRIPLE_SIGNING_CERT_SHA1 in $UPDATES_ENV is not a SHA-1: $PIN"
fi
readonly PIN

# Asks for the passphrase of the backup $1, unless STRIPLE_SIGNING_P12_PASSWORD is set.
read_passphrase() {
    if [[ -z "${STRIPLE_SIGNING_P12_PASSWORD:-}" ]]; then
        [[ -r /dev/tty ]] || die "no terminal: set STRIPLE_SIGNING_P12_PASSWORD"
        printf 'Passphrase of %s: ' "$1" > /dev/tty
        IFS= read -rs STRIPLE_SIGNING_P12_PASSWORD < /dev/tty
        printf '\n' > /dev/tty
    fi
    export STRIPLE_SIGNING_P12_PASSWORD
}

# Status 0 when the PKCS#12 file $1 has a private key. The passphrase is in STRIPLE_SIGNING_P12_PASSWORD.
# grep -c reads to the end: with grep -q, openssl can fail on a closed pipe (pipefail).
p12_has_key() {
    local keys
    keys=$("$OPENSSL" pkcs12 -in "$1" -passin env:STRIPLE_SIGNING_P12_PASSWORD -nocerts -nodes 2>/dev/null \
        | grep -c 'PRIVATE KEY') || keys=0
    [[ $keys -gt 0 ]]
}

sha1_of_cert() { "$OPENSSL" x509 -in "$1" -noout -fingerprint -sha1 | sed -e 's/.*=//' -e 's/://g' | tr 'a-f' 'A-F'; }

for tool in "$OPENSSL" "$STRIPLE_SECURITY" "$STRIPLE_CODESIGN"; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done

if [[ $MODE == dry ]]; then
    if [[ -f "$STRIPLE_SIGNING_KEYCHAIN" ]]; then
        say "[dry-run] $STRIPLE_SIGNING_KEYCHAIN exists. Without --dry-run the script unlocks it, puts it on the"
        say "[dry-run] keychain search list if it is not there, and checks the identity. It makes nothing new."
        exit 0
    fi
    if [[ -n "$PIN" && $NEW_IDENTITY -eq 0 ]]; then
        say "[dry-run] $UPDATES_ENV pins the identity $PIN. Without --dry-run the script stops and makes nothing."
        say "[dry-run] Restore the pinned identity: scripts/make-signing-cert.sh --import <backup file>"
        exit 0
    fi
    cat <<STEPS
[dry-run] 1. openssl: make an RSA 2048 key and a certificate "CN=$STRIPLE_SIGNING_NAME" with the codeSigning usage ($DAYS days)
[dry-run] 2. write the backup $BACKUP (PKCS#12, encrypted with a random passphrase) and the passphrase to $PASSPHRASE_FILE
[dry-run] 3. security create-keychain $STRIPLE_SIGNING_KEYCHAIN with a random password (no auto-lock)
[dry-run] 4. security add-generic-password -s "$STRIPLE_SIGNING_PASSWORD_ITEM" -a $USER (the password, in the login keychain)
[dry-run] 5. security import the identity into the new keychain, usable by /usr/bin/codesign only
[dry-run] 6. security set-key-partition-list (so codesign signs with no prompt)
[dry-run] 7. security list-keychains -d user -s <current list> $STRIPLE_SIGNING_KEYCHAIN
[dry-run] 8. sign a test file and check that its designated requirement names the certificate hash
STEPS
    exit 0
fi

if [[ $MODE == remove ]]; then
    if [[ $YES -eq 0 ]]; then
        cat >&2 <<WARN
This deletes the private key of "$STRIPLE_SIGNING_NAME" for good.
Installed copies of Striple and published releases are signed with it. An update signed with
another identity takes the Accessibility permission away on every Mac, while the switch still shows on.
Only the backup brings it back: scripts/make-signing-cert.sh --import <backup file>
To delete it, run: scripts/make-signing-cert.sh --remove --yes
WARN
        exit 1
    fi
    # Only the backup brings the pinned identity back. Delete it only when that backup is at hand.
    # When the identity cannot be read, it can be the pinned one, so the same rule applies.
    if [[ -n "$PIN" && -f "$STRIPLE_SIGNING_KEYCHAIN" ]]; then
        CURRENT=$(striple_signing_identity 2>/dev/null) || CURRENT=""
        if [[ -z "$CURRENT" ]] || striple_sha1_equal "$CURRENT" "$PIN"; then
            WHAT="the pinned identity $PIN"
            [[ -n "$CURRENT" ]] || WHAT="an identity that cannot be read. It can be the pinned identity $PIN"
            [[ -n "$REMOVE_BACKUP" ]] || die "the keychain has $WHAT.
Only its backup brings it back. Give the backup, so the script can check it first:
  scripts/make-signing-cert.sh --remove --yes --backup <backup file>
Nothing was deleted."
            [[ -f "$REMOVE_BACKUP" ]] || die "no such file: $REMOVE_BACKUP. Nothing was deleted."
            read_passphrase "$REMOVE_BACKUP"
            BACKUP_HASH=$("$OPENSSL" pkcs12 -in "$REMOVE_BACKUP" -passin env:STRIPLE_SIGNING_P12_PASSWORD -nokeys 2>/dev/null \
                | "$OPENSSL" x509 -noout -fingerprint -sha1 2>/dev/null | sed -e 's/.*=//' -e 's/://g') || BACKUP_HASH=""
            striple_sha1_equal "$BACKUP_HASH" "$PIN" \
                || die "$REMOVE_BACKUP is not a backup of the pinned identity $PIN (${BACKUP_HASH:-cannot read it: wrong passphrase, or not a PKCS#12 file}). Nothing was deleted."
            p12_has_key "$REMOVE_BACKUP" \
                || die "$REMOVE_BACKUP has no private key. It is not a backup of the identity. Nothing was deleted."
            say "$REMOVE_BACKUP is a backup of the pinned identity $PIN."
        fi
    fi
    striple_signing_remove_from_search_list
    if [[ -f "$STRIPLE_SIGNING_KEYCHAIN" ]]; then
        "$STRIPLE_SECURITY" delete-keychain "$STRIPLE_SIGNING_KEYCHAIN"
        say "Deleted $STRIPLE_SIGNING_KEYCHAIN"
    fi
    "$STRIPLE_SECURITY" delete-generic-password -s "$STRIPLE_SIGNING_PASSWORD_ITEM" -a "$USER" >/dev/null 2>&1 \
        && say "Deleted the password item \"$STRIPLE_SIGNING_PASSWORD_ITEM\" from the login keychain"
    if [[ -n "$PIN" ]]; then
        say "Done. 'make app' stops until you import the pinned identity again (or use SIGN_IDENTITY=- for an ad hoc test build)."
    else
        say "Done. The next 'make app' signs ad hoc."
    fi
    exit 0
fi

# The private key is written here for a moment. Delete it on every exit path.
case "$WORK" in */.build/signing-cert) ;; *) die "unexpected work directory: $WORK" ;; esac
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
rm -rf "$WORK"
mkdir -p "$WORK"
chmod 700 "$WORK"

# Signs a test file with HASH and checks that the designated requirement names that certificate.
verify_identity() {
    cp /usr/bin/true "$WORK/probe"
    "$STRIPLE_CODESIGN" --force --sign "$1" --identifier com.fskroes.Striple.probe "$WORK/probe" 2>/dev/null \
        || die "codesign could not sign with the identity $1"
    [[ "$("$STRIPLE_CODESIGN" -d -r - "$WORK/probe" 2>&1)" == *"certificate leaf = H\"$(tr 'A-F' 'a-f' <<<"$1")\""* ]] \
        || die "the designated requirement does not name the certificate $1"
}

NEW_HASH=""
if [[ $MODE == import ]]; then
    [[ -f "$IMPORT" ]] || die "no such file: $IMPORT"
    read_passphrase "$IMPORT"
    "$OPENSSL" pkcs12 -in "$IMPORT" -passin env:STRIPLE_SIGNING_P12_PASSWORD -nokeys -out "$WORK/cert.pem" 2>/dev/null \
        || die "cannot read $IMPORT: wrong passphrase, or not a PKCS#12 file"
    SUBJECT=$("$OPENSSL" x509 -in "$WORK/cert.pem" -noout -subject)
    [[ "$SUBJECT" == *"CN=$STRIPLE_SIGNING_NAME"* || "$SUBJECT" == *"CN = $STRIPLE_SIGNING_NAME"* ]] \
        || die "$IMPORT is not a \"$STRIPLE_SIGNING_NAME\" identity ($SUBJECT)"
    # Before any keychain change: a certificate without its key cannot sign.
    p12_has_key "$IMPORT" || die "$IMPORT has no private key. It is not a backup of the identity. Nothing was changed."
    NEW_HASH=$(sha1_of_cert "$WORK/cert.pem")
    if [[ -n "$PIN" ]] && ! striple_sha1_equal "$NEW_HASH" "$PIN"; then
        die "$IMPORT has the identity $NEW_HASH, but $UPDATES_ENV pins $PIN.
Import the backup of the pinned identity. Nothing was changed."
    fi
fi

if HASH=$(striple_signing_identity 2>/dev/null); then
    # An import must not report success when the keychain keeps another identity.
    if [[ $MODE == import && "$(tr 'a-f' 'A-F' <<<"$HASH")" != "$NEW_HASH" ]]; then
        die "the keychain has another identity ($HASH) than $IMPORT ($NEW_HASH).
To use the backup: scripts/make-signing-cert.sh --remove --yes, then --import $IMPORT"
    fi
    if [[ -n "$PIN" && $NEW_IDENTITY -eq 0 ]] && ! striple_sha1_equal "$HASH" "$PIN"; then
        die "the keychain has the identity $HASH, but $UPDATES_ENV pins $PIN.
Builds with this identity lose the Accessibility permission of the installed copies.
Restore the pinned identity: scripts/make-signing-cert.sh --remove --yes, then --import <backup file>"
    fi
    verify_identity "$HASH"
    say "The identity \"$STRIPLE_SIGNING_NAME\" is ready in $STRIPLE_SIGNING_KEYCHAIN ($HASH) and signs. Nothing to do."
    exit 0
fi
if [[ -f "$STRIPLE_SIGNING_KEYCHAIN" ]]; then
    die "$STRIPLE_SIGNING_KEYCHAIN exists, but it has no usable identity or its password item is missing.
Remove it with: scripts/make-signing-cert.sh --remove --yes
Then run this script again (with --import <backup file> to keep the identity of your releases).
When $UPDATES_ENV pins an identity, --remove needs that backup too: add --backup <backup file>."
fi
if [[ $MODE == make && -n "$PIN" && $NEW_IDENTITY -eq 0 ]]; then
    die "$UPDATES_ENV pins the identity $PIN. With a new identity, every installed copy would lose the
Accessibility permission after the next update, while the switch still shows on. Restore the pinned identity from its backup:
  scripts/make-signing-cert.sh --import <backup file>
To change the identity of the releases on purpose: scripts/make-signing-cert.sh --new-identity"
fi
if [[ $MODE == make && -e "$BACKUP" ]]; then
    die "$BACKUP exists. Move it away, or restore it: scripts/make-signing-cert.sh --import $BACKUP"
fi
if [[ $MODE == make && ( -e "$PASSPHRASE_FILE" || -L "$PASSPHRASE_FILE" ) ]]; then
    die "$PASSPHRASE_FILE exists. Move it away first. Nothing was changed."
fi
if [[ $MODE == make ]]; then
    [[ -d "$(dirname "$BACKUP")" && -w "$(dirname "$BACKUP")" ]] \
        || die "cannot write the backup to $(dirname "$BACKUP"). Set STRIPLE_SIGNING_BACKUP to a file in a folder you can write."
fi

if [[ $MODE == import ]]; then
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
    # The backup comes before any keychain change: if a later step fails, the key is not lost.
    NEW_HASH=$(sha1_of_cert "$WORK/cert.pem")
    (umask 077 && cp "$WORK/identity.p12" "$BACKUP") || die "cannot write the backup $BACKUP"
    # printf is a shell builtin: the passphrase is in no argument list. set -C: never write into an existing file.
    (umask 077 && set -C && printf '%s\n' "$STRIPLE_SIGNING_P12_PASSWORD" > "$PASSPHRASE_FILE") \
        || die "cannot write the passphrase file $PASSPHRASE_FILE"
    cat <<BACKUP_NOTE

Back up the identity now. Without the backup, a new Mac or a lost keychain means a new identity,
and every installed Striple loses the Accessibility permission after the next update, while the
switch still shows on.
  File:       $BACKUP
  Passphrase: in $PASSPHRASE_FILE
  SHA-1:      $NEW_HASH
Put the file and the passphrase in your password manager, then delete both files:
  rm "$BACKUP" "$PASSPHRASE_FILE"
Restore it with: scripts/make-signing-cert.sh --import <file>

BACKUP_NOTE
fi
P12_PASS=$STRIPLE_SIGNING_P12_PASSWORD

say "Making the keychain $STRIPLE_SIGNING_KEYCHAIN"
KC_PASS=$("$OPENSSL" rand -hex 24)
# Quote in assignments: a failed quote then stops the script (set -e). Inside a string it would not.
KC=$(striple_security_quote "$STRIPLE_SIGNING_KEYCHAIN")
Q_ITEM=$(striple_security_quote "$STRIPLE_SIGNING_PASSWORD_ITEM")
Q_USER=$(striple_security_quote "$USER")
Q_NOTE=$(striple_security_quote "Unlocks $STRIPLE_SIGNING_KEYCHAIN for Striple builds")
Q_P12=$(striple_security_quote "$WORK/identity.p12")
Q_P12_PASS=$(striple_security_quote "$P12_PASS")
striple_security_secret "create-keychain -p $KC_PASS $KC"
"$STRIPLE_SECURITY" set-keychain-settings "$STRIPLE_SIGNING_KEYCHAIN"
striple_security_secret "unlock-keychain -p $KC_PASS $KC"
striple_security_secret "add-generic-password -U -s $Q_ITEM -a $Q_USER -w $KC_PASS -T /usr/bin/security -j $Q_NOTE"

say "Adding the identity (codesign only)"
striple_security_secret "import $Q_P12 -k $KC -f pkcs12 -P $Q_P12_PASS -T /usr/bin/codesign" >/dev/null
striple_security_secret "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $KC_PASS $KC" >/dev/null
striple_signing_add_to_search_list

HASH=$(striple_signing_identity) || die "the identity is not usable after the import"
verify_identity "$HASH"
say "The identity \"$STRIPLE_SIGNING_NAME\" ($HASH) signs with no prompt."

if [[ "$(tr 'a-f' 'A-F' <<<"$HASH")" != "$NEW_HASH" ]]; then
    die "the keychain identity ($HASH) is not the certificate in the backup ($NEW_HASH)"
fi

if [[ -n "$PIN" ]] && striple_sha1_equal "$HASH" "$PIN"; then
    STEP1="$UPDATES_ENV pins this identity already. Nothing to change there."
elif [[ -n "$PIN" ]]; then
    STEP1="Set STRIPLE_SIGNING_CERT_SHA1=$HASH in $UPDATES_ENV (it pins $PIN now).
     This changes the identity of the releases. After the next update, every installed copy
     loses the Accessibility permission while the switch still shows on. Tell the users in the
     release notes: click Settings > Mac Setup > Reset Permission, then turn Striple on."
else
    STEP1="Set STRIPLE_SIGNING_CERT_SHA1=$HASH in $UPDATES_ENV if releases use this identity."
fi
cat <<NEXT

Done. Next steps:
  1. $STEP1
  2. make install    (build-app.sh now signs with "$STRIPLE_SIGNING_NAME")
  3. Open the new Striple. If it says "Accessibility permission needed", make a new Accessibility
     entry: turning the switch off and on is not enough, because the old entry keeps the requirement
     of the old build. Click Settings > Mac Setup > Reset Permission
     (or run: tccutil reset Accessibility com.fskroes.Striple, then click Request Permission).
     Turn Striple on. Later rebuilds keep the permission.
NEXT
