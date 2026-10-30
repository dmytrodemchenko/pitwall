# Changelog

Versions come from git tags (`v1.2` → 1.2); the build number is the commit count (`scripts/release.sh`).

## Unreleased

- Analytics redesign: four summary tiles (7-day cost with the change against the week before, cache hit ratio with a 7-day sparkline, verifier pass rate, savings on cheaper models), each section on its own card, a cleaner cost chart that labels the peak day, and project rows with share bars that double as the chart's legend.
- Chart colors checked for color blindness: orange, blue, aqua, violet, magenta. The status colors (green, yellow) are no longer used for projects.

## 1.3

- Analytics › Models: per pipeline agent, the model it runs on, its 7-day cost, what the same tokens cost one tier down ("On Sonnet 5.5: $7.47 less (−50%)"), and the verifier result after its runs, per model. Subagent usage is now tagged with its agent type (from `.meta.json`); older rows are tagged once on the next launch.
- Cache expiry warning: 2 min before the prompt cache of a waiting session expires, "storefront: prompt cache expires in 2 min. A message after that costs $0.96 more" (5 min or 1 h TTL, from the session's cache writes). Only from $0.50 extra; Settings > Cache.
- Collision alert: "storefront and api are both editing cart.ts" when two sessions edit the same file within 30 min (once per pair and file).

## 1.2.2

- The header's "today" comes from the transcripts, like the Analytics chart, so the two always agree; it no longer shows $0.00 when no session has sent an event yet.
- After `uninstall.sh --purge` and a new install, Analytics imports the full 30 days again (it imported only today).
- Pipeline: subagent runs from before the event log started (a first install, or after `--purge`) are read from the subagent transcripts (`subagents/agent-*.jsonl` + `.meta.json`), so the 7 days are complete.
- The Analytics store files are owner-only (600), like the rest of the app's data.

## 1.2.1

- Config changes: saves with no verifier run in between count as one change, so a burst of `CLAUDE.md` edits is one row.

## 1.2

- Renamed to **Pitwall** (was Claude Monitor; bundle id `com.demchenko.Pitwall`). Data stays in `~/.claude-monitor`. Delete the old `ClaudeMonitor.app`; set up Settings, Notifications, Automation and Start at login again.
- The accent and the mascot are Claude Code orange (`#D97757` / `#E08466` in dark mode); running sessions are green.
- Current action: paths are shown relative to the session folder and with `~` for your home; `cd … &&` is skipped ("Running npm test").
- Demo mode: `open -n Pitwall.app --args -demo YES` shows made-up sessions with an active pipeline and a made-up week of analytics.
- Config changes (Analytics): each edit of an agent prompt or `CLAUDE.md` with the verifier failure rate before and after it ("planner prompt — 40% → 15%").
- Notifications are titled **Pitwall** (were "Claude Code"), so they don't look like they come from Anthropic. MIT license; the README says Pitwall isn't affiliated with Anthropic.
- Loop alert: "storefront: developer is looping, $3.20 in 10 min" with a **Stop…** button, when one call repeats 5 times with no edit in between, one file gets 12 edits, or the verifier fails 3 times in a row (counted within 10 min, except verifier fails).
- New mascot, **Pip**: an original round orange pit-crew kid with a cowlick, two legs and round eyes, in place of the Claude Code mascot; the app icon too. Public releases are no longer limited by the trademark.
- One-line install and update: `curl -fsSL https://github.com/dmytrodemchenko/pitwall/releases/latest/download/install.sh | sh` (checks the SHA-256, installs to `~/Applications`, registers the hooks, starts the app). `scripts/release.sh --adhoc` builds the release without an Apple Developer account. `uninstall.sh` also deletes `~/Applications/Pitwall.app`.
- The mascot is a pit engineer: a radio headset everywhere (its mic lights up while waiting), and on the popover stage a telemetry tablet while running, the chequered flag on a pass and its helmet beside it when idle.

### Security & privacy
- `~/.claude-monitor` and its files are owner-only (700/600); `install.sh` fixes an existing folder.
- Allow/Deny notifications say when the command has more lines or was cut, and then offer Deny only.
- Allow needs an unlocked Mac.
- The system log no longer holds commands, paths or messages (`os.Logger`, private).
- Stop signals only Claude Code (a `node` process must be running `claude-code`); the dialog shows the folder.

### Reliability & performance
- `events.jsonl` is trimmed to 7 days at a quiet launch.
- Transcripts are read off the main thread.
- Analytics shows save errors; keeps 30 days. Ended sessions are dropped after a day.
- Hook: reads the event name as JSON; no pid instead of a dropped event when `ps` finds nothing.
- Only one copy runs: a second launch (say an Xcode build next to the installed app) quits at once.
- The verifier's failure pattern is matched against the last line of its report only, so quoting "VERDICT: PASS or VERDICT: FAIL" earlier doesn't count as a failure.
- `install.sh` keeps a symlinked `settings.json` a symlink and won't overwrite a concurrent change.

### Build
- Hardened runtime with the Apple Events entitlement; strict concurrency, zero warnings.
- `scripts/release.sh`: Developer ID signing, notarization, zip with the app and hooks. CI on every push.

### Product
- Settings: Start at login.
- Livelier mascot: arms swing and eyes glance while walking; it droops and sweats on a failure; crouches, jumps with arms up and blushes on a pass; breathes while asleep in the popover. Shading and catchlights at popover size.
- Sessions/Analytics switch: a liquid highlight that stretches across and settles with a wobble, labels that change color exactly under it, pages that slide across together (the leaving one shrinks, blurs and fades), and a popover that springs to the new height instead of jumping.
- Resume and Stop sit on each session card (on hover) instead of the footer; the footer's New menu also resumes ended sessions.
- Subscription mode shows costs as "≈ $…" marked API-equivalent.
- Analytics: "7 days" on the cost total and the project list; the cache chart's axis fits the data; Claude Code's built-in and plugin agents are listed under "Other agents", apart from the pipeline; long agent names are cut at the end, with the full name on hover.
- One accent color, the mascot's terracotta; Running is a green status color. The first chart color is the accent too.
- The pipeline track shows on every session whose project defines agents (`.claude/agents`), with the gates still to run in gray; built-in agents aren't on it.
- A heredoc command shows as "Running python3 script".
- `hooks/uninstall.sh` (`--purge` deletes the data too). Manual update steps in the README.

## 1.1
- First internal version: sessions, gates, usage and cost, Analytics, Allow/Deny from notifications.
