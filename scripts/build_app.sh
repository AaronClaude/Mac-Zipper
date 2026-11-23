#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacZipper"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME (release)..."
cd "$ROOT_DIR"
swift build -c release

BIN_PATH="$ROOT_DIR/.build/release/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "Error: Binary not found at $BIN_PATH" >&2
    exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Bundle unar/lsar if available so RAR5 & encrypted RAR work out of the box
for tool in unar lsar; do
    if TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)" && [[ -n "$TOOL_PATH" && -f "$TOOL_PATH" ]]; then
        cp "$TOOL_PATH" "$APP_BUNDLE/Contents/MacOS/$tool"
        chmod +x "$APP_BUNDLE/Contents/MacOS/$tool"
    fi
done

codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
