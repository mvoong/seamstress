#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Seamstress"
ARCH="$(uname -m)"
BUILD_ROOT="$ROOT/build/local-install"
APP_BUNDLE="$BUILD_ROOT/$APP_NAME.app"
INSTALL_DEST="/Applications/$APP_NAME.app"

read_xcconfig() {
    local file="$1"
    local key="$2"
    [ -f "$file" ] || return 0
    awk -v k="$key" '
        /^[[:space:]]*\/\// { next }
        {
            sub(/\/\/.*$/, "")
            if (match($0, "^[[:space:]]*" k "[[:space:]]*=")) {
                val = substr($0, RSTART + RLENGTH)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                print val
            }
        }
    ' "$file" | tail -n 1
}

CONFIG_FILE="$ROOT/Local.xcconfig"
if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="$ROOT/Config.example.xcconfig"
fi

BUNDLE_ID="${SEAMSTRESS_BUNDLE_ID:-$(read_xcconfig "$CONFIG_FILE" PRODUCT_BUNDLE_IDENTIFIER)}"
BUNDLE_ID="${BUNDLE_ID:-com.example.seamstress}"

SIGN_ID="${SEAMSTRESS_SIGN_ID:-$(read_xcconfig "$CONFIG_FILE" CODE_SIGN_IDENTITY)}"
if [ -z "$SIGN_ID" ] || [[ "$SIGN_ID" == *"Your Name"* ]] || [[ "$SIGN_ID" == *"TEAMID"* ]]; then
    DETECTED_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
        | head -n 1 || true)"
    if [ -n "$DETECTED_ID" ]; then
        SIGN_ID="$DETECTED_ID"
    else
        SIGN_ID="-"
    fi
fi

echo "[1/5] Building $APP_NAME (Release, $ARCH)..."
swift build \
    --package-path "$ROOT" \
    --configuration release \
    --arch "$ARCH" \
    --scratch-path "$BUILD_ROOT/spm"

BIN_DIR="$(swift build \
    --package-path "$ROOT" \
    --configuration release \
    --arch "$ARCH" \
    --scratch-path "$BUILD_ROOT/spm" \
    --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
test -x "$BIN"

echo "[2/5] Generating AppIcon.icns..."
ICONSET="$BUILD_ROOT/AppIcon.iconset"
rm -rf "$ICONSET" "$BUILD_ROOT/AppIcon.icns"
swift "$ROOT/Resources/generate-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$BUILD_ROOT/AppIcon.icns"

echo "[3/5] Assembling $APP_NAME.app bundle ($BUNDLE_ID)..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
cp "$BUILD_ROOT/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

if [ "$SIGN_ID" = "-" ]; then
    echo "[4/5] Ad-hoc signing (no Developer ID Application identity configured)..."
    echo "      Note: Accessibility permission may need to be re-granted after rebuilds."
    codesign \
        --force \
        --sign - \
        --entitlements "$ROOT/Resources/Seamstress.entitlements" \
        "$APP_BUNDLE"
else
    echo "[4/5] Signing with $SIGN_ID..."
    codesign \
        --force \
        --sign "$SIGN_ID" \
        --options runtime \
        --entitlements "$ROOT/Resources/Seamstress.entitlements" \
        "$APP_BUNDLE"
fi
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
