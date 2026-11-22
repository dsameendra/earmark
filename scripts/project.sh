#!/bin/bash
# Keep Xcode's coordinated project reads and build products outside cloud-synced Documents.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${EARMARK_BUILD_ROOT:-$HOME/Library/Caches/EarmarkBuild}"
mkdir -p "$build_root"
for directory in App Packages Config Brand UITests; do
    if [ ! -e "$build_root/$directory" ]; then ln -s "$repo_root/$directory" "$build_root/$directory"; fi
done
xcodegen generate --spec "$repo_root/project.yml" --project "$build_root" > "$build_root/xcodegen.log"
if [ -f "$repo_root/Config/Package.resolved" ]; then
    lock_directory="$build_root/Earmark.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
    mkdir -p "$lock_directory"
    cp "$repo_root/Config/Package.resolved" "$lock_directory/Package.resolved"
fi
printf '%s\n' "$build_root/Earmark.xcodeproj"
