"""Wrap `tmux ls -F` and parse its output into TmuxSession models.

Root-vs-user tmux namespace (B17)
---------------------------------
tmux keeps its server socket at ``/tmp/tmux-<uid>/default``. When the
collector runs as a root launchd daemon it has its own ``/tmp/tmux-0/``
namespace, completely separate from the user's ``/tmp/tmux-<user_uid>/``
namespace where the user's actual tmux sessions live. Without intervention
the daemon's ``tmux ls`` shows root's sessions (usually empty) and
``tmux new-session`` creates in root's namespace, invisible to the user's
own SSH sessions.

Fix: if the ``STUDIOD_TMUX_USER`` env var is set (the plist sets it to the
user that ran ``install-server.sh``), every tmux invocation is wrapped in
``sudo -u <user> -H --`` so the subprocess runs as the target user and
hits that user's ``/tmp/tmux-<uid>/default`` socket. Root can impersonate
any user without a password, so this is a free elevation switch.
"""

from __future__ import annotations

import logging
import os
import subprocess
from datetime import datetime, timezone

from shared.models import TmuxSession

logger = logging.getLogger(__name__)

TMUX_FORMAT = "#{session_name}|#{session_windows}|#{?session_attached,1,0}|#{session_created}"

# Security: resolve tmux to an absolute path at module load from a
# known-safe candidate list. The daemon may run as root; do not trust PATH.
TMUX_BIN_CANDIDATES: tuple[str, ...] = (
    "/opt/homebrew/bin/tmux",
    "/usr/local/bin/tmux",
    "/usr/bin/tmux",
)

# sudo is needed for the user-namespace wrapping below. Pin the absolute
# path; on macOS it's always /usr/bin/sudo.
SUDO_BIN_CANDIDATES: tuple[str, ...] = ("/usr/bin/sudo",)


def _resolve_binary(candidates: tuple[str, ...]) -> str | None:
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


TMUX_BIN: str | None = _resolve_binary(TMUX_BIN_CANDIDATES)
SUDO_BIN: str | None = _resolve_binary(SUDO_BIN_CANDIDATES)

# Which user's tmux namespace to target. Set by the plist at prod install
# time from $SUDO_USER. Unset in dev mode -> no wrap -> root's namespace.
TMUX_USER: str | None = os.environ.get("STUDIOD_TMUX_USER") or None

SUBPROCESS_ENV: dict[str, str] = {
    "PATH": "/usr/sbin:/usr/bin:/bin:/opt/homebrew/bin",
    "LANG": "C",
}
SUBPROCESS_CWD: str = "/"


def wrap_tmux_cmd(cmd: list[str]) -> list[str]:
    """Prepend ``sudo -u <TMUX_USER> -H --`` to ``cmd`` when the env var
    is set and sudo is available.

    Reads the module-level ``TMUX_USER`` / ``SUDO_BIN`` on every call so
    pytest ``monkeypatch.setattr`` works. Returns a fresh list.
    """
    if TMUX_USER and SUDO_BIN:
        return [SUDO_BIN, "-u", TMUX_USER, "-H", "--", *cmd]
    if TMUX_USER and not SUDO_BIN:
        logger.warning(
            "STUDIOD_TMUX_USER=%s set but sudo not found; falling back to root tmux namespace",
            TMUX_USER,
        )
    return list(cmd)


TMUX_CMD: list[str] | None = (
    wrap_tmux_cmd([TMUX_BIN, "ls", "-F", TMUX_FORMAT]) if TMUX_BIN else None
)


class TmuxCollector:
    def __init__(self, cmd: list[str] | None = None) -> None:
        if cmd is not None:
            self._cmd: list[str] | None = list(cmd)
        else:
            self._cmd = list(TMUX_CMD) if TMUX_CMD else None

    def sessions(self) -> list[TmuxSession]:
        if self._cmd is None:
            logger.info("tmux binary not found; returning empty session list")
            return []
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
            logger.info("tmux binary not found; returning empty session list")
            return []
        except subprocess.TimeoutExpired:
            logger.warning("tmux ls timed out")
            return []

        if proc.returncode != 0:
            # tmux exits non-zero when no server is running. That's fine.
            return []

        return parse_tmux_output(proc.stdout.decode("utf-8", errors="replace"))


def parse_tmux_output(output: str) -> list[TmuxSession]:
    sessions: list[TmuxSession] = []
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) < 4:
            continue
        name, windows_s, attached_s, created_s = parts[0], parts[1], parts[2], parts[3]
        try:
            windows = int(windows_s)
        except ValueError:
            windows = 0
        attached = attached_s == "1"
        created: datetime | None
        try:
            created = datetime.fromtimestamp(int(created_s), tz=timezone.utc)
        except (ValueError, OverflowError, OSError):
            created = None
        sessions.append(
            TmuxSession(
                name=name,
                windows=windows,
                attached=attached,
                created_at=created,
            )
        )
    return sessions
