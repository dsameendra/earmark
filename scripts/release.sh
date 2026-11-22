#!/bin/bash
# local: ad-hoc test package. selfsigned: stable self-signed identity + Sparkle EdDSA, no Apple account, no notarization.
# distribution: Developer ID signing and Apple notarization. Set EARMARK_RELEASE_DRY_RUN=1 to validate inputs and stop.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-local}"
case "$mode" in local|selfsigned|distribution) ;; *) printf 'Usage: %s local|selfsigned|distribution\n' "$0" >&2; exit 64 ;; esac
for tool in python3 git xcodegen xcodebuild xcrun hdiutil codesign security; do command -v "$tool" >/dev/null; done
identity=-
feed=""
public_key=""
if [ "$mode" = selfsigned ]; then
    : "${EARMARK_SIGN_IDENTITY:?Set the self-signed identity name (scripts/make-signing-identity.sh creates 'Earmark Release Signing')}"
    : "${EARMARK_UPDATE_FEED_URL:?Set the HTTPS Sparkle appcast URL}"
    : "${EARMARK_SPARKLE_PUBLIC_KEY:?Set the Sparkle Ed25519 public key (scripts/make-appcast.sh keys)}"
    identity="$EARMARK_SIGN_IDENTITY"
    feed="$EARMARK_UPDATE_FEED_URL"
    public_key="$EARMARK_SPARKLE_PUBLIC_KEY"
fi
if [ "$mode" = distribution ]; then
    : "${EARMARK_SIGN_IDENTITY:?Set a Developer ID Application identity}"
    : "${EARMARK_UPDATE_FEED_URL:?Set the HTTPS Sparkle appcast URL}"
    : "${EARMARK_SPARKLE_PUBLIC_KEY:?Set the Sparkle Ed25519 public key}"
    : "${EARMARK_NOTARY_PROFILE:?Set a notarytool Keychain profile}"
    identity="$EARMARK_SIGN_IDENTITY"
    feed="$EARMARK_UPDATE_FEED_URL"
    public_key="$EARMARK_SPARKLE_PUBLIC_KEY"
fi
# Validate before building, signing, or submitting anything. Do not print credentials or environment contents.
python3 - "$repo_root" "$mode" "$identity" "$feed" "$public_key" <<'PY'
from pathlib import Path
import hashlib,importlib.util,json,subprocess,sys
root=Path(sys.argv[1]);mode,identity,feed,key=sys.argv[2:]
spec=importlib.util.spec_from_file_location('release_verifier',root/'scripts/verify-release.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
metadata=json.loads((root/'Packages/NLLBNative/Vendor/provenance.json').read_text())
archive=root/'Packages/NLLBNative/Vendor/EarmarkNLLBCore.xcframework/macos-arm64/libEarmarkNLLBCore.a'
module.require(module.sha256(archive)==metadata['archiveSHA256'],'native archive differs from its provenance')
bridge=hashlib.sha256()
for relative in ['NativeRuntime/Bridge/include/earmark_nllb.h','NativeRuntime/Bridge/earmark_nllb.cpp']:
 bridge.update(relative.encode());bridge.update((root/relative).read_bytes())
module.require(bridge.hexdigest()==metadata.get('bridgeSHA256'),'native C bridge changed without rebuilding/updating its provenance')
if mode=='selfsigned':
 module.validate_update_configuration(feed,key)
 identities=subprocess.check_output(['/usr/bin/security','find-identity','-v','-p','codesigning'],text=True)
 module.validate_selfsigned_identity(identity,identities,module.certificate_name_lines)
 changes=subprocess.check_output(['git','-C',str(root),'status','--porcelain','--untracked-files=all','--','App','Packages','NativeRuntime','Config','project.yml','scripts',':(exclude)**/.DS_Store'],text=True)
 module.require(not changes.strip(),'commit release source and tooling before self-signed packaging')
if mode=='distribution':
 module.require(identity.startswith('Developer ID Application:'),'distribution requires a Developer ID Application identity')
 module.validate_update_configuration(feed,key)
 identities=subprocess.check_output(['/usr/bin/security','find-identity','-v','-p','codesigning'],text=True)
 module.require('"'+identity+'"' in identities,'the requested valid Developer ID identity is not available in Keychain')
 changes=subprocess.check_output(['git','-C',str(root),'status','--porcelain','--untracked-files=all','--','App','Packages','NativeRuntime','Config','project.yml','scripts',':(exclude)**/.DS_Store'],text=True)
 module.require(not changes.strip(),'commit release source and tooling before distribution packaging')
PY
if [ -n "${EARMARK_RELEASE_DRY_RUN:-}" ]; then
    printf 'Validated %s release inputs; nothing was built or signed.\n' "$mode"
    exit 0
fi
project="$(bash "$repo_root/scripts/project.sh")"
if [ -n "${EARMARK_RELEASE_ROOT:-}" ]; then
    release_root="$EARMARK_RELEASE_ROOT"
    if [ -e "$release_root" ] || [ -L "$release_root" ]; then
        echo 'EARMARK_RELEASE_ROOT must be a new, unused directory.' >&2; exit 64
    fi
    mkdir -p "$(dirname "$release_root")"
    mkdir "$release_root"
else
    mkdir -p "$repo_root/dist"
    release_root="$(mktemp -d "$repo_root/dist/Earmark-$mode-$(date +%Y%m%d-%H%M%S).XXXXXX")"
fi
release_root="$(cd "$release_root" && pwd)"
derived_data="${EARMARK_RELEASE_DERIVED_DATA:-$(dirname "$project")/ReleaseDerivedData}"
package_args=(-disableAutomaticPackageResolution -skipPackageUpdates)
if [ -n "${EARMARK_SOURCE_PACKAGES_DIR:-}" ]; then
    package_args+=(-clonedSourcePackagesDirPath "$EARMARK_SOURCE_PACKAGES_DIR")
fi
mkdir -p "$(dirname "$project")/PackagingStages"
stage_root="$(mktemp -d "$(dirname "$project")/PackagingStages/Earmark-$mode.XXXXXX")"
python3 - "$repo_root" "$release_root/build-provenance.json" "$mode" "$stage_root/Earmark.app" <<'PY'
from pathlib import Path
import datetime,json,subprocess,sys
root=Path(sys.argv[1]);destination=Path(sys.argv[2])
head=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()
changes=subprocess.check_output(['git','-C',str(root),'status','--porcelain','--untracked-files=all','--','App','Packages','NativeRuntime','Config','project.yml','scripts'],text=True).splitlines()
destination.write_text(json.dumps(dict(commit=head,mode=sys.argv[3],stagedApp=sys.argv[4],createdAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),sourceChanges=changes),indent=2)+'\n')
PY
# Compile without signing; the explicit inside-out pass below gives all nested code one consistent identity.
if ! xcodebuild -project "$project" -scheme Earmark -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" "${package_args[@]}" CODE_SIGNING_ALLOWED=NO \
    "EARMARK_UPDATE_FEED_URL=$feed" "EARMARK_SPARKLE_PUBLIC_KEY=$public_key" \
    build > "$release_root/build.log" 2>&1; then
    tail -60 "$release_root/build.log" >&2
    printf 'Build log: %s\n' "$release_root/build.log" >&2
    exit 1
fi
app="$stage_root/Earmark.app"
# Finder/File Provider attributes inherited from cloud-synced source bundles invalidate signing.
# Prepare only our new staging copy, outside Documents; never modify an installed app or its permissions.
/usr/bin/ditto --norsrc --noextattr "$derived_data/Build/Products/Release/Earmark.app" "$app"
sign_args=()
if [ "$mode" = selfsigned ]; then sign_args=(--self-signed); fi
python3 "$repo_root/scripts/sign-bundle.py" "$app" --identity "$identity" ${sign_args[@]+"${sign_args[@]}"} --entitlements "$repo_root/App/Earmark.entitlements"
verify_app() {
    if [ "$mode" = selfsigned ]; then
        python3 "$repo_root/scripts/verify-release.py" "$app" --require-self-signed --report "$release_root/app-manifest.json"
    elif [ "$mode" = distribution ]; then
        python3 "$repo_root/scripts/verify-release.py" "$app" --require-developer-id --report "$release_root/app-manifest.json"
    else
        python3 "$repo_root/scripts/verify-release.py" "$app" --report "$release_root/app-manifest.json"
    fi
}
verify_app
notarize() {
    local artifact="$1" report="$2"
    xcrun notarytool submit "$artifact" --keychain-profile "$EARMARK_NOTARY_PROFILE" --wait --output-format json > "$report"
    python3 - "$report" <<'PY'
import json,sys
from pathlib import Path
result=json.loads(Path(sys.argv[1]).read_text())
if result.get('status')!='Accepted':
 sys.exit('Notarization was not accepted; inspect the saved report before proceeding.')
PY
}
if [ "$mode" = distribution ]; then
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$release_root/notarization.zip"
    notarize "$release_root/notarization.zip" "$release_root/app-notarization.json"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$app"
    # Capture the final, stapled app that will actually be copied into the DMG.
    python3 "$repo_root/scripts/verify-release.py" "$app" --require-developer-id --report "$release_root/app-manifest.json"
fi
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")"
dmg_name="Earmark-$version-$build_number-$mode.dmg"
dmg="$release_root/$dmg_name"
bash "$repo_root/scripts/make-dmg.sh" "$app" "$dmg" "$release_root/installer-artwork" "$mode"
dmg_python="${EARMARK_DMG_PYTHON:-${EARMARK_BUILD_ROOT:-$HOME/Library/Caches/EarmarkBuild}/dmg-venv/bin/python}"
if [ "$mode" = distribution ]; then
    /usr/bin/codesign --sign "$identity" --timestamp "$dmg"
    notarize "$dmg" "$release_root/dmg-notarization.json"
    xcrun stapler staple "$dmg"
fi
if [ "$mode" = selfsigned ]; then
    "$dmg_python" "$repo_root/scripts/verify-dmg.py" "$dmg" --source-app "$app" --layout-assets "$release_root/installer-artwork" \
        --require-self-signed --report "$release_root/dmg-verification.json"
elif [ "$mode" = distribution ]; then
    "$dmg_python" "$repo_root/scripts/verify-dmg.py" "$dmg" --source-app "$app" --layout-assets "$release_root/installer-artwork" \
        --require-developer-id --report "$release_root/dmg-verification.json"
else
    "$dmg_python" "$repo_root/scripts/verify-dmg.py" "$dmg" --source-app "$app" --layout-assets "$release_root/installer-artwork" \
        --report "$release_root/dmg-verification.json"
fi
(cd "$release_root" && shasum -a 256 "$dmg_name" > "$dmg_name.sha256")
printf 'Prepared %s\n' "$dmg"
printf 'Signed app: %s\n' "$app"
printf 'Validation reports: %s\n' "$release_root"
if [ "$mode" = selfsigned ]; then
    printf 'Self-signed, not notarized. Next: scripts/make-appcast.sh appcast %q\n' "$release_root"
fi
