"""Fixtures for the CLI test suite.

The strategy: build a real :class:`studio_cli.client.StudioClient` whose
underlying httpx Client is wired to a :class:`httpx.MockTransport` that
returns canned JSON for each collector endpoint. Then monkeypatch the
``StudioClient`` constructor inside each command module so the production
``load_config`` / ``load_token`` code path is exercised end-to-end and
tests still use the mock transport.

We can't simply patch ``httpx.Client`` globally because rich + click also
use the network in some tests, so the cleanest seam is to swap the whole
``StudioClient`` factory.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import httpx
import pytest
from click.testing import CliRunner

from studio_cli import client as client_module
from studio_cli.client import StudioClient
from studio_cli.config import ClientConfig

# ---------- canned response payloads ----------

NOW_ISO = "2026-04-15T12:00:00+00:00"

STATS_PAYLOAD = {
    "cpu": {
        "percent_total": 21.5,
        "percent_per_core": [10.0, 22.0, 33.0, 21.0],
        "load_avg": [0.5, 0.7, 1.1],
    },
    "memory": {
        "total_bytes": 64 * 1024**3,
        "used_bytes": 24 * 1024**3,
        "available_bytes": 40 * 1024**3,
        "percent": 37.5,
        "swap_used_bytes": 0,
        "swap_total_bytes": 2 * 1024**3,
    },
    "gpu": {"percent": 42.0, "frequency_mhz": 1398.0},
    "power": {
        "cpu_package_watts": 4.2,
        "gpu_watts": 6.8,
        "total_watts": 12.0,
    },
    "timestamp": NOW_ISO,
}

PROCESSES_PAYLOAD = {
    "processes": [
        {
            "pid": 4242,
            "ppid": 1,
            "user": "core",
            "name": "python",
            "cmdline": "python",
            "cpu_percent": 88.5,
            "memory_rss_bytes": 512 * 1024**2,
            "memory_percent": 12.4,
            "status": "running",
            "create_time": NOW_ISO,
        },
        {
            "pid": 1,
            "ppid": 0,
            "user": "root",
            "name": "launchd",
            "cmdline": "/sbin/launchd",
            "cpu_percent": 0.0,
            "memory_rss_bytes": 5 * 1024**2,
            "memory_percent": 0.1,
            "status": "running",
            "create_time": NOW_ISO,
        },
    ],
    "total_count": 2,
    "sampled_at": NOW_ISO,
}

PORTS_PAYLOAD = {
    "ports": [
        {
            "protocol": "tcp",
            "address": "0.0.0.0",
            "port": 22,
            "pid": 1001,
            "process_name": "sshd",
            "user": "root",
        },
        {
            "protocol": "tcp",
            "address": "127.0.0.1",
            "port": 8765,
            "pid": 9000,
            "process_name": "studiod",
            "user": "core",
        },
    ],
    "sampled_at": NOW_ISO,
}

SSH_PAYLOAD = {
    "sessions": [
        {
            "pid": 1101,
            "user": "core",
            "source_ip": "100.64.0.2",
            "source_port": 51234,
            "tailscale_peer": {
                "hostname": "macbook-air",
                "tailscale_ip": "100.64.0.2",
                "os": "macOS",
                "user_display_name": "Core Operator",
            },
            "tty": "pts/0",
            "started_at": NOW_ISO,
            "idle_seconds": 3.0,
        },
    ],
    "sampled_at": NOW_ISO,
}

TMUX_PAYLOAD = {
    "sessions": [
        {
            "name": "main",
            "windows": 3,
            "attached": True,
            "created_at": NOW_ISO,
        },
        {
            "name": "dev",
            "windows": 1,
            "attached": False,
            "created_at": NOW_ISO,
        },
    ],
    "sampled_at": NOW_ISO,
}

HEALTH_PAYLOAD = {"ok": True, "version": "0.1.0", "uptime_seconds": 1.234}

# Default write-side payloads for the Phase 3 POST endpoints. Tests override
# these via the ``set_route`` fixture when they need to assert on refusals.
KILL_PAYLOAD = {
    "pid": 4242,
    "signal": 15,
    "process_name": "python",
    "user": "core",
    "sent_at": NOW_ISO,
}

SSH_KICK_PAYLOAD = {
    "session": SSH_PAYLOAD["sessions"][0],
    "sent_at": NOW_ISO,
}

TMUX_NEW_PAYLOAD = {
    "name": "alpha",
    "created": True,
    "exists": False,
}

# A registry the mock transport handler reads from; tests can override.
ROUTES: dict[str, object] = {
    "/health": HEALTH_PAYLOAD,
    "/stats": STATS_PAYLOAD,
    "/processes": PROCESSES_PAYLOAD,
    "/ports": PORTS_PAYLOAD,
    "/ssh/sessions": SSH_PAYLOAD,
    "/tmux/sessions": TMUX_PAYLOAD,
    "/kill": KILL_PAYLOAD,
    "/ssh/kick": SSH_KICK_PAYLOAD,
    "/tmux/new": TMUX_NEW_PAYLOAD,
}


def _default_handler(request: httpx.Request) -> httpx.Response:
    payload = ROUTES.get(request.url.path)
    if payload is None:
        return httpx.Response(404, json={"error": "not found"})
    return httpx.Response(200, json=payload)


# ---------- fixtures ----------


@pytest.fixture
def fake_token_file(tmp_path: Path) -> Path:
    p = tmp_path / "token"
    p.write_text("dummy-token-for-tests\n")
    p.chmod(0o600)
    return p


@pytest.fixture
def fake_config(tmp_path: Path, fake_token_file: Path) -> ClientConfig:
    return ClientConfig(
        collector_url="http://test.invalid:8765",
        token_file=fake_token_file,
        timeout_seconds=2.0,
        ssh_host="macstudio-test",
        config_file=None,
        token_override=None,
    )


@pytest.fixture
def env_overrides(monkeypatch: pytest.MonkeyPatch, fake_token_file: Path) -> dict[str, str]:
    """Set the env vars the CLI's load_config reads, so subcommands talk to
    our mock-backed client instead of the real Mac Studio."""
    monkeypatch.setenv("STUDIO_COLLECTOR_URL", "http://test.invalid:8765")
    monkeypatch.setenv("STUDIO_TOKEN_FILE", str(fake_token_file))
    monkeypatch.setenv("STUDIO_TIMEOUT", "2.0")
    monkeypatch.setenv("STUDIO_SSH_HOST", "macstudio-test")
    monkeypatch.setenv("STUDIO_CONFIG_FILE", str(fake_token_file.parent / "no-such.toml"))
    return {}


@pytest.fixture
def patched_client(monkeypatch: pytest.MonkeyPatch, env_overrides):
    """Patch StudioClient so every instance uses a MockTransport.

    The patch wraps the real constructor and just injects the transport
    keyword arg. All routing logic, header construction, and error mapping
    in :class:`StudioClient` therefore stays under test.
    """
    real_init = StudioClient.__init__

    def patched_init(self, cfg, token, *, transport=None):
        if transport is None:
            transport = httpx.MockTransport(_default_handler)
        real_init(self, cfg, token, transport=transport)

    monkeypatch.setattr(client_module.StudioClient, "__init__", patched_init)
    yield


@pytest.fixture
def runner() -> CliRunner:
    # click 8.3 dropped mix_stderr from CliRunner.__init__; stderr is now
    # always merged into result.output. Tests that need to assert on errors
    # just check result.output (which is what existed in older click as
    # the merged stream when mix_stderr=True).
    return CliRunner()


# ---------- helpers exposed to tests ----------


@pytest.fixture
def set_route(monkeypatch: pytest.MonkeyPatch, env_overrides):
    """Tests can use this to override one route's response or status code.

    Usage::

        set_route("/stats", status=500)
        set_route("/ports", payload={...})
    """
    overrides: dict[str, tuple[int, object]] = {}

    def setter(path: str, payload: object | None = None, status: int = 200) -> None:
        overrides[path] = (status, payload if payload is not None else ROUTES.get(path))

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path in overrides:
            status, payload = overrides[request.url.path]
            if isinstance(payload, (dict, list)):
                return httpx.Response(status, json=payload)
            return httpx.Response(status, content=str(payload).encode())
        return _default_handler(request)

    real_init = StudioClient.__init__

    def patched_init(self, cfg, token, *, transport=None):
        real_init(self, cfg, token, transport=httpx.MockTransport(handler))

    monkeypatch.setattr(client_module.StudioClient, "__init__", patched_init)
    yield setter
