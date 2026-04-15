"""Tests for ``studio status``."""

from __future__ import annotations

from studio_cli.cli import cli


def test_status_happy_path(runner, patched_client) -> None:
    result = runner.invoke(cli, ["status"])
    assert result.exit_code == 0, result.output
    assert "studio status" in result.output
    assert "CPU" in result.output
    assert "GPU" in result.output
    assert "MEM" in result.output
    # Power line present
    assert "PWR" in result.output
    assert "macbook-air" in result.output  # peer hostname rendered
    # Top listening ports rendered
    assert "tcp/22" in result.output


def test_status_handles_connect_error(runner, env_overrides) -> None:
    # No patched_client fixture, so the real httpx client tries to hit
    # http://test.invalid -- which fails with a connect / dns error.
    result = runner.invoke(cli, ["status"])
    assert result.exit_code == 1
    assert "error" in result.output.lower()


def test_status_handles_401(runner, set_route) -> None:
    set_route("/stats", payload={"error": "unauthorized"}, status=401)
    result = runner.invoke(cli, ["status"])
    assert result.exit_code == 1
    assert "401" in result.output or "rejected token" in result.output


def test_status_handles_500(runner, set_route) -> None:
    set_route("/stats", payload={"error": "boom"}, status=500)
    result = runner.invoke(cli, ["status"])
    assert result.exit_code == 1
    assert "internal error" in result.output or "500" in result.output
