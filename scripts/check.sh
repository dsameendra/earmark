#!/bin/bash
# Unit suites are serial so engine/performance tests do not compete for the GPU or unified memory.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-all}"
case "$mode" in all|unit|build|ui) ;; *) echo 'Usage: scripts/check.sh all|unit|build|ui' >&2; exit 64 ;; esac
report_root="${EARMARK_REPORT_ROOT:-$HOME/Library/Caches/EarmarkBuild/reports}"
mkdir -p "$report_root"
python3 "$repo_root/scripts/check-dependencies.py"
if [ "$mode" = all ] || [ "$mode" = unit ]; then
    for package in AppCore Persistence DesignSystem ModelStore AudioCapture Processing Export Permissions Meetings Translation Transcription Diarization LiveCaptions Dictation Jobs QwenASR Features NLLBNative; do
        printf 'Testing %s\n' "$package"
        if ! swift test --no-parallel --package-path "$repo_root/Packages/$package" > "$report_root/$package.log" 2>&1; then
            printf '%s\n' "--- failing tests and errors in $package ---"
            sed 's/\x1b\[[0-9;]*m//g' "$report_root/$package.log" | grep -aE '✘ Test |recorded an issue|error:' | sort -u | cut -c1-300 | head -40 || true
            printf '%s\n' '--- end ---'
            tail -20 "$report_root/$package.log"
            exit 1
        fi
        rg 'Test run with|tests? passed|Test Suite.*passed' "$report_root/$package.log" | tail -2 || true
    done
fi
if [ "$mode" = all ] || [ "$mode" = build ] || [ "$mode" = ui ]; then
    project="$($repo_root/scripts/project.sh)"
    action=build
    scheme=Earmark
    configuration=Debug
    signing=(CODE_SIGNING_ALLOWED=NO)
    if [ "$mode" = ui ]; then
        action=test
        scheme=Earmark-QA
        configuration=DebugUI
        signing=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
    fi
    xcodebuild -project "$project" -scheme "$scheme" -configuration "$configuration" -destination 'platform=macOS' \
        -disableAutomaticPackageResolution -skipPackageUpdates "${signing[@]}" ${EARMARK_XCODEBUILD_EXTRA:-} "$action" > "$report_root/xcode-$action.log" 2>&1 || {
        printf '%s\n' '--- compiler and test errors ---'
        sed 's/\x1b\[[0-9;]*m//g' "$report_root/xcode-$action.log" | grep -aE '(error|warning: unre)[: ]|\*\* .* FAILED' | sort -u | head -40 || true
        printf '%s\n' '--- end of log ---'
        tail -40 "$report_root/xcode-$action.log"; exit 1;
    }
    tail -4 "$report_root/xcode-$action.log"
fi
