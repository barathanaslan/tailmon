# Plan 02a: CLI package + deploy scripts (offline)

## Goal

Build the Python CLI package that replaces the user's existing `studio` zsh function, and write the deploy scripts (launchd plist + install/uninstall shell scripts) that Phase 2b will execute interactively against the real Mac Studio.

**This phase does NOT deploy anything.** All work is local to this repo on the MacBook. The worker must not SSH anywhere, must not run `launchctl`, must not modify `~/.zshrc`, and must not execute either install script. Deploy scripts are written and reviewable but not run.

## Context the worker needs

- The collector from Phase 1 is complete and hardened. It runs on `127.0.0.1:8765` in dev mode today.
- The user's Mac Studio is reachable at `100.80.21.79` over Tailscale (CGNAT IP, SSH alias `macstudio` in `~/.ssh/config`, user `barathanaslan`).
- The existing `studio` zsh function lives at `~/.zshrc:95-140`. It's a 46-line fzf-based tmux picker. **Do not read or modify that file.** The replacement CLI must preserve the current UX (`studio` with no args → picker, `studio <name>` → direct attach) exactly.
- Phase 3 will add control endpoints (`/kill`, `/ssh/kick`, `/tmux/new`). Phase 2 stays read-only on the server side. The CLI can have `kill` stubbed with "not implemented in Phase 2" if it fits the shape.

## Success criteria

1. `uv sync` installs the package cleanly; `studio --help` works from the MacBook shell.
2. `studio` with no args and `studio <session-name>` both behave like the existing zsh function (fzf picker / direct attach via `ssh -t macstudio tmux ...`). The subprocess that runs fzf and ssh still gives the user full interactive control of their terminal.
3. `studio status`, `studio ports`, `studio who`, `studio ps`, `studio sessions`, `studio stats` all hit the collector over HTTP and render pretty `rich` output. Work against the localhost collector today; will work against the Studio after Phase 2b.
4. Every CLI subcommand has tests using `click.testing.CliRunner` with mocked HTTP responses via `httpx.MockTransport`.
5. `deploy/install-server.sh`, `deploy/uninstall-server.sh`, `deploy/install-client.sh`, `deploy/uninstall-client.sh`, and `deploy/com.bosphorify.studiod.plist` exist, pass `bash -n` and `shellcheck` (if installed), and are self-documenting via `--help` / inline comments.
6. Full test suite (collector + CLI) passes: `uv run pytest`.
7. `docs/progress.md` updated with Phase 2a completion and any deviations.

## Out of scope (leave for Phase 2b or later)

- Executing any install script or deploying to the Mac Studio.
- Modifying `~/.zshrc` or any file outside the repo directory.
- Control endpoints on the collector (Phase 3).
- SwiftUI menubar app (Phase 4).
- Historical metrics, rate limiting, multi-host support.

## Repo additions

```
studio-cli/
├── src/
│   └── studio_cli/
│       ├── __init__.py
│       ├── __main__.py              # `python -m studio_cli`
│       ├── cli.py                   # click group + dispatch
│       ├── config.py                # client config loading (URL, token path)
│       ├── client.py                # httpx wrapper around collector API
│       ├── formatting.py            # rich renderers for tables, bars, etc.
│       └── commands/
│           ├── __init__.py
│           ├── tmux.py              # default command + fzf picker + ssh attach
│           ├── status.py            # overview: cpu/gpu/mem/power/ssh/ports summary
│           ├── ports.py             # listening-port table
│           ├── who.py               # SSH session table with Tailscale peer labels
│           ├── ps.py                # top processes table
│           ├── sessions.py          # tmux session list (non-interactive)
│           └── stats.py             # raw stats dump
├── deploy/
│   ├── com.bosphorify.studiod.plist   # launchd system daemon plist template
│   ├── install-server.sh              # runs on the Mac Studio (sudo); not executed in this phase
│   ├── uninstall-server.sh
│   ├── install-client.sh              # runs on the MacBook; not executed in this phase
│   ├── uninstall-client.sh
│   └── README.md                      # step-by-step deploy instructions for Phase 2b
└── tests/
    └── cli/
        ├── __init__.py
        ├── conftest.py                # fixtures: CliRunner, MockTransport, fake responses
        ├── test_dispatch.py           # default/tmux-passthrough dispatch
        ├── test_status.py
        ├── test_ports.py
        ├── test_who.py
        ├── test_ps.py
        ├── test_sessions.py
        ├── test_stats.py
        └── test_config.py             # env var and config-file loading
```

## Dependency structure

Update `pyproject.toml` to split deps into optional extras so the Mac Studio deploy pulls only what the collector needs:

- **Core (always installed)**: `pydantic>=2`
- **`collector` extra**: `fastapi`, `uvicorn[standard]`, `psutil`. Installed on the Studio.
- **`client` extra**: `click`, `rich`, `httpx`. Installed on the MacBook.
- **`dev` extra**: `pytest`, `pytest-asyncio`, `httpx`, `ruff`.

The default install for local development (`uv sync`) installs everything. The server install script runs `uv pip install .[collector]` to get the minimal surface. The client install script runs `uv pip install .[client]`.

**Why the split matters**: the collector runs as root. Every transitive dep of `click`/`rich` becomes root-privileged if we don't separate them. Hard-isolate them now.

## CLI dispatch behavior (critical — read carefully)

The existing `studio` zsh function accepts either:
- No args → fzf picker showing tmux sessions with attached/detached indicators, then attach
- One positional arg → direct attach to that tmux session (creating it if it doesn't exist)

We must preserve both behaviors and also add subcommands. Approach:

Use `click.Group` with `invoke_without_command=True`. In the group callback, if `ctx.invoked_subcommand is None`:
- If no args: invoke the `tmux` command with no target (picker mode).
- If `sys.argv[1]` is NOT a reserved subcommand name AND doesn't start with `-`: treat it as a tmux session name and invoke `tmux_cmd(name=sys.argv[1])`.

Subcommands (reserved names): `tmux`, `status`, `ports`, `who`, `ps`, `sessions`, `stats`, `config`, `version`.

If a user ever has a tmux session literally named `status` (unlikely), they can use `studio tmux status` to disambiguate.

Document this in `cli.py`'s docstring and in `deploy/README.md`.

## Subcommand specifications

### `studio tmux [NAME]`
- No NAME: fetches `/tmux/sessions` from the collector, builds a fzf input stream (same format as existing function: `"<name>  ● attached"` / `"<name>  ○ detached"`, plus `"+ New session"`), calls `fzf` as a subprocess with the same flags the existing function uses, takes the user's pick, then `os.execvp` into `ssh -t macstudio tmux ...`.
- With NAME: direct `ssh -t macstudio tmux new-session -A -s NAME`.
- Use `os.execvp` for the final ssh call so the CLI process is replaced — no lingering Python process holding the terminal.
- **Important**: do NOT use `shlex.quote` on the session name and interpolate into a shell string. Pass the ssh args as a list. `ssh -t macstudio "tmux new-session -A -s NAME"` is fine as `["ssh", "-t", "macstudio", "tmux", "new-session", "-A", "-s", NAME]`.
- Validate NAME is `^[A-Za-z0-9_-]+$` before using it. Reject with a friendly error otherwise.

### `studio status`
- Hits `GET /stats`, `GET /ssh/sessions`, `GET /ports` in parallel (httpx supports this via a connection pool + threading, or sequentially if simpler).
- Renders a compact single-screen overview:
  - CPU bar (percent), GPU bar (percent or "—" if null), Memory bar (percent + used/total)
  - Power line: `CPU: X.X W · GPU: Y.Y W · Total: Z.Z W` (or `—` if null)
  - `SSH sessions: N` (list each one with peer label)
  - `Listening ports: N` (just the count + top 5 by port number)
- No polling, no live refresh in Phase 2 — one snapshot, then exit. Menubar app (Phase 4) handles live updates.

### `studio ports`
- Hits `GET /ports`.
- Renders a `rich.Table` with columns: `Proto`, `Address`, `Port`, `PID`, `Process`, `User`.
- Sort by port ascending.
- `--watch` flag: refresh every 2 seconds via `rich.Live`. Useful; trivial to add.

### `studio who`
- Hits `GET /ssh/sessions`.
- Renders a `rich.Table` with columns: `PID`, `User`, `From`, `Peer`, `TTY`, `Started`, `Idle`.
- "Peer" column shows `tailscale_peer.hostname` if present, else `—`.
- Empty case: print "No active SSH sessions." and exit 0.

### `studio ps [--sort cpu|mem] [--limit N] [--full-cmdline]`
- Hits `GET /processes?limit=N&sort=...&include_full_cmdline=...`.
- Renders a `rich.Table` with columns: `PID`, `User`, `CPU%`, `Mem%`, `RSS`, `Name`, `Cmdline`.
- `--full-cmdline` passes the query flag through. Default is argv[0] only.
- Default limit 20, max 100.

### `studio sessions`
- Hits `GET /tmux/sessions`.
- Renders a list (not a table — it's short): `main ● attached`, `dev ○ detached`, etc.
- Non-interactive (no fzf). For the interactive picker, `studio` or `studio tmux` is the entry point.

### `studio stats`
- Hits `GET /stats`.
- `--json` flag: dump the raw response as pretty JSON. Default: formatted sections with `rich`.

### `studio config [show|path]`
- `show`: print the loaded config (collector URL, token file path, token redacted to first 4 chars + `…`)
- `path`: print the config file path
- No `set` subcommand in Phase 2 — editing is manual.

### `studio version`
- Prints the package version from `studio_cli.__version__`.

## Client configuration

`src/studio_cli/config.py` loads config in this order (first hit wins):

1. Environment variables: `STUDIO_COLLECTOR_URL`, `STUDIO_TOKEN_FILE`, `STUDIO_TOKEN` (direct override, useful for tests).
2. Config file: `~/.config/studio-cli/config.toml`
3. Built-in defaults:
   - `collector_url = "http://100.80.21.79:8765"`
   - `token_file = "~/.config/studio-cli/token"`
   - `timeout_seconds = 5.0`

The token file lives at `~/.config/studio-cli/token` with mode `0600` (enforced; if wider, refuse to read and print a fix hint).

`shared/auth.py` already has token-reading helpers for the server side — reuse the constant-time comparison pattern and mode-check logic where sensible, but the client side is allowed to be a little more forgiving (it reads; it doesn't authenticate).

## HTTP client

`src/studio_cli/client.py` wraps `httpx.Client` (sync, not async — this is a CLI, not a service):

- Base URL from config
- `Authorization: Bearer <token>` set once at construction
- Default timeout from config
- Methods: `health()`, `stats()`, `processes(limit, sort, include_full_cmdline)`, `ports()`, `ssh_sessions()`, `tmux_sessions()`
- Parses responses into the pydantic models from `shared/models.py`
- Catches `httpx.ConnectError` → raises `StudioClientError("cannot reach collector at <URL> — is studiod running?")`
- Catches 401 → raises `StudioClientError("collector rejected token — check ~/.config/studio-cli/token")`
- CLI entry point catches `StudioClientError` and prints the message in red via `rich`, exits 1. No traceback in the user's face.

## Deploy scripts

**`deploy/com.bosphorify.studiod.plist`** — launchd system daemon plist. Keys:

```xml
Label:         com.bosphorify.studiod
UserName:      root
ProgramArguments:
  - /opt/studiod/venv/bin/python
  - -m
  - collector
EnvironmentVariables:
  STUDIOD_BIND_HOST: __TAILSCALE_IP__    # substituted by install-server.sh
  STUDIOD_BIND_PORT: "8765"
  STUDIOD_TOKEN_FILE: /etc/studiod/token
RunAtLoad:          true
KeepAlive:          true (with SuccessfulExit=false so crash loops still restart)
StandardOutPath:    /var/log/studiod.out.log
StandardErrorPath:  /var/log/studiod.err.log
WorkingDirectory:   /
ProcessType:        Interactive
```

Place in `deploy/` as a template with `__TAILSCALE_IP__` as a literal placeholder. `install-server.sh` does the substitution.

**`deploy/install-server.sh`** — runs on the Mac Studio, probably invoked via `ssh macstudio sudo bash install-server.sh`. It must:

1. Assert running on Darwin, running as root (or re-exec with sudo).
2. Assert `tailscale` is installed and up. Get the Tailscale IPv4 via `tailscale ip -4`. Refuse to proceed if empty.
3. Check Python 3.12+ is available (prefer `uv` if installed, fall back to `python3 -m venv`).
4. Create `/opt/studiod/` (mode 0755, root:wheel), `/etc/studiod/` (mode 0700, root:wheel), `/var/log/studiod.out.log` and `.err.log` (mode 0640, root:wheel).
5. Create a venv at `/opt/studiod/venv` and install the collector: `uv pip install .[collector]` from the repo directory (assume repo is at `~/studio-cli` — make this configurable via `--repo-dir` flag, default to the script's detected location).
6. Generate a random token: `openssl rand -base64 32 | tr -d '\n' > /etc/studiod/token; chmod 600 /etc/studiod/token; chown root:wheel /etc/studiod/token`.
7. Render `com.bosphorify.studiod.plist` with the Tailscale IP substituted, write to `/Library/LaunchDaemons/com.bosphorify.studiod.plist` (mode 0644, root:wheel).
8. Load it: `launchctl bootstrap system /Library/LaunchDaemons/com.bosphorify.studiod.plist`.
9. Wait 2s, then curl `http://<tailscale_ip>:8765/health` and assert 200.
10. Print:
    - The Tailscale IP it bound to
    - A one-line reminder: "Copy the token from /etc/studiod/token to the MacBook at ~/.config/studio-cli/token"
    - The command to tail logs: `log show --predicate 'process == "studiod"' --last 5m`

The script should be **idempotent**: running it twice should not duplicate the launchd entry or re-generate the token. Use `launchctl print system/com.bosphorify.studiod` to detect an existing install and either bail out with a "use uninstall-server.sh first" message, or offer a `--reinstall` flag.

**`deploy/uninstall-server.sh`** — reverses the install: `launchctl bootoff`, remove plist, remove `/opt/studiod/`, optionally preserve `/etc/studiod/token` (prompt or `--purge-token` flag).

**`deploy/install-client.sh`** — runs on the MacBook. Much simpler:

1. Assert running on Darwin.
2. Check Python 3.12+ and `uv` available (offer to `brew install uv` if missing).
3. Create `~/.config/studio-cli/` (mode 0700).
4. Prompt for the collector URL (default: `http://100.80.21.79:8765`) and token (paste from clipboard/terminal). Write to `~/.config/studio-cli/config.toml` and `~/.config/studio-cli/token` (mode 0600) respectively.
5. Run `uv pip install .[client]` from the repo directory into the user's active Python env.
6. Verify with `studio version` and `studio status`.
7. Print a message with the exact zsh shim lines to add to `~/.zshrc` **manually** (do NOT touch `.zshrc`):
   ```
   # Remove your old `studio()` function block first.
   # The `studio` command is now provided by the studio-cli package.
   ```
   If pip's console script is on PATH, no shim needed. If it's not (pyenv confusion), print a fallback shim:
   ```
   studio() { python -m studio_cli "$@"; }
   ```

**`deploy/uninstall-client.sh`** — `uv pip uninstall studio-cli`, optionally remove `~/.config/studio-cli/`.

**`deploy/README.md`** — a numbered step-by-step walkthrough for Phase 2b. Should read like a checklist for the human + architect. Include what to verify at each step.

## Tests

- Use `click.testing.CliRunner` with `mix_stderr=False`.
- Use `httpx.MockTransport` to fake the collector. Fixtures return well-formed pydantic-validated responses for each endpoint.
- Test each subcommand's happy path: renders without exception, contains expected substrings.
- Test error paths: `httpx.ConnectError` → friendly message + exit 1; 401 → token-hint message + exit 1; 500 → generic error + exit 1.
- Test dispatch: `studio`, `studio main`, `studio status` all route to the right handler.
- Test config loading: env vars override file, file overrides defaults, missing token file produces a clear error.
- Don't test the deploy scripts' runtime behavior (they're not executed). Do run `bash -n deploy/*.sh` and, if `shellcheck` is on PATH, `shellcheck deploy/*.sh` as a test.

Target test count: ~25 new tests. Total should be ~118 (93 from Phase 1 + ~25 here).

## Guardrails for the worker

- **Do not** SSH anywhere. Do not execute `launchctl`, `sudo`, `install-server.sh`, or `install-client.sh`. These are artifacts reviewed by the human in Phase 2b.
- **Do not** touch `~/.zshrc`, `~/.ssh/config`, `~/.config/studio-cli/`, `/etc/studiod/`, `/opt/studiod/`, `/Library/LaunchDaemons/`, or any file outside the repo.
- **Do not** add deps beyond the ones listed (`click`, `rich`, `httpx` for client; nothing new for collector). If you think you need another, put it in the PR notes.
- **Do not** use `shell=True` anywhere. Pass args as lists.
- **Do** preserve the existing collector behavior exactly — this phase adds code, doesn't modify collector internals. If you find yourself editing `src/collector/`, stop and explain why.
- **Do** run `uv run pytest` at the end and report the result.
- **Do** run `bash -n` on every script in `deploy/` and report the result.
- **Do** update `docs/progress.md` with a dated Phase 2a completion entry.

## Definition of done

- Repo additions match the layout above
- `uv sync` installs cleanly; `studio --help` shows the command list
- Every subcommand's happy path verified with tests
- Full test suite passes
- `bash -n deploy/*.sh` is clean
- `deploy/README.md` reads like a walkthrough a human can follow step by step
- `docs/progress.md` updated; Phase 2a checkbox ticked
- PR-notes report: what was built, deviations, anything surprising, recommended Phase 2b sequence
