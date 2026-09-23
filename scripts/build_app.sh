#!/bin/bash
# Build a relocatable TopicTidy.app (Apple Silicon), sign it, and produce a DMG.
#
# The bundle is pure native code: no Python runtime, no helper subprocesses.
# `tt` ships inside the bundle because the daily LaunchAgent invokes it.
#
# Usage: scripts/build_app.sh [--identity NAME] [--version X.Y.Z]
#                            [--skip-build] [--bin-dir DIR] [--app-only]
#
# --skip-build reuses binaries that are already compiled (CI builds them once);
# --bin-dir points at them explicitly. Without either flag the script builds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Version comes from the Swift source so the app, CLI and tap cannot drift.
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' \
  "$ROOT/Sources/TopicTidyCore/Config/AppInfo.swift" | head -1)"
IDENTITY=""
BIN_DIR=""
SKIP_BUILD=0
APP_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --app-only) APP_ONLY=1; shift ;;
    --bin-dir) BIN_DIR="$2"; SKIP_BUILD=1; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
# shellcheck source=scripts/lib/identity.sh
. "$ROOT/scripts/lib/identity.sh"
REQUESTED_IDENTITY="$IDENTITY"
IDENTITY="$(resolve_signing_identity "$REQUESTED_IDENTITY")"
if [ "$IDENTITY" = "-" ]; then
  echo "note: no TopicTidy certificate in this keychain, signing ad-hoc"
fi
echo "==> version $VERSION, identity $IDENTITY"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/topictidy-bundle-XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

if [ "$SKIP_BUILD" = 1 ]; then
  echo "==> reusing release binaries"
  BIN="${BIN_DIR:-$(swift build -c release --package-path "$ROOT" --show-bin-path)}"
else
  echo "==> building release binaries"
  MACOSX_DEPLOYMENT_TARGET=15.0 swift build -c release --package-path "$ROOT" \
    -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=."
  BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)"
fi
for binary in TopicTidy tt; do
  [ -x "$BIN/$binary" ] || { echo "missing $BIN/$binary; build first or drop --skip-build" >&2; exit 1; }
done

APP="$STAGING/TopicTidy.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
mkdir -p "$CONTENTS/MacOS" "$RESOURCES"

cp "$BIN/TopicTidy" "$CONTENTS/MacOS/TopicTidy"
strip -S "$CONTENTS/MacOS/TopicTidy"
# The daily task and the CLI share this binary.
cp "$BIN/tt" "$RESOURCES/tt"
strip -S "$RESOURCES/tt"

echo "==> generating icon"
ICONSET="$STAGING/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=""
    [ "$scale" = 2 ] && suffix="@2x"
    sips -z $((size * scale)) $((size * scale)) "$ROOT/Resources/AppIcon.png" \
      --out "$ICONSET/icon_${size}x${size}${suffix}.png" > /dev/null
  done
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.topictidy.app</string>
  <key>CFBundleName</key><string>TopicTidy</string>
  <key>CFBundleExecutable</key><string>TopicTidy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDownloadsFolderUsageDescription</key><string>读取下载文件并按您确认的方案整理。</string>
</dict>
</plist>
PLIST

echo "==> checking bundle hygiene"
if [ -e "$RESOURCES/python" ]; then
  echo "bundle must not contain a Python runtime" >&2
  exit 1
fi
if find "$APP" -name '*.py' -o -name '*.pyc' | grep -q .; then
  echo "bundle must not contain Python sources" >&2
  exit 1
fi
# Reject any developer/source path in distributable bytes before signing.
while IFS= read -r -d '' file; do
  if [ -L "$file" ]; then continue; fi
  if LC_ALL=C grep -qa -e "$ROOT" -e "$STAGING" -e '/Users/' "$file" 2>/dev/null; then
    echo "build path leaked into ${file#"$APP"/}" >&2
    exit 1
  fi
done < <(find "$APP" -type f -print0)

echo "==> signing"
MACH_MAGICS=(cffaedfe feedfacf cafebabe bebaFeca)
while IFS= read -r -d '' file; do
  if [ -L "$file" ]; then continue; fi
  magic="$(xxd -p -l 4 "$file" 2>/dev/null || true)"
  case "$magic" in
    cffaedfe|feedfacf|cafebabe|bebafeca)
      codesign --force --sign "$IDENTITY" --timestamp=none "$file" ;;
  esac
done < <(find "$APP" -type f -print0)
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "==> writing dist"
DIST="$ROOT/dist"
mkdir -p "$DIST"
rm -rf "$DIST/TopicTidy.app"
cp -R "$APP" "$DIST/TopicTidy.app"

if [ "$APP_ONLY" = 1 ]; then
  echo "APP: $DIST/TopicTidy.app"
  exit 0
fi

DMG_ROOT="$STAGING/dmg-root"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/TopicTidy.app"
ln -s /Applications "$DMG_ROOT/Applications"
DMG="$DIST/TopicTidy-${VERSION}-arm64.dmg"
rm -f "$DMG"
hdiutil create -volname TopicTidy -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG" > /dev/null
codesign --force --sign "$IDENTITY" --timestamp=none "$DMG"
codesign --verify --strict "$DMG"
hdiutil verify "$DMG" > /dev/null

APP_KIB="$(du -sk "$DIST/TopicTidy.app" | cut -f1)"
cat > "$DIST/TopicTidy-${VERSION}-size-report.json" <<REPORT
{
  "version": "${VERSION}",
  "app_bytes": $((APP_KIB * 1024)),
  "dmg_bytes": $(stat -f%z "$DMG"),
  "contains_python": false,
  "architecture": "arm64"
}
REPORT

echo "APP: $DIST/TopicTidy.app"
echo "DMG: $DMG"
echo "SIZE REPORT: $DIST/TopicTidy-${VERSION}-size-report.json"
echo "SHA256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
