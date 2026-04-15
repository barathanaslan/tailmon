"""FastAPI app factory.

Dependency injection of data sources and the bearer token makes the app
trivially testable: tests pass in fakes + a known token and drive the app
through `fastapi.testclient.TestClient`.
"""

from __future__ import annotations

import time

from fastapi import FastAPI

from collector.audit import AuditLogger, build_default_audit_logger
from collector.auth import require_token_factory
from collector.routes import control as control_routes
from collector.routes import health as health_routes
from collector.routes import ports as ports_routes
from collector.routes import processes as processes_routes
from collector.routes import ssh as ssh_routes
from collector.routes import stats as stats_routes
from collector.routes import tmux as tmux_routes
from collector.sources import Sources, build_default_sources
from shared.config import VERSION


def create_app(
    *,
    token: str,
    sources: Sources | None = None,
    audit: AuditLogger | None = None,
) -> FastAPI:
    """Build a FastAPI application with fully-injected deps.

    Args:
        token: the expected bearer token, compared in constant time.
        sources: optional pre-built :class:`Sources`; defaults to real system.
        audit: optional pre-built :class:`AuditLogger`; defaults to the
            on-disk rotating-file implementation resolved per dev/prod mode.
    """
    if sources is None:
        sources = build_default_sources()
    if audit is None:
        audit = build_default_audit_logger()

    started_at = time.monotonic()
    auth_dep = require_token_factory(token)

    app = FastAPI(
        title="studiod",
        version=VERSION,
        description="Read-only collector daemon for studio-cli (Phase 1).",
        # Security: do not expose OpenAPI schema or interactive docs. The
        # daemon will eventually run as root and the API surface must not be
        # discoverable by unauthenticated callers on the Tailscale network.
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )

    app.include_router(health_routes.build_router(started_at))
    app.include_router(stats_routes.build_router(sources, auth_dep))
    app.include_router(processes_routes.build_router(sources, auth_dep))
    app.include_router(ports_routes.build_router(sources, auth_dep))
    app.include_router(ssh_routes.build_router(sources, auth_dep))
    app.include_router(tmux_routes.build_router(sources, auth_dep))
    app.include_router(
        control_routes.build_router(
            sources,
            auth_dep,
            audit,
            expected_token=token,
        )
    )

    # Attach a couple of objects so tests can reach them if needed.
    app.state.sources = sources
    app.state.token = token
    app.state.audit = audit
    app.state.started_at = started_at

    return app
