import subprocess
from unittest import mock

from collector.sources.powermetrics import (
    PowermetricsCollector,
    _gpu_stats_from_text,
    _power_stats_from_text,
    parse_powermetrics_text,
)


def test_parse_text_fixture(powermetrics_fixture_bytes):
    gpu, power = parse_powermetrics_text(powermetrics_fixture_bytes)
    assert gpu is not None
    # idle residency 25% -> percent busy 75%
    assert 74.0 < gpu.percent < 76.0
    assert gpu.frequency_mhz is not None
    assert 1397.0 < gpu.frequency_mhz < 1399.0
    assert power is not None
    assert power.cpu_package_watts == 4.2
    assert power.gpu_watts == 6.8
    assert power.total_watts == 12.0


def test_parse_text_empty():
    gpu, power = parse_powermetrics_text(b"")
    assert gpu is None
    assert power is None


def test_parse_text_garbage():
    gpu, power = parse_powermetrics_text(b"not a powermetrics sample at all")
    assert gpu is None
    assert power is None


def test_parse_text_accepts_str():
    # The parser accepts both bytes (from subprocess.stdout) and str (for
    # ergonomic tests and ad-hoc debugging).
    text = (
        "CPU Power: 1000 mW\n"
        "GPU Power: 500 mW\n"
        "Combined Power (CPU + GPU + ANE): 1500 mW\n"
        "GPU HW active frequency: 800 MHz\n"
        "GPU idle residency:  40.00%\n"
    )
    gpu, power = parse_powermetrics_text(text)
    assert gpu is not None
    assert gpu.percent == 60.0
    assert gpu.frequency_mhz == 800.0
    assert power is not None
    assert power.cpu_package_watts == 1.0
    assert power.gpu_watts == 0.5
    assert power.total_watts == 1.5


def test_parse_text_combined_falls_back_to_cpu_plus_gpu():
    # When "Combined Power" is absent the parser sums cpu + gpu.
    text = "CPU Power: 3000 mW\nGPU Power: 2000 mW\n"
    _, power = parse_powermetrics_text(text)
    assert power is not None
    assert power.cpu_package_watts == 3.0
    assert power.gpu_watts == 2.0
    assert power.total_watts == 5.0


def test_parse_text_returns_partial_gpu_only():
    # No power fields at all, only GPU residency. Power -> None, GPU populated.
    text = "GPU HW active frequency: 1200 MHz\nGPU idle residency:  10.00%\n"
    gpu, power = parse_powermetrics_text(text)
    assert gpu is not None
    assert gpu.percent == 90.0
    assert gpu.frequency_mhz == 1200.0
    assert power is None


def test_parse_text_missing_gpu_section():
    text = "CPU Power: 2000 mW\n"
    gpu, power = parse_powermetrics_text(text)
    assert gpu is None
    assert power is not None
    assert power.cpu_package_watts == 2.0
    assert power.gpu_watts == 0.0
    assert power.total_watts == 2.0


def test_gpu_stats_from_text_missing_both():
    assert _gpu_stats_from_text("totally unrelated text") is None


def test_power_stats_from_text_missing():
    assert _power_stats_from_text("nothing interesting here") is None


def test_collector_handles_missing_binary(monkeypatch):
    coll = PowermetricsCollector(cmd=["/does/not/exist/powermetrics-xyz"])
    gpu, power = coll.sample()
    assert gpu is None
    assert power is None


def test_collector_caches(monkeypatch):
    coll = PowermetricsCollector(cmd=["false"], cache_ttl=60.0)
    calls: list[int] = []

    def fake_sample_uncached():
        calls.append(1)
        return None, None

    monkeypatch.setattr(coll, "_sample_uncached", fake_sample_uncached)
    coll.sample()
    coll.sample()
    coll.sample()
    assert len(calls) == 1


def test_collector_handles_non_zero_returncode():
    coll = PowermetricsCollector(cmd=["false"])
    gpu, power = coll.sample()
    assert gpu is None
    assert power is None
    assert coll.sample() == (None, None)


def test_collector_handles_timeout(monkeypatch):
    coll = PowermetricsCollector(cmd=["sleep", "60"])

    def fake_run(*args, **kwargs):
        raise subprocess.TimeoutExpired(cmd=args[0], timeout=1)

    with mock.patch("subprocess.run", side_effect=fake_run):
        assert coll.sample() == (None, None)


def test_collector_parses_successful_output(powermetrics_fixture_bytes):
    coll = PowermetricsCollector(cmd=["true"])
    completed = subprocess.CompletedProcess(
        args=["true"],
        returncode=0,
        stdout=powermetrics_fixture_bytes,
        stderr=b"",
    )
    with mock.patch("subprocess.run", return_value=completed):
        gpu, power = coll.sample()
    assert gpu is not None
    assert power is not None
    assert power.cpu_package_watts == 4.2


def test_collector_subprocess_uses_pinned_env_and_cwd(monkeypatch):
    # Fix 5: subprocess calls must go out with an explicit minimal env and
    # cwd="/" so PATH manipulation / CWD-relative attacks don't work when
    # the daemon eventually runs as root.
    import collector.sources.powermetrics as pm

    fake_bin = "/tmp/fake-powermetrics-bin"
    monkeypatch.setattr(pm, "POWERMETRICS_BIN", fake_bin)
    monkeypatch.setattr(pm, "POWERMETRICS_CMD", pm._build_cmd(fake_bin))

    captured: dict = {}

    def fake_run(cmd, **kwargs):
        captured["cmd"] = cmd
        captured.update(kwargs)
        return subprocess.CompletedProcess(args=cmd, returncode=0, stdout=b"", stderr=b"")

    with mock.patch("collector.sources.powermetrics.subprocess.run", side_effect=fake_run):
        coll = pm.PowermetricsCollector()
        coll.sample()

    assert captured["cmd"][0] == fake_bin
    # The command must not contain the plist format flag -- we parse text.
    assert "-f" not in captured["cmd"]
    assert "plist" not in captured["cmd"]
    assert captured["env"] == pm.SUBPROCESS_ENV
    assert captured["env"]["PATH"] == "/usr/sbin:/usr/bin:/bin:/opt/homebrew/bin"
    assert captured["env"]["LANG"] == "C"
    assert captured["cwd"] == "/"
