# Deploying the tailmon agent

Three machines, one binary each. The agent binds only to the machine's
Tailscale IP + 127.0.0.1 on port **7020** — no tokens, no root; tailnet
membership is the security perimeter (monitor-only, read-only data).

| Host | IP | OS | How |
|---|---|---|---|
| barathans-macstudio | 100.80.21.79 | macOS | `./build.sh && ./deploy/install-macos.sh` |
| barathans-5070 | 100.95.91.27 | Windows 11 | see below — needs one manual admin step |
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

2. **On the PC, by the owner, once**: open an **Administrator** PowerShell and run
   `deploy\install-windows.ps1` (copy it over, or paste it). It copies
   `tailmon.exe` to `C:\Tools\tailmon\` and registers a Task Scheduler ONSTART
   task running as SYSTEM, then starts it.

   Registering the service **cannot be done over ssh** — ssh sessions are not
   elevated. Until the owner runs the script, `ssh barat@100.95.91.27
   "tailmon.exe sample"` still works for one-shot checks.

## Sanity checks from anywhere on the tailnet

```sh
tailmon json | jq '.hosts[] | {host, status}'
curl -s http://100.80.21.79:7020/stats | jq .agent   # the agent watches itself
```
