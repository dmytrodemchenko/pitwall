<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Pitwall icon">
</p>

<h1 align="center">Pitwall</h1>

<p align="center">
  A macOS menu bar app that monitors your Claude Code sessions.<br>
  Status, pipeline gates, tokens and cost. All data stays on your Mac.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-lightgrey.svg" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Swift-5-orange.svg" alt="Swift 5">
  <img src="https://img.shields.io/badge/dependencies-none-brightgreen.svg" alt="No dependencies">
</p>

> [!NOTE]
> Pitwall is an independent project. Anthropic does not make, endorse or support it.
> Claude and Claude Code are trademarks of Anthropic, PBC.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/cards-dark.png">
    <img src="docs/images/cards-light.png" width="360" alt="Session cards in the Pitwall popover">
  </picture>
</p>

## Install

```sh
curl -fsSL https://github.com/dmytrodemchenko/pitwall/releases/latest/download/install.sh | sh
```

You need macOS 14 or later, Claude Code and `jq` (macOS 15 and later include it). The command installs
`Pitwall.app` in `~/Applications`, registers the Claude Code hooks and starts the app. To update, run it again.
For details, other install methods and uninstall, refer to [Installation](#installation).

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [The menu bar icon](#the-menu-bar-icon)
- [Session cards](#session-cards)
- [Notifications](#notifications)
- [Analytics](#analytics)
- [Settings](#settings)
- [Configuration files](#configuration-files)
- [Privacy and data](#privacy-and-data)
- [Update](#update)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [License](#license)

## Features

- **Live status.** The menu bar icon shows the status of all active sessions: running, waiting, failed or idle.
- **Pipeline gates.** Each session card shows the subagents that ran (for example, architect, planner, developer,
  verifier) and the time of each run.
- **Tokens and cost.** Each card shows the tokens and the API-equivalent cost of the session.
- **Allow or deny from a notification.** When Claude Code asks for a permission, you can answer from the
  notification.
- **Loop detection.** Pitwall tells you when an agent repeats the same action and spends money without progress.
- **Cache expiry warning.** Pitwall tells you before the prompt cache of a waiting session expires, and what your
  next message will cost more after that.
- **Collision alert.** Pitwall tells you when two sessions edit the same file.
- **Analytics.** Cost per day, cache hit ratio, gate times and the verifier failure rate for the last 7 days.
- **Models.** For each pipeline agent: the model it runs on, its cost for 7 days, how much less the same tokens cost
  one tier down (Opus → Sonnet → Haiku), and how often the verifier passed after it, per model.
- **Config impact.** Pitwall compares the verifier failure rate before and after each change to an agent prompt
  or to `CLAUDE.md`.
- **Budget.** A daily budget in USD, or a token limit for a 5-hour window on a subscription.
- **Quick actions.** Open the terminal of a session, resume a session, stop a session or start a new one.
- **Local only.** The app makes no network requests. It has no third-party dependencies.

## Requirements

- macOS 14 or later.
- Xcode 16 or later, only to build the app from source.
- `jq`. macOS 15 and later include it. On macOS 14, install `jq` before you start.
- Claude Code.

## Installation

Pitwall has two parts: a Claude Code hook that writes events to a log, and the app that reads the log.

### Quick install

```sh
curl -fsSL https://github.com/dmytrodemchenko/pitwall/releases/latest/download/install.sh | sh
```

The script downloads the latest release and checks its SHA-256 checksum. Then it puts `Pitwall.app` in
`~/Applications`, registers the hooks (as `hooks/install.sh` does) and starts the app. It does not use `sudo`.
To install a specific version, set `PITWALL_VERSION`, for example `... | PITWALL_VERSION=1.2 sh`.

The release is signed ad hoc, not with an Apple Developer ID. macOS opens it without a warning because files
that `curl` downloads get no quarantine attribute. If you download the zip in a browser instead, macOS
blocks the app. Refer to [Troubleshooting](#troubleshooting).

When macOS asks, allow notifications. Then start a Claude Code session.

### Build from source

1. Clone the repository:

   ```sh
   git clone https://github.com/dmytrodemchenko/pitwall.git
   cd pitwall
   ```

2. Register the hooks:

   ```sh
   hooks/install.sh
   ```

   The script copies the hook scripts to `~/.claude-monitor/`. Then it adds them to `~/.claude/settings.json`.
   The script keeps all your existing hooks. Before it changes the file, it makes a backup
   (`settings.json.bak.<timestamp>`). You can run the script again. It does not add duplicate entries.

3. Build the app and copy it to the Applications folder:

   ```sh
   xcodebuild -project Pitwall.xcodeproj -scheme Pitwall -configuration Release -derivedDataPath build build
   cp -R build/Build/Products/Release/Pitwall.app /Applications/
   ```

4. Start the app:

   ```sh
   open /Applications/Pitwall.app
   ```

5. When macOS asks, allow notifications.

6. Start a Claude Code session. The session appears in the Pitwall menu.

To start Pitwall when you log in, turn on **Start at login** in Settings.

## The menu bar icon

The icon is Pip, the Pitwall mascot. Pip shows the most important status of all active sessions.
The order is: failed, then waiting, then running, then idle.

<p align="center">
  <img src="docs/images/pip.png" width="420" alt="Pip: running, passed and waiting">
</p>

| Pip | Status |
|-----|--------|
| Walks and blinks | A session is running. |
| Looks up at a yellow dot | A session waits for your permission or input. |
| Red, with X eyes | A verifier subagent reported a failure. |
| Happy eyes and a jump | The verifier passed. |
| Asleep, outline only | No session is active. |

Click the icon to open the popover. Press **⌥⌘C** to open or close the popover from any app.
Press **Escape** to close it.

If **Reduce motion** is on (System Settings > Accessibility > Display), the icon does not move.

## Session cards

The **Sessions** tab shows one card for each active session. A card shows:

- **Project and status.** The project folder name and the status of the session.
- **Time, tokens and cost.** The time since the session started, the tokens and the API-equivalent cost.
- **Current action.** The last tool call, for example "Editing App.swift" or "Running npm test".
  Paths are relative to the project folder. Move the pointer over the text to see the full command.
- **Pipeline track.** The subagents that ran, in order, and the duration of the last run of each one.
  Agents that are defined in `.claude/agents/` but did not run yet are gray. A run that takes more than
  10 minutes is yellow.
- **Tasks.** The progress of the task list, for example "3/5 tasks".
- **Context.** How full the context window is. The bar is yellow from 70% and red from 85%.
- **Git.** The branch and the number of changed files.

### Actions

- **Click a card** to bring the terminal of the session to the front. In iTerm2 and Terminal.app, Pitwall selects
  the correct tab.
- **Resume** opens a new terminal tab in the project folder and runs `claude --resume <session id>`.
- **Stop** asks for confirmation. Then it sends Ctrl-C (SIGINT) to the Claude Code process.
  Pitwall sends the signal only if the process is still Claude Code.
- **New session** opens a terminal tab in a recent project and runs `claude`.
- **Open in IDE** (right-click a card) runs the IDE command from Settings with the project folder.
  The default command is `webstorm`.

The first time that Pitwall controls a terminal, macOS asks for Automation permission.

## Notifications

Pitwall sends a notification when:

- A session waits for your input.
- The verifier fails.
- The context of a session is more than 85% full.
- An agent is in a loop.
- The prompt cache of a waiting session expires in 2 minutes (see below).
- Two sessions edit the same file, for example "storefront and api are both editing cart.ts".
- You reach 80% or 100% of your budget.

### Allow or deny a permission request

When Claude Code asks for a permission, Pitwall shows a notification with the tool, a summary of the command,
file or URL, and two buttons: **Allow** and **Deny**.

- Only the **Allow** button allows the request.
- **Deny** denies the request.
- If you close the notification, click its body, or do not answer in 50 seconds, Pitwall sends no decision.
  Claude Code then shows its usual prompt in the terminal.
- If Pitwall is not running, Claude Code shows the terminal prompt immediately.
- If a command has more lines than the notification can show, the notification shows **Deny** only.
  Use the terminal to allow it.

To keep the buttons on the screen, set the notification style to **Alerts**
(System Settings > Notifications > Pitwall).

### Loop alerts

Pitwall sends a loop alert, for example "storefront: developer is looping, $3.20 in 10 min", when one of these
conditions occurs:

- The same tool call occurs 5 times in 10 minutes, and no file changes between the calls.
- The same file gets 12 edits in 10 minutes.
- The verifier fails 3 times in sequence.

The alert has a **Stop…** button. It asks for confirmation before it stops the session.

### Cache expiry warning

Claude Code caches the conversation for 5 minutes (or 1 hour) after each reply. If you answer later, the whole
context is written to the cache again, at the cache-write price instead of the cache-read price. For a session that
waits for you, Pitwall sends a warning 2 minutes before the cache expires, for example
"storefront: prompt cache expires in 2 min. A message after that costs $0.96 more".

Pitwall sends the warning only when the extra cost is at least $0.50. To change the amount, or to turn the warning
off (0), use **Settings > Cache > Expiry warning from**.

### Verifier result

To get a "verifier failed" alert, make sure that your `verifier` subagent ends its report with one of these lines:

```
VERDICT: PASS
VERDICT: FAIL
```

You can change the failure pattern in Settings > Pipeline.

## Analytics

The **Analytics** tab shows the data for the last 7 days:

- **Cost per day.** The bars show the cost of your top 5 projects. Move the pointer over a bar to see the values.
- **Projects.** The tokens and the cost of each project.
- **Cache hit ratio.** Cache reads divided by the sum of cache reads, cache writes and input tokens.
  If the ratio of an active session stays below the limit for 10 minutes, its card shows a warning.
- **Pipeline.** The number of runs, the average time and the median time of each subagent.
  The gate that used the most time is highlighted. The verifier failure rate is below the chart.
- **Config changes (30 days).** Each change to an agent prompt or to `CLAUDE.md`, with the verifier failure rate
  before and after the change. For example: "planner prompt: Verifier fails 40% → 15% (10 → 9 runs)".
  Pitwall shows a rate only when there are 3 or more runs before and after the change.

When Pitwall starts for the first time, it imports the last 30 days of transcripts in the background.

### How Pitwall finds config changes

Pitwall records a hash of each agent prompt and `CLAUDE.md`, in the project and in `~/.claude`.
When a hash changes, Pitwall records the change with the modification time of the file.
This works also when these files are not in git. For the time before the first record, Pitwall reads the
git history of the project.

## Settings

Click the gear icon in the popover to open Settings.

| Setting | Default | Description |
|---------|---------|-------------|
| Start at login | Off | Starts Pitwall when you log in. |
| Shortcut | ⌥⌘C | Opens and closes the popover. |
| IDE command | `webstorm` | The command for **Open in IDE**. |
| Terminal | iTerm2, if installed | The app for new sessions: iTerm2 or Terminal. |
| Context warning | 70% | The card shows the context bar in yellow. |
| Context alert | 85% | The card shows the context bar in red and Pitwall sends a notification. |
| Billing mode | API | **API**: a daily budget in USD. **Subscription**: a token limit for 5 hours. |
| Cache warning | 50% | The lowest cache hit ratio before a warning. |
| Gate time limit | 10 min | A gate run that takes longer is yellow. |
| Verifier failure pattern | `VERDICT: FAIL` | A regular expression, not case-sensitive. |

### Budget

- **API mode.** Set a daily budget in USD. Pitwall sends a notification at 80% and at 100%, one time each day.
- **Subscription mode.** Set the number of tokens that you expect in a 5-hour window. Pitwall counts input,
  output and cache-write tokens from your local transcripts. It does not count cache reads. The value is an
  estimate, because Anthropic does not publish exact limits. Pitwall does not read your OAuth token.

## Configuration files

Pitwall creates these files in `~/.claude-monitor/` when it starts for the first time. Edit a file, then
restart the app.

### `prices.json`

The price of each model, in USD for 1 million tokens. Each key is the start of a model ID.
The longest key that matches is used.

```json
"claude-opus-5-5": { "input": 4, "output": 20, "cache_read": 0.2, "cache_write_5m": 5, "cache_write_1h": 8 }
```

If a model has no price, its card shows the tokens and "—" for the cost.

### `context.json`

The context window of each model. The default is 200,000 tokens.

## Privacy and data

- Pitwall makes no network requests.
- Pitwall reads `~/.claude/projects/` (transcripts) and `~/.claude-monitor/` (events). For this reason,
  the app is not sandboxed.
- Only your user can read the data folder and its files (permissions 700 and 600).
  The event log contains commands, paths and verifier reports.
- The system log does not contain commands, paths or messages. They show as `<private>`.
- The hook and the app communicate through a Unix socket, `~/.claude-monitor/monitor.sock` (permissions 600).

| File | Contents | Kept for |
|------|----------|----------|
| `~/.claude-monitor/events.jsonl` | One line for each hook event | 7 days |
| `~/.claude-monitor/config-history.json` | Hashes of agent prompts and `CLAUDE.md` | 30 days |
| `~/Library/Application Support/ClaudeMonitor/analytics.store` | Token usage and gate runs | 30 days |

> [!NOTE]
> The data folders have the name of the earlier version of the app, Claude Monitor. This prevents data loss
> when you update.

## Update

Pitwall has no automatic updates, because it makes no network requests.

If you used the quick install, run the same command again. It quits Pitwall, replaces the app, updates the
hook scripts and starts Pitwall again. It does not add duplicate hooks.

macOS links some permissions to the app signature, and an ad-hoc signature changes with each release.
After an update, macOS can ask again for Automation (iTerm2 or Terminal) and Notifications. You can also have
to turn on **Start at login** again.

If you built from source:

1. Quit Pitwall.
2. Get the new version and build the app again. Replace `Pitwall.app` in the Applications folder.
3. Run `hooks/install.sh` from the new version. The script updates the hook scripts. It does not add duplicates.
4. Start Pitwall.

Pitwall keeps your settings, `prices.json`, `context.json` and analytics data.

## Uninstall

```sh
curl -fsSL https://github.com/dmytrodemchenko/pitwall/releases/latest/download/uninstall.sh | bash
```

From a clone of the repository, run `hooks/uninstall.sh` instead.

The script removes only the Pitwall entries from `~/.claude/settings.json`. It makes a backup first.
It quits Pitwall and deletes `~/Applications/Pitwall.app`. If you put the app in `/Applications`, delete it yourself.

To delete all Pitwall data also, use the `--purge` option:

```sh
curl -fsSL https://github.com/dmytrodemchenko/pitwall/releases/latest/download/uninstall.sh | bash -s -- --purge
```

## Troubleshooting

**macOS says that Pitwall is damaged or is from an unidentified developer.**
The app has the quarantine attribute, for example because you downloaded the zip in a browser.
Install with the `curl` command, or remove the attribute:

```sh
xattr -dr com.apple.quarantine ~/Applications/Pitwall.app
```

**Pitwall shows no notifications.**
Open System Settings > Notifications > Pitwall and turn on **Allow notifications**. If you closed the first
permission prompt, macOS receives the notifications but does not show them.

**A session stays in the "Waiting" status after you stopped Claude Code.**
Claude Code did not send a SessionEnd event. Pitwall removes the session after 30 minutes without events.

**A session does not appear.**
Make sure that the hooks are in `~/.claude/settings.json`. Run `hooks/install.sh` again if necessary.
Then make sure that `jq` is installed:

```sh
command -v jq
```

**To read the Pitwall log:**

```sh
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.demchenko.Pitwall"'
```

## Development

### Build and test

```sh
xcodebuild -project Pitwall.xcodeproj -scheme Pitwall test
hooks/test.sh
```

### Snapshots

To render the popover, the session cards and the icon frames to PNG files:

```sh
TEST_RUNNER_SNAPSHOT_DIR=/tmp/snap xcodebuild -project Pitwall.xcodeproj -scheme Pitwall test \
  -only-testing:PitwallTests/SnapshotTests
```

### Demo mode

To run Pitwall with sample sessions and sample analytics, for example for screenshots:

```sh
open -n Pitwall.app --args -demo YES
```

Demo mode does not read your data. It can run at the same time as your usual copy of Pitwall.

### Release

To build a release from the latest git tag, with an ad-hoc signature:

```sh
git tag v1.2
scripts/release.sh --adhoc
gh release create v1.2 build/release/upload/*
```

The `upload` folder has the zip, its checksum, `latest.txt`, `install.sh` and `uninstall.sh`.
The quick install reads these files from the latest GitHub release.

To sign with a Developer ID and notarize, set `TEAM_ID` and omit `--adhoc`. For the one-time setup, refer to
the header of `scripts/release.sh`.

### Project structure

```
hooks/            Claude Code hooks and the install, uninstall and test scripts
Pitwall/          App source code
PitwallTests/     Unit tests (XCTest)
scripts/          Release script and the one-line installer
docs/images/      Images for this file
```

## License

Pitwall is available under the [MIT License](LICENSE). The license includes the Pip mascot.
