"""Shared pytest fixtures and fakes for studio-cli."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from collector.app import create_app
from collector.audit import AuditLogger
from collector.sources import Sources
from shared.models import (
    CPUStats,
    GPUStats,
    MemoryStats,
    PortInfo,
    PowerStats,
    ProcessInfo,
    SSHSession,
    TailscalePeer,
    TmuxSession,
)

FIXTURE_DIR = Path(__file__).parent / "fixtures"
TEST_TOKEN = "unit-test-token"  # noqa: S105


# ---------- data source fakes ----------


@dataclass
class FakeSystem:
    cpu: CPUStats = field(
        default_factory=lambda: CPUStats(
            percent_total=21.5,
            percent_per_core=[10.0, 22.0, 33.0, 21.0],
            load_avg=(0.5, 0.7, 1.1),
        )
    )
    memory: MemoryStats = field(
        default_factory=lambda: MemoryStats(
            total_bytes=64 * 1024**3,
            used_bytes=24 * 1024**3,
            available_bytes=40 * 1024**3,
            percent=37.5,
            swap_used_bytes=0,
            swap_total_bytes=2 * 1024**3,
        )
    )
    processes: list[ProcessInfo] = field(
        default_factory=lambda: [
            ProcessInfo(
                pid=1,
                ppid=0,
                user="root",
                name="launchd",
                cmdline="/sbin/launchd",
                cpu_percent=0.0,
                memory_rss_bytes=5 * 1024**2,
                memory_percent=0.1,
                status="running",
                create_time=datetime(2026, 4, 15, 12, 0, tzinfo=timezone.utc),
            ),
            ProcessInfo(
                pid=4242,
                ppid=1,
                user="core",
                name="python",
                cmdline="python worker.py",
                cpu_percent=88.5,
                memory_rss_bytes=512 * 1024**2,
                memory_percent=12.4,
                status="running",
                create_time=datetime(2026, 4, 15, 12, 30, tzinfo=timezone.utc),
            ),
        ]
    )
    ports: list[PortInfo] = field(
        default_factory=lambda: [
            PortInfo(
                protocol="tcp",
                address="0.0.0.0",
                port=22,
                pid=1001,
                process_name="sshd",
                user="root",
            ),
            PortInfo(
                protocol="tcp",
                address="127.0.0.1",
                port=8765,
                pid=9000,
                process_name="studiod",
                user="core",
            ),
        ]
    )

    def cpu_stats(self) -> CPUStats:
        return self.cpu

    def memory_stats(self) -> MemoryStats:
        return self.memory

    def process_list(
        self,
        limit: int | None = None,
        *,
        include_full_cmdline: bool = False,
    ) -> tuple[list[ProcessInfo], int]:
        data = list(self.processes)
        data.sort(key=lambda p: (-p.cpu_percent, -p.memory_rss_bytes, p.pid))
        total = len(data)
        if limit is not None:
            data = data[: max(0, limit)]
        # The fake holds pre-built ProcessInfo objects whose cmdline field
        # is already decided by the test author. When include_full_cmdline
        # is False (the default in prod), we reduce the cmdline to argv[0]
        # (first whitespace-split token) to mirror SystemCollector behavior
        # -- tests that need the full string can opt in.
        if not include_full_cmdline:
            redacted: list[ProcessInfo] = []
            for p in data:
                first = p.cmdline.split(" ", 1)[0] if p.cmdline else ""
                redacted.append(p.model_copy(update={"cmdline": first}))
            data = redacted
        return data, total

    def listening_ports(self) -> list[PortInfo]:
        return list(self.ports)


@dataclass
class FakePowermetrics:
    gpu: GPUStats | None = field(
        default_factory=lambda: GPUStats(percent=42.0, frequency_mhz=1398.0)
    )
    power: PowerStats | None = field(
        default_factory=lambda: PowerStats(
            cpu_package_watts=4.2,
            gpu_watts=6.8,
            total_watts=12.0,
        )
    )

    def sample(self) -> tuple[GPUStats | None, PowerStats | None]:
        return self.gpu, self.power


@dataclass
class FakeTailscale:
    peers: dict[str, TailscalePeer] = field(
        default_factory=lambda: {
            "100.64.0.2": TailscalePeer(
                hostname="macbook-air",
                tailscale_ip="100.64.0.2",
                os="macOS",
                user_display_name="Core Operator",
            ),
        }
    )

    def peer_map(self) -> dict[str, TailscalePeer]:
        return dict(self.peers)


@dataclass
class FakeSSH:
    sessions_list: list[SSHSession] = field(default_factory=list)

    def sessions(self, peer_map: dict[str, TailscalePeer]) -> list[SSHSession]:
        # Apply peer labeling from the live map so tests can cover it.
        out: list[SSHSession] = []
        for s in self.sessions_list:
            labeled = s.model_copy(update={"tailscale_peer": peer_map.get(s.source_ip)})
            out.append(labeled)
        return out


@dataclass
class FakeTmux:
    sessions_list: list[TmuxSession] = field(default_factory=list)

    def sessions(self) -> list[TmuxSession]:
        return list(self.sessions_list)


# ---------- pytest fixtures ----------


@pytest.fixture
def fake_sources() -> Sources:
    return Sources(
        system=FakeSystem(),
        powermetrics=FakePowermetrics(),
        tailscale=FakeTailscale(),
        ssh=FakeSSH(
            sessions_list=[
                SSHSession(
                    pid=1101,
                    user="core",
                    source_ip="100.64.0.2",
                    source_port=51234,
                    tailscale_peer=None,
                    tty="pts/0",
                    started_at=datetime(2026, 4, 15, 12, 0, tzinfo=timezone.utc),
                    idle_seconds=3.0,
                ),
                SSHSession(
                    pid=1201,
                    user="friend",
                    source_ip="203.0.113.9",
                    source_port=44321,
                    tailscale_peer=None,
                    tty="pts/1",
                    started_at=datetime(2026, 4, 15, 12, 5, tzinfo=timezone.utc),
                    idle_seconds=None,
                ),
            ],
        ),
        tmux=FakeTmux(
            sessions_list=[
                TmuxSession(
                    name="main",
                    windows=3,
                    attached=True,
                    created_at=datetime(2026, 4, 15, 11, 0, tzinfo=timezone.utc),
                ),
            ],
        ),
    )


@pytest.fixture
def audit_logger(tmp_path: Path) -> AuditLogger:
    return AuditLogger(tmp_path / "audit.log", mode=0o600)


@pytest.fixture
def app(fake_sources, audit_logger):
    return create_app(
        token=TEST_TOKEN, sources=fake_sources, audit=audit_logger
    )


@pytest.fixture
def client(app) -> TestClient:
    return TestClient(app)


@pytest.fixture
def auth_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {TEST_TOKEN}"}


# ---------- fixture loaders ----------


@pytest.fixture
def tailscale_fixture_data() -> dict:
    return json.loads((FIXTURE_DIR / "tailscale_status.json").read_text())


@pytest.fixture
def powermetrics_fixture_bytes() -> bytes:
    return (FIXTURE_DIR / "powermetrics_sample.txt").read_bytes()


@pytest.fixture
def sshd_fixture_processes() -> list[SimpleNamespace]:
    data = json.loads((FIXTURE_DIR / "sshd_processes.json").read_text())
    out: list[SimpleNamespace] = []
    for entry in data:
        conns = [
            SimpleNamespace(
                raddr=SimpleNamespace(ip=c["raddr_ip"], port=c["raddr_port"])
                if c.get("raddr_ip")
                else None,
            )
            for c in entry.get("connections", [])
        ]
        info = dict(entry)
        info["connections"] = conns
        out.append(SimpleNamespace(info=info))
    return out
