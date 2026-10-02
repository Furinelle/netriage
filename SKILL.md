---
name: netriage
description: Diagnose Linux VPS throughput, latency, loss, and TCP/network tuning over SSH; derive changes from the workload and measured path.
---

# netriage

Diagnose the actual traffic path and change only settings supported by measurements. Do not copy MTU, shaping, buffer, or one-click BBR values from unrelated hosts.

## Boundaries

- Before remote inspection, testing, or a concrete tuning recommendation, establish target identity, role (落地/线路/中转), and advertised bandwidth. Reuse session facts; ask only for missing information needed next.
- Reuse existing authorization within its scope. Inspection or testing alone does not authorize persistent changes. Present exact proposed changes and obtain approval when application is not already authorized.
- Budget traffic before throughput tests or sweeps. Temporary qdisc replacement requires full topology capture, serialized execution, cleanup, and provable exact restoration; skip it if restoration is unknown.
- Before live changes, preserve affected files, units, rules, and values. Verify the real service path and read back live state after applying; roll back regressions.

## Read only the relevant procedure

- Before remote inspection, testing, recommendations, or changes, read [operations.md](references/operations.md) for identity, approval, measurement, tuning, and acceptance requirements. Conceptual questions need only the relevant section.
- When interpreting slow transfers, buffer pressure, loaded latency, CPU/queue limits, or advice from a tuning blog, read [current-evidence.md](references/current-evidence.md). It distinguishes kernel semantics and reproducible evidence from workload-specific settings.
- For detailed command patterns, consult [blog-method.md](references/blog-method.md).
- For `Madhatter2099/TCP-Optimize`, IPv4 priority, conntrack, RPS/RFS, UDP buffers, MSS, or its workload profiles, consult [tcp-optimize-review.md](references/tcp-optimize-review.md).
- For `Eric86777/vps-tcp-tune`, XanMod/BBRv3 menu chains, or Realm extras, consult [vps-tcp-tune-review.md](references/vps-tcp-tune-review.md).
- For `Kylin010/tcpfit`, BDP-derived candidates, automatic bandwidth probes, or policer sweeps, consult [tcpfit-review.md](references/tcpfit-review.md) before running it. The 2026-10-02 review pins v0.5.9; its traffic/time guards do not replace a per-run budget or exact qdisc restoration. Follow its checksum and telemetry opt-out constraints.

## Reuse the bundled tools

`scripts/inspect.sh` collects read-only state; `pmtu-probe.sh` probes PMTU; `measure-window.sh` captures route-bound counter deltas; `derive-candidates.py` computes workload/page-size/concurrency-aware candidates and traffic estimates; `backup-snapshot.sh` preserves the immediate pre-change state. Use the recommendation and profile templates when useful.

Do not silently wrap or run third-party installers. Pin and inspect their side effects first. TCP test results do not establish UDP/QUIC performance; validate the actual protocol and durable business path.
