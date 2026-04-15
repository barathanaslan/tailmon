def test_ports_lists_tcp_listeners(client, auth_headers):
    resp = client.get("/ports", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    ports = body["ports"]
    assert {p["port"] for p in ports} == {22, 8765}
    ssh_port = next(p for p in ports if p["port"] == 22)
    assert ssh_port["process_name"] == "sshd"
    assert ssh_port["user"] == "root"
    assert ssh_port["protocol"] == "tcp"
