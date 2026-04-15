"""`/stats` endpoint: CPU, memory, GPU, power snapshot."""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends

from collector.sources import Sources
from shared.models import StatsResponse


def build_router(sources: Sources, auth_dep) -> APIRouter:
    r = APIRouter()

    @r.get("/stats", response_model=StatsResponse, dependencies=[Depends(auth_dep)])
    def stats() -> StatsResponse:
        cpu = sources.system.cpu_stats()
        memory = sources.system.memory_stats()
        gpu, power = sources.powermetrics.sample()
        return StatsResponse(
            cpu=cpu,
            memory=memory,
            gpu=gpu,
            power=power,
            timestamp=datetime.now(tz=timezone.utc),
        )

    return r
