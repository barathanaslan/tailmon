# Progress

## Current phase

**v2 tailmon MVP shipped and verified live (2026-07-10)** — see the dated entry at the bottom of this file. Everything between here and that entry is v1 (Python) history; the v1 stack itself is archived on the `v1-python` branch and is no longer on `main`.

## Status

- [x] Phase 1: collector daemon with read endpoints
- [x] Phase 2a: CLI package + deploy scripts (offline)
- [x] Phase 2b: interactive deploy of collector + CLI to Mac Studio
- [x] Phase 2.5: polish pass (B1, B2, B3, B4, B7) -- offline; awaiting Studio deploy
- [x] Phase 3: control endpoints (B8-B12) -- offline; awaiting Studio deploy
- [x] Phase 4: SwiftUI menubar app (B13) -- offline; awaiting human install + live verification

## Decisions log

- **2026-04-15**: Menubar app chosen over CLI-only or web dashboard. Going directly to SwiftUI (not SwiftBar) to avoid throwaway work — user prefers more effort for a better result.
- **2026-04-15**: Collector runs as root (system launchd daemon) to access `powermetrics` for GPU/power stats. Mitigated by Tailscale-only binding, bearer-token auth, minimal dependency surface.
- **2026-04-15**: One repo, one project. The existing `studio` zsh function at `~/.zshrc:95-140` gets absorbed into the Python CLI package, with a thin zsh shim preserving the command name.
- **2026-04-15**: Phase 1 scope deliberately excludes deployment to Mac Studio — collector is built to run on localhost first, tested via pytest with fakes for `powermetrics` / `tailscale` / `sshd`, then deployed in Phase 2.
- **2026-04-15 (Phase 1 impl)**: psutil 7.x removed `connections` as an `as_dict()` attribute in favor of `Process.net_connections()`. `SSHCollector` bridges the difference with a small `SimpleProcess` wrapper so the pure `collect_ssh_sessions` walker still takes a plain `process_iter` it can be fed synthetic data in tests.
- **2026-04-15 (Phase 1 impl)**: `SystemCollector.listening_ports` got split into a pure `ports_from_connections(conns, resolver=...)` function so it can be unit-tested without needing root (`psutil.net_connections` is permission-gated on macOS non-root, so the dev-mode path returns `[]`). Production / launchd mode will populate it.
- **2026-04-16 (Phase 2b impl)**: Powermetrics parser rewritten from plist format to text format. Phase 1 had built a synthetic plist fixture and parsed `plistlib` output; on the real Mac Studio (macOS 26.3) the plist output is unreliable and real key names don't match the synthetic ones, whereas the human-readable text labels (`CPU Power: N mW`, `GPU HW active frequency: N MHz`, `GPU idle residency: N%`) are stable across macOS releases. The rewrite is both the immediate fix and a longevity win.
- **2026-04-16 (Phase 2b impl)**: `install-server.sh` `ensure_python_and_uv` + `build_venv` now resolve `PY_BIN` from an absolute-path candidate list rather than trusting `command -v python3`. Root's PATH via `sudo` does not include `/opt/homebrew/bin`, so the pre-patch script resolved the system Python 3.9.6 and died at the version check even though `/opt/homebrew/bin/python3.14` was installed.

## Phase 1 verification (2026-04-15)

- `uv run pytest`: **73 passed, 0 failed**, 94% coverage on collector+shared.
- `uv run studiod` in dev mode binds to `127.0.0.1:8765`, prints the token, serves all six read endpoints.
- `/health` responds unauthenticated; every other endpoint returns 401 without a valid bearer token.
- In dev mode (no root): `/stats` returns `gpu: null, power: null` as designed; `/ports` returns `[]` (psutil net_connections is root-gated on macOS); `/processes` returns a fully populated top-N list; `/ssh/sessions` and `/tmux/sessions` return empty lists (no sshd children into the MacBook, no tmux server running).

## Phase 1 post-review hardening (2026-04-15)

Security review of Phase 1 surfaced six findings. All fixed, 20 new tests
added, full suite at **93 passed, 0 failed**.

- **Fix 1 (blocker)**: `FastAPI(...)` now passes `docs_url=None`, `redoc_url=None`, `openapi_url=None`. `/docs`, `/redoc`, and `/openapi.json` all return 404 — the authenticated API surface is no longer discoverable by unauthenticated callers on the Tailscale network.
- **Fix 2**: `ProcessInfo.cmdline` now contains only `argv[0]` by default. `/processes?include_full_cmdline=true` opts into the full joined command line. This prevents secrets passed via `curl -H 'Authorization: Bearer ...'` or `mysql -pPASSWORD` by other users on the shared machine from bleeding into every authenticated API response.
- **Fix 3**: `collector/config.py` validates `STUDIOD_BIND_HOST` via `ipaddress`. Only `127.0.0.1`, `::1`, or any IP in the Tailscale CGNAT range `100.64.0.0/10` is accepted in prod. Dev mode allows only the two loopback addresses. `0.0.0.0`, private non-Tailscale IPs, public IPs, and garbage strings all raise `ConfigError`, caught by `main()` and turned into exit code 2.
- **Fix 4**: `shared/auth.read_token` now also asserts `st.st_uid == 0` in prod, not just `mode & 0o077 == 0`. Stops an attacker with a non-root foothold from planting a 0600 token file.
- **Fix 5**: `powermetrics`, `tailscale`, and `tmux` subprocess sources now resolve their binary at module load from a known-safe absolute-path candidate list, pass an explicit minimal `env={"PATH": ..., "LANG": "C"}`, and pass `cwd="/"`. If no candidate binary exists the source returns empty results without ever shelling out. The daemon will eventually run as root; PATH / CWD manipulation no longer helps an attacker.
- **Fix 6**: `ensure_dev_token` now verifies the post-chmod mode via `os.stat` and logs a WARNING via `logging` if the file ended up anything other than `0o600`. Dev mode stays forgiving (no hard failure) but stops silently leaving world-readable tokens on exotic filesystems.

## Phase 2a verification (2026-04-15)

- New CLI package at `src/studio_cli/` with subcommands: `tmux`, `status`, `ports`, `who`, `ps`, `sessions`, `stats`, `config show|path`, `version`. Bare `studio` opens the fzf picker; `studio <name>` direct-attaches; both go through `os.execvp("ssh", [...])` -- no shell, no Python wrapper holding the terminal.
- Custom `StudioGroup(click.Group)` overrides `resolve_command` for the bareword tmux dispatch and `invoke` to surface `StudioClientError` / `StudioConfigError` as one-line red errors with exit 1, in both the console-script and `CliRunner.invoke` paths.
- `pyproject.toml` split into extras: core only `pydantic`, `[collector]` adds fastapi+uvicorn+psutil, `[client]` adds click+rich+httpx, `[dev]` covers everything for tests. Collector deploy stays minimal-surface as designed.
- Deploy scripts written but NOT executed:
  - `deploy/com.bosphorify.studiod.plist` (template with `__TAILSCALE_IP__` placeholder)
  - `deploy/install-server.sh` -- idempotent, `--reinstall` flag, validates Tailscale 100.x.x.x range, generates `/etc/studiod/token` only if missing
  - `deploy/uninstall-server.sh` -- preserves token by default, `--purge-token` to remove
  - `deploy/install-client.sh` -- interactive prompts, never touches `~/.zshrc`, prints zshrc shim instructions
  - `deploy/uninstall-client.sh`
  - `deploy/README.md` -- step-by-step Phase 2b walkthrough
- `bash -n deploy/*.sh`: clean. `shellcheck` not installed on this host, so the parametrized `shellcheck` test suite is `SKIPPED [4]`. Re-running with shellcheck installed will exercise it.
- Test count: **147 passed, 4 skipped** (54 new CLI tests on top of the 93 collector tests). Every CLI subcommand has a happy-path test plus targeted error-path coverage (401, 500, connect error, missing/empty/world-readable token file, invalid TOML, dispatch reroutes, invalid session-name rejection without spawning ssh).
- Fixtures use `httpx.MockTransport` injected through a monkeypatched `StudioClient.__init__`, so the real client error-mapping logic is exercised end-to-end without any network calls.
- `uv run studio --help` and `uv run studio version` work locally; `uv sync --extra dev` installs cleanly.

## Phase 2b verification (2026-04-16)

Walked through the deploy interactively from this conversation. Collector is live on the Mac Studio and the MacBook CLI talks to it over Tailscale with real data.

**Server side (Mac Studio, 100.80.21.79)**
- `/opt/studiod/venv` built with Python 3.14.3 (resolved from `/opt/homebrew/bin/python3.14` via the candidate-list patch to `install-server.sh` — root's PATH via `sudo` doesn't include `/opt/homebrew/bin`, so the pre-patch `command -v python3` resolved to macOS system Python 3.9.6 and the script died at the version check).
- `/etc/studiod/token` generated as 256-bit base64, mode 0600, root:wheel.
- `/Library/LaunchDaemons/com.bosphorify.studiod.plist` rendered with `STUDIOD_BIND_HOST=100.80.21.79`.
- `launchctl bootstrap system` succeeded; `/health` curl returned 200 from localhost and from the MacBook over Tailscale.

**Verified from MacBook after install**
- `/health` → 200 in ~17ms over Tailscale (unauthenticated, as designed).
- `/stats` without token → 401. `/stats` with garbage token → 401. `/stats` with real token → 200.
- `/docs`, `/redoc`, `/openapi.json` → 404 (Phase 1 post-review fix confirmed in prod).
- `studio status`, `studio ps`, `studio who`, `studio sessions`, `studio config show`, `studio stats --json` all rendered correctly.

**Client side (MacBook)**
- `~/.config/studio-cli/` created mode 0700 with `config.toml` and `token` (both 0600). Token transferred from `/etc/studiod/token` via `sudo install -m 600 -o $USER ... /tmp/studiod-xfer`, `scp`, then remote `rm` — never landed in shell history or /tmp on the MacBook.
- `uv pip install ".[client]"` into the project's dev venv (the dev venv already had the client extras, so this was a no-op).
- `~/.zshrc:95-140` (the old 46-line fzf+ssh+tmux function) replaced with a 2-line shim: `studio() { "$HOME/Projects/SSH/studio-cli/.venv/bin/studio" "$@"; }`. Backup at `~/.zshrc.bak-pre-studio-cli`. `zsh -n` clean.

**Mid-deploy fix: powermetrics parser rewrite (plist → text)**

First `studio stats --json` against the real daemon came back with `gpu.percent: 100.0` and `gpu.frequency_mhz: 0.00138` and `gpu_watts: 0.0` — a known Phase 1 risk from the worker's notes. Diagnosis via a captured powermetrics sample: the plist output on macOS 26.3 was unreliable (key names shifted), while the **text output** is stable and cleanly labeled (`CPU Power: N mW`, `GPU HW active frequency: N MHz`, `GPU idle residency: N%`, `Combined Power (CPU + GPU + ANE): N mW`).

Rewrote `src/collector/sources/powermetrics.py` to parse the text format with labeled-line regexes; removed `-f plist` from the command; replaced `tests/fixtures/powermetrics_sample.plist` with `powermetrics_sample.txt`; rewrote `tests/test_powermetrics.py` around the new `parse_powermetrics_text` and helpers. Text labels are stable across macOS releases in a way plist key names are not, so this rewrite is also a longevity win.

Pushed via rsync + `sudo launchctl kickstart -k system/com.bosphorify.studiod`. Post-restart `/stats` returned:
- `gpu.frequency_mhz: 1380.0` (real, matches the captured sample)
- `gpu_watts: 44.8` (real; the daemon was discovered to be GPU-pinned by some user process at that moment)
- `cpu_package_watts: 7.362`, `total_watts: 52.162`

**Script tweak: `install-server.sh` Python resolution**

Patched `ensure_python_and_uv` and `build_venv` to resolve `PY_BIN` from an absolute-path candidate list (`/opt/homebrew/bin/python3.{14,13,12,3}`, `/usr/local/bin/python3.{14,13,12,3}`, falling back to `command -v python3`) instead of trusting root's PATH. Matches the existing pattern the script uses for `tailscale` and `uv`.

**Tests**: 153 passed, 4 skipped (shellcheck still not installed). +6 new tests for the text parser (fixture, empty, garbage, string-accept, partial GPU, partial power, missing sections).

See `## Backlog` below for known non-blockers discovered during Phase 2b.

## Phase 2.5 deploy notes (2026-04-16)

Shipped to Studio via `rsync` + `ssh -t macstudio "sudo bash deploy/update-server.sh"`. Daemon restart was clean (uvicorn "Application startup complete. Uvicorn running on http://100.80.21.79:8765", PID 13078 after restart).

**Discovered during deploy verification:**

- **B14 — `update-server.sh` health check binds-to-localhost bug (FIXED inline)**: The script polled `http://127.0.0.1:8765/health`, but the daemon binds to the Tailscale interface only (`STUDIOD_BIND_HOST=100.80.21.79`) per the Phase 1 hardening (`validate_bind_host` restricts to loopback OR `100.64.0.0/10`, and uvicorn only binds to one host at a time). The localhost poll never succeeded, the script exited with "health check failed after 10s" even though the daemon came up fine. Fixed inline by reusing the `detect_tailscale_ip` pattern from `install-server.sh` and polling `http://${ip}:8765/health`. Not in the original Phase 2.5 plan — caught by real-hardware deploy.
- **B15 — `tailscale status --json` returning non-JSON (backlog, non-blocker)**: The collector logs `WARNING collector.sources.tailscale: tailscale status returned non-JSON output` on every peer-map refresh. Peer labeling in `/ssh/sessions` silently falls back to an empty peer map, so `studio who` shows source IPs without the device/owner tag. Most likely cause is the root-running daemon not having access to the Tailscale IPN socket in the same way the user-level CLI does. Added to backlog as B15.
- **B16 — architecture vs implementation: multi-interface bind (backlog, low priority)**: `docs/architecture.md` claims the daemon binds to both `127.0.0.1` and the Tailscale interface. Actual implementation uses a single uvicorn instance bound to one host. For now this is actually fine (Tailscale-only is more restrictive), but the docs don't reflect reality. Added to backlog as B16.

**Pending human verification:**

- `studio status` memory currently reports `20.2%` (`used: 19.4 GB`, `cached: 18.9 GB`, `app_memory: 17.2 GB`, `wired: 3.8 GB`). Need Activity Monitor / Stats.app on the Studio to corroborate within ~2 points.

**Already verified on real hardware:**

- B2 — `studio ps` returned real non-zero CPU% immediately after daemon restart (`launchservicesd 35.1%`, `loginwindow 9.2%`, `kernel_task 7.2%`, etc.).
- B3 — `[v4+v6]` family tags rendering on `tcp/443 io.tailscale`, `tcp/5000 ControlCenter`, `tcp/7000 ControlCenter`.
- B4 — `studio status` shows 5 interesting user ports with `+11 system port(s)` summary instead of 4 duplicate `tcp/22 launchd` rows.

## Backlog

Items in rough priority order. Phase 2.5 (polish) bundles small correctness/display fixes before Phase 3 starts.

### Phase 2.5 — polish pass (small contained fixes)

- **B5. SSH idle-time validation** — `_tty_idle_seconds` uses `os.stat("/dev/<tty>").st_atime`. No real sustained SSH session was active during Phase 2b verification. Action: open a real session, let it sit idle for 60s, check `studio who` reports a sane `idle` column; if atime semantics are wrong, swap to parsing `utmpx` or `last` output. Small task.

### Phase 3 hotfix — B17 root-vs-user tmux namespace (FIXED 2026-04-16)

**Status**: code shipped, deployed, verified end-to-end.

**Bug**: the collector runs as root via launchd, so every `tmux` subprocess (ls, new-session) hit root's `/tmp/tmux-0/` namespace. The user's real tmux sessions live in `/tmp/tmux-501/default`. Result: `studio sessions` returned root's namespace (empty or different from what the user saw), `studio tmux new <name>` created in root's namespace (invisible to user's `ssh -t macstudio tmux attach` which runs as the user), and the bareword `studio <name>` picker workflow was subtly broken since Phase 2b — we just didn't notice during Phase 2b verification because root's namespace happened to be empty. Only discovered during Phase 3 smoke testing when `studio tmux new smoke` succeeded but the session vanished from the user's tmux view.

**Fix**: added `STUDIOD_TMUX_USER` env var (set in the plist at install time from `$SUDO_USER`). When non-empty, `collector.sources.tmux.wrap_tmux_cmd()` prepends `sudo -u <user> -H --` to every tmux invocation. Root-to-any-user sudo is passwordless by definition, so no sudoers change needed. The effective UID switch makes tmux target the user's `/tmp/tmux-<uid>/default` socket. `TmuxCollector` and `perform_tmux_new` both go through the same wrap helper.

**Files touched**: `src/collector/sources/tmux.py`, `src/collector/routes/control.py`, `deploy/com.bosphorify.studiod.plist` (new `__TMUX_USER__` placeholder), `deploy/install-server.sh` (new `detect_tmux_user` from `$SUDO_USER`, plumbed through `write_plist`), `tests/test_tmux_collector.py` (+4), `tests/test_control.py` (+1). Suite 235 → 240 passed.

**Deploy friction**: the plist template changed, so `update-server.sh` (which only kickstarts) wasn't sufficient — needed `install-server.sh --reinstall` to re-render `/Library/LaunchDaemons/com.bosphorify.studiod.plist` and re-bootstrap launchd to pick up the new env var. The `--reinstall` flag got line-wrapped twice in pasted commands, so I ended up running `launchctl bootout` + `install-server.sh` (no flag, daemon unloaded so the already-loaded check passes) manually via the sudo creds the user shared.

**Verification** (post-install):

- `studio sessions` shows `route ● attached (1 window)` — the user's real session, previously invisible
- `studio tmux new b17-check` succeeds; `studio sessions` then shows BOTH `b17-check` and `route`
- `ssh macstudio '/opt/homebrew/bin/tmux ls'` (plain user SSH, no daemon involvement) confirms BOTH sessions exist in the user's namespace at `/tmp/tmux-501/default`
- Cleaned up `b17-check` via `tmux kill-session`

B17 is closed. The Phase 2b regression of the bareword `studio` picker workflow is repaired.

### Deploy-time discoveries (from Phase 2.5 real-hardware verification)

- **B15. `tailscale status --json` returning non-JSON when called from the root daemon.** Logs `WARNING collector.sources.tailscale: tailscale status returned non-JSON output` every ~10s. Peer labeling falls back to empty map so `studio who` lacks device/owner tags. Investigate: probably a socket access issue between root-running `studiod` and user-scoped Tailscale IPN daemon on macOS. Possible fixes: (a) run the tailscale binary via `sudo -u <user>` from the daemon, (b) read the Tailscale status file directly (if there is one), (c) accept the limitation and document. Low priority — SSH sessions still appear, just without the nice labels.
- **B16. Multi-interface bind (docs vs reality).** `docs/architecture.md` says the daemon binds to both `127.0.0.1` and the Tailscale interface. The actual code uses a single uvicorn instance that binds to one host. Either update the architecture doc to say "Tailscale IP in prod, loopback in dev" OR spin up a second uvicorn listener if real multi-interface bind is desired (e.g., for local tools on the Studio that want to hit localhost). Low priority; the current single-bind Tailscale-only setup is actually more secure.

### Phase 2.5 — ergonomics (optional, low priority)

- **B6. `uv tool install --editable` for global `studio`** — Current shim in `~/.zshrc` depends on `~/Projects/SSH/studio-cli/.venv/bin/studio` existing. If the venv is ever nuked (e.g., `rm -rf .venv`), `studio` breaks until `uv sync`. Alternative: `uv tool install --editable ~/Projects/SSH/studio-cli` puts `studio` in `~/.local/bin/` (already on the user's PATH). Trade-off: another installed copy to remember when updating. Low priority — only do this if the .venv dependency causes real friction.

### Phase 3 — control endpoints

- **B8-B12 code complete, awaiting Studio deploy (2026-04-15).** See the new "Phase 3 verification" block below for details.

### Phase 4 — SwiftUI menubar app

- **B13 code complete, pending human install + live verification (2026-04-16).** See `## Phase 4 verification` block below.

### Closed / done

Items listed here are kept as a changelog so we can see what moved off the backlog without digging through history. Move items here when they ship.

- **B1 (2026-04-15)**: macOS memory accounting via `vm_stat`. New `src/collector/sources/memory_macos.py` parses `/usr/bin/vm_stat` into a `VmStatSample` (page size parsed from the header, labeled-line regex for each field, 2-second cache, defensive subprocess pattern with pinned env/cwd and graceful None on binary/timeout/parse failure). `SystemCollector.memory_stats` now computes `used = anonymous + wired + compressed` and `available = free + file_backed + speculative + purgeable` on Darwin, falling back to the psutil path when vm_stat is unavailable. `MemoryStats` gained optional `app_memory_bytes`, `wired_bytes`, `compressed_bytes`, `cached_files_bytes`. `studio status` shows a "Cached: N" hint line under the memory bar when those fields are present.
- **B2 (2026-04-15)**: per-pid CPU% tracked across collector polls. `SystemCollector` now starts a daemon background thread at construction (can be disabled with `background=False` for tests) that calls `psutil.cpu_percent` + walks `process_iter` every 2 seconds and caches the snapshot under a `threading.Lock`. `__init__` primes psutil's internal state for both the system and every process, sleeps 500ms, then takes the first real sample before the thread starts — so the very first `studio ps` after a daemon restart returns real non-zero numbers. `cpu_stats()` and `process_list()` read the cache; there's a synchronous fallback for the cold path. The old argv[0]-redact rule for `include_full_cmdline=false` is preserved by storing the full joined cmdline in the cache and splitting at request time.
- **B3 (2026-04-15)**: listening-port dedupe. `ports_from_connections` now groups by `(protocol, port, process_name, user, pid)` and collapses rows that only differ by address family. The canonical row takes the first-seen address and records the contributing families in the new `PortInfo.address_families` field. Single-family rows keep `address_families=None` so Phase 1/2 clients render unchanged. IPv4-mapped IPv6 is classified as v4. `dedupe=False` opts out (not used in prod).
- **B4 (2026-04-15)**: top-5 ports ordering. `studio status` now splits ports into "interesting" vs "system well-known" (22, 53, 67, 68, 88, 123, 137-139, 445, 500, 546, 547, 631, 5353, 5355, 5900), shows up to 5 interesting rows, backfills with system rows if fewer than 5 non-system ports exist, and appends a `+N system port(s)` footer otherwise. `studio ports` (the full list) is unchanged except it now shows an optional "Fam" column that renders "v4+v6" on collapsed rows.
- **B7 (2026-04-15)**: `deploy/update-server.sh`. Short one-purpose iterative update helper: sanity-checks macOS + root + existing venv, reinstalls `studio-cli[collector]` into `/opt/studiod/venv` via `uv pip install --reinstall` (falling back to `venv/bin/pip`), runs `launchctl kickstart -k system/com.bosphorify.studiod`, polls `http://127.0.0.1:8765/health` for up to 10 seconds, exits. No plist rewrite, no token rotation, no venv rebuild. `ssh -t macstudio "sudo bash deploy/update-server.sh"` fits on one line.
- **B8 (2026-04-15, pending Studio deploy)**: `POST /kill {pid, signal}`. Allowed signals 1/2/9/15. Refuses pid 1 (launchd), the daemon's own pid, missing pids (404), and a denylist of macOS critical processes (`launchd`, `kernel_task`, `WindowServer`, `loginwindow`, `coreaudiod`, `systemstats`, `runningboardd`). Implementation in `src/collector/routes/control.py::perform_kill`, late-binds `os.kill` / `psutil.pid_exists` for test monkeypatching.
- **B9 (2026-04-15, pending Studio deploy)**: `POST /ssh/kick {pid}`. Looks the pid up against the live `/ssh/sessions` snapshot (so it's *provably* an sshd child), refuses to kick the session whose `source_ip` matches `Request.client.host`, delivers SIGHUP. Response body echoes the full `SSHSession`.
- **B10 (2026-04-15, pending Studio deploy)**: `POST /tmux/new {name}`. Regex-validated name (`^[A-Za-z0-9_.-]+$`, len ≤ 64). Subprocess reuses `collector.sources.tmux`'s pinned env / cwd / absolute-binary pattern. Idempotent: duplicate-session stderr collapses to `{created: false, exists: true}` rather than 500. No tmux binary -> 503.
- **B11 (2026-04-15, pending Studio deploy)**: CLI subcommands `studio kill <pid>` (with `--signal N` and `--kill` alias, confirmation prompt unless `--yes`), `studio kick <pid>`, `studio tmux new <name>`. `RESERVED_NAMES` in `StudioGroup` now includes `kill` and `kick` so bareword tmux dispatch can't swallow them; `tmux_cmd` was converted to a click group with a hidden `__attach__` fallback subcommand so `studio tmux <name>` still attaches and `studio tmux new <name>` dispatches correctly.
- **B12 (2026-04-15, pending Studio deploy)**: `src/collector/audit.py`. Stdlib-only `RotatingFileHandler` (5 MB, 3 backups). Grep-friendly `<iso8601Z> action=... key=value ...` format. Prod path `/var/log/studiod.audit.log` mode 0640, dev path `./studiod-audit.log` mode 0600. Every write endpoint writes a record on both success AND refusal. Audit-write failure raises `AuditWriteError` and the endpoint returns 500 -- fail-closed: an auditable action that cannot be logged must not succeed. Token identity is logged as the first 8 hex chars of `sha256(token)`.

## Phase 2.5 verification (2026-04-15)

- `uv run pytest`: **180 passed, 5 skipped** (the fifth skip is the new `update-server.sh` shellcheck parametrization; shellcheck is still not installed on this host). Baseline was 149 passed / 4 skipped, so the phase added 31 tests against its ~25 target.
- New test files: `tests/test_memory_macos.py` (parser + VmStatCollector), `tests/test_system_memory.py` (SystemCollector memory integration with injected vm_stat), `tests/test_system_cpu_cache.py` (B2 cache behavior), `tests/test_ports_dedupe.py` (B3 family dedupe), `tests/cli/test_status_ports.py` (B4 top-5 filtering + family tag rendering + cached-files hint).
- `bash -n deploy/*.sh`: clean for all five scripts.
- No new runtime dependencies. No `shell=True`. All subprocess calls go through the absolute-binary + pinned-env pattern.
- **Known caveat (for the human during Studio deploy of B1)**: on the captured fixture (96 GiB total, 51.25 GB used) the AM-style percent lands near ~49.7% when computed against the raw `hw.memsize` bytes, not the ~53% the plan writeup cited. The writeup used decimal-GB division (51.25 GB / 96 GB) while `hw.memsize` on real hardware is raw bytes against which 51.25 GB = ~47.7 GiB. The real Mac Studio number should still be within 2 points of Activity Monitor because both use the same accounting — but don't be alarmed if `studio status` now reads ~49% when the plan said "around 53". If Activity Monitor and `studio status` diverge by more than ~2 points, recheck `parse_vm_stat` against a fresh `sudo vm_stat` capture on the Studio and compare the anonymous/wired/compressed page counts.

## Phase 3 verification (2026-04-15)

- `uv run pytest`: **235 passed, 5 skipped** (baseline was 180 passed / 5 skipped, so Phase 3 added 55 tests against the ~25 target). The fifth skip is still the `shellcheck` parametrization; shellcheck isn't installed on this host.
- New test files: `tests/test_audit.py` (9 tests: fingerprint, line format, quoting, rotation-handler instantiation, append-across-instances, unwritable-parent, prod vs dev path resolution), `tests/test_control.py` (25 tests across /kill /ssh/kick /tmux/new happy-paths, every refusal branch, audit-write on both success and refusal, unauthenticated 401 for each endpoint), `tests/cli/test_kill_command.py` (8 tests: --yes happy path, --kill alias → SIGKILL, explicit --signal, confirmation prompt accept/deny, server 403 surfacing, reserved-name check), `tests/cli/test_kick_command.py` (6 tests: analogous), `tests/cli/test_tmux_new_command.py` (5 tests: created, exists, bad-name client-side, 503 surfacing, bareword attach still works).
- `bash -n deploy/*.sh`: clean for all five scripts. No deploy-script changes in Phase 3.
- No new runtime dependencies. Audit log uses stdlib `logging.handlers.RotatingFileHandler` only.
- No `shell=True`. `/tmux/new` reuses the existing `SUBPROCESS_ENV` / `SUBPROCESS_CWD` / absolute-binary pattern from `collector.sources.tmux`.
- Conftest wiring: the shared `app` fixture now instantiates `create_app` with an `AuditLogger(tmp_path / "audit.log", mode=0o600)` per-test fixture, so tests can assert on audit-file contents via `app.state.audit.path`.

**Pending human verification on real hardware:**

- `/var/log/studiod.audit.log` is created with owner `root:wheel`, mode `0640`, on first write. The daemon runs as root via launchd and creates the file itself on first control call -- no install-script surgery is needed. On an existing deployment where the daemon is re-loaded and no write has happened yet, the file will not exist until the first `studio kill` / `studio kick` / `studio tmux new` call.
- `logging.handlers.RotatingFileHandler` rotates to `.1` / `.2` / `.3` backups at 5 MB. For a single-user setup this is effectively "never" but verify by tail-F-ing the file during a smoke test.
- Confirmation prompts in `studio kill` and `studio kick` use `click.prompt` with default=""; pressing Enter is a rejection. The `--yes` flag skips the prompt entirely.

**Guardrails carried over from the plan (worth re-reading before the deploy):**

- `DENY_PROCESS_NAMES` in `collector/routes/control.py` is easy to extend -- if a future kill attempt ever hits a surprise "I bricked the Mac" process, add it there and reinstall.
- `refuse your own session` check in `/ssh/kick` compares against `request.client.host`. When the daemon runs behind Tailscale the client host is the peer's 100.x.x.x IP; the test harness sees `"testclient"`. Either way the invariant holds: an operator cannot kick the session they are currently using to make the API call.

## Phase 4 verification (2026-04-16)

**Code-complete, offline.** No Python / collector / deploy changes. All new code lives under `menubar/`.

### What shipped

- SwiftUI menubar app targeting macOS 13+ (`MenuBarExtra` scene, window-style popover).
- `StudioClient` (URLSession-based async actor) with typed `StudioClientError` that mirrors the Python client's error mapping.
- `Config` loader with a hand-rolled ~80-line TOML parser covering the exact 4 keys the CLI writes (`collector_url`, `token_file`, `timeout_seconds`, `ssh_host`). Honors `STUDIO_COLLECTOR_URL` / `STUDIO_TOKEN` / `STUDIO_TOKEN_FILE` / `STUDIO_TIMEOUT` / `STUDIO_SSH_HOST` / `STUDIO_CONFIG_FILE` env var overrides and enforces 0600 on the token file with a chmod hint.
- `AppState` (`@MainActor ObservableObject`) with 60-entry `HistoryRing` buffers for CPU / GPU / MEM / total-power sparklines.
- `PollingService` with 3s idle / 1s open cadence, five-endpoint `async let` parallel fetch per poll, typed error surfacing into an orange banner in the popover header.
- Popover layout: connection dot + last-poll age + collector host in the header, system overview bars (CPU / GPU / MEM with cached-files hint under MEM when available) + PWR line, 2x2 grid of Swift Charts sparklines, segmented tab picker, Processes / Ports / SSH / Tmux tab bodies, footer with Refresh and Quit buttons.
- Control actions: Kill (with `confirmationDialog`), Kick (same), New tmux (inline text field + New button). Each surfaces success / failure inline under the table.
- `menubar/build.sh`, `menubar/install.sh`, `menubar/uninstall.sh`, `menubar/deploy/com.bosphorify.studiomenubar.plist` (with `__HOME__` placeholder substituted by install.sh). Install script is user-scope, no sudo, `launchctl bootstrap gui/$(id -u)`.
- 43 Swift tests under `menubar/Tests/StudioMenuBarTests/`: 9 model round-trip decode tests against 7 JSON fixtures derived from `src/shared/models.py`, 14 HTTP-client tests (happy + error paths for every endpoint) using a custom `URLProtocol` subclass, 14 config tests (TOML parser happy/malformed/tables/duplicate keys, env-vs-file precedence, 0600 / 0644 token mode enforcement, empty token rejection), 6 polling-state tests (ring-buffer capacity, `AppState.apply`, `markError`, cadence flag).

### Build / test results

- `swift build -c release --package-path menubar`: `Build complete! (34.51s)` on first release build; `Build complete! (0.09s)` incremental.
- Test harness via `swift run --package-path menubar StudioMenuBarTests`: **43 passed, 0 failed**.
- `bash menubar/build.sh`: produced `menubar/build/StudioMenuBar.app`. `codesign -dvvv` confirms `Signature=adhoc`, `Identifier=com.bosphorify.studiomenubar`, `Format=app bundle with Mach-O thin (arm64)`. `codesign -v` exit 0.

### Deviations from the plan

- **No XCTest, no swift-testing.** Both are unavailable in this environment: XCTest ships only with full Xcode (this machine has Command Line Tools only, `xcode-select -p` -> `/Library/Developer/CommandLineTools`), and swift-testing's `Testing.framework` is present in the CLT SDK but the `_Testing_Foundation` cross-import overlay is incomplete (binary present, swiftmodule missing), so any `import Testing` + `import Foundation` combo fails with `no such module '_Testing_Foundation'`. Worked around by making the test target an executable target and writing a ~120-line hand-rolled test harness (`TestHarness.swift` + `TestMain.swift`) with `expect` / `expectEqual` / `expectClose` / `expectThrows` / `expectThrowsAsync` helpers and a `TestRunner` that prints pytest-ish output. Invoked via `swift run StudioMenuBarTests` (or `bash menubar/test.sh`), not `swift test`. The plan said "Swift Testing or XCTest -- worker's call"; this is a third option but the outcome is the same: 43 tests pass, exit code 0 on success, exit code 1 on any failure.
- **Split library target + executable target.** Because the test target is now an executable (not a testTarget), it can't use `@testable import`. So `StudioMenuBarApp` became a thin 9-line `@main` executable that imports the `StudioMenuBar` library target, and every type the tests touch is marked `public`. The library target also contains the SwiftUI Scene (as `StudioMenuBarScene`). One-line App file in `Sources/StudioMenuBar/App/Main.swift`.
- **TOML parser is hand-rolled.** Per the plan guidance. ~80 lines, supports bare keys + string values (with `\"` and `\\` escapes) + numeric values + inline comments + duplicate-key detection + table rejection. No external SPM deps.

### Collector / API changes flagged (not implemented)

None. Every Swift Codable struct matches the pydantic source of truth in `src/shared/models.py` exactly. The only field-name wart is `PortInfo.protocol` in Python, which is a Swift keyword -- handled by mapping it to `protocolName` via `CodingKeys` on the Swift side. No Python edit needed.

One minor observation for future consideration (NOT a blocker, NOT implemented):

- The collector responds to an unauthenticated `/health` the same as the Python CLI expects, but the menubar app currently uses authenticated polls for the five data endpoints and never calls `/health`. If we wanted a faster "is the collector reachable at all?" signal we could add a cheap authenticated `/ping` endpoint or reuse `/health` as a liveness probe. For now the 5s URLSession timeout is fine.

### Recommended human smoke-test sequence

1. `cd /Users/barathanaslan/Projects/SSH/studio-cli/menubar && bash test.sh` -- expect `43 passed, 0 failed`.
2. `bash build.sh` -- expect `Built build/StudioMenuBar.app` and `codesign -v` passes silently.
3. `bash install.sh` -- expect `App installed. Look for the icon in the menubar.` and no errors from `launchctl bootstrap`.
4. Look in the menubar for the icon (a green dot + CPU% + SSH count, e.g. `3% 0`). First poll lands within ~3 seconds.
5. Click the icon. Verify the popover header shows the Mac Studio's Tailscale host and a recent "2s ago" age; verify CPU / GPU / MEM bars and the PWR line have real non-zero values; verify the sparklines start drawing a growing 60-sample history after watching for ~60s.
6. Click through the four tabs. Processes should list the top 10 by CPU; Ports should show the same rows as `studio ports`; SSH should show your own session (plus any others); Tmux should show your `/tmp/tmux-501/default` sessions (B17 fix).
7. On the Mac Studio, in a throwaway shell: `ssh macstudio 'sleep 9999' &` (or a plain background sleep via another terminal). Back in the menubar, find the `sleep` process in the Processes tab, click Kill, confirm. Verify the row disappears on the next poll and the action message reads "killed sleep (pid N)".
8. Tmux tab: type `smoke-test` in the New field, click New. Verify the row appears on the next poll. On the Studio: `tmux kill-session -t smoke-test` to clean up.
9. Optional: in System Settings -> General -> Login Items, verify `StudioMenuBar` is listed under "Allow in the Background". Reboot / logout+login to confirm launch-at-login works.
10. When done testing (or if anything goes wrong): `bash uninstall.sh`. Expect the icon to disappear and the launchd agent to be removed.

## v2 tailmon MVP (2026-07-10)

Executed `docs/plans/v2-tailmon-mvp.md`: Go rewrite, single `tailmon` binary
(module `github.com/barathanaslan/studio-cli`), Python v1 removed from `main`
(archived on `v1-python`). Subcommands: TUI (default) / `agent` / `sample` /
`json` / `version`. Port 7020, binds Tailscale IP + 127.0.0.1 only, no root,
no tokens. Deps: gopsutil/v4, bubbletea v1.3.10, lipgloss v1.1.0, stdlib.

**Verification (all on real hardware):**

- `go vet ./...` + `go test ./...` green. Soak test: 5,000 in-process /stats
  requests → RSS 20.0→23.0 MB (**+3.03 MB**, limit 10), goroutines 6→3
  (returns below baseline). Parser tests for ioreg / nvidia-smi CSV /
  memory_pressure / tailscale status JSON from captured real output.
- Studio `tailmon sample`: cpu 3.6% / 28 cores / load1 4.4; mem used 16427 of
  98304 MB (used = total − available), pressure normal; GPU "Apple M3 Ultra"
  util from ioreg (`"Device Utilization %"` key present as planned, no
  adaptation needed); disk 209.4/926.4 GB; real top_procs; agent self-block.
- Agent + `tailmon json`: agent answered on 127.0.0.1:7020 AND
  100.80.21.79:7020; json showed studio `live` (local in-process), 5070 +
  MacBook `offline`; with the 5070 awake but serviceless it showed `no-agent`.
- Windows end-to-end: `cuda on` (up ~45s), scp'd exe, `ssh barat@100.95.91.27
  "tailmon.exe sample"` → RTX 5070 Ti util 0% / VRAM 176/16303 MB / 34°C,
  mem 4910/64673 MB, 24 cores, load1 null, C: + E: disks. Only tailmon.exe
  dropped in the home dir; Task Scheduler service NOT installed (needs admin —
  owner runs `deploy/install-windows.ps1` once). `cuda off` clean afterward.
- launchd agent installed on the Studio via `deploy/install-macos.sh`
  (user LaunchAgent `com.bosphorify.tailmon`, ~/bin/tailmon): idle at
  **0.0% CPU, ~22 MB RSS**; `curl http://100.80.21.79:7020/stats | jq .agent`
  works.
- TUI smoke-tested on a pty: cards render with live data + sparklines, states
  live/no-agent/offline correct, `q` exits cleanly with zero leftover
  processes. (Headless-pty note: a pty that doesn't answer terminal capability
  queries (OSC 11 / CSI 6n) eats the first keypress — a test-harness artifact,
  not an app bug; verified fine with query-answering pty and real terminals.)

**Decisions during implementation:**

- CGO_ENABLED=0 everywhere — gopsutil v4 gives identical real numbers on
  darwin without cgo (verified side by side).
- Discovery filters peers to agent-capable OSes (macOS/windows/linux); the
  tailnet's phones and shared-in devices would otherwise clutter every view.
- TUI prefers the local :7020 agent for the self row (surfaces the deployed
  agent's real RSS), falling back to in-process sampling; `tailmon json`
  always samples local in-process per the plan.
- The wake affordance keys off "offline Windows host + local ~/bin/cuda
  exists" rather than a hardcoded hostname.

**Still to do (later phases):** run `deploy/install-windows.ps1` on the PC as
admin (owner, once); install on the MacBook when it comes online (`git pull &&
./build.sh && ./deploy/install-macos.sh`); rework `menubar/` against the v2
agent (see `menubar/STATUS.md`).

---

## 2026-07-10 (late) — agents everywhere, boot-race fix, Tailmon.app

- Windows agent installed as a SYSTEM ONSTART task over elevated ssh (barat's
  key is in administrators_authorized_keys — discovered tonight; the ps1's
  "ssh is not elevated" assumption was wrong). PS 5.1 needs ASCII-only ps1.
- **Boot race found and fixed**: at Windows boot the agent started before the
  Tailscale interface had its IP and bound loopback-only forever (netstat
  after a power cycle proved it). agent.Run now retries the Tailscale bind
  every 15s until first success, then stops. Verified: cold boot → answering
  on the Tailscale IP in ~10s, pre-login.
- MacBook fully deployed (Go agent via launchd + PATH fix in .zshrc).
- TUI: wake/shutdown keys removed entirely — owner rule: monitoring tools must
  not control power; `cuda on/off` in a shell is the only path.
- `/stats?top=N` (clamp 1..25) + `sample/json --top` + `command` field on
  top_procs. Cache samples once at max depth; handler trims per request.
- **Tailmon.app** (menubar/ rewritten, SwiftUI, macOS 13+ MenuBarExtra):
  label = local CPU% + mem + pressure mark; dropdown = per-host cards with
  top-processes lists (the "what runs" insight). Read-only by design. Menu
  closed = one localhost poll/15s, zero spawns (verified: 60s pgrep watch, 0
  violations); menu open = `tailmon json --top 10`/3s, single-flight.
  Installed and running on Studio + MacBook. Fixture-based decode tests.
  Deviation: idle RSS 74.5 MB vs the 50 MB plan target — SwiftUI baseline;
  still far under Stats.app. Trim later if it bothers.
- The first menubar build agent stalled 10 min in with only the sampler diff
  done; the rest was implemented directly in the main session.

**Still to do:** owner clicks through Tailmon.app in the morning (layout
verification is visual); Windows box gets the ?top= agent whenever it's next
on (`scp dist/tailmon-windows-amd64.exe` + task restart, or just ask); decide
repo rename; later phases: ports/ssh/tmux insight, Windows tray.
