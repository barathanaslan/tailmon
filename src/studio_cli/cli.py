"""Top-level click group and dispatch for ``studio``.

Dispatch behavior (preserves the user's existing zsh muscle memory):

* ``studio``                      -> tmux picker (fzf)
* ``studio <session-name>``       -> direct ``ssh -t macstudio tmux ... -s <name>``
* ``studio status``               -> the ``status`` subcommand
* ``studio tmux <name>``          -> explicit tmux subcommand (disambiguates a
                                     session literally named e.g. "status")
* ``studio --help`` / ``--version`` -> click defaults

Implementation:

We declare a :class:`click.Group` with ``invoke_without_command=True``. The
group callback inspects ``ctx.invoked_subcommand`` -- if it is None, the
user either gave us nothing or a positional that click did not match to a
subcommand. We then look at ``sys.argv`` (rather than re-parsing) to decide
between picker mode and direct-attach mode.

Why ``sys.argv`` and not click args? Click strips out the unknown positional
before the callback runs because we declared no positional on the group.
The cleanest way to recover it without fighting click is to read argv
directly. The reserved-name check guards against accidentally swallowing
typoed subcommand names (e.g. ``studio statuz``).
"""

from __future__ import annotations

import sys

import click

from studio_cli import __version__
from studio_cli.client import StudioClientError
from studio_cli.commands.config_cmd import config_group
from studio_cli.commands.kick import kick_cmd
from studio_cli.commands.kill import kill_cmd
from studio_cli.commands.ports import ports_cmd
from studio_cli.commands.ps import ps_cmd
from studio_cli.commands.sessions import sessions_cmd
from studio_cli.commands.stats import stats_cmd
from studio_cli.commands.status import status_cmd
from studio_cli.commands.tmux import run_tmux_command, tmux_cmd
from studio_cli.commands.who import who_cmd
from studio_cli.config import StudioConfigError

# Reserved subcommand names. If sys.argv[1] matches one of these (or starts
# with '-'), we let click handle it normally. Otherwise we treat argv[1] as
# a tmux session name. Keep this list in sync with the registrations below.
#
# Phase 3 adds ``kill`` and ``kick`` -- a tmux session literally named
# ``kill`` can't be attached with the bareword shortcut ``studio kill`` any
# more; use ``studio tmux kill`` explicitly. Destructive-command safety
# outranks the shortcut.
RESERVED_NAMES = frozenset(
    {
        "tmux",
        "status",
        "ports",
        "who",
        "ps",
        "sessions",
        "stats",
        "config",
        "version",
        "kill",
        "kick",
        "--help",
        "-h",
        "--version",
    }
)


class StudioGroup(click.Group):
    """A click Group that routes unknown positional args to the tmux command.

    We override ``resolve_command`` so that ``studio main`` (where ``main``
    is a tmux session name, not a subcommand) does not crash with click's
    "no such command" error -- it instead dispatches to ``tmux`` with that
    name.

    We also override ``invoke`` so ``StudioClientError`` and
    ``StudioConfigError`` raised by any subcommand surface as a friendly
    one-line error + ``ctx.exit(1)`` rather than a Python traceback. This
    runs whether the entry point is ``cli.main()`` (the console script) or
    ``runner.invoke(cli, ...)`` from the test suite, so behavior is
    identical in both contexts.
    """

    def resolve_command(self, ctx, args):
        try:
            return super().resolve_command(ctx, args)
        except click.UsageError:
            if args and not args[0].startswith("-") and args[0] not in RESERVED_NAMES:
                # Re-route to the tmux subcommand with the bareword as NAME.
                cmd = self.get_command(ctx, "tmux")
                assert cmd is not None  # tmux is always registered
                return cmd.name, cmd, args
            raise

    def invoke(self, ctx):
        try:
            return super().invoke(ctx)
        except StudioClientError as exc:
            click.secho(f"error: {exc}", fg="red", err=True)
            ctx.exit(1)
        except StudioConfigError as exc:
            click.secho(f"config error: {exc}", fg="red", err=True)
            ctx.exit(1)


@click.group(
    cls=StudioGroup,
    invoke_without_command=True,
    context_settings={"help_option_names": ["-h", "--help"]},
)
@click.version_option(__version__, "-V", "--version", prog_name="studio")
@click.pass_context
def cli(ctx: click.Context) -> None:
    """studio: monitor and control the Mac Studio over Tailscale.

    With no arguments, opens an fzf picker for tmux sessions on the Mac
    Studio (matching the legacy `studio()` zsh function). With a bare
    session name, attaches to that tmux session directly.
    """
    if ctx.invoked_subcommand is not None:
        return
    # No subcommand and no positional that resolve_command rerouted -- this
    # is the bare `studio` invocation. Open the picker.
    code = run_tmux_command(name=None)
    ctx.exit(code)


# Register subcommands.
cli.add_command(tmux_cmd)
cli.add_command(status_cmd)
cli.add_command(ports_cmd)
cli.add_command(who_cmd)
cli.add_command(ps_cmd)
cli.add_command(sessions_cmd)
cli.add_command(stats_cmd)
cli.add_command(config_group)
cli.add_command(kill_cmd)
cli.add_command(kick_cmd)


@cli.command("version")
def version_cmd() -> None:
    """Print the studio-cli package version."""
    click.echo(f"studio-cli {__version__}")


def main(argv: list[str] | None = None) -> int:
    """Console script entry point. Catches user-facing errors and exits."""
    try:
        cli.main(args=argv, prog_name="studio", standalone_mode=False)
    except click.exceptions.UsageError as exc:
        exc.show()
        return exc.exit_code
    except click.exceptions.Abort:
        click.secho("aborted.", fg="yellow", err=True)
        return 130
    except SystemExit as exc:
        return int(exc.code) if exc.code is not None else 0
    except StudioClientError as exc:
        click.secho(f"error: {exc}", fg="red", err=True)
        return 1
    except StudioConfigError as exc:
        click.secho(f"config error: {exc}", fg="red", err=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
