#!/bin/bash
# PermissionRequest hook: asks Pitwall to Allow/Deny through an actionable notification.
# Protocol (one connection per request, socket ~/.claude-monitor/monitor.sock, mode 0600):
#   hook -> app: the hook input as one JSON line
#   app -> hook: "allow" or "deny" as one line, then close
# App not running, no answer within $CLAUDE_MONITOR_WAIT s (default 50), or any other reply:
# print nothing, so Claude Code shows its normal prompt in the terminal. Never allows on its own.
sock="${CLAUDE_MONITOR_SOCKET:-$HOME/.claude-monitor/monitor.sock}"
wait="${CLAUDE_MONITOR_WAIT:-50}"

command -v jq >/dev/null 2>&1 || exit 0
[ -S "$sock" ] || exit 0
req=$(jq -c . 2>/dev/null) || exit 0

# System Perl does the socket round trip (macOS nc can't wait for a reply once its stdin ends).
# alarm: no reply within $wait seconds -> exit with no answer.
answer=$(printf '%s\n' "$req" | /usr/bin/perl -MIO::Socket::UNIX -e '
  my ($path, $wait) = @ARGV;
  $SIG{ALRM} = sub { exit 0 };
  alarm $wait; # covers connecting and sending too, not only the wait for a reply
  my $request = <STDIN>;
  my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $path) or exit 0;
  print $s $request;
  $s->flush;
  my $reply = <$s>;
  print $reply if defined $reply;
' "$sock" "$wait" 2>/dev/null)
answer=${answer%$'\n'}

case "$answer" in
  allow) jq -nc '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"}}}' ;;
  deny)  jq -nc '{hookSpecificOutput: {hookEventName: "PermissionRequest",
                  decision: {behavior: "deny", message: "Denied by the user from Pitwall"}}}' ;;
esac
exit 0
