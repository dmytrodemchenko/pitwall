#!/bin/bash
# Claude Code hook: appends one JSON line per event to ~/.claude-monitor/events.jsonl.
# Must never break a Claude Code session: no stdout, always exit 0.

umask 077 # the log holds commands, paths and reports: owner-only
dir="$HOME/.claude-monitor"
jq=$(command -v jq) || exit 0
mkdir -p "$dir" 2>/dev/null || exit 0
input=$(cat)

# The Claude Code process (pid, tty) and its terminal app, so the menu can bring that tab to the front.
# A few ps calls: only on rare events (Stop runs every turn, which also covers sessions started earlier).
pid=null tty="" app="${__CFBundleIdentifier:-}"
event=$(printf '%s' "$input" | "$jq" -r '.hook_event_name // empty' 2>/dev/null)
case "$event" in SessionStart|Stop|Notification)
  p=$PPID fallback=""
  for _ in 1 2 3 4 5 6 7 8; do
    [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || break
    info=$(ps -o ppid=,tty=,comm= -p "$p" 2>/dev/null)
    [ -n "$info" ] || break # no ps, or the process is gone: no pid rather than a wrong one
    read -r ppid t comm <<<"$info"
    case "${comm##*/}" in
      claude) pid=$p tty=$t; break ;;
      sh|bash|zsh|dash|fish|-sh|-bash|-zsh) ;;
      *) [ -z "$fallback" ] && fallback="$p $t" ;; # e.g. node running the npm build of Claude Code
    esac
    p=$ppid
  done
  if [ "$pid" = null ] && [ -n "$fallback" ]; then read -r pid tty <<<"$fallback"; fi
  case "$tty" in ""|"??") tty="" ;; *) tty="/dev/$tty" ;; esac
esac
case "$pid" in ""|*[!0-9]*) pid=null ;; esac # --argjson needs a number or null, else the event is dropped

line=$(printf '%s' "$input" | "$jq" -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson pid "$pid" --arg tty "$tty" --arg app "$app" '
  (.tool_input.subagent_type? // (.agent_type | select(. != "")) // null) as $agent |
  # An untyped SubagentStop (agent_type "") may be the verifier: the app knows which agent it was.
  (.hook_event_name == "SubagentStop" and ($agent == "verifier" or $agent == null)) as $report |
  {
    timestamp: $ts,
    session_id, cwd, hook_event_name, transcript_path,
    tool_name: (.tool_name // null),
    # What the tool works on (file, command, pattern, URL, query), shown as the current action on the card.
    tool_detail: (.tool_input | if type == "object"
      then (.file_path // .notebook_path // .command // .pattern // .url // .query // .path // null
            | if type == "string" then .[0:300] else null end)
      else null end),
    subagent_type: $agent,
    # SubagentStop fires when the subagent really finishes (Agent PostToolUse may fire early for background agents).
    verdict: (
      if $report
      then (if (.last_assistant_message // "" | tostring | [splits("\n") | select(test("\\S"))] | last // ""
             | ascii_downcase | contains("verdict: fail")) then "fail" else "pass" end)
      else null end),
    # The verifier report ending (the app matches its own failure pattern from Settings against it).
    last_message: (if $report
      then (.last_assistant_message // "" | tostring | .[-2000:]) else null end),
    # Task list, after the call succeeded: TodoWrite sends the whole list; TaskCreate/TaskUpdate one task.
    todos: (if .hook_event_name == "PostToolUse" and .tool_name == "TodoWrite" and (.tool_input.todos | type) == "array"
      then [.tool_input.todos[:100][] | select(type == "object")
            | {content: (.content // "" | tostring | .[0:200]), status: (.status // "pending" | tostring)}]
      else null end),
    task: (if .hook_event_name != "PostToolUse" then null
      elif .tool_name == "TaskCreate" then
        {id: (.tool_response | if type == "object" then (.task.id? // null) else null end | if . == null then null else tostring end),
         subject: (.tool_input.subject // "" | tostring | .[0:200]), status: "pending"}
      elif .tool_name == "TaskUpdate" then
        {id: (.tool_input.taskId // .tool_input.id // .tool_input.task_id // null | if . == null then null else tostring end),
         subject: (.tool_input.subject // null | if . == null then null else tostring | .[0:200] end),
         status: (.tool_input.status // null)}
      else null end),
    pid: $pid,
    tty: (if $tty == "" then null else $tty end),
    terminal_app: (if $app == "" then null else $app end)
  }' 2>/dev/null) || exit 0

# One write per event; O_APPEND keeps concurrent sessions from interleaving.
[ -n "$line" ] && printf '%s\n' "$line" >> "$dir/events.jsonl" 2>/dev/null
exit 0
