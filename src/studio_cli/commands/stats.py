"""``studio stats`` -- raw stats dump."""

from __future__ import annotations

import json

import click

from studio_cli.client import StudioClient
from studio_cli.config import load_config, load_token
from studio_cli.formatting import bar, console, human_bytes


@click.command("stats")
@click.option("--json", "as_json", is_flag=True, help="Dump the raw JSON response.")
def stats_cmd(as_json: bool) -> None:
    """Print the current /stats snapshot."""
    cfg = load_config()
    token = load_token(cfg)
    with StudioClient(cfg, token) as client:
        resp = client.stats()

    if as_json:
        console.print_json(json.dumps(resp.model_dump(mode="json")))
        return

    console.print("[bold]CPU[/bold]")
    console.print(f"  total       {bar(resp.cpu.percent_total)}")
    console.print(f"  per-core    {[round(c, 1) for c in resp.cpu.percent_per_core]}")
    console.print(
        f"  load avg    {resp.cpu.load_avg[0]:.2f} "
        f"{resp.cpu.load_avg[1]:.2f} {resp.cpu.load_avg[2]:.2f}"
    )

    console.print("[bold]Memory[/bold]")
    console.print(
        f"  used/total  {human_bytes(resp.memory.used_bytes)} / "
        f"{human_bytes(resp.memory.total_bytes)} ({resp.memory.percent:.1f}%)"
    )
    console.print(
        f"  swap        {human_bytes(resp.memory.swap_used_bytes)} / "
        f"{human_bytes(resp.memory.swap_total_bytes)}"
    )

    console.print("[bold]GPU[/bold]")
    if resp.gpu is not None:
        console.print(f"  utilization {bar(resp.gpu.percent)}")
        if resp.gpu.frequency_mhz is not None:
            console.print(f"  frequency   {resp.gpu.frequency_mhz:.0f} MHz")
    else:
        console.print("  -")

    console.print("[bold]Power[/bold]")
    if resp.power is not None:
        console.print(f"  CPU         {resp.power.cpu_package_watts:.2f} W")
        console.print(f"  GPU         {resp.power.gpu_watts:.2f} W")
        console.print(f"  Total       {resp.power.total_watts:.2f} W")
    else:
        console.print("  -")
