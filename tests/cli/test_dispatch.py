"""Tests for the click dispatch / passthrough layer.

These tests verify the user-facing muscle memory:

* ``studio status`` runs the status subcommand.
* ``studio main`` is a tmux session attach (NOT a "no such command" error).
* ``studio`` with no args triggers the picker code path.
* ``studio version`` prints the package version.
* ``studio --help`` lists all subcommands.
"""

from __future__ import annotations

import pytest

from studio_cli import __version__
from studio_cli.cli import cli
from studio_cli.commands import tmux as tmux_module


@pytest.fixture
def captured_tmux_calls(monkeypatch: pytest.MonkeyPatch) -> list:
    """Replace run_tmux_command in BOTH the cli module (used by the bare
    ``studio`` callback) and in the tmux command module (used by ``studio
    tmux NAME``) so we can assert on what would have happened without
    actually shelling out to ssh / fzf."""
    calls: list = []

    def fake(name=None, cfg=None):
        calls.append(name)
        return 0

    monkeypatch.setattr("studio_cli.cli.run_tmux_command", fake)
    monkeypatch.setattr(tmux_module, "run_tmux_command", fake)
    return calls


def test_help_lists_subcommands(runner) -> None:
    result = runner.invoke(cli, ["--help"])
    assert result.exit_code == 0
    for name in ("status", "ports", "who", "ps", "sessions", "stats", "tmux", "config", "version"):
        assert name in result.output


def test_version_subcommand(runner) -> None:
    result = runner.invoke(cli, ["version"])
    assert result.exit_code == 0
    assert __version__ in result.output


def test_version_flag(runner) -> None:
    result = runner.invoke(cli, ["--version"])
    assert result.exit_code == 0
    assert __version__ in result.output


def test_no_args_invokes_picker(runner, captured_tmux_calls) -> None:
    result = runner.invoke(cli, [])
    assert result.exit_code == 0, result.output
    assert captured_tmux_calls == [None]


def test_bare_session_name_dispatches_to_tmux(runner, captured_tmux_calls) -> None:
    result = runner.invoke(cli, ["main"])
    assert result.exit_code == 0, result.output
    assert captured_tmux_calls == ["main"]


def test_explicit_tmux_subcommand_with_name(runner, captured_tmux_calls) -> None:
    result = runner.invoke(cli, ["tmux", "dev"])
    assert result.exit_code == 0, result.output
    assert captured_tmux_calls == ["dev"]


def test_unknown_flag_still_errors(runner) -> None:
    result = runner.invoke(cli, ["--no-such-flag"])
    assert result.exit_code != 0


def test_status_dispatches_to_status(runner, patched_client) -> None:
    """Sanity check: a reserved subcommand name routes to its handler,
    not to the tmux fallback."""
    result = runner.invoke(cli, ["status"])
    assert result.exit_code == 0
    assert "studio status" in result.output


def test_kill_and_kick_are_reserved(runner) -> None:
    """Phase 3: ``kill`` and ``kick`` must be reserved so they dispatch to
    the new subcommands rather than being treated as tmux session names."""
    from studio_cli.cli import RESERVED_NAMES

    assert "kill" in RESERVED_NAMES
    assert "kick" in RESERVED_NAMES


def test_help_lists_phase3_subcommands(runner) -> None:
    result = runner.invoke(cli, ["--help"])
    assert result.exit_code == 0
    for name in ("kill", "kick"):
        assert name in result.output


def test_invalid_session_name_is_rejected(runner, monkeypatch: pytest.MonkeyPatch) -> None:
    """A session name with shell metacharacters must be refused before any
    subprocess is spawned."""
    spawned: list = []

    def fail_if_called(*args, **kwargs):
        spawned.append(args)
        raise AssertionError("ssh should never be invoked for an invalid name")

    monkeypatch.setattr("os.execvp", fail_if_called)
    result = runner.invoke(cli, ["tmux", "bad name; rm -rf /"])
    assert result.exit_code != 0
    assert spawned == []
