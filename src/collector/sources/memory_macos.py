"""Parse ``/usr/bin/vm_stat`` output to build an Activity Monitor-style
memory breakdown on macOS.

psutil's ``virtual_memory()`` on Darwin uses Linux-flavoured accounting
(``used = active + wired``), which undercounts real memory pressure on
Apple Silicon: anonymous inactive pages are NOT reclaimable without
swapping, and should be counted as "used". Activity Monitor / Stats.app
compute it as ``used = anonymous + wired + compressed`` and that's what
we want `studio status` to report.

This module shells out to the absolute path ``/usr/bin/vm_stat`` using
the same defensive pattern as the other subprocess sources: pinned env,
``cwd="/"``, short timeout, graceful ``None`` return on failure. A short
in-memory cache avoids re-shelling on back-to-back requests from the
collector (e.g. ``/stats`` and ``/processes`` arriving within a few
hundred milliseconds of each other).
"""

from __future__ import annotations

import logging
import os
import re
import subprocess
import time
from dataclasses import dataclass

logger = logging.getLogger(__name__)

# Security: absolute path + candidate list. /usr/bin/vm_stat ships with
# macOS and is the only realistic location, but keep the pattern
# consistent with tailscale.py / powermetrics.py for auditability.
VM_STAT_BIN_CANDIDATES: tuple[str, ...] = (
    "/usr/bin/vm_stat",
)


def _resolve_binary(candidates: tuple[str, ...]) -> str | None:
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


VM_STAT_BIN: str | None = _resolve_binary(VM_STAT_BIN_CANDIDATES)

SUBPROCESS_ENV: dict[str, str] = {
    "PATH": "/usr/sbin:/usr/bin:/bin",
    "LANG": "C",
}
SUBPROCESS_CWD: str = "/"

CACHE_TTL_SECONDS = 2.0


@dataclass(frozen=True)
class VmStatSample:
    """One parsed ``vm_stat`` sample, all fields in bytes."""

    page_size: int
    free: int
    active: int
    inactive: int
    speculative: int
    wired: int
    purgeable: int
    compressed: int  # "Pages occupied by compressor" * page_size
    file_backed: int
    anonymous: int


# Regex: match the "page size of N bytes" bit in the header line.
_HEADER_PAGE_SIZE_RE = re.compile(r"page size of (\d+) bytes")

# Regex: match a labeled line like "Pages wired down:  321922.".
# Labels can contain spaces and quotes; the trailing integer is followed
# by an optional period. We tolerate trailing whitespace.
_LINE_RE = re.compile(r'^\s*"?([A-Za-z][A-Za-z \-]+?)"?\s*:\s*(\d+)\s*\.?\s*$')

# Which labels we actually care about, in the exact form they appear in
# vm_stat output (trimmed). Values are attribute names on VmStatSample.
_LABEL_MAP: dict[str, str] = {
    "Pages free": "free",
    "Pages active": "active",
    "Pages inactive": "inactive",
    "Pages speculative": "speculative",
    "Pages wired down": "wired",
    "Pages purgeable": "purgeable",
    "Pages occupied by compressor": "compressed",
    "File-backed pages": "file_backed",
    "Anonymous pages": "anonymous",
}


def parse_vm_stat(text: str) -> VmStatSample | None:
    """Parse the textual output of ``vm_stat`` into a :class:`VmStatSample`.

    Returns ``None`` when the output is missing the header page size or any
    of the required labeled fields -- callers should then fall back to
    psutil.
    """

    page_size: int | None = None
    header_match = _HEADER_PAGE_SIZE_RE.search(text)
    if header_match:
        try:
            page_size = int(header_match.group(1))
        except ValueError:
            page_size = None
    if not page_size or page_size <= 0:
        return None

    # Collect raw page counts by attribute name.
    fields: dict[str, int] = {}
    for raw_line in text.splitlines():
        m = _LINE_RE.match(raw_line)
        if not m:
            continue
        label = m.group(1).strip()
        if label not in _LABEL_MAP:
            continue
        try:
            pages = int(m.group(2))
        except ValueError:
            continue
        fields[_LABEL_MAP[label]] = pages

    required = set(_LABEL_MAP.values())
    if not required.issubset(fields.keys()):
        missing = sorted(required - fields.keys())
        logger.warning("vm_stat output missing fields: %s", missing)
        return None

    return VmStatSample(
        page_size=page_size,
        free=fields["free"] * page_size,
        active=fields["active"] * page_size,
        inactive=fields["inactive"] * page_size,
        speculative=fields["speculative"] * page_size,
        wired=fields["wired"] * page_size,
        purgeable=fields["purgeable"] * page_size,
        compressed=fields["compressed"] * page_size,
        file_backed=fields["file_backed"] * page_size,
        anonymous=fields["anonymous"] * page_size,
    )


class VmStatCollector:
    """Wrap ``/usr/bin/vm_stat`` with a short cache.

    Construct once at daemon startup; call :meth:`sample` from
    :class:`SystemCollector.memory_stats`. If the binary is unavailable
    (non-Darwin, or someone stripped /usr/bin/vm_stat out of a container
    image), ``sample()`` returns ``None`` and the caller falls back to the
    existing psutil-based memory stats path.
    """

    # Sentinel used to distinguish "caller passed nothing, auto-resolve
    # from VM_STAT_BIN" from "caller explicitly passed None to mean
    # unavailable".
    _AUTO = object()

    def __init__(
        self,
        cmd: "list[str] | None | object" = _AUTO,
        cache_ttl: float = CACHE_TTL_SECONDS,
    ) -> None:
        if cmd is VmStatCollector._AUTO:
            self._cmd: list[str] | None = (
                [VM_STAT_BIN] if VM_STAT_BIN is not None else None
            )
        elif cmd is None:
            self._cmd = None
        else:
            self._cmd = list(cmd)  # type: ignore[arg-type]
        self._cache_ttl = cache_ttl
        self._cache: tuple[float, VmStatSample | None] | None = None
        self._warned_unavailable = False

    def sample(self) -> VmStatSample | None:
        now = time.monotonic()
        if self._cache is not None:
            expires, value = self._cache
            if expires > now:
                return value

        value = self._fetch_uncached()
        self._cache = (now + self._cache_ttl, value)
        return value

    def _fetch_uncached(self) -> VmStatSample | None:
        if self._cmd is None:
            if not self._warned_unavailable:
                logger.warning(
                    "vm_stat binary not found; falling back to psutil memory stats"
                )
                self._warned_unavailable = True
            return None
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
                logger.warning("vm_stat binary missing at runtime")
                self._warned_unavailable = True
            return None
        except subprocess.TimeoutExpired:
            logger.warning("vm_stat timed out")
            return None

        if proc.returncode != 0:
            logger.warning("vm_stat returned %s", proc.returncode)
            return None

        text = proc.stdout.decode("utf-8", errors="replace")
        parsed = parse_vm_stat(text)
        if parsed is None:
            logger.warning("vm_stat output could not be parsed")
        return parsed
