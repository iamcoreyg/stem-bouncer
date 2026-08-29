#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/dist/StemBouncer.app"
CONTENTS_DIR="$APP_DIR/Contents"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

cd "$PROJECT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$PROJECT_DIR/.build/release/StemBouncer" "$CONTENTS_DIR/MacOS/StemBouncer"
cp "$PROJECT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Packaging/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --options runtime \
        --entitlements "$PROJECT_DIR/Packaging/StemBouncer.entitlements" \
        "$APP_DIR"
else
    codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime \
        --entitlements "$PROJECT_DIR/Packaging/StemBouncer.entitlements" \
        "$APP_DIR"
fi

echo "$APP_DIR"
