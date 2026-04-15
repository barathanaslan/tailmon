from dataclasses import dataclass, field
from datetime import datetime, timezone

from fastapi.testclient import TestClient

from collector.app import create_app
from collector.audit import AuditLogger
from collector.sources import Sources
from shared.models import ProcessInfo


@dataclass
class _CmdlineFakeSystem:
    """Fake system source that honors include_full_cmdline the same way
    the real SystemCollector does: stores raw argv lists and joins / slices
    them at call time.
    """

    raw_processes: list[tuple[int, list[str]]] = field(default_factory=list)

    def cpu_stats(self):  # pragma: no cover - unused here
        raise NotImplementedError

    def memory_stats(self):  # pragma: no cover - unused here
        raise NotImplementedError

    def listening_ports(self):  # pragma: no cover - unused here
        return []

    def process_list(self, limit=None, *, include_full_cmdline=False):
        out: list[ProcessInfo] = []
        for pid, argv in self.raw_processes:
            cmdline = " ".join(argv) if include_full_cmdline else (argv[0] if argv else "")
            out.append(
                ProcessInfo(
                    pid=pid,
                    ppid=0,
                    user="tester",
                    name=argv[0] if argv else "",
                    cmdline=cmdline,
                    cpu_percent=0.0,
                    memory_rss_bytes=0,
                    memory_percent=0.0,
                    status="running",
                    create_time=datetime(2026, 4, 15, 12, 0, tzinfo=timezone.utc),
                )
            )
        return out, len(out)


def _cmdline_client(fake_sources, audit_logger):
    argv_fake = _CmdlineFakeSystem(
        raw_processes=[
            (101, ["curl", "-H", "Authorization: Bearer SECRET", "http://foo"]),
            (202, ["mysql", "-u", "root", "-pPASSWORD"]),
        ]
    )
    sources = Sources(
        system=argv_fake,
        powermetrics=fake_sources.powermetrics,
        tailscale=fake_sources.tailscale,
        ssh=fake_sources.ssh,
        tmux=fake_sources.tmux,
    )
    app = create_app(token="unit-test-token", sources=sources, audit=audit_logger)
    return TestClient(app)


def test_processes_cmdline_default_is_argv0_only(fake_sources, audit_logger):
    # Fix 2: by default, /processes must NOT leak full argv. A friend on
    # the shared machine passing secrets via `curl -H "Authorization: ..."`
    # or `mysql -pPASSWORD` should only show the executable name.
    client = _cmdline_client(fake_sources, audit_logger)
    resp = client.get(
        "/processes",
        headers={"Authorization": "Bearer unit-test-token"},
    )
    assert resp.status_code == 200
    procs = resp.json()["processes"]
    cmdlines = {p["pid"]: p["cmdline"] for p in procs}
    assert cmdlines[101] == "curl"
    assert cmdlines[202] == "mysql"
    # Secrets must not appear anywhere in the response body.
    body = resp.text
    assert "SECRET" not in body
    assert "PASSWORD" not in body


def test_processes_include_full_cmdline_opt_in(fake_sources, audit_logger):
    # Fix 2: explicit opt-in returns the full joined argv.
    client = _cmdline_client(fake_sources, audit_logger)
    resp = client.get(
        "/processes?include_full_cmdline=true",
        headers={"Authorization": "Bearer unit-test-token"},
    )
    assert resp.status_code == 200
    procs = resp.json()["processes"]
    cmdlines = {p["pid"]: p["cmdline"] for p in procs}
    assert cmdlines[101] == "curl -H Authorization: Bearer SECRET http://foo"
    assert cmdlines[202] == "mysql -u root -pPASSWORD"


def test_processes_returns_sorted_list(client, auth_headers):
    resp = client.get("/processes", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["total_count"] == 2
    procs = body["processes"]
    assert procs[0]["pid"] == 4242  # highest cpu_percent wins
    assert procs[0]["name"] == "python"


def test_processes_limit(client, auth_headers):
    resp = client.get("/processes?limit=1", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["processes"]) == 1
    assert body["total_count"] == 2


def test_processes_limit_rejects_out_of_range(client, auth_headers):
    resp = client.get("/processes?limit=-1", headers=auth_headers)
    assert resp.status_code == 422
