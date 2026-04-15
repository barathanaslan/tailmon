"""`/ports` endpoint."""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends

from collector.sources import Sources
from shared.models import PortListResponse


def build_router(sources: Sources, auth_dep) -> APIRouter:
    r = APIRouter()

    @r.get(
        "/ports",
        response_model=PortListResponse,
        dependencies=[Depends(auth_dep)],
    )
    def ports() -> PortListResponse:
        return PortListResponse(
            ports=sources.system.listening_ports(),
            sampled_at=datetime.now(tz=timezone.utc),
        )

    return r
