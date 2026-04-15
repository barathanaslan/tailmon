"""``studio kill <pid>`` -- send a signal to a process on the Mac Studio.

Phase 3 backlog item B11. Wraps ``POST /kill``.

UX notes:

* Default signal is ``SIGTERM`` (15). ``--kill`` is a shortcut for SIGKILL (9).
* Without ``--yes``, we first fetch ``/processes``, show a confirmation line
  with the process name / user / RSS, and bail out unless the user types
  ``y`` / ``yes``. This is a guardrail, not a picker -- the user has already
  committed to a specific pid on the command line.
* On HTTP errors the underlying :class:`StudioClientError` bubbles up and
  is rendered as a red one-liner by :class:`StudioGroup.invoke`.
"""

from __future__ import annotations

import click

from studio_cli.client import StudioClient, StudioClientError
from studio_cli.config import load_config, load_token
from studio_cli.formatting import console, human_bytes

_SIGNAL_NAMES = {1: "SIGHUP", 2: "SIGINT", 9: "SIGKILL", 15: "SIGTERM"}


def _lookup_process(client: StudioClient, pid: int) -> dict | None:
    """Fetch ``/processes`` and return the entry for ``pid`` or ``None``."""
    try:
        resp = client.processes(limit=1000)
    except StudioClientError:
        # Listing failed -- don't block the kill just because the enrich
        # failed; caller will show a weaker prompt.
        return None
    for proc in resp.processes:
        if proc.pid == pid:
            return {
                "pid": proc.pid,
                "name": proc.name,
                "user": proc.user,
                "memory_rss_bytes": proc.memory_rss_bytes,
            }
    return None


def _confirm(info: dict | None, pid: int, signal: int) -> bool:
    sig_name = _SIGNAL_NAMES.get(signal, f"SIG{signal}")
    if info is None:
        prompt = f"Send {sig_name} to pid={pid} (process details unavailable)? [y/N] "
    else:
        rss = human_bytes(info["memory_rss_bytes"])
        prompt = (
            f"Kill {info['name']} (pid={info['pid']}, user={info['user']}, "
            f"RSS={rss}) with {sig_name}? [y/N] "
        )
    answer = click.prompt(prompt, default="", show_default=False).strip().lower()
    return answer in {"y", "yes"}


@click.command("kill")
@click.argument("pid", type=click.IntRange(min=1, max=2**31 - 1))
@click.option(
    "--signal",
    "signal_num",
    type=click.IntRange(min=1, max=64),
    default=15,
    help="Signal number (default 15 / SIGTERM). Allowed: 1, 2, 9, 15.",
)
@click.option(
    "--kill",
    "kill_alias",
    is_flag=True,
    help="Shortcut for --signal 9 (SIGKILL).",
)
@click.option(
    "--yes",
    "skip_prompt",
    is_flag=True,
    help="Skip the confirmation prompt.",
)
def kill_cmd(pid: int, signal_num: int, kill_alias: bool, skip_prompt: bool) -> None:
    """Send a signal to a process on the Mac Studio."""
    if kill_alias:
        signal_num = 9

    cfg = load_config()
    token = load_token(cfg)
    with StudioClient(cfg, token) as client:
        if not skip_prompt:
            info = _lookup_process(client, pid)
            if not _confirm(info, pid, signal_num):
                console.print("[yellow]aborted.[/yellow]")
                raise SystemExit(1)

        body = client.kill(pid=pid, signal=signal_num)

    sig_name = _SIGNAL_NAMES.get(signal_num, f"SIG{signal_num}")
    name = body.get("process_name", "?")
    console.print(
        f"[green]killed[/green] {name} (pid={body.get('pid', pid)}) with {sig_name}"
    )
