# Architecture (v0.3.0 — tailmon)

## Shape

One Go binary, `tailmon` (module `github.com/barathanaslan/studio-cli`),
running in two roles on every fleet machine:

```
┌────────────────────┐        ┌──────────────────────┐
│ any machine        │        │ each tailnet machine │
│  tailmon (TUI)     │ HTTP   │  tailmon agent :7020 │
│  tailmon json ─────┼───────▶│  GET /stats /health  │
│                    │        │  GET /fleet (loopback│
│                    │        │   only; fans out)    │
│  (+ local sample   │        │  binds Tailscale IP  │
│    in-process)     │        │  + 127.0.0.1 only    │
└────────────────────┘        └──────────────────────┘
```

Packages:

| Path | Role |
|---|---|
| `cmd/tailmon` | subcommand dispatch: TUI (default), `agent`, `sample`, `json`, `version` |
| `internal/sample` | one bounded snapshot of the local machine (platform files per OS) |
| `internal/agent` | HTTP server, single-flight 1s caches (full, lite, fleet; 10s discovery); soak test lives here |
| `internal/port` | the agent port (7020), shared by agent and aggregate |
| `internal/discover` | `tailscale status --json` → Self + agent-capable peers |
| `internal/aggregate` | parallel fan-out used by `tailmon json`, the TUI and the agent's `/fleet` |
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
   (`internal/agent/cache.go`, one slot each for full sample, lite sample,
   fleet report; discovery is cached 10s). No tickers, no history in the
   agent — only ONE previous CPU counter reading (lite CPU% delta). Idle
   agent = 0% CPU, flat RSS. The agent runs at lowered priority (nice +10 /
   BELOW_NORMAL_PRIORITY_CLASS) so it never competes with training.
2. No unbounded data structures. TUI sparkline history is a fixed
   120-slot ring buffer per host, allocated once.
3. `/health` returns the agent's self-stats (`rss_mb`, `goroutines`,
   `uptime_sec`) and the same block rides along in every `/stats` response.
4. `internal/agent/soak_test.go` hammers /stats, /stats?lite=1 and /fleet
   (fanning out to a second in-process agent) 5,000 times each and
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
  full sample (prime → sleep → read deltas), so a sample costs ~0.5-1 s wall
  and nothing when nobody asks. A lite sample (`?lite=1`) enumerates no
  processes: CPU% is the delta against the previous reading if it is
  0.2-60 s old, else a 250 ms window.
- macOS memory: `used = total − available` (Activity Monitor semantics);
  pressure from the `kern.memorystatus_level` sysctl (free %, the number
  `memory_pressure -Q` prints) bucketed >20 normal, 10-20 warn, <10 critical.
- macOS GPU: `ioreg -r -d 1 -c IOAccelerator` → `PerformanceStatistics` →
  `"Device Utilization %"` and `"In use system memory"`. No root. Absent key
  → `util_pct: null`. Unified memory → `vram_used_mb` = in-use system
  memory, `vram_total_mb: null`, `unified: true`. GPU name from the
  `machdep.cpu.brand_string` sysctl, read once. `ioreg` is the only
  subprocess a macOS sample spawns.
- macOS disks: `getfsstat(MNT_NOWAIT)` (the kernel's cached mount table —
  never blocks on a hung network mount) + `statfs` per real local volume.
- Disk I/O: gopsutil `disk.IOCounters` summed over physical disks
  (`disk_io`, cumulative; clients compute rates).
- Windows GPU: `nvidia-smi --query-gpu=…,power.draw,power.limit,fan.speed
  --format=csv,noheader,nounits`, trying PATH, then `C:\Windows\System32`,
  then the NVSMI folder.
- Windows disks: every drive letter (fixed + removable) via GetDriveType,
  GetVolumeInformation (label, format), GetDiskFreeSpaceEx; a fixed drive on
  the USB bus (IOCTL_STORAGE_QUERY_PROPERTY) is `external`.
- Linux GPU: `nvidia-smi` from PATH if present. WSL is not a target — the
  Windows agent runs native and sees the real host.
- Every subprocess: 2 s `context.WithTimeout`, stdin from the null device,
  reaped by `cmd.Run`/`Output`.

## Menu bar app (menubar/)

- Label: native every 5s — `host_statistics` CPU tick deltas,
  `host_statistics64` free+inactive pages (same "available" as gopsutil, so
  label == dropdown), `kern.memorystatus_level`, IOAccelerator
  `PerformanceStatistics`. Peer letters: `/health` every 60s.
- Dropdown: `GET 127.0.0.1:7020/fleet?top=10` every 2s while open, one in
  flight. Rates from one previous counter snapshot per host. Last reading of
  every non-removable disk persisted per host (UserDefaults, pruned after 30
  days unseen) so a sleeping/disabled drive still shows.
- The window is sized to the content synchronously in the layout pass
  (`WindowHeightFitter`), with animations off, so toggling processes never
  draws a wrong-size frame.

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
