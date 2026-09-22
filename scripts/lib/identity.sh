# Shared code-signing identity resolution for the packaging scripts.
#
# Order: an explicit --identity, then the TopicTidy certificate (validated or
# merely present in the keychain — it is self-signed, so macOS reports it as
# untrusted yet codesign still uses it), then ad-hoc, which is all a CI runner
# without the certificate can do.
resolve_signing_identity() {
  local requested="${1:-}"
  if [ -n "$requested" ]; then
    printf '%s' "$requested"
    return
  fi
  if security find-identity -v -p codesigning 2> /dev/null | grep -q '"TopicTidy"'; then
    printf 'TopicTidy'
    return
  fi
  if security find-certificate -c "TopicTidy" > /dev/null 2>&1; then
    printf 'TopicTidy'
    return
  fi
  printf '%s' '-'
}
