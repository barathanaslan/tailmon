# Maintainer's fleet notes (personal)

Not part of the generic docs — this records the maintainer's own deployment.

| Host | IP | OS | State |
|---|---|---|---|
| barathans-macstudio | 100.80.21.79 | macOS (M3 Ultra) | LaunchAgent + Tailmon.app, always on |
| barathans-5070 | 100.95.91.27 | Windows 11 (RTX 5070 Ti) | SYSTEM task `tailmon-agent` (2026-07-10); usually powered off — wake via `~/bin/cuda on` |
| barathans-macbook-1 | 100.80.159.96 | macOS | LaunchAgent + Tailmon.app |

Quirks specific to this fleet:

- The Windows box's ssh sessions carry a full Administrator token (key in
  `administrators_authorized_keys`), so `install-windows.ps1` can be run
  remotely: `scp deploy/install-windows.ps1 barat@100.95.91.27:` then
  `ssh barat@100.95.91.27 "powershell -ExecutionPolicy Bypass -File install-windows.ps1"`.
- Power control of the Windows box lives OUTSIDE tailmon by owner rule:
  `cuda on` / `cuda off` (see the cuda-box skill / ~/bin/CUDA-README.md in
  the ClaudeSetup repo). tailmon never touches power.
- Updating the Windows agent binary:
  `scp dist/tailmon-windows-amd64.exe barat@100.95.91.27:tailmon.exe` then
  `ssh barat@100.95.91.27 "schtasks /end /tn tailmon-agent & copy /y tailmon.exe C:\Tools\tailmon\tailmon.exe & schtasks /run /tn tailmon-agent"`.
