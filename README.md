# studio-cli

A unified tool for monitoring and controlling a headless Mac Studio from a
MacBook over Tailscale. See [`docs/overview.md`](docs/overview.md) and
[`docs/architecture.md`](docs/architecture.md) for the long version.

This repo is being built in phases. Phase 1 (the current state) ships the
**collector daemon** with read-only endpoints, runnable locally on a MacBook
in dev mode. Phases 2-4 add deployment, a CLI, control endpoints, and a
SwiftUI menubar app.

## Running the collector in dev mode

Dev mode skips root-required features (`powermetrics`) gracefully and writes
a local bearer token file to the repo root.

```bash
uv sync --extra dev
STUDIOD_DEV_MODE=1 uv run studiod
```

On first start, a `.studiod-dev-token` file is generated in the current
working directory and the token is printed to stdout. Grab it — you'll need
it for every authenticated curl call.

The collector binds to `127.0.0.1:8765` by default. Override with
`STUDIOD_BIND_HOST` / `STUDIOD_BIND_PORT` if you need to.

## Hitting the endpoints

`/health` is unauthenticated. Everything else needs
`Authorization: Bearer <token>`.

```bash
TOKEN=$(cat .studiod-dev-token)

curl -s http://127.0.0.1:8765/health | jq
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/stats | jq
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/processes?limit=10 | jq
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/ports | jq
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/ssh/sessions | jq
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/tmux/sessions | jq
```

In dev mode (without root), `/stats` returns `gpu: null, power: null` — that
is expected. The Phase 2 deploy will run the collector as a launchd daemon
as root on the Mac Studio, at which point GPU and power stats populate.

## Tests

```bash
uv run pytest
```

The full test suite uses `fastapi.testclient.TestClient` and in-memory fake
data sources, so it doesn't touch `psutil`, `powermetrics`, `tailscale`, or
`tmux`.

## Layout

```
src/
  shared/     # pydantic models, token helpers, shared config
  collector/  # FastAPI daemon (routes, sources, auth, entry point)
tests/        # pytest suite with fakes for every data source
docs/         # architecture, plans, progress (shared state)
```
