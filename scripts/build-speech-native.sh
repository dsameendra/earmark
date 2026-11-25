#!/bin/bash
# Rebuild the pinned native speech framework. No models or Python runtime are bundled.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${EARMARK_SPEECH_NATIVE_BUILD_ROOT:-$HOME/Developer/earmark-validation/speech-native}"
revision=cfa237c2551a4b2d3a56ff8fe5461e3c67c51772
source_root="$build_root/transcribe-source"
output_root="$build_root/transcribe-build"
mkdir -p "$build_root"
if [ ! -d "$source_root/.git" ]; then
    git init -q "$source_root"
    git -C "$source_root" remote add origin https://github.com/handy-computer/transcribe.cpp.git
fi
git -C "$source_root" fetch --depth 1 origin "$revision"
git -C "$source_root" checkout --detach "$revision"
test "$(git -C "$source_root" rev-parse HEAD)" = "$revision"
cmake -S "$source_root" -B "$output_root" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DTRANSCRIBE_BUILD_TESTS=OFF -DTRANSCRIBE_BUILD_EXAMPLES=OFF -DTRANSCRIBE_BUILD_TOOLS=OFF \
    -DTRANSCRIBE_BUILD_SHARED=OFF -DTRANSCRIBE_USE_OPENMP=OFF -DTRANSCRIBE_METAL=ON \
    -DTRANSCRIBE_ENABLE_VALIDATION_HOOKS=OFF -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF
cmake --build "$output_root" --target transcribe -j4
framework="$build_root/CTranscribe.framework"
mkdir -p "$framework/Versions/A/Headers" "$framework/Versions/A/Modules" "$framework/Versions/A/Resources"
ln -sfn A "$framework/Versions/Current"
for part in Headers Modules Resources CTranscribe; do ln -sfn "Versions/Current/$part" "$framework/$part"; done
# Keep same-basename archive members and Objective-C metadata. Never libtool-merge these archives.
archives=()
for name in transcribe ggml ggml-cpu ggml-metal ggml-base; do
    found=()
    while IFS= read -r -d '' path; do found+=("$path"); done < <(find "$output_root" -name "lib$name.a" -print0)
    test "${#found[@]}" = 1
    archives+=("-Wl,-force_load,${found[0]}")
done
xcrun clang++ -dynamiclib -arch arm64 -mmacosx-version-min=26.0 \
    -isysroot "$(xcrun --sdk macosx --show-sdk-path)" "${archives[@]}" \
    -framework Accelerate -framework Foundation -framework Metal -framework MetalKit \
    -install_name '@rpath/CTranscribe.framework/Versions/A/CTranscribe' \
    -o "$framework/Versions/A/CTranscribe"
python3 - "$repo_root" "$source_root" "$framework" "$revision" <<'PY'
import hashlib, json, pathlib, plistlib, shutil, sys
repo, source, framework = map(pathlib.Path, sys.argv[1:4])
revision = sys.argv[4]
headers = framework / 'Versions/A/Headers'
for header in [source / 'include/transcribe.h', *sorted((source / 'include/transcribe').glob('*.h'))]:
    (headers / header.name).write_text(header.read_text().replace('#include "transcribe/', '#include "'))
module = 'framework module CTranscribe {\n' + ''.join(f'  header "{h.name}"\n' for h in sorted(headers.glob('*.h'))) + '  export *\n}\n'
(framework / 'Versions/A/Modules/module.modulemap').write_text(module)
info = dict(CFBundleExecutable='CTranscribe', CFBundleIdentifier='lk.dumindu.earmark.speech-native',
            CFBundleName='CTranscribe', CFBundlePackageType='FMWK', CFBundleVersion='1',
            CFBundleShortVersionString='0.4.2', CFBundleSupportedPlatforms=['MacOSX'], LSMinimumSystemVersion='26.0')
(framework / 'Versions/A/Resources/Info.plist').write_bytes(plistlib.dumps(info))
# Require verbatim reviewed bindings before publishing an artifact against their ABI.
for header in (source / 'bindings/swift/Sources/TranscribeCpp').glob('*.swift'):
    if (repo / 'Packages/SpeechNative/Vendor/Swift' / header.name).read_bytes() != header.read_bytes():
        raise ValueError('Vendored Swift wrapper changed: ' + header.name)
PY
codesign --force --sign - --timestamp=none "$framework"
artifact="$build_root/TranscribeCpp.xcframework"
if [ -d "$artifact" ]; then rm -rf "$artifact"; fi
xcodebuild -create-xcframework -framework "$framework" -output "$artifact"
codesign --verify --strict "$framework"
test "$(lipo -archs "$framework/Versions/A/CTranscribe")" = arm64
/usr/bin/ditto "$artifact" "$repo_root/Packages/SpeechNative/Vendor/TranscribeCpp.xcframework"
python3 - "$repo_root" "$source_root" "$revision" <<'PY'
import hashlib, json, os, pathlib, sys
repo, source = map(pathlib.Path, sys.argv[1:3])
root = repo / 'Packages/SpeechNative/Vendor'
files = []
for path in sorted(root.rglob('*')):
    if path.is_file() and not path.is_symlink() and path.name != 'provenance.json':
        files.append(dict(path=str(path.relative_to(root)), bytes=path.stat().st_size,
                          sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
metadata = dict(repository='https://github.com/handy-computer/transcribe.cpp', revision=sys.argv[3],
                version='0.4.2', abiHash=(source / 'include/transcribe.abihash').read_text().strip(),
                deploymentTarget='26.0', architectures=['arm64'], backends=['metal', 'cpu'],
                embeddedMetal=True, buildScript='scripts/build-speech-native.sh', files=files)
metadata['symlinks'] = {str(p.relative_to(root)): str(p.readlink()) for p in sorted(root.rglob('*')) if p.is_symlink()}
(root / 'provenance.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY
