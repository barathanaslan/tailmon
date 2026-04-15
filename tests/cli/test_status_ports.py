"""Tests for the B4 top-5-ports ordering logic in ``studio status``."""

from __future__ import annotations

import copy

from studio_cli.cli import cli
from studio_cli.commands.status import SYSTEM_WELL_KNOWN_PORTS, _split_system_ports

from tests.cli.conftest import PORTS_PAYLOAD


def test_split_system_ports_partitions_by_well_known():
    from shared.models import PortInfo

    rows = [
        PortInfo(protocol="tcp", address="0.0.0.0", port=22, pid=1, process_name="sshd", user="root"),
        PortInfo(protocol="tcp", address="127.0.0.1", port=8765, pid=2, process_name="studiod", user="core"),
        PortInfo(protocol="udp", address="0.0.0.0", port=5353, pid=3, process_name="mDNS", user="root"),
        PortInfo(protocol="tcp", address="0.0.0.0", port=3000, pid=4, process_name="node", user="core"),
    ]
    interesting, system = _split_system_ports(rows)
    assert [p.port for p in interesting] == [8765, 3000]
    assert [p.port for p in system] == [22, 5353]


def test_known_ports_set_covers_the_usual_noise():
    for port in (22, 53, 5353, 5355, 631, 123):
        assert port in SYSTEM_WELL_KNOWN_PORTS


def _set_ports_payload(set_route, new_payload):
    set_route("/ports", payload=new_payload)


def test_status_top5_ports_excludes_system_ports_when_plenty_available(
    runner, set_route,
):
    payload = copy.deepcopy(PORTS_PAYLOAD)
    payload["ports"] = [
        {"protocol": "tcp", "address": "0.0.0.0", "port": 22, "pid": 1, "process_name": "sshd", "user": "root"},
        {"protocol": "udp", "address": "0.0.0.0", "port": 5353, "pid": 2, "process_name": "mDNS", "user": "root"},
        {"protocol": "tcp", "address": "127.0.0.1", "port": 3000, "pid": 3, "process_name": "node", "user": "core"},
        {"protocol": "tcp", "address": "127.0.0.1", "port": 3100, "pid": 4, "process_name": "vite", "user": "core"},
        {"protocol": "tcp", "address": "127.0.0.1", "port": 4000, "pid": 5, "process_name": "api", "user": "core"},
        {"protocol": "tcp", "address": "127.0.0.1", "port": 5000, "pid": 6, "process_name": "flask", "user": "core"},
        {"protocol": "tcp", "address": "127.0.0.1", "port": 8765, "pid": 7, "process_name": "studiod", "user": "core"},
    ]
    _set_ports_payload(set_route, payload)

    result = runner.invoke(cli, ["status"])
    assert result.exit_code == 0, result.output
    # The five non-system ports all appear...
    for port_str in ("tcp/3000", "tcp/3100", "tcp/4000", "tcp/5000", "tcp/8765"):
        assert port_str in result.output
    # ...and the system ports do NOT appear in the top-5 body (they
    # should only contribute to the trailing +N counter).
    # We assert that the filter worked: neither port 22 nor 5353 is
    # rendered in the top-5 table region, which means the text "tcp/22 "
    # (with trailing space/process) should not appear. Allow "+N system"
    # footer to be present.
    assert "tcp/22   " not in result.output
    assert "udp/5353" not in result.output
    assert "system port" in result.output  # the "+N system port(s)" footer


def test_status_top5_backfills_system_ports_when_few_interesting(
    runner, set_route,
):
    payload = copy.deepcopy(PORTS_PAYLOAD)
    payload["ports"] = [
        {"protocol": "tcp", "address": "0.0.0.0", "port": 22, "pid": 1, "process_name": "sshd", "user": "root"},
        {"protocol": "udp", "address": "0.0.0.0", "port": 5353, "pid": 2, "process_name": "mDNS", "user": "root"},
        {"protocol": "tcp", "address": "127.0.0.1", "port": 8765, "pid": 3, "process_name": "studiod", "user": "core"},
    ]
    _set_ports_payload(set_route, payload)

    result = runner.invoke(cli, ["status"])
    assert result.exit_code == 0, result.output
    # With only one non-system port, backfill should show the system
    # ports so the view isn't empty.
    assert "tcp/8765" in result.output
    assert "tcp/22" in result.output
    assert "udp/5353" in result.output


def test_status_renders_family_tag_on_deduped_row(runner, set_route):
    payload = copy.deepcopy(PORTS_PAYLOAD)
    payload["ports"] = [
        {
            "protocol": "tcp",
            "address": "0.0.0.0",
            "port": 3000,
            "pid": 111,
            "process_name": "node",
            "user": "core",
            "address_families": ["v4", "v6"],
        },
    ]
    _set_ports_payload(set_route, payload)
    result = runner.invoke(cli, ["status"])
    assert result.exit_code == 0, result.output
    assert "tcp/3000" in result.output
    # Rich consumes the backslash escape so the final rendered output
    # carries the literal "[v4+v6]" bracket tag.
    assert "[v4+v6]" in result.output


def test_status_cached_memory_line_when_vmstat_fields_present(runner, set_route):
    """When the collector exposes the new memory fields, status shows a
    'Cached: N' hint line under the memory bar."""
    from tests.cli.conftest import STATS_PAYLOAD

    payload = copy.deepcopy(STATS_PAYLOAD)
    payload["memory"]["app_memory_bytes"] = 40 * 1024**3
    payload["memory"]["wired_bytes"] = 5 * 1024**3
    payload["memory"]["compressed_bytes"] = 1 * 1024**3
    payload["memory"]["cached_files_bytes"] = 12 * 1024**3
    set_route("/stats", payload=payload)

    result = runner.invoke(cli, ["status"])
    assert result.exit_code == 0, result.output
    assert "Cached:" in result.output
