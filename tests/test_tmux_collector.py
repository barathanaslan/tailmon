import subprocess
from unittest import mock

from collector.sources.tmux import TmuxCollector


def test_collector_handles_missing_binary():
    coll = TmuxCollector(cmd=["/does/not/exist/tmux-xyz"])
    assert coll.sessions() == []


def test_collector_non_zero_returncode():
    # `false` exits 1 with no stdout
    coll = TmuxCollector(cmd=["false"])
    assert coll.sessions() == []


def test_collector_parses_successful_output():
    coll = TmuxCollector(cmd=["true"])
    stdout = b"main|3|1|1744700000\nwork|1|0|1744710000\n"
    completed = subprocess.CompletedProcess(
        args=["true"], returncode=0, stdout=stdout, stderr=b""
    )
    with mock.patch("subprocess.run", return_value=completed):
        sessions = coll.sessions()
    assert [s.name for s in sessions] == ["main", "work"]


def test_collector_handles_timeout():
    coll = TmuxCollector(cmd=["sleep", "60"])

    def fake_run(*args, **kwargs):
        raise subprocess.TimeoutExpired(cmd=args[0], timeout=1)

    with mock.patch("subprocess.run", side_effect=fake_run):
        assert coll.sessions() == []


def test_collector_subprocess_uses_pinned_env_and_cwd(monkeypatch):
    # Fix 5: tmux subprocess must use explicit minimal env + cwd="/" and
    # pull its binary from the resolved candidate list.
    import collector.sources.tmux as tm

    fake_bin = "/tmp/fake-tmux-bin"
    monkeypatch.setattr(tm, "TMUX_BIN", fake_bin)
    monkeypatch.setattr(tm, "TMUX_CMD", [fake_bin, "ls", "-F", tm.TMUX_FORMAT])

    captured: dict = {}

    def fake_run(cmd, **kwargs):
        captured["cmd"] = cmd
        captured.update(kwargs)
        return subprocess.CompletedProcess(args=cmd, returncode=0, stdout=b"", stderr=b"")

    with mock.patch("collector.sources.tmux.subprocess.run", side_effect=fake_run):
        coll = TmuxCollector()
        coll.sessions()

    assert captured["cmd"][0] == fake_bin
    assert captured["env"] == tm.SUBPROCESS_ENV
    assert captured["env"]["PATH"] == "/usr/sbin:/usr/bin:/bin:/opt/homebrew/bin"
    assert captured["env"]["LANG"] == "C"
    assert captured["cwd"] == "/"


def test_collector_empty_when_binary_unresolved(monkeypatch):
    # Fix 5: when no tmux candidate exists, return [] without shelling out.
    import collector.sources.tmux as tm

    monkeypatch.setattr(tm, "TMUX_BIN", None)
    monkeypatch.setattr(tm, "TMUX_CMD", None)

    def should_not_run(*args, **kwargs):
        raise AssertionError("subprocess.run must not be called")

    with mock.patch("collector.sources.tmux.subprocess.run", side_effect=should_not_run):
        coll = TmuxCollector()
        assert coll.sessions() == []


# ---- B17: user-namespace wrap ----------------------------------------


def test_wrap_tmux_cmd_unwrapped_when_env_unset(monkeypatch):
    import collector.sources.tmux as tm

    monkeypatch.setattr(tm, "TMUX_USER", None)
    monkeypatch.setattr(tm, "SUDO_BIN", "/usr/bin/sudo")
    assert tm.wrap_tmux_cmd(["/opt/homebrew/bin/tmux", "ls"]) == [
        "/opt/homebrew/bin/tmux",
        "ls",
    ]


def test_wrap_tmux_cmd_wraps_when_env_set(monkeypatch):
    import collector.sources.tmux as tm

    monkeypatch.setattr(tm, "TMUX_USER", "alice")
    monkeypatch.setattr(tm, "SUDO_BIN", "/usr/bin/sudo")
    assert tm.wrap_tmux_cmd(["/opt/homebrew/bin/tmux", "ls"]) == [
        "/usr/bin/sudo",
        "-u",
        "alice",
        "-H",
        "--",
        "/opt/homebrew/bin/tmux",
        "ls",
    ]


def test_wrap_tmux_cmd_falls_back_when_sudo_missing(monkeypatch, caplog):
    import collector.sources.tmux as tm

    monkeypatch.setattr(tm, "TMUX_USER", "alice")
    monkeypatch.setattr(tm, "SUDO_BIN", None)
    with caplog.at_level("WARNING", logger="collector.sources.tmux"):
        result = tm.wrap_tmux_cmd(["/opt/homebrew/bin/tmux", "ls"])
    assert result == ["/opt/homebrew/bin/tmux", "ls"]
    assert any("sudo not found" in record.message for record in caplog.records)


def test_wrap_tmux_cmd_returns_fresh_list(monkeypatch):
    import collector.sources.tmux as tm

    monkeypatch.setattr(tm, "TMUX_USER", None)
    monkeypatch.setattr(tm, "SUDO_BIN", None)
    original = ["/opt/homebrew/bin/tmux", "ls"]
    result = tm.wrap_tmux_cmd(original)
    assert result == original
    assert result is not original  # defensive copy
