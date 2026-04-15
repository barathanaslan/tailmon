# Plan 01: Foundation + Collector (read-only)

## Goal

Stand up the repo structure and implement the collector daemon with all **read** endpoints. Scope deliberately excludes deployment to the Mac Studio — the collector must run on the MacBook in dev mode for local testing. Deployment is Phase 2.

## Success criteria

1. Running `uv run studiod` (or equivalent) on the MacBook starts the collector on `127.0.0.1:8765` in dev mode.
2. `curl -s http://127.0.0.1:8765/health` returns `{"ok": true}`.
3. With a dev bearer token in the `Authorization` header, every read endpoint returns well-formed JSON matching the pydantic models in `shared/`.
4. `pytest` passes with >90% coverage on collector code.
5. All endpoints gracefully degrade in dev mode: if `powermetrics` isn't available (not running as root), `/stats` returns `gpu: null, power: null` but still serves CPU/memory.
6. `README.md` at the repo root documents how to run the collector in dev mode and hit each endpoint with curl.

## Out of scope (leave for later phases)

- launchd plist and install scripts (Phase 2)
- Actual deployment to Mac Studio (Phase 2)
- CLI package (Phase 2)
- Control endpoints — `/kill`, `/ssh/kick`, `/tmux/new` (Phase 3)
- SwiftUI menubar app (Phase 4)

## Repo structure to create

```
studio-cli/
├── pyproject.toml              # uv/pip project, Python 3.12+
├── README.md                   # short: dev mode run, curl examples
├── .gitignore                  # __pycache__, .venv, .pytest_cache, token files
├── .python-version             # 3.12
├── src/
│   ├── shared/
│   │   ├── __init__.py
│   │   ├── models.py           # pydantic models for all API responses
│   │   ├── auth.py             # token loading/validation helpers
│   │   └── config.py           # default ports, paths, env var names
│   └── collector/
│       ├── __init__.py
│       ├── __main__.py         # `python -m collector` entry point
│       ├── app.py              # FastAPI app factory
│       ├── auth.py             # FastAPI dependency for bearer token
│       ├── config.py           # dev mode detection, bind address logic
│       ├── routes/
│       │   ├── __init__.py
│       │   ├── health.py
│       │   ├── stats.py
│       │   ├── processes.py
│       │   ├── ports.py
│       │   ├── ssh.py
│       │   └── tmux.py
│       └── sources/            # data collection modules (easy to fake in tests)
│           ├── __init__.py
│           ├── system.py       # psutil-based CPU, mem, processes, network
│           ├── powermetrics.py # subprocess wrapper, parser, graceful fail
│           ├── tailscale.py    # `tailscale status --json` parser, peer map
│           ├── ssh_sessions.py # sshd process tree walker + peer labeling
│           └── tmux.py         # `tmux ls -F` wrapper
├── tests/
│   ├── __init__.py
│   ├── conftest.py             # pytest fixtures: FastAPI TestClient, fakes
│   ├── test_health.py
│   ├── test_stats.py
│   ├── test_processes.py
│   ├── test_ports.py
│   ├── test_ssh.py
│   ├── test_tmux.py
│   ├── test_auth.py
│   └── fixtures/
│       ├── tailscale_status.json     # sample output for fakes
│       ├── powermetrics_sample.txt   # sample output for parser tests
│       └── sshd_processes.json       # sample psutil process tree
└── docs/                       # already exists, do not touch
```

## Implementation notes

### Packaging

- Use `pyproject.toml` with `uv` (user is on Apple Silicon with pyenv, `uv` is the fastest modern Python workflow). Fall back to plain `pip -e .` compatibility if `uv` introduces friction.
- Python 3.12+ (user uses pyenv, assume they can install any version).
- Dependencies: `fastapi`, `uvicorn[standard]`, `psutil`, `pydantic>=2`. Dev deps: `pytest`, `pytest-asyncio`, `httpx` (for TestClient), `ruff`.
- Entry point: define a console script `studiod = collector.__main__:main` in pyproject.

### Shared models (`src/shared/models.py`)

Write pydantic v2 models for every response. At minimum:

- `HealthResponse { ok: bool, version: str, uptime_seconds: float }`
- `StatsResponse { cpu: CPUStats, memory: MemoryStats, gpu: GPUStats | None, power: PowerStats | None, timestamp: datetime }`
- `CPUStats { percent_total: float, percent_per_core: list[float], load_avg: tuple[float, float, float] }`
- `MemoryStats { total_bytes: int, used_bytes: int, available_bytes: int, percent: float, swap_used_bytes: int, swap_total_bytes: int }`
- `GPUStats { percent: float, frequency_mhz: float | None }` — nullable when powermetrics unavailable
- `PowerStats { cpu_package_watts: float, gpu_watts: float, total_watts: float }` — nullable when powermetrics unavailable
- `ProcessInfo { pid: int, ppid: int, user: str, name: str, cmdline: str, cpu_percent: float, memory_rss_bytes: int, memory_percent: float, status: str, create_time: datetime }`
- `ProcessListResponse { processes: list[ProcessInfo], total_count: int, sampled_at: datetime }`
- `PortInfo { protocol: Literal["tcp", "udp"], address: str, port: int, pid: int | None, process_name: str | None, user: str | None }`
- `PortListResponse { ports: list[PortInfo], sampled_at: datetime }`
- `SSHSession { pid: int, user: str, source_ip: str, source_port: int, tailscale_peer: TailscalePeer | None, tty: str | None, started_at: datetime, idle_seconds: float | None }`
- `TailscalePeer { hostname: str, tailscale_ip: str, os: str | None, user_display_name: str | None }`
- `SSHSessionListResponse { sessions: list[SSHSession], sampled_at: datetime }`
- `TmuxSession { name: str, windows: int, attached: bool, created_at: datetime | None }`
- `TmuxSessionListResponse { sessions: list[TmuxSession], sampled_at: datetime }`

### Collector configuration

Environment variables the collector reads (all optional):

- `STUDIOD_TOKEN_FILE` — path to bearer token file. Default: `/etc/studiod/token` in prod, `.studiod-dev-token` in the repo root for dev.
- `STUDIOD_BIND_HOST` — bind address. Default: `127.0.0.1`. In prod the launchd plist will set this to the Tailscale IP.
- `STUDIOD_BIND_PORT` — default `8765`.
- `STUDIOD_DEV_MODE` — if set to `1`, skip root-required features (powermetrics) gracefully, allow the token file to be user-owned, log to stdout.

When starting in dev mode and the token file doesn't exist, generate one (`secrets.token_urlsafe(32)`) and print it to stdout so the developer can copy it.

### Auth

- FastAPI dependency `require_token` that:
  - Reads the token file once at startup, caches it
  - Compares `Authorization: Bearer <token>` in constant time (`hmac.compare_digest`)
  - Returns 401 otherwise
- Applied to all routes except `/health`.

### Data sources — critical guidance

- **`sources/system.py`**: use `psutil.cpu_percent(interval=None, percpu=True)`, `psutil.virtual_memory()`, `psutil.process_iter([...])`. For processes, sort in Python — don't use `psutil.cpu_percent` with blocking intervals (it would serialize requests).

- **`sources/powermetrics.py`**: wraps `powermetrics --samplers cpu_power,gpu_power --sample-count 1 --sample-rate 1000 -f plist`. Parse the plist output (stdlib `plistlib`). If the subprocess fails with permission denied or `FileNotFoundError`, return `None` instead of raising — this is dev mode graceful degradation. Wrap with a short cache (e.g., 2 seconds) so rapid polling doesn't hammer the system.

- **`sources/tailscale.py`**: wraps `tailscale status --json`. Build a map of `tailscale_ip -> TailscalePeer`. Cache for ~10 seconds. If `tailscale` binary isn't on PATH, return empty map and log once at warning level.

- **`sources/ssh_sessions.py`**: walk all `sshd` processes. The parent `sshd` is `root`, session children are forked `sshd: user@pty/X` processes. Parse the command line to extract source IP:port. Cross-reference source IP against the Tailscale peer map to populate `tailscale_peer`. Also include SSH sessions from non-Tailscale sources (raw IPs) — just with `tailscale_peer: null`.

- **`sources/tmux.py`**: `tmux ls -F '#{session_name}|#{session_windows}|#{?session_attached,1,0}|#{session_created}'`. If `tmux` isn't installed or no server is running, return empty list.

- **`sources/ports.py`** (put this in system.py or its own file): `psutil.net_connections(kind='inet')` filtered to `LISTEN` status. Cross-reference pid against `psutil.Process(pid)` for process name/user. Include both TCP and UDP (UDP has no LISTEN state, include all UDP with a bound local address).

### Tests

- Use `fastapi.testclient.TestClient`.
- Fake every data source with dependency-injection: the FastAPI app factory should accept optional source overrides. Tests pass in fakes that return fixture data.
- For `powermetrics`: test both the success case (parse fixture plist) and the failure case (subprocess returns non-zero, file not found, wrong output format). In dev mode, `/stats` should still respond 200 with `gpu: null, power: null`.
- For auth: test missing header, wrong token, right token.
- For SSH session peer labeling: test that a session with source IP matching a Tailscale peer gets labeled, one with a non-Tailscale IP gets `tailscale_peer: null`.

### README.md content

Short. Just:
- What this is (one paragraph pointing at `docs/overview.md` for the long version)
- How to run the collector in dev mode: `uv sync && uv run studiod`
- The dev token gets printed to stdout on first start
- curl examples for each endpoint
- How to run tests: `uv run pytest`

## Guardrails for the worker

- **Do not** deploy anything to the Mac Studio. Do not SSH anywhere. Do not touch `~/.zshrc`. All work is local to the MacBook's `studio-cli/` directory.
- **Do not** use `shell=True` in any subprocess call. Always pass a list of args.
- **Do not** add dependencies beyond those listed above without a good reason. If you think you need one, put it in the PR notes at the end.
- **Do not** implement control endpoints (`/kill`, `/ssh/kick`, `/tmux/new`). Skeleton them if you want, but no behavior — leave TODO comments pointing at the Phase 3 plan.
- **Do** run `pytest` and report the result at the end. If anything fails, fix it before reporting done.
- **Do** run the collector in dev mode at the end (`uv run studiod` or equivalent) and verify `curl http://127.0.0.1:8765/health` and one authenticated endpoint return the expected output. Report both outputs.
- **Do** write a short PR-notes block at the end: what was built, any decisions made that deviated from this plan (and why), anything the human should review before moving to Phase 2.

## Definition of done

- Repo structure matches the layout above
- `pyproject.toml` installs cleanly on Python 3.12
- `uv run pytest` (or `pytest`) passes, all tests green
- `uv run studiod` starts the collector, prints the dev token, serves on 127.0.0.1:8765
- `curl http://127.0.0.1:8765/health` returns 200 with `{"ok": true, ...}`
- `curl -H "Authorization: Bearer <token>" http://127.0.0.1:8765/stats` returns 200 with a valid `StatsResponse` JSON
- `README.md` covers dev mode usage
- Progress tracker in `docs/progress.md` updated: Phase 1 checkbox ticked, notes added under decisions log if any deviations happened
