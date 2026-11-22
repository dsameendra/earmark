#!/bin/bash
# Create Earmark's self-signed release code-signing certificate in the login Keychain (no Apple account needed).
# Idempotent: an existing valid identity with the same name is left alone. Keys never touch the repository.
#   scripts/make-signing-identity.sh            create (or confirm) the identity
#   scripts/make-signing-identity.sh --dry-run  print what would happen; changes nothing
#
# Why a stable certificate matters: codesign's default designated requirement for a self-signed identity is
#   identifier "lk.dumindu.earmark.Earmark" and certificate leaf = H"<SHA-1 of this certificate>"
# macOS privacy (TCC) grants such as Microphone, System Audio and Accessibility, and Sparkle's check that an
# update comes from the same publisher, are matched against that requirement. It stays identical across versions
# only while every release is signed with this same certificate. Re-creating it (new key) changes the hash, so
# users would be asked to re-grant permissions. Back the identity up (see the instructions printed below).
set -euo pipefail
name="${EARMARK_SIGN_IDENTITY_NAME:-Earmark Release Signing}"
keychain="${EARMARK_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
days=3650
dry_run=0
case "${1:-}" in
    "") ;;
    --dry-run) dry_run=1 ;;
    *) printf 'Usage: %s [--dry-run]\n' "$0" >&2; exit 64 ;;
esac
case "$name" in *[\"\\$\`]*|"") echo 'Invalid identity name.' >&2; exit 64 ;; esac
case "$name" in "Developer ID"*|"Apple "*|"-") echo 'Choose a name that does not imitate an Apple-issued identity.' >&2; exit 64 ;; esac

existing="$(/usr/bin/security find-identity -v -p codesigning "$keychain" 2>/dev/null || true)"
if printf '%s\n' "$existing" | grep -Fq "\"$name\""; then
    printf 'Identity "%s" already exists and is valid; nothing changed.\n' "$name"
    printf '%s\n' "$existing" | grep -F "\"$name\"" || true
    exit 0
fi
if /usr/bin/security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
    echo "A certificate named \"$name\" exists but is not a valid code-signing identity (missing private key or trust)." >&2
    echo 'Open Keychain Access, delete the stale certificate, then run this script again. It will not overwrite it.' >&2
    exit 1
fi
if [ "$dry_run" = 1 ]; then
    printf 'Would create a %d-day self-signed RSA-2048 code-signing certificate "%s" (EKU codeSigning, critical) in %s,\n' "$days" "$name" "$keychain"
    echo 'import it with codesign access, and mark it trusted for code signing for the current user (a macOS password prompt appears).'
    exit 0
fi
openssl_bin=/usr/bin/openssl  # Apple's LibreSSL writes PKCS#12 files that `security import` accepts.
work="$(mktemp -d "${TMPDIR:-/tmp}/earmark-identity.XXXXXX")"
chmod 700 "$work"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
password="$($openssl_bin rand -hex 24)"
cat > "$work/openssl.cnf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
O = Earmark
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONF
$openssl_bin req -x509 -newkey rsa:2048 -nodes -days "$days" -sha256 -config "$work/openssl.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
$openssl_bin pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" -passout "pass:$password" -out "$work/identity.p12"
/usr/bin/security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# Trust for code signing in the user domain only (no sudo, no system-wide change). Without it the identity is not "valid".
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"
fingerprint="$($openssl_bin x509 -in "$work/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2)"
printf 'Created self-signed code-signing identity "%s" (SHA-1 %s, valid %d days).\n' "$name" "$fingerprint" "$days"
cat <<NOTES

Next steps
  1. Use it:   export EARMARK_SIGN_IDENTITY='$name'
  2. The first signing run may ask Keychain for access to the private key; choose "Always Allow".
  3. BACK IT UP NOW. If the private key is lost, the next release cannot match this designated requirement:
       Keychain Access > login > My Certificates > "$name" > right-click > Export... > .p12 (set a strong passphrase)
     or:  security export -k "$keychain" -t identities -f pkcs12 -o ~/Earmark-Release-Signing.p12
     Store the .p12 and its passphrase in a password manager or offline vault. Never put it in this repository
     (verify-release.py rejects .p12/.pem/.key files inside the app).
  4. Restore on another Mac:  security import Earmark-Release-Signing.p12 -k login.keychain-db -T /usr/bin/codesign
     then re-run this script; it will report the identity as valid and not create a second one.
  5. Confirm: security find-identity -v -p codesigning     and, after a build,   codesign -d -r- Earmark.app
NOTES
