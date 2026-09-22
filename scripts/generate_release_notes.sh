#!/bin/bash
# Build release notes from the commits between two tags.
#
# This project commits straight to main, so GitHub's generated notes would
# contain little more than a changelog link. Instead the notes list the commit
# subjects that landed since the previous version.
#
# Usage: scripts/generate_release_notes.sh [tag]     (default: GITHUB_REF_NAME or the latest tag)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-${GITHUB_REF_NAME:-$(git -C "$ROOT" describe --tags --abbrev=0)}}"
REPOSITORY="YangChen-cn/TopicTidy"
TAP="YangChen-cn/tap"
VERSION_PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+$'

# The previous tag has to be present to diff against; a shallow clone or a
# fresh checkout has none, so pull tags when a remote is reachable.
if git -C "$ROOT" remote get-url origin > /dev/null 2>&1; then
  git -C "$ROOT" fetch --tags --quiet 2>/dev/null || true
fi

if ! git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
  echo "unknown tag: $TAG" >&2
  exit 1
fi

# The previous release: the first version tag older than this one.
previous="$(git -C "$ROOT" tag --sort=-v:refname \
  | grep -E "$VERSION_PATTERN" \
  | awk -v tag="$TAG" '{ if (found) { print; exit } if ($0 == tag) found = 1 }')"

if [ -n "$previous" ]; then
  range="$previous..$TAG"
  compare="https://github.com/$REPOSITORY/compare/$previous...$TAG"
else
  echo "note: no earlier version tag to diff against; listing history up to $TAG" >&2
  range="$TAG"
  compare="https://github.com/$REPOSITORY/commits/$TAG"
fi

# Merge commits carry no user-visible change; the rest are listed verbatim.
subjects="$(git -C "$ROOT" log --no-merges --pretty=format:'%h %s' "$range" \
  | grep -vE '^[0-9a-f]+ (Merge |Merge pull request|Merge branch|Merge remote-tracking)' \
  | grep -vE '^[0-9a-f]+ +$' || true)"

echo "## What's Changed"
echo
if [ -n "$subjects" ]; then
  while IFS= read -r line; do
    printf -- '- %s (%s)\n' "${line#* }" "${line%% *}"
  done <<< "$subjects"
else
  echo "- Maintenance release: no user-visible changes since ${previous:-the previous release}."
fi
echo
echo "## Install"
echo
echo "GUI + CLI:"
echo
echo '```bash'
echo "brew install --cask $TAP/topictidy"
echo '```'
echo
echo "CLI only:"
echo
echo '```bash'
echo "brew install --cask $TAP/topictidy-cli"
echo '```'
echo
echo "Or, without Homebrew:"
echo
echo '```bash'
echo "curl -fsSL https://raw.githubusercontent.com/$REPOSITORY/main/install.sh | sh"
echo '```'
echo
echo "Requires macOS 15 or newer on Apple Silicon."
echo
echo "## Full Changelog"
echo
echo "$compare"
