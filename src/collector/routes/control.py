"""Write-side control endpoints: /kill, /ssh/kick, /tmux/new.

Phase 3 (backlog B8-B10). Every endpoint:

* Requires the same bearer-token dependency as the read endpoints.
* Appends an audit record to :mod:`collector.audit` on both success AND
  refusal. An auditable action without a record must fail closed -- if the
  audit write fails we return 500 instead of proceeding.
* Refuses destructive operations against the daemon itself, ``launchd`` (pid
  1), and a named denylist of critical macOS system processes.
* Never uses ``shell=True``. Subprocess invocations reuse the pinned env /
  cwd / absolute-binary pattern from :mod:`collector.sources.tmux`.

The endpoints themselves delegate to small pure helpers so the validation
logic can be unit-tested without spinning up a TestClient.
"""

from __future__ import annotations

import logging
import os
import re
import signal as signal_module
import subprocess
from datetime import datetime, timezone
from typing import Any

import psutil
from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, Field

from collector.audit import AuditLogger, AuditWriteError, token_fingerprint
from collector.sources import Sources
from collector.sources.tmux import (
    SUBPROCESS_CWD,
    SUBPROCESS_ENV,
    TMUX_BIN,
    wrap_tmux_cmd,
)
from shared.models import SSHSession

logger = logging.getLogger(__name__)

_UNSET: object = object()

# Signals we are willing to deliver via /kill. Anything else is a 400.
_ALLOWED_KILL_SIGNALS: frozenset[int] = frozenset(
    {
        signal_module.SIGHUP,   # 1
        signal_module.SIGINT,   # 2
        signal_module.SIGKILL,  # 9
        signal_module.SIGTERM,  # 15
    }
)

# Refuse to signal any of these critical macOS processes no matter what.
# Keep the list short and obvious; extend only with care. See Phase 3 plan.
DENY_PROCESS_NAMES: frozenset[str] = frozenset(
    {
        "launchd",
        "kernel_task",
        "WindowServer",
        "loginwindow",
        "coreaudiod",
        "systemstats",
        "runningboardd",
    }
)

# Strict tmux session-name regex -- matches the CLI's client-side check in
# ``studio_cli.commands.tmux``. Kept independent so the two layers can evolve
# together without importing across package boundaries.
_TMUX_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_TMUX_NAME_MAX_LEN = 64


# ---------- request / response models ----------


class KillRequest(BaseModel):
    pid: int = Field(..., ge=1, le=2**31 - 1, description="Target PID")
    signal: int = Field(
        default=int(signal_module.SIGTERM),
        description="POSIX signal number (default SIGTERM).",
    )


class KillResponse(BaseModel):
    pid: int
    signal: int
    process_name: str
    user: str | None = None
    sent_at: datetime


class SSHKickRequest(BaseModel):
    pid: int = Field(..., ge=1, le=2**31 - 1)


class SSHKickResponse(BaseModel):
    session: SSHSession
    sent_at: datetime


class TmuxNewRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=_TMUX_NAME_MAX_LEN)


class TmuxNewResponse(BaseModel):
    name: str
    created: bool
    exists: bool


# ---------- helpers ----------


def _refuse(
    audit: AuditLogger,
    *,
    action: str,
    fields: dict[str, Any],
    http_status: int,
    reason: str,
) -> None:
    """Write an audit record for a refused call and raise ``HTTPException``.

    ``fields`` should already contain the per-action context (``pid``,
    ``name``, etc.); we add ``result=err:<reason>`` and re-raise.
    """
    record = dict(fields)
    record["result"] = f"err:{reason}"
    try:
        audit.write(action, record)
    except AuditWriteError as exc:
        logger.warning("audit write failed for refusal %s: %s", action, exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="audit log unavailable; refusing to answer",
        ) from exc
    raise HTTPException(status_code=http_status, detail=reason)


def _record_ok(audit: AuditLogger, action: str, fields: dict[str, Any]) -> None:
    """Write a success audit record. 500 on audit failure (fail-closed)."""
    record = dict(fields)
    record["result"] = "ok"
    try:
        audit.write(action, record)
    except AuditWriteError as exc:
        logger.warning("audit write failed for success %s: %s", action, exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="audit log unavailable; refusing to answer",
        ) from exc


def _process_info(pid: int) -> tuple[str, str | None]:
    """Return ``(name, username)`` for a pid.

    Falls back to ``("unknown", None)`` if psutil can't read it -- the
    caller has already validated the pid exists, so this is a best-effort
    enrichment for the response body and audit record.
    """
    try:
        proc = psutil.Process(pid)
        name = proc.name()
        try:
            user = proc.username()
        except (psutil.AccessDenied, psutil.Error):
            user = None
        return name, user
    except (psutil.NoSuchProcess, psutil.Error):
        return "unknown", None


def _signal_name(sig: int) -> str:
    """Return a POSIX signal name for logging / response text."""
    try:
        return signal_module.Signals(sig).name
    except ValueError:
        return f"SIG{sig}"


# ---------- endpoint bodies (exposed for tests) ----------


def perform_kill(
    body: KillRequest,
    *,
    request_remote: str | None,
    token_fp: str,
    audit: AuditLogger,
    os_kill=None,
    pid_exists=None,
    daemon_pid: int | None = None,
) -> KillResponse:
    # Late-bind so monkeypatching ``os.kill`` / ``psutil.pid_exists`` in
    # tests after module import is effective.
    if os_kill is None:
        os_kill = os.kill
    if pid_exists is None:
        pid_exists = psutil.pid_exists
    """Implementation of ``POST /kill``.

    Split out of the route body so tests can drive it directly with fakes
    for ``os_kill``/``pid_exists``/``daemon_pid``. Validation order matches
    the plan: signal first, pid sanity next, denylist last.
    """
    fields: dict[str, Any] = {
        "pid": body.pid,
        "signal": body.signal,
        "by": request_remote or "-",
        "token": token_fp,
    }

    if body.signal not in _ALLOWED_KILL_SIGNALS:
        _refuse(
            audit,
            action="kill",
            fields=fields,
            http_status=400,
            reason=f"disallowed signal {body.signal}",
        )

    if body.pid == 1:
        _refuse(
            audit,
            action="kill",
            fields=fields,
            http_status=403,
            reason="refusing to signal launchd",
        )

    self_pid = daemon_pid if daemon_pid is not None else os.getpid()
    if body.pid == self_pid:
        _refuse(
            audit,
            action="kill",
            fields=fields,
            http_status=403,
            reason="refusing to signal self",
        )

    if not pid_exists(body.pid):
        _refuse(
            audit,
            action="kill",
            fields=fields,
            http_status=404,
            reason="pid not found",
        )

    name, user = _process_info(body.pid)
    fields["name"] = name
    if user is not None:
        fields["user"] = user
    if name in DENY_PROCESS_NAMES:
        _refuse(
            audit,
            action="kill",
            fields=fields,
            http_status=403,
            reason=f"refusing to signal {name}",
        )

    try:
        os_kill(body.pid, body.signal)
    except ProcessLookupError:
        # Race: the process exited between pid_exists() and os.kill().
        _refuse(
            audit,
            action="kill",
            fields=fields,
            http_status=404,
            reason="pid not found",
        )
    except PermissionError as exc:
        _refuse(
            audit,
            action="kill",
            fields=fields,
            http_status=403,
            reason=f"permission denied: {exc}",
        )
    except OSError as exc:
        _refuse(
            audit,
            action="kill",
            fields=fields,
            http_status=500,
            reason=f"os error: {exc}",
        )

    sent_at = datetime.now(tz=timezone.utc)
    _record_ok(audit, "kill", fields)
    return KillResponse(
        pid=body.pid,
        signal=body.signal,
        process_name=name,
        user=user,
        sent_at=sent_at,
    )


def _find_ssh_session(
    sources: Sources, pid: int
) -> SSHSession | None:
    """Walk the active SSH sessions snapshot for a matching pid."""
    peer_map = sources.tailscale.peer_map()
    for sess in sources.ssh.sessions(peer_map):
        if sess.pid == pid:
            return sess
    return None


def perform_ssh_kick(
    body: SSHKickRequest,
    *,
    request_remote: str | None,
    token_fp: str,
    sources: Sources,
    audit: AuditLogger,
    os_kill=None,
    pid_exists=None,
) -> SSHKickResponse:
    if os_kill is None:
        os_kill = os.kill
    if pid_exists is None:
        pid_exists = psutil.pid_exists
    """Implementation of ``POST /ssh/kick``."""
    fields: dict[str, Any] = {
        "pid": body.pid,
        "signal": int(signal_module.SIGHUP),
        "by": request_remote or "-",
        "token": token_fp,
    }

    if not pid_exists(body.pid):
        _refuse(
            audit,
            action="ssh_kick",
            fields=fields,
            http_status=404,
            reason="pid not found",
        )

    session = _find_ssh_session(sources, body.pid)
    if session is None:
        _refuse(
            audit,
            action="ssh_kick",
            fields=fields,
            http_status=403,
            reason="target is not an sshd session",
        )
    assert session is not None  # for type checker

    fields["session_user"] = session.user
    fields["source_ip"] = session.source_ip

    if request_remote and session.source_ip == request_remote:
        _refuse(
            audit,
            action="ssh_kick",
            fields=fields,
            http_status=403,
            reason="refusing to kick your own session",
        )

    try:
        os_kill(body.pid, int(signal_module.SIGHUP))
    except ProcessLookupError:
        _refuse(
            audit,
            action="ssh_kick",
            fields=fields,
            http_status=404,
            reason="pid not found",
        )
    except PermissionError as exc:
        _refuse(
            audit,
            action="ssh_kick",
            fields=fields,
            http_status=403,
            reason=f"permission denied: {exc}",
        )
    except OSError as exc:
        _refuse(
            audit,
            action="ssh_kick",
            fields=fields,
            http_status=500,
            reason=f"os error: {exc}",
        )

    _record_ok(audit, "ssh_kick", fields)
    return SSHKickResponse(
        session=session,
        sent_at=datetime.now(tz=timezone.utc),
    )


def _default_tmux_runner(cmd: list[str]) -> subprocess.CompletedProcess:
    """Run a tmux command with the same env/cwd pinning as the read source."""
    return subprocess.run(  # noqa: S603 -- list args, no shell
        cmd,
        capture_output=True,
        timeout=5,
        check=False,
        env=SUBPROCESS_ENV,
        cwd=SUBPROCESS_CWD,
    )


def perform_tmux_new(
    body: TmuxNewRequest,
    *,
    request_remote: str | None,
    token_fp: str,
    audit: AuditLogger,
    tmux_bin: object = _UNSET,
    runner=None,
) -> TmuxNewResponse:
    # Late-bind module attrs so tests can monkeypatch ``control.TMUX_BIN``
    # and ``control._default_tmux_runner`` and see the effect here.
    if tmux_bin is _UNSET:
        tmux_bin = TMUX_BIN
    if runner is None:
        runner = _default_tmux_runner
    """Implementation of ``POST /tmux/new``."""
    fields: dict[str, Any] = {
        "name": body.name,
        "by": request_remote or "-",
        "token": token_fp,
    }

    if not _TMUX_NAME_RE.match(body.name):
        _refuse(
            audit,
            action="tmux_new",
            fields=fields,
            http_status=400,
            reason="invalid session name",
        )

    if tmux_bin is None:
        _refuse(
            audit,
            action="tmux_new",
            fields=fields,
            http_status=503,
            reason="tmux not available",
        )
    assert tmux_bin is not None  # for type checker

    # B17: wrap with sudo -u <STUDIOD_TMUX_USER> so the session lands in
    # the user's tmux namespace (/tmp/tmux-<uid>/default), not root's.
    cmd = wrap_tmux_cmd([tmux_bin, "new-session", "-d", "-s", body.name])
    try:
        proc = runner(cmd)
    except FileNotFoundError:
        _refuse(
            audit,
            action="tmux_new",
            fields=fields,
            http_status=503,
            reason="tmux not available",
        )
    except subprocess.TimeoutExpired:
        _refuse(
            audit,
            action="tmux_new",
            fields=fields,
            http_status=504,
            reason="tmux timed out",
        )

    stderr = proc.stderr.decode("utf-8", errors="replace") if proc.stderr else ""
    if proc.returncode == 0:
        fields["created"] = True
        _record_ok(audit, "tmux_new", fields)
        return TmuxNewResponse(name=body.name, created=True, exists=False)

    if "duplicate session" in stderr.lower():
        fields["created"] = False
        fields["exists"] = True
        _record_ok(audit, "tmux_new", fields)
        return TmuxNewResponse(name=body.name, created=False, exists=True)

    short = stderr.strip().splitlines()[-1] if stderr.strip() else "tmux failed"
    _refuse(
        audit,
        action="tmux_new",
        fields=fields,
        http_status=500,
        reason=short[:120],
    )
    # unreachable; _refuse raises
    return TmuxNewResponse(name=body.name, created=False, exists=False)


# ---------- router factory ----------


def build_router(
    sources: Sources,
    auth_dep,
    audit: AuditLogger,
    *,
    expected_token: str,
) -> APIRouter:
    """Construct the control router.

    ``expected_token`` is captured to compute the per-request token
    fingerprint without re-parsing the header -- ``auth_dep`` has already
    validated that the presented token equals this one, so we can use it.
    """
    router = APIRouter()
    token_fp = token_fingerprint(expected_token)

    def _remote(request: Request) -> str | None:
        client = request.client
        return client.host if client else None

    @router.post(
        "/kill",
        response_model=KillResponse,
        dependencies=[Depends(auth_dep)],
    )
    def kill_endpoint(body: KillRequest, request: Request) -> KillResponse:
        return perform_kill(
            body,
            request_remote=_remote(request),
            token_fp=token_fp,
            audit=audit,
        )

    @router.post(
        "/ssh/kick",
        response_model=SSHKickResponse,
        dependencies=[Depends(auth_dep)],
    )
    def ssh_kick_endpoint(
        body: SSHKickRequest, request: Request
    ) -> SSHKickResponse:
        return perform_ssh_kick(
            body,
            request_remote=_remote(request),
            token_fp=token_fp,
            sources=sources,
            audit=audit,
        )

    @router.post(
        "/tmux/new",
        response_model=TmuxNewResponse,
        dependencies=[Depends(auth_dep)],
    )
    def tmux_new_endpoint(
        body: TmuxNewRequest, request: Request
    ) -> TmuxNewResponse:
        return perform_tmux_new(
            body,
            request_remote=_remote(request),
            token_fp=token_fp,
            audit=audit,
        )

    return router
