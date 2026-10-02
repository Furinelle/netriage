# Network tuning evidence: kernel documentation and operator experience

Reviewed 2026-10-02. These are decision rules, not a sysctl preset. Kernel
documentation defines semantics; operator blogs supply hypotheses to reproduce
on the target workload. Check the running distribution's kernel/backports and
tool versions before using an option from newer documentation.

## Traffic-saving test selection

Use the least traffic that can answer the current question. This is a local
netriage operating policy, not a kernel recommendation or permission to test.

1. Reuse recent samples with matching route, peer, protocol and load context;
   do not repeat a full baseline merely because a new agent or turn started.
   Observe existing service traffic, socket/counter deltas and application
   behavior before generating traffic. Expired or mismatched samples remain
   background evidence only.
2. If active testing is needed, start with one durable peer, the user-critical
   direction, P1, a low paced rate and a short window. Without a supplied budget,
   plan at most **64 MiB per host for the initial diagnosis**, including retries
   and verification; a smaller user budget takes precedence. This is a planning
   ceiling, not an enforced quota or a new grant of authorization. Keep room
   for protocol overhead and any final retest. Do not reset it per peer or turn.
3. A 5-second paced pilot can check reachability and gross trouble, but cannot
   establish peak capacity, steady-state long-RTT TCP performance or a policer
   knee. Select a rate within the known link/test budget; omit warm-up only for
   this explicitly labelled pilot. If the next decision needs steady state,
   budget sufficient ramp-up and measurement rather than drawing a conclusion
   from an artificially short run.
4. Add a reverse run only for directionality; P4 only for a single-flow/CPU
   question; another peer only to distinguish peer/path from host limits. Raise
   rate/duration only when the prior result leaves that decision unresolved.
   Repeat failed connections at most once after investigating the failure;
   do not rotate through public ports or peers automatically.
5. Leave full-speed probes, complete P1/P4 × forward/reverse matrices, bidirectional
   load and policer sweeps off by default. A necessary escalation must fit the
   existing scope/budget or obtain approval for the specific additional cost.
   A scan range should follow existing observations; repeat/refine suspected
   transitions, not every clean point. Stop if the peer cannot resolve the
   question, results are already sufficient, or the remaining budget is too low.
6. After a change, rerun only the affected critical-path test plus required
   service checks. Reuse the baseline; do not repeat unrelated directions or
   the entire peer inventory. Report actual bytes, skipped tests and the
   uncertainty left by the smaller test, without claiming unmeasured capacity.

## Test cost and sample validity

Record client/server `iperf3 --version`. TCP `-b` defaults to unlimited; with
`-P N`, `-b` is per stream, so budget the sum. `-O` sends warm-up traffic even
though its statistics are omitted. For a time-based run, estimate payload as
`aggregate_Mbps × 125000 × (duration_s + omit_s)`, then add reverse runs,
retries, baseline, refinement and verification. An HTB aggregate cap is counted
once, not multiplied by stream count. Starting with 3.16, iperf3 uses one thread
per stream: version and per-core load can explain P1/P4 differences.
[Source: ESnet iperf3 manual](https://software.es.net/iperf/invoking.html).

An estimate is not an enforced quota. Set a bounded run duration, retry/step
ceiling and overall deadline before testing. Between steps compare actual
interface RX/TX deltas and remaining budget; reserve room for the next complete
step, warm-up and cleanup. For a strict cap, use a supported byte limit or a
supervisor that stops the owned test process at the byte/time threshold, allowing
for in-flight traffic and polling overshoot. Stop on route drift, peer failure,
CPU saturation, deadline or insufficient remaining budget. Never auto-expand
the scan beyond the approved scope. RX+TX includes unrelated service traffic
and may differ from the provider's billing rules; label GB versus GiB explicitly.
`measure-window.sh` observes a completed window; it is not a live quota guard.

For the tests actually selected, keep P1/P4 and directions separate. Use
repeated A/B/A only when a noisy comparison or proposed persistent change
needs corroboration; these runs should keep the same
endpoint tuple, tool options, time window and background load. Report receiver
goodput, sender retransmits, per-core CPU/steal, idle/loaded RTT and actual
application startup/transfer behavior. A result that trades application tail
latency for a larger speed-test number is not an improvement by default.

## TCP buffers: identify what is limiting the socket

Inspect representative `ss -tinm` sockets and before/after `nstat -az`,
`/proc/net/sockstat`, memory pressure and cgroup limits. Where exposed, use
`rwnd_limited`, `sndbuf_limited`, `app_limited`, `cwnd`, `rtt`, `delivery_rate`,
`skmem` and queue sizes as clues, not isolated verdicts. Check both endpoints;
a slow reader, application flow-control window, disk, encryption CPU or remote
receiver cannot be repaired by increasing the sender's global buffer maximum.

Linux TCP receive autotuning uses `tcp_rmem[2]` while `tcp_moderate_rcvbuf` is
enabled. Explicit `SO_RCVBUF` disables receive autotuning for that socket;
iperf3 `-w` is therefore a separate experiment, not a neutral baseline. Keep
TCP defaults, TCP autotuning maxima and `net.core.*` application socket limits
distinct. Memory accounting includes overhead, so BDP is not the exact buffer
allocation. `tcp_mem` and `udp_mem` are pages. Preserve kernel defaults unless
the observed limit justifies changing them.
[Source: Linux IP sysctl documentation](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html).

The calculator's RAM/4, workload defaults and 256 MiB ceiling are conservative
heuristics, not a proof that a host can afford the setting. Use an explicit
available network-memory budget that respects cgroups, other services and
headroom when interpreting its physical-RAM input. A proxy has multiple legs,
and each socket has send/receive memory: count simultaneously large allocations,
not just users. A maximum is not preallocated, but many growing sockets can
still exhaust memory. Leave defaults unchanged unless startup evidence calls
for a change; raise only the measured limiting ceiling.

ESnet distinguishes parallel-stream data-transfer hosts from single-stream
measurement hosts. Its large 10G/100G examples assume their hardware, RTT and
workload; they are not presets for a small, busy VPS. `fq maxrate` is per flow,
not a global host shaper.
[Sources: ESnet Linux tuning](https://fasterdata.es.net/host-tuning/linux/),
[measurement-host tuning](https://fasterdata.es.net/host-tuning/linux/test-measurement-host-tuning/).

Cloudflare's throughput/latency experiments show why large receive queues and
TCP collapse work need latency and memory measurements alongside bandwidth.
Reuse that validation method, not their 512 MiB settings or custom
`tcp_collapse_max_bytes` patch. Their older `tcp_adv_win_scale` advice is
version-bound: upstream documents it as obsolete since Linux 6.6.
[Sources: Cloudflare's WAN tuning experiments](https://blog.cloudflare.com/optimizing-tcp-for-high-throughput-and-low-latency/),
[Linux sysctl semantics](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html).

Cloudflare also documented slow-reader receive-memory growth requiring a
kernel fix. If socket memory grows unexpectedly, investigate application drain
rate and the distribution's fixes; increasing global limits can hide the
failure. The article describes a historical bug, not proof that the running
kernel is affected.
[Source: Cloudflare's receive-buffer investigation](https://blog.cloudflare.com/unbounded-memory-usage-by-tcp-for-receive-buffers-and-how-we-fixed-it/).

## Locate loss and CPU pressure before choosing a queue knob

| Correlated evidence during the same window | Next step |
| --- | --- |
| NIC RX missed/no-buffer counters rise | Check `ethtool -S/-g/-l`, queue capacity, IRQ placement and CPU; ring growth is a candidate only here. |
| Per-CPU softnet drops/time-squeeze and receive CPU saturation | Inspect RSS/IRQ distribution, then backlog/budget or RPS if justified; also check VPS steal time. |
| TCP receive queue/memory pressure or slow drain | Check receiving application and socket limits before link shaping. |
| Local egress backlog/drops plus loaded RTT growth | Compare queue/pacing/shaper candidates and application latency. |
| Retransmits without local queue evidence | Investigate path, remote receiver and provider policing; zero local drops do not exclude an upstream policer. |
| Only a transit hop reports ICMP loss, destination stays clean | Do not equate ICMP reply throttling with forwarded data loss; corroborate at destination/application. |

Interpret counter deltas, not absolute totals; softnet counters are hexadecimal
and layouts depend on kernel. Offloads change packet accounting. Do not disable
TSO/GSO/GRO globally to make counters simpler. Red Hat's guidance ties ring,
backlog and budget changes to the specific drop/CPU stage; larger queues can
increase latency.
[Source: Red Hat network troubleshooting and tuning](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html-single/network_troubleshooting_and_performance_tuning/network_troubleshooting_and_performance_tuning).

Prefer existing RSS and valid IRQ placement. RPS can be redundant when RSS
already distributes hardware queues across CPUs, and adds cross-CPU work;
consider it for an evidenced queue/CPU mismatch, not merely because a VPS has
several vCPUs. Preserve `mq` and its leaf topology when applicable.
[Source: Linux networking scaling](https://www.kernel.org/doc/html/latest/networking/scaling.html).

## Protocol and persistence acceptance

- Separate kernel forwarding from TCP termination. BBR operates on locally
  terminated TCP; qdiscs can affect forwarded TCP and UDP. For HY2/TUIC/QUIC,
  test the application transport, UDP drops and CPU as well as any outbound TCP
  leg. A TCP iperf run cannot establish QUIC performance.
- `tcp_mtu_probing=1` reacts to TCP black-hole detection; `2` enables probing
  unconditionally. Neither fixes UDP/QUIC PMTU. Blocked ICMP alone is not proof
  of a smaller MTU; validate representative packet sizes and the real service.
  [Source: Linux IP sysctl documentation](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html).
- Resolve the actual route, including policy table/source and gateway-less
  point-to-point paths. Persist optional route metrics through the existing
  network owner. A later route update or DHCP renewal can overwrite them;
  verify after that event when authorized, and label it unverified otherwise.
- Accept a change only after live-state readback, the same critical-path test,
  application latency/throughput and memory checks. Reboot/renewal validation
  requires existing authorization; a successful unit exit does not prove
  persistence. Rollback restores the immediate pre-change owner/state.
