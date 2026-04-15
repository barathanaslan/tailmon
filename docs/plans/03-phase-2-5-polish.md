# Plan 03: Phase 2.5 polish pass

## Goal

Fix the accumulated backlog items B1–B4 and B7 (see `docs/progress.md` → "Backlog" section). B5 is a verification task that happens interactively with the user post-deploy; don't try to do it in code.

Everything in this phase is contained correctness/display fixes — no new endpoints, no new commands, no architectural shifts. The collector API surface stays the same except for additive fields on `MemoryStats` and improved data inside `ProcessInfo` and `PortInfo` responses. The CLI gets small renderer updates.

## Scope

- **B1**: macOS memory accounting via `vm_stat`
- **B2**: Per-process CPU% tracked across polls on the collector (no more first-call zeros)
- **B3**: Dedupe listening ports by `(protocol_family_collapsed, port, process_name, user)`
- **B4**: `studio status` top-5 ports ordering — exclude well-known system ports
- **B7**: `deploy/update-server.sh` one-purpose iterative update helper

Out of scope: B5 (needs a real SSH session, user-interactive), B6 (low priority, defer), any Phase 3 / Phase 4 work.

## Success criteria

1. `studio status` memory percent matches Activity Monitor / Stats.app within ~2 percentage points on the real Mac Studio.
2. `studio ps` shows real non-zero CPU% for active processes even on the very first call of the CLI after the daemon starts (no cold-poll zeros).
3. `studio status` top-5 ports shows 5 distinct, non-duplicate, non-system (or mostly non-system) rows.
4. `studio ports` full list has duplicate address-family rows collapsed into single rows with a small family indicator (e.g., `tcp/22 launchd [v4+v6]`).
5. `deploy/update-server.sh` exists, passes `bash -n` and `shellcheck` (when available), and is short enough that `ssh -t macstudio "sudo bash deploy/update-server.sh"` does not risk terminal wrap breakage.
6. Full test suite stays green. New test count should be +25 or so.

## Context the worker needs

- Phase 2b is complete. Collector runs on the Mac Studio as a root launchd daemon bound to `100.80.21.79:8765`. MacBook CLI works. Token transfer is set up.
- The user discovered the memory discrepancy during Phase 2b verification: `studio status` reports ~33% while Activity Monitor reports ~50%. We captured raw `vm_stat` from the Studio mid-session. A good sample to use as a fixture:

  ```
  Mach Virtual Memory Statistics: (page size of 16384 bytes)
  Pages free:                             2453686.
  Pages active:                           1715997.
  Pages inactive:                         1706518.
  Pages speculative:                        35181.
  Pages throttled:                              0.
  Pages wired down:                        321922.
  Pages purgeable:                          29393.
  "Translation faults":                5488725224.
  Pages copy-on-write:                   99749569.
  Pages zero filled:                   2284205729.
  Pages reactivated:                        64362.
  Pages purged:                           2058550.
  File-backed pages:                       651864.
  Anonymous pages:                        2805832.
  Pages stored in compressor:                2733.
  Pages occupied by compressor:               610.
  ...
  ```

  Reading of this sample:
  - Total = 96 GB (from `hw.memsize`, which psutil gives us via `virtual_memory().total`).
  - **Wired** = 321922 × 16384 ≈ 5.27 GB.
  - **Anonymous** = 2805832 × 16384 ≈ 45.97 GB (this is the "App Memory" analog).
  - **Compressed** (occupied by compressor) = 610 × 16384 ≈ 10 MB.
  - **Used (Activity Monitor style)** = anonymous + wired + compressed ≈ 51.25 GB ≈ 53%.
  - **Cached (reclaimable)** = file-backed + speculative ≈ (651864 + 35181) × 16384 ≈ 10.74 GB.
  - Activity Monitor also shows "Memory Used" + "Cached Files" separately; the collector should expose both.

## Implementation

### B1: vm_stat-based memory accounting

**New file**: `src/collector/sources/memory_macos.py`

- Wraps `/usr/bin/vm_stat` with the same defensive pattern as the other subprocess sources: absolute-path candidate list resolved at module load, pinned `env`, `cwd="/"`, short timeout, graceful `None` return on failure.
- Parses the labeled text output. The page size is reported in the header line (`page size of N bytes`) — parse it, don't hardcode 16384, because Intel Macs still use 4096 and older Apple Silicon used different values.
- Regexes for the lines we care about: `Pages free`, `Pages active`, `Pages inactive`, `Pages speculative`, `Pages wired down`, `Pages purgeable`, `Pages occupied by compressor`, `File-backed pages`, `Anonymous pages`.
- Returns a dataclass with `page_size`, `free`, `active`, `inactive`, `speculative`, `wired`, `purgeable`, `compressed`, `file_backed`, `anonymous`, all in bytes.
- Short cache (2 seconds) to avoid re-shelling on back-to-back requests.

**Update `shared/models.py`**: extend `MemoryStats` with these optional fields:

```python
class MemoryStats(BaseModel):
    total_bytes: int
    used_bytes: int
    available_bytes: int
    percent: float
    swap_used_bytes: int
    swap_total_bytes: int
    # New: Activity Monitor–style breakdown. None on non-Darwin or when vm_stat fails.
    app_memory_bytes: int | None = None
    wired_bytes: int | None = None
    compressed_bytes: int | None = None
    cached_files_bytes: int | None = None
```

Backwards compatible — existing callers keep working.

**Update `src/collector/sources/system.py`** `memory_stats()`:

- On Darwin, call the new `VmStatCollector.sample()` helper, compute `used = anonymous + wired + compressed`, `percent = used / total * 100`, and populate the new optional fields.
- Fall back to the existing psutil-based calculation if `vm_stat` is unavailable (non-Darwin dev mode, binary missing, parse failure).
- `available_bytes` on Darwin should use `free + file_backed + speculative + purgeable` (reclaimable memory) rather than psutil's `available`.

**Update `src/studio_cli/commands/status.py`** (or wherever the status renderer lives):

- Show the new `percent`. Add a secondary line under the memory bar: `Cached: N GB` when `cached_files_bytes` is present.
- If all four new fields are present, optionally render an expanded breakdown in a `--detail` mode: `App N · Wired N · Compressed N · Cached N`. Keep this off by default — the one-line view matters for menubar-style use.

**Tests**:

- New fixture: `tests/fixtures/vm_stat_sample.txt` with the real capture above (or a trimmed but representative subset).
- Parser tests for each field.
- `memory_stats()` integration test that uses a FakeVmStat injected into `SystemCollector` and asserts the computed Activity Monitor-style numbers.
- Fallback test: when vm_stat returns None (not Darwin), psutil path is used and the new optional fields are None.

### B2: Per-pid CPU% tracked across collector polls

**New**: a background sampler thread (or `threading.Timer`-based refresh) inside `SystemCollector` that calls `psutil.cpu_percent(interval=None, percpu=True)` and `psutil.process_iter(['pid', 'cpu_percent'])` every 2 seconds and caches the results. The HTTP handler for `/processes` and `/stats` reads the cache, never calls psutil directly for CPU.

**Implementation notes**:

- A `threading.Thread(daemon=True)` owned by `SystemCollector`, started at `__init__`, runs a simple loop: `time.sleep(2); self._refresh_cpu()`.
- `_refresh_cpu()` does:
  - `psutil.cpu_percent(interval=None, percpu=True)` — system CPU
  - Walk `psutil.process_iter(['pid', 'name', 'username', 'cpu_percent', 'memory_info', 'memory_percent', 'create_time', 'status', 'ppid', 'cmdline'])` once, materialize into a list of `ProcessInfo`, store in `self._process_cache`.
  - On the *first* pass after startup, `cpu_percent` returns 0.0 for every process (known psutil quirk). Solution: do a warm-up pass at `__init__` time that seeds psutil's internal state, then sleep 500ms, then do the first real sample. From there on, every sample gives real numbers.
- Cache access is guarded by a `threading.Lock`.
- `cpu_stats()` and `process_list()` read from the cache. If the cache is empty (collector just started and warm-up hasn't completed), fall back to a synchronous sample with `interval=None` and accept the zeros for that one call.
- Pytest fixtures construct `SystemCollector` with the background thread **disabled** (pass `background=False` or similar) and manually call `_refresh_cpu()` where needed. No flaky sleep-based tests.

**Clean shutdown**: the daemon thread is, well, a daemon thread — it dies with the process. No explicit cleanup needed for SIGTERM because uvicorn handles the HTTP side and daemon threads get torn down by interpreter shutdown.

**Tests**:

- `SystemCollector(background=False)` constructible.
- `_refresh_cpu()` called twice: first run returns zeros, second run returns real numbers (fake psutil via `monkeypatch`).
- `process_list()` returns the cached snapshot.
- `process_list()` fallback path when the cache is empty.

### B3: Dedupe listening ports

Update `ports_from_connections()` in `src/collector/sources/system.py` (or a new helper) to group by `(port, protocol_layer_4, process_name, user, pid)` — ignoring the specific address family. When multiple rows collapse, pick one as the canonical row and record which families contributed in a new optional field:

```python
class PortInfo(BaseModel):
    protocol: Literal["tcp", "udp"]
    address: str
    port: int
    pid: int | None
    process_name: str | None
    user: str | None
    # New: which address families this listener was observed on (e.g., ["v4", "v6"]).
    # Absent on non-deduplicated responses for backwards compat with tests.
    address_families: list[str] | None = None
```

The renderer in `studio ports` uses `address_families` to show `tcp/22 launchd [v4+v6]`; when None, renders as before.

**Tests**: construct a fake set of connections where sshd binds `0.0.0.0:22` and `:::22` and assert the dedupe collapses them into one row with `address_families=["v4","v6"]`.

### B4: Top-5 ports ordering

Update `src/studio_cli/commands/status.py` (the renderer):

- Maintain a small constant `SYSTEM_WELL_KNOWN = {22, 53, 68, 123, 500, 631, 5353, 5355, ...}` inside the renderer. Keep it short — the point isn't to exhaustively categorize, just to skip the "boring" rows that dominate sorted-by-port output.
- For the status top-5 view, filter out ports in `SYSTEM_WELL_KNOWN` first, pick the first 5 of what remains, and append a trailing line `+N system ports` with the count of filtered rows. If fewer than 5 non-system ports exist, backfill with system ports so the view is always populated.
- `studio ports` (the full list) is unchanged — no filtering, show everything.

**Tests**: snapshot-style test on the status renderer that confirms the top-5 excludes port 22 and port 53 when a rich fake set of ports is provided, and includes them when `<5` non-system ports exist.

### B7: deploy/update-server.sh

**New file**: `deploy/update-server.sh` — a one-purpose iterative update script. The entire body:

1. Assert macOS + root + Tailscale (reuse the helpers from `install-server.sh` — either source them or copy the small checks).
2. Install the package into the existing `/opt/studiod/venv` via `uv pip install --python /opt/studiod/venv/bin/python ${REPO_DIR}[collector] --reinstall` (or the equivalent for non-uv installs).
3. `launchctl kickstart -k system/com.bosphorify.studiod`.
4. Wait for `/health` to respond 200 (up to 10s), then exit.

No plist rewrite, no token regeneration, no venv rebuild. Fast path only for "I rsync'd new code, kick the daemon".

**Short invocation form**: the entire line `ssh -t macstudio "sudo bash deploy/update-server.sh"` must fit in a typical terminal width without wrap. Don't add optional flags in the common case.

**Tests**: `bash -n deploy/update-server.sh` in the existing deploy-script test, `shellcheck` when available. No runtime tests — the script won't execute during pytest.

## Guardrails for the worker

- Do NOT SSH anywhere. All work is local to `/Users/barathanaslan/Projects/SSH/studio-cli/`.
- Do NOT modify `~/.zshrc`, `~/.config/studio-cli/`, `/etc/studiod/`, `/opt/studiod/`, `/Library/LaunchDaemons/`.
- Do NOT add any new dependencies. Standard library + existing deps only.
- Do NOT break existing tests. If a test breaks and you think the new behavior is correct, update the test with a comment explaining why — don't silently rewrite assertions.
- Do NOT touch `src/collector/sources/powermetrics.py`, the FastAPI app structure, the auth path, or the deploy plist. Out of scope.
- Do NOT implement Phase 3 endpoints (`/kill`, `/ssh/kick`, `/tmux/new`) — even if the surrounding code looks like a natural place to add them.
- Do run `uv run pytest` at the end and report the exact summary line.
- Do run `bash -n deploy/*.sh` and report the result.
- Do update `docs/progress.md` with a dated Phase 2.5 completion block summarizing what shipped and listing which backlog items were closed (move B1, B2, B3, B4, B7 to the "Closed / done" section under `## Backlog`). Leave B5 and B6 as-is.

## Definition of done

- All five items (B1, B2, B3, B4, B7) implemented per the specs above.
- New tests exist for each (target +25 total).
- Full `uv run pytest` passes.
- `bash -n deploy/*.sh` clean.
- `docs/progress.md` updated; backlog items moved to closed.
- PR-notes report: what shipped, any deviations and why, anything to pay attention to when the human deploys this to the Studio in the post-worker verification step.
