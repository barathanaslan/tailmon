"""Tests for the vm_stat-based macOS memory source (B1)."""

from __future__ import annotations

from pathlib import Path

import pytest

from collector.sources.memory_macos import (
    VmStatCollector,
    VmStatSample,
    parse_vm_stat,
)

FIXTURE = Path(__file__).parent / "fixtures" / "vm_stat_sample.txt"


# ---------- parser: happy path ----------


def test_parse_vm_stat_fixture_has_page_size_16384():
    text = FIXTURE.read_text()
    sample = parse_vm_stat(text)
    assert sample is not None
    assert sample.page_size == 16384


def test_parse_vm_stat_fixture_field_bytes_match_expected():
    """Sanity-check the math on the real captured sample.

    The page values in the fixture come from a live `vm_stat` run on the
    Mac Studio during Phase 2b (see docs/progress.md). The expected byte
    counts below are therefore fixed numbers we can assert on exactly.
    """
    text = FIXTURE.read_text()
    sample = parse_vm_stat(text)
    assert sample is not None
    ps = 16384
    assert sample.free == 2453686 * ps
    assert sample.active == 1715997 * ps
    assert sample.inactive == 1706518 * ps
    assert sample.speculative == 35181 * ps
    assert sample.wired == 321922 * ps
    assert sample.purgeable == 29393 * ps
    assert sample.compressed == 610 * ps
    assert sample.file_backed == 651864 * ps
    assert sample.anonymous == 2805832 * ps


def test_parse_vm_stat_yields_activity_monitor_style_used_bytes():
    """Activity Monitor used = anonymous + wired + compressed.

    On the captured sample that lands around 51.25 GB, which is ~53% of
    a 96 GB total. This is the behavior B1 is meant to restore.
    """
    text = FIXTURE.read_text()
    sample = parse_vm_stat(text)
    assert sample is not None
    used = sample.anonymous + sample.wired + sample.compressed
    assert used == (2805832 + 321922 + 610) * 16384
    # ~51.25 decimal GB == ~47.7 GiB. Use GiB to match `/ 1024**3`.
    gib = used / 1024**3
    assert 47.0 <= gib <= 48.5


def test_parse_vm_stat_fallback_page_size_4096():
    """Intel Macs report a 4096-byte page size; the parser must honor it."""
    text = (
        "Mach Virtual Memory Statistics: (page size of 4096 bytes)\n"
        "Pages free:                              1000.\n"
        "Pages active:                            2000.\n"
        "Pages inactive:                          3000.\n"
        "Pages speculative:                         50.\n"
        "Pages wired down:                         500.\n"
        "Pages purgeable:                          100.\n"
        "Pages occupied by compressor:              10.\n"
        "File-backed pages:                        900.\n"
        "Anonymous pages:                         4100.\n"
    )
    sample = parse_vm_stat(text)
    assert sample is not None
    assert sample.page_size == 4096
    assert sample.free == 1000 * 4096
    assert sample.wired == 500 * 4096


# ---------- parser: sad path ----------


def test_parse_vm_stat_returns_none_when_header_missing():
    # No "page size of N bytes" header at all.
    text = (
        "Pages free: 1000.\n"
        "Pages active: 2000.\n"
    )
    assert parse_vm_stat(text) is None


def test_parse_vm_stat_returns_none_when_required_field_missing():
    text = (
        "Mach Virtual Memory Statistics: (page size of 16384 bytes)\n"
        "Pages free:                              1000.\n"
        # Missing Pages active, inactive, wired, ...
    )
    assert parse_vm_stat(text) is None


def test_parse_vm_stat_returns_none_when_empty():
    assert parse_vm_stat("") is None


# ---------- VmStatCollector: subprocess-free wiring via stub cmd ----------


class _StubCollector(VmStatCollector):
    """Inject a preset text output without going through subprocess."""

    def __init__(self, text: str | None):
        super().__init__(cmd=["/bin/true"], cache_ttl=0.0)
        self._stub_text = text

    def _fetch_uncached(self) -> VmStatSample | None:  # type: ignore[override]
        if self._stub_text is None:
            return None
        return parse_vm_stat(self._stub_text)


def test_vm_stat_collector_sample_returns_parsed_sample():
    text = FIXTURE.read_text()
    collector = _StubCollector(text)
    sample = collector.sample()
    assert isinstance(sample, VmStatSample)
    assert sample.page_size == 16384


def test_vm_stat_collector_returns_none_on_binary_unavailable():
    collector = VmStatCollector(cmd=None)
    assert collector.sample() is None
    # Second call should also be None and should not raise.
    assert collector.sample() is None


def test_vm_stat_collector_caches_within_ttl():
    calls = {"n": 0}
    text = FIXTURE.read_text()

    class _CountingCollector(VmStatCollector):
        def __init__(self):
            super().__init__(cmd=["/bin/true"], cache_ttl=60.0)

        def _fetch_uncached(self):  # type: ignore[override]
            calls["n"] += 1
            return parse_vm_stat(text)

    c = _CountingCollector()
    c.sample()
    c.sample()
    c.sample()
    assert calls["n"] == 1, "cache should suppress repeated subprocess calls"
