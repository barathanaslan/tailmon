"""Tests for the tmux subcommand internals."""

from __future__ import annotations

import pytest

from studio_cli.commands import tmux as tmux_module
from studio_cli.commands.tmux import (
    SESSION_NAME_RE,
    _format_session_lines,
    _validate_session_name,
)


def test_session_name_regex_accepts_normal_names() -> None:
    for name in ("main", "dev", "feature-1", "exp_01", "v1.2"):
        assert SESSION_NAME_RE.match(name)


def test_session_name_regex_rejects_metachars() -> None:
    for name in ("bad name", "$(rm -rf /)", "a;b", "a/b", "", "a|b", "a&b"):
        assert not SESSION_NAME_RE.match(name)


def test_validate_session_name_raises_on_bad() -> None:
    import click

    with pytest.raises(click.UsageError):
        _validate_session_name("bad name")


def test_format_session_lines_includes_indicators_and_new() -> None:
    lines = _format_session_lines(
        [
            {"name": "main", "attached": True, "windows": 3},
            {"name": "dev", "attached": False, "windows": 1},
        ]
    )
    assert lines[0].startswith("main")
    assert "attached" in lines[0]
    assert lines[1].startswith("dev")
    assert "detached" in lines[1]
    assert lines[-1] == "+ New session"


def test_run_tmux_command_with_name_calls_execvp(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: list = []

    def fake_execvp(prog, args):
        captured.append((prog, list(args)))

    monkeypatch.setattr(tmux_module.os, "execvp", fake_execvp)

    from studio_cli.config import ClientConfig
    from pathlib import Path

    cfg = ClientConfig(
        collector_url="http://test.invalid:8765",
        token_file=Path("/tmp/no-such-token"),
        timeout_seconds=2.0,
        ssh_host="macstudio-test",
        config_file=None,
        token_override="dummy",
    )

    rc = tmux_module.run_tmux_command("main", cfg=cfg)
    assert rc == 0
    assert len(captured) == 1
    prog, args = captured[0]
    assert prog == "ssh"
    assert args == [
        "ssh",
        "-t",
        "macstudio-test",
        "tmux",
        "new-session",
        "-A",
        "-s",
        "main",
    ]


def test_run_tmux_command_picker_with_fzf_cancel(
    monkeypatch: pytest.MonkeyPatch, fake_config, env_overrides, patched_client
) -> None:
    """When fzf returns non-zero (user cancelled), no execvp happens."""
    monkeypatch.setattr(tmux_module, "_fzf_pick", lambda lines: None)

    spawned: list = []
    monkeypatch.setattr(tmux_module.os, "execvp", lambda *a, **k: spawned.append(a))

    rc = tmux_module.run_tmux_command(name=None)
    assert rc == 0
    assert spawned == []


def test_run_tmux_command_picker_pick_existing(
    monkeypatch: pytest.MonkeyPatch, env_overrides, patched_client
) -> None:
    """If the user picks an existing session, execvp is called with that name."""
    monkeypatch.setattr(
        tmux_module, "_fzf_pick", lambda lines: "main  \u25cf attached"
    )
    captured: list = []
    monkeypatch.setattr(tmux_module.os, "execvp", lambda p, a: captured.append((p, list(a))))

    rc = tmux_module.run_tmux_command(name=None)
    assert rc == 0
    assert captured and captured[0][1][-1] == "main"


def test_fzf_subprocess_call_uses_arglist(monkeypatch: pytest.MonkeyPatch) -> None:
    """Guardrail: the fzf invocation must never use shell=True."""
    seen: dict = {}

    class FakeProc:
        returncode = 0
        stdout = "main\n"
        stderr = ""

    def fake_run(args, **kwargs):
        seen["args"] = args
        seen["kwargs"] = kwargs
        return FakeProc()

    monkeypatch.setattr(tmux_module.subprocess, "run", fake_run)
    out = tmux_module._fzf_pick(["main", "dev"])
    assert out == "main"
    assert isinstance(seen["args"], list)
    assert seen["args"][0] == "fzf"
    assert "shell" not in seen["kwargs"] or seen["kwargs"]["shell"] is False
