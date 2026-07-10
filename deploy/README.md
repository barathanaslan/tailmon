# Deploying the tailmon agent

Three machines, one binary each. The agent binds only to the machine's
Tailscale IP + 127.0.0.1 on port **7020** — no tokens, no root; tailnet
membership is the security perimeter (monitor-only, read-only data).

| Host | IP | OS | How |
|---|---|---|---|
| barathans-macstudio | 100.80.21.79 | macOS | `./build.sh && ./deploy/install-macos.sh` |
| barathans-5070 | 100.95.91.27 | Windows 11 | installed 2026-07-10 (SYSTEM task `tailmon-agent`) |
| barathans-macbook-1 | 100.80.159.96 | macOS | `git pull`, `./build.sh`, `./deploy/install-macos.sh` |

## macOS (Studio and MacBook)

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

## Windows (barathans-5070)

Two steps, split on purpose:

1. **From the Mac** (this much can be done over ssh — and nothing more):

   ```sh
   ~/bin/cuda on   # wake the box if it's off
   ./build.sh
   scp dist/tailmon-windows-amd64.exe barat@100.95.91.27:tailmon.exe
   ```

2. **Run `install-windows.ps1` in an elevated context.** On THIS box, ssh
   sessions as `barat` carry a full Administrator token (the key lives in
   `administrators_authorized_keys`), so the install was done remotely:
   `scp deploy/install-windows.ps1 barat@100.95.91.27:` then
   `ssh barat@100.95.91.27 "powershell -ExecutionPolicy Bypass -File install-windows.ps1"`.
   On a box without elevated ssh, run it once in an admin PowerShell locally.
   Keep the script ASCII-only — PowerShell 5.1 reads BOM-less UTF-8 as ANSI and
   a stray em-dash breaks parsing.

## Sanity checks from anywhere on the tailnet

```sh
tailmon json | jq '.hosts[] | {host, status}'
curl -s http://100.80.21.79:7020/stats | jq .agent   # the agent watches itself
```
