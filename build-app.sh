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
ICONSET_SOURCE="$ROOT_DIR/AppBundle/Resources/AppIcon.iconset"
ICON_FILE="$ROOT_DIR/AppBundle/Resources/ApplicationIcon.icns"
SWIFTPM_ROOT_MARKER="$ROOT_DIR/.build/.workspace-root"
VERSION_FILE="$ROOT_DIR/VERSION"

cd "$ROOT_DIR"

if [ ! -f "$VERSION_FILE" ]; then
  echo "Missing VERSION file: $VERSION_FILE" >&2
  exit 1
fi

APP_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid version in VERSION: $APP_VERSION" >&2
  exit 1
fi

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

if [ -d "$ICONSET_SOURCE" ] && command -v iconutil >/dev/null 2>&1; then
  iconutil -c icns "$ICONSET_SOURCE" -o "$ICON_FILE"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$ROOT_DIR/AppBundle/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/.build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"

if [ -x /usr/libexec/PlistBuddy ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$CONTENTS_DIR/Info.plist"
fi

if [ -d "$ROOT_DIR/AppBundle/Resources" ]; then
  cp -R "$ROOT_DIR/AppBundle/Resources/." "$RESOURCES_DIR/"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Built app bundle for version $APP_VERSION at:"
echo "$APP_DIR"
