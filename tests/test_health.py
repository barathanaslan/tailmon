def test_health_is_unauthenticated(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert body["version"]
    assert body["uptime_seconds"] >= 0
