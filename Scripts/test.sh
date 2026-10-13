#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ModuleCache
swiftc -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 -swift-version 5 \
    -module-cache-path "$PWD/build/ModuleCache" \
    Sources/Clipboard/History.swift Sources/Clipboard/ClipboardMonitor.swift Sources/Clipboard/Settings.swift \
    Sources/Clipboard/GlobalHotKey.swift \
    Sources/Clipboard/ClipboardImage.swift \
    Sources/Clipboard/LoginItemController.swift \
    Sources/Clipboard/TextSnippet.swift \
    Tests/main.swift -o build/ClipboardTests
build/ClipboardTests
