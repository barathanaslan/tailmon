"""Tests for ``studio sessions``."""

from __future__ import annotations

from studio_cli.cli import cli


def test_sessions_happy_path(runner, patched_client) -> None:
    result = runner.invoke(cli, ["sessions"])
    assert result.exit_code == 0, result.output
    assert "main" in result.output
    assert "dev" in result.output
    assert "attached" in result.output
    assert "detached" in result.output


def test_sessions_empty(runner, set_route) -> None:
    set_route(
        "/tmux/sessions",
        payload={"sessions": [], "sampled_at": "2026-04-15T12:00:00+00:00"},
    )
    result = runner.invoke(cli, ["sessions"])
    assert result.exit_code == 0
    assert "No tmux sessions" in result.output
