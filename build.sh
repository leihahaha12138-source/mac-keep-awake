#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/不许睡.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

/usr/bin/swiftc -O -target arm64-apple-macos13.0 \
	-o "$APP/Contents/MacOS/KeepAwake" src/main.swift -framework AppKit

cp Info.plist "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "构建完成：$PWD/$APP"
