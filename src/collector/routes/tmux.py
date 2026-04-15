"""`/tmux/sessions` endpoint.

The `/tmux/new` control endpoint is intentionally left for Phase 3.
"""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends

from collector.sources import Sources
from shared.models import TmuxSessionListResponse

# TODO(phase-3): add POST /tmux/new {name: str} -> create a new tmux session.


def build_router(sources: Sources, auth_dep) -> APIRouter:
    r = APIRouter()

    @r.get(
        "/tmux/sessions",
        response_model=TmuxSessionListResponse,
        dependencies=[Depends(auth_dep)],
    )
    def tmux_sessions() -> TmuxSessionListResponse:
        return TmuxSessionListResponse(
            sessions=sources.tmux.sessions(),
            sampled_at=datetime.now(tz=timezone.utc),
        )

    return r
