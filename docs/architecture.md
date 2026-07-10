# Architecture (v2 — tailmon)

## Shape

One Go binary, `tailmon` (module `github.com/barathanaslan/studio-cli`),
running in two roles on every fleet machine:

```
┌────────────────────┐        ┌──────────────────────┐
│ any machine        │        │ each tailnet machine │
│  tailmon (TUI)     │ HTTP   │  tailmon agent :7020 │
│  tailmon json ─────┼───────▶│  GET /stats /health  │
│  (+ local sample   │        │  binds Tailscale IP  │
│    in-process)     │        │  + 127.0.0.1 only    │
└────────────────────┘        └──────────────────────┘
```

Packages:

| Path | Role |
|---|---|
| `cmd/tailmon` | subcommand dispatch: TUI (default), `agent`, `sample`, `json`, `version` |
| `internal/sample` | one bounded snapshot of the local machine (platform files per OS) |
| `internal/agent` | HTTP server + single-flight 1s sample cache; soak test lives here |
| `internal/discover` | `tailscale status --json` → Self + agent-capable peers |
| `internal/aggregate` | parallel fan-out client used by `tailmon json` and the TUI |
| `internal/tui` | bubbletea/lipgloss viewer |
| `deploy/` | launchd plist + install scripts (macOS user agent, Windows schtasks) |

## Security model

No root, no bearer tokens. The agent binds **only** to the machine's Tailscale
CGNAT address(es) and 127.0.0.1. Tailnet membership is the perimeter; the data
is monitor-only and read-only. (v1 ran a root FastAPI daemon with token auth —
v2 deliberately needs neither: `ioreg` provides GPU stats unprivileged.)

## Anti-leak requirements (why v2 exists)

v1 leaked memory on a MacBook for about ten days. v2's hard rules:

1. The agent samples **on demand** only. `GET /stats` triggers a sample;
   requests within 1s share one result via a single-flight cache
   (`internal/agent/cache.go`). No tickers, no history in the agent. Idle
   agent = 0% CPU, flat RSS.
2. No unbounded data structures. TUI sparkline history is a fixed
   120-slot ring buffer per host, allocated once.
3. `/health` returns the agent's self-stats (`rss_mb`, `goroutines`,
   `uptime_sec`) and the same block rides along in every `/stats` response.
4. `internal/agent/soak_test.go` hammers /stats 5,000 times in-process and
   fails the build if RSS grows ≥10 MB or goroutines don't return to
   baseline. Part of plain `go test ./...`.
5. The TUI probes agentless hosts on a 10s backoff, uses 800ms request
   timeouts, and holds a per-host in-flight guard so retries never stack.
   Quit cancels the program context, which kills any spawned `cuda on/off`.
6. Binaries built `-trimpath -ldflags "-s -w"`, `CGO_ENABLED=0`.

## Data sources

- CPU / mem / swap / disks / net counters / processes / uptime:
  `gopsutil/v4`, pure Go on all three OSes.
- System CPU% and per-process CPU% share one 500 ms measurement window per
  sample (prime → sleep → read deltas), so a sample costs ~0.5-1 s wall and
  nothing when nobody asks.
- macOS memory: `used = total − available` (Activity Monitor semantics);
  pressure from `memory_pressure -Q` free-percentage buckets (>20 normal,
  10-20 warn, <10 critical).
- macOS GPU: `ioreg -r -d 1 -c IOAccelerator` → `PerformanceStatistics` →
  `"Device Utilization %"`. No root. Absent key → `util_pct: null`.
  Unified memory → `vram_*: null`. GPU name from
  `sysctl machdep.cpu.brand_string`.
- Windows GPU: `nvidia-smi --query-gpu=… --format=csv,noheader,nounits`,
  trying PATH, then `C:\Windows\System32`, then the NVSMI folder.
- Linux GPU: `nvidia-smi` from PATH if present. WSL is not a target — the
  Windows agent runs native and sees the real host.
- Every subprocess: 2 s `context.WithTimeout`, stdin from the null device,
  reaped by `cmd.Run`/`Output`.

## Discovery & degradation

`tailscale status --json` (PATH, falling back to the macOS app-bundle binary).
Self + peers filtered to OSes that could run an agent (macOS/windows/linux —
phones and OS-less shared-in devices are skipped). Peers marked
live / no-agent / offline by Online flag + a :7020 probe. If the tailscale CLI
is missing entirely, `tailmon` monitors localhost only (local sampling is
in-process and never depends on the agent or tailscale).

## The CUDA box affordance

`barathans-5070` (Windows, RTX 5070 Ti) is usually powered off. When the TUI's
selected host is an offline Windows machine and `~/bin/cuda` exists locally,
`w` runs `cuda on` (WoL + poll) asynchronously; `s` behind a y/N confirm runs
`cuda off`, which itself refuses to shut down a busy GPU.

## Ports

7020. (7012 voice-recorder UI, 7013 whisper-service, 8765 v1 studiod are taken
in this household.)
