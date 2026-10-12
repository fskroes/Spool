#!/usr/bin/env bash
# Creates a self-signed code signing identity "Striple Local Signing" in the login keychain.
#
# Why: an ad hoc signature changes on every build, so macOS forgets the Accessibility
# permission after each rebuild. With this identity the designated requirement of the app
# (bundle ID + certificate hash) stays the same, so the permission stays.
# scripts/build-app.sh uses this identity automatically when it exists.
#
# Usage: scripts/make-signing-cert.sh [--dry-run]
#   --dry-run  make the certificate in .build/signing-cert, show it, print the keychain
#              commands, then delete the files. The keychain is not changed.
#
# Remove the identity later with:
#   security delete-identity -c "Striple Local Signing"
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly NAME="Striple Local Signing"
readonly OPENSSL=/usr/bin/openssl   # LibreSSL: its PKCS#12 output is what `security import` accepts.
readonly KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
readonly WORK="$ROOT/.build/signing-cert"
readonly DAYS=3650

DRY_RUN=0
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; exit 1 ;;
esac

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
    else
        "$@"
    fi
}

for tool in "$OPENSSL" security codesign; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done

# Valid: the certificate, its private key and the code signing trust are all there. That is what build-app.sh needs.
if [[ "$(security find-identity -v -p codesigning 2>/dev/null || true)" == *"\"$NAME\""* ]]; then
    say "The identity \"$NAME\" is in your keychain and is valid for code signing. Nothing to do."
    exit 0
fi
# The certificate can be there without the trust (the password prompt was cancelled, or the trust step failed).
# Then only the trust step runs again. Without its private key it cannot sign at all, so it must go first.
RETRUST=0
if [[ "$(security find-certificate -a -c "$NAME" 2>/dev/null || true)" == *"$NAME"* ]]; then
    if [[ "$(security find-identity -p codesigning 2>/dev/null || true)" != *"\"$NAME\""* ]]; then
        die "a certificate named \"$NAME\" is in your keychain without its private key. Remove it with:
  security delete-certificate -c \"$NAME\"
Then run this script again."
    fi
    RETRUST=1
    say "The identity \"$NAME\" is in your keychain, but macOS does not trust it for code signing yet."
fi

# The private key is written here for a moment. Delete it on every exit path.
case "$WORK" in */.build/signing-cert) ;; *) die "unexpected work directory: $WORK" ;; esac
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
rm -rf "$WORK"
mkdir -p "$WORK"
chmod 700 "$WORK"

verify_identity() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    [[ "$(security find-identity -v -p codesigning 2>/dev/null || true)" == *"\"$NAME\""* ]] \
        || die "the identity is not valid for code signing. See docs/INSTALL.md."
    say "The identity \"$NAME\" is valid for code signing."
}

next_steps() {
    cat <<EOF

Done. Next steps:
  1. make app       (build-app.sh now signs with "$NAME")
  2. make install
  3. Give Accessibility permission to Striple one more time. Later rebuilds keep it.
If codesign asks for keychain access during the build, click "Always Allow".
EOF
}

if [[ $RETRUST -eq 1 ]]; then
    security find-certificate -c "$NAME" -p > "$WORK/cert.pem"
    say "Trusting the certificate for code signing (macOS asks for your login password)"
    run security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
    verify_identity
    next_steps
    exit 0
fi

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $NAME

[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

say "Making the certificate"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
    -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# `security import` needs a non-empty password. It is random and used only here.
P12_PASS=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
    -passout "pass:$P12_PASS" -out "$WORK/identity.p12"

if [[ $DRY_RUN -eq 1 ]]; then
    "$OPENSSL" x509 -in "$WORK/cert.pem" -noout -subject -enddate -ext extendedKeyUsage 2>/dev/null \
        || "$OPENSSL" x509 -in "$WORK/cert.pem" -noout -subject -enddate -text | grep -A1 'Extended Key Usage'
    "$OPENSSL" pkcs12 -in "$WORK/identity.p12" -passin "pass:$P12_PASS" -noout && say "PKCS#12 file: OK"
fi

say "Adding the identity to $KEYCHAIN"
# -T lets codesign use the key without a prompt each time.
run security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$P12_PASS" -T /usr/bin/codesign

say "Trusting the certificate for code signing (macOS asks for your login password)"
run security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

verify_identity
next_steps
