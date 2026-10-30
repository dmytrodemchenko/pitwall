#!/bin/bash
# Self-check for monitor-hook.sh and install.sh against a throwaway $HOME.
set -euo pipefail
cd "$(dirname "$0")"
export HOME=$(mktemp -d)
trap 'rm -rf "$HOME"' EXIT
log="$HOME/.claude-monitor/events.jsonl"

hook() { echo "$1" | ./monitor-hook.sh; }
last() { tail -1 "$log" | jq -r "$@"; }

# Basic event
hook '{"session_id":"s1","cwd":"/x/proj","hook_event_name":"SessionStart","transcript_path":"/t.jsonl"}'
[ "$(last .session_id)" = s1 ]
[ "$(last .tool_name)" = null ]
mode() { stat -f %Lp "$1"; }
[ "$(mode "$HOME/.claude-monitor")" = 700 ]
[ "$(mode "$log")" = 600 ]   # owner-only from the first event

# Subagent gate
hook '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"planner"}}'
[ "$(last .subagent_type)" = planner ]
[ "$(last .verdict)" = null ]

# Verifier verdicts
hook '{"session_id":"s1","hook_event_name":"SubagentStop","agent_type":"verifier","last_assistant_message":"2 tests broke\nVERDICT: FAIL"}'
[ "$(last .verdict)" = fail ]
[ "$(last .subagent_type)" = verifier ]
[ "$(last .last_message)" = "$(printf '2 tests broke\nVERDICT: FAIL')" ]
hook '{"session_id":"s1","hook_event_name":"SubagentStop","agent_type":"verifier","last_assistant_message":"all good. Verdict: PASS"}'
[ "$(last .verdict)" = pass ]
hook '{"session_id":"s1","hook_event_name":"SubagentStop","agent_type":"verifier","last_assistant_message":"Asked to end with VERDICT: PASS or VERDICT: FAIL.\nVERDICT: PASS\n\n"}'
[ "$(last .verdict)" = pass ] # only the last line counts
hook '{"session_id":"s1","hook_event_name":"SubagentStop","agent_type":"developer","last_assistant_message":"VERDICT: FAIL"}'
[ "$(last .verdict)" = null ]
[ "$(last .last_message)" = null ]
long=$(printf 'x%.0s' $(seq 1 2500))
hook "{\"session_id\":\"s1\",\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"verifier\",\"last_assistant_message\":\"${long}END\"}"
[ "$(last '.last_message | length')" = 2000 ]
[ "$(last '.last_message | endswith("END")')" = true ]

# The thing a tool works on, capped
hook '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/x/a.swift","old_string":"a"}}'
[ "$(last .tool_detail)" = /x/a.swift ]
hook "{\"session_id\":\"s1\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$(printf 'x%.0s' $(seq 400))\"}}"
[ "$(last '.tool_detail | length')" = 300 ]

# Task lists, from real payloads (PostToolUse only)
hook '{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"TodoWrite","tool_input":{"todos":[{"content":"Write tests","status":"in_progress","activeForm":"Writing tests"},{"content":"Ship it","status":"pending"}]}}'
[ "$(last -c .todos)" = '[{"content":"Write tests","status":"in_progress"},{"content":"Ship it","status":"pending"}]' ]
hook '{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"TaskCreate","tool_input":{"subject":"Ship it","description":"x"},"tool_response":{"task":{"id":"2","subject":"Ship it"}}}'
[ "$(last -c .task)" = '{"id":"2","subject":"Ship it","status":"pending"}' ]
hook '{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"completed"},"tool_response":{"success":true}}'
[ "$(last -c .task)" = '{"id":"1","subject":null,"status":"completed"}' ]
hook '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"completed"}}'
[ "$(last .task)" = null ]

# Non-object tool_input must not drop the event
hook '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":"weird"}'
[ "$(last .tool_name)" = Bash ]

# Garbage input: no line, no output, exit 0
before=$(wc -l < "$log")
out=$(echo 'not json' | ./monitor-hook.sh)
[ -z "$out" ]
[ "$(wc -l < "$log")" = "$before" ]

# Process info: the nearest "claude" ancestor is recorded on Stop (no tty in a test run)
ln -s /bin/bash "$HOME/claude"
"$HOME/claude" -c 'echo "{\"session_id\":\"s1\",\"hook_event_name\":\"Stop\"}" | ./monitor-hook.sh; echo $$ > "$HOME/claude.pid"'
[ "$(last .pid)" = "$(cat "$HOME/claude.pid")" ]
[ "$(last .tty)" = null ]
__CFBundleIdentifier=com.googlecode.iterm2 hook '{"session_id":"s1","hook_event_name":"Stop"}'
[ "$(last .terminal_app)" = com.googlecode.iterm2 ]
hook '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash"}'   # not looked up on busy events
[ "$(last .pid)" = null ]
# The event is read as JSON, not matched as text: spaced JSON still gets the process info
"$HOME/claude" -c 'echo "{ \"session_id\": \"s2\", \"hook_event_name\" : \"Stop\" }" | ./monitor-hook.sh; echo $$ > "$HOME/claude.pid"'
[ "$(last .session_id)" = s2 ]
[ "$(last .pid)" = "$(cat "$HOME/claude.pid")" ]
# ps finds nothing: the event is still logged, with no pid
mkdir -p "$HOME/fakebin" && printf '#!/bin/sh\nexit 1\n' > "$HOME/fakebin/ps" && chmod +x "$HOME/fakebin/ps"
echo '{"session_id":"s3","hook_event_name":"Stop"}' | PATH="$HOME/fakebin:$PATH" ./monitor-hook.sh
[ "$(last .session_id)" = s3 ]
[ "$(last .pid)" = null ]

# Install: keeps existing hooks, idempotent
mkdir -p "$HOME/.claude"
echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}' > "$HOME/.claude/settings.json"
./install.sh >/dev/null && ./install.sh >/dev/null
s="$HOME/.claude/settings.json"
[ "$(jq -r .model "$s")" = opus ]
[ "$(jq '.hooks.Stop | length' "$s")" = 2 ]
[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" = "say done" ]
[ "$(jq '[.hooks[][]] | length' "$s")" = 9 ]   # 7 events + PermissionRequest + 1 existing
[ -x "$HOME/.claude-monitor/monitor-hook.sh" ]
[ -x "$HOME/.claude-monitor/permission-hook.sh" ]
[ "$(jq '.hooks.PermissionRequest[0].hooks[0].timeout' "$s")" = 60 ]

# Install makes an existing, too-open data folder owner-only
chmod 755 "$HOME/.claude-monitor" && chmod 644 "$log" && echo '{}' > "$HOME/.claude-monitor/prices.json" && chmod 644 "$HOME/.claude-monitor/prices.json"
./install.sh >/dev/null
[ "$(mode "$HOME/.claude-monitor")" = 700 ]
[ "$(mode "$log")" = 600 ]
[ "$(mode "$HOME/.claude-monitor/prices.json")" = 600 ]
[ "$(mode "$HOME/.claude-monitor/monitor-hook.sh")" = 700 ]
[ "$(mode "$HOME/.claude-monitor/permission-hook.sh")" = 700 ]

# Install through a symlinked settings.json (dotfiles): the link stays, its target gets the hooks
mkdir -p "$HOME/dotfiles" && mv "$s" "$HOME/dotfiles/settings.json" && ln -s "$HOME/dotfiles/settings.json" "$s"
./install.sh >/dev/null
[ -L "$s" ]
[ "$(jq '[.hooks[][]] | length' "$HOME/dotfiles/settings.json")" = 9 ]
[ "$(jq -r .model "$s")" = opus ]
rm "$s" && echo '{}' > "$s"
./install.sh >/dev/null
[ ! -L "$s" ]
[ "$(jq '[.hooks[][]] | length' "$s")" = 8 ]

# Permission hook: a fake app (nc -lU) answers on a throwaway socket.
export CLAUDE_MONITOR_SOCKET="$HOME/.claude-monitor/monitor.sock"
req='{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf x"}}'
perm() { echo "$req" | ./permission-hook.sh; }
app() { # app <reply or empty> <seconds to stay silent>: serve one connection, record the request
  rm -f "$CLAUDE_MONITOR_SOCKET"
  { [ -n "$1" ] && echo "$1"; sleep "$2"; } | nc -lU "$CLAUDE_MONITOR_SOCKET" > "$HOME/request" &
  for _ in $(seq 50); do [ -S "$CLAUDE_MONITOR_SOCKET" ] && break; sleep 0.05; done
}

# No app: no output, at once
rm -f "$CLAUDE_MONITOR_SOCKET"
[ -z "$(perm)" ]

# Allow: decision JSON, and the app got the request as one JSON line
app allow 1
[ "$(perm | jq -r .hookSpecificOutput.decision.behavior)" = allow ]
wait
[ "$(jq -r .tool_input.command "$HOME/request")" = "rm -rf x" ]

# Deny
app deny 1
out=$(perm)
[ "$(echo "$out" | jq -r .hookSpecificOutput.decision.behavior)" = deny ]
[ "$(echo "$out" | jq -r .hookSpecificOutput.hookEventName)" = PermissionRequest ]
wait

# Anything else is no decision (never an allow)
app maybe 1
[ -z "$(perm)" ]
wait

# Timeout: a silent app -> no output after CLAUDE_MONITOR_WAIT seconds, not before, not much after
app "" 6
start=$(date +%s)
out=$(CLAUDE_MONITOR_WAIT=2 perm)
took=$(( $(date +%s) - start ))
[ -z "$out" ] && [ "$took" -ge 2 ] && [ "$took" -le 4 ] || { echo "timeout test: out='$out' took=${took}s" >&2; exit 1; }
wait

# Uninstall: only our entries go, others stay; safe to repeat; --purge deletes the data
s="$HOME/.claude/settings.json"
echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}' > "$s"
./install.sh >/dev/null
jq '.hooks.Stop[0].hooks += [{"type":"command","command":"'"$HOME"'/.claude-monitor/monitor-hook.sh"}]' "$s" > "$HOME/s" && cat "$HOME/s" > "$s" # ours mixed into a user entry
./uninstall.sh >/dev/null
[ "$(jq -c .hooks "$s")" = '{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}' ]
[ "$(jq -r .model "$s")" = opus ]
ls "$HOME/.claude/settings.json.bak."* >/dev/null
./uninstall.sh >/dev/null
[ "$(jq -c .hooks "$s")" = '{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}' ]
./install.sh >/dev/null && ./uninstall.sh --purge >/dev/null
[ ! -e "$HOME/.claude-monitor" ]
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'"$HOME"'/.claude-monitor/monitor-hook.sh"}]}]}}' > "$s"
./uninstall.sh >/dev/null
[ "$(jq -c . "$s")" = '{}' ]

# Remote installer (scripts/install-remote.sh): a fake release served from file://
rel="$HOME/release" pkg="$HOME/pkg/Pitwall-9.9" app="$HOME/Applications/Pitwall.app"
mkdir -p "$pkg/Pitwall.app/Contents/MacOS" "$pkg/hooks" "$rel" "$HOME/openbin"
cp /usr/bin/true "$pkg/Pitwall.app/Contents/MacOS/Pitwall"
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Pitwall</string><key>CFBundleIdentifier</key><string>test.Pitwall</string></dict></plist>' > "$pkg/Pitwall.app/Contents/Info.plist"
codesign -f -s - "$pkg/Pitwall.app" 2>/dev/null
cp monitor-hook.sh permission-hook.sh install.sh uninstall.sh "$pkg/hooks/"
ditto -c -k --keepParent "$pkg" "$rel/Pitwall-9.9.zip"
echo "9.9 $(shasum -a 256 "$rel/Pitwall-9.9.zip" | awk '{print $1}')" > "$rel/latest.txt"
printf '#!/bin/sh\necho "$@" >> "$HOME/opened"\n' > "$HOME/openbin/open" && chmod +x "$HOME/openbin/open" # no real launch
remote() { PITWALL_BASE_URL="file://$rel" PATH="$HOME/openbin:$PATH" sh ../scripts/install-remote.sh >/dev/null; }
remote && remote   # second run = update: same result, no duplicate hooks
[ -x "$app/Contents/MacOS/Pitwall" ]
[ -z "$(xattr -p com.apple.quarantine "$app" 2>/dev/null)" ]
[ "$(jq '[.hooks[][]] | length' "$s")" = 8 ]
[ -x "$HOME/.claude-monitor/monitor-hook.sh" ]
[ "$(wc -l < "$HOME/opened" | tr -d ' ')" = 2 ]
# A wrong checksum aborts before anything changes
touch "$app/marker" && cp "$s" "$HOME/s.before"
echo "9.9 $(printf '0%.0s' $(seq 64))" > "$rel/latest.txt"
if remote 2>/dev/null; then echo "installed despite a bad checksum" >&2; exit 1; fi
[ -e "$app/marker" ]
cmp -s "$s" "$HOME/s.before"
# Uninstall deletes the installed app too
./uninstall.sh >/dev/null
[ ! -e "$app" ]
[ "$(jq -c . "$s")" = '{}' ]

echo "all hook tests passed"
