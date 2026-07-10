# Plan: tailmon v2 MVP — tailnet-wide resource monitor (Go rewrite)

Self-contained plan. A fresh agent should be able to execute this without any other context.

## Context

This repo (`~/studio-cli`, github.com/barathanaslan/studio-cli) was a Python v1: a root-run
FastAPI collector on a Mac Studio, consumed by a CLI + SwiftUI menubar app on a MacBook.
That entire v1 is archived on the `v1-python` branch — do not delete that branch.

v2 reframes the project: **every machine on the user's tailnet is both a stats source and a
viewer**. Goal: replace the "Stats" menubar app with something that shows, from any machine,
the live resource usage of that machine AND every online tailnet peer — and that AI tools
can read as JSON. The owner had a bad incident where v1 leaked memory on a MacBook for ~10
days; **bounded memory and near-zero idle footprint are hard requirements, not preferences**.

The fleet:
| Host | Tailscale IP | OS | Notes |
|---|---|---|---|
| barathans-macstudio | 100.80.21.79 | macOS (M3 Ultra, arm64) | always on; this machine |
| barathans-5070 | 100.95.91.27 | Windows 11 (RTX 5070 Ti) | usually OFF; wake with `~/bin/cuda on`, ssh as `barat@100.95.91.27` (key auth works). GPU/CUDA box. |
| barathans-macbook-1 | 100.80.159.96 | macOS (arm64) | currently offline; just needs the same darwin binary later |

## Decisions already made (do not relitigate)

- **Go rewrite**, single binary `tailmon` with subcommands. Python v1 is gone from `main`.
- **TUI first** (bubbletea), monitor-only. No kill/tmux/control endpoints in this version.
- No root anywhere. No bearer tokens: the agent binds ONLY to the machine's Tailscale IP
  + 127.0.0.1; tailnet membership is the security perimeter (monitor-only, read-only data).
- Port: **7020** (7012/7013/8765 are taken by other services in this household).
- Repo name stays `studio-cli` for now; the tool is `tailmon`.

## Binary & subcommands

Go module `github.com/barathanaslan/studio-cli`. One binary:

- `tailmon` — the TUI viewer (default subcommand).
- `tailmon agent` — HTTP agent serving local stats. Flags: `--port` (default 7020).
- `tailmon sample` — print ONE local stats snapshot as JSON to stdout and exit (no server).
  This is the primary test/debug path and works over bare ssh with zero setup.
- `tailmon json` — aggregate: discover peers, query every reachable agent (+ local sample
  in-process even if no local agent runs), print one combined JSON document. For AI tools.
- `tailmon version`.

## Repo restructure (on `main`)

- DELETE from main: `src/`, `tests/` (python), `deploy/` (python-era), `pyproject.toml`,
  `uv.lock`, `.python-version`, `.coverage`, `.ruff_cache`. (All preserved on `v1-python`.)
- KEEP: `menubar/` untouched — add a one-paragraph `menubar/STATUS.md` saying it targets the
  v1 API and will be reworked in a later phase.
- NEW layout:
  ```
  cmd/tailmon/main.go
  internal/sample/      sampler interface + darwin.go / windows.go / linux.go (+ gpu_*.go)
  internal/agent/       http server, single-flight sample cache (1s TTL)
  internal/discover/    tailscale peer discovery
  internal/aggregate/   fan-out client used by `json` and the TUI
  internal/tui/         bubbletea app
  deploy/               launchd plist + install-macos.sh + install-windows.ps1 + README.md
  docs/                 rewrite architecture.md for v2; keep docs/plans/, docs/progress.md (append)
  build.sh              cross-compile darwin/arm64, windows/amd64, linux/amd64 into dist/
  ```
- Rewrite `README.md` for v2 (what it is, install per OS, subcommands, JSON examples).
- New `.gitignore`: Go-oriented (`dist/`, binary names) + keep `.DS_Store` etc.

## Stats schema (`/stats` and `sample` output — one struct, versioned `"schema": 1`)

```json
{
  "schema": 1, "host": "barathans-macstudio", "os": "darwin", "arch": "arm64",
  "sampled_at": "RFC3339", "uptime_sec": 12345,
  "cpu": {"percent": 12.3, "cores": 24, "load1": 1.2},
  "mem": {"total_mb": 98304, "used_mb": 41200, "available_mb": 57104, "pressure": "normal", "swap_used_mb": 0},
  "gpu": [{"name": "Apple M3 Ultra", "util_pct": 7, "vram_used_mb": null, "vram_total_mb": null, "temp_c": null}],
  "disks": [{"mount": "/", "free_gb": 512, "total_gb": 994}],
  "net": {"rx_bytes": 0, "tx_bytes": 0},
  "top_procs": [{"pid": 1, "name": "python3", "cpu_pct": 88.1, "mem_mb": 4096}],
  "agent": {"version": "0.2.0", "rss_mb": 9.4, "goroutines": 8, "uptime_sec": 3600}
}
```
`agent` self-stats are mandatory — the monitor must monitor itself (leak trauma, see Context).
Fields that a platform can't provide are `null`, never fabricated. Unified-memory Macs:
`vram_* = null`, GPU util still real.

## Data sources

- CPU / mem / swap / disks / net counters / top processes / uptime:
  `github.com/shirou/gopsutil/v4` everywhere (pure Go, no cgo needed for these).
- **macOS memory**: report `used = total - available` (matches Activity Monitor's sense of
  "used"); pressure level from `memory_pressure -Q` (parse "System-wide memory free
  percentage" → normal/warn/critical buckets; skip if command missing). This solves the
  known "Claude sees only 2GB used when it's really 8GB" problem — document in README.
- **macOS GPU (Apple Silicon, no root)**: `ioreg -r -d 1 -c IOAccelerator` (or `-w0`), parse
  `"PerformanceStatistics"` dict, key `"Device Utilization %"`. This works WITHOUT root —
  do NOT use powermetrics. If the key is absent, `util_pct: null`.
- **Windows GPU**: `nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits`.
  Try PATH first, then `C:\Windows\System32\nvidia-smi.exe` and
  `C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe`.
- **Linux GPU**: nvidia-smi if present, else no gpu entry. (Covers possible future boxes; WSL
  is NOT a target — the Windows agent runs native and sees the real host.)
- ALL exec.Command calls: `context.WithTimeout` (2s), never inherit stdin, reap properly.

## Anti-leak / efficiency requirements (the heart of this project)

1. Agent samples ON DEMAND only. GET /stats triggers a sample; concurrent requests within
   1s share one result (single-flight + timestamp check). No background tickers, no history
   buffers in the agent. Idle agent = 0% CPU, flat RSS.
2. No unbounded data structures anywhere. The TUI keeps sparkline history in FIXED arrays
   (ring buffer, 120 slots per host, allocated once).
3. `/health` (unauthenticated-trivial, same bind) returns the `agent` self-stats block.
4. Soak test (`internal/agent/soak_test.go`): start agent in-process, hit /stats 5,000
   times, assert RSS growth < 10 MB and goroutine count returns to baseline. Must be in
   the default `go test ./...` run.
5. TUI probes offline hosts with backoff (10s), 800ms request timeouts, never stacks
   retries. Quitting the TUI must not leave goroutines/processes behind.
6. Build with `-trimpath -ldflags "-s -w"`.

## TUI spec (bubbletea + lipgloss)

- One card/row per host: name, OS badge, CPU% (bar), RAM used/total (bar + pressure color),
  GPU util + VRAM when present, disk free on main volume, uptime, and the remote agent's
  own rss_mb in dim text. Sparkline for CPU and RAM per host.
- Host discovery: run `tailscale status --json` (path fallbacks:
  `/Applications/Tailscale.app/Contents/MacOS/Tailscale` on macOS, `tailscale` in PATH),
  take Self + Peers, mark Online flag. Probe :7020 on online hosts. States: `live` (agent
  answered), `no agent` (online, port closed — dim, with hint), `offline` (grey).
- The CUDA box gets a special affordance: when offline and a local `~/bin/cuda` exists,
  show "[w]ake"; pressing `w` runs `~/bin/cuda on` async and shows progress; when live,
  show "[s]hutdown" only behind a confirm prompt, running `~/bin/cuda off` (which
  self-guards against killing training runs).
- Keys: `q` quit, `p` pause, `r` refresh now, `j/k` select, `w` wake, `s` shutdown (confirm).
- Refresh every 2s (only queries `live` + probes `no agent` hosts on the backoff cadence).
- Must degrade gracefully when `tailscale` CLI is missing: monitor localhost only.

## Deploy

- `deploy/com.bosphorify.tailmon.plist`: user LaunchAgent (NOT root, NOT LaunchDaemon),
  RunAtLoad + KeepAlive, runs `~/bin/tailmon agent`, logs to
  `~/Library/Logs/tailmon-agent.log`. `deploy/install-macos.sh` copies the built binary to
  `~/bin/tailmon`, installs + loads the plist. Uninstall script too.
- `deploy/install-windows.ps1`: to be RUN ONCE AS ADMIN by the owner on the PC — copies
  `tailmon.exe` to `C:\Tools\tailmon\`, registers a Task Scheduler ONSTART task running as
  SYSTEM (`schtasks /create /sc onstart /ru SYSTEM /tn tailmon-agent /tr "C:\Tools\tailmon\tailmon.exe agent"`),
  starts it. The installing agent must NOT try to run this (no admin over ssh) — document it.
- `deploy/README.md` explains all three machines, incl. "MacBook: git pull, ./build.sh,
  ./deploy/install-macos.sh".

## Verification (do all of this)

1. `go vet ./...` and `go test ./...` green, including the soak test.
2. Local: `tailmon sample | jq .` sane on the Studio (real CPU/mem/GPU util numbers; GPU
   util from ioreg present).
3. Run `tailmon agent` on the Studio (foreground is fine), then `tailmon json | jq .` and
   confirm the Studio appears with live data.
4. Windows, end-to-end (the CUDA box is usually OFF — this also exercises the wake path):
   - `~/bin/cuda on` (waits for boot, ~40s).
   - `./build.sh`, then `scp dist/tailmon-windows-amd64.exe barat@100.95.91.27:tailmon.exe`
   - `ssh barat@100.95.91.27 "tailmon.exe sample"` → verify JSON: real RAM, CPU, and the
     RTX 5070 Ti GPU block with VRAM numbers.
   - Do NOT install the Windows service (needs admin) — just verify `sample` works and
     leave `tailmon.exe` in the home dir; the ps1 handles the rest when the owner runs it.
   - `~/bin/cuda off` when done (it refuses if the GPU is busy — that's fine, then leave it on).
5. Install the launchd agent on the Studio via `deploy/install-macos.sh`; confirm
   `curl -s http://100.80.21.79:7020/stats | jq .agent` works from the Studio itself.
6. Append a dated progress entry to `docs/progress.md`.

## Hard constraints

- NOTHING on the Windows box may be modified beyond: dropping `tailmon.exe` in the home
  dir. Do not touch anything under WSL, `trendyol*`, `ft`, `judge`, or E:\ — an active ML
  competition lives there.
- Do not push to GitHub — commit locally in clear increments; the owner reviews then pushes.
- Do not modify `~/Projects/Trendyol2026` on this Mac.
- Keep dependencies minimal: gopsutil, bubbletea/lipgloss (+ its deps), stdlib. No web
  frameworks, no ORMs, nothing else without strong reason.
