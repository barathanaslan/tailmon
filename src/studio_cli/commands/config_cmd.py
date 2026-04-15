"""``studio config`` -- inspect the resolved client configuration."""

from __future__ import annotations

import click

from studio_cli.config import (
    DEFAULT_CONFIG_FILE,
    StudioConfigError,
    load_config,
    load_token,
    redact_token,
)
from studio_cli.formatting import console


@click.group("config")
def config_group() -> None:
    """Inspect the loaded studio-cli client configuration."""


@config_group.command("show")
def config_show() -> None:
    """Print the resolved client configuration (token redacted)."""
    cfg = load_config()
    try:
        token = load_token(cfg)
        token_display = redact_token(token)
    except StudioConfigError as exc:
        token_display = f"(unavailable: {exc.args[0].splitlines()[0]})"

    console.print("[bold]studio-cli config[/bold]")
    console.print(f"  collector_url   {cfg.collector_url}")
    console.print(f"  token_file      {cfg.token_file}")
    console.print(f"  token           {token_display}")
    console.print(f"  timeout_seconds {cfg.timeout_seconds}")
    console.print(f"  ssh_host        {cfg.ssh_host}")
    console.print(f"  config_file     {cfg.config_file or '(none, using defaults)'}")


@config_group.command("path")
def config_path() -> None:
    """Print the path the client searches for its config file."""
    cfg = load_config()
    console.print(str(cfg.config_file or DEFAULT_CONFIG_FILE))
