"""psutil-backed collector for CPU, memory, processes, and listening ports."""

from __future__ import annotations

import ipaddress
import logging
import os
import threading
import time
from datetime import datetime, timezone

import psutil

from collector.sources.memory_macos import VmStatCollector, VmStatSample
from shared.models import CPUStats, MemoryStats, PortInfo, ProcessInfo

logger = logging.getLogger(__name__)

# psutil returns cpu_percent=0.0 on the first call per-process. We prime the
# cache on construction so subsequent calls carry a meaningful delta.
_PROCESS_ATTRS = [
    "pid",
    "ppid",
    "username",
    "name",
    "cmdline",
    "cpu_percent",
    "memory_info",
    "memory_percent",
    "status",
    "create_time",
]

# Default interval between background CPU/process snapshots, in seconds.
# Chosen to match the 2-second refresh that `studio ports --watch` and the
# menubar popover will poll at, so the cache is always fresh enough.
_REFRESH_INTERVAL = 2.0

# Warm-up sleep between the __init__-time priming call and the first real
# sample. psutil's cpu_percent needs a non-zero time delta between samples
# to produce meaningful numbers; 500ms is enough and keeps startup snappy.
_WARMUP_SLEEP = 0.5


def _utc(ts: float) -> datetime:
    return datetime.fromtimestamp(ts, tz=timezone.utc)


class SystemCollector:
    """Real psutil-backed collector. Safe to instantiate at import time.

    A background daemon thread periodically re-samples per-process CPU%
    and the system-wide CPU figures so that the FastAPI route handlers
    can read a fresh snapshot without the "first call returns 0.0"
    quirk of ``psutil.cpu_percent(interval=None)``. The thread can be
    disabled for tests via ``background=False``.
    """

    def __init__(
        self,
        *,
        background: bool = True,
        refresh_interval: float = _REFRESH_INTERVAL,
        vm_stat: VmStatCollector | None = None,
    ) -> None:
        # Prime per-core and total CPU counters so the first real call is
        # actually meaningful. These calls are non-blocking (interval=None).
        psutil.cpu_percent(interval=None, percpu=False)
        psutil.cpu_percent(interval=None, percpu=True)
        # Prime every process' cpu_percent cache too -- without this the
        # first pass through process_iter returns 0.0 for every process,
        # which is B2. We tolerate AccessDenied on a few pids.
        for proc in psutil.process_iter(["pid"]):
            try:
                proc.cpu_percent(interval=None)
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue

        self._refresh_interval = refresh_interval
        self._lock = threading.Lock()
        self._cached_cpu_total: float | None = None
        self._cached_cpu_percore: list[float] | None = None
        self._cached_processes: list[ProcessInfo] | None = None
        self._cached_sampled_at: float = 0.0
        self._vm_stat = vm_stat if vm_stat is not None else VmStatCollector()

        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        if background:
            # Give psutil a real delta for the first background sample.
            time.sleep(_WARMUP_SLEEP)
            self._refresh_cpu()
            self._thread = threading.Thread(
                target=self._run_loop,
                name="studiod-cpu-refresh",
                daemon=True,
            )
            self._thread.start()

    # ----- Background loop -----

    def _run_loop(self) -> None:
        while not self._stop_event.is_set():
            if self._stop_event.wait(self._refresh_interval):
                return
            try:
                self._refresh_cpu()
            except Exception:  # pragma: no cover - defensive
                logger.exception("CPU refresh loop iteration failed")

    def _refresh_cpu(self) -> None:
        """Take one system + per-process CPU snapshot and update the cache.

        Safe to call directly from tests (with ``background=False``) -- no
        locking surprises because the caller controls the thread of
        execution.
        """
        total = psutil.cpu_percent(interval=None, percpu=False)
        per_core = psutil.cpu_percent(interval=None, percpu=True)
        processes: list[ProcessInfo] = []
        for proc in psutil.process_iter(_PROCESS_ATTRS):
            try:
                info = proc.info
                cmdline_list = info.get("cmdline") or []
                # Always cache the full argv as a list on the ProcessInfo-
                # shaped dict so that process_list() can decide at request
                # time whether to expose argv[0] only or the full joined
                # line. We store it joined here for simplicity -- the
                # process_list() renderer splits it back at the first
                # space when redaction is needed.
                cmdline_full = " ".join(cmdline_list) if cmdline_list else ""
                mem_info = info.get("memory_info")
                rss = int(getattr(mem_info, "rss", 0) or 0)
                create_time = info.get("create_time") or 0.0
                processes.append(
                    ProcessInfo(
                        pid=int(info["pid"]),
                        ppid=int(info.get("ppid") or 0),
                        user=str(info.get("username") or ""),
                        name=str(info.get("name") or ""),
                        cmdline=cmdline_full,
                        cpu_percent=float(info.get("cpu_percent") or 0.0),
                        memory_rss_bytes=rss,
                        memory_percent=float(info.get("memory_percent") or 0.0),
                        status=str(info.get("status") or ""),
                        create_time=_utc(float(create_time)),
                    )
                )
            except (psutil.NoSuchProcess, psutil.AccessDenied, ValueError, TypeError):
                continue

        with self._lock:
            self._cached_cpu_total = float(total)
            self._cached_cpu_percore = [float(x) for x in per_core]
            self._cached_processes = processes
            self._cached_sampled_at = time.monotonic()

    # ----- CPU -----

    def cpu_stats(self) -> CPUStats:
        with self._lock:
            total = self._cached_cpu_total
            per_core = list(self._cached_cpu_percore or [])

        if total is None:
            # Cold path: background thread hasn't produced a sample yet.
            # Fall back to an on-demand read. May return 0.0 on very first
            # call but will be correct on subsequent ones.
            total = psutil.cpu_percent(interval=None, percpu=False)
            per_core = [
                float(x) for x in psutil.cpu_percent(interval=None, percpu=True)
            ]

        try:
            load1, load5, load15 = psutil.getloadavg()
        except (AttributeError, OSError):
            load1 = load5 = load15 = 0.0
        return CPUStats(
            percent_total=float(total),
            percent_per_core=[float(x) for x in per_core],
            load_avg=(float(load1), float(load5), float(load15)),
        )

    # ----- Memory -----

    def memory_stats(self) -> MemoryStats:
        vm = psutil.virtual_memory()
        sw = psutil.swap_memory()

        sample: VmStatSample | None = None
        try:
            sample = self._vm_stat.sample()
        except Exception:  # pragma: no cover - defensive
            logger.exception("vm_stat sampling raised unexpectedly")

        if sample is not None:
            total = int(vm.total)
            # Activity Monitor semantics: "Memory Used" =
            #   anonymous (the "App Memory" analog)
            # + wired (kernel-locked)
            # + compressed (pages stored by the compressor)
            used = sample.anonymous + sample.wired + sample.compressed
            # "Available" in the Activity Monitor sense is the reclaimable
            # chunk: free pages plus file-backed and speculative caches
            # plus purgeable. swap-backed anonymous pages are NOT
            # reclaimable without paging, so they stay on the "used" side.
            available = (
                sample.free
                + sample.file_backed
                + sample.speculative
                + sample.purgeable
            )
            percent = (used / total * 100.0) if total > 0 else 0.0
            cached_files = sample.file_backed + sample.speculative
            return MemoryStats(
                total_bytes=total,
                used_bytes=int(used),
                available_bytes=int(available),
                percent=float(percent),
                swap_used_bytes=int(sw.used),
                swap_total_bytes=int(sw.total),
                app_memory_bytes=int(sample.anonymous),
                wired_bytes=int(sample.wired),
                compressed_bytes=int(sample.compressed),
                cached_files_bytes=int(cached_files),
            )

        # Fallback path: non-Darwin dev mode, vm_stat unavailable, parse
        # failure. The new optional fields stay None so clients that know
        # about them can show a degraded view, while legacy clients see
        # the same shape as before.
        return MemoryStats(
            total_bytes=int(vm.total),
            used_bytes=int(vm.used),
            available_bytes=int(vm.available),
            percent=float(vm.percent),
            swap_used_bytes=int(sw.used),
            swap_total_bytes=int(sw.total),
        )

    # ----- Processes -----

    def process_list(
        self,
        limit: int | None = None,
        *,
        include_full_cmdline: bool = False,
    ) -> tuple[list[ProcessInfo], int]:
        # Read the cached snapshot if the background thread has populated
        # it; otherwise take a synchronous sample. The cached list already
        # has non-zero CPU% because the __init__ warm-up plus the
        # background loop both went through the prime-then-sample dance.
        with self._lock:
            cached = self._cached_processes

        if cached is None:
            # Cold path: synchronous snapshot. This call will likely show
            # zero CPU% for every process, as documented in B2. Callers
            # that hit this path are the very first /processes request
            # against a newly-started collector with background=False.
            self._refresh_cpu()
            with self._lock:
                cached = self._cached_processes or []

        results: list[ProcessInfo] = []
        for p in cached:
            if include_full_cmdline:
                cmdline_str = p.cmdline
            else:
                # Security: by default only expose argv[0]. Full argv
                # may contain secrets passed on the command line, e.g.
                # `curl -H "Authorization: Bearer ..."` or
                # `mysql -pPASSWORD`. See test_processes.py for the
                # regression.
                cmdline_str = p.cmdline.split(" ", 1)[0] if p.cmdline else ""
            results.append(p.model_copy(update={"cmdline": cmdline_str}))

        total = len(results)
        # Sort by CPU desc, then memory desc, then pid for stability.
        results.sort(
            key=lambda p: (-p.cpu_percent, -p.memory_rss_bytes, p.pid),
        )
        if limit is not None:
            results = results[: max(0, limit)]
        return results, total

    # ----- Ports -----

    def listening_ports(self) -> list[PortInfo]:
        try:
            conns = psutil.net_connections(kind="inet")
        except (psutil.AccessDenied, PermissionError):
            # On macOS without root, net_connections for other users is
            # restricted -- return whatever we can.
            return []
        return ports_from_connections(conns, resolver=_default_pid_resolver)


def _default_pid_resolver(pid: int | None) -> tuple[str | None, str | None]:
    if pid is None:
        return None, None
    try:
        p = psutil.Process(pid)
        return p.name(), p.username()
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return None, None


def _address_family(addr: str | None) -> str:
    """Return 'v4' or 'v6' from a bind address string.

    Defaults to 'v4' if the address is empty, a wildcard, or fails to
    parse. We classify ``::`` and ``::1`` as v6, and IPv4-mapped IPv6
    (``::ffff:x.y.z.w``) as v4 because the effective listener is v4.
    """
    if not addr:
        return "v4"
    try:
        parsed = ipaddress.ip_address(addr)
    except ValueError:
        return "v4"
    if isinstance(parsed, ipaddress.IPv6Address):
        if parsed.ipv4_mapped is not None:
            return "v4"
        return "v6"
    return "v4"


def ports_from_connections(
    conns,
    *,
    resolver,
    dedupe: bool = True,
) -> list[PortInfo]:
    """Turn a list of psutil-like connections into PortInfo models.

    Split out from :class:`SystemCollector` so it can be unit-tested without
    needing root on macOS (where `net_connections` is gated).

    When ``dedupe`` is True (the default), rows that only differ by
    address family (e.g. sshd bound to both ``0.0.0.0:22`` and ``:::22``)
    collapse into a single row with ``address_families`` recording every
    family that was observed. The canonical row keeps the first-seen
    address. When ``dedupe`` is False, behavior matches the Phase 1/2
    output exactly.
    """
    out: list[PortInfo] = []
    name_cache: dict[int, tuple[str | None, str | None]] = {}

    def resolve_pid(pid: int | None) -> tuple[str | None, str | None]:
        if pid is None:
            return None, None
        if pid in name_cache:
            return name_cache[pid]
        name_cache[pid] = resolver(pid)
        return name_cache[pid]

    for conn in conns:
        laddr = getattr(conn, "laddr", None)
        if not laddr:
            continue
        try:
            addr, port = laddr.ip, laddr.port
        except AttributeError:
            continue
        if not port:
            continue

        # TCP: only LISTEN. UDP: any bound local address counts.
        ctype = getattr(conn, "type", None)
        if ctype == 1:  # SOCK_STREAM
            proto: str = "tcp"
            if conn.status != psutil.CONN_LISTEN:
                continue
        elif ctype == 2:  # SOCK_DGRAM
            proto = "udp"
        else:
            continue

        name, user = resolve_pid(conn.pid)
        out.append(
            PortInfo(
                protocol=proto,  # type: ignore[arg-type]
                address=addr,
                port=int(port),
                pid=conn.pid,
                process_name=name,
                user=user,
            )
        )

    if dedupe:
        out = _dedupe_ports(out)

    out.sort(key=lambda p: (p.protocol, p.port, p.pid or 0))
    return out


def _dedupe_ports(ports: list[PortInfo]) -> list[PortInfo]:
    """Collapse multi-address-family rows into single rows.

    Grouping key: ``(protocol, port, process_name, user, pid)``. All rows
    sharing this key fuse into one canonical row whose ``address_families``
    field lists every family (``v4``, ``v6``) that contributed. Address
    is taken from the first-seen row for determinism.
    """
    # Preserve insertion order so the first row sets the canonical address.
    groups: dict[tuple, list[PortInfo]] = {}
    order: list[tuple] = []
    for p in ports:
        key = (p.protocol, p.port, p.process_name, p.user, p.pid)
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(p)

    out: list[PortInfo] = []
    for key in order:
        rows = groups[key]
        families_seen: list[str] = []
        for row in rows:
            fam = _address_family(row.address)
            if fam not in families_seen:
                families_seen.append(fam)
        canonical = rows[0]
        # Only attach address_families when the group actually contains
        # more than one family; single-family rows keep the pre-Phase-2.5
        # shape (address_families=None) so the CLI renders them unchanged.
        if len(families_seen) > 1:
            out.append(
                canonical.model_copy(update={"address_families": families_seen})
            )
        else:
            out.append(canonical)
    return out


def current_user() -> str:
    try:
        return os.getlogin()
    except OSError:
        return os.environ.get("USER", "unknown")
