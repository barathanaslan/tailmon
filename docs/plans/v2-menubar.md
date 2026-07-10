# Plan: Tailmon menubar app — the actual Stats replacement

Self-contained plan. A fresh agent should be able to execute this without other context.

## Context

tailmon v2 (Go) is live: agents on `:7020` on all three machines (Mac Studio
`100.80.21.79` — this machine, MacBook `100.80.159.96`, Windows CUDA box `100.95.91.27`,
usually off). `tailmon json` aggregates the fleet; the TUI shows per-host cards.

The owner's critique of the TUI, verbatim goals for this phase: it "gives very little
insight on what runs, good for seeing if a device is active or not, but that's all". The
menubar app is "the real thing" — the replacement for the Stats.app he runs today. So this
app must be: always visible, glanceable, and reveal **what is actually running** on each
machine (the thing Stats and the old studio-cli v1 gave him that tailmon doesn't yet).

Existing `menubar/` contains a parked v1 SwiftUI app that talks to a dead API — replace
its contents entirely (history stays in git). Swift 6.3.2 toolchain is installed on this
Studio; target macOS 13+ `MenuBarExtra` (both Macs run macOS 26.x, arm64).

## Hard rules

1. **NO power controls anywhere in this app** — no wake, no shutdown, nothing that changes
   any machine's state. Owner was explicit (2026-07-10) after removing the same from the
   TUI. Read-only monitor.
2. Do NOT wake or shut down the CUDA box during this work. It stays off; the fleet view
   simply shows it offline. Test Windows-specific rendering with a JSON fixture.
3. Efficiency is a hard requirement (owner had a leak incident with v1): when the menu is
   CLOSED the app may only run one lightweight local poll for the icon; fleet queries and
   subprocess spawns happen only while the menu is OPEN. No unbounded collections. App RSS
   under ~50 MB.
4. Do not push to GitHub — commit locally; the owner reviews.
5. Keep PowerShell/Windows and agent Go code changes minimal and tested (`go test ./...`
   must stay green, including the soak test).

## Part 1 — small Go enhancement: richer process visibility

- `/stats?top=N`: agent returns N top processes (default 5, hard cap 25). Parse + clamp.
- `tailmon json --top N` passes it through to every host (and to the in-process local
  sample). `tailmon sample --top N` likewise.
- Extend top_procs entries with `command` (short) if cheaply available from gopsutil;
  keep pid/name/cpu_pct/mem_mb as-is. Update schema docs in README (stay `"schema": 1` —
  additive fields only).
- Unit tests for the clamp + param plumbing.

## Part 2 — the SwiftUI menubar app (menubar/, full rewrite)

**App**: `Tailmon.app`, LSUIElement (no Dock icon), MenuBarExtra with window style.

**Menu bar label**: compact live text for the LOCAL machine, e.g. `4% · 17G` (CPU%,
mem used) with the RAM figure tinted by pressure (normal/warn/critical). Data source:
URLSession GET `http://127.0.0.1:7020/stats` every 15s while closed, 3s while open.
If the local agent is down: show `–` dimmed (never crash, never spawn anything).

**Dropdown content** (the Stats replacement):
- One section per tailnet host, same statuses as the TUI (live / no agent / offline).
- Per live host: CPU bar + load, RAM bar + pressure + swap, GPU (util, VRAM, temp when
  present), main disk free, uptime, agent RSS in fine print.
- **Top processes list per host** — THE new capability: name, CPU%, mem. Local host
  expanded by default showing 8; remote hosts collapsible (DisclosureGroup) showing 5,
  fetched with `?top=10` when expanded. This answers "what runs on my machines right now".
- Fleet data: while the menu is open, spawn `~/bin/tailmon json --top 10` every 3s
  (Process, 5s timeout, max one in flight, reap properly). Decode into the same cards.
  Reusing the CLI keeps discovery/fan-out logic in one place.
- Footer row: "Open TUI" (opens Terminal with `tailmon`) is allowed; a Quit item; a
  "Launch at Login" toggle (SMAppService.mainApp).

**Style**: native SwiftUI, monospaced digits for numbers, subtle color coding matching the
TUI (green live, dim offline, yellow no-agent/warn, red critical). No custom themes.

**Packaging**:
- SPM executable target; `menubar/build.sh` builds release and assembles `Tailmon.app`
  bundle (Info.plist: LSUIElement true, CFBundleIdentifier com.bosphorify.tailmon.menubar),
  ad-hoc codesign.
- `menubar/install.sh`: copy to /Applications, (re)launch. `uninstall.sh` reverses,
  including SMAppService deregistration note.
- Update `deploy/README.md` and root `README.md` with the menubar section.

## Verification

1. `go test ./...` green (incl. new param tests); `swift build -c release` clean.
2. Decode-tests in Swift against a fixture captured from real `tailmon json --top 10`
   output (commit the fixture), including a Windows host entry with GPU/VRAM fields and
   an offline host.
3. Build + install on the Studio; verify with `pgrep -x Tailmon` and that the app logs a
   successful local /stats fetch (log to ~/Library/Logs/tailmon-menubar.log, size-capped:
   truncate at 1 MB on launch).
4. While the menu is CLOSED, confirm no `tailmon json` processes appear over a 60s watch
   (`pgrep -fl "tailmon json"` stays empty) — the efficiency contract.
5. Install on the MacBook over ssh (`barathanaslan@100.80.159.96`, key auth works): scp a
   tarball of Tailmon.app, run install.sh remotely. Note: launching a GUI app over ssh
   works via `open -a`; if the app needs one interactive approval, leave it installed and
   note it for the owner instead of fighting macOS.
6. Update docs/progress.md with a dated entry.
7. Redeploy the updated Go binary (Studio launchd + MacBook) so `?top=` works live. Do
   NOT touch the Windows box — its agent gets the update whenever it's next on and the
   owner asks.

## Out of scope (later phases)

Ports/ssh-sessions/tmux insight (needs the auth story from v1), kill/control anything,
Windows tray app, sparkline history in the menubar, repo rename.
