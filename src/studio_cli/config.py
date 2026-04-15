"""Client-side configuration loading.

Search order (first hit wins):

1. Environment variables: ``STUDIO_COLLECTOR_URL``, ``STUDIO_TOKEN_FILE``,
   ``STUDIO_TOKEN``, ``STUDIO_TIMEOUT``, ``STUDIO_SSH_HOST``.
2. Config file at ``~/.config/studio-cli/config.toml``.
3. Built-in defaults (see :data:`DEFAULTS`).

Token storage:

The bearer token is read from ``token_file`` (default
``~/.config/studio-cli/token``). The file must be mode ``0600``; if it is
wider, :func:`load_token` raises :class:`StudioConfigError` with a fix hint
rather than silently using a world-readable secret.

Tests can short-circuit token loading with the ``STUDIO_TOKEN`` env var,
which directly overrides the file.
"""

from __future__ import annotations

import os
import stat
import tomllib
from dataclasses import dataclass
from pathlib import Path

# ---- env var names --------------------------------------------------------

ENV_COLLECTOR_URL = "STUDIO_COLLECTOR_URL"
ENV_TOKEN_FILE = "STUDIO_TOKEN_FILE"
ENV_TOKEN = "STUDIO_TOKEN"  # noqa: S105 -- env var name only
ENV_TIMEOUT = "STUDIO_TIMEOUT"
ENV_SSH_HOST = "STUDIO_SSH_HOST"
ENV_CONFIG_FILE = "STUDIO_CONFIG_FILE"

# ---- defaults -------------------------------------------------------------

DEFAULT_CONFIG_DIR = Path("~/.config/studio-cli").expanduser()
DEFAULT_CONFIG_FILE = DEFAULT_CONFIG_DIR / "config.toml"
DEFAULT_TOKEN_FILE = DEFAULT_CONFIG_DIR / "token"

DEFAULTS = {
    "collector_url": "http://100.80.21.79:8765",
    "token_file": str(DEFAULT_TOKEN_FILE),
    "timeout_seconds": 5.0,
    "ssh_host": "macstudio",
}


class StudioConfigError(RuntimeError):
    """Raised when the client config or token cannot be loaded."""


@dataclass(frozen=True)
class ClientConfig:
    """Resolved client configuration.

    The token itself is loaded lazily by :func:`load_token` so that purely
    informational commands like ``studio version`` and ``studio config show``
    do not error out when the token file is missing.
    """

    collector_url: str
    token_file: Path
    timeout_seconds: float
    ssh_host: str
    config_file: Path | None
    token_override: str | None  # set by STUDIO_TOKEN env var, bypasses token_file


def _load_config_file(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        with path.open("rb") as f:
            data = tomllib.load(f)
    except OSError as exc:
        raise StudioConfigError(f"cannot read config file {path}: {exc}") from exc
    except tomllib.TOMLDecodeError as exc:
        raise StudioConfigError(f"invalid TOML in config file {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise StudioConfigError(f"config file {path} must contain a TOML table")
    return data


def load_config(env: dict[str, str] | None = None) -> ClientConfig:
    """Resolve a :class:`ClientConfig` from env vars + config file + defaults.

    ``env`` is injected for tests; production callers pass nothing and we
    use :data:`os.environ`.
    """
    e = env if env is not None else os.environ

    config_file_path = Path(e.get(ENV_CONFIG_FILE, str(DEFAULT_CONFIG_FILE))).expanduser()
    file_data = _load_config_file(config_file_path)

    def pick(key: str, env_name: str, cast=str):
        if env_name in e and e[env_name] != "":
            return cast(e[env_name])
        if key in file_data:
            return cast(file_data[key])
        return cast(DEFAULTS[key])

    collector_url = pick("collector_url", ENV_COLLECTOR_URL).rstrip("/")
    token_file = Path(pick("token_file", ENV_TOKEN_FILE)).expanduser()
    timeout_seconds = pick("timeout_seconds", ENV_TIMEOUT, float)
    ssh_host = pick("ssh_host", ENV_SSH_HOST)

    return ClientConfig(
        collector_url=collector_url,
        token_file=token_file,
        timeout_seconds=timeout_seconds,
        ssh_host=ssh_host,
        config_file=config_file_path if config_file_path.exists() else None,
        token_override=e.get(ENV_TOKEN) or None,
    )


def load_token(cfg: ClientConfig) -> str:
    """Read the bearer token. Honors the ``STUDIO_TOKEN`` override.

    Enforces ``0600`` on the token file: if the mode is wider, refuse to
    read and raise with a chmod hint. The client side is forgiving about
    ownership (unlike the server-side ``shared.auth.read_token`` which
    requires uid 0) -- on the client the user owns the file.
    """
    if cfg.token_override:
        return cfg.token_override.strip()

    path = cfg.token_file
    if not path.exists():
        raise StudioConfigError(
            f"token file not found: {path}\n"
            f"Run the client install script or paste the token from the Mac Studio:\n"
            f"  install -m 600 /dev/stdin {path}"
        )

    try:
        st = path.stat()
    except OSError as exc:
        raise StudioConfigError(f"cannot stat token file {path}: {exc}") from exc

    mode = stat.S_IMODE(st.st_mode)
    if mode & 0o077:
        raise StudioConfigError(
            f"token file {path} has overly permissive mode {oct(mode)} -- want 0600.\n"
            f"Fix with:  chmod 600 {path}"
        )

    try:
        contents = path.read_text().strip()
    except OSError as exc:
        raise StudioConfigError(f"cannot read token file {path}: {exc}") from exc

    if not contents:
        raise StudioConfigError(f"token file {path} is empty")

    return contents


def redact_token(token: str) -> str:
    """Render a token for display: first 4 chars + ellipsis."""
    if not token:
        return "(empty)"
    if len(token) <= 4:
        return "***"
    return token[:4] + "\u2026"
