"""Tests for ``studio stats``."""

from __future__ import annotations

import json

from studio_cli.cli import cli


def test_stats_pretty(runner, patched_client) -> None:
    result = runner.invoke(cli, ["stats"])
    assert result.exit_code == 0, result.output
    assert "CPU" in result.output
    assert "Memory" in result.output
    assert "GPU" in result.output
    assert "Power" in result.output


def test_stats_json(runner, patched_client) -> None:
    result = runner.invoke(cli, ["stats", "--json"])
    assert result.exit_code == 0, result.output
    # Find the JSON payload in the output. rich.print_json renders with
    # indentation, so we just check that the structure is parseable when
    # we strip rich color codes.
    raw = result.output.strip()
    # Find the first '{' and parse from there.
    start = raw.find("{")
    parsed = json.loads(raw[start:])
    assert "cpu" in parsed
    assert "memory" in parsed


def test_stats_handles_missing_gpu(runner, set_route) -> None:
    set_route(
        "/stats",
        payload={
            "cpu": {
                "percent_total": 5.0,
                "percent_per_core": [5.0],
                "load_avg": [0.1, 0.1, 0.1],
            },
            "memory": {
                "total_bytes": 1024,
                "used_bytes": 512,
                "available_bytes": 512,
                "percent": 50.0,
                "swap_used_bytes": 0,
                "swap_total_bytes": 0,
            },
            "gpu": None,
            "power": None,
            "timestamp": "2026-04-15T12:00:00+00:00",
        },
    )
    result = runner.invoke(cli, ["stats"])
    assert result.exit_code == 0
