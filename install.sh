#!/bin/sh
# TopicTidy CLI installer for macOS on Apple Silicon.
#
#   curl -fsSL https://raw.githubusercontent.com/YangChen-cn/TopicTidy/main/install.sh | sh
#
# Downloads the native `tt` from the latest GitHub Release, verifies its
# SHA-256 against the release's SHA256SUMS.txt, and installs it to
# ~/.local/bin/tt. Re-running upgrades in place.
#
# Environment overrides:
#   TOPICTIDY_VERSION     install a specific version, e.g. 0.10.0 (default: latest)
#   TOPICTIDY_INSTALL_DIR install somewhere else (default: ~/.local/bin)
#   TOPICTIDY_API_BASE    GitHub API base, for testing
#   TOPICTIDY_DOWNLOAD_BASE  release asset base, for testing
set -eu

REPOSITORY="YangChen-cn/TopicTidy"
API_BASE="${TOPICTIDY_API_BASE:-https://api.github.com/repos/$REPOSITORY}"
DOWNLOAD_BASE="${TOPICTIDY_DOWNLOAD_BASE:-https://github.com/$REPOSITORY/releases/download}"
VERSION="${TOPICTIDY_VERSION:-latest}"
INSTALL_DIR="${TOPICTIDY_INSTALL_DIR:-$HOME/.local/bin}"
TARGET="$INSTALL_DIR/tt"

say() { printf '%s\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m错误：%s\033[0m\n' "$*" >&2; exit 1; }

# --- platform ---------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "TopicTidy CLI 只支持 macOS。"
[ "$(uname -m)" = "arm64" ] || die "TopicTidy CLI 目前只提供 Apple Silicon（arm64）版本，检测到 $(uname -m)。"
command -v curl > /dev/null 2>&1 || die "需要 curl。"
command -v shasum > /dev/null 2>&1 || die "需要 shasum（macOS 自带，位于 /usr/bin/shasum）。"
command -v tar > /dev/null 2>&1 || die "需要 tar。"

# --- resolve release --------------------------------------------------------
if [ "$VERSION" = "latest" ]; then
  release_url="$API_BASE/releases/latest"
else
  version="${VERSION#v}"
  release_url="$API_BASE/releases/tags/v$version"
fi

say "正在查询 GitHub Release…"
release="$(curl -fsSL "$release_url")" \
  || die "无法读取 Release 信息：${release_url}"

tag="$(printf '%s\n' "$release" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
archive_url="$(printf '%s\n' "$release" | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*topictidy-cli-[^"]*\.tar\.gz\)".*/\1/p' | head -1)"
sums_url="$(printf '%s\n' "$release" | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*SHA256SUMS\.txt\)".*/\1/p' | head -1)"

[ -n "$tag" ] || die "Release 中没有找到版本号。"
[ -n "$archive_url" ] || die "Release ${tag} 中没有找到 CLI 压缩包（topictidy-cli-*.tar.gz）。"
[ -n "$sums_url" ] || die "Release ${tag} 中没有找到 SHA256SUMS.txt。"

archive_name="$(basename "$archive_url")"
say "版本：${tag}"
say "文件：${archive_name}"

temporary="$(mktemp -d "${TMPDIR:-/tmp}/topictidy-install-XXXXXX")"
cleanup() { rm -rf "$temporary"; }
trap cleanup EXIT INT TERM

say "正在下载…"
curl -fsSL -o "$temporary/$archive_name" "$archive_url" || die "下载失败：${archive_url}"
curl -fsSL -o "$temporary/SHA256SUMS.txt" "$sums_url" || die "下载校验文件失败：${sums_url}"

# --- verify -----------------------------------------------------------------
expected="$(awk -v name="$archive_name" \
  '$2 == name || $2 == "*" name { print $1; exit }' "$temporary/SHA256SUMS.txt")"
[ -n "$expected" ] || die "SHA256SUMS.txt 中没有 ${archive_name} 的校验值。"

actual="$(shasum -a 256 "$temporary/$archive_name" | awk '{print $1}')"
if [ "$expected" != "$actual" ]; then
  die "SHA256 校验失败，已中止安装。
  期望：$expected
  实际：$actual"
fi
say "SHA256 校验通过。"

# --- install ----------------------------------------------------------------
tar -xzf "$temporary/$archive_name" -C "$temporary" || die "解压失败。"

source_binary=""
for candidate in "$temporary"/*/tt "$temporary"/tt; do
  if [ -f "$candidate" ] && [ -x "$candidate" ]; then
    source_binary="$candidate"
    break
  fi
done
[ -n "$source_binary" ] || die "压缩包中没有找到可执行的 tt。"

previous=""
if [ -x "$TARGET" ]; then
  previous="$("$TARGET" --version 2>/dev/null || true)"
fi

mkdir -p "$INSTALL_DIR"
# Write beside the target and rename, so an interrupted run cannot leave a
# half-written binary behind.
install -m 755 "$source_binary" "$TARGET.new" || die "无法写入 ${INSTALL_DIR}。"
mv -f "$TARGET.new" "$TARGET" || die "无法替换 ${TARGET}。"

installed="$("$TARGET" --version 2>/dev/null || echo "$tag")"
if [ -n "$previous" ] && [ "$previous" != "$installed" ]; then
  say "已升级：${previous} → ${installed}"
else
  say "已安装：${TARGET}（${installed}）"
fi

# --- PATH hint --------------------------------------------------------------
case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    say "可以直接运行：tt --help"
    ;;
  *)
    warn "注意：${INSTALL_DIR} 不在 PATH 中。"
    say ""
    say "把它加到 shell 配置里（zsh，macOS 默认）："
    say "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
    say ""
    say "或者本次直接使用完整路径：${TARGET} --help"
    ;;
esac
