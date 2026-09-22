#!/bin/bash
# Render the Homebrew tap from a published release and (optionally) push it.
#
# The cask and formula must pin the SHA-256 of the artefacts GitHub actually
# published, so they are downloaded from the release by default: a local build
# has different bytes (tar and DMG embed timestamps) and would pin hashes that
# no user can ever match.
#
# Usage: scripts/publish_tap.sh [--version X.Y.Z] [--local] [--dry-run] [--no-push]
#
# Set TAP_GITHUB_TOKEN (or GH_TOKEN) to push to the tap from CI; without it the
# developer's own git credentials are used.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAP_REPOSITORY="YangChen-cn/homebrew-tap"
VERSION=""
DRY_RUN=0
PUSH=1
USE_LOCAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --local) USE_LOCAL=1; shift ;;
    --dry-run) DRY_RUN=1; PUSH=0; shift ;;
    --no-push) PUSH=0; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$VERSION" ]; then
  VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' \
    "$ROOT/Sources/TopicTidyCore/Config/AppInfo.swift" | head -1)"
fi

DMG="TopicTidy-${VERSION}-arm64.dmg"
CLI="topictidy-cli-${VERSION}-arm64.tar.gz"
BASE_URL="https://github.com/YangChen-cn/TopicTidy/releases/download/v${VERSION}"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/topictidy-tap-XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

fetch() {
  local name="$1"
  if [ "$USE_LOCAL" = 1 ]; then
    [ -f "$ROOT/dist/$name" ] || { echo "missing local artifact: dist/$name" >&2; exit 1; }
    cp "$ROOT/dist/$name" "$STAGING/$name"
    return
  fi
  echo "==> downloading $name from the release"
  curl -fsSL -o "$STAGING/$name" "$BASE_URL/$name" \
    || { echo "release asset missing: $BASE_URL/$name" >&2; exit 1; }
  if [ -f "$ROOT/dist/SHA256SUMS.txt" ] && grep -q "$name" "$ROOT/dist/SHA256SUMS.txt"; then
    expected="$(awk -v n="$name" '$2 == n { print $1; exit }' "$ROOT/dist/SHA256SUMS.txt")"
    actual="$(shasum -a 256 "$STAGING/$name" | awk '{print $1}')"
    if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
      echo "note: released $name differs from the local copy (expected for a CI build)"
    fi
  fi
}
fetch "$DMG"
fetch "$CLI"

DMG_SHA="$(shasum -a 256 "$STAGING/$DMG" | awk '{print $1}')"
CLI_SHA="$(shasum -a 256 "$STAGING/$CLI" | awk '{print $1}')"
echo "==> version $VERSION"
echo "    dmg sha256 $DMG_SHA"
echo "    cli sha256 $CLI_SHA"

mkdir -p "$STAGING/tap/Casks"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256_DMG__/$DMG_SHA/g" \
  "$ROOT/packaging/homebrew/Casks/topictidy.rb" > "$STAGING/tap/Casks/topictidy.rb"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256_CLI__/$CLI_SHA/g" \
  "$ROOT/packaging/homebrew/Casks/topictidy-cli.rb" > "$STAGING/tap/Casks/topictidy-cli.rb"

if command -v ruby > /dev/null 2>&1; then
  ruby -c "$STAGING/tap/Casks/topictidy.rb" > /dev/null
  ruby -c "$STAGING/tap/Casks/topictidy-cli.rb" > /dev/null
  echo "==> ruby syntax ok"
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "==> rendered tap (dry run)"
  for file in "$STAGING/tap/Casks/topictidy.rb" "$STAGING/tap/Casks/topictidy-cli.rb"; do
    echo "----- ${file#"$STAGING/tap"/} -----"
    grep -vE '^\s*#' "$file" | grep -vE '^\s*$' | head -12
  done
  exit 0
fi

if [ "$PUSH" = 0 ]; then
  echo "==> tap rendered in $STAGING/tap (not pushed)"
  exit 0
fi

echo "==> preparing $TAP_REPOSITORY"
WORK="$STAGING/checkout"
# In CI the release workflow supplies a token that can write to the tap; the
# token is never echoed and the URL is only used for this one push.
TOKEN="${TAP_GITHUB_TOKEN:-${GH_TOKEN:-}}"
CLONE_URL="https://github.com/$TAP_REPOSITORY.git"
PUSH_URL="$CLONE_URL"
if [ -n "$TOKEN" ]; then
  PUSH_URL="https://x-access-token:$TOKEN@github.com/$TAP_REPOSITORY.git"
fi
if ! git clone --quiet "$CLONE_URL" "$WORK" 2>/dev/null; then
  echo "==> tap repository not found, creating it"
  gh repo create "$TAP_REPOSITORY" --public \
    --description "Homebrew tap for TopicTidy" > /dev/null
  git clone --quiet "$CLONE_URL" "$WORK"
fi

mkdir -p "$WORK/Casks"
cp "$STAGING/tap/Casks/topictidy.rb" "$WORK/Casks/topictidy.rb"
cp "$STAGING/tap/Casks/topictidy-cli.rb" "$WORK/Casks/topictidy-cli.rb"

# The CLI used to be a formula; a formula would make Homebrew demand a working
# Xcode/CLT toolchain for a prebuilt binary, so it moved to a cask.
if [ -f "$WORK/Formula/topictidy-cli.rb" ]; then
  git -C "$WORK" rm -q -f Formula/topictidy-cli.rb
  rmdir "$WORK/Formula" 2>/dev/null || true
fi

if [ -z "$(git -C "$WORK" status --porcelain)" ]; then
  echo "==> tap already up to date"
  exit 0
fi

git -C "$WORK" add -A
git -C "$WORK" -c user.name="$(git config user.name || echo TopicTidy)" \
  -c user.email="$(git config user.email || echo noreply@github.com)" \
  commit --quiet -m "TopicTidy ${VERSION}"
git -C "$WORK" push --quiet "$PUSH_URL" HEAD:main
echo "==> pushed to https://github.com/$TAP_REPOSITORY"
