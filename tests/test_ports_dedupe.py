"""Tests for address-family dedupe in ports_from_connections (B3)."""

from __future__ import annotations

from types import SimpleNamespace

import psutil

from collector.sources.system import ports_from_connections


def _listen(ip: str, port: int, pid: int, proto: int = 1):
    return SimpleNamespace(
        laddr=SimpleNamespace(ip=ip, port=port),
        raddr=None,
        type=proto,
        status=psutil.CONN_LISTEN if proto == 1 else "NONE",
        pid=pid,
    )


def _same_resolver(pid):
    return ("sshd", "root")


def test_dedupe_collapses_v4_and_v6_for_same_port_and_process():
    conns = [
        _listen("0.0.0.0", 22, pid=100),
        _listen("::", 22, pid=100),
    ]
    out = ports_from_connections(conns, resolver=_same_resolver)
    assert len(out) == 1
    row = out[0]
    assert row.port == 22
    assert row.process_name == "sshd"
    assert row.address_families == ["v4", "v6"]


def test_dedupe_preserves_first_seen_address():
    conns = [
        _listen("::", 22, pid=100),
        _listen("0.0.0.0", 22, pid=100),
    ]
    out = ports_from_connections(conns, resolver=_same_resolver)
    assert len(out) == 1
    assert out[0].address == "::"
    # Insertion order preserved in the families list: v6 first, v4 second.
    assert out[0].address_families == ["v6", "v4"]


def test_dedupe_keeps_distinct_rows_when_pid_differs():
    conns = [
        _listen("0.0.0.0", 22, pid=100),
        _listen("::", 22, pid=200),
    ]
    out = ports_from_connections(conns, resolver=_same_resolver)
    # Different pids => different canonical rows; no collapse.
    assert len(out) == 2
    for p in out:
        assert p.address_families is None


def test_dedupe_leaves_single_family_rows_alone():
    conns = [
        _listen("0.0.0.0", 8765, pid=500),
    ]
    out = ports_from_connections(conns, resolver=lambda _: ("studiod", "root"))
    assert len(out) == 1
    # Single-family rows should keep the Phase 1/2 output shape.
    assert out[0].address_families is None


def test_dedupe_can_be_disabled():
    conns = [
        _listen("0.0.0.0", 22, pid=100),
        _listen("::", 22, pid=100),
    ]
    out = ports_from_connections(conns, resolver=_same_resolver, dedupe=False)
    # When dedupe is off the two rows survive separately.
    assert len(out) == 2


def test_ipv4_mapped_ipv6_classified_as_v4():
    conns = [
        _listen("0.0.0.0", 443, pid=300),
        _listen("::ffff:0.0.0.0", 443, pid=300),
    ]
    out = ports_from_connections(conns, resolver=lambda _: ("nginx", "root"))
    assert len(out) == 1
    # Both rows collapse and both are classified as v4 so families has
    # one unique entry -> the row keeps address_families=None.
    assert out[0].address_families is None
