#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
PRODUCT_NAME="华为备忘录"
EXECUTABLE_NAME="HuaweiNotesNative"
APP_DIR="$BUILD_DIR/${PRODUCT_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$ROOT_DIR/AppBundle/Resources/ApplicationIcon-source.png"
SWIFTPM_ROOT_MARKER="$ROOT_DIR/.build/.workspace-root"

cd "$ROOT_DIR"

if [ -d "$ROOT_DIR/.build" ]; then
  PREVIOUS_ROOT=""
  if [ -f "$SWIFTPM_ROOT_MARKER" ]; then
    PREVIOUS_ROOT="$(<"$SWIFTPM_ROOT_MARKER")"
  fi

  if [ "$PREVIOUS_ROOT" != "$ROOT_DIR" ]; then
    echo "Refreshing SwiftPM cache for the current workspace..."
    swift package clean >/dev/null 2>&1 || true
  fi
fi

mkdir -p "$ROOT_DIR/.build"
printf '%s\n' "$ROOT_DIR" > "$SWIFTPM_ROOT_MARKER"

swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$ROOT_DIR/AppBundle/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/.build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"

if [ -d "$ROOT_DIR/AppBundle/Resources" ]; then
  cp -R "$ROOT_DIR/AppBundle/Resources/." "$RESOURCES_DIR/"
fi

if [ -f "$ICON_SOURCE" ] && command -v sips >/dev/null 2>&1 && command -v DeRez >/dev/null 2>&1 && command -v Rez >/dev/null 2>&1 && command -v SetFile >/dev/null 2>&1; then
  TMP_ICON="$BUILD_DIR/.app-icon.png"
  TMP_RSRC="$BUILD_DIR/.app-icon.rsrc"
  ICON_RESOURCE_FILE="$APP_DIR"/$'Icon\r'
  cp "$ICON_SOURCE" "$TMP_ICON"
  sips -i "$TMP_ICON" >/dev/null
  DeRez -only icns "$TMP_ICON" > "$TMP_RSRC"
  rm -f "$ICON_RESOURCE_FILE"
  Rez -append "$TMP_RSRC" -o "$ICON_RESOURCE_FILE"
  SetFile -a C "$APP_DIR"
  SetFile -a V "$ICON_RESOURCE_FILE"
  rm -f "$TMP_ICON" "$TMP_RSRC"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Built app bundle at:"
echo "$APP_DIR"
