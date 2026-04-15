import pytest

from collector.config import ConfigError, load_config, validate_bind_host
from shared.config import (
    ENV_BIND_HOST,
    ENV_BIND_PORT,
    ENV_DEV_MODE,
    ENV_TOKEN_FILE,
)


def test_load_config_defaults(monkeypatch, tmp_path):
    for k in (ENV_BIND_HOST, ENV_BIND_PORT, ENV_DEV_MODE, ENV_TOKEN_FILE):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.chdir(tmp_path)
    cfg = load_config()
    assert cfg.bind_host == "127.0.0.1"
    assert cfg.bind_port == 8765
    assert cfg.dev_mode is False


def test_load_config_dev_mode(monkeypatch, tmp_path):
    monkeypatch.setenv(ENV_DEV_MODE, "1")
    monkeypatch.setenv(ENV_BIND_PORT, "19999")
    monkeypatch.chdir(tmp_path)
    cfg = load_config()
    assert cfg.dev_mode is True
    assert cfg.bind_port == 19999


# ---- Fix 3: bind-host validation ----


def test_validate_bind_host_loopback_ipv4():
    assert validate_bind_host("127.0.0.1", dev_mode=False) == "127.0.0.1"
    assert validate_bind_host("127.0.0.1", dev_mode=True) == "127.0.0.1"


def test_validate_bind_host_loopback_ipv6():
    assert validate_bind_host("::1", dev_mode=False) == "::1"
    assert validate_bind_host("::1", dev_mode=True) == "::1"


def test_validate_bind_host_tailscale_cgnat_prod_ok():
    # 100.64.0.0/10 covers 100.64.0.0 - 100.127.255.255
    assert validate_bind_host("100.64.1.5", dev_mode=False) == "100.64.1.5"
    assert validate_bind_host("100.100.50.1", dev_mode=False) == "100.100.50.1"


def test_validate_bind_host_tailscale_rejected_in_dev():
    with pytest.raises(ConfigError, match="dev mode"):
        validate_bind_host("100.64.1.5", dev_mode=True)


def test_validate_bind_host_rejects_wildcard():
    with pytest.raises(ConfigError):
        validate_bind_host("0.0.0.0", dev_mode=False)
    with pytest.raises(ConfigError):
        validate_bind_host("0.0.0.0", dev_mode=True)


def test_validate_bind_host_rejects_private_non_tailscale():
    with pytest.raises(ConfigError):
        validate_bind_host("192.168.1.10", dev_mode=False)
    with pytest.raises(ConfigError):
        validate_bind_host("192.168.1.10", dev_mode=True)


def test_validate_bind_host_rejects_public_ip():
    with pytest.raises(ConfigError):
        validate_bind_host("8.8.8.8", dev_mode=False)


def test_validate_bind_host_rejects_garbage():
    with pytest.raises(ConfigError, match="not a valid IP"):
        validate_bind_host("not-an-ip-at-all", dev_mode=False)
    with pytest.raises(ConfigError, match="not a valid IP"):
        validate_bind_host("not-an-ip-at-all", dev_mode=True)


def test_load_config_rejects_bad_bind_host(monkeypatch, tmp_path):
    monkeypatch.delenv(ENV_DEV_MODE, raising=False)
    monkeypatch.setenv(ENV_BIND_HOST, "0.0.0.0")
    monkeypatch.chdir(tmp_path)
    with pytest.raises(ConfigError):
        load_config()
