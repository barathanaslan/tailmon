"""``studio ports`` -- listening port table."""

from __future__ import annotations

import time

import click
from rich.live import Live

from studio_cli.client import StudioClient
from studio_cli.config import load_config, load_token
from studio_cli.formatting import console, make_table


def _build_table(resp) -> "Table":  # noqa: F821 -- forward ref to rich.table.Table
    table = make_table(
        "Proto", "Address", "Port", "PID", "Process", "User", "Fam",
        title="Listening ports",
    )
    for p in sorted(resp.ports, key=lambda x: x.port):
        # When a row has collapsed multiple address families (e.g. sshd
        # bound to 0.0.0.0:22 and :::22), render them as "v4+v6". Single-
        # family rows are left blank so the column is unobtrusive.
        if p.address_families and len(p.address_families) > 1:
            fam = "+".join(p.address_families)
        else:
            fam = ""
        table.add_row(
            p.protocol,
            p.address,
            str(p.port),
            str(p.pid) if p.pid is not None else "-",
            p.process_name or "-",
            p.user or "-",
            fam,
        )
    return table


@click.command("ports")
@click.option("--watch", is_flag=True, help="Refresh every 2 seconds.")
def ports_cmd(watch: bool) -> None:
    """List listening TCP/UDP ports with the owning process."""
    cfg = load_config()
    token = load_token(cfg)
    with StudioClient(cfg, token) as client:
        if not watch:
            resp = client.ports()
            console.print(_build_table(resp))
            return

        # Watch mode: refresh every 2s. Cap to a sensible long duration so
        # tests with a fake clock don't spin forever; in practice the user
        # interrupts with Ctrl-C.
        with Live(_build_table(client.ports()), console=console, refresh_per_second=2) as live:
            try:
                while True:
                    time.sleep(2)
                    live.update(_build_table(client.ports()))
            except KeyboardInterrupt:
                pass
