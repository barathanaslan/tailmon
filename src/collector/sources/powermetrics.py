"""Subprocess wrapper around macOS `powermetrics` with graceful degradation.

`powermetrics` requires root. In dev mode (running as a regular user on the
MacBook) we fall back to returning `(None, None)` so that `/stats` still
responds 200 with `gpu: null, power: null`.

We parse the **text** output (not plist). The labels in the text format
(``CPU Power: N mW``, ``GPU HW active frequency: N MHz``, etc.) are stable
across macOS releases; plist key names are not, and on macOS 26.3 the plist
format yields empty/unparseable data in practice.
"""

from __future__ import annotations

import logging
import os
import re
import subprocess
import time
from dataclasses import dataclass

from shared.models import GPUStats, PowerStats

logger = logging.getLogger(__name__)


# Security: pin the absolute path to the system `powermetrics` binary so
# PATH manipulation can't trick the root daemon into executing something
# else. On macOS this is always /usr/bin/powermetrics.
POWERMETRICS_BIN_CANDIDATES: tuple[str, ...] = ("/usr/bin/powermetrics",)


def _resolve_binary(candidates: tuple[str, ...]) -> str | None:
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


POWERMETRICS_BIN: str | None = _resolve_binary(POWERMETRICS_BIN_CANDIDATES)

# Minimal env passed to every subprocess call -- no inherited environment.
SUBPROCESS_ENV: dict[str, str] = {
    "PATH": "/usr/sbin:/usr/bin:/bin:/opt/homebrew/bin",
    "LANG": "C",
}
SUBPROCESS_CWD: str = "/"


def _build_cmd(binary: str) -> list[str]:
    # Text format is the default. We intentionally do NOT pass `-f plist`:
    # on macOS 26 the plist output is unreliable / shifted key names, while
    # the text labels below are stable.
    return [
        binary,
        "--samplers",
        "cpu_power,gpu_power",
        "--sample-count",
        "1",
        "--sample-rate",
        "1000",
    ]


POWERMETRICS_CMD: list[str] | None = (
    _build_cmd(POWERMETRICS_BIN) if POWERMETRICS_BIN else None
)

CACHE_TTL_SECONDS = 2.0


@dataclass
class _CacheEntry:
    expires_at: float
    value: tuple[GPUStats | None, PowerStats | None]


class PowermetricsCollector:
    def __init__(
        self,
        cmd: list[str] | None = None,
        cache_ttl: float = CACHE_TTL_SECONDS,
    ) -> None:
        if cmd is not None:
            self._cmd: list[str] | None = list(cmd)
        else:
            self._cmd = list(POWERMETRICS_CMD) if POWERMETRICS_CMD else None
        self._cache_ttl = cache_ttl
        self._cache: _CacheEntry | None = None
        self._warned_unavailable = False

    def sample(self) -> tuple[GPUStats | None, PowerStats | None]:
        now = time.monotonic()
        if self._cache is not None and self._cache.expires_at > now:
            return self._cache.value

        value = self._sample_uncached()
        self._cache = _CacheEntry(expires_at=now + self._cache_ttl, value=value)
        return value

    def _sample_uncached(self) -> tuple[GPUStats | None, PowerStats | None]:
        if self._cmd is None:
            if not self._warned_unavailable:
                logger.warning("powermetrics binary not found; GPU/power stats disabled")
                self._warned_unavailable = True
            return None, None
        try:
            proc = subprocess.run(
                self._cmd,
                capture_output=True,
                timeout=10,
                check=False,
                env=SUBPROCESS_ENV,
                cwd=SUBPROCESS_CWD,
            )
        except FileNotFoundError:
            if not self._warned_unavailable:
                logger.warning("powermetrics binary not found; GPU/power stats disabled")
                self._warned_unavailable = True
            return None, None
        except subprocess.TimeoutExpired:
            logger.warning("powermetrics timed out")
            return None, None

        if proc.returncode != 0:
            if not self._warned_unavailable:
                # Most common: not running as root -> stderr contains "Bailing".
                stderr = (proc.stderr or b"").decode("utf-8", errors="replace").strip()
                logger.warning(
                    "powermetrics exited with %s; GPU/power stats disabled (%s)",
                    proc.returncode,
                    stderr[:200],
                )
                self._warned_unavailable = True
            return None, None

        return parse_powermetrics_text(proc.stdout)


# ---- text parser ---------------------------------------------------------

# Each regex matches a labeled line in the text output. Multiline mode so
# ^ anchors at start-of-line; we tolerate extra whitespace after the colon.
_CPU_POWER_RE = re.compile(r"^CPU Power:\s+(\d+)\s*mW\s*$", re.MULTILINE)
_GPU_POWER_RE = re.compile(r"^GPU Power:\s+(\d+)\s*mW\s*$", re.MULTILINE)
_COMBINED_POWER_RE = re.compile(
    r"^Combined Power \(CPU \+ GPU \+ ANE\):\s+(\d+)\s*mW\s*$", re.MULTILINE
)
_GPU_FREQ_RE = re.compile(r"^GPU HW active frequency:\s+(\d+)\s*MHz\s*$", re.MULTILINE)
_GPU_IDLE_RE = re.compile(r"^GPU idle residency:\s+([\d.]+)\s*%", re.MULTILINE)


def parse_powermetrics_text(raw: bytes | str) -> tuple[GPUStats | None, PowerStats | None]:
    """Parse the labeled text output of ``powermetrics``.

    Returns ``(None, None)`` only if the input is empty or totally unparseable.
    When *some* fields can be extracted, we return whatever we have (missing
    numbers default to ``0.0`` on the power side and ``None`` on the GPU side).
    """
    if not raw:
        return None, None
    text = raw.decode("utf-8", errors="replace") if isinstance(raw, (bytes, bytearray)) else raw

    gpu = _gpu_stats_from_text(text)
    power = _power_stats_from_text(text)
    return gpu, power


def _gpu_stats_from_text(text: str) -> GPUStats | None:
    idle_match = _GPU_IDLE_RE.search(text)
    freq_match = _GPU_FREQ_RE.search(text)

    # If neither GPU idle nor GPU frequency were found, the sample has no GPU
    # section at all -- return None to signal "unknown".
    if idle_match is None and freq_match is None:
        return None

    if idle_match is not None:
        idle_pct = float(idle_match.group(1))
        percent = max(0.0, min(100.0, 100.0 - idle_pct))
    else:
        percent = 0.0

    freq_mhz: float | None
    if freq_match is not None:
        freq_mhz = float(freq_match.group(1))
    else:
        freq_mhz = None

    return GPUStats(percent=percent, frequency_mhz=freq_mhz)


def _power_stats_from_text(text: str) -> PowerStats | None:
    cpu_mw = _first_int(_CPU_POWER_RE, text)
    # "GPU Power: ... mW" appears twice in a typical sample (once in the
    # power summary block, once at the end of the GPU section). Both values
    # are from the same sample window; take the first match.
    gpu_mw = _first_int(_GPU_POWER_RE, text)
    combined_mw = _first_int(_COMBINED_POWER_RE, text)

    if cpu_mw is None and gpu_mw is None and combined_mw is None:
        return None

    cpu_mw = cpu_mw if cpu_mw is not None else 0
    gpu_mw = gpu_mw if gpu_mw is not None else 0
    if combined_mw is None:
        combined_mw = cpu_mw + gpu_mw

    return PowerStats(
        cpu_package_watts=round(cpu_mw / 1000.0, 3),
        gpu_watts=round(gpu_mw / 1000.0, 3),
        total_watts=round(combined_mw / 1000.0, 3),
    )


def _first_int(pattern: re.Pattern[str], text: str) -> int | None:
    m = pattern.search(text)
    return int(m.group(1)) if m else None
