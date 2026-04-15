"""Tests for :mod:`studio_cli.config`."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from studio_cli.config import (
    ENV_COLLECTOR_URL,
    ENV_TIMEOUT,
    ENV_TOKEN,
    ENV_TOKEN_FILE,
    StudioConfigError,
    load_config,
    load_token,
    redact_token,
)


def test_defaults_when_no_env_or_file(tmp_path: Path) -> None:
    cfg = load_config(env={"STUDIO_CONFIG_FILE": str(tmp_path / "missing.toml")})
    assert cfg.collector_url == "http://100.80.21.79:8765"
    assert cfg.ssh_host == "macstudio"
    assert cfg.timeout_seconds == 5.0
    assert cfg.config_file is None


def test_env_var_overrides_defaults(tmp_path: Path) -> None:
    cfg = load_config(
        env={
            "STUDIO_CONFIG_FILE": str(tmp_path / "missing.toml"),
            ENV_COLLECTOR_URL: "http://example.invalid:9000/",  # trailing slash should be stripped
            ENV_TIMEOUT: "1.5",
        }
    )
    assert cfg.collector_url == "http://example.invalid:9000"
    assert cfg.timeout_seconds == 1.5


def test_config_file_overrides_defaults(tmp_path: Path) -> None:
    cfg_file = tmp_path / "config.toml"
    cfg_file.write_text(
        'collector_url = "http://from-file.invalid:1234"\n'
        'timeout_seconds = 9.0\n'
        'ssh_host = "from-file-host"\n'
    )
    cfg = load_config(env={"STUDIO_CONFIG_FILE": str(cfg_file)})
    assert cfg.collector_url == "http://from-file.invalid:1234"
    assert cfg.timeout_seconds == 9.0
    assert cfg.ssh_host == "from-file-host"
    assert cfg.config_file == cfg_file


def test_env_overrides_file(tmp_path: Path) -> None:
    cfg_file = tmp_path / "config.toml"
    cfg_file.write_text('collector_url = "http://from-file.invalid:1234"\n')
    cfg = load_config(
        env={
            "STUDIO_CONFIG_FILE": str(cfg_file),
            ENV_COLLECTOR_URL: "http://env.invalid:5555",
        }
    )
    assert cfg.collector_url == "http://env.invalid:5555"


def test_invalid_toml_raises(tmp_path: Path) -> None:
    cfg_file = tmp_path / "config.toml"
    cfg_file.write_text("not = valid = toml\n")
    with pytest.raises(StudioConfigError, match="invalid TOML"):
        load_config(env={"STUDIO_CONFIG_FILE": str(cfg_file)})


def test_token_override_env_var_bypasses_file(tmp_path: Path) -> None:
    cfg = load_config(
        env={
            "STUDIO_CONFIG_FILE": str(tmp_path / "missing.toml"),
            ENV_TOKEN: "direct-injected-token",
        }
    )
    token = load_token(cfg)
    assert token == "direct-injected-token"


def test_load_token_reads_file_with_correct_mode(tmp_path: Path) -> None:
    token_file = tmp_path / "token"
    token_file.write_text("file-token\n")
    token_file.chmod(0o600)
    cfg = load_config(
        env={
            "STUDIO_CONFIG_FILE": str(tmp_path / "missing.toml"),
            ENV_TOKEN_FILE: str(token_file),
        }
    )
    assert load_token(cfg) == "file-token"


def test_load_token_rejects_world_readable(tmp_path: Path) -> None:
    token_file = tmp_path / "token"
    token_file.write_text("file-token\n")
    token_file.chmod(0o644)
    cfg = load_config(
        env={
            "STUDIO_CONFIG_FILE": str(tmp_path / "missing.toml"),
            ENV_TOKEN_FILE: str(token_file),
        }
    )
    with pytest.raises(StudioConfigError, match="overly permissive"):
        load_token(cfg)


def test_load_token_missing_file_friendly_error(tmp_path: Path) -> None:
    cfg = load_config(
        env={
            "STUDIO_CONFIG_FILE": str(tmp_path / "missing.toml"),
            ENV_TOKEN_FILE: str(tmp_path / "no-token"),
        }
    )
    with pytest.raises(StudioConfigError, match="token file not found"):
        load_token(cfg)


def test_load_token_empty_file_rejected(tmp_path: Path) -> None:
    token_file = tmp_path / "token"
    token_file.write_text("")
    token_file.chmod(0o600)
    cfg = load_config(
        env={
            "STUDIO_CONFIG_FILE": str(tmp_path / "missing.toml"),
            ENV_TOKEN_FILE: str(token_file),
        }
    )
    with pytest.raises(StudioConfigError, match="empty"):
        load_token(cfg)


def test_redact_token_short_and_long() -> None:
    assert redact_token("") == "(empty)"
    assert redact_token("abc") == "***"
    assert redact_token("abcdef1234") == "abcd\u2026"


def test_load_config_uses_real_env_when_no_arg(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(ENV_COLLECTOR_URL, "http://from-real-env.invalid:7777")
    monkeypatch.setenv("STUDIO_CONFIG_FILE", "/nonexistent/config.toml")
    cfg = load_config()
    assert cfg.collector_url == "http://from-real-env.invalid:7777"
