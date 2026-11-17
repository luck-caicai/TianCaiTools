#!/bin/zsh
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_artifacts="$task_root/artifacts"
task_arch="$(uname -m)"
mkdir -p "$task_artifacts/module-cache"
rm -f "$task_artifacts/self-test.json"
xcrun swiftc -O -swift-version 5 -target "$task_arch-apple-macos13.0" \
    -module-cache-path "$task_artifacts/module-cache" \
    "$task_root/src/ShortcutTransformer.swift" \
    "$task_root/src/SwitcherState.swift" \
    "$task_root"/tests/*.swift \
    -o "$task_artifacts/ShortcutTransformerTests"
"$task_artifacts/ShortcutTransformerTests" --report "$task_artifacts/self-test.json"
