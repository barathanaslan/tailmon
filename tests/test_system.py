"""Integration-ish tests for SystemCollector against the real psutil.

These don't require root; they just exercise the data shapes on whatever
machine the tests are running on (dev mode assumption).
"""

from __future__ import annotations

from collector.sources.system import SystemCollector, current_user


def test_cpu_stats_shape():
    coll = SystemCollector()
    cpu = coll.cpu_stats()
    assert 0.0 <= cpu.percent_total <= 100.0 * max(1, len(cpu.percent_per_core))
    assert len(cpu.percent_per_core) >= 1
    assert len(cpu.load_avg) == 3


def test_memory_stats_shape():
    coll = SystemCollector()
    mem = coll.memory_stats()
    assert mem.total_bytes > 0
    assert mem.used_bytes >= 0
    assert 0.0 <= mem.percent <= 100.0


def test_process_list_returns_sorted_and_respects_limit():
    coll = SystemCollector()
    procs, total = coll.process_list(limit=5)
    assert total >= len(procs)
    assert len(procs) <= 5
    # Sort order: cpu desc, then rss desc
    for a, b in zip(procs, procs[1:]):
        assert (-a.cpu_percent, -a.memory_rss_bytes) <= (
            -b.cpu_percent,
            -b.memory_rss_bytes,
        )


def test_process_list_zero_limit():
    coll = SystemCollector()
    procs, total = coll.process_list(limit=0)
    assert procs == []
    assert total > 0


def test_process_list_no_limit():
    coll = SystemCollector()
    procs, total = coll.process_list(limit=None)
    assert len(procs) == total


def test_listening_ports_shape():
    coll = SystemCollector()
    ports = coll.listening_ports()
    # We can't guarantee any particular port is listening, but the call must
    # succeed and return the expected shape.
    for p in ports:
        assert p.protocol in ("tcp", "udp")
        assert 0 < p.port < 65536


def test_current_user_returns_non_empty():
    user = current_user()
    assert isinstance(user, str)
    assert len(user) > 0
