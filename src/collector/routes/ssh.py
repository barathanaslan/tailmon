"""`/ssh/sessions` endpoint.

Phase 1 is read-only. The `/ssh/kick` control endpoint is intentionally left
for Phase 3 (see docs/plans).
"""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends

from collector.sources import Sources
from shared.models import SSHSessionListResponse

# TODO(phase-3): add POST /ssh/kick {pid: int} -> terminate session.


def build_router(sources: Sources, auth_dep) -> APIRouter:
    r = APIRouter()

    @r.get(
        "/ssh/sessions",
        response_model=SSHSessionListResponse,
        dependencies=[Depends(auth_dep)],
    )
    def ssh_sessions() -> SSHSessionListResponse:
        peer_map = sources.tailscale.peer_map()
        return SSHSessionListResponse(
            sessions=sources.ssh.sessions(peer_map),
            sampled_at=datetime.now(tz=timezone.utc),
        )

    return r
