def test_missing_header_is_401(client):
    resp = client.get("/stats")
    assert resp.status_code == 401


def test_wrong_scheme_is_401(client):
    resp = client.get("/stats", headers={"Authorization": "Basic abc"})
    assert resp.status_code == 401


def test_wrong_token_is_401(client):
    resp = client.get("/stats", headers={"Authorization": "Bearer nope"})
    assert resp.status_code == 401


def test_correct_token_is_200(client, auth_headers):
    resp = client.get("/stats", headers=auth_headers)
    assert resp.status_code == 200


def test_openapi_schema_is_disabled(client):
    # Fix 1: the collector must not expose the OpenAPI schema or the
    # Swagger / ReDoc UI. These endpoints would leak the full API surface
    # (including authenticated routes) to any unauthenticated caller.
    for path in ("/openapi.json", "/docs", "/redoc"):
        resp = client.get(path)
        assert resp.status_code == 404, (
            f"{path} should be 404, got {resp.status_code}"
        )
