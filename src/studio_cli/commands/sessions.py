"""``studio sessions`` -- non-interactive tmux session list.

For the interactive picker (the muscle-memory replacement), see
``studio_cli.commands.tmux``.
"""

from __future__ import annotations

import click

from studio_cli.client import StudioClient
from studio_cli.config import load_config, load_token
from studio_cli.formatting import console


@click.command("sessions")
def sessions_cmd() -> None:
    """List tmux sessions on the Mac Studio (non-interactive)."""
    cfg = load_config()
    token = load_token(cfg)
    with StudioClient(cfg, token) as client:
        resp = client.tmux_sessions()

    if not resp.sessions:
        console.print("No tmux sessions.")
        return

    for s in resp.sessions:
        marker = "\u25cf attached" if s.attached else "\u25cb detached"
        console.print(f"  {s.name}  {marker}  ({s.windows} window{'s' if s.windows != 1 else ''})")
