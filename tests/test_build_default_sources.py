from collector.sources import Sources, build_default_sources


def test_build_default_sources_returns_full_container():
    sources = build_default_sources()
    assert isinstance(sources, Sources)
    # All five must be non-None
    assert sources.system is not None
    assert sources.powermetrics is not None
    assert sources.tailscale is not None
    assert sources.ssh is not None
    assert sources.tmux is not None


def test_create_app_without_sources_uses_defaults(tmp_path, monkeypatch):
    from collector.app import create_app
    from collector.audit import AuditLogger

    audit = AuditLogger(tmp_path / "audit.log", mode=0o600)
    app = create_app(token="any", audit=audit)
    assert app.state.sources is not None
    assert app.state.audit is audit
