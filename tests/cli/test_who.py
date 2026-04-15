"""Tests for ``studio who``."""

from __future__ import annotations

from studio_cli.cli import cli


def test_who_happy_path(runner, patched_client) -> None:
    result = runner.invoke(cli, ["who"])
    assert result.exit_code == 0, result.output
    assert "SSH sessions" in result.output
    assert "macbook-air" in result.output  # tailscale peer hostname
    assert "100.64.0.2" in result.output


def test_who_empty(runner, set_route) -> None:
    set_route("/ssh/sessions", payload={"sessions": [], "sampled_at": "2026-04-15T12:00:00+00:00"})
    result = runner.invoke(cli, ["who"])
    assert result.exit_code == 0
    assert "No active SSH sessions" in result.output
