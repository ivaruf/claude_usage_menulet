#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeUsage.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/ClaudeUsage"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so Keychain/login-item behavior is stable across rebuilds.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run it with: open $APP"
