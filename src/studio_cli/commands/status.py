"""``studio status`` -- compact one-screen overview."""

from __future__ import annotations

import click

from studio_cli.client import StudioClient
from studio_cli.config import load_config, load_token
from studio_cli.formatting import bar, console, human_bytes
from shared.models import PortInfo


# Well-known system ports to downrank in the top-5 view. The goal is not
# to categorize exhaustively -- just to push sshd, mDNS, NTP, DHCP, DNS,
# CUPS, llmnr etc. out of the first five rows so the user actually sees
# the interesting listeners (app dev servers, studiod itself, custom
# services). The full list is still available via ``studio ports``.
SYSTEM_WELL_KNOWN_PORTS: frozenset[int] = frozenset(
    {
        22,     # ssh
        53,     # DNS
        67,     # DHCP server
        68,     # DHCP client
        88,     # Kerberos
        123,    # NTP
        137,    # NetBIOS
        138,    # NetBIOS
        139,    # NetBIOS
        445,    # SMB
        500,    # ISAKMP / IKE
        546,    # DHCPv6 client
        547,    # DHCPv6 server
        631,    # CUPS
        5353,   # mDNS
        5355,   # LLMNR
        5900,   # VNC / Screen Sharing
    }
)


def _split_system_ports(
    ports: list[PortInfo],
) -> tuple[list[PortInfo], list[PortInfo]]:
    """Return ``(interesting, system)`` for the status top-N view."""
    interesting: list[PortInfo] = []
    system: list[PortInfo] = []
    for p in ports:
        if p.port in SYSTEM_WELL_KNOWN_PORTS:
            system.append(p)
        else:
            interesting.append(p)
    return interesting, system


def _port_display_line(p: PortInfo) -> str:
    """Render a single port row for the status view.

    Rich treats ``[...]`` as BBCode-style markup, so the family tag needs
    the literal brackets escaped as ``\\[...]``. The backslash is consumed
    by Rich on output but remains in the raw string, which is also what
    Click's ``CliRunner`` sees -- tests assert on the escaped form.
    """
    proc = p.process_name or "-"
    family_tag = ""
    if p.address_families and len(p.address_families) > 1:
        family_tag = f" \\[{'+'.join(p.address_families)}]"
    return f"    {p.protocol}/{p.port:<6} {proc}{family_tag}"


@click.command("status")
def status_cmd() -> None:
    """Show a compact one-screen system overview."""
    cfg = load_config()
    token = load_token(cfg)
    with StudioClient(cfg, token) as client:
        stats = client.stats()
        sessions = client.ssh_sessions()
        ports = client.ports()

    cpu_pct = stats.cpu.percent_total
    gpu_pct = stats.gpu.percent if stats.gpu is not None else None
    mem_pct = stats.memory.percent

    console.print("[bold cyan]studio status[/bold cyan]")
    console.print(f"  CPU  {bar(cpu_pct)}")
    console.print(f"  GPU  {bar(gpu_pct)}")
    console.print(
        f"  MEM  {bar(mem_pct)}  "
        f"{human_bytes(stats.memory.used_bytes)} / {human_bytes(stats.memory.total_bytes)}"
    )
    if stats.memory.cached_files_bytes is not None:
        console.print(
            f"       Cached: {human_bytes(stats.memory.cached_files_bytes)}"
        )

    if stats.power is not None:
        console.print(
            f"  PWR  CPU {stats.power.cpu_package_watts:.1f} W "
            f"\u00b7 GPU {stats.power.gpu_watts:.1f} W "
            f"\u00b7 Total {stats.power.total_watts:.1f} W"
        )
    else:
        console.print("  PWR  -")

    console.print()
    console.print(f"[bold]SSH sessions:[/bold] {len(sessions.sessions)}")
    for s in sessions.sessions:
        peer = s.tailscale_peer.hostname if s.tailscale_peer else s.source_ip
        console.print(f"    pid {s.pid}  {s.user}@{peer}  ({s.tty or '-'})")

    console.print()
    # Sort by port for deterministic output, then split into "interesting"
    # (user / app / custom service ports) and "system" (sshd, mDNS, NTP,
    # ...). Show up to 5 interesting rows; backfill with system rows if
    # fewer than 5 non-system ports are listening. Always show the count
    # of the filtered rows so the user knows they're hidden on purpose.
    sorted_ports = sorted(ports.ports, key=lambda p: p.port)
    interesting, system = _split_system_ports(sorted_ports)

    console.print(f"[bold]Listening ports:[/bold] {len(sorted_ports)}")
    top: list[PortInfo] = interesting[:5]
    if len(top) < 5:
        top = top + system[: (5 - len(top))]
    for p in top:
        console.print(_port_display_line(p))

    hidden_system = len(system) - max(0, 5 - len(interesting))
    if hidden_system > 0:
        console.print(f"    +{hidden_system} system port(s) (see `studio ports`)")
