"""Token loading and constant-time comparison helpers.

These helpers are shared because the CLI (Phase 2) will need to load a token
from the MacBook side too, using the same logic.
"""

from __future__ import annotations

import hmac
import logging
import os
import secrets
import stat
from pathlib import Path

from shared.config import (
    DEV_TOKEN_FILENAME,
    ENV_DEV_MODE,
    ENV_TOKEN_FILE,
    PROD_TOKEN_FILE,
)

logger = logging.getLogger(__name__)


class TokenError(RuntimeError):
    """Raised when a token file cannot be read or is invalid."""


def is_dev_mode() -> bool:
    return os.environ.get(ENV_DEV_MODE, "") == "1"


def resolve_token_path() -> Path:
    """Return the path that should hold the bearer token, per env + mode."""
    explicit = os.environ.get(ENV_TOKEN_FILE)
    if explicit:
        return Path(explicit).expanduser()
    if is_dev_mode():
        return Path.cwd() / DEV_TOKEN_FILENAME
    return PROD_TOKEN_FILE


def ensure_dev_token(path: Path) -> str:
    """In dev mode, generate a token file if it doesn't already exist.

    Returns the token contents. Prints the token to stdout when it is first
    generated, so the developer can copy it into a curl command.
    """
    if path.exists():
        return read_token(path)

    token = secrets.token_urlsafe(32)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(token + "\n")
    try:
        path.chmod(0o600)
    except PermissionError:
        # Best-effort; on some filesystems chmod may not apply. We still
        # check the actual mode below and log if it's wrong.
        pass

    # Verify the mode took effect. Dev mode is forgiving -- we do not raise
    # here -- but we must make noise if a dev token ends up world-readable.
    try:
        actual_mode = stat.S_IMODE(os.stat(path).st_mode)
    except OSError as exc:
        logger.warning(
            "dev-mode: could not stat token file %s after chmod: %s", path, exc
        )
    else:
        if actual_mode != 0o600:
            logger.warning(
                "dev-mode: token file %s has mode %s (expected 0o600); "
                "other users on this machine may be able to read it",
                path,
                oct(actual_mode),
            )
    print(f"[studiod] dev-mode: generated bearer token at {path}")
    print(f"[studiod] dev-mode: token = {token}")
    return token


def read_token(path: Path) -> str:
    """Read a token from disk. Enforces sane permissions in non-dev mode."""
    if not path.exists():
        raise TokenError(f"Token file not found: {path}")
    try:
        contents = path.read_text().strip()
    except OSError as exc:
        raise TokenError(f"Cannot read token file {path}: {exc}") from exc
    if not contents:
        raise TokenError(f"Token file is empty: {path}")
    if not is_dev_mode():
        # Prod expects root-owned 0600. A non-root user planting a 0600
        # file at /etc/studiod/token would otherwise be trusted -- so we
        # also require st_uid == 0. The launchd deploy in Phase 2 owns
        # writing the file as root.
        st = path.stat()
        mode = stat.S_IMODE(st.st_mode)
        if mode & 0o077:
            raise TokenError(
                f"Token file {path} has overly permissive mode {oct(mode)}; want 0600"
            )
        if st.st_uid != 0:
            raise TokenError(
                f"Token file {path} must be owned by root (uid 0); "
                f"found uid {st.st_uid}"
            )
    return contents


def compare(expected: str, presented: str) -> bool:
    """Constant-time string comparison wrapper."""
    return hmac.compare_digest(expected.encode("utf-8"), presented.encode("utf-8"))
