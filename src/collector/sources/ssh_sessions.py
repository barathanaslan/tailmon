"""Walk the sshd process tree and extract active SSH sessions."""

from __future__ import annotations

import logging
import re
import time
from datetime import datetime, timezone

import psutil

from shared.models import SSHSession, TailscalePeer

logger = logging.getLogger(__name__)


# Examples of sshd child-session command lines:
#   sshd: alice [priv]
#   sshd: alice@pts/0
#   sshd: alice@notty
#   sshd-session: alice [priv]      (macOS 26.3+ / modern OpenSSH session-per-process)
#   sshd-session: alice@ttys001
#   sshd-session: alice@notty
# and for network peers, psutil reports a connection we can cross-reference.
_SSHD_CHILD_RE = re.compile(r"sshd(?:-session)?:\s+([^\s\[@]+)")

# Any cmdline token that marks this process as an sshd-forked session (not
# the top-level listener). Matched as a plain substring check against the
# joined argv so we accept `sshd:` or `sshd-session:` without caring where
# it appears.
_SSHD_CHILD_MARKERS: tuple[str, ...] = ("sshd:", "sshd-session:")


class SSHCollector:
    """Real sshd process tree walker."""

    def sessions(self, peer_map: dict[str, TailscalePeer]) -> list[SSHSession]:
        def iter_with_connections(attrs):
            # psutil 7 removed `connections` as an as_dict attr in favor of
            # `Process.net_connections()`. Build a compatible iterator that
            # fetches connections lazily so the downstream walker can reuse
            # its test-fake contract.
            wanted = [a for a in attrs if a != "connections"]
            for proc in psutil.process_iter(wanted):
                info = dict(proc.info)
                try:
                    info["connections"] = list(proc.net_connections(kind="tcp"))
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    info["connections"] = []
                yield SimpleProcess(info)

        return collect_ssh_sessions(peer_map, process_iter=iter_with_connections)


class SimpleProcess:
    """Tiny psutil-process-lookalike with just an `info` dict.

    Used to bridge the gap between psutil 7's API (`net_connections()`) and
    the `process_iter` signature the collector expects.
    """

    __slots__ = ("info",)

    def __init__(self, info: dict) -> None:
        self.info = info


def collect_ssh_sessions(
    peer_map: dict[str, TailscalePeer],
    *,
    process_iter,
) -> list[SSHSession]:
    """Pure function that drives the psutil iterator.

    `process_iter` is injected so tests can feed synthetic processes.
    """
    sessions: list[SSHSession] = []
    for proc in process_iter(
        ["pid", "ppid", "name", "username", "cmdline", "create_time", "connections"]
    ):
        try:
            info = proc.info
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

        name = (info.get("name") or "").lower()
        cmd_list = info.get("cmdline") or []
        cmdline = " ".join(cmd_list) if isinstance(cmd_list, list) else str(cmd_list)

        # We want _forked session_ sshd processes, not the top-level listener.
        if "sshd" not in name and "sshd" not in cmdline:
            continue
        if not any(marker in cmdline for marker in _SSHD_CHILD_MARKERS):
            continue
        if "[listener]" in cmdline:
            continue

        match = _SSHD_CHILD_RE.search(cmdline)
        session_user = match.group(1) if match else str(info.get("username") or "")
        # For "[priv]" processes the cmdline still contains the user, but
        # they're the privileged parent of the user-privsep child. Skip.
        if "[priv]" in cmdline:
            continue

        source_ip, source_port = _peer_from_connections(
            info.get("connections") or [],
        )
        if source_ip is None:
            # Fallback: parse "from 1.2.3.4 port 22" if sshd put it in argv.
            source_ip, source_port = _peer_from_cmdline(cmdline)
        if source_ip is None:
            # Can't label it meaningfully; still surface it with 0/0.
            source_ip, source_port = "unknown", 0

        peer = peer_map.get(source_ip) if source_ip != "unknown" else None
        tty = _extract_tty(cmdline)
        started = _utc(float(info.get("create_time") or 0.0))
        idle = _tty_idle_seconds(tty) if tty else None

        sessions.append(
            SSHSession(
                pid=int(info.get("pid") or 0),
                user=session_user,
                source_ip=source_ip,
                source_port=int(source_port or 0),
                tailscale_peer=peer,
                tty=tty,
                started_at=started,
                idle_seconds=idle,
            )
        )

    sessions.sort(key=lambda s: s.started_at)
    return sessions


def _utc(ts: float) -> datetime:
    return datetime.fromtimestamp(ts, tz=timezone.utc)


def _peer_from_connections(conns) -> tuple[str | None, int | None]:
    """Walk a process's TCP connections to find the ESTABLISHED SSH peer."""
    for conn in conns or []:
        try:
            raddr = conn.raddr
        except AttributeError:
            continue
        if not raddr:
            continue
        try:
            ip = raddr.ip
            port = raddr.port
        except AttributeError:
            continue
        if ip:
            return str(ip), int(port or 0)
    return None, None


def _peer_from_cmdline(cmdline: str) -> tuple[str | None, int | None]:
    # sshd with verbose logging sometimes has "from 1.2.3.4 port 12345"
    m = re.search(r"from\s+([0-9a-fA-F\.:]+)\s+port\s+(\d+)", cmdline)
    if m:
        return m.group(1), int(m.group(2))
    return None, None


def _extract_tty(cmdline: str) -> str | None:
    m = re.search(r"@([A-Za-z0-9/]+)", cmdline)
    if not m:
        return None
    tty = m.group(1)
    if tty in {"notty", "priv"}:
        return None
    return tty


def _tty_idle_seconds(tty: str) -> float | None:
    """Return idle seconds for a given tty, if we can stat(/dev/<tty>)."""
    import os

    try:
        st = os.stat(f"/dev/{tty}")
    except (FileNotFoundError, PermissionError, OSError):
        return None
    return max(0.0, time.time() - st.st_atime)
