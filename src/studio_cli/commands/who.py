"""``studio who`` -- active SSH sessions with Tailscale peer labels."""

from __future__ import annotations

import click

from studio_cli.client import StudioClient
from studio_cli.config import load_config, load_token
from studio_cli.formatting import console, human_duration, human_time, make_table


@click.command("who")
def who_cmd() -> None:
    """List active SSH sessions on the Mac Studio."""
    cfg = load_config()
    token = load_token(cfg)
    with StudioClient(cfg, token) as client:
        resp = client.ssh_sessions()

    if not resp.sessions:
        console.print("No active SSH sessions.")
        return

    table = make_table(
        "PID", "User", "From", "Peer", "TTY", "Started", "Idle",
        title="SSH sessions",
    )
    for s in resp.sessions:
        peer_label = s.tailscale_peer.hostname if s.tailscale_peer else "-"
        table.add_row(
            str(s.pid),
            s.user,
            f"{s.source_ip}:{s.source_port}",
            peer_label,
            s.tty or "-",
            human_time(s.started_at),
            human_duration(s.idle_seconds),
        )
    console.print(table)
