from collector.app import create_app
from collector.sources import Sources
from fastapi.testclient import TestClient
from tests.conftest import (
    TEST_TOKEN,
    FakePowermetrics,
    FakeSSH,
    FakeSystem,
    FakeTailscale,
    FakeTmux,
)


def test_stats_full_payload(client, auth_headers):
    resp = client.get("/stats", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["cpu"]["percent_total"] == 21.5
    assert len(body["cpu"]["percent_per_core"]) == 4
    assert body["memory"]["percent"] == 37.5
    assert body["gpu"]["percent"] == 42.0
    assert body["power"]["total_watts"] == 12.0
    assert "timestamp" in body


def test_stats_gracefully_degrades_when_powermetrics_unavailable(
    auth_headers, audit_logger
):
    sources = Sources(
        system=FakeSystem(),
        powermetrics=FakePowermetrics(gpu=None, power=None),
        tailscale=FakeTailscale(),
        ssh=FakeSSH(),
        tmux=FakeTmux(),
    )
    app = create_app(token=TEST_TOKEN, sources=sources, audit=audit_logger)
    client = TestClient(app)
    resp = client.get("/stats", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["gpu"] is None
    assert body["power"] is None
    assert body["cpu"]["percent_total"] == 21.5
