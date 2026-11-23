#!/bin/bash
# Fail if a tracked file looks like key material. Complements GitHub secret scanning and push protection.
set -euo pipefail
cd "$(dirname "$0")/.."
bad="$(git ls-files | grep -E '\.(p12|pfx|pem|key|keychain|keychain-db|mobileprovision|provisionprofile)$|private-key|\.passphrase$|id_(rsa|ed25519)$' || true)"
if [ -n "$bad" ]; then
    printf 'Tracked files that look like secrets:\n%s\n' "$bad" >&2
    exit 1
fi
# --cached reads the staged blobs, not the working tree (fast, and unaffected by files that are not downloaded locally).
if git grep --cached -IlE -e '-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----' -- . ':!scripts/check-no-secrets.sh' | grep -q .; then
    echo 'A tracked file contains a PEM private key block.' >&2
    exit 1
fi
echo 'No key material tracked.'
