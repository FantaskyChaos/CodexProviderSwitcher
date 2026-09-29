#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_NAME="Codex 提供商切换"
APP_DIR="$PROJECT_DIR/dist/$APP_NAME.app"
ICON_WORK="$PROJECT_DIR/.build/AppIcon.iconset"
ICON_SOURCE="$PROJECT_DIR/.build/AppIcon-1024.png"

cd "$PROJECT_DIR"
swift build -c release

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/.build/release/CodexProviderSwitcher" "$APP_DIR/Contents/MacOS/"
cp "$PROJECT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/"

rm -r "$ICON_WORK" 2>/dev/null || true
mkdir -p "$ICON_WORK"
swift "$PROJECT_DIR/Packaging/make-icon.swift" "$ICON_SOURCE"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICON_WORK/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$ICON_SOURCE" --out "$ICON_WORK/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_WORK" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
