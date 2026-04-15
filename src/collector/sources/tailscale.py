"""Wrap `tailscale status --json` and build a peer map keyed by Tailscale IP."""

from __future__ import annotations

import json
import logging
import os
import subprocess
import time

from shared.models import TailscalePeer

logger = logging.getLogger(__name__)

# Security: resolve the tailscale binary to an absolute path from a
# known-safe list. Do not trust PATH at runtime -- the daemon will run as
# root. If none of the candidates exist, TAILSCALE_BIN is None and the
# collector gracefully returns an empty peer map.
TAILSCALE_BIN_CANDIDATES: tuple[str, ...] = (
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    "/opt/homebrew/bin/tailscale",
    "/usr/local/bin/tailscale",
)


def _resolve_binary(candidates: tuple[str, ...]) -> str | None:
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


TAILSCALE_BIN: str | None = _resolve_binary(TAILSCALE_BIN_CANDIDATES)

SUBPROCESS_ENV: dict[str, str] = {
    "PATH": "/usr/sbin:/usr/bin:/bin:/opt/homebrew/bin",
    "LANG": "C",
}
SUBPROCESS_CWD: str = "/"

TAILSCALE_CMD: list[str] | None = (
    [TAILSCALE_BIN, "status", "--json"] if TAILSCALE_BIN else None
)
CACHE_TTL_SECONDS = 10.0


class TailscaleCollector:
    def __init__(
        self,
        cmd: list[str] | None = None,
        cache_ttl: float = CACHE_TTL_SECONDS,
    ) -> None:
        if cmd is not None:
            self._cmd: list[str] | None = list(cmd)
        else:
            self._cmd = list(TAILSCALE_CMD) if TAILSCALE_CMD else None
        self._cache_ttl = cache_ttl
        self._cache: tuple[float, dict[str, TailscalePeer]] | None = None
        self._warned_unavailable = False

    def peer_map(self) -> dict[str, TailscalePeer]:
        now = time.monotonic()
        if self._cache is not None:
            expires, value = self._cache
            if expires > now:
                return value

        value = self._fetch_uncached()
        self._cache = (now + self._cache_ttl, value)
        return value

    def _fetch_uncached(self) -> dict[str, TailscalePeer]:
        if self._cmd is None:
            if not self._warned_unavailable:
                logger.warning("tailscale binary not found; peer labels disabled")
                self._warned_unavailable = True
            return {}
        try:
            proc = subprocess.run(
                self._cmd,
                capture_output=True,
                timeout=5,
                check=False,
                env=SUBPROCESS_ENV,
                cwd=SUBPROCESS_CWD,
            )
        except FileNotFoundError:
            if not self._warned_unavailable:
                logger.warning("tailscale binary not found; peer labels disabled")
                self._warned_unavailable = True
            return {}
        except subprocess.TimeoutExpired:
            logger.warning("tailscale status timed out")
            return {}

        if proc.returncode != 0:
            logger.warning("tailscale status returned %s", proc.returncode)
            return {}

        try:
            data = json.loads(proc.stdout.decode("utf-8", errors="replace"))
        except json.JSONDecodeError:
            logger.warning("tailscale status returned non-JSON output")
            return {}

        return parse_tailscale_status(data)


def parse_tailscale_status(data: dict) -> dict[str, TailscalePeer]:
    """Turn the `tailscale status --json` blob into a map keyed by peer IP."""
    out: dict[str, TailscalePeer] = {}
    if not isinstance(data, dict):
        return out

    users = data.get("User") or {}

    def display_name_for(user_id: object) -> str | None:
        if user_id is None:
            return None
        user = users.get(str(user_id)) if isinstance(users, dict) else None
        if isinstance(user, dict):
            return user.get("DisplayName") or user.get("LoginName") or None
        return None

    # Include the local node too so we can label loopback SSH sessions.
    self_node = data.get("Self")
    if isinstance(self_node, dict):
        _add_peer(out, self_node, display_name_for)

    peers = data.get("Peer") or {}
    if isinstance(peers, dict):
        for node in peers.values():
            if isinstance(node, dict):
                _add_peer(out, node, display_name_for)

    return out


def _add_peer(
    out: dict[str, TailscalePeer],
    node: dict,
    display_name_for,
) -> None:
    ips = node.get("TailscaleIPs") or []
    if not isinstance(ips, list) or not ips:
        return
    hostname = node.get("HostName") or node.get("DNSName") or "unknown"
    os_name = node.get("OS")
    display = display_name_for(node.get("UserID"))
    for ip in ips:
        if not isinstance(ip, str):
            continue
        out[ip] = TailscalePeer(
            hostname=str(hostname),
            tailscale_ip=ip,
            os=os_name if isinstance(os_name, str) else None,
            user_display_name=display,
        )
