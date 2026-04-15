"""Tests for ``studio kill``."""

from __future__ import annotations

import pytest

from studio_cli.cli import cli


def test_kill_happy_path_with_yes(runner, patched_client) -> None:
    result = runner.invoke(cli, ["kill", "4242", "--yes"])
    assert result.exit_code == 0, result.output
    assert "killed" in result.output
    assert "SIGTERM" in result.output
    assert "python" in result.output


def test_kill_signal_alias_maps_to_9(runner, patched_client) -> None:
    result = runner.invoke(cli, ["kill", "4242", "--yes", "--kill"])
    assert result.exit_code == 0, result.output
    assert "SIGKILL" in result.output


def test_kill_explicit_signal_option(runner, patched_client) -> None:
    result = runner.invoke(cli, ["kill", "4242", "--yes", "--signal", "1"])
    assert result.exit_code == 0, result.output
    assert "SIGHUP" in result.output


def test_kill_confirmation_prompt_accepts_yes(runner, patched_client) -> None:
    result = runner.invoke(cli, ["kill", "4242"], input="y\n")
    assert result.exit_code == 0, result.output
    assert "Kill" in result.output
    assert "python" in result.output


def test_kill_confirmation_prompt_aborts_on_no(runner, patched_client) -> None:
    result = runner.invoke(cli, ["kill", "4242"], input="n\n")
    assert result.exit_code == 1
    assert "aborted" in result.output.lower()


def test_kill_surfaces_403_error(runner, set_route) -> None:
    set_route("/kill", payload={"detail": "refusing to signal launchd"}, status=403)
    result = runner.invoke(cli, ["kill", "1", "--yes"])
    assert result.exit_code == 1
    assert "launchd" in result.output


def test_kill_requires_positive_pid(runner, patched_client) -> None:
    result = runner.invoke(cli, ["kill", "0", "--yes"])
    assert result.exit_code != 0


def test_kill_is_reserved_name_not_tmux_fallback(runner, patched_client) -> None:
    """``studio kill`` must dispatch to the kill command, not treat ``kill`` as a tmux session name."""
    # With no pid argument, kill should complain about missing positional,
    # NOT try to attach a tmux session named "kill".
    result = runner.invoke(cli, ["kill"])
    assert result.exit_code != 0
    # Error message should reference the kill command's usage, not a tmux attach.
    assert "PID" in result.output or "pid" in result.output or "Usage" in result.output
