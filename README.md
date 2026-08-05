# Claude Usage — macOS menu bar widget

A tiny native menu bar app that shows your current Claude Code **session usage %**
and a **countdown until the session resets**, e.g. `✳ 57% · 1h07m`.

Click the icon for details:

```
Session  █████░░░░░  57%   resets 12:30 (1h07m)
Week     █░░░░░░░░░   8%   resets Wed 12 Aug 03:00
─────────────────────────────────────────────────
Updated 10:04:12
Refresh Now                                    ⌘R
─────────────────────────────────────────────────
Start at Login
Quit Claude Usage                              ⌘Q
```

The text turns **orange at ≥80%** and **red at ≥95%** usage.

## How it works

- Reads your Claude Code OAuth token from the macOS Keychain
  (item `Claude Code-credentials`, falling back to `~/.claude/.credentials.json`).
- Polls `https://api.anthropic.com/api/oauth/usage` every 60 seconds — the same
  endpoint Claude Code's own `/usage` command uses.
- The countdown in the menu bar ticks every 10 seconds between polls.
- No dock icon (`LSUIElement`), no dependencies — one Swift file compiled with `swiftc`.

## Build & run

```bash
./build.sh
open ClaudeUsage.app
```

Requires Xcode Command Line Tools (`xcode-select --install`).

## Start at login

Click the menu bar icon → **Start at Login**. (Uses `SMAppService`; if you move
the .app afterwards, toggle it off and on again.)

## Troubleshooting

- **Keychain popup on first launch** — macOS asking to allow reading the
  `Claude Code-credentials` item. Click **Always Allow**.
- **Shows `—` / "Token expired"** — the OAuth token in the Keychain has expired.
  Run any Claude Code command; it refreshes the token, then hit **Refresh Now**.
- **Shows `…`** — still loading, or no network.
