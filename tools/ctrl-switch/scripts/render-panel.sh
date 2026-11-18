#!/bin/zsh
# Local manual QA only: displays synthetic cards briefly, writes their own view, then exits.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_output="$task_root/artifacts/panel-fixture.png"
task_mode="${1:-}"
if [[ "$task_mode" == '--lifecycle' ]]; then
    task_output="$task_root/artifacts/panel-lifecycle.json"
fi
mkdir -p "$task_root/artifacts/module-cache"
xcrun swiftc -O -swift-version 5 -D UI_FIXTURE \
    -module-cache-path "$task_root/artifacts/module-cache" \
    "$task_root/src/SwitcherState.swift" "$task_root/src/WindowActivation.swift" "$task_root/src/WindowInventory.swift" \
    "$task_root/src/WindowKeyRecords.swift" \
    "$task_root/src/WindowCloseState.swift" \
    "$task_root/src/WindowPreviewProvider.swift" "$task_root/src/SwitcherPanel.swift" \
    "$task_root/tests/fixtures/PanelFixture.swift" \
    -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit \
    -o "$task_root/artifacts/PanelFixture"
"$task_root/artifacts/PanelFixture" "$task_output" "$task_mode"
printf 'Rendered synthetic UI fixture: %s\n' "$task_output"
