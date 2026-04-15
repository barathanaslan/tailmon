"""Sync HTTP client wrapping the studiod collector API.

Returns parsed pydantic models from ``shared.models`` rather than raw dicts.
This keeps the CLI rendering code type-safe and ensures the JSON schema
contract is enforced at the boundary.

Exceptions are normalized to :class:`StudioClientError`, which the CLI
top-level catches and renders as a one-line red message (no traceback).
"""

from __future__ import annotations

from typing import Any

import httpx

from shared.models import (
    HealthResponse,
    PortListResponse,
    ProcessListResponse,
    SSHSessionListResponse,
    StatsResponse,
    TmuxSessionListResponse,
)
from studio_cli.config import ClientConfig


class StudioClientError(RuntimeError):
    """User-facing client error. The message is printed as-is."""


class StudioClient:
    """Thin wrapper around :class:`httpx.Client`.

    Parameters
    ----------
    cfg:
        Resolved client config. Used for the base URL, timeout, and ssh host.
    token:
        Bearer token. Pass ``None`` only when the caller is exclusively
        hitting unauthenticated endpoints (just ``/health``).
    transport:
        Optional :class:`httpx.BaseTransport`. Tests inject
        :class:`httpx.MockTransport` here to fake the collector.
    """

    def __init__(
        self,
        cfg: ClientConfig,
        token: str | None,
        *,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self._cfg = cfg
        headers: dict[str, str] = {"Accept": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        self._client = httpx.Client(
            base_url=cfg.collector_url,
            headers=headers,
            timeout=cfg.timeout_seconds,
            transport=transport,
        )

    # ----- lifecycle -----

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> StudioClient:
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    # ----- internals -----

    def _handle_response(self, resp: httpx.Response) -> dict:
        if resp.status_code == 401:
            raise StudioClientError(
                "collector rejected token (401) -- "
                f"check {self._cfg.token_file} matches /etc/studiod/token on the Mac Studio"
            )
        if resp.status_code == 403:
            detail = _extract_detail(resp) or "forbidden"
            raise StudioClientError(f"collector refused request (403): {detail}")
        if resp.status_code == 404:
            detail = _extract_detail(resp) or "not found"
            raise StudioClientError(f"collector returned 404: {detail}")
        if resp.status_code >= 500:
            raise StudioClientError(
                f"collector internal error ({resp.status_code}): {resp.text[:200]}"
            )
        if resp.status_code >= 400:
            detail = _extract_detail(resp) or resp.text[:200]
            raise StudioClientError(
                f"collector returned {resp.status_code}: {detail}"
            )
        try:
            return resp.json()
        except ValueError as exc:
            raise StudioClientError(
                f"collector returned non-JSON response: {resp.text[:200]}"
            ) from exc

    def _post(self, path: str, json_body: dict[str, Any]) -> dict:
        try:
            resp = self._client.post(path, json=json_body)
        except httpx.ConnectError as exc:
            raise StudioClientError(
                f"cannot reach collector at {self._cfg.collector_url} -- "
                f"is studiod running? ({exc})"
            ) from exc
        except httpx.TimeoutException as exc:
            raise StudioClientError(
                f"timed out talking to collector at {self._cfg.collector_url} "
                f"after {self._cfg.timeout_seconds}s"
            ) from exc
        except httpx.HTTPError as exc:
            raise StudioClientError(
                f"HTTP error talking to collector at {self._cfg.collector_url}: {exc}"
            ) from exc
        return self._handle_response(resp)

    def _get(self, path: str, params: dict[str, Any] | None = None) -> dict:
        try:
            resp = self._client.get(path, params=params)
        except httpx.ConnectError as exc:
            raise StudioClientError(
                f"cannot reach collector at {self._cfg.collector_url} -- "
                f"is studiod running? ({exc})"
            ) from exc
        except httpx.TimeoutException as exc:
            raise StudioClientError(
                f"timed out talking to collector at {self._cfg.collector_url} "
                f"after {self._cfg.timeout_seconds}s"
            ) from exc
        except httpx.HTTPError as exc:
            raise StudioClientError(
                f"HTTP error talking to collector at {self._cfg.collector_url}: {exc}"
            ) from exc

        if resp.status_code == 401:
            raise StudioClientError(
                "collector rejected token (401) -- "
                f"check {self._cfg.token_file} matches /etc/studiod/token on the Mac Studio"
            )
        if resp.status_code == 403:
            raise StudioClientError(
                "collector returned 403 -- token is valid but the request was forbidden"
            )
        if resp.status_code >= 500:
            raise StudioClientError(
                f"collector internal error ({resp.status_code}): {resp.text[:200]}"
            )
        if resp.status_code >= 400:
            raise StudioClientError(
                f"collector returned {resp.status_code}: {resp.text[:200]}"
            )

        try:
            return resp.json()
        except ValueError as exc:
            raise StudioClientError(
                f"collector returned non-JSON response: {resp.text[:200]}"
            ) from exc

    # ----- typed endpoints -----

    def health(self) -> HealthResponse:
        return HealthResponse.model_validate(self._get("/health"))

    def stats(self) -> StatsResponse:
        return StatsResponse.model_validate(self._get("/stats"))

    def processes(
        self,
        *,
        limit: int = 20,
        include_full_cmdline: bool = False,
    ) -> ProcessListResponse:
        params: dict[str, Any] = {
            "limit": limit,
            "include_full_cmdline": str(include_full_cmdline).lower(),
        }
        return ProcessListResponse.model_validate(self._get("/processes", params=params))

    def ports(self) -> PortListResponse:
        return PortListResponse.model_validate(self._get("/ports"))

    def ssh_sessions(self) -> SSHSessionListResponse:
        return SSHSessionListResponse.model_validate(self._get("/ssh/sessions"))

    def tmux_sessions(self) -> TmuxSessionListResponse:
        return TmuxSessionListResponse.model_validate(self._get("/tmux/sessions"))

    # ----- Phase 3 write endpoints -----

    def kill(self, *, pid: int, signal: int = 15) -> dict:
        """POST /kill. Returns the decoded JSON response body."""
        return self._post("/kill", {"pid": pid, "signal": signal})

    def ssh_kick(self, *, pid: int) -> dict:
        """POST /ssh/kick. Returns the decoded JSON response body."""
        return self._post("/ssh/kick", {"pid": pid})

    def tmux_new(self, *, name: str) -> dict:
        """POST /tmux/new. Returns the decoded JSON response body."""
        return self._post("/tmux/new", {"name": name})


def _extract_detail(resp: httpx.Response) -> str | None:
    """Pull the FastAPI-style ``detail`` field out of an error response."""
    try:
        data = resp.json()
    except ValueError:
        return None
    if isinstance(data, dict):
        detail = data.get("detail")
        if isinstance(detail, str):
            return detail
    return None
