#!/bin/bash
# Removes Pitwall's hooks from ~/.claude/settings.json; every other hook stays. Backs the file up first.
# Quits and deletes ~/Applications/Pitwall.app (where the one-line installer puts it).
# --purge also deletes ~/.claude-monitor (event log, configs, hook scripts) and the Analytics store.
# Also published with each release: curl -fsSL <release>/uninstall.sh | bash -s -- --purge
# Everything is in main(), so a download cut off halfway runs nothing.

main() {
  set -euo pipefail
  command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }
  dest="$HOME/.claude-monitor"
  settings="$HOME/.claude/settings.json"
  app="$HOME/Applications/Pitwall.app"

  if [ -f "$settings" ]; then
    jq empty "$settings" 2>/dev/null || { echo "$settings is not valid JSON; not touching it." >&2; exit 1; }
    cp "$settings" "$settings.bak.$(date +%Y%m%d%H%M%S)"
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    jq --arg cmd "$dest/monitor-hook.sh" --arg perm "$dest/permission-hook.sh" '
      if (.hooks | type) != "object" then . else
        .hooks |= (map_values(
                     map(if (.hooks | type) == "array" then .hooks |= map(select(.command != $cmd and .command != $perm)) else . end)
                     | map(select((.hooks | type) != "array" or (.hooks | length) > 0)))
                   | with_entries(select(.value | length > 0)))
        | if .hooks == {} then del(.hooks) else . end
      end' "$settings" > "$tmp"
    cat "$tmp" > "$settings" # through the path: a symlinked settings.json stays a link
    echo "Removed Pitwall's hooks from $settings"
  fi

  if [ -d "$app" ]; then
    pkill -f "$app/Contents/MacOS/Pitwall" 2>/dev/null || true
    rm -rf "$app"
    echo "Deleted $app"
  fi
  [ -d /Applications/Pitwall.app ] && echo "Quit Pitwall and delete /Applications/Pitwall.app yourself."

  if [ "${1:-}" = --purge ]; then
    rm -rf "$dest" "$HOME/Library/Application Support/ClaudeMonitor"
    echo "Deleted $dest and the Analytics store"
  fi
  return 0
}

main "$@"
