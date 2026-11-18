#!/bin/zsh
# Local manual QA only; builds three disposable windows, never runs in headless CI.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_app="$task_root/artifacts/CloseTarget.app"
mkdir -p "$task_app/Contents/MacOS" "$task_root/artifacts/module-cache"
xcrun swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos13.0 \
    -module-cache-path "$task_root/artifacts/module-cache" \
    "$task_root/tests/fixtures/CloseTargetFixture.swift" -framework AppKit \
    -o "$task_app/Contents/MacOS/CloseTarget"
python3 - "$task_app" <<'PY'
from pathlib import Path
import plistlib, sys
app = Path(sys.argv[1])
info = {'CFBundleIdentifier':'local.ctrlswitch.close-target', 'CFBundleName':'CtrlSwitch Close Target',
        'CFBundleDisplayName':'CtrlSwitch 关闭测试', 'CFBundleExecutable':'CloseTarget', 'CFBundlePackageType':'APPL'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - --timestamp=none "$task_app"
printf 'Built disposable close fixture: %s\n' "$task_app"
