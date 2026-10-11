#!/usr/bin/env python3
"""Compare two saved measure-window logs offline; never run a network test."""

import argparse
import ipaddress
import json
import math
import re
from pathlib import Path


COUNTERS = (
    "rx_bytes_delta", "tx_bytes_delta", "total_interface_bytes_delta",
    "tcp_retrans_segs_delta", "tcp_out_segs_delta", "qdisc_dropped_delta",
    "qdisc_overlimits_delta", "qdisc_requeues_delta", "softnet_dropped_delta",
    "softnet_time_squeeze_delta",
)
TEST_FIELDS = ("num_streams", "blksize", "omit", "duration", "bytes", "blocks", "reverse", "tos", "target_bitrate")


def number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"missing or invalid {name}")
    try:
        valid = math.isfinite(value) and value >= 0
    except OverflowError:
        valid = False
    if not valid:
        raise ValueError(f"missing or invalid {name}")
    return value


def route_tuple(value):
    return " ".join(re.sub(r"\bexpires\s+\d+sec\b", "", value).split())


def parse_sample(text):
    offset = text.find("{")
    if offset < 0:
        raise ValueError("missing complete iperf3 JSON")
    try:
        data, end = json.JSONDecoder().raw_decode(text[offset:])
    except json.JSONDecodeError:
        raise ValueError("invalid or truncated iperf3 JSON") from None
    suffix = text[offset + end:]
    if "{" in suffix or "}" in suffix:
        raise ValueError("multiple JSON documents in one measurement window")
    metadata = text[:offset] + suffix

    def field(name, line=False):
        pattern = rf"^{re.escape(name)}=(.+)$" if line else rf"(?:^|[ \t]){re.escape(name)}=([^\s]+)"
        values = re.findall(pattern, metadata, re.M)
        if len(values) != 1 or values[0] in ("<unknown>", "unknown"):
            raise ValueError(f"missing or ambiguous {name}")
        return values[0]

    for name, expected in (("sample_valid", "yes"), ("test_exit_status", "0"),
                           ("route_tuple_unchanged", "yes"), ("tc_topology_unchanged", "yes")):
        if field(name) != expected:
            raise ValueError(f"invalid measurement window: {name}")
    route = route_tuple(field("route_before", line=True))
    if route != route_tuple(field("route_after", line=True)):
        raise ValueError("route changed during measurement")
    if field("tc_topology_before_checksum") != field("tc_topology_after_checksum"):
        raise ValueError("tc topology changed during measurement")
    counters = {}
    for name in COUNTERS:
        raw = field(name)
        if not re.fullmatch(r"\d+", raw):
            raise ValueError(f"invalid/reset counter: {name}")
        counters[name] = int(raw)
    if counters["rx_bytes_delta"] + counters["tx_bytes_delta"] != counters["total_interface_bytes_delta"]:
        raise ValueError("inconsistent interface byte counters")
    if number(int(field("duration_seconds")), "duration_seconds") == 0:
        raise ValueError("empty measurement window")

    try:
        if data.get("error"):
            raise ValueError("iperf3 reported an error")
        start, summary = data["start"], data["end"]
        test = start["test_start"]
        if test["protocol"] != "TCP" or test.get("bidirectional", 0) != 0 or any("bidir" in key for key in summary):
            raise ValueError("only unidirectional TCP iperf3 samples are supported")
        settings = {key: number(test[key], f"test_start.{key}") for key in TEST_FIELDS}
        if settings["reverse"] not in (0, 1) or not all(settings[k] > 0 for k in ("num_streams", "duration", "blksize")):
            raise ValueError("invalid iperf3 test settings")
        if settings["bytes"] or settings["blocks"]:
            raise ValueError("only fixed-duration tests are supported")
        connected = start["connected"]
        if not connected or len(connected) != settings["num_streams"]:
            raise ValueError("missing or inconsistent iperf3 connections")
        endpoints = {(str(ipaddress.ip_address(c["local_host"])), str(ipaddress.ip_address(c["remote_host"])), c["remote_port"]) for c in connected}
        if len(endpoints) != 1:
            raise ValueError("mixed iperf3 endpoints")
        source, peer, port = endpoints.pop()
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError("invalid peer port")
        if str(ipaddress.ip_address(field("route_target"))) != peer:
            raise ValueError("route target differs from iperf3 peer")
        bound_source = field("route_source")
        if bound_source != "<kernel-selected>" and str(ipaddress.ip_address(bound_source)) != source:
            raise ValueError("bound source differs from iperf3 source")
        if not re.search(rf"\bdev\s+{re.escape(field('egress_dev'))}(?:\s|$)", route) or not re.search(rf"\bsrc\s+{re.escape(source)}(?:\s|$)", route):
            raise ValueError("route does not match the measured source/interface")
        received = summary["sum_received"]
        bitrate = number(received["bits_per_second"], "sum_received.bits_per_second")
        seconds = number(received["seconds"], "sum_received.seconds")
        if seconds == 0:
            raise ValueError("empty receiver measurement interval")
        version, timestamp = start["version"], start["timestamp"]["timesecs"]
        if not isinstance(version, str) or not version.strip():
            raise ValueError("missing iperf3 version")
        number(timestamp, "timestamp.timesecs")
    except (KeyError, TypeError, AttributeError):
        raise ValueError("incomplete iperf3 TCP evidence") from None

    return {
        "identity": {"host_id": field("host_id"), "peer": peer, "peer_port": port,
                     "source": source, "ip_family": ipaddress.ip_address(peer).version,
                     "egress_dev": field("egress_dev"), "route": route, "protocol": "TCP",
                     "direction": "receive" if settings["reverse"] else "send",
                     "iperf3_version": version, **settings},
        "timestamp": timestamp, "receiver_seconds": seconds,
        "receiver_bits_per_second": bitrate, "counters": counters,
    }


def compare(before, after):
    samples, reasons = [], []
    for label, text in (("before", before), ("after", after)):
        try:
            samples.append(parse_sample(text))
        except ValueError as exc:
            reasons.append(f"{label}: {exc}")
    if reasons:
        return {"comparable": False, "reasons": reasons}
    before, after = samples
    for key, value in before["identity"].items():
        if value != after["identity"][key]:
            reasons.append(f"mismatched {key}")
    if after["timestamp"] <= before["timestamp"]:
        reasons.append("after timestamp must be later than before timestamp")
    if reasons:
        return {"comparable": False, "reasons": reasons}
    old, new = before["receiver_bits_per_second"], after["receiver_bits_per_second"]
    percent = (new - old) / old * 100 if old else None
    if percent is not None and not math.isfinite(percent):
        return {"comparable": False, "reasons": ["percentage exceeds finite numeric range"]}
    return {
        "comparable": True, "identity": before["identity"],
        "before_timestamp": before["timestamp"], "after_timestamp": after["timestamp"],
        "sample_gap_seconds": after["timestamp"] - before["timestamp"],
        "receiver_seconds": {"before": before["receiver_seconds"], "after": after["receiver_seconds"]},
        "receiver_throughput": {"unit": "bits_per_second", "before": old, "after": new,
                                "delta": new - old, "change_percent": percent},
        "host_counter_deltas": {name: {"before": before["counters"][name], "after": after["counters"][name]} for name in COUNTERS},
        "notes": ["Observed difference only; this does not establish tuning causality or long-term performance.",
                  "host_id is the captured hostname, not independently verified hardware identity.",
                  "Interface and host counters include unrelated traffic; retransmits are not a measured loss percentage.",
                  "A zero baseline has no defined percentage change."],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    args = parser.parse_args()
    try:
        report = compare(args.before.read_text(encoding="utf-8"), args.after.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as exc:
        parser.error(str(exc))
    print(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False))
    return 0 if report["comparable"] else 3


if __name__ == "__main__":
    raise SystemExit(main())
