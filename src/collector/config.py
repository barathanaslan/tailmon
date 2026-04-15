"""Runtime configuration for the collector daemon."""

from __future__ import annotations

import ipaddress
import logging
import os
from dataclasses import dataclass
from pathlib import Path

from shared.auth import is_dev_mode, resolve_token_path
from shared.config import (
    DEFAULT_BIND_HOST,
    DEFAULT_BIND_PORT,
    ENV_BIND_HOST,
    ENV_BIND_PORT,
)

logger = logging.getLogger(__name__)

# Tailscale CGNAT range -- the only non-loopback range the collector will
# ever bind to in production. See docs/architecture.md "Security model".
_TAILSCALE_CGNAT = ipaddress.ip_network("100.64.0.0/10")
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "::1"})


class ConfigError(RuntimeError):
    """Raised when runtime configuration is invalid and the daemon must refuse to start."""


@dataclass(frozen=True)
class CollectorConfig:
    bind_host: str
    bind_port: int
    token_path: Path
    dev_mode: bool


def validate_bind_host(host: str, *, dev_mode: bool) -> str:
    """Validate STUDIOD_BIND_HOST and return it unchanged on success.

    Raises :class:`ConfigError` with a clear message when the host is not
    allowed. The daemon may eventually run as root, so we refuse to bind
    to anything beyond loopback (prod and dev) or the Tailscale CGNAT
    range ``100.64.0.0/10`` (prod only). Public IPs, ``0.0.0.0``, and
    non-Tailscale private ranges are always rejected.
    """
    if host in _LOOPBACK_HOSTS:
        return host

    try:
        parsed = ipaddress.ip_address(host)
    except ValueError as exc:
        logger.error("rejecting bind host %r: not a valid IP address", host)
        raise ConfigError(
            f"STUDIOD_BIND_HOST={host!r} is not a valid IP address; "
            f"allowed: 127.0.0.1, ::1"
            + ("" if dev_mode else ", or any 100.64.0.0/10 Tailscale IP")
        ) from exc

    if dev_mode:
        logger.error(
            "rejecting bind host %s in dev mode: only 127.0.0.1 and ::1 allowed",
            host,
        )
        raise ConfigError(
            f"STUDIOD_BIND_HOST={host} is not allowed in dev mode "
            "(STUDIOD_DEV_MODE=1); only 127.0.0.1 and ::1 are permitted"
        )

    if parsed in _TAILSCALE_CGNAT:
        return host

    logger.error(
        "rejecting bind host %s: not loopback and not in Tailscale CGNAT %s",
        host,
        _TAILSCALE_CGNAT,
    )
    raise ConfigError(
        f"STUDIOD_BIND_HOST={host} is not allowed; must be 127.0.0.1, ::1, "
        f"or an IP in the Tailscale CGNAT range {_TAILSCALE_CGNAT}"
    )


def load_config() -> CollectorConfig:
    host = os.environ.get(ENV_BIND_HOST, DEFAULT_BIND_HOST)
    port = int(os.environ.get(ENV_BIND_PORT, str(DEFAULT_BIND_PORT)))
    dev_mode = is_dev_mode()
    validate_bind_host(host, dev_mode=dev_mode)
    return CollectorConfig(
        bind_host=host,
        bind_port=port,
        token_path=resolve_token_path(),
        dev_mode=dev_mode,
    )
