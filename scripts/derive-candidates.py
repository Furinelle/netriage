#!/usr/bin/env python3
"""Derive auditable TCP buffer candidates without changing the host.

The output is deliberately a candidate calculation, not an apply script.  It
combines BDP, RAM and role, and can estimate the payload volume of a linear
policer sweep before the user approves that test.
"""

from __future__ import annotations

import argparse
import json
import os
from dataclasses import asdict, dataclass

MIB = 1024 * 1024
GIB = 1024 * MIB


def positive_float(value: str) -> float:
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def current_page_size() -> int:
    try:
        return os.sysconf("SC_PAGE_SIZE")
    except (ValueError, OSError):
        return 4096


@dataclass(frozen=True)
class CandidateReport:
    bandwidth_mbps: float
    rtt_ms: float
    ram_mib: int
    role: str
    page_size_bytes: int
    bdp_bytes: int
    bdp_mib: float
    two_x_bdp_bytes: int
    ram_per_socket_cap_bytes: int
    socket_max_candidate_bytes: int
    socket_max_limiting_factor: str
    socket_default_candidate_bytes: int
    tcp_mem_candidate_pages: tuple[int, int, int]
    tcp_mem_candidate_mib: tuple[float, float, float]
    sweep_step_count: int | None
    sweep_payload_estimate_gib: float | None
    notes: tuple[str, ...]


def derive(args: argparse.Namespace) -> CandidateReport:
    bdp = round(args.bandwidth_mbps * 1_000_000 / 8 * (args.rtt_ms / 1000))
    two_x_bdp = bdp * 2

    # tcpfit v0.3.8 uses RAM/32 as a per-socket concurrency cap and 256 MiB as
    # an absolute cap.  Keep it as an auditable candidate, not a universal rule.
    ram_cap = min(args.ram_mib * MIB // 32, 256 * MIB)
    floor = min(4 * MIB, ram_cap)
    socket_max = max(floor, min(two_x_bdp, ram_cap))
    if socket_max == floor and two_x_bdp < floor:
        limiting_factor = "minimum_floor"
    elif two_x_bdp <= ram_cap:
        limiting_factor = "two_x_bdp"
    elif args.ram_mib * MIB // 32 <= 256 * MIB:
        limiting_factor = "ram_div_32_concurrency_cap"
    else:
        limiting_factor = "absolute_256_mib_cap"

    if args.role == "proxy":
        socket_default = 1 * MIB
    elif args.role == "bulk":
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
        rates = list(range(args.sweep_from, args.sweep_to + 1, args.sweep_step))
        sweep_step_count = len(rates)
        # Aggregate rate is the shaper rate; stream count does not multiply it.
        payload_bytes = (
            sum(rates) * 1_000_000 / 8 * args.sweep_duration * args.sweep_repeats
        )
        sweep_gib = round(payload_bytes / GIB, 3)

    return CandidateReport(
        bandwidth_mbps=args.bandwidth_mbps,
        rtt_ms=args.rtt_ms,
        ram_mib=args.ram_mib,
        role=args.role,
        page_size_bytes=args.page_size,
        bdp_bytes=bdp,
        bdp_mib=round(bdp / MIB, 2),
        two_x_bdp_bytes=two_x_bdp,
        ram_per_socket_cap_bytes=ram_cap,
        socket_max_candidate_bytes=socket_max,
        socket_max_limiting_factor=limiting_factor,
        socket_default_candidate_bytes=socket_default,
        tcp_mem_candidate_pages=tcp_mem_pages,
        tcp_mem_candidate_mib=tcp_mem_mib,
        sweep_step_count=sweep_step_count,
        sweep_payload_estimate_gib=sweep_gib,
        notes=(
            "Candidate math only; validate against real traffic, concurrency and memory pressure.",
            "tcp_mem values are pages; pass the target host page size when it is not 4096 bytes.",
            "Sweep estimate is payload only and excludes retries, protocol overhead, baseline and verification runs.",
        ),
    )


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--bandwidth-mbps", type=positive_float, required=True)
    p.add_argument("--rtt-ms", type=positive_float, required=True)
    p.add_argument("--ram-mib", type=positive_int, required=True)
    p.add_argument("--role", choices=("proxy", "bulk", "mixed"), required=True)
    p.add_argument("--page-size", type=positive_int, default=current_page_size())
    p.add_argument("--sweep-from", type=positive_int)
    p.add_argument("--sweep-to", type=positive_int)
    p.add_argument("--sweep-step", type=positive_int)
    p.add_argument("--sweep-duration", type=positive_int, default=12)
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
