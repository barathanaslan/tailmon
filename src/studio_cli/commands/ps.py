"""``studio ps`` -- top processes table."""

from __future__ import annotations

import click

from studio_cli.client import StudioClient
from studio_cli.config import load_config, load_token
from studio_cli.formatting import console, human_bytes, make_table


@click.command("ps")
@click.option(
    "--sort",
    "sort_key",
    type=click.Choice(["cpu", "mem"], case_sensitive=False),
    default="cpu",
    help="Sort by CPU% (default) or memory RSS.",
)
@click.option(
    "--limit",
    type=click.IntRange(1, 100),
    default=20,
    help="Number of processes to show (1-100, default 20).",
)
@click.option(
    "--full-cmdline",
    is_flag=True,
    help="Show the full joined command line. WARNING: may expose secrets.",
)
def ps_cmd(sort_key: str, limit: int, full_cmdline: bool) -> None:
    """List top processes by CPU or memory."""
    cfg = load_config()
    token = load_token(cfg)
    with StudioClient(cfg, token) as client:
        # The collector currently sorts by (-cpu, -rss, pid). We re-sort
        # locally if the user asked for memory ordering. Phase 3 may push
        # this server-side once a /processes?sort= param exists.
        resp = client.processes(limit=limit, include_full_cmdline=full_cmdline)

    procs = list(resp.processes)
    if sort_key.lower() == "mem":
        procs.sort(key=lambda p: (-p.memory_rss_bytes, -p.cpu_percent, p.pid))
    else:
        procs.sort(key=lambda p: (-p.cpu_percent, -p.memory_rss_bytes, p.pid))

    table = make_table(
        "PID", "User", "CPU%", "Mem%", "RSS", "Name", "Cmdline",
        title=f"Top {len(procs)} processes (by {sort_key.lower()})",
    )
    for p in procs:
        table.add_row(
            str(p.pid),
            p.user,
            f"{p.cpu_percent:.1f}",
            f"{p.memory_percent:.1f}",
            human_bytes(p.memory_rss_bytes),
            p.name,
            p.cmdline,
        )
    console.print(table)
