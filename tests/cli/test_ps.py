"""Tests for ``studio ps``."""

from __future__ import annotations

from studio_cli.cli import cli


def test_ps_happy_path_default_sort_cpu(runner, patched_client) -> None:
    result = runner.invoke(cli, ["ps"])
    assert result.exit_code == 0, result.output
    assert "Top" in result.output
    assert "python" in result.output
    assert "launchd" in result.output
    # Default sort is CPU desc -- python (88.5) should come before launchd (0.0).
    assert result.output.index("python") < result.output.index("launchd")


def test_ps_sort_mem(runner, patched_client) -> None:
    result = runner.invoke(cli, ["ps", "--sort", "mem"])
    assert result.exit_code == 0
    assert "by mem" in result.output
    # python has 512M RSS, launchd has 5M -- python still first.
    assert result.output.index("python") < result.output.index("launchd")


def test_ps_limit_validation(runner, patched_client) -> None:
    result = runner.invoke(cli, ["ps", "--limit", "0"])
    # click.IntRange rejects 0; exit code is 2 (usage error).
    assert result.exit_code != 0


def test_ps_full_cmdline_flag(runner, patched_client) -> None:
    result = runner.invoke(cli, ["ps", "--full-cmdline"])
    assert result.exit_code == 0
