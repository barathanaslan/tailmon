# Tailmon v0.2.0 → v0.3.0 resource measurements (Mac mini, 2026-11-07)

Same machine (Mac mini, M6, 32 GB, macOS 27), same fleet state (box and
MacBook offline, tahalinux live with a v0.2.0-compatible agent). CPU time is
from `ps -o time`; it includes every client of the local agent, not only the
menu bar app (e.g. the website status reporter LaunchAgent).

## Menu closed, 10 minutes

| | v0.2.0 | v0.3.0 |
|---|---|---|
| Agent CPU / 10 min | 9.00 s (515:21.67 → 515:30.67) | 0.57 s (0:04.03 → 0:04.60) |
| Tailmon.app CPU / 10 min | 7.01 s (252:13.14 → 252:20.15) | 1.57 s (0:00.17 → 0:01.74) |
| Combined | 16.0 s (≈ 2.7 % of one core) | 2.1 s (−87 %) |
| Agent RSS | 20.8 MB | 23.5 MB |
| Tailmon.app RSS | 60–62 MB | 88.7 MB (phys_footprint 19 MB) |
| What runs | full agent sample (process scan + 500 ms window + 3 subprocesses) every 15 s for the label, + peer /health | label read natively every 5 s (Mach/sysctl/IORegistry, no HTTP), peer /health every 60 s |

The v0.2.0 agent had accumulated 515 CPU-minutes over ~23 days of uptime,
almost all of it from the label's 15 s full samples.

App RSS is higher after the change (RSS counts shared system frameworks:
IOKit and the new SwiftUI views); the app's own footprint
(`footprint -p`) is 19 MB. No v0.2.0 footprint number was taken.

## Menu open

| | v0.2.0 | v0.3.0 |
|---|---|---|
| Poll | `tailmon json --top 10` subprocess every 3 s | `GET /fleet?top=10` (URLSession) every 2 s |
| Client cost per poll | 0.07 s user+sys, 45 MB max RSS (median of 20 runs; spawns `tailscale status` each time) | ~0 (in-app HTTP request) |
| Agent cost per poll | 0.041 s (20 samples: 515:32.32 → 515:33.14) | 0.047 s (15 polls 2 s apart: 0:04.90 → 0:05.60; full sample + peer fan-out; discovery cached 30 s) |
| CPU per second while open | ≈ 0.037 s/s | ≈ 0.023 s/s, despite polling 1.5× as often |
| Wall time per poll | 2.56 s median (max 3.15) | 0.010 s median when served from the 1 s cache, 0.79 s max cold |

## Subprocesses per agent sample (macOS)

| | v0.2.0 | v0.3.0 |
|---|---|---|
| Per `/stats` sample | 3: `ioreg`, `sysctl -n machdep.cpu.brand_string`, `memory_pressure -Q` | 1: `ioreg` (GPU name via sysctl syscall once; pressure via `kern.memorystatus_level`) |
| Per menu-open poll, app side | 2: `tailmon json` + its `tailscale status --json` | 0 (the agent runs `tailscale status` at most once per 30 s) |
| Menu closed, app side | 0 | 0 |

Counts are from the code paths (no root tracing on this machine).
