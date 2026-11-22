#!/bin/bash
# Rebuild the bundled static runtime from pinned upstream sources. Requires CMake >=3.24 and Ninja.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${EARMARK_NATIVE_BUILD_ROOT:-${TMPDIR:-/tmp}/earmark-native-rebuild}"
ct2_revision=617405f4b050e994e829d527da6caa0e0030afe7
sp_revision=31646a467d2051eb904e0b45de3a73e91fe1c1e3
command -v cmake >/dev/null
command -v ninja >/dev/null
mkdir -p "$build_root"
fetch_source() {
    local url="$1" revision="$2" destination="$3"
    if [ ! -d "$destination/.git" ]; then
        git init -q "$destination"
        git -C "$destination" remote add origin "$url"
    fi
    git -C "$destination" fetch --depth 1 origin "$revision"
    git -C "$destination" checkout --detach "$revision"
    git -C "$destination" submodule update --init --recursive --depth 1
    test "$(git -C "$destination" rev-parse HEAD)" = "$revision"
}
fetch_source https://github.com/OpenNMT/CTranslate2.git "$ct2_revision" "$build_root/CTranslate2"
fetch_source https://github.com/google/sentencepiece.git "$sp_revision" "$build_root/sentencepiece"
cmake -S "$build_root/CTranslate2" -B "$build_root/ct2-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_CXX_STANDARD=17 -DBUILD_SHARED_LIBS=OFF -DBUILD_CLI=OFF -DBUILD_TESTS=OFF \
    -DWITH_MKL=OFF -DWITH_ACCELERATE=ON -DWITH_RUY=ON -DOPENMP_RUNTIME=NONE -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$build_root/ct2-build" -j 4
cmake -S "$build_root/sentencepiece" -B "$build_root/sp-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DSPM_ENABLE_SHARED=OFF -DSPM_ENABLE_TCMALLOC=OFF -DSPM_BUILD_TEST=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$build_root/sp-build" --target sentencepiece-static -j 2
xcrun clang++ -std=c++17 -O3 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 \
    -I "$repo_root/NativeRuntime/Bridge/include" -isystem "$build_root/CTranslate2/include" \
    -isystem "$build_root/sentencepiece/src" -c "$repo_root/NativeRuntime/Bridge/earmark_nllb.cpp" -o "$build_root/earmark_nllb.o"
libraries=()
while IFS= read -r -d '' path; do libraries+=("$path"); done < <(find "$build_root/ct2-build" -name '*.a' -print0)
xcrun libtool -static -o "$build_root/libEarmarkNLLBCore.a" "${libraries[@]}" "$build_root/sp-build/src/libsentencepiece.a" "$build_root/earmark_nllb.o"
mkdir -p "$build_root/headers"
cp "$repo_root/NativeRuntime/Bridge/include/earmark_nllb.h" "$build_root/headers/"
printf 'module EarmarkNLLBCore { header "earmark_nllb.h" export * }\n' > "$build_root/headers/module.modulemap"
artifact="$build_root/EarmarkNLLBCore.xcframework"
# Remove only this script's previously generated output; never the checked-in artifact before a successful build.
if [ -d "$artifact" ]; then rm -rf "$artifact"; fi
xcodebuild -create-xcframework -library "$build_root/libEarmarkNLLBCore.a" -headers "$build_root/headers" -output "$artifact"
/usr/bin/ditto "$artifact" "$repo_root/Packages/NLLBNative/Vendor/EarmarkNLLBCore.xcframework"
python3 - "$repo_root" <<'PROVENANCE'
from pathlib import Path
import hashlib, json, sys
root = Path(sys.argv[1])
metadata_path = root / 'Packages/NLLBNative/Vendor/provenance.json'
metadata = json.loads(metadata_path.read_text())
archive = root / 'Packages/NLLBNative/Vendor/EarmarkNLLBCore.xcframework/macos-arm64/libEarmarkNLLBCore.a'
metadata['archiveSHA256'] = hashlib.sha256(archive.read_bytes()).hexdigest()
bridge = hashlib.sha256()
for relative in ['NativeRuntime/Bridge/include/earmark_nllb.h', 'NativeRuntime/Bridge/earmark_nllb.cpp']:
    bridge.update(relative.encode())
    bridge.update((root / relative).read_bytes())
metadata['bridgeSHA256'] = bridge.hexdigest()
metadata_path.write_text(json.dumps(metadata, indent=2) + '\n')
print('Rebuilt native runtime and updated archive/bridge provenance.')
PROVENANCE
