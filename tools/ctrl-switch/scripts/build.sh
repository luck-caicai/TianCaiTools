#!/bin/zsh
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_id="$(basename "$task_root")"
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_root/Resources/Info.plist")"
task_build="$task_root/artifacts/build"
task_app="$task_root/release/CtrlSwitch.app"
if [[ "${1:-}" == '--versioned-output' ]]; then
    task_app="$task_root/release/CtrlSwitch-$task_version.app"
fi
mkdir -p "$task_build/module-cache" "$task_build/AppIcon.iconset" "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$task_build/module-cache"
export SWIFT_MODULECACHE_PATH="$task_build/module-cache"
xcrun swiftc -O -whole-module-optimization -swift-version 5 -target arm64-apple-macos13.0 \
    -module-cache-path "$task_build/module-cache" \
    "$task_root"/src/*.swift \
    -framework AppKit -framework ApplicationServices -framework ServiceManagement -framework ScreenCaptureKit \
    -o "$task_app/Contents/MacOS/CtrlSwitch"
cp "$task_root/Resources/Info.plist" "$task_app/Contents/Info.plist"
xcrun swift -module-cache-path "$task_build/module-cache" "$task_root/scripts/make-icon.swift" \
    "$task_build/AppIcon.iconset" "$task_app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$task_app"
task_package="$task_root/release/$task_id-$task_version-macos-arm64.zip"
ditto -c -k --keepParent "$task_app" "$task_package"
cp "$task_root/README.md" "$task_root/release/使用说明.md"
python3 - "$task_root" "$task_id" "$task_version" "$task_package" <<'PY'
from pathlib import Path
import hashlib, json, sys
root, tool_id, version, package = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4])
metadata=json.loads((root/'tool.json').read_text())
digest=hashlib.sha256(package.read_bytes()).hexdigest()
tag=f'{tool_id}/v{version}'
release={
    'schemaVersion':1, 'id':tool_id, 'name':metadata['name'], 'version':version,
    'platform':'macos-arm64', 'selfContained':False, 'tag':tag, 'asset':package.name,
    'downloadUrl':f'https://github.com/luck-caicai/TianCaiTools/releases/download/{tool_id}%2Fv{version}/{package.name}',
    'size':package.stat().st_size, 'sha256':digest,
}
(root/'release'/f'{tool_id}-update.json').write_text(json.dumps(release,ensure_ascii=False,indent=2)+'\n')
Path(str(package)+'.sha256').write_text(f'{digest}  {package.name}\n')
PY
printf '已生成：%s\n' "$task_app"
