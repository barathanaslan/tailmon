"""Unauthenticated liveness endpoint."""

from __future__ import annotations

import time

from fastapi import APIRouter

from shared.config import VERSION
from shared.models import HealthResponse

router = APIRouter()


def build_router(started_at: float) -> APIRouter:
    r = APIRouter()

    @r.get("/health", response_model=HealthResponse)
    def health() -> HealthResponse:
        return HealthResponse(
            ok=True,
            version=VERSION,
            uptime_seconds=round(time.monotonic() - started_at, 3),
        )

    return r
