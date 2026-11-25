#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${EARMARK_TEXT_NATIVE_BUILD_ROOT:-$HOME/Developer/earmark-validation/1.1.0}"
revision=9578bd3fe48b793cf193c2e4615ec2f24a2ea92a
source_root="$build_root/llama-source"
output_root="$build_root/llama-build"
mkdir -p "$build_root"
if [ ! -d "$source_root/.git" ]; then
    git init -q "$source_root"
    git -C "$source_root" remote add origin https://github.com/ggml-org/llama.cpp.git
fi
git -C "$source_root" fetch --depth 1 origin "$revision"
git -C "$source_root" checkout --detach "$revision"
test "$(git -C "$source_root" rev-parse HEAD)" = "$revision"
cmake -S "$source_root" -B "$output_root" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DBUILD_SHARED_LIBS=OFF -DGGML_OPENMP=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF
cmake --build "$output_root" --target llama -j4
bridge="$repo_root/Packages/TextGenerationNative/Bridge"
framework="$build_root/EarmarkLlama.framework"
mkdir -p "$framework/Versions/A/Headers" "$framework/Versions/A/Modules" "$framework/Versions/A/Resources"
ln -sfn A "$framework/Versions/Current"
for part in Headers Modules Resources EarmarkLlama; do ln -sfn "Versions/Current/$part" "$framework/$part"; done
archives=()
for name in llama ggml ggml-base ggml-cpu ggml-metal ggml-blas; do
    found=()
    while IFS= read -r -d '' path; do found+=("$path"); done < <(find "$output_root" -name "lib$name.a" -print0)
    test "${#found[@]}" = 1
    archives+=("-Wl,-force_load,${found[0]}")
done
xcrun clang++ -std=c++17 -dynamiclib -arch arm64 -mmacosx-version-min=26.0 \
    -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -I "$source_root/include" -I "$source_root/ggml/include" \
    "$bridge/EarmarkLlama.cpp" "${archives[@]}" \
    -framework Accelerate -framework Foundation -framework Metal -framework MetalKit \
    -install_name '@rpath/EarmarkLlama.framework/Versions/A/EarmarkLlama' -o "$framework/Versions/A/EarmarkLlama"
cp "$bridge/EarmarkLlama.h" "$framework/Versions/A/Headers/"
cat > "$framework/Versions/A/Modules/module.modulemap" <<'EOF'
framework module EarmarkLlama {
  header "EarmarkLlama.h"
  export *
}
EOF
python3 - "$framework" <<'PY'
import pathlib,plistlib,sys
root=pathlib.Path(sys.argv[1])
info=dict(CFBundleExecutable='EarmarkLlama',CFBundleIdentifier='lk.dumindu.earmark.text-native',
          CFBundleName='EarmarkLlama',CFBundlePackageType='FMWK',CFBundleVersion='1',
          CFBundleShortVersionString='1.0',CFBundleSupportedPlatforms=['MacOSX'],LSMinimumSystemVersion='26.0')
(root/'Versions/A/Resources/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - --timestamp=none "$framework"
codesign --verify --strict "$framework"
test "$(lipo -archs "$framework/Versions/A/EarmarkLlama")" = arm64
artifact="$build_root/EarmarkLlama.xcframework"
if [ -d "$artifact" ]; then rm -rf "$artifact"; fi
xcodebuild -create-xcframework -framework "$framework" -output "$artifact"
vendor="$repo_root/Packages/TextGenerationNative/Vendor"
mkdir -p "$vendor/Licences"
/usr/bin/ditto "$artifact" "$vendor/EarmarkLlama.xcframework"
cp "$source_root/LICENSE" "$vendor/Licences/llama.cpp-and-ggml-MIT.txt"
python3 - "$repo_root" "$revision" <<'PY'
import hashlib,json,pathlib,sys
repo=pathlib.Path(sys.argv[1]);root=repo/'Packages/TextGenerationNative/Vendor'
files=[]
for path in sorted(root.rglob('*')):
    if path.is_file() and not path.is_symlink() and path.name!='provenance.json':
        files.append(dict(path=str(path.relative_to(root)),bytes=path.stat().st_size,sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
bridge={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (repo/'Packages/TextGenerationNative/Bridge').iterdir() if p.is_file()}
metadata=dict(repository='https://github.com/ggml-org/llama.cpp',revision=sys.argv[2],deploymentTarget='26.0',
              architectures=['arm64'],backends=['metal','cpu'],embeddedMetal=True,networkRuntime=False,
              buildScript='scripts/build-text-generation-native.sh',bridge=bridge,files=files)
metadata['symlinks'] = {str(p.relative_to(root)): str(p.readlink()) for p in sorted(root.rglob('*')) if p.is_symlink()}
(root/'provenance.json').write_text(json.dumps(metadata,indent=2)+'\n')
PY
