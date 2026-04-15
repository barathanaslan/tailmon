"""Tests for ``studio tmux new``."""

from __future__ import annotations

from studio_cli.cli import cli


def test_tmux_new_happy_path(runner, patched_client) -> None:
    result = runner.invoke(cli, ["tmux", "new", "alpha"])
    assert result.exit_code == 0, result.output
    assert "created" in result.output.lower()
    assert "alpha" in result.output


def test_tmux_new_idempotent_shows_already_exists(runner, set_route) -> None:
    set_route(
        "/tmux/new",
        payload={"name": "alpha", "created": False, "exists": True},
    )
    result = runner.invoke(cli, ["tmux", "new", "alpha"])
    assert result.exit_code == 0, result.output
    assert "already exists" in result.output


def test_tmux_new_rejects_bad_name(runner, patched_client) -> None:
    # Client-side validation -- should not hit the server.
    result = runner.invoke(cli, ["tmux", "new", "bad name"])
    assert result.exit_code != 0


def test_tmux_new_surfaces_503(runner, set_route) -> None:
    set_route("/tmux/new", payload={"detail": "tmux not available"}, status=503)
    result = runner.invoke(cli, ["tmux", "new", "alpha"])
    assert result.exit_code == 1
    assert "tmux" in result.output


def test_tmux_attach_still_works_with_bareword(runner, monkeypatch, patched_client) -> None:
    """``studio tmux main`` should continue to dispatch to the attach handler
    even though we added a ``new`` subcommand under the tmux group.
    """
    captured: list = []

    def fake(name=None, cfg=None):
        captured.append(name)
        return 0

    monkeypatch.setattr("studio_cli.commands.tmux.run_tmux_command", fake)
    result = runner.invoke(cli, ["tmux", "main"])
    assert result.exit_code == 0, result.output
    assert captured == ["main"]
