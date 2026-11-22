#!/bin/bash
# Sparkle EdDSA key setup and appcast generation for a self-signed Earmark release. Publishes nothing.
#   scripts/make-appcast.sh keys                 create the EdDSA key in the login Keychain (if absent) and print the PUBLIC key
#   scripts/make-appcast.sh appcast RELEASE_DIR  sign the *-selfsigned.dmg in RELEASE_DIR and write RELEASE_DIR/appcast.xml
#
# The private EdDSA key lives only in the login Keychain (Sparkle's generate_keys). It is never written to the repo.
# Back it up once with:  "$SPARKLE_BIN/generate_keys" --account earmark -x ~/earmark-sparkle-private-key   (store offline, never commit)
#
# Sparkle tools come from the pinned Sparkle version (project.yml exactVersion). Set EARMARK_SPARKLE_BIN to a directory
# containing generate_keys, sign_update and generate_appcast, or let this script search the build cache's package
# artifacts (SourcePackages/artifacts/sparkle/Sparkle/bin) and package checkouts. If absent, download
# Sparkle-<version>.tar.xz from https://github.com/sparkle-project/Sparkle/releases and point EARMARK_SPARKLE_BIN at its bin/.
#
# Hosting (GitHub Releases of github.com/dsameendra/earmark; nothing is uploaded here):
#   1. Create release tag v<version>; attach the DMG and its .sha256.
#   2. Attach appcast.xml to the SAME release. The feed URL baked into the app can then be
#        https://github.com/dsameendra/earmark/releases/latest/download/appcast.xml
#      which always serves the appcast of the newest non-prerelease release (it must therefore list every
#      supported version: set EARMARK_PREVIOUS_APPCAST to the previous appcast.xml so history is preserved).
#   3. Alternative: serve appcast.xml from GitHub Pages (e.g. https://dsameendra.github.io/earmark/appcast.xml)
#      and keep DMGs on Releases.
# The DMG enclosure URL is EARMARK_DOWNLOAD_URL_PREFIX + the DMG name; default
#   https://github.com/dsameendra/earmark/releases/download/v<version>/
set -euo pipefail
account="${EARMARK_SPARKLE_ACCOUNT:-earmark}"  # dedicated key account, separate from other apps (e.g. Downer)
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${EARMARK_BUILD_ROOT:-$HOME/Library/Caches/EarmarkBuild}"
sparkle_version="$(sed -n 's/^ *exactVersion: *//p' "$repo_root/project.yml" | head -1)"
usage() { printf 'Usage: %s keys | appcast RELEASE_DIR\n' "$0" >&2; exit 64; }
[ "$#" -ge 1 ] || usage
command="$1"

find_sparkle_bin() {
    local candidate
    for candidate in "${EARMARK_SPARKLE_BIN:-}" \
        "$build_root/ReleaseDerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin" \
        "${EARMARK_SOURCE_PACKAGES_DIR:-/nonexistent}/artifacts/sparkle/Sparkle/bin" \
        "$build_root/ReleaseDerivedData/SourcePackages/checkouts/Sparkle/bin"; do
        if [ -n "$candidate" ] && [ -x "$candidate/generate_keys" ] && [ -x "$candidate/generate_appcast" ] && [ -x "$candidate/sign_update" ]; then
            printf '%s\n' "$candidate"; return 0
        fi
    done
    {
        echo "Sparkle ${sparkle_version:-?} command-line tools were not found."
        echo 'Set EARMARK_SPARKLE_BIN to the bin/ directory of the matching Sparkle release (generate_keys, sign_update, generate_appcast).'
    } >&2
    return 1
}

case "$command" in
keys)
    [ "$#" -eq 1 ] || usage
    bin="$(find_sparkle_bin)"
    # Creates the key only when this Keychain has none; otherwise it reports the existing public key. Idempotent.
    "$bin/generate_keys" --account "$account" >&2
    public_key="$("$bin/generate_keys" --account "$account" -p)"
    printf 'Public key (safe to publish and embed): %s\n' "$public_key"
    printf "export EARMARK_SPARKLE_PUBLIC_KEY='%s'\n" "$public_key"
    ;;
appcast)
    [ "$#" -eq 2 ] || usage
    release_dir="$(cd "$2" && pwd)"
    bin="$(find_sparkle_bin)"
    shopt -s nullglob
    dmgs=("$release_dir"/Earmark-*-selfsigned.dmg)
    [ "${#dmgs[@]}" -eq 1 ] || { echo "Expected exactly one Earmark-*-selfsigned.dmg in $release_dir" >&2; exit 64; }
    dmg="${dmgs[0]}"
    [ -f "$release_dir/app-manifest.json" ] || { echo 'Missing app-manifest.json; run scripts/release.sh selfsigned first.' >&2; exit 64; }
    [ ! -e "$release_dir/appcast.xml" ] || { echo "Refusing to overwrite $release_dir/appcast.xml" >&2; exit 64; }
    version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$release_dir/app-manifest.json")"
    prefix="${EARMARK_DOWNLOAD_URL_PREFIX:-https://github.com/dsameendra/earmark/releases/download/v$version/}"
    case "$prefix" in https://*/) ;; *) echo 'EARMARK_DOWNLOAD_URL_PREFIX must be an https:// URL ending in /.' >&2; exit 64 ;; esac
    stage="$(mktemp -d "${TMPDIR:-/tmp}/earmark-appcast.XXXXXX")"
    trap 'rm -rf "$stage"' EXIT
    cp "$dmg" "$stage/"
    if [ -n "${EARMARK_PREVIOUS_APPCAST:-}" ]; then cp "$EARMARK_PREVIOUS_APPCAST" "$stage/appcast.xml"; fi
    # generate_appcast reads the version from the DMG's app and signs with the Keychain EdDSA key.
    "$bin/generate_appcast" --account "$account" --download-url-prefix "$prefix" "$stage"
    cp "$stage/appcast.xml" "$release_dir/appcast.xml"
    "$bin/sign_update" --account "$account" "$dmg" > "$release_dir/dmg-eddsa-signature.txt"
    python3 "$repo_root/scripts/verify-appcast.py" "$release_dir/appcast.xml" --dmg "$dmg" --manifest "$release_dir/app-manifest.json" --url-prefix "$prefix"
    printf 'Wrote %s\nNothing was published. Upload the DMG, .sha256 and appcast.xml to the GitHub release after approval.\n' "$release_dir/appcast.xml"
    ;;
*) usage ;;
esac
