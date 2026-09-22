#!/bin/bash
# Package the standalone `tt` CLI for release.
#
# The archive is deliberately small: the native binary plus the licence and
# readme that must travel with a distributed executable.
#
# Usage: scripts/package_cli.sh [--version X.Y.Z]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$VERSION" ]; then
  VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' \
    "$ROOT/Sources/TopicTidyCore/Config/AppInfo.swift" | head -1)"
fi

NAME="topictidy-cli-${VERSION}-arm64"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/topictidy-cli-XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

echo "==> building tt $VERSION"
MACOSX_DEPLOYMENT_TARGET=15.0 swift build -c release --package-path "$ROOT" \
  -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=."
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)"

PACKAGE="$STAGING/$NAME"
mkdir -p "$PACKAGE"
cp "$BIN/tt" "$PACKAGE/tt"
cp "$ROOT/LICENSE" "$PACKAGE/LICENSE"
cp "$ROOT/README.md" "$PACKAGE/README.md"

# Stripping invalidates the linker's ad-hoc signature, which arm64 refuses to
# run, so re-sign ad-hoc afterwards.
if strip -S "$PACKAGE/tt" 2>/dev/null; then
  codesign --force --sign - --timestamp=none "$PACKAGE/tt"
fi
codesign --verify --strict "$PACKAGE/tt"

# Reject developer paths before shipping.
if LC_ALL=C grep -qa -e "$ROOT" -e "$STAGING" -e '/Users/' "$PACKAGE/tt"; then
  echo "build path leaked into the CLI binary" >&2
  exit 1
fi
if ! "$PACKAGE/tt" --version > /dev/null; then
  echo "packaged tt does not run" >&2
  exit 1
fi

mkdir -p "$ROOT/dist"
ARCHIVE="$ROOT/dist/$NAME.tar.gz"
rm -f "$ARCHIVE"
tar -czf "$ARCHIVE" -C "$STAGING" "$NAME"

echo "CLI: $ARCHIVE"
echo "SHA256: $(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
