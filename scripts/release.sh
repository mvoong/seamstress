#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Seamstress"
BUILD_ROOT="$ROOT/build/release"
APP_BUNDLE="$BUILD_ROOT/$APP_NAME.app"
DMG_STAGE="$BUILD_ROOT/dmg-stage"

NO_UPLOAD=false
DRAFT=false
REMOTE=""
GH_REPO=""
VERSION_ARG=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [version]

Builds a universal (arm64 + x86_64) Release bundle, signs with Hardened Runtime,
packages a signed .dmg (with an Applications symlink), notarizes via App Store
Connect API (1Password or keychain profile), staples, verifies with Gatekeeper,
and uploads to GitHub Releases.

Options:
  --no-upload         Build, sign, notarize, and staple the .dmg without tagging or uploading
  --draft             Create the GitHub release as a draft
  --remote <name>     Git remote to push the tag to (default: github if present, else origin)
  --repo <owner/repo> GitHub repository for gh release create (default: inferred from remote)
  -h, --help          Show this help

Environment overrides:
  SEAMSTRESS_BUNDLE_ID        Override PRODUCT_BUNDLE_IDENTIFIER
  SEAMSTRESS_SIGN_ID          Override CODE_SIGN_IDENTITY
  SEAMSTRESS_NOTARY_OP_ITEM   1Password item reference (default: op://Development/App Store Connect Notary)
  SEAMSTRESS_NOTARY_PROFILE   Use a notarytool keychain profile instead of 1Password
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-upload) NO_UPLOAD=true; shift ;;
        --draft) DRAFT=true; shift ;;
        --remote) REMOTE="$2"; shift 2 ;;
        --repo) GH_REPO="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            if [ -n "$VERSION_ARG" ]; then
                echo "Unexpected argument: $1" >&2
                exit 1
            fi
            VERSION_ARG="$1"
            shift
            ;;
    esac
done

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
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
        | head -n 1 || true)"
fi

if [ -z "$SIGN_ID" ] || [ "$SIGN_ID" = "-" ]; then
    echo "Error: A Developer ID Application signing identity is required for notarization." >&2
    exit 1
fi

VERSION="${VERSION_ARG:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")}"
VERSION="${VERSION#v}"
TAG="v$VERSION"
RELEASE_DMG="$BUILD_ROOT/$APP_NAME-$VERSION.dmg"

if [ "$NO_UPLOAD" = false ]; then
    if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
        echo "Error: Working tree has uncommitted changes. Commit or pass --no-upload." >&2
        exit 1
    fi
    if [ -z "$REMOTE" ]; then
        if git -C "$ROOT" remote get-url github >/dev/null 2>&1; then
            REMOTE="github"
        else
            REMOTE="origin"
        fi
    fi
    if [ -z "$GH_REPO" ]; then
        REMOTE_URL="$(git -C "$ROOT" remote get-url "$REMOTE")"
        GH_REPO="$(printf '%s' "$REMOTE_URL" | sed -E 's#^(https?://[^/]+/|ssh://[^/]+/|git@[^:]+:)##; s#\.git$##')"
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "Error: GitHub CLI (gh) is required to upload releases." >&2
        exit 1
    fi
fi

KEY_FILE=""
cleanup() {
    if [ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ]; then
        rm -f "$KEY_FILE"
    fi
    rm -rf "$DMG_STAGE"
}
trap cleanup EXIT

echo "[1/7] Building $APP_NAME $VERSION (Release, universal arm64 + x86_64)..."
swift build \
    --package-path "$ROOT" \
    --configuration release \
    --arch arm64 \
    --arch x86_64 \
    --scratch-path "$BUILD_ROOT/spm"

BIN_DIR="$(swift build \
    --package-path "$ROOT" \
    --configuration release \
    --arch arm64 \
    --arch x86_64 \
    --scratch-path "$BUILD_ROOT/spm" \
    --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
test -x "$BIN"
echo "      Architectures: $(lipo -archs "$BIN")"

echo "[2/7] Generating AppIcon.icns..."
ICONSET="$BUILD_ROOT/AppIcon.iconset"
rm -rf "$ICONSET" "$BUILD_ROOT/AppIcon.icns"
swift "$ROOT/Resources/generate-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$BUILD_ROOT/AppIcon.icns"

echo "[3/7] Assembling $APP_NAME.app ($BUNDLE_ID, $VERSION)..."
rm -rf "$APP_BUNDLE" "$DMG_STAGE" "$RELEASE_DMG"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
cp "$BUILD_ROOT/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "[4/7] Signing $APP_NAME.app and creating signed DMG..."
codesign \
    --force \
    --sign "$SIGN_ID" \
    --options runtime \
    --timestamp \
    --entitlements "$ROOT/Resources/Seamstress.entitlements" \
    "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

mkdir -p "$DMG_STAGE"
ditto "$APP_BUNDLE" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$RELEASE_DMG"

codesign --force --sign "$SIGN_ID" --timestamp "$RELEASE_DMG"
codesign --verify --verbose=2 "$RELEASE_DMG"

echo "[5/7] Submitting $RELEASE_DMG for notarization..."
if [ -n "${SEAMSTRESS_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$RELEASE_DMG" \
        --keychain-profile "$SEAMSTRESS_NOTARY_PROFILE" \
        --wait
else
    OP_ITEM="${SEAMSTRESS_NOTARY_OP_ITEM:-op://Development/App Store Connect Notary}"
    KEY_ID="$(op read -n "$OP_ITEM/key-id")"
    ISSUER_ID="$(op read -n "$OP_ITEM/issuer-id")"
    KEY_FILE="$(mktemp)"
    chmod 600 "$KEY_FILE"
    op read -n "$OP_ITEM/AuthKey_${KEY_ID}.p8" > "$KEY_FILE"

    xcrun notarytool submit "$RELEASE_DMG" \
        --key "$KEY_FILE" \
        --key-id "$KEY_ID" \
        --issuer "$ISSUER_ID" \
        --wait
fi

echo "[6/7] Stapling and verifying $RELEASE_DMG..."
xcrun stapler staple "$RELEASE_DMG"
xcrun stapler validate "$RELEASE_DMG"
spctl --assess --type open --context context:primary-signature -vv "$RELEASE_DMG"
shasum -a 256 "$RELEASE_DMG"

if [ "$NO_UPLOAD" = true ]; then
    echo "[7/7] Skipping upload (--no-upload). DMG ready at: $RELEASE_DMG"
    exit 0
fi

echo "[7/7] Syncing site version, tagging $TAG, and uploading GitHub release to $GH_REPO..."
SITE_INDEX="$ROOT/site/index.html"
if [ -f "$SITE_INDEX" ]; then
    VERSION_TAG="$TAG" /usr/bin/perl -0777 -i -pe 's/(<span\b[^>]*\bdata-version\b[^>]*>)v?[0-9]+\.[0-9]+\.[0-9]+([^<]*<\/span>)/$1.$ENV{VERSION_TAG}.$2/ge' "$SITE_INDEX"
    if ! git -C "$ROOT" diff --quiet -- "$SITE_INDEX"; then
        git -C "$ROOT" add "$SITE_INDEX"
        git -C "$ROOT" commit -m "Update site version to $TAG"
    fi
fi

if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    TAG_COMMIT="$(git -C "$ROOT" rev-list -n 1 "$TAG")"
    HEAD_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
    if [ "$TAG_COMMIT" != "$HEAD_COMMIT" ]; then
        echo "Error: Tag $TAG already exists on $TAG_COMMIT (HEAD is $HEAD_COMMIT)." >&2
        exit 1
    fi
else
    git -C "$ROOT" tag "$TAG"
fi

git -C "$ROOT" push "$REMOTE" HEAD "$TAG"

GH_ARGS=(release create "$TAG" "$RELEASE_DMG" --repo "$GH_REPO" --title "$APP_NAME $VERSION" --generate-notes)
if [ "$DRAFT" = true ]; then
    GH_ARGS+=(--draft)
fi
gh "${GH_ARGS[@]}"
