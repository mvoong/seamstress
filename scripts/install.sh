#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Seamstress"
BUILD_ROOT="$ROOT/build/local-install"
APP_BUNDLE="$BUILD_ROOT/$APP_NAME.app"
INSTALL_DEST="/Applications/$APP_NAME.app"
SIGN_ID="${SEAMSTRESS_SIGN_ID:-Developer ID Application: Your Name (TEAMID)}"

echo "[1/5] Building $APP_NAME (Release, arm64)..."
swift build \
    --package-path "$ROOT" \
    --configuration release \
    --arch arm64 \
    --scratch-path "$BUILD_ROOT/spm"

BIN_DIR="$(swift build \
    --package-path "$ROOT" \
    --configuration release \
    --arch arm64 \
    --scratch-path "$BUILD_ROOT/spm" \
    --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
test -x "$BIN"

echo "[2/5] Generating AppIcon.icns..."
ICONSET="$BUILD_ROOT/AppIcon.iconset"
rm -rf "$ICONSET" "$BUILD_ROOT/AppIcon.icns"
swift "$ROOT/Resources/generate-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$BUILD_ROOT/AppIcon.icns"

echo "[3/5] Assembling $APP_NAME.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$BUILD_ROOT/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "[4/5] Signing with Developer ID Application..."
codesign \
    --force \
    --sign "$SIGN_ID" \
    --options runtime \
    --entitlements "$ROOT/Resources/Seamstress.entitlements" \
    "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "[5/5] Installing to $INSTALL_DEST..."
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    pkill -x "$APP_NAME" || true
    sleep 0.5
fi
rm -rf "$INSTALL_DEST"
ditto "$APP_BUNDLE" "$INSTALL_DEST"
codesign --verify --deep --strict --verbose=2 "$INSTALL_DEST"

echo "Installed $INSTALL_DEST ($(lipo -archs "$INSTALL_DEST/Contents/MacOS/$APP_NAME"))"
