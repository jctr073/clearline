#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift build --disable-sandbox -c "$configuration" --scratch-path .build
bin_path="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"
app="$PWD/dist/Clearline.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/agent-service"
cp "$bin_path/Clearline" "$app/Contents/MacOS/Clearline.next"
mv "$app/Contents/MacOS/Clearline.next" "$app/Contents/MacOS/Clearline"
cp agent-service/agent.py "$app/Contents/Resources/agent-service/agent.py"
python3 scripts/package-info.py "$app/Contents/Info.plist"
swift scripts/make-icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
printf 'Built %s\n' "$app"
