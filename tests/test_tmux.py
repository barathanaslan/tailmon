from collector.sources.tmux import parse_tmux_output


def test_tmux_sessions_endpoint(client, auth_headers):
    resp = client.get("/tmux/sessions", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["sessions"]) == 1
    assert body["sessions"][0]["name"] == "main"
    assert body["sessions"][0]["attached"] is True


def test_parse_tmux_output():
    raw = "main|3|1|1744700000\nwork|1|0|1744710000\n"
    sessions = parse_tmux_output(raw)
    assert [s.name for s in sessions] == ["main", "work"]
    assert sessions[0].windows == 3
    assert sessions[0].attached is True
    assert sessions[1].attached is False
    assert sessions[0].created_at is not None


def test_parse_tmux_output_empty():
    assert parse_tmux_output("") == []


def test_parse_tmux_output_malformed_lines_skipped():
    assert parse_tmux_output("no-separators\n") == []
