# Deploying the tailmon agent

One binary per machine. The agent binds only to the machine's Tailscale IP +
127.0.0.1 on port **7020** — no tokens, no root; tailnet membership is the
security perimeter (monitor-only, read-only data).

## macOS

```sh
./build.sh                  # cross-compiles into dist/
./deploy/install-macos.sh   # ~/bin/tailmon + user LaunchAgent, no sudo
```

The agent runs as a **user LaunchAgent** (`com.bosphorify.tailmon`), RunAtLoad
+ KeepAlive, logging to `~/Library/Logs/tailmon-agent.log`. Verify:

```sh
curl -s http://127.0.0.1:7020/health | jq .
curl -s http://<tailscale-ip>:7020/stats | jq .cpu,.mem
```

Remove with `./deploy/uninstall-macos.sh`.

For the menu bar app, see [`menubar/`](../menubar) (`cd menubar && ./install.sh`).

## Windows

1. Get `tailmon.exe` onto the box — either build there (`go build -o
   tailmon.exe ./cmd/tailmon`) or cross-compile elsewhere (`./build.sh`) and
   copy `dist/tailmon-windows-amd64.exe` over (scp lands fine in
   `%USERPROFILE%`).

2. Run `deploy\install-windows.ps1` **in an elevated PowerShell** (locally,
   or over ssh if your ssh sessions carry an admin token). It copies the exe
   to `C:\Tools\tailmon\`, registers a Task Scheduler ONSTART task running as
   SYSTEM, and starts it.

   Keep the script ASCII-only — PowerShell 5.1 reads BOM-less UTF-8 as ANSI
   and a stray em-dash breaks parsing.

Quick test without installing anything: `tailmon.exe sample` prints one JSON
snapshot and exits.

## Linux

`./build.sh` produces `dist/tailmon-linux-amd64`; run `tailmon agent` under
systemd or your supervisor of choice (no unit file shipped yet).

## Sanity checks from anywhere on the tailnet

```sh
tailmon json | jq '.hosts[] | {host, status}'
curl -s http://<any-agent-ip>:7020/stats | jq .agent   # the agent watches itself
```
