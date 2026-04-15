import logging
import os
from types import SimpleNamespace

import pytest

from shared.auth import (
    TokenError,
    compare,
    ensure_dev_token,
    is_dev_mode,
    read_token,
    resolve_token_path,
)
from shared.config import ENV_DEV_MODE, ENV_TOKEN_FILE


def test_compare_constant_time():
    assert compare("abc", "abc") is True
    assert compare("abc", "abd") is False
    assert compare("abc", "") is False


def test_resolve_token_path_explicit(tmp_path, monkeypatch):
    target = tmp_path / "some.token"
    monkeypatch.setenv(ENV_TOKEN_FILE, str(target))
    assert resolve_token_path() == target


def test_resolve_token_path_dev_mode(tmp_path, monkeypatch):
    monkeypatch.delenv(ENV_TOKEN_FILE, raising=False)
    monkeypatch.setenv(ENV_DEV_MODE, "1")
    monkeypatch.chdir(tmp_path)
    assert is_dev_mode() is True
    assert resolve_token_path() == tmp_path / ".studiod-dev-token"


def test_ensure_dev_token_creates_file(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv(ENV_DEV_MODE, "1")
    target = tmp_path / ".studiod-dev-token"
    token = ensure_dev_token(target)
    assert target.exists()
    assert len(token) >= 32
    captured = capsys.readouterr()
    assert "dev-mode" in captured.out


def test_ensure_dev_token_reuses_existing(tmp_path, monkeypatch):
    monkeypatch.setenv(ENV_DEV_MODE, "1")
    target = tmp_path / ".studiod-dev-token"
    target.write_text("my-saved-token\n")
    assert ensure_dev_token(target) == "my-saved-token"


def test_read_token_missing(tmp_path):
    with pytest.raises(TokenError):
        read_token(tmp_path / "nope.token")


def test_read_token_empty(tmp_path, monkeypatch):
    monkeypatch.setenv(ENV_DEV_MODE, "1")
    p = tmp_path / "t"
    p.write_text("")
    with pytest.raises(TokenError):
        read_token(p)


def test_read_token_rejects_world_readable_in_prod(tmp_path, monkeypatch):
    monkeypatch.delenv(ENV_DEV_MODE, raising=False)
    p = tmp_path / "t"
    p.write_text("abc")
    p.chmod(0o644)
    with pytest.raises(TokenError):
        read_token(p)


def test_read_token_rejects_non_root_owner_in_prod(tmp_path, monkeypatch):
    # Fix 4: prod mode must reject a token file that isn't owned by root,
    # even if the mode bits are 0o600. An attacker who compromises a
    # non-root user could otherwise plant a 0600 file at the token path.
    monkeypatch.delenv(ENV_DEV_MODE, raising=False)
    p = tmp_path / "t"
    p.write_text("abc")
    p.chmod(0o600)

    real_stat = os.stat(p)
    # Pretend the file is owned by uid 501 (a regular user), not root.
    fake_stat = SimpleNamespace(
        st_mode=real_stat.st_mode,
        st_uid=501,
        st_gid=real_stat.st_gid,
        st_size=real_stat.st_size,
        st_mtime=real_stat.st_mtime,
    )

    original_stat = type(p).stat

    def fake_path_stat(self, *args, **kwargs):
        if self == p:
            return fake_stat
        return original_stat(self, *args, **kwargs)

    monkeypatch.setattr(type(p), "stat", fake_path_stat)
    with pytest.raises(TokenError, match="owned by root"):
        read_token(p)


def test_read_token_accepts_root_owned_prod(tmp_path, monkeypatch):
    # Fix 4: a 0o600 file with st_uid=0 is accepted in prod.
    monkeypatch.delenv(ENV_DEV_MODE, raising=False)
    p = tmp_path / "t"
    p.write_text("goodtoken")
    p.chmod(0o600)

    real_stat = os.stat(p)
    fake_stat = SimpleNamespace(
        st_mode=real_stat.st_mode,
        st_uid=0,
        st_gid=real_stat.st_gid,
        st_size=real_stat.st_size,
        st_mtime=real_stat.st_mtime,
    )
    original_stat = type(p).stat

    def fake_path_stat(self, *args, **kwargs):
        if self == p:
            return fake_stat
        return original_stat(self, *args, **kwargs)

    monkeypatch.setattr(type(p), "stat", fake_path_stat)
    assert read_token(p) == "goodtoken"


def test_ensure_dev_token_warns_on_bad_mode(tmp_path, monkeypatch, caplog):
    # Fix 6: if chmod(0o600) silently fails to apply the intended mode,
    # ensure_dev_token must log a WARNING so the developer notices -- but
    # must NOT raise, because dev mode has to be forgiving on exotic
    # filesystems. We simulate "silent chmod failure" by intercepting
    # Path.chmod and forcing the file to end up with mode 0o644 instead
    # of 0o600 regardless of what the caller asked for.
    monkeypatch.setenv(ENV_DEV_MODE, "1")
    target = tmp_path / ".studiod-dev-token"

    from pathlib import Path as _Path

    real_path_chmod = _Path.chmod

    def sabotaged_chmod(self, mode):
        # Ignore what the caller wanted, always set 0o644.
        return real_path_chmod(self, 0o644)

    monkeypatch.setattr(_Path, "chmod", sabotaged_chmod)

    caplog.set_level(logging.WARNING, logger="shared.auth")
    token = ensure_dev_token(target)
    assert token  # still returns successfully (dev mode is forgiving)

    warnings = [
        r for r in caplog.records
        if r.levelno == logging.WARNING and "0o600" in r.getMessage()
    ]
    assert warnings, (
        f"expected a WARNING about token mode 0o600, got "
        f"{[r.getMessage() for r in caplog.records]}"
    )
