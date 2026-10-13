#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
case "$CONFIG" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
mkdir -p build/Clipboard.app/Contents/MacOS build/Clipboard.app/Contents/Resources build/ModuleCache
FLAGS=(-sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 -swift-version 5
       -module-name Clipboard -module-cache-path "$PWD/build/ModuleCache")
if [[ "$CONFIG" == release ]]; then
    FLAGS+=(-O)
    # A previous debug build may have left symbols inside the application bundle.
    rm -rf build/Clipboard.app/Contents/MacOS/Clipboard.dSYM
else
    FLAGS+=(-Onone -g)
fi
swiftc "${FLAGS[@]}" Sources/Clipboard/*.swift -o build/Clipboard.app/Contents/MacOS/Clipboard
cp Scripts/Info.plist build/Clipboard.app/Contents/Info.plist
VERSION="${CLIPBOARD_VERSION:-0.3.0}"
BUILD_NUMBER="${CLIPBOARD_BUILD_NUMBER:-3}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "CLIPBOARD_VERSION must look like 1.2.3" >&2; exit 2; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "CLIPBOARD_BUILD_NUMBER must be an integer" >&2; exit 2; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" build/Clipboard.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" build/Clipboard.app/Contents/Info.plist
if [[ "$CONFIG" == release ]]; then
    /usr/libexec/PlistBuddy -c "Set :ClipboardBuildChannel release" build/Clipboard.app/Contents/Info.plist
fi
/usr/libexec/PlistBuddy -c "Set :ClipboardBuildDate $(date -u '+%Y-%m-%d %H:%M UTC')" build/Clipboard.app/Contents/Info.plist
REVISION="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
/usr/libexec/PlistBuddy -c "Set :ClipboardSourceRevision ${REVISION:-local}" build/Clipboard.app/Contents/Info.plist
# Ad-hoc signature is sufficient for this local MVP; provide a certificate for distribution.
codesign --force --sign "${CLIPBOARD_SIGNING_IDENTITY:--}" build/Clipboard.app
codesign --verify --strict build/Clipboard.app
echo "Built: $PWD/build/Clipboard.app"
