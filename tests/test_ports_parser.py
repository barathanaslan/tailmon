from types import SimpleNamespace

import psutil

from collector.sources.system import ports_from_connections


def _conn(**kwargs):
    return SimpleNamespace(**kwargs)


def _resolver(pid):
    return ("fakeproc", "fakeuser")


def test_ports_from_connections_tcp_listen_only():
    conns = [
        _conn(
            laddr=SimpleNamespace(ip="0.0.0.0", port=22),
            raddr=None,
            type=1,
            status=psutil.CONN_LISTEN,
            pid=100,
        ),
        _conn(
            laddr=SimpleNamespace(ip="127.0.0.1", port=55555),
            raddr=SimpleNamespace(ip="127.0.0.1", port=80),
            type=1,
            status=psutil.CONN_ESTABLISHED,
            pid=200,
        ),
    ]
    out = ports_from_connections(conns, resolver=_resolver)
    assert [p.port for p in out] == [22]
    assert out[0].protocol == "tcp"
    assert out[0].process_name == "fakeproc"


def test_ports_from_connections_includes_udp_bound():
    conns = [
        _conn(
            laddr=SimpleNamespace(ip="0.0.0.0", port=53),
            raddr=None,
            type=2,
            status="NONE",
            pid=300,
        ),
    ]
    out = ports_from_connections(conns, resolver=_resolver)
    assert [(p.protocol, p.port) for p in out] == [("udp", 53)]


def test_ports_from_connections_skips_unknown_type():
    conns = [
        _conn(laddr=SimpleNamespace(ip="0.0.0.0", port=1), type=99, status="?", pid=1),
    ]
    assert ports_from_connections(conns, resolver=_resolver) == []


def test_ports_from_connections_skips_bad_laddr():
    conns = [
        _conn(laddr=None, type=1, status=psutil.CONN_LISTEN, pid=1),
        _conn(laddr=SimpleNamespace(ip="0.0.0.0", port=0), type=1, status=psutil.CONN_LISTEN, pid=2),
        _conn(laddr=SimpleNamespace(), type=1, status=psutil.CONN_LISTEN, pid=3),
    ]
    assert ports_from_connections(conns, resolver=_resolver) == []


def test_ports_from_connections_resolver_caches(monkeypatch):
    calls: list[int] = []

    def counting_resolver(pid):
        calls.append(pid)
        return ("p", "u")

    conns = [
        _conn(
            laddr=SimpleNamespace(ip="0.0.0.0", port=22),
            type=1,
            status=psutil.CONN_LISTEN,
            pid=42,
        ),
        _conn(
            laddr=SimpleNamespace(ip="0.0.0.0", port=80),
            type=1,
            status=psutil.CONN_LISTEN,
            pid=42,
        ),
    ]
    ports_from_connections(conns, resolver=counting_resolver)
    assert calls == [42]  # second call hits the cache


def test_ports_from_connections_none_pid():
    conns = [
        _conn(
            laddr=SimpleNamespace(ip="0.0.0.0", port=5000),
            type=1,
            status=psutil.CONN_LISTEN,
            pid=None,
        ),
    ]
    out = ports_from_connections(conns, resolver=_resolver)
    assert len(out) == 1
    assert out[0].pid is None
    assert out[0].process_name is None
