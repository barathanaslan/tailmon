"""Tests for ``studio kick``."""

from __future__ import annotations

from studio_cli.cli import cli


def test_kick_happy_path_with_yes(runner, patched_client) -> None:
    result = runner.invoke(cli, ["kick", "1101", "--yes"])
    assert result.exit_code == 0, result.output
    assert "kicked" in result.output
    assert "100.64.0.2" in result.output


def test_kick_prompt_accepts_yes(runner, patched_client) -> None:
    result = runner.invoke(cli, ["kick", "1101"], input="y\n")
    assert result.exit_code == 0, result.output
    assert "kicked" in result.output


def test_kick_prompt_aborts_on_no(runner, patched_client) -> None:
    result = runner.invoke(cli, ["kick", "1101"], input="n\n")
    assert result.exit_code == 1
    assert "aborted" in result.output.lower()


def test_kick_surfaces_403(runner, set_route) -> None:
    set_route(
        "/ssh/kick",
        payload={"detail": "refusing to kick your own session"},
        status=403,
    )
    result = runner.invoke(cli, ["kick", "1101", "--yes"])
    assert result.exit_code == 1
    assert "own session" in result.output


def test_kick_requires_pid(runner) -> None:
    result = runner.invoke(cli, ["kick"])
    assert result.exit_code != 0


def test_kick_is_reserved_name_not_tmux_fallback(runner, patched_client) -> None:
    """``studio kick`` must not be swallowed by the tmux bareword dispatch."""
    result = runner.invoke(cli, ["kick"])
    assert result.exit_code != 0
    assert "Usage" in result.output or "PID" in result.output or "pid" in result.output
