"""FastAPI dependency that enforces the bearer token."""

from __future__ import annotations

from fastapi import Header, HTTPException, Request, status


def _extract_bearer(header: str | None) -> str | None:
    if not header:
        return None
    parts = header.split(None, 1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        return None
    return parts[1].strip()


def require_token_factory(expected_token: str):
    """Build a FastAPI dependency bound to an expected token.

    The token is captured at app-creation time so that tests can override it
    via the app factory.
    """
    from shared.auth import compare

    async def dependency(
        request: Request,
        authorization: str | None = Header(default=None),
    ) -> None:
        presented = _extract_bearer(authorization)
        if presented is None or not compare(expected_token, presented):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="missing or invalid bearer token",
                headers={"WWW-Authenticate": "Bearer"},
            )
        # attach for downstream logging hooks if we ever want it
        request.state.authenticated = True

    return dependency
