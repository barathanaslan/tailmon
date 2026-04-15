# Plan 05: Phase 4 — SwiftUI menubar app

## Goal

Ship the native macOS menubar app that was the original goal of this project: a small SwiftUI `MenuBarExtra` that lives in the MacBook's menubar, polls the collector, and gives a one-click window into the Mac Studio's state (with control actions). Installs to `/Applications`, launches at login.

This phase is a hard shift: new language (Swift), new toolchain (SwiftPM + `xcodebuild`, or a minimal Xcode project), new runtime (AppKit + SwiftUI). Everything from Phases 1–3 is the *backend*; this phase builds the frontend that was implied by the original conversation.

## Scope

- **B13** — SwiftUI menubar app with live polling, graphs, and control actions

**In scope for this phase**:

- Menubar icon with compact status (e.g., CPU% + SSH count, or a small bar + number)
- Click → popover window with:
  - Header: connection state (green/yellow/red dot) + last-poll age
  - System overview: CPU bar, GPU bar, MEM bar + cached line, PWR line (CPU/GPU/total watts)
  - **Live sparkline graphs** for CPU %, GPU %, MEM %, Total power (last ~60 seconds, 1s resolution). Use Swift Charts.
  - Tabbed or segmented sections for: Processes (top 10), Listening Ports, SSH Sessions, Tmux Sessions
  - Action buttons: kill process (with confirm), kick SSH session (with confirm), create tmux session (with text field + confirm)
- Live polling: 3s cadence when the popover is closed, 1s when the popover is open
- Reads configuration from **`~/.config/studio-cli/config.toml`** (same file the Python CLI uses) and token from **`~/.config/studio-cli/token`**. Single source of truth; no separate prefs UI for these in v1.
- Ad-hoc codesigned `.app` bundle (no Apple Developer account required)
- Install script that copies `StudioMenuBar.app` to `/Applications` and installs a user launchd agent at `~/Library/LaunchAgents/com.bosphorify.studiomenubar.plist` for launch-at-login
- Uninstall script that reverses the install

**Out of scope** (deferrable, to the backlog):

- Preferences window / settings UI (collector URL, poll interval knobs) — defer. Use defaults.
- Process search / filter inside the popover — defer.
- Historical metrics beyond the 60s in-memory window — defer.
- Notifications on thresholds (CPU > 80% etc.) — defer.
- Multi-host support — defer (forever; see `docs/overview.md` non-goals).
- App Store / notarization — defer forever; personal tool.

## Success criteria

1. `cd menubar && bash build.sh` produces `menubar/build/StudioMenuBar.app` with an ad-hoc signature that runs on the current Mac without Gatekeeper intervention beyond the first right-click-open.
2. Running `StudioMenuBar.app` shows the menubar icon immediately with real live data from the collector within 3 seconds of launch.
3. Clicking the menubar icon opens the popover. Every section renders real data: CPU/GPU/MEM/PWR bars animate, processes list shows real top-10, ports list shows real listeners, SSH list shows real sessions, tmux list shows real sessions (all from the user's namespace thanks to B17).
4. The four sparkline graphs show a growing 60s history after the app has been running for a minute.
5. A "Kill" button on a process row in the popover successfully calls `POST /kill` and the row disappears from the next poll.
6. A "Kick" button on an SSH session row calls `POST /ssh/kick` (with its own session safeguarded by the collector).
7. A "New" button next to the tmux list opens a small inline text field; submitting it calls `POST /tmux/new` and the new session appears on the next poll.
8. `bash install.sh` copies the `.app` to `/Applications` and installs the launchd agent; logging out and back in re-launches the app automatically.
9. `bash uninstall.sh` reverses everything cleanly (removes app, removes agent, kills any running instance).
10. Swift unit tests pass via `swift test` (target: ~20-30 tests covering the Codable models, the HTTP client with a mocked URLProtocol, the poll service state transitions, and the config loader).

## Directory layout

```
studio-cli/
├── menubar/
│   ├── Package.swift                     # SPM manifest (executable target)
│   ├── Info.plist                        # LSUIElement=YES, bundle id, version
│   ├── Entitlements.plist                # empty / minimal (no sandbox)
│   ├── build.sh                          # swift build + .app assembly + codesign --sign -
│   ├── install.sh                        # cp to /Applications, install launchd agent
│   ├── uninstall.sh                      # remove both
│   ├── deploy/
│   │   └── com.bosphorify.studiomenubar.plist   # launchd agent template
│   ├── Sources/
│   │   └── StudioMenuBar/
│   │       ├── StudioMenuBarApp.swift    # @main, SwiftUI App, MenuBarExtra scene
│   │       ├── AppState.swift            # @Observable state: current snapshot, history rings, connection state
│   │       ├── StudioClient.swift        # URLSession-based HTTP client, maps errors to typed cases
│   │       ├── Models.swift              # Codable structs matching the collector JSON schema
│   │       ├── Config.swift              # reads ~/.config/studio-cli/config.toml + token file, minimal TOML parser
│   │       ├── PollingService.swift      # timer-driven poll loop, 3s/1s cadence switch
│   │       ├── MenuBarView.swift         # the compact label shown in the menubar
│   │       └── Views/
│   │           ├── PopoverView.swift
│   │           ├── SystemOverviewView.swift  # bars + PWR line
│   │           ├── ChartsView.swift          # 4 sparklines via Swift Charts
│   │           ├── ProcessesTab.swift        # table + kill button
│   │           ├── PortsTab.swift            # table (read-only)
│   │           ├── SSHTab.swift              # table + kick button
│   │           ├── TmuxTab.swift             # table + new button
│   │           └── ConfirmSheet.swift        # reusable confirm dialog
│   └── Tests/
│       └── StudioMenuBarTests/
│           ├── ModelsTests.swift
│           ├── StudioClientTests.swift   # URLProtocol-mocked
│           ├── ConfigTests.swift         # temp dir fixtures
│           └── PollingServiceTests.swift
└── (everything else unchanged)
```

## Build approach

- **Swift Package Manager (SPM)** for the executable target. Package.swift declares one executable product, macOS 13+ platform, Swift 5.9+.
- No external SPM dependencies. Stdlib + SwiftUI + Charts + AppKit + Foundation only. If the worker finds a real reason to pull in a TOML parser (TOMLKit or swift-toml), it can — but a 50-line hand-rolled parser for our 4 keys is preferred.
- `build.sh` sequence:
  1. `swift build -c release --package-path menubar`
  2. Assemble the `.app` bundle structure: `menubar/build/StudioMenuBar.app/Contents/{Info.plist, MacOS/StudioMenuBar, Resources/}`
  3. Copy the SPM-built binary in, copy Info.plist in.
  4. `codesign --deep --force --sign - menubar/build/StudioMenuBar.app` — ad-hoc signature (the `-` means "no identity"; it's enough for local execution).
- No Xcode project file (`.xcodeproj`) unless the worker finds that SPM genuinely can't express something we need. If they do create one, keep it hand-editable and committed.

## Configuration surface (Swift side)

`Config.swift` mirrors the Python `config.py` behavior:

1. Read env vars first: `STUDIO_COLLECTOR_URL`, `STUDIO_TOKEN`, `STUDIO_TOKEN_FILE`, `STUDIO_TIMEOUT`. Useful for debugging / launching from terminal.
2. Read `~/.config/studio-cli/config.toml` if it exists. Hand-rolled TOML parser: the file only has four string / number keys (`collector_url`, `token_file`, `timeout_seconds`, `ssh_host`), so a line-wise parser with strip-and-split handles it cleanly. Reject malformed input with a clear error.
3. Read the token from `token_file` (default `~/.config/studio-cli/token`). **Enforce mode `0600`** — same check the CLI does. If the mode is wider, set the app state to an error with a fix hint (don't crash).
4. Built-in defaults match the Python side: `http://100.80.21.79:8765`, `~/.config/studio-cli/token`, `5.0`, `macstudio`.

Config load failures surface in the popover header as a red banner with the error message. No preferences UI in v1; the fix is always "edit `~/.config/studio-cli/config.toml`".

## Polling and state

`PollingService` is a timer-driven actor (or class) that:

- Owns a `URLSession` with a 5-second timeout.
- Has two cadences: `idleInterval = 3.0`, `openInterval = 1.0`. Switches when the popover opens/closes.
- Fetches in parallel: `GET /stats`, `GET /processes?limit=10`, `GET /ports`, `GET /ssh/sessions`, `GET /tmux/sessions`. One poll = five parallel requests. Use `async let` and wait on all.
- On success, pushes the snapshot into `AppState` (observable).
- On failure, sets an error state: connection refused → red dot + "cannot reach collector"; 401 → red dot + "token rejected"; other → red dot + `error.localizedDescription`.
- Maintains a ring buffer for each of CPU/GPU/MEM/PWR — 60 entries at 1s resolution, or the equivalent time window when polling at 3s. The UI graphs read from these ring buffers.

## UI notes

- **Menubar label** (`MenuBarView`): compact. Something like `42% · 3●` (CPU% and SSH count), or an SF Symbol + number. If connection is down, show `!` or a red dot.
- **Popover size**: roughly 480 × 600 pt. Resizable if the user drags the edge, otherwise fixed.
- **Layout**: vertical stack. Top: header with connection state, Tailscale peer identifier (from the collector's hostname field — not in the current API; we display the collector URL for now), last-poll age. Middle: system overview + sparklines. Bottom: tabbed section (Processes / Ports / SSH / Tmux).
- **Tables**: use `Table` (macOS 13+ has native SwiftUI Table). Each row has action buttons inline where relevant.
- **Confirmations**: "Kill process `<name>` (pid=<N>, user=<X>)?" as a `.confirmationDialog` modifier. `--yes`-style auto-confirm is not exposed in v1.

## Installation

- **`install.sh`** (on the MacBook, no sudo needed — everything is user-scope):
  1. Verify `menubar/build/StudioMenuBar.app` exists (if not, run `build.sh` first and bail with a hint).
  2. Remove any existing `/Applications/StudioMenuBar.app` cleanly: first `launchctl bootout gui/$(id -u)/com.bosphorify.studiomenubar 2>/dev/null || true` to stop a running instance, then `rm -rf`.
  3. `cp -R menubar/build/StudioMenuBar.app /Applications/`.
  4. Render the launchd agent plist from `menubar/deploy/com.bosphorify.studiomenubar.plist` (substitute `__HOME__` if needed), write to `~/Library/LaunchAgents/com.bosphorify.studiomenubar.plist` mode 0644.
  5. `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.bosphorify.studiomenubar.plist`
  6. Print "App installed. Look for the icon in the menubar."
- **`uninstall.sh`**: `launchctl bootout`, `rm` the plist and the app. Idempotent.
- The launchd agent plist runs `/Applications/StudioMenuBar.app/Contents/MacOS/StudioMenuBar` with `RunAtLoad=true`, `KeepAlive=true`, StandardOutPath/StandardErrorPath set to `~/Library/Logs/studiomenubar.out.log` / `.err.log`.

## Tests

Use Swift Testing (`import Testing`) or XCTest (`import XCTest`) — worker's call.

- **`ModelsTests`**: round-trip decode all the Codable structs against JSON fixtures captured from the real collector. Include one fixture per endpoint plus one malformed example per that forces the decoder to fail gracefully.
- **`StudioClientTests`**: mock the network via a custom `URLProtocol` subclass; test happy path for each endpoint, timeout, 401, 500, connection refused.
- **`ConfigTests`**: feed the TOML parser happy inputs, malformed inputs, missing keys, env var overrides; verify token-mode enforcement fires on `0o644`.
- **`PollingServiceTests`**: state machine transitions (idle → polling → idle → error → idle), cadence switching.
- **Charts / View tests**: skip. SwiftUI views are painful to unit-test and the popover is the part that needs human eyeballs.

Target: 20–30 tests. `swift test` must pass.

## JSON fixtures to capture

The worker should capture these from the real collector (via authenticated curl) and commit them to `menubar/Tests/StudioMenuBarTests/Fixtures/`:

- `stats.json`
- `processes.json`
- `ports.json`
- `ssh-sessions.json`
- `tmux-sessions.json`

If the worker is offline (can't reach the live collector), they should construct representative fixtures from the existing Python test fixtures under `tests/fixtures/` and the pydantic models under `src/shared/models.py` — same schema, just rendered as JSON. Document which path was taken.

## Guardrails for the worker

- **Do NOT** touch the Python side. No edits to `src/`, `tests/`, `deploy/`, or the Python-side plist. If the Swift app needs an API change, STOP and flag it in the final report instead of silently editing the collector.
- **Do NOT** SSH anywhere. Do not `launchctl` anything. Everything is local to `/Users/barathanaslan/Projects/SSH/studio-cli/`. The install/uninstall scripts are artifacts for the human to run later.
- **Do NOT** add Swift packages unless absolutely necessary. Stdlib + SwiftUI + Charts + AppKit + Foundation is the allowlist.
- **Do NOT** require an Apple Developer account or a provisioning profile. Ad-hoc codesigning only.
- **Do NOT** modify `~/.zshrc`, `~/.config/`, `~/Library/LaunchAgents/`, `/Applications/`, or any system paths during the phase — those are deploy artifacts, not build artifacts.
- **Do NOT** drift scope into preferences UI, notifications, multi-host support, or historical persistence.
- **Do** run `swift build -c release --package-path menubar` and `swift test --package-path menubar` at the end and report both results.
- **Do** build the `.app` via `bash menubar/build.sh` at the end and verify with `codesign -v menubar/build/StudioMenuBar.app` that it's ad-hoc signed and valid.
- **Do** update `docs/progress.md` with a Phase 4 code-complete block and mark B13 ready for human verification.
- **Do** write a PR-notes block at the end: what shipped, deviations, any collector API changes you wanted to make but flagged instead of implementing, recommended smoke-test sequence for the human (build, install, verify live data, try a kill action, uninstall).

## Definition of done

- `menubar/` directory populated per the layout above.
- `swift build -c release --package-path menubar` succeeds.
- `swift test --package-path menubar` passes with ~20-30 tests.
- `bash menubar/build.sh` produces a valid `menubar/build/StudioMenuBar.app` that passes `codesign -v`.
- `docs/progress.md` Phase 4 block added, B13 listed as "code complete, pending human install + live verification".
- PR-notes report under 500 words, honest about any skipped pieces.
