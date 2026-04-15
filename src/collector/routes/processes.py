"""`/processes` endpoint."""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Query

from collector.sources import Sources
from shared.models import ProcessListResponse


def build_router(sources: Sources, auth_dep) -> APIRouter:
    r = APIRouter()

    @r.get(
        "/processes",
        response_model=ProcessListResponse,
        dependencies=[Depends(auth_dep)],
    )
    def processes(
        limit: int = Query(default=50, ge=0, le=1000),
        include_full_cmdline: bool = Query(
            default=False,
            description=(
                "If true, return the full joined process command line "
                "(argv). WARNING: this may expose secrets passed on the "
                "command line, e.g. curl -H 'Authorization: Bearer ...' "
                "or mysql -pPASSWORD. Use with care. Default is false, "
                "which returns only argv[0] (the executable path)."
            ),
        ),
    ) -> ProcessListResponse:
        """List processes sorted by CPU then memory.

        By default, the ``cmdline`` field on each :class:`ProcessInfo` is
        only the executable path (argv[0]) to avoid leaking secrets that
        may have been passed as command-line arguments by other users
        sharing the machine. Pass ``include_full_cmdline=true`` to get the
        full joined command line -- this may expose secrets, use with care.
        """
        procs, total = sources.system.process_list(
            limit=limit,
            include_full_cmdline=include_full_cmdline,
        )
        return ProcessListResponse(
            processes=procs,
            total_count=total,
            sampled_at=datetime.now(tz=timezone.utc),
        )

    return r
