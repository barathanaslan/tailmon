import subprocess
from unittest import mock

from collector.sources.tailscale import TailscaleCollector, parse_tailscale_status


def test_parse_status_builds_peer_map(tailscale_fixture_data):
    peers = parse_tailscale_status(tailscale_fixture_data)
    assert set(peers.keys()) == {"100.64.0.1", "100.64.0.2", "100.64.0.3"}
    assert peers["100.64.0.2"].hostname == "macbook-air"
    assert peers["100.64.0.2"].user_display_name == "Core Operator"
    assert peers["100.64.0.3"].user_display_name == "Friend One"


def test_parse_status_handles_empty():
    assert parse_tailscale_status({}) == {}
    assert parse_tailscale_status({"Peer": None}) == {}


def test_collector_handles_missing_binary():
    coll = TailscaleCollector(cmd=["/does/not/exist/tailscale-xyz"])
    assert coll.peer_map() == {}


def test_collector_handles_non_zero_returncode():
    coll = TailscaleCollector(cmd=["false"])
    assert coll.peer_map() == {}


def test_collector_handles_bad_json(tailscale_fixture_data):
    coll = TailscaleCollector(cmd=["true"])
    completed = subprocess.CompletedProcess(
        args=["true"], returncode=0, stdout=b"not json", stderr=b""
    )
    with mock.patch("subprocess.run", return_value=completed):
        assert coll.peer_map() == {}


def test_collector_parses_real_fixture(tailscale_fixture_data):
    import json as _json

    coll = TailscaleCollector(cmd=["true"])
    completed = subprocess.CompletedProcess(
        args=["true"],
        returncode=0,
        stdout=_json.dumps(tailscale_fixture_data).encode(),
        stderr=b"",
    )
    with mock.patch("subprocess.run", return_value=completed):
        peers = coll.peer_map()
    assert "100.64.0.2" in peers


def test_collector_caches(monkeypatch):
    coll = TailscaleCollector(cmd=["true"], cache_ttl=60.0)
    calls: list[int] = []

    def fake_fetch():
        calls.append(1)
        return {}

    monkeypatch.setattr(coll, "_fetch_uncached", fake_fetch)
    coll.peer_map()
    coll.peer_map()
    assert len(calls) == 1


def test_collector_handles_timeout():
    coll = TailscaleCollector(cmd=["sleep", "60"])

    def fake_run(*args, **kwargs):
        raise subprocess.TimeoutExpired(cmd=args[0], timeout=1)

    with mock.patch("subprocess.run", side_effect=fake_run):
        assert coll.peer_map() == {}


def test_collector_subprocess_uses_pinned_env_and_cwd(monkeypatch):
    # Fix 5: tailscale subprocess must use explicit minimal env + cwd="/"
    # and the binary path must come from the resolved candidate list, not
    # from whatever PATH happens to contain.
    import collector.sources.tailscale as ts

    fake_bin = "/tmp/fake-tailscale-bin"
    monkeypatch.setattr(ts, "TAILSCALE_BIN", fake_bin)
    monkeypatch.setattr(ts, "TAILSCALE_CMD", [fake_bin, "status", "--json"])

    captured: dict = {}

    def fake_run(cmd, **kwargs):
        captured["cmd"] = cmd
        captured.update(kwargs)
        return subprocess.CompletedProcess(
            args=cmd, returncode=0, stdout=b"{}", stderr=b""
        )

    with mock.patch("collector.sources.tailscale.subprocess.run", side_effect=fake_run):
        coll = ts.TailscaleCollector()
        coll.peer_map()

    assert captured["cmd"] == [fake_bin, "status", "--json"]
    assert captured["env"] == ts.SUBPROCESS_ENV
    assert captured["cwd"] == "/"


def test_collector_empty_when_binary_unresolved(monkeypatch):
    # Fix 5: if no tailscale binary candidate exists, the collector never
    # shells out and just returns an empty peer map gracefully.
    import collector.sources.tailscale as ts

    monkeypatch.setattr(ts, "TAILSCALE_BIN", None)
    monkeypatch.setattr(ts, "TAILSCALE_CMD", None)
    called = {"n": 0}

    def should_not_run(*args, **kwargs):
        called["n"] += 1
        raise AssertionError("subprocess.run must not be called")

    with mock.patch("collector.sources.tailscale.subprocess.run", side_effect=should_not_run):
        coll = ts.TailscaleCollector()
        assert coll.peer_map() == {}
    assert called["n"] == 0


def test_parse_tailscale_status_self_only():
    data = {
        "Self": {
            "HostName": "host",
            "TailscaleIPs": ["100.0.0.1"],
            "OS": "macOS",
            "UserID": "1",
        },
        "User": {"1": {"DisplayName": "name"}},
    }
    peers = parse_tailscale_status(data)
    assert peers["100.0.0.1"].user_display_name == "name"
