#!/bin/sh
# One-line install and update:
#   curl -fsSL https://github.com/dmytrodemchenko/pitwall/releases/latest/download/install.sh | sh
# Downloads the latest release, checks its sha256, puts Pitwall.app in ~/Applications,
# registers the hooks (hooks/install.sh) and starts the app. No sudo.
# PITWALL_VERSION=1.2 pins a version. PITWALL_BASE_URL overrides where the files come from (tests).
# POSIX sh, because it is piped to sh. Everything is in main(), so a download cut off halfway runs nothing.

main() {
  set -eu
  repo=https://github.com/dmytrodemchenko/pitwall/releases
  if [ -n "${PITWALL_VERSION:-}" ]; then base="$repo/download/v$PITWALL_VERSION"; else base="$repo/latest/download"; fi
  base="${PITWALL_BASE_URL:-$base}"
  proto='=https'
  case "$base" in file://*) proto='=file' ;; esac
  apps="$HOME/Applications"
  app="$apps/Pitwall.app"

  fail() { echo "Pitwall: $*" >&2; exit 1; }
  get() { curl -fsSL --proto "$proto" --tlsv1.2 "$@"; }

  [ "$(uname -s)" = Darwin ] || fail "Pitwall runs on macOS only."
  major=$(sw_vers -productVersion | cut -d. -f1)
  [ "$major" -ge 14 ] || fail "Pitwall needs macOS 14 or later."
  case "$(uname -m)" in arm64 | x86_64) ;; *) fail "Unsupported CPU: $(uname -m)." ;; esac
  command -v jq >/dev/null || fail "jq is required (ships with macOS 15+; on macOS 14 install it first)."

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  latest=$(get "$base/latest.txt") || fail "Can't read $base/latest.txt."
  version=$(echo "$latest" | awk '{print $1}')
  sha=$(echo "$latest" | awk '{print $2}')
  echo "$version" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || fail "Bad version in latest.txt."
  echo "$sha" | grep -Eq '^[0-9a-f]{64}$' || fail "Bad sha256 in latest.txt."

  echo "Downloading Pitwall $version"
  get -o "$tmp/pitwall.zip" "$base/Pitwall-$version.zip" || fail "Download failed."
  echo "$sha  $tmp/pitwall.zip" | shasum -a 256 -c -s || fail "Checksum mismatch; nothing installed."
  ditto -x -k "$tmp/pitwall.zip" "$tmp/x"
  src="$tmp/x/Pitwall-$version"
  codesign --verify --strict --deep "$src/Pitwall.app" 2>/dev/null || fail "The app's signature is broken; nothing installed."

  /bin/bash "$src/hooks/install.sh"

  # Only the copy we replace; the path keeps a test run from quitting the real app.
  pkill -f "$app/Contents/MacOS/Pitwall" 2>/dev/null || true
  i=0
  while pgrep -f "$app/Contents/MacOS/Pitwall" >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done

  mkdir -p "$apps"
  rm -rf "$app"
  mv "$src/Pitwall.app" "$app"
  xattr -dr com.apple.quarantine "$app" 2>/dev/null || true

  [ -d /Applications/Pitwall.app ] && echo "Note: /Applications/Pitwall.app is an older copy. Delete it, so only one Pitwall starts."
  open "$app"
  echo "Installed Pitwall $version in $app"
  echo "Uninstall: curl -fsSL $repo/latest/download/uninstall.sh | bash -s -- --purge"
}

main "$@"
