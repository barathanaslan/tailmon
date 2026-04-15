"""Rich rendering helpers shared across subcommands.

Centralizes table styling, byte / duration / timestamp formatting, and the
ASCII bars used by ``studio status``. Everything is deterministic so tests
can assert on substrings without having to introspect rich's internal state.
"""

from __future__ import annotations

from datetime import datetime, timezone

from rich.console import Console
from rich.table import Table

# A single shared console instance keeps width detection consistent across
# subcommands and lets tests redirect output trivially.
console = Console()
err_console = Console(stderr=True)


def make_table(*columns: str, title: str | None = None) -> Table:
    """Build a :class:`rich.table.Table` with the project's house style."""
    table = Table(title=title, show_lines=False, header_style="bold cyan")
    for col in columns:
        table.add_column(col)
    return table


def human_bytes(n: int | float) -> str:
    """Format a byte count as e.g. ``1.4G``, ``512M``, ``8.2K``."""
    n = float(n)
    for unit in ("B", "K", "M", "G", "T", "P"):
        if abs(n) < 1024.0:
            if unit == "B":
                return f"{int(n)}B"
            return f"{n:.1f}{unit}"
        n /= 1024.0
    return f"{n:.1f}E"


def human_duration(seconds: float | None) -> str:
    """Format a duration in seconds as e.g. ``3s``, ``5m``, ``2h13m``."""
    if seconds is None:
        return "-"
    s = int(seconds)
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m"
    if s < 86400:
        return f"{s // 3600}h{(s % 3600) // 60}m"
    return f"{s // 86400}d{(s % 86400) // 3600}h"


def human_time(ts: datetime | None) -> str:
    """Render a timestamp in the local timezone as ``HH:MM:SS``."""
    if ts is None:
        return "-"
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts.astimezone().strftime("%H:%M:%S")


def bar(percent: float | None, width: int = 20) -> str:
    """Return a unicode bar of ``width`` cells filled to ``percent`` (0..100)."""
    if percent is None:
        return "[" + "-" * width + "] -"
    p = max(0.0, min(100.0, float(percent)))
    filled = int(round((p / 100.0) * width))
    return "[" + "#" * filled + "-" * (width - filled) + f"] {p:5.1f}%"
