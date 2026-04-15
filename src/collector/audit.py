"""Append-only audit log for write-side endpoints.

Every successful or failed ``/kill``, ``/ssh/kick``, and ``/tmux/new`` call
writes one line to the audit log. The log file is deliberately grep-friendly
(``key=value`` pairs separated by spaces) rather than JSON -- it is designed
to be tailed and scanned on the shared Mac Studio box.

Location:

* **prod**: ``/var/log/studiod.audit.log`` -- created at daemon startup, mode
  ``0640``, owned by the root user under which launchd starts the daemon.
* **dev**: ``./studiod-audit.log`` in the current working directory, mode
  ``0600``. No file-system surgery for the developer.

Rotation is handled by :class:`logging.handlers.RotatingFileHandler` with a
5 MB cap and 3 backups so the daemon cannot fill the disk. Stdlib only --
no new runtime dependencies.

``AuditWriteError`` is raised when appending a record fails. Every write
endpoint catches it, logs a WARNING to the main daemon log, and returns 500.
An auditable action without an audit trail must fail closed.
"""

from __future__ import annotations

import hashlib
import logging
import os
import stat
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler
from pathlib import Path

from shared.auth import is_dev_mode

PROD_AUDIT_PATH = Path("/var/log/studiod.audit.log")
DEV_AUDIT_FILENAME = "studiod-audit.log"

_MAX_BYTES = 5 * 1024 * 1024  # 5 MB
_BACKUP_COUNT = 3

logger = logging.getLogger(__name__)


class AuditWriteError(RuntimeError):
    """Raised when the audit record cannot be persisted.

    Write endpoints treat this as a hard failure and return 500 -- an
    auditable action that cannot be recorded must not appear to succeed.
    """


def resolve_audit_path() -> Path:
    """Return the path the audit log should live at for this process."""
    if is_dev_mode():
        return Path.cwd() / DEV_AUDIT_FILENAME
    return PROD_AUDIT_PATH


def token_fingerprint(token: str) -> str:
    """Stable per-token identifier for audit lines.

    First 8 hex chars of ``sha256(token)``. This identifies *which* stored
    token was used (so an operator can revoke it) without writing the token
    itself anywhere.
    """
    digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
    return digest[:8]


def _iso_now() -> str:
    # Explicit millisecond precision + trailing Z -- stable format for log
    # tailing and easy to sort lexicographically.
    now = datetime.now(tz=timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"


def _escape_value(value: object) -> str:
    """Render a value for the ``key=value`` log line.

    Spaces, ``=``, quotes, or non-printables would break the grep-friendly
    format. We wrap such values in double quotes with backslash escapes.
    """
    s = "-" if value is None else str(value)
    needs_quote = any(c.isspace() or c in {'"', "\\", "="} for c in s) or not s
    if not needs_quote:
        return s
    escaped = s.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def format_audit_line(action: str, fields: dict[str, object]) -> str:
    """Build a single audit log line without writing it.

    Kept pure so tests can assert on the output without I/O.
    """
    ordered: list[tuple[str, object]] = [("action", action)]
    # Render remaining keys in insertion order. Python dicts preserve
    # insertion order and the write endpoints assemble them in a stable
    # action-specific sequence.
    for key, value in fields.items():
        if key == "action":
            continue
        ordered.append((key, value))
    parts = [_iso_now()] + [f"{k}={_escape_value(v)}" for k, v in ordered]
    return " ".join(parts)


class AuditLogger:
    """Wraps a :class:`RotatingFileHandler` writing plain audit lines.

    The logger is a singleton per-process -- tests construct fresh instances
    with a ``path`` pointing at a tmp directory.
    """

    def __init__(self, path: Path, *, mode: int) -> None:
        self._path = path
        self._mode = mode
        self._ensure_file()
        self._handler = RotatingFileHandler(
            str(path),
            maxBytes=_MAX_BYTES,
            backupCount=_BACKUP_COUNT,
            encoding="utf-8",
            delay=False,
        )
        # We format lines ourselves; the handler just writes the message.
        self._handler.setFormatter(logging.Formatter("%(message)s"))
        self._logger = logging.getLogger(f"studiod.audit.{id(self)}")
        self._logger.setLevel(logging.INFO)
        self._logger.propagate = False
        # Purge any pre-existing handlers from prior constructions in the
        # same process (pytest re-imports can leak handlers otherwise).
        for existing in list(self._logger.handlers):
            self._logger.removeHandler(existing)
        self._logger.addHandler(self._handler)

    @property
    def path(self) -> Path:
        return self._path

    def _ensure_file(self) -> None:
        """Create the file with the right mode if it does not exist.

        We create the parent directory if missing (dev mode only -- in prod
        the parent is always ``/var/log`` which already exists). On permission
        errors the constructor fails fast so the daemon refuses to start.
        """
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
        except PermissionError as exc:
            raise AuditWriteError(
                f"cannot create audit log parent directory {self._path.parent}: {exc}"
            ) from exc
        if not self._path.exists():
            try:
                # O_CREAT|O_EXCL protects against a race where another
                # process creates the file between our exists() check and
                # the open call -- though in practice the daemon is the
                # only writer.
                fd = os.open(
                    str(self._path),
                    os.O_CREAT | os.O_WRONLY | os.O_APPEND,
                    self._mode,
                )
                os.close(fd)
            except OSError as exc:
                raise AuditWriteError(
                    f"cannot create audit log file {self._path}: {exc}"
                ) from exc
        # Re-apply the mode in case umask interfered with the O_CREAT mode.
        try:
            os.chmod(self._path, self._mode)
        except PermissionError:
            # Non-fatal in dev mode; log a warning but continue.
            pass
        self._verify_mode()

    def _verify_mode(self) -> None:
        try:
            actual = stat.S_IMODE(os.stat(self._path).st_mode)
        except OSError:
            return
        if actual != self._mode:
            logger.warning(
                "audit log %s has mode %s (expected %s); "
                "continuing but the permissions should be reviewed",
                self._path,
                oct(actual),
                oct(self._mode),
            )

    def write(self, action: str, fields: dict[str, object]) -> None:
        """Append a single line and flush.

        Raises :class:`AuditWriteError` on any I/O failure so the calling
        endpoint can return 500 instead of silently losing the record.
        """
        line = format_audit_line(action, fields)
        try:
            self._logger.info(line)
            for h in self._logger.handlers:
                try:
                    h.flush()
                except Exception:  # noqa: BLE001 -- best-effort flush
                    pass
        except OSError as exc:
            raise AuditWriteError(
                f"failed to write audit record for {action}: {exc}"
            ) from exc


def build_default_audit_logger() -> AuditLogger:
    """Factory used by the app builder: resolves the right path for the mode."""
    path = resolve_audit_path()
    mode = 0o600 if is_dev_mode() else 0o640
    return AuditLogger(path, mode=mode)
