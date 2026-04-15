# Plan 04: Phase 3 — control endpoints

## Goal

Add write-side capabilities to the collector: kill processes, terminate SSH sessions, create tmux sessions. Plus a proper audit trail. All three endpoints get matching CLI subcommands.

This is the first phase that lets the user do more than *observe* the Mac Studio from their MacBook. Every endpoint takes a destructive action, so the guardrails matter more than the code.

## Backlog items covered

- **B8** — `POST /kill`
- **B9** — `POST /ssh/kick`
- **B10** — `POST /tmux/new`
- **B11** — CLI subcommands: `studio kill`, `studio kick`, `studio tmux new`
- **B12** — Audit logging to `/var/log/studiod.audit.log`

## Success criteria

1. `studio kill <pid>` sends `SIGTERM` (default) or `--signal <N>` to a target PID on the Mac Studio. Refuses the daemon's own PID, `launchd` (pid 1), and any pid in a denylist. Confirmation prompt unless `--yes`. Exits 0 on success, non-zero on any refusal.
2. `studio kick <pid>` terminates a specific SSH session by signaling the `sshd:` child process. Validates the target is actually an sshd child before acting. Confirmation prompt unless `--yes`.
3. `studio tmux new <name>` creates a new tmux session on the Studio with the given name (regex-validated), without attaching. Idempotent: if the session already exists, returns 200 with a `exists: true` flag instead of erroring.
4. Every write call appends a line to `/var/log/studiod.audit.log`: timestamp, remote IP, action, target (pid or session name), signal, actor's token identity (by hash, not the token itself), success/failure, error string if any.
5. `/kill`, `/ssh/kick`, `/tmux/new` all require the bearer token (same auth as the read endpoints). Unauthenticated calls get 401.
6. Full pytest suite stays green with +20 to +30 new tests. Target: 200+ passing.

## Out of scope

- Interactive `studio kill` with process search/picker (that's a nice-to-have; keep the first version purely argumental).
- Bulk operations (`studio kill --all python`). Too easy to misfire.
- Remote tmux *attach* via a control endpoint — that's inherently interactive and is already covered by `studio tmux <name>` (which SSHes in).
- Any structured rate limiting — single-user setup, not needed.
- Phase 4 menubar app — the upcoming phase.

## Endpoint specs

### `POST /kill`

**Request body** (JSON):

```json
{
  "pid": 12345,
  "signal": 15
}
```

- `pid`: required, positive int, ≤ 2^31.
- `signal`: optional, defaults to `15` (SIGTERM). Allowed: `1` (HUP), `2` (INT), `9` (KILL), `15` (TERM). Any other value is 400.

**Validation** (in this order; first failure wins):

1. `pid` is a positive int in range. → 400 `invalid pid`
2. `pid != 1` (launchd). → 403 `refusing to signal launchd`
3. `pid != os.getpid()` (the daemon itself). → 403 `refusing to signal self`
4. `pid != os.getppid()` and not in the daemon's process tree. Optional; skip if it's fiddly. Revisit if we ever kill ourselves by accident.
5. Process with that pid exists via `psutil.pid_exists(pid)`. → 404 `pid not found`
6. Denylist check: refuse to signal certain critical processes by name (`launchd`, `kernel_task`, `WindowServer`, `loginwindow`, `coreaudiod`, `systemstats`, `runningboardd`). The list lives in one constant in `collector/routes/control.py` and is easy to extend. → 403 `refusing to signal <name>`

**Action**: `os.kill(pid, signal)` wrapped in `try/except ProcessLookupError` (race against the process exiting) and `PermissionError` (shouldn't happen as root, but handle anyway).

**Response** (200):

```json
{
  "pid": 12345,
  "signal": 15,
  "process_name": "python",
  "user": "barathanaslan",
  "sent_at": "2026-04-16T00:30:00Z"
}
```

**Audit log line** (always, even on failure):

```
2026-04-16T00:30:00.123Z kill pid=12345 signal=15 name=python user=barathanaslan by=100.64.0.2 token=<fp> result=ok
```

### `POST /ssh/kick`

**Request body**:

```json
{ "pid": 54321 }
```

**Validation**:

1. `pid` is a positive int. → 400
2. Process exists. → 404
3. **Must be an sshd session child.** Check `psutil.Process(pid).name() == "sshd"` and the parent (`ppid`) is also an `sshd` (the forked master). If not, → 403 `target is not an sshd session`.
4. Denylist: refuse to kick our own session (the one the HTTP request came in on). We can identify it by comparing `pid` against the sshd children whose source IP matches the Tailscale peer the request came from. If it matches, → 403 `refusing to kick your own session`.

**Action**: `os.kill(pid, signal.SIGHUP)` — SIGHUP is the standard way to terminate an SSH session cleanly.

**Response**: 200 with the session summary (matches `SSHSession` model).

**Audit log line** follows the same format.

### `POST /tmux/new`

**Request body**:

```json
{ "name": "alpha" }
```

**Validation**:

1. `name` matches `^[A-Za-z0-9_.-]+$`. → 400
2. Length ≤ 64. → 400

**Action**: subprocess call to `/opt/homebrew/bin/tmux` (or `/usr/local/bin/tmux` per the existing candidate-list pattern in `sources/tmux.py`):

```
tmux new-session -d -s <name>
```

- `-d` creates without attaching, which is exactly what we want for a remote API call.
- If tmux is not installed or the binary isn't on the candidate list, return 503 `tmux not available`.

**Idempotency**: if `tmux new-session -d -s <name>` returns non-zero with stderr matching "duplicate session" (already exists), return 200 with `{"name": "<name>", "created": false, "exists": true}` instead of erroring. If it succeeds, return `{"name": "<name>", "created": true, "exists": false}`.

**Must reuse** the subprocess env/cwd pinning from `sources/tmux.py`. Do not shell out naively.

**Audit log**: action=`tmux_new`, target=name.

### Audit log

**New file**: `src/collector/audit.py` — a tiny wrapper around Python logging that writes to `/var/log/studiod.audit.log`.

- File is created at daemon startup if missing, owned `root:wheel` mode `0640`.
- Handler: `logging.handlers.RotatingFileHandler` with 5 MB max size and 3 backups — prevents unbounded growth.
- Line format (not JSON — grep-friendly is more useful for a shared-machine log): `<iso8601>Z <action> <key=value...>` space-separated.
- Fields required on every line: `action`, `by` (remote IP from `Request.client.host`), `token` (first 8 chars of sha256 of the presented token — identifies *which* stored token was used without leaking it), `result` (`ok` or `err:<reason>`), plus action-specific fields (`pid`, `signal`, `name`, etc.).
- Write is best-effort: if the audit write fails (disk full, permission), log a WARNING to the main daemon log and return 500 from the endpoint. An auditable action without an audit record should fail closed.

**In dev mode** (`STUDIOD_DEV_MODE=1`), the audit log goes to `./studiod-audit.log` in the cwd instead of `/var/log/`, mode 0600, owned by the user. No file system surgery for dev.

### CLI subcommands

**`studio kill <pid> [--signal N] [--yes]`** — `src/studio_cli/commands/kill.py`:

- Default signal is 15. `--signal 9` shortcut: `--kill` (alias).
- If not `--yes`, fetches `/processes` first, finds the pid, shows a confirmation prompt: `Kill <name> (pid=<pid>, user=<user>, RSS=<size>)? [y/N]`. Aborts on anything not `y`/`yes`.
- Calls `POST /kill`. On 200, prints `killed <name> (pid=<pid>) with SIG<name>`. On error, prints the error body and exits 1.
- Surfaces `StudioClientError` the same way other commands do.

**`studio kick <pid> [--yes]`** — `src/studio_cli/commands/kick.py`:

- Fetches `/ssh/sessions`, finds the matching session (validates user isn't kicking a non-existent session), shows a confirmation prompt with source IP and Tailscale peer label.
- Calls `POST /ssh/kick`. On 200, prints `kicked ssh session pid=<pid> from <source_ip>`.

**`studio tmux new <name>`** — extends the existing `src/studio_cli/commands/tmux.py`:

- This is a new subcommand under the `tmux` group: `studio tmux new <name>`.
- Calls `POST /tmux/new`. On `created: true`, prints `created tmux session <name>`. On `exists: true`, prints `tmux session <name> already exists`.
- **Does NOT attach** — the user can attach with `studio <name>` or `studio tmux <name>` after creation if they want.

**Dispatcher update**: `StudioGroup.resolve_command` already reroutes bareword `studio <name>` → `studio tmux <name>`. Adding `kill`, `kick`, and `tmux new` means extending `RESERVED_NAMES` to include `kill` and `kick`, so a user can't have a tmux session literally named `kill` without being explicit. Document this in the cli.py docstring.

## Tests

- **Endpoint tests** (pytest + TestClient with fakes): happy path and each validation branch for all three endpoints. Fake `os.kill` via monkeypatch. Fake `psutil.Process` via a small stub that the existing system source pattern already uses.
- **Audit log tests**: write happens on every call (including refusals), file format is stable, redacted token identifier is deterministic, dev-mode path uses a tmp directory.
- **CLI tests**: happy path + confirmation prompt (via CliRunner `input="y\n"`), `--yes` skipping the prompt, error-path rendering.
- **Dispatcher test**: `studio kill`, `studio kick`, `studio tmux new` route correctly, and `studio tmux main` still picks the `main` tmux session (via `studio tmux <name>` attach behavior).

Target: +25 to +30 new tests.

## Guardrails for the worker

- **Do NOT** SSH anywhere. No `launchctl`, no `sudo`. All work is offline. Deploy is interactive.
- **Do NOT** touch `powermetrics.py`, the vm_stat memory logic from Phase 2.5, or the CPU background sampler.
- **Do NOT** add runtime dependencies.
- **Do NOT** use `shell=True` anywhere. List-form args only.
- **Do NOT** implement a `studio kill --all <pattern>` or any bulk / interactive picker. First version is single-pid only.
- **Do NOT** relax the bearer-token requirement for write endpoints. Every destructive path goes through the same `require_token` dependency as the read endpoints.
- **Do** reuse existing code: subprocess env/cwd pinning, bearer-token dependency, `StudioClientError` surfacing, rich output formatting.
- **Do** run `uv run pytest` and report the exact final summary line.
- **Do** run `bash -n deploy/*.sh` (the deploy scripts don't change but the test still runs).
- **Do** update `docs/progress.md`: move B8–B12 to a new `## Phase 3 verification` block and strike them from the backlog's "Closed / done" section once the real-hardware deploy is done (leave a note saying "pending deploy verification" for now since the worker runs offline).
- **Do** write a short PR-notes report at the end: what shipped, deviations, things to watch during the Studio deploy.

## Definition of done

- `/kill`, `/ssh/kick`, `/tmux/new` implemented per specs above.
- `studio kill`, `studio kick`, `studio tmux new` subcommands implemented.
- Audit log writes on every write call, at `/var/log/studiod.audit.log` in prod, `./studiod-audit.log` in dev.
- Full test suite passes locally.
- `docs/progress.md` updated with a Phase 3 code-complete block; backlog B8–B12 marked "code complete, awaiting Studio deploy".
