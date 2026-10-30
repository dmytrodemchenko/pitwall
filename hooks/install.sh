#!/bin/bash
# Installs monitor-hook.sh (all events) and permission-hook.sh (PermissionRequest, 60 s timeout)
# and registers them in ~/.claude/settings.json.
# Keeps existing hooks; safe to run more than once.
set -euo pipefail

command -v jq >/dev/null || { echo "jq is required (ships with macOS 15+; on macOS 14 install it first)." >&2; exit 1; }

dest="$HOME/.claude-monitor"
hook="$dest/monitor-hook.sh"
perm="$dest/permission-hook.sh"
settings="$HOME/.claude/settings.json"

mkdir -p "$dest" "$(dirname "$settings")"
cp "$(dirname "$0")/monitor-hook.sh" "$hook"
cp "$(dirname "$0")/permission-hook.sh" "$perm"
# Owner-only: the log holds commands, paths and verifier reports, and every local account is in group staff.
chmod 700 "$dest" "$hook" "$perm"
for f in events.jsonl prices.json context.json; do [ -e "$dest/$f" ] && chmod 600 "$dest/$f"; done

[ -f "$settings" ] || echo '{}' > "$settings"
jq empty "$settings" 2>/dev/null || { echo "$settings is not valid JSON; not touching it." >&2; exit 1; }
cp "$settings" "$settings.bak.$(date +%Y%m%d%H%M%S)"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
merge() {
  jq --arg cmd "$hook" --arg perm "$perm" '
    reduce ("SessionStart","PreToolUse","PostToolUse","Notification","SubagentStop","Stop","SessionEnd") as $e (.;
      if any(.hooks[$e][]?.hooks[]?; .command == $cmd) then .
      else .hooks[$e] += [{hooks: [{type: "command", command: $cmd}]}] end)
    | if any(.hooks.PermissionRequest[]?.hooks[]?; .command == $perm) then .
      else .hooks.PermissionRequest += [{hooks: [{type: "command", command: $perm, timeout: 60}]}] end
  ' "$settings" > "$tmp"
}
# Written through the path (not mv), so a symlinked settings.json (dotfiles) stays a link.
# If something else changed the file while we merged, merge again once, then give up rather than lose its change.
for _ in 1 2; do
  before=$(shasum < "$settings")
  merge
  if [ "$(shasum < "$settings")" = "$before" ]; then
    cat "$tmp" > "$settings"
    echo "Installed $hook and $perm and registered them in $settings"
    exit 0
  fi
done
echo "$settings kept changing while installing; nothing written. Close Claude Code and run this again." >&2
exit 1
