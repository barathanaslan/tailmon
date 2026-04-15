"""Data collection source modules.

Each source is a small, testable wrapper around a system data source. They
are bundled into a :class:`Sources` container so that the FastAPI app factory
can inject fakes during tests.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol

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


class SystemSource(Protocol):
    def cpu_stats(self) -> CPUStats: ...
    def memory_stats(self) -> MemoryStats: ...
    def process_list(
        self,
        limit: int | None = None,
        *,
        include_full_cmdline: bool = False,
    ) -> tuple[list[ProcessInfo], int]: ...
    def listening_ports(self) -> list[PortInfo]: ...


class PowermetricsSource(Protocol):
    def sample(self) -> tuple[GPUStats | None, PowerStats | None]: ...


class TailscaleSource(Protocol):
    def peer_map(self) -> dict[str, TailscalePeer]: ...


class SSHSource(Protocol):
    def sessions(self, peer_map: dict[str, TailscalePeer]) -> list[SSHSession]: ...


class TmuxSource(Protocol):
    def sessions(self) -> list[TmuxSession]: ...


@dataclass
class Sources:
    system: SystemSource
    powermetrics: PowermetricsSource
    tailscale: TailscaleSource
    ssh: SSHSource
    tmux: TmuxSource
    extras: dict[str, object] = field(default_factory=dict)


def build_default_sources() -> Sources:
    """Construct the real-system sources used in production / dev mode."""
    from collector.sources.powermetrics import PowermetricsCollector
    from collector.sources.ssh_sessions import SSHCollector
    from collector.sources.system import SystemCollector
    from collector.sources.tailscale import TailscaleCollector
    from collector.sources.tmux import TmuxCollector

    return Sources(
        system=SystemCollector(),
        powermetrics=PowermetricsCollector(),
        tailscale=TailscaleCollector(),
        ssh=SSHCollector(),
        tmux=TmuxCollector(),
    )
