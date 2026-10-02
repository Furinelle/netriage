#!/usr/bin/env python3
"""Derive auditable TCP buffer candidates without changing the host.

The output is deliberately a candidate calculation, not an apply script.  It
combines BDP, RAM and role, and can estimate the payload volume of a linear
policer sweep before the user approves that test.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import asdict, dataclass

MIB = 1024 * 1024
GIB = 1024 * MIB
MAX_BDP_BYTES = 2**63 - 1


def positive_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be a finite number greater than zero")
    return parsed


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def nonnegative_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be zero or greater")
    return parsed


@dataclass(frozen=True)
class CandidateReport:
    bandwidth_mbps: float
    rtt_ms: float
    ram_mib: int
    concurrency: int
    workload: str
    page_size_bytes: int
    bdp_bytes: int
    bdp_mib: float
    two_x_bdp_bytes: int
    tcpfit_v0_5_7_competing_candidate_bytes: int
    ram_quarter_budget_bytes: int
    ram_quarter_budget_per_socket_bytes: int
    ram_per_socket_cap_bytes: int
    socket_max_candidate_bytes: int
    socket_max_limiting_factor: str
    socket_default_candidate_bytes: int
    tcp_mem_candidate_pages: tuple[int, int, int]
    tcp_mem_candidate_mib: tuple[float, float, float]
    sweep_step_count: int | None
    sweep_omit_seconds: int
    sweep_payload_estimate_gib: float | None
    notes: tuple[str, ...]


def derive(args: argparse.Namespace) -> CandidateReport:
    bdp_float = args.bandwidth_mbps * 1_000_000 / 8 * (args.rtt_ms / 1000)
    if not math.isfinite(bdp_float) or bdp_float > MAX_BDP_BYTES:
        raise ValueError("bandwidth and RTT produce an unsupported BDP")
    bdp = round(bdp_float)
    two_x_bdp = bdp * 2
    tcpfit_competing_candidate = two_x_bdp + 2 * MIB

    # An explicit RAM/4 total budget divided across expected concurrent large
    # sockets preserves the former RAM/32 assumption when concurrency is eight.
    ram_quarter_budget = args.ram_mib * MIB // 4
    ram_quarter_budget_per_socket = ram_quarter_budget // args.concurrency
    if ram_quarter_budget_per_socket < 1:
        raise ValueError("RAM/4 divided by concurrency must be at least one byte")
    ram_cap = min(ram_quarter_budget_per_socket, 256 * MIB)
    floor = min(4 * MIB, ram_cap)
    socket_max = max(floor, min(two_x_bdp, ram_cap))
    if socket_max == floor and two_x_bdp < floor:
        limiting_factor = "minimum_floor"
    elif two_x_bdp <= ram_cap:
        limiting_factor = "two_x_bdp"
    elif ram_quarter_budget_per_socket <= 256 * MIB:
        limiting_factor = "ram_quarter_budget_divided_by_concurrency_cap"
    else:
        limiting_factor = "absolute_256_mib_cap"

    if args.workload == "proxy":
        socket_default = 1 * MIB
    elif args.workload == "bulk":
        socket_default = max(1 * MIB, min(bdp, 8 * MIB))
    else:
        socket_default = 2 * MIB
    socket_default = min(socket_default, socket_max)

    total_pages = args.ram_mib * MIB // args.page_size
    tcp_mem_pages = (
        total_pages // 16,
        total_pages // 8,
        total_pages // 4,
    )
    tcp_mem_mib = tuple(
        round(pages * args.page_size / MIB, 2) for pages in tcp_mem_pages
    )

    sweep_gib = None
    sweep_step_count = None
    sweep_values = (args.sweep_from, args.sweep_to, args.sweep_step)
    if any(value is not None for value in sweep_values):
        if not all(value is not None for value in sweep_values):
            raise ValueError(
                "--sweep-from, --sweep-to and --sweep-step must be supplied together"
            )
        if args.sweep_to < args.sweep_from:
            raise ValueError("--sweep-to must be greater than or equal to --sweep-from")
        if (args.sweep_to - args.sweep_from) % args.sweep_step:
            raise ValueError("sweep range must be evenly divisible by --sweep-step")
        sweep_step_count = (args.sweep_to - args.sweep_from) // args.sweep_step + 1
        # Aggregate rate is the shaper rate; stream count does not multiply it.
        sweep_rate_sum = sweep_step_count * (args.sweep_from + args.sweep_to) // 2
        payload_bytes = (
            sweep_rate_sum
            * 1_000_000
            // 8
            * (args.sweep_duration + args.sweep_omit)
            * args.sweep_repeats
        )
        sweep_gib = round(payload_bytes / GIB, 3)

    return CandidateReport(
        bandwidth_mbps=args.bandwidth_mbps,
        rtt_ms=args.rtt_ms,
        ram_mib=args.ram_mib,
        concurrency=args.concurrency,
        workload=args.workload,
        page_size_bytes=args.page_size,
        bdp_bytes=bdp,
        bdp_mib=round(bdp / MIB, 2),
        two_x_bdp_bytes=two_x_bdp,
        tcpfit_v0_5_7_competing_candidate_bytes=tcpfit_competing_candidate,
        ram_quarter_budget_bytes=ram_quarter_budget,
        ram_quarter_budget_per_socket_bytes=ram_quarter_budget_per_socket,
        ram_per_socket_cap_bytes=ram_cap,
        socket_max_candidate_bytes=socket_max,
        socket_max_limiting_factor=limiting_factor,
        socket_default_candidate_bytes=socket_default,
        tcp_mem_candidate_pages=tcp_mem_pages,
        tcp_mem_candidate_mib=tcp_mem_mib,
        sweep_step_count=sweep_step_count,
        sweep_omit_seconds=args.sweep_omit,
        sweep_payload_estimate_gib=sweep_gib,
        notes=(
            "Candidate math only; validate against real traffic, concurrency and memory pressure.",
            "tcp_mem values are pages; --page-size must come from the target host.",
            "The legacy tcpfit_v0_5_7 key also represents v0.5.9's unchanged 2xBDP+2MiB candidate, not the netriage selection.",
            "RAM/4 and workload defaults are heuristics; allow for send/receive memory, proxy legs, cgroups and other services.",
            "Sweep estimate includes configured warm-up at the aggregate shaper rate; it excludes extra retries, protocol overhead, baseline and verification runs. It does not enforce a quota.",
        ),
    )


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--bandwidth-mbps", type=positive_float, required=True)
    p.add_argument("--rtt-ms", type=positive_float, required=True)
    p.add_argument("--ram-mib", type=positive_int, required=True)
    p.add_argument("--concurrency", type=positive_int, required=True)
    p.add_argument(
        "--workload",
        "--role",
        dest="workload",
        choices=("proxy", "bulk", "mixed"),
        required=True,
        metavar="WORKLOAD",
        help="socket workload class, not the landing/line/relay host role",
    )
    p.add_argument("--page-size", type=positive_int, required=True)
    p.add_argument("--sweep-from", type=positive_int)
    p.add_argument("--sweep-to", type=positive_int)
    p.add_argument("--sweep-step", type=positive_int)
    p.add_argument("--sweep-duration", type=positive_int, default=12)
    p.add_argument(
        "--sweep-omit", type=nonnegative_int, default=0,
        help="iperf3 -O warm-up seconds per run; included in traffic cost",
    )
    p.add_argument("--sweep-repeats", type=positive_int, default=1)
    return p


def main() -> int:
    p = parser()
    args = p.parse_args()
    try:
        report = derive(args)
    except ValueError as exc:
        p.error(str(exc))
    print(json.dumps(asdict(report), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
