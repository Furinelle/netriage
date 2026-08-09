# tcpfit v0.3.8 Review Notes

Reviewed source: [`Kylin010/tcpfit`](https://github.com/Kylin010/tcpfit), release
[`v0.3.8`](https://github.com/Kylin010/tcpfit/releases/tag/v0.3.8), commit
[`5671da0`](https://github.com/Kylin010/tcpfit/tree/5671da0a01814997216903c3ac6825a1512bf4da),
2026-08-09. The upstream project is MIT-licensed. This review extracts workflow
ideas; netriage does not vendor or auto-run the upstream program.

## Table of contents

- [What the tool does](#what-the-tool-does)
- [Ideas worth reusing](#ideas-worth-reusing)
- [Candidate math](#candidate-math)
- [Policer-knee experiment](#policer-knee-experiment)
- [qdisc safety](#qdisc-safety)
- [Keep behind evidence gates](#keep-behind-evidence-gates)
- [Agent integration checklist](#agent-integration-checklist)

## What the tool does

`tcpfit.sh` is a single-host Bash tuner. It profiles the machine, derives TCP
buffer candidates from bandwidth × RTT and RAM, can temporarily sweep HTB + fq
rates against an iperf3 peer to look for a provider policer knee, writes a
sysctl drop-in and qdisc service, verifies, and offers rollback. The repository
also contains a fleet orchestrator, but upstream labels multi-host mode as not
validated in real environments.

Treat it as a useful experiment design, not as a universal configuration. Its
target problem (a VPS port policer measured against a nearby fast peer) differs
from an international business path, a relay chain, and UDP/QUIC traffic.

## Ideas worth reusing

1. **Derive, then label the limiting condition.** Show BDP, the 2×BDP target,
   the RAM/concurrency cap, and which condition selected the candidate. Do not
   output a magic buffer number without provenance.
2. **Separate maxima from defaults.** Socket ceilings do not reserve that memory
   up front, while large `rmem_default`/`wmem_default` values affect every new
   socket. Keep high-concurrency proxy defaults smaller than bulk-transfer
   defaults.
3. **Estimate test traffic before running it.** A multi-step sweep at hundreds
   of Mbit/s can use many GiB. Include retries, the unshaped baseline, reverse
   tests, and post-apply verification when requesting the user's test budget.
4. **Use different peers for different questions.** A nearby, higher-capacity
   peer can probe a VPS port/policer; durable peers on the real business path
   determine lasting end-to-end tuning. Never substitute one for the other.
5. **No observed knee means no shaper.** If the measured range stays clean,
   report that no knee was observed against this peer/time and leave the global
   cap off. Never turn the top of the scan range into a cap.
6. **Repeat suspected spikes.** Pause between steps and require repeatability;
   one public iperf result can reflect a busy peer. Coarse scan first, refine
   only around a reproducible transition.
7. **Test the topology you may deploy.** `fq maxrate` is per-flow rather than an
   aggregate host cap. Aggregate egress experiments need a classful shaper such
   as HTB with an fq leaf, and the experimental/final structures must match.
8. **Validate before mutation and serialize disruptive tests.** Parse numeric
   inputs before taking a snapshot or changing qdisc. Use a per-host lock so two
   agents do not simultaneously replace qdisc or sysctl.
9. **Make temporary changes self-cleaning.** Install traps before the first
   qdisc/firewall mutation and verify cleanup after normal exit, failure, and
   interruption.
10. **Keep mutation and rollback inventories coupled.** Every newly written
    sysctl key, file, unit, route property, firewall rule, swap file, and qdisc
    object must have a captured pre-run state and an exact restore action.

## Candidate math

Use the target business-path RTT for endpoint buffers, not a generic country
ping target:

```text
BDP_bytes = bandwidth_Mbps × RTT_ms × 125
```

tcpfit v0.3.8 proposes this auditable ceiling candidate:

```text
target       = 2 × BDP
RAM cap      = min(RAM_bytes / 32, 256 MiB)
floor        = min(4 MiB, RAM cap)
socket max   = max(floor, min(target, RAM cap))
```

This encodes an assumption that at least eight large sockets should fit within
a global TCP budget of about RAM/4. It is a **candidate**, not a proof. Tighten
it when concurrency, cgroup limits, low free memory, UDP-heavy services, or OOM
history demand more headroom. Values above it require explicit evidence.

The upstream role starting points are also candidates:

| Role | Per-socket default candidate |
| --- | --- |
| high-concurrency proxy | 1 MiB |
| mixed | 2 MiB |
| few bulk flows | clamp(BDP, 1 MiB, 8 MiB) |

Do not write `tcp_mem` merely because the formula can produce it. If pressure
evidence supports changing it, remember all three values are **pages**, obtain
the target page size with `getconf PAGE_SIZE`, and report both pages and bytes.
The upstream display assumes 4 KiB pages, which is not portable.

For reproducible arithmetic without touching a host:

```bash
python3 scripts/derive-candidates.py \
  --bandwidth-mbps 500 --rtt-ms 150 --ram-mib 1024 --role proxy \
  --page-size 4096 \
  --sweep-from 450 --sweep-to 600 --sweep-step 25 \
  --sweep-duration 12 --sweep-repeats 3
```

Treat the sweep payload estimate as a lower bound: it excludes retries,
protocol overhead, the baseline probe, reverse tests, and verification.

## Policer-knee experiment

Run this only when shaping is within the permission boundary and all of these
preconditions hold:

- the question is specifically the local VPS port/provider policer, not merely
  a weak international path;
- the peer is nearby, idle enough, and demonstrably faster than the target;
- the traffic quota and test window were disclosed and approved;
- the egress interface and direction are confirmed;
- the original qdisc can be recreated exactly;
- an interruption trap and explicit cleanup verification are in place.

Suggested evidence sequence:

1. Save full text and JSON (when supported) for root qdisc, classes, and filters;
   record qdisc/TCP counters and interface byte counters.
2. At a deliberately sub-cap paced rate, verify that the peer/path can sustain
   the requested rate without a counter spike. If it cannot, stop: that peer
   cannot identify the target host's policer.
3. Run an unshaped or known-baseline single-flow test, then P4 and reverse tests
   for context. Repeat at another time if the peer is public or variable.
4. A clean baseline means only “no policer observed with this peer/time.” Stop
   rather than inventing a cap.
5. If the baseline repeatedly shows a sharp retransmission/counter increase,
   scan around the measured goodput. A knee can sit above unpaced goodput because
   pacing avoids microbursts into the provider policer.
6. Use coarse steps, wait between steps, and repeat a suspected spike at least
   twice. Refine only the interval between the last clean step and first
   reproducibly bad step.
7. Compare iperf3 JSON retransmits, goodput, RTT/cwnd, `tc -s` deltas, TCP MIB
   deltas, and application-critical behavior. A retransmission-derived “loss
   percent” is a heuristic, not observed packet loss.
8. If a stable knee exists, test a small ladder below it across peak/off-peak
   windows and, when available, a second capable peer. Select the highest cap
   that reduces the bad evidence without hurting healthy peers or the critical
   direction. Otherwise remove the shaper.
9. Restore the exact pre-test qdisc and verify it, even when no recommendation is
   produced.

Do not universalize tcpfit's `0.1%` threshold, 1448-byte packet estimate, fixed
margin tiers, 12-second duration, or `0.95×goodput → 1.25×goodput` range. TSO/GSO,
MSS, parallel flows, peer load, and path behavior change the meaning of those
numbers.

## qdisc safety

The upstream `qdisc_save` records only the qdisc **kind**. Re-adding `htb`,
`cake`, `fq`, or `fq_codel` by kind does not reconstruct handles, classes,
filters, limits, or custom options. In particular, an empty restored HTB root is
not the prior topology.

There is an additional v0.3.8 state bug in automatic sweep mode: the initial
unshaped probe calls `qdisc_restore()`, which clears the saved interface; later
scan steps install temporary HTB again, but the final restore sees no saved
interface and can no-op. Standalone sweep, peer-too-slow, and no-knee exits may
therefore leave the last temporary test shaper active. The snapshot also stores
route/qdisc only as comments, while rollback reconstructs only a simplified
default route and sysctl values. **Do not run v0.3.8 auto-sweep on a production
host or treat its qdisc/route snapshot as executable rollback.**

The automatic bandwidth probe also replaces the root qdisc with `fq`; the tune
path can call it without the custom-qdisc guard. Treat that probe as a
disruptive qdisc experiment, not a read-only bandwidth check.

Therefore:

- do not replace a custom/classful root qdisc unless an exact owned script/unit
  or tested restore procedure exists;
- `tc -j -s qdisc/class/filter` is valuable evidence but not a generic import
  format; keep the authoritative config/owner too;
- if the host's qdisc is owned by NetworkManager, systemd-networkd, a provider
  agent, CAKE, qos-agent, or another service, use that owner for restore;
- verify root, classes, filters, service state, and critical traffic after
  restoration;
- never describe a “restore by qdisc kind” as exact rollback.

HTB + fq can be a good candidate for a confirmed aggregate policer, but do not
copy `quantum 1514`, `burst 32k`, `flow_limit 8192`, or large queue limits to
every rate/NIC. Derive quantum/burst from rate and MTU, inspect `tc` warnings,
measure latency/backlog/drops, and use the smallest queue that meets the workload.

## Keep behind evidence gates

- Generic “RTT to a country” targets: anycast and routing can understate the real
  path. Measure representative service/durable peers and record median/tail RTT.
- Automatic writes of all upstream sysctls: backlog, budgets, TFO, FIN/keepalive,
  local port range, `vm.min_free_kbytes`, `fs.file-max`, and initcwnd/initrwnd
  need separate role and pressure evidence.
- Automatic BBR module loading or silent Cubic fallback: recommend the actual
  available congestion control and test it; do not persist a fallback merely
  because the requested module is absent.
- Automatic swap creation: OOM history and low RAM matter, but swap sizing,
  storage cost, cgroup limits, and service latency remain a separate decision.
- Global shaping from one direction or peer: validate both directions and every
  healthy production path that shares the egress root.
- Public iperf port rotation: use only endpoints whose policy permits testing;
  a busy/refused port is not evidence about the target host.
- Self-install/update or `curl | bash`: pin a release, verify checksums, inspect
  side effects, and get approval before running upstream code.
- Fleet mode: upstream marks it unvalidated; netriage keeps peer tests serial and
  verifies each host independently.

## Agent integration checklist

When tcpfit is mentioned or a policer-knee/BDP-derived plan is requested:

1. Read this reference and the core workflow in `SKILL.md`.
2. Collect `test_budget_gb`, quota/billing window, peak/off-peak constraints, and
   whether temporary qdisc replacement is allowed.
3. Run `scripts/derive-candidates.py` for transparent math; paste relevant input
   and output into the recommendation/profile.
4. Label the nearby capacity peer and durable business-path peers separately.
5. Refuse destructive qdisc experimentation when exact restoration is unknown;
   use read-only observation and a proposed maintenance-window procedure instead.
6. Preserve the recommendation-before-application gate. Upstream “auto-tune” is
   not implicit approval to mutate a live host.
7. Report “no knee observed” rather than “no policer exists,” because the result
   is peer-, direction-, load-, and time-specific.
