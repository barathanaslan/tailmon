"""Tests for ``studio config show`` / ``studio config path``."""

from __future__ import annotations

from studio_cli.cli import cli


def test_config_show_renders(runner, env_overrides, fake_token_file) -> None:
    result = runner.invoke(cli, ["config", "show"])
    assert result.exit_code == 0, result.output
    assert "collector_url" in result.output
    assert "test.invalid" in result.output
    # token should be redacted, never printed in full
    assert "dummy-token-for-tests" not in result.output


def test_config_show_handles_missing_token(runner, monkeypatch) -> None:
    monkeypatch.setenv("STUDIO_TOKEN_FILE", "/nonexistent/token")
    monkeypatch.setenv("STUDIO_CONFIG_FILE", "/nonexistent/config.toml")
    monkeypatch.setenv("STUDIO_COLLECTOR_URL", "http://test.invalid:8765")
    result = runner.invoke(cli, ["config", "show"])
    assert result.exit_code == 0
    assert "unavailable" in result.output


def test_config_path(runner, env_overrides) -> None:
    result = runner.invoke(cli, ["config", "path"])
    assert result.exit_code == 0
    assert ".toml" in result.output
