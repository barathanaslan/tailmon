"""Unit tests for the audit log wrapper."""

from __future__ import annotations

import os
import stat
from pathlib import Path

import pytest

from collector.audit import (
    AuditLogger,
    AuditWriteError,
    build_default_audit_logger,
    format_audit_line,
    resolve_audit_path,
    token_fingerprint,
)


def test_token_fingerprint_is_deterministic_and_short():
    fp1 = token_fingerprint("hunter2")
    fp2 = token_fingerprint("hunter2")
    assert fp1 == fp2
    assert len(fp1) == 8
    assert all(c in "0123456789abcdef" for c in fp1)
    assert token_fingerprint("other") != fp1


def test_format_audit_line_basic_fields():
    line = format_audit_line(
        "kill",
        {"pid": 42, "signal": 15, "by": "100.64.0.2", "token": "deadbeef", "result": "ok"},
    )
    # Action comes first, remaining keys preserve insertion order.
    assert " action=kill " in line
    assert "pid=42" in line
    assert "signal=15" in line
    assert "by=100.64.0.2" in line
    assert "token=deadbeef" in line
    assert "result=ok" in line
    # Leading timestamp is ISO8601 with trailing Z.
    head = line.split(" ", 1)[0]
    assert head.endswith("Z")
    assert "T" in head


def test_format_audit_line_quotes_spaces_and_empty():
    line = format_audit_line(
        "tmux_new",
        {"name": "session with space", "result": ""},
    )
    assert 'name="session with space"' in line
    # empty string -> quoted empty
    assert 'result=""' in line


def test_format_audit_line_escapes_quotes_and_backslashes():
    line = format_audit_line("x", {"k": 'a"b\\c'})
    assert 'k="a\\"b\\\\c"' in line


def test_audit_logger_writes_line_and_creates_file(tmp_path: Path):
    path = tmp_path / "audit.log"
    al = AuditLogger(path, mode=0o600)
    assert path.exists()
    # mode is 0o600 on the on-disk file
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600

    al.write("kill", {"pid": 1, "signal": 15, "result": "ok"})
    al.write("kill", {"pid": 2, "signal": 9, "result": "err:refused"})

    contents = path.read_text()
    lines = [line for line in contents.splitlines() if line.strip()]
    assert len(lines) == 2
    assert "action=kill" in lines[0]
    assert "pid=1" in lines[0]
    assert "result=ok" in lines[0]
    assert "result=err:refused" in lines[1]


def test_audit_logger_appends_across_instances(tmp_path: Path):
    path = tmp_path / "audit.log"
    AuditLogger(path, mode=0o600).write("a", {"k": 1, "result": "ok"})
    AuditLogger(path, mode=0o600).write("b", {"k": 2, "result": "ok"})
    contents = path.read_text()
    lines = [line for line in contents.splitlines() if line.strip()]
    assert len(lines) == 2
    assert "action=a" in lines[0]
    assert "action=b" in lines[1]


def test_audit_logger_refuses_unwritable_parent(tmp_path: Path, monkeypatch):
    # Simulate a permission error at file-open time.
    real_open = os.open

    def fake_open(path, *args, **kwargs):
        if "audit.log" in str(path):
            raise PermissionError("nope")
        return real_open(path, *args, **kwargs)

    monkeypatch.setattr(os, "open", fake_open)
    with pytest.raises(AuditWriteError):
        AuditLogger(tmp_path / "audit.log", mode=0o600)


def test_resolve_audit_path_respects_dev_mode(monkeypatch, tmp_path: Path):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("STUDIOD_DEV_MODE", "1")
    assert resolve_audit_path() == tmp_path / "studiod-audit.log"

    monkeypatch.setenv("STUDIOD_DEV_MODE", "0")
    from collector.audit import PROD_AUDIT_PATH

    assert resolve_audit_path() == PROD_AUDIT_PATH


def test_build_default_audit_logger_in_dev_mode(monkeypatch, tmp_path: Path):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("STUDIOD_DEV_MODE", "1")
    al = build_default_audit_logger()
    assert al.path == tmp_path / "studiod-audit.log"
    al.write("ping", {"result": "ok"})
    assert al.path.exists()
    assert stat.S_IMODE(os.stat(al.path).st_mode) == 0o600
