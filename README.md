# tailmon

Tailnet-wide resource monitor. One small Go binary: every machine on the
tailnet is both a stats source and a viewer. From any machine you can see the
live CPU / RAM / GPU / disk usage of that machine **and** every online tailnet
peer — in a TUI for humans, or as one JSON document for AI tools.

(Formerly `studio-cli` — renamed 2026-07-11; GitHub redirects the old URL.
The v1 Python collector/CLI/menubar stack lives on the `v1-python` branch.)

## Tailmon.app — the menu bar monitor (macOS)

`menubar/` is a SwiftUI menu bar app on top of the same agents — the Stats.app
replacement. The menu bar label shows the local machine's live **CPU / GPU /
RAM percentages** (Stats-style stacked columns, tightly packed; RAM tinted by
memory pressure) plus **one letter per other tailnet device** colored by
status — green live, orange no-agent, dim offline (letters learned on the
first menu open, then persisted). The dropdown shows every live fleet host as
a card of labelled bars with their numbers inside (CPU, RAM + swap, GPU
utilization joined with its memory, every disk), network and disk rates, and
a **top-processes list per host** ("what is actually running"); offline hosts
are one compact line at the bottom. A disk that drops out of a live host's
report (an external drive asleep or disabled) keeps showing with its last
reading. A device only joins the fleet once it has answered with a live
agent; tailnet nodes that never ran tailmon (phones, other people's machines)
are not shown at all. Strictly read-only: no power controls, no kill — by design.

Efficiency contract: menu closed → the label's numbers are read natively
every 5s (a few Mach/sysctl calls and one IORegistry read: **no HTTP, no
subprocesses, no process scans**), plus one tiny /health probe per known peer
every 60s. Menu open → one `GET 127.0.0.1:7020/fleet?top=10` every 2s, one in
flight max; the local agent fans out and caches. No history kept (one previous
counter snapshot per host for rates); log capped at 1 MB.

```
cd menubar && ./install.sh     # builds Tailmon.app, installs to /Applications
```
Launch-at-login is registered automatically on first launch; toggle it from
the dropdown's `⋯` menu (Girişte başlat). The app never re-forces it. Needs
macOS 14+ and a v0.3.0 agent on the same Mac (for `/fleet`).

## Design rules

- **Bounded memory, near-zero idle footprint.** v1 once leaked memory on a
  MacBook for ~10 days; never again. The agent samples **on demand only** — no
  background tickers, no history buffers. Concurrent requests within 1s share
  a single sample. The TUI keeps sparkline history in fixed 120-slot ring
  buffers. A soak test (5,000 requests, RSS growth must stay under 10 MB) runs
  in the default `go test ./...`.
- **The monitor monitors itself.** Every response carries an `agent` block
  with the agent's own RSS, goroutine count, and uptime.
- **No root, no tokens.** The agent binds only to the machine's Tailscale IP
  and 127.0.0.1 on port **7020**; tailnet membership is the security perimeter
  (monitor-only, read-only data).

## Requirements & install

Clone-and-build; no prebuilt binaries (yet). You need:

- **Go 1.22+** (agent, TUI, CLI — all platforms)
- **[Tailscale](https://tailscale.com)** with the `tailscale` CLI available
  (peer discovery; without it tailmon monitors localhost only)
- **Swift toolchain** (macOS only, optional — just for the menu bar app)

```sh
git clone https://github.com/barathanaslan/tailmon && cd tailmon
./build.sh                        # dist/ binaries for darwin/windows/linux
./deploy/install-macos.sh         # macOS: agent as a user LaunchAgent
cd menubar && ./install.sh        # macOS, optional: Tailmon.app menu bar UI
```

Windows and Linux: see [deploy/README.md](deploy/README.md). Go users can
also grab just the CLI with
`go install github.com/barathanaslan/tailmon/cmd/tailmon@latest`.
Run `tailmon agent` on every machine you want visible, then `tailmon` (TUI)
or `tailmon json` from anywhere. MIT licensed.

## Subcommands

```
tailmon              TUI: cards for this machine + every tailnet peer
tailmon agent        HTTP agent on :7020 (--port to override)
tailmon sample       one local stats snapshot as JSON to stdout, then exit
tailmon json         combined JSON for the whole tailnet (for AI tools)
tailmon version
```

`tailmon sample` is the zero-setup debug path — it works over bare ssh:

```sh
ssh user@some-windows-box "tailmon.exe sample"
```

## TUI

One card per host: CPU bar, RAM bar with memory-pressure color, GPU util (+
VRAM/temp on NVIDIA), disk free, uptime, the remote agent's own RSS, and CPU/
RAM sparklines. Hosts are `live` (agent answered), `no agent` (online, :7020
closed), or `offline`. Keys: `q` quit · `p` pause · `r` refresh · `j/k`
select. Deliberately no power controls — tailmon observes machines, it never
changes their state. Without the `tailscale` CLI it degrades to monitoring
localhost only.

## JSON

`GET http://<host>:7020/stats` and `tailmon sample` print schema 1
(`?top=N` for up to 25 processes; `?lite=1` skips process enumeration):

```json
{
  "schema": 1, "host": "barathans-macstudio", "os": "darwin", "arch": "arm64",
  "sampled_at": "2026-07-10T18:00:00Z", "uptime_sec": 773619,
  "cpu": {"percent": 4.6, "cores": 28, "load1": 5.1},
  "mem": {"total_mb": 98304, "used_mb": 17102, "available_mb": 81201,
          "pressure": "normal", "swap_used_mb": 2460},
  "gpu": [{"name": "Apple M3 Ultra", "util_pct": 7, "vram_used_mb": 690,
           "vram_total_mb": null, "temp_c": null, "unified": true}],
  "disks": [{"mount": "/", "free_gb": 209.4, "total_gb": 926.4, "used_gb": 717.0,
             "label": "HD", "fstype": "apfs", "kind": "internal"}],
  "net": {"rx_bytes": 211981786521, "tx_bytes": 55753167396},
  "disk_io": {"read_bytes": 3947653914624, "write_bytes": 3106902585344},
  "top_procs": [{"pid": 4242, "name": "python3", "cpu_pct": 88.1, "mem_mb": 4096}],
  "agent": {"version": "0.3.0", "rss_mb": 9.4, "goroutines": 8, "uptime_sec": 3600}
}
```

Fields a platform can't provide are `null` or omitted, never fabricated
(`load1` on Windows, `vram_total_mb` on unified-memory Macs, where
`vram_used_mb` is the GPU's in-use share of system memory; `pressure` outside
macOS). NVIDIA GPUs add `power_w`, `power_limit_w`, `fan_pct`. Disks: macOS
reports the root as `/` labelled `HD` (usage of the Data volume) plus every
real volume under `/Volumes`; Windows every fixed/removable drive letter;
Linux every real filesystem. `kind` is internal / external / removable.
Free-space queries only — directories are never walked. All 0.3.0 fields are
additive; schema stays 1.

**macOS memory note:** `used_mb` is `total - available` — the same sense of
"used" as Activity Monitor. Naive `free`-style numbers on macOS wildly
underreport (file cache etc.); this schema avoids the classic "the tool says
2 GB used when the machine is really at 8 GB" misread. `pressure` buckets
`kern.memorystatus_level` (the free percentage `memory_pressure -Q` prints)
into normal / warn / critical.

GPU utilization on Apple Silicon comes from the IOAccelerator registry
(`ioreg`), which needs **no root** — unlike `powermetrics`. NVIDIA data comes
from `nvidia-smi` (PATH, then the usual install locations).

`tailmon json` wraps per-host stats in:

```json
{
  "schema": 1, "generated_at": "…",
  "hosts": [
    {"host": "barathans-macstudio", "ip": "100.80.21.79", "os": "macOS",
     "status": "live", "source": "local", "stats": { … }},
    {"host": "barathans-5070", "ip": "100.95.91.27", "os": "windows",
     "status": "offline", "stats": null}
  ]
}
```

The local machine is sampled in-process, so it appears even when no local
agent is running. The agent serves the same document at `GET /fleet?top=N`
to **loopback clients only** (403 otherwise) — that is what the menu bar app
reads.

## Install

```sh
./build.sh                  # dist/ binaries for darwin/arm64, windows/amd64, linux/amd64
./deploy/install-macos.sh   # user LaunchAgent (no sudo) on a Mac
```

Windows and fleet details: [deploy/README.md](deploy/README.md).
Architecture: [docs/architecture.md](docs/architecture.md).
