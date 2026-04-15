"""Pydantic v2 models for every API response.

Source of truth for the JSON schema that the CLI and (later) SwiftUI menubar
app will consume.
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


# ---------- /health ----------


class HealthResponse(BaseModel):
    ok: bool
    version: str
    uptime_seconds: float


# ---------- /stats ----------


class CPUStats(BaseModel):
    percent_total: float
    percent_per_core: list[float]
    load_avg: tuple[float, float, float]


class MemoryStats(BaseModel):
    total_bytes: int
    used_bytes: int
    available_bytes: int
    percent: float
    swap_used_bytes: int
    swap_total_bytes: int
    # Activity Monitor-style macOS breakdown. None on non-Darwin or when
    # vm_stat is unavailable / fails to parse; existing fields above are
    # always populated from psutil so clients get a valid response either
    # way. Backwards compatible with Phase 1/2 clients.
    app_memory_bytes: int | None = None
    wired_bytes: int | None = None
    compressed_bytes: int | None = None
    cached_files_bytes: int | None = None


class GPUStats(BaseModel):
    percent: float
    frequency_mhz: float | None = None


class PowerStats(BaseModel):
    cpu_package_watts: float
    gpu_watts: float
    total_watts: float


class StatsResponse(BaseModel):
    cpu: CPUStats
    memory: MemoryStats
    gpu: GPUStats | None = None
    power: PowerStats | None = None
    timestamp: datetime


# ---------- /processes ----------


class ProcessInfo(BaseModel):
    pid: int
    ppid: int
    user: str
    name: str
    cmdline: str
    cpu_percent: float
    memory_rss_bytes: int
    memory_percent: float
    status: str
    create_time: datetime


class ProcessListResponse(BaseModel):
    processes: list[ProcessInfo]
    total_count: int
    sampled_at: datetime


# ---------- /ports ----------


class PortInfo(BaseModel):
    protocol: Literal["tcp", "udp"]
    address: str
    port: int
    pid: int | None = None
    process_name: str | None = None
    user: str | None = None
    # When multiple address-family rows have been collapsed into one
    # (e.g. sshd bound to both 0.0.0.0:22 and :::22), record which
    # families were observed so the renderer can show "[v4+v6]". None
    # for backwards compatibility with Phase 1/2 clients and for non-
    # deduplicated / single-family rows.
    address_families: list[str] | None = None


class PortListResponse(BaseModel):
    ports: list[PortInfo]
    sampled_at: datetime


# ---------- /ssh/sessions ----------


class TailscalePeer(BaseModel):
    hostname: str
    tailscale_ip: str
    os: str | None = None
    user_display_name: str | None = None


class SSHSession(BaseModel):
    pid: int
    user: str
    source_ip: str
    source_port: int
    tailscale_peer: TailscalePeer | None = None
    tty: str | None = None
    started_at: datetime
    idle_seconds: float | None = None


class SSHSessionListResponse(BaseModel):
    sessions: list[SSHSession]
    sampled_at: datetime


# ---------- /tmux/sessions ----------


class TmuxSession(BaseModel):
    name: str
    windows: int
    attached: bool
    created_at: datetime | None = None


class TmuxSessionListResponse(BaseModel):
    sessions: list[TmuxSession]
    sampled_at: datetime


# ---------- generic error envelope ----------


class ErrorResponse(BaseModel):
    error: str
    detail: str | None = Field(default=None)
