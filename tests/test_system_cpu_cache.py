"""Tests for the background CPU/process cache in SystemCollector (B2)."""

from __future__ import annotations

from datetime import datetime, timezone
from types import SimpleNamespace

import psutil

from collector.sources.system import SystemCollector
from shared.models import ProcessInfo


def _fake_psutil_process(pid: int, cpu: float, *, cmdline=None, name="proc"):
    """Build an object that quacks like psutil.Process() for process_iter."""
    info = {
        "pid": pid,
        "ppid": 1,
        "username": "core",
        "name": name,
        "cmdline": cmdline if cmdline is not None else [name],
        "cpu_percent": cpu,
        "memory_info": SimpleNamespace(rss=1024 * 1024),
        "memory_percent": 0.5,
        "status": "running",
        "create_time": 1_700_000_000.0,
    }
    stub = SimpleNamespace(info=info)
    stub.cpu_percent = lambda *a, **k: 0.0  # for the __init__ warm-up loop
    return stub


def test_background_false_allows_construction_without_thread(monkeypatch):
    collector = SystemCollector(background=False)
    assert collector._thread is None  # type: ignore[attr-defined]


def test_refresh_cpu_caches_per_process_cpu_percent(monkeypatch):
    """Calling _refresh_cpu twice should produce a cache the handler reads."""
    first_batch = [
        _fake_psutil_process(101, 12.5, name="worker"),
        _fake_psutil_process(202, 99.0, name="hotloop"),
    ]
    # Second batch: same pids, different CPU%.
    second_batch = [
        _fake_psutil_process(101, 25.0, name="worker"),
        _fake_psutil_process(202, 50.0, name="hotloop"),
    ]

    batches = iter([first_batch, first_batch, second_batch])

    def fake_process_iter(attrs=None):
        try:
            return iter(next(batches))
        except StopIteration:
            return iter(second_batch)

    monkeypatch.setattr(psutil, "process_iter", fake_process_iter)
    monkeypatch.setattr(psutil, "cpu_percent", lambda interval=None, percpu=False: [
        10.0, 20.0, 30.0, 40.0
    ] if percpu else 25.0)

    collector = SystemCollector(background=False)
    # __init__ already consumed one batch. Call refresh twice more.
    collector._refresh_cpu()
    collector._refresh_cpu()

    procs, total = collector.process_list()
    assert total == 2
    pid_to_cpu = {p.pid: p.cpu_percent for p in procs}
    assert pid_to_cpu[101] == 25.0
    assert pid_to_cpu[202] == 50.0


def test_cpu_stats_reads_from_cache(monkeypatch):
    def fake_process_iter(attrs=None):
        return iter([_fake_psutil_process(1, 1.0, name="init")])

    monkeypatch.setattr(psutil, "process_iter", fake_process_iter)
    monkeypatch.setattr(
        psutil,
        "cpu_percent",
        lambda interval=None, percpu=False: [11.0, 22.0] if percpu else 33.0,
    )

    collector = SystemCollector(background=False)
    collector._refresh_cpu()
    cpu = collector.cpu_stats()
    assert cpu.percent_total == 33.0
    assert cpu.percent_per_core == [11.0, 22.0]


def test_process_list_fallback_when_cache_empty(monkeypatch):
    """Cold path: cache is empty, process_list triggers a synchronous sample."""
    batch = [_fake_psutil_process(7, 7.5, name="early")]

    def fake_process_iter(attrs=None):
        return iter(batch)

    monkeypatch.setattr(psutil, "process_iter", fake_process_iter)
    monkeypatch.setattr(
        psutil,
        "cpu_percent",
        lambda interval=None, percpu=False: [0.0] if percpu else 0.0,
    )

    collector = SystemCollector(background=False)
    # Manually blow the cache away to simulate "right after __init__
    # before any refresh has happened".
    collector._cached_processes = None  # type: ignore[attr-defined]
    collector._cached_cpu_total = None  # type: ignore[attr-defined]
    collector._cached_cpu_percore = None  # type: ignore[attr-defined]

    procs, total = collector.process_list()
    assert total == 1
    assert procs[0].pid == 7


def test_process_list_redacts_cmdline_by_default(monkeypatch):
    """The Phase 1 secrets-in-cmdline guard must still apply via the cache."""
    batch = [
        _fake_psutil_process(
            101,
            1.0,
            name="curl",
            cmdline=["curl", "-H", "Authorization: Bearer SECRET", "http://x"],
        ),
    ]

    def fake_process_iter(attrs=None):
        return iter(batch)

    monkeypatch.setattr(psutil, "process_iter", fake_process_iter)
    monkeypatch.setattr(
        psutil,
        "cpu_percent",
        lambda interval=None, percpu=False: [0.0] if percpu else 0.0,
    )

    collector = SystemCollector(background=False)
    collector._refresh_cpu()
    procs, _ = collector.process_list()
    assert procs[0].cmdline == "curl"

    full, _ = collector.process_list(include_full_cmdline=True)
    assert "SECRET" in full[0].cmdline
