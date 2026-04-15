"""Tests for the write-side control endpoints (/kill, /ssh/kick, /tmux/new)."""

from __future__ import annotations

import signal
import subprocess
from pathlib import Path

import pytest

from collector.routes import control


class _FakeKillRegistry:
    """Records ``os.kill`` calls and can be primed with pid existence."""

    def __init__(self, alive_pids: set[int], *, raise_for: dict[int, Exception] | None = None):
        self.alive = set(alive_pids)
        self.calls: list[tuple[int, int]] = []
        self._raise_for = raise_for or {}

    def pid_exists(self, pid: int) -> bool:
        return pid in self.alive

    def os_kill(self, pid: int, sig: int) -> None:
        self.calls.append((pid, sig))
        if pid in self._raise_for:
            raise self._raise_for[pid]


@pytest.fixture
def kill_fakes(monkeypatch):
    """Neutralize psutil.Process() so the endpoint's enrichment is stable."""
    class _Proc:
        def __init__(self, pid: int):
            self._pid = pid

        def name(self) -> str:
            return {
                4242: "python",
                9999: "launchd",  # denylist test
                7777: "WindowServer",
            }.get(self._pid, "worker")

        def username(self) -> str:
            return "tester"

    monkeypatch.setattr(control.psutil, "Process", _Proc)
    return _Proc


# ---------- /kill ----------


def test_kill_happy_path(client, auth_headers, kill_fakes, monkeypatch):
    reg = _FakeKillRegistry({4242})
    monkeypatch.setattr(control.os, "kill", reg.os_kill)
    monkeypatch.setattr(control.psutil, "pid_exists", reg.pid_exists)

    resp = client.post("/kill", headers=auth_headers, json={"pid": 4242, "signal": 15})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["pid"] == 4242
    assert body["signal"] == 15
    assert body["process_name"] == "python"
    assert reg.calls == [(4242, 15)]


def test_kill_default_signal_is_sigterm(client, auth_headers, kill_fakes, monkeypatch):
    reg = _FakeKillRegistry({4242})
    monkeypatch.setattr(control.os, "kill", reg.os_kill)
    monkeypatch.setattr(control.psutil, "pid_exists", reg.pid_exists)

    resp = client.post("/kill", headers=auth_headers, json={"pid": 4242})
    assert resp.status_code == 200
    assert reg.calls == [(4242, signal.SIGTERM)]


def test_kill_rejects_unknown_signal(client, auth_headers):
    resp = client.post("/kill", headers=auth_headers, json={"pid": 4242, "signal": 7})
    assert resp.status_code == 400
    assert "disallowed signal" in resp.json()["detail"]


def test_kill_refuses_launchd(client, auth_headers):
    resp = client.post("/kill", headers=auth_headers, json={"pid": 1, "signal": 15})
    assert resp.status_code == 403
    assert "launchd" in resp.json()["detail"]


def test_kill_refuses_self(client, auth_headers, kill_fakes, monkeypatch, app):
    # Force daemon_pid detection to always return 4242 by setting os.getpid.
    monkeypatch.setattr(control.os, "getpid", lambda: 4242)
    resp = client.post("/kill", headers=auth_headers, json={"pid": 4242, "signal": 15})
    assert resp.status_code == 403
    assert "self" in resp.json()["detail"]


def test_kill_missing_pid_returns_404(client, auth_headers, monkeypatch):
    monkeypatch.setattr(control.psutil, "pid_exists", lambda pid: False)
    resp = client.post("/kill", headers=auth_headers, json={"pid": 99999, "signal": 15})
    assert resp.status_code == 404


def test_kill_denylist_refuses_windowserver(client, auth_headers, kill_fakes, monkeypatch):
    reg = _FakeKillRegistry({7777})
    monkeypatch.setattr(control.os, "kill", reg.os_kill)
    monkeypatch.setattr(control.psutil, "pid_exists", reg.pid_exists)

    resp = client.post("/kill", headers=auth_headers, json={"pid": 7777, "signal": 15})
    assert resp.status_code == 403
    assert "WindowServer" in resp.json()["detail"]
    assert reg.calls == []  # never called


def test_kill_os_lookup_race(client, auth_headers, kill_fakes, monkeypatch):
    reg = _FakeKillRegistry({4242}, raise_for={4242: ProcessLookupError()})
    monkeypatch.setattr(control.os, "kill", reg.os_kill)
    monkeypatch.setattr(control.psutil, "pid_exists", reg.pid_exists)

    resp = client.post("/kill", headers=auth_headers, json={"pid": 4242, "signal": 15})
    assert resp.status_code == 404


def test_kill_requires_auth(client):
    resp = client.post("/kill", json={"pid": 4242, "signal": 15})
    assert resp.status_code == 401


def test_kill_writes_audit_line_on_success(
    client, auth_headers, kill_fakes, monkeypatch, app
):
    reg = _FakeKillRegistry({4242})
    monkeypatch.setattr(control.os, "kill", reg.os_kill)
    monkeypatch.setattr(control.psutil, "pid_exists", reg.pid_exists)

    resp = client.post("/kill", headers=auth_headers, json={"pid": 4242, "signal": 15})
    assert resp.status_code == 200

    audit_path: Path = app.state.audit.path
    content = audit_path.read_text()
    assert "action=kill" in content
    assert "pid=4242" in content
    assert "signal=15" in content
    assert "result=ok" in content
    assert "name=python" in content


def test_kill_writes_audit_line_on_refusal(client, auth_headers, app):
    resp = client.post("/kill", headers=auth_headers, json={"pid": 1, "signal": 15})
    assert resp.status_code == 403

    audit_path: Path = app.state.audit.path
    content = audit_path.read_text()
    assert "action=kill" in content
    assert "pid=1" in content
    assert "result=err:refusing to signal launchd" in content.replace('"', "")


# ---------- /ssh/kick ----------


def test_ssh_kick_happy_path(client, auth_headers, monkeypatch):
    # FakeSSH in conftest contains a session with pid=1101, source_ip=100.64.0.2.
    monkeypatch.setattr(control.psutil, "pid_exists", lambda pid: pid == 1101)
    calls: list[tuple[int, int]] = []
    monkeypatch.setattr(control.os, "kill", lambda pid, sig: calls.append((pid, sig)))

    # request.client.host is '127.0.0.1' under TestClient, which differs from
    # the session's 100.64.0.2 -- so the "own session" check passes.
    resp = client.post("/ssh/kick", headers=auth_headers, json={"pid": 1101})
    assert resp.status_code == 200, resp.text
    assert calls == [(1101, int(signal.SIGHUP))]
    body = resp.json()
    assert body["session"]["pid"] == 1101
    assert body["session"]["source_ip"] == "100.64.0.2"


def test_ssh_kick_not_an_ssh_session(client, auth_headers, monkeypatch):
    monkeypatch.setattr(control.psutil, "pid_exists", lambda pid: True)
    resp = client.post("/ssh/kick", headers=auth_headers, json={"pid": 999999})
    assert resp.status_code == 403
    assert "not an sshd session" in resp.json()["detail"]


def test_ssh_kick_missing_pid(client, auth_headers, monkeypatch):
    monkeypatch.setattr(control.psutil, "pid_exists", lambda pid: False)
    resp = client.post("/ssh/kick", headers=auth_headers, json={"pid": 1101})
    assert resp.status_code == 404


def test_ssh_kick_refuses_own_session(client, auth_headers, monkeypatch, fake_sources):
    # Override one session's source_ip so it matches TestClient's remote (127.0.0.1).
    from shared.models import SSHSession

    fake_sources.ssh.sessions_list = [
        SSHSession(
            pid=2002,
            user="core",
            source_ip="testclient",
            source_port=1234,
            tailscale_peer=None,
            tty="pts/9",
            started_at=fake_sources.ssh.sessions_list[0].started_at,
            idle_seconds=0.0,
        )
    ]
    monkeypatch.setattr(control.psutil, "pid_exists", lambda pid: pid == 2002)
    monkeypatch.setattr(control.os, "kill", lambda pid, sig: None)
    resp = client.post("/ssh/kick", headers=auth_headers, json={"pid": 2002})
    assert resp.status_code == 403
    assert "own session" in resp.json()["detail"]


def test_ssh_kick_requires_auth(client):
    resp = client.post("/ssh/kick", json={"pid": 1101})
    assert resp.status_code == 401


def test_ssh_kick_writes_audit_on_success(client, auth_headers, monkeypatch, app):
    monkeypatch.setattr(control.psutil, "pid_exists", lambda pid: True)
    monkeypatch.setattr(control.os, "kill", lambda pid, sig: None)
    resp = client.post("/ssh/kick", headers=auth_headers, json={"pid": 1101})
    assert resp.status_code == 200
    content = app.state.audit.path.read_text()
    assert "action=ssh_kick" in content
    assert "pid=1101" in content
    assert "result=ok" in content


# ---------- /tmux/new ----------


class _FakeCompletedProcess:
    def __init__(self, rc: int, stderr: bytes = b""):
        self.returncode = rc
        self.stdout = b""
        self.stderr = stderr


def test_tmux_new_happy_path(client, auth_headers, monkeypatch):
    calls: list[list[str]] = []

    def fake_runner(cmd):
        calls.append(list(cmd))
        return _FakeCompletedProcess(0)

    monkeypatch.setattr(control, "_default_tmux_runner", fake_runner)
    monkeypatch.setattr(control, "TMUX_BIN", "/opt/homebrew/bin/tmux")

    resp = client.post("/tmux/new", headers=auth_headers, json={"name": "alpha"})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body == {"name": "alpha", "created": True, "exists": False}
    assert calls == [["/opt/homebrew/bin/tmux", "new-session", "-d", "-s", "alpha"]]


def test_tmux_new_wraps_command_when_tmux_user_set(client, auth_headers, monkeypatch):
    # B17: when STUDIOD_TMUX_USER is set the daemon must run tmux via
    # `sudo -u <user> -H --` so the session lands in the user's tmux
    # namespace instead of root's.
    import collector.sources.tmux as tm

    monkeypatch.setattr(tm, "TMUX_USER", "alice")
    monkeypatch.setattr(tm, "SUDO_BIN", "/usr/bin/sudo")

    calls: list[list[str]] = []

    def fake_runner(cmd):
        calls.append(list(cmd))
        return _FakeCompletedProcess(0)

    monkeypatch.setattr(control, "_default_tmux_runner", fake_runner)
    monkeypatch.setattr(control, "TMUX_BIN", "/opt/homebrew/bin/tmux")

    resp = client.post("/tmux/new", headers=auth_headers, json={"name": "beta"})
    assert resp.status_code == 200, resp.text
    assert calls == [
        [
            "/usr/bin/sudo",
            "-u",
            "alice",
            "-H",
            "--",
            "/opt/homebrew/bin/tmux",
            "new-session",
            "-d",
            "-s",
            "beta",
        ]
    ]


def test_tmux_new_idempotent_duplicate(client, auth_headers, monkeypatch):
    def fake_runner(cmd):
        return _FakeCompletedProcess(
            1, stderr=b"duplicate session: alpha\n"
        )

    monkeypatch.setattr(control, "_default_tmux_runner", fake_runner)
    monkeypatch.setattr(control, "TMUX_BIN", "/opt/homebrew/bin/tmux")
    resp = client.post("/tmux/new", headers=auth_headers, json={"name": "alpha"})
    assert resp.status_code == 200
    assert resp.json() == {"name": "alpha", "created": False, "exists": True}


def test_tmux_new_invalid_name(client, auth_headers, monkeypatch):
    monkeypatch.setattr(control, "TMUX_BIN", "/opt/homebrew/bin/tmux")
    resp = client.post(
        "/tmux/new", headers=auth_headers, json={"name": "bad name; rm -rf /"}
    )
    assert resp.status_code == 400
    assert "invalid session name" in resp.json()["detail"]


def test_tmux_new_rejects_empty_name(client, auth_headers):
    resp = client.post("/tmux/new", headers=auth_headers, json={"name": ""})
    # pydantic min_length=1 -> 422
    assert resp.status_code == 422


def test_tmux_new_no_tmux_binary(client, auth_headers, monkeypatch):
    monkeypatch.setattr(control, "TMUX_BIN", None)
    resp = client.post("/tmux/new", headers=auth_headers, json={"name": "alpha"})
    assert resp.status_code == 503
    assert "tmux not available" in resp.json()["detail"]


def test_tmux_new_tmux_timeout(client, auth_headers, monkeypatch):
    def fake_runner(cmd):
        raise subprocess.TimeoutExpired(cmd=cmd, timeout=5)

    monkeypatch.setattr(control, "_default_tmux_runner", fake_runner)
    monkeypatch.setattr(control, "TMUX_BIN", "/opt/homebrew/bin/tmux")
    resp = client.post("/tmux/new", headers=auth_headers, json={"name": "alpha"})
    assert resp.status_code == 504


def test_tmux_new_requires_auth(client):
    resp = client.post("/tmux/new", json={"name": "alpha"})
    assert resp.status_code == 401


def test_tmux_new_writes_audit_on_success(client, auth_headers, monkeypatch, app):
    def fake_runner(cmd):
        return _FakeCompletedProcess(0)

    monkeypatch.setattr(control, "_default_tmux_runner", fake_runner)
    monkeypatch.setattr(control, "TMUX_BIN", "/opt/homebrew/bin/tmux")
    resp = client.post("/tmux/new", headers=auth_headers, json={"name": "alpha"})
    assert resp.status_code == 200
    content = app.state.audit.path.read_text()
    assert "action=tmux_new" in content
    assert "name=alpha" in content
    assert "result=ok" in content
    assert "created=True" in content
