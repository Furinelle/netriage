# tcpfit Review Notes (v0.5.9)

Reviewed 2026-10-02: upstream latest release is
[`v0.5.9`](https://github.com/Kylin010/tcpfit/releases/tag/v0.5.9), commit
[`38fbf5a`](https://github.com/Kylin010/tcpfit/tree/38fbf5af30daf87735f2ffbc5e0905033ee2b86e),
released 2026-10-01 UTC. This is a **static source review**, including the diff
from v0.5.7, not a production-host test or a claim of verified restoration.
Upstream test reports are upstream evidence, not netriage acceptance results.
The project is MIT-licensed; netriage extracts workflow ideas and does not
vendor or auto-run the program.

If the user explicitly requires upstream tcpfit, use this reviewed pin rather
than `main`, an unreviewed newer release, or the self-update path:

```text
tag      v0.5.9
commit   38fbf5af30daf87735f2ffbc5e0905033ee2b86e
sha256   8331cc40950229a3280ce32406330a85b1a3d21ba398a4db3dc7e25c39783741  tcpfit.sh
```

The locally calculated script hash matches the
[pinned upstream SHA256SUMS](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/SHA256SUMS).
This pins the reviewed content; a checksum in the same repository is not an
independent signature. Inspect installation/update side effects separately.

## What changed since v0.5.7

- **Traffic and stopping:** v0.5.9 bounds refinement to at most eight interior
  points, recalculates scan traffic from the measured range, and adds default-no
  confirmation for large/manual-range scans and material estimate increases.
  Refusing the scan now skips subsequent full-speed wizard verification. The
  interactive menu exits without a controlling terminal, before self-install
  and telemetry. These are useful guards, not a hard byte budget.
  [Scan guards](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L3070-L3141),
  [refinement](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L3222-L3245),
  [menu gate](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L4374-L4396).
- **Sample quality:** clean but weak baseline/aggregate results become
  `INCONCLUSIVE`; failed/skipped scan points no longer prove complete coverage.
  Clean, sufficiently strong eight-flow corroboration no longer drives shaping
  from the lossy single-flow rate. Results remain peer/time/direction specific.
  [Aggregate and baseline decisions](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2930-L3039),
  [coverage](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L3263-L3296).
- **Routes and persistence:** v0.5.8 fixes default routes without `via` and adds
  a PPP reconnect hook. v0.5.9 selects the test NIC using the resolved peer
  route, preserves current route tokens when changing/restoring windows, and
  adds networkd DHCP drop-ins, an active dispatcher check, and a systemd
  fallback. Updating the script alone does not install these new persistence
  artifacts. Do not rerun broad tuning just to upgrade without an approved
  candidate configuration.
  [Route selection](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L448-L572),
  [persistence selection](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2297-L2327).
- **Failure handling:** snapshot/sysctl writes now use checked temporary files
  and atomic rename; several apply/verify failures now propagate instead of
  reporting success. `netdev_budget_usecs=4000` is no longer written; the key
  remains in rollback inventory for older installations. These fixes do not
  make the full run transactional or reconstruct custom qdisc state.
  [Snapshot](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L1082-L1109),
  [sysctl writes](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L1739-L1855).

Historical context: v0.3.8 could clear its saved qdisc interface after the
baseline probe and leave temporary HTB active on later exits; v0.5.4 fixed that
path. v0.5.5+ adds mq handling and the `2×BDP+2MiB` candidate. v0.5.7 adds
archives, a 10 Gbit/s default scan ceiling, and opt-out menu telemetry. These
older fixes should not be repeated as current defects.

## What the tool does and what to reuse

`tcpfit.sh` is a single-host Bash tuner: machine profile, BDP/RAM-derived
buffers, optional temporary HTB + fq policer sweep, persistent sysctl/qdisc and
route-window changes, verification, archives and rollback. Its
[pinned README](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/README.md#L93-L108)
still marks fleet mode as unvalidated in real environments.

Useful ideas for netriage:

1. Show BDP, target buffer, memory/concurrency cap, and the binding limit.
2. Separate socket defaults from maxima; use workload and pressure evidence.
3. Estimate all test phases and retries before spending the approved quota.
4. Label the nearby capacity peer separately from durable business-path peers.
5. A clean or inconclusive scan supplies no new shaper recommendation; preserve
   an existing owned configuration unless removal has sufficient evidence.
6. Repeat suspected spikes, use coarse scans first, and refine a bounded range.
7. Test the final topology: `fq maxrate` is per-flow; HTB with an fq leaf can
   supply an aggregate egress cap.
8. Validate inputs, serialize mutations, install cleanup before mutation, and
   capture a restore action for every affected file/unit/route/rule/qdisc.

A nearby peer probes a local VPS port/provider policer. It does not establish
international business-path performance, relay-chain behavior, or UDP/QUIC
acceptance.

## Candidate math and remaining limits

Use representative business-path RTT for endpoint buffers:

```text
BDP_bytes = bandwidth_Mbps × RTT_ms × 125

# tcpfit v0.5.9, with RAM in bytes:
target       = 2 × BDP + 2 MiB
RAM cap      = min(RAM_bytes / 32, 256 MiB)
socket max   = max(4 MiB, min(target, RAM cap))
```

The upstream floor is applied **after** the RAM cap, so below 128 MiB RAM it
can exceed that cap. Netriage's `floor=min(4 MiB, cap)` preserves its cap. Keep
`2×BDP` and `2×BDP+2MiB` as competing candidates rather than promises of optimal
throughput. Upstream assumes roughly eight large sockets within a RAM/4 TCP
budget; it does not take actual expected concurrency or cgroup headroom as an
input. Socket ceilings are not preallocation, but this is not an OOM guarantee
or a budget for every kind of socket/application memory.
[Upstream buffer math](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L708-L763).

| Workload | Upstream default candidate |
| --- | --- |
| high-concurrency proxy | 1 MiB |
| mixed | 2 MiB |
| few bulk flows | clamp(BDP, 1 MiB, 8 MiB) |

Upstream still defaults RTT to 150 ms. `tune --rtt` overrides it; the wizard
uses the default. Use measured median/tail RTT, free memory, concurrency and
pressure evidence instead. `tcp_mem` is in **pages**: upstream hardcodes
4 KiB in both its calculation and display, not just its display. Obtain the
target page size with `getconf PAGE_SIZE`, show pages and bytes, and do not write
`tcp_mem` solely because a formula produces a candidate.
[RTT default](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L653),
[page assumption](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L712-L721).

For arithmetic without touching a host:

```bash
python3 scripts/derive-candidates.py \
  --bandwidth-mbps 500 --rtt-ms 150 --ram-mib 1024 --concurrency 8 --workload proxy \
  --page-size 4096
```

This example computes buffers only and sends no traffic. Add sweep inputs only
when a specific scan is justified; do not treat the calculator's defaults as
a prescribed scan duration or test plan. The helper includes the configured warm-up at the aggregate shaper rate. Its
payload estimate excludes baseline, reverse tests, verification, extra retries
and protocol overhead, and does not enforce a quota.

## Traffic budget and stopping

The v0.5.9 confirmation threshold is **50 GB as labelled by upstream**, not a
user-configured maximum. Automatic sweep asks when measured goodput exceeds
stated bandwidth by 3×; in the wizard it also asks when estimated scan traffic
exceeds the agreed estimate by 1.5× **and** exceeds 50 GB. Without an agreed
estimate, automatic/manual-range scans ask above 50 GB. `--yes` bypasses those
scan confirmations. Do not use it as a default for netriage.

Important boundaries:

- Automatic sweep sends its unshaped test, retries and any extra/aggregate
  probes **before** the scan-volume confirmation. Standalone `probe`, `verify`
  and `tune --bw auto` do not inherit a hard quota gate.
- The wizard estimate assumes nominal-rate phases and three fine points; the
  scan estimate reserves eight fine points but is still not a conservative
  total: retries, spike repeats, lower-rate controls, port attempts and other
  phases can add traffic. Neither estimate stops at a measured byte ceiling.
- Refusal stops further scan/verification, not already sent bytes. In the
  auto-bandwidth wizard, refusal can still be followed by base tuning; it is
  not cancellation/rollback of every change.
- Signal handlers attempt to reap iperf children and restore qdisc, but there
  is no general `EXIT` cleanup or proof of exact recovery. Do not infer safe
  restoration from an interrupt or a printed `qdisc restored` message.
  [Probe and subprocess handling](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2570-L2657),
  [wizard refusal](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L4091-L4126),
  [cancelled verification](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L4261-L4274).

Netriage leaves automatic full-speed probes and sweeps off by default. First
use passive evidence or a paced critical-path pilot as described in
[current-evidence.md](current-evidence.md). Escalate only for an unresolved
policer question; scan the narrowest supported range and repeat/refine suspected
transitions instead of repeating every clean point.

Netriage must obtain `test_budget_gb`, quota/billing window and peak constraints
before the first full-speed test. Include all phases and a retry allowance,
monitor interface-byte deltas, define a byte/time stop condition, and keep a
separate interruption/cleanup procedure. A sub-50-GB upstream estimate is not
implicit authorization.

## qdisc safety

v0.5.9 moves the custom-qdisc guard into `qdisc_save`, covering wizard probes
and peer validation as well as direct commands. External HTB now prompts with
a warning that classes/filters will be lost; it is no longer silently accepted.
However, the guard allows continuation, accepts fq/fq_codel/mq without checking
custom parameters, and treats an executable tcpfit qdisc script as ownership
evidence. Inspect the actual owner/topology before allowing replacement.

`qdisc_save` still stores only root kind and one mq leaf kind. It does not
capture handles, classes, filters, per-queue differences, limits or options.
`qdisc_restore` first tries the current tcpfit script, otherwise recreates by
kind; an HTB restored that way is empty. The sweep wrapper prints restoration
success without checking its return code. The persistent rollback snapshot
records qdisc as a comment; rollback removes the root and lets the kernel
recreate defaults rather than replaying the old topology.
[Save/restore and guard](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2458-L2562),
[sweep restore wrapper](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2755-L2759),
[rollback](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L1629-L1634).

Therefore, automatic bandwidth probing is a disruptive qdisc experiment. On
mq, it changes leaf qdiscs and may assign a root handle; on other roots it can
replace the root. Require exact restoration from the authoritative owner or a
tested owned script. `tc -j -s qdisc/class/filter` is evidence, not a generic
import format. Verify root, leaves, classes, filters, owner/service state and
critical traffic after cleanup. If exact restore is unknown, stay read-only
and propose a maintenance-window procedure.

The HTB burst is now rate-derived (`max(32 KiB, rate_Mbps×500)`), not always
32 KiB; quantum 1514, fq limit 40960 and flow_limit 8192 remain fixed. Derive
rate/MTU/workload candidates and inspect latency/backlog/drops and tc warnings.
The persistent shaper dynamically follows the first IPv4 main-table default
unless `TCPFIT_IF` is supplied; that can differ from the peer-route NIC used
in the test. Validate both live and reboot targets on multi-egress hosts.
[Persistent shaper](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2330-L2378).

## initcwnd and telemetry

Direct `tune` still sets IPv4 main-table default `initcwnd/initrwnd=32` unless
`--no-initcwnd` is given. Only the wizard automatically suppresses the override
at bandwidth ≤100 Mbps. There is no equivalent general IPv6/policy-table
window tuning. Require first-second burst evidence before changing windows,
and preserve any pre-existing values.
[Direct tune](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L1857-L1894),
[low-bandwidth wizard](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L4109-L4116).

Inventory PPP hooks, `tcpfit-initcwnd.service` and its script,
networkd-dispatcher hooks, `/etc/systemd/network/*.network.d/50-tcpfit-initcwnd.conf`,
and `/var/lib/tcpfit/initcwnd.{owned,vals}` as well as qdisc/sysctl artifacts.
Networkd DHCP drop-ins need systemd ≥255. They are deliberately not reloaded
immediately; existing daemon state can remain stale until restart. The
fallback unit runs only at boot, while dispatcher can miss a networkd restart
with no link-state transition. A successful unit/enable operation is not a
read-back of route windows. Verify after the relevant reboot/reconnect/renewal
and validate the actual selected route, with no unapproved production reload.
[Persistence limits](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2087-L2139),
[networkd behavior](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L2205-L2327).

Opt-out telemetry remains: the interactive menu starts a background version
request to `https://tcpfit.spacevps.cc/ping`. No explicit host ID is sent by
this function, but the endpoint can observe source IP/time. v0.5.9 closes the
inherited lock descriptor in that child; it does not remove telemetry.
Netriage never triggers it. If upstream execution is explicitly requested,
disclose it and set `TCPFIT_NO_TELEMETRY=1` unless the user approves the request.
A `/var/lib/tcpfit/no-telemetry` marker also disables it.
[Telemetry source](https://github.com/Kylin010/tcpfit/blob/38fbf5af30daf87735f2ffbc5e0905033ee2b86e/tcpfit.sh#L1018-L1055).

## Evidence gates and integration checklist

1. Read this reference and `SKILL.md`; scope role, path, direction and approval.
2. Freeze literal peer IP, family, source, NIC and port before/after every
   sample. DNS resolution/target-aware NIC selection does not bind upstream's
   iperf endpoint or prove route stability. Keep whole `iperf3 -J` documents;
   upstream's text parser is not a replacement for these evidence records.
3. Use an idle, nearby, demonstrably faster peer for the local policer question.
   Validate a deliberately sub-cap paced rate first. An incapable peer cannot
   identify that host's port knee.
4. Compare goodput, retransmits, RTT/cwnd, interface bytes, tc/backlog/drop and
   TCP counter deltas plus application behavior. Retransmits divided by a
   presumed 1448-byte packet count are a heuristic, not observed packet loss.
   Do not universalize the 0.1% threshold, margin tiers, 12-second tests or
   automatically widened `0.95×goodput` range.
5. Scan only within approved traffic/qdisc conditions; repeat suspected spikes
   and test a ladder below a reproducible knee across appropriate time windows
   and capable peers. Remove/reject shaping when evidence does not support it.
6. Keep broad sysctl writes, BBR loading/Cubic fallback, swap, TFO, FIN/keepalive,
   port range, `netdev_budget=600`, file limits and route windows behind separate
   workload/pressure evidence. `detect` itself writes facts and may load BBR;
   do not treat all upstream inspection commands as read-only.
7. Preserve a per-run baseline and exact rollback for affected artifacts; the
   upstream first-tune snapshot/archive is not necessarily the current baseline.
   Netriage recommendation-before-application remains in force.
8. If upstream use is required, pin v0.5.9 and verify the script hash above,
   disable unapproved telemetry, inventory every artifact, and accept only
   measured cleanup/service/business-path results. Keep fleet tests serial and
   independently validate each host.

The measured-tuner comparison with
[`ike-sh/bbrv3-lite` v8.0.3](https://github.com/ike-sh/bbrv3-lite/releases/tag/v8.0.3)
remains limited to workflow ideas: fixed endpoint tuples, pre/post route checks,
whole JSON samples and no recommendation from drifting or CPU-bound tests.
Netriage does not inherit its kernel, DNS, IPv6 or one-click control plane.
