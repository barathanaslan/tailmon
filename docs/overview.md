# studio-cli

A unified tool for monitoring and controlling a Mac Studio used as a headless server, from a MacBook over Tailscale.

## Problem

The Mac Studio is used as a shared headless server:

- Accessed via SSH over Tailscale from multiple devices (MacBook, phone)
- Shared with friends for hosting (via Tailscale device sharing, no dedicated user accounts)
- Hosts a growing number of services on various ports (SSH, Whisper transcription, others forgotten over time)
- Runs with Stats.app locally for CPU/GPU/power monitoring, but those numbers aren't visible remotely

As the number of hosted services, active SSH sessions, and background processes grows, visibility from the MacBook becomes essential. The current `studio` zsh function (see `~/.zshrc:95-140`) only handles tmux session attach/create — nothing else.

## Goal

One project that provides, from the MacBook:

1. **Visibility**: CPU / GPU / memory / power usage, listening ports with owning processes, active SSH sessions (labeled by Tailscale peer when possible), top processes
2. **Control**: kill processes, kick SSH sessions, attach/create tmux sessions
3. **Ambient access**: lives in the macOS menubar, one click to open, live-updating

The existing `studio` command is folded into this project as a subcommand, so there's a single source of truth for "how I talk to my Mac Studio."

## Non-goals

- Multi-host: this tool monitors exactly one Mac Studio, not a fleet
- Historical metrics / long-term storage: live state only
- Public internet exposure: the collector is bound to loopback + Tailscale interface only
- Web dashboard: rejected in favor of native menubar app for keyboard-driven workflow
