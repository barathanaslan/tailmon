"""``studio tmux`` -- replacement for the existing zsh fzf-picker function.

Behavior matches the user's pre-existing ``studio()`` zsh function at
``~/.zshrc:95-140``:

* No NAME: fetch the tmux session list from the collector, present it via
  ``fzf``, then SSH in and attach.
* With NAME: SSH straight in and run ``tmux new-session -A -s NAME``.

The final SSH call uses :func:`os.execvp` so the Python process is replaced
by ssh -- there is no lingering Python wrapper holding the user's terminal.

Security notes:

* No ``shell=True`` anywhere. Both fzf and ssh are invoked with arg lists.
* Session names are validated against a strict regex before being passed
  through, so a name like ``$(rm -rf /)`` cannot reach the remote shell.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys

import click

from studio_cli.client import StudioClient, StudioClientError
from studio_cli.config import ClientConfig, load_config, load_token
from studio_cli.formatting import err_console

SESSION_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")


def _validate_session_name(name: str) -> None:
    if not SESSION_NAME_RE.match(name):
        raise click.UsageError(
            f"invalid tmux session name {name!r}: "
            "only letters, digits, '_', '.', and '-' are allowed"
        )


def _format_session_lines(sessions: list[dict]) -> list[str]:
    """Build the fzf input lines, mirroring the zsh function's format.

    Each line is ``"<name>  <indicator> <state>"``. The first whitespace
    token is the session name, which the post-fzf parser splits back out.
    """
    lines: list[str] = []
    for s in sessions:
        indicator = "\u25cf" if s["attached"] else "\u25cb"
        state = "attached" if s["attached"] else "detached"
        lines.append(f"{s['name']}  {indicator} {state}")
    lines.append("+ New session")
    return lines


def _fzf_pick(lines: list[str]) -> str | None:
    """Run fzf as a subprocess and return the selected line, or None on cancel.

    If fzf isn't installed, raise a :class:`click.UsageError` rather than
    silently doing nothing.
    """
    try:
        proc = subprocess.run(
            [
                "fzf",
                "--height=40%",
                "--reverse",
                "--prompt=tmux > ",
                "--header=Pick a session (Esc to cancel)",
            ],
            input="\n".join(lines),
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:
        raise click.UsageError(
            "fzf is not installed -- install it with `brew install fzf`"
        ) from exc
    if proc.returncode != 0:
        return None  # user pressed Esc / Ctrl-C
    picked = proc.stdout.strip()
    return picked or None


def _prompt_new_session_name() -> str | None:
    """Prompt the user for a new session name. Returns None on empty input."""
    try:
        name = click.prompt("New session name", type=str, default="", show_default=False)
    except click.Abort:
        return None
    name = name.strip()
    if not name:
        return None
    _validate_session_name(name)
    return name


def _exec_ssh_attach(cfg: ClientConfig, session: str) -> None:
    """Replace the current process with ssh ... tmux new-session -A -s <session>.

    Uses :func:`os.execvp` so the user's terminal goes straight to the
    remote tmux session with no Python wrapper in between.
    """
    args = [
        "ssh",
        "-t",
        cfg.ssh_host,
        "tmux",
        "new-session",
        "-A",
        "-s",
        session,
    ]
    os.execvp(args[0], args)  # noqa: S606 -- argv list, no shell


def run_tmux_command(name: str | None, cfg: ClientConfig | None = None) -> int:
    """Top-level helper that the click command and the dispatch fallback share.

    Returns an exit code (only used in error paths -- the success path
    execvp's away).
    """
    cfg = cfg or load_config()

    if name is not None:
        _validate_session_name(name)
        _exec_ssh_attach(cfg, name)
        return 0  # unreachable

    # Picker mode: fetch sessions over HTTP, run fzf locally, then ssh in.
    try:
        token = load_token(cfg)
        with StudioClient(cfg, token) as client:
            resp = client.tmux_sessions()
    except StudioClientError as exc:
        err_console.print(f"[red]error:[/red] {exc}")
        return 1

    session_dicts = [
        {"name": s.name, "attached": s.attached, "windows": s.windows}
        for s in resp.sessions
    ]
    lines = _format_session_lines(session_dicts)
    picked = _fzf_pick(lines)
    if picked is None:
        return 0  # user cancelled

    if picked.startswith("+ New session"):
        new_name = _prompt_new_session_name()
        if new_name is None:
            return 0
        _exec_ssh_attach(cfg, new_name)
        return 0  # unreachable

    # The first whitespace-delimited token is the session name.
    session_name = picked.split()[0]
    _validate_session_name(session_name)
    _exec_ssh_attach(cfg, session_name)
    return 0  # unreachable


class _TmuxGroup(click.Group):
    """A click Group so we can host ``studio tmux new`` while still letting
    ``studio tmux <name>`` dispatch to the attach/picker handler.

    When click tries to resolve ``<name>`` as a subcommand and fails, we
    re-route to the synthetic ``__attach__`` command below. Actual
    subcommands (``new``) take precedence because ``super().resolve_command``
    is tried first.
    """

    def resolve_command(self, ctx, args):
        try:
            return super().resolve_command(ctx, args)
        except click.UsageError:
            if args and not args[0].startswith("-"):
                attach = self.get_command(ctx, "__attach__")
                assert attach is not None
                return attach.name, attach, args
            raise


@click.group(
    "tmux",
    cls=_TmuxGroup,
    invoke_without_command=True,
    context_settings={"help_option_names": ["-h", "--help"]},
)
@click.pass_context
def tmux_cmd(ctx: click.Context) -> None:
    """Attach to a tmux session on the Mac Studio (fzf picker by default)."""
    if ctx.invoked_subcommand is not None:
        return
    code = run_tmux_command(None)
    sys.exit(code)


@tmux_cmd.command("__attach__", hidden=True)
@click.argument("name", required=False)
def _tmux_attach(name: str | None) -> None:
    """Internal fallthrough: attach to NAME (invoked when NAME isn't a subcmd)."""
    code = run_tmux_command(name)
    sys.exit(code)


@tmux_cmd.command("new")
@click.argument("name")
def tmux_new_cmd(name: str) -> None:
    """Create a new tmux session on the Mac Studio without attaching."""
    from studio_cli.client import StudioClient
    from studio_cli.config import load_config, load_token
    from studio_cli.formatting import console

    _validate_session_name(name)
    cfg = load_config()
    token = load_token(cfg)
    with StudioClient(cfg, token) as client:
        body = client.tmux_new(name=name)
    if body.get("created"):
        console.print(f"[green]created[/green] tmux session {name}")
    elif body.get("exists"):
        console.print(f"tmux session [cyan]{name}[/cyan] already exists")
    else:
        console.print(f"tmux new: {body}")
