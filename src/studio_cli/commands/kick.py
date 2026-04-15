"""``studio kick <pid>`` -- terminate an SSH session on the Mac Studio.

Phase 3 backlog B11. Wraps ``POST /ssh/kick``. Uses ``/ssh/sessions`` to
build a confirmation prompt unless ``--yes``.
"""

from __future__ import annotations

import click

from studio_cli.client import StudioClient, StudioClientError
from studio_cli.config import load_config, load_token
from studio_cli.formatting import console


def _lookup_session(client: StudioClient, pid: int) -> dict | None:
    try:
        resp = client.ssh_sessions()
    except StudioClientError:
        return None
    for sess in resp.sessions:
        if sess.pid == pid:
            peer = sess.tailscale_peer
            peer_label = None
            if peer is not None:
                peer_label = peer.hostname
                if peer.user_display_name:
                    peer_label = f"{peer.hostname} ({peer.user_display_name})"
            return {
                "pid": sess.pid,
                "user": sess.user,
                "source_ip": sess.source_ip,
                "peer_label": peer_label,
            }
    return None


def _confirm(info: dict | None, pid: int) -> bool:
    if info is None:
        prompt = (
            f"Kick ssh session pid={pid} "
            "(session details unavailable)? [y/N] "
        )
    else:
        peer = info["peer_label"] or "unknown peer"
        prompt = (
            f"Kick ssh session pid={info['pid']} user={info['user']} "
            f"from {info['source_ip']} [{peer}]? [y/N] "
        )
    answer = click.prompt(prompt, default="", show_default=False).strip().lower()
    return answer in {"y", "yes"}


@click.command("kick")
@click.argument("pid", type=click.IntRange(min=1, max=2**31 - 1))
@click.option(
    "--yes",
    "skip_prompt",
    is_flag=True,
    help="Skip the confirmation prompt.",
)
def kick_cmd(pid: int, skip_prompt: bool) -> None:
    """Terminate an SSH session on the Mac Studio by sending SIGHUP."""
    cfg = load_config()
    token = load_token(cfg)
    with StudioClient(cfg, token) as client:
        if not skip_prompt:
            info = _lookup_session(client, pid)
            if not _confirm(info, pid):
                console.print("[yellow]aborted.[/yellow]")
                raise SystemExit(1)

        body = client.ssh_kick(pid=pid)

    session = body.get("session") or {}
    source_ip = session.get("source_ip", "?")
    console.print(
        f"[green]kicked[/green] ssh session pid={session.get('pid', pid)} "
        f"from {source_ip}"
    )
