"""Integration tests for ``SystemCollector.memory_stats`` with vm_stat (B1)."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import psutil

from collector.sources.memory_macos import VmStatCollector, VmStatSample, parse_vm_stat
from collector.sources.system import SystemCollector

FIXTURE = Path(__file__).parent / "fixtures" / "vm_stat_sample.txt"


class _FakeVmStat(VmStatCollector):
    def __init__(self, sample: VmStatSample | None):
        super().__init__(cmd=["/bin/true"], cache_ttl=0.0)
        self._fixed = sample

    def sample(self) -> VmStatSample | None:  # type: ignore[override]
        return self._fixed


def _stub_psutil_total(monkeypatch, total_bytes: int) -> None:
    real_vm = psutil.virtual_memory
    real_sw = psutil.swap_memory

    def fake_vm():
        v = real_vm()
        return SimpleNamespace(
            total=total_bytes,
            used=v.used,
            available=v.available,
            percent=v.percent,
            free=v.free,
            active=getattr(v, "active", 0),
            inactive=getattr(v, "inactive", 0),
            wired=getattr(v, "wired", 0),
        )

    def fake_sw():
        return real_sw()

    monkeypatch.setattr(psutil, "virtual_memory", fake_vm)
    monkeypatch.setattr(psutil, "swap_memory", fake_sw)


def test_memory_stats_uses_activity_monitor_accounting(monkeypatch):
    """The real captured sample should produce ~53% used, not ~33%."""
    sample = parse_vm_stat(FIXTURE.read_text())
    assert sample is not None

    # 96 GB total, matching the fixture capture context.
    total_bytes = 96 * 1024**3
    _stub_psutil_total(monkeypatch, total_bytes)

    collector = SystemCollector(background=False, vm_stat=_FakeVmStat(sample))
    mem = collector.memory_stats()

    used_expected = sample.anonymous + sample.wired + sample.compressed
    assert mem.used_bytes == used_expected
    assert mem.total_bytes == total_bytes
    # With total == 96 GiB and used == ~47.7 GiB the Activity Monitor
    # style percent lands near 49-50%. This is still a ~17 pp jump
    # above the old psutil-flavoured ~33% reading on the same machine,
    # which is the bug B1 exists to fix.
    assert 48.0 <= mem.percent <= 52.0
    assert mem.app_memory_bytes == sample.anonymous
    assert mem.wired_bytes == sample.wired
    assert mem.compressed_bytes == sample.compressed
    assert mem.cached_files_bytes == sample.file_backed + sample.speculative


def test_memory_stats_available_is_reclaimable_only(monkeypatch):
    sample = parse_vm_stat(FIXTURE.read_text())
    assert sample is not None

    _stub_psutil_total(monkeypatch, 96 * 1024**3)
    collector = SystemCollector(background=False, vm_stat=_FakeVmStat(sample))
    mem = collector.memory_stats()

    expected_available = (
        sample.free + sample.file_backed + sample.speculative + sample.purgeable
    )
    assert mem.available_bytes == expected_available


def test_memory_stats_falls_back_to_psutil_when_vm_stat_none():
    collector = SystemCollector(background=False, vm_stat=_FakeVmStat(None))
    mem = collector.memory_stats()

    # Fallback path: the new optional fields stay None (degraded mode).
    assert mem.app_memory_bytes is None
    assert mem.wired_bytes is None
    assert mem.compressed_bytes is None
    assert mem.cached_files_bytes is None
    # Core fields still populated from psutil so /stats stays usable.
    assert mem.total_bytes > 0
    assert 0.0 <= mem.percent <= 100.0
