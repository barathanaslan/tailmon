from types import SimpleNamespace

from collector.sources.ssh_sessions import (
    _extract_tty,
    _peer_from_cmdline,
    _tty_idle_seconds,
    collect_ssh_sessions,
)
from shared.models import TailscalePeer


def test_ssh_sessions_endpoint_labels_peer(client, auth_headers):
    # The endpoint uses the in-memory FakeSSH from conftest (not the fixture
    # file), which still has exactly two synthetic sessions wired up.
    resp = client.get("/ssh/sessions", headers=auth_headers)
    assert resp.status_code == 200
    sessions = resp.json()["sessions"]
    assert len(sessions) == 2
    tailscale_session = next(s for s in sessions if s["source_ip"] == "100.64.0.2")
    assert tailscale_session["tailscale_peer"] is not None
    assert tailscale_session["tailscale_peer"]["hostname"] == "macbook-air"
    raw_session = next(s for s in sessions if s["source_ip"] == "203.0.113.9")
    assert raw_session["tailscale_peer"] is None


def test_collect_ssh_sessions_walks_fixture(sshd_fixture_processes):
    peer_map = {
        "100.64.0.2": TailscalePeer(
            hostname="macbook-air",
            tailscale_ip="100.64.0.2",
            os="macOS",
            user_display_name="Core Operator",
        )
    }

    def fake_process_iter(_attrs):
        return iter(sshd_fixture_processes)

    sessions = collect_ssh_sessions(peer_map, process_iter=fake_process_iter)
    # Listener + all [priv] parents (sshd: and sshd-session:) are filtered
    # out. We keep: core@pts/0, friend@pts/1, vsuser@notty (sshd-session),
    # core@ttys001 (sshd-session). Four user sessions, three unique users.
    assert len(sessions) == 4
    assert {s.user for s in sessions} == {"core", "friend", "vsuser"}

    # Legacy sshd: prefix (pts/0) still works.
    core_pts = next(s for s in sessions if s.tty == "pts/0")
    assert core_pts.source_ip == "100.64.0.2"
    assert core_pts.tailscale_peer is not None
    assert core_pts.tailscale_peer.hostname == "macbook-air"

    friend = next(s for s in sessions if s.user == "friend")
    assert friend.tailscale_peer is None
    assert friend.source_ip == "203.0.113.9"

    # New sshd-session: prefix with notty (VSCode Remote-SSH shape) must be
    # surfaced. The tty is None because `notty` is not a real device.
    vsuser = next(s for s in sessions if s.user == "vsuser")
    assert vsuser.tty is None
    assert vsuser.idle_seconds is None
    assert vsuser.source_ip == "100.64.0.3"

    # New sshd-session: prefix with a real pty also works.
    core_tty = next(s for s in sessions if s.tty == "ttys001")
    assert core_tty.user == "core"
    assert core_tty.source_ip == "100.64.0.2"
    assert core_tty.tailscale_peer is not None


def test_extract_tty_and_peer_helpers():
    assert _extract_tty("sshd: core@pts/0") == "pts/0"
    assert _extract_tty("sshd: core@notty") is None
    assert _extract_tty("sshd: /usr/sbin/sshd -D") is None
    # sshd-session: prefix (macOS 26.3+ OpenSSH session-per-process model)
    assert _extract_tty("sshd-session: core@ttys001") == "ttys001"
    assert _extract_tty("sshd-session: vsuser@notty") is None

    ip, port = _peer_from_cmdline("sshd: core@pts/0 from 10.0.0.1 port 22")
    assert ip == "10.0.0.1"
    assert port == 22
    assert _peer_from_cmdline("sshd: core@pts/0") == (None, None)


def test_tty_idle_seconds_missing_tty():
    assert _tty_idle_seconds("definitely-not-a-real-tty") is None


def test_collect_ssh_sessions_falls_back_to_cmdline_peer():
    processes = [
        SimpleNamespace(
            info={
                "pid": 5000,
                "ppid": 1,
                "name": "sshd",
                "username": "root",
                "cmdline": ["sshd: alice@pts/2 from 10.1.2.3 port 1111"],
                "create_time": 1744700000.0,
                "connections": [],
            }
        ),
    ]
    sessions = collect_ssh_sessions({}, process_iter=lambda _: iter(processes))
    assert len(sessions) == 1
    assert sessions[0].source_ip == "10.1.2.3"
    assert sessions[0].source_port == 1111
    assert sessions[0].user == "alice"


def test_collect_ssh_sessions_unknown_source_when_no_info():
    processes = [
        SimpleNamespace(
            info={
                "pid": 6000,
                "ppid": 1,
                "name": "sshd",
                "username": "root",
                "cmdline": ["sshd: bob@pts/3"],
                "create_time": 1744700000.0,
                "connections": [],
            }
        ),
    ]
    sessions = collect_ssh_sessions({}, process_iter=lambda _: iter(processes))
    assert sessions[0].source_ip == "unknown"
    assert sessions[0].source_port == 0


def test_collect_ssh_sessions_skips_non_sshd_and_listener():
    processes = [
        SimpleNamespace(
            info={
                "pid": 1,
                "ppid": 0,
                "name": "launchd",
                "username": "root",
                "cmdline": ["/sbin/launchd"],
                "create_time": 1744700000.0,
                "connections": [],
            }
        ),
        SimpleNamespace(
            info={
                "pid": 99,
                "ppid": 1,
                "name": "sshd",
                "username": "root",
                "cmdline": ["sshd: /usr/sbin/sshd -D [listener]"],
                "create_time": 1744700000.0,
                "connections": [],
            }
        ),
    ]
    sessions = collect_ssh_sessions({}, process_iter=lambda _: iter(processes))
    assert sessions == []
