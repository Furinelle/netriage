# Evidence-Based VPS TCP Tuning Method

Source: Lide, “让 AI 帮你调 VPS 网络：中转机和落地机 TCP 调优笔记”, iBytebox, 2026-07-07, https://blog.ibytebox.com/posts/ai-agent-vps-tcp-tuning/. This file is a concise adaptation for agent reuse, not a verbatim copy.

For the 2026-10-02 cross-check against Linux/ESnet documentation and Cloudflare/Red Hat experience, read [current-evidence.md](current-evidence.md). The original article remains methodological background, not a current kernel parameter specification.

## Input Contract

Collect or ask for:

| Field | Why it matters |
| --- | --- |
| `target_ssh` | Use aliases; never request private keys or secrets. |
| `machine_role` | **Identity gate.** Choose 落地 / 线路 / 中转; do not infer it from a hostname. |
| `traffic_path` | Needed to map measurements to real UX. |
| `critical_direction` | User download/upload may map to target egress/ingress differently. |
| `proxy_software` / `proxy_protocols` | TCP and UDP/QUIC respond to different knobs. |
| `service_ports` | Identify real services and testing ports. |
| `advertised_bandwidth` | **Identity gate.** Vendor nominal Mbps, up/down separately if asymmetric. Prefer known port speed over public speedtests. |
| `socket_workload` | `proxy` (high-concurrency user-space TCP termination), `bulk` (few long TCP flows), or `mixed`; it is separate from the host role. |
| `service_region` / RTT class | Asia/short-RTT vs overseas/long-RTT; selects BDP-informed buffer *candidates* (see `vps-tcp-tune-review.md`). |
| `test_peers` | Peer label, literal IP/family, source/egress route, iperf3 port, ICMP, SSH, role. |
| `peer_lifecycle` | Long-term/renewing peers should drive persistent tuning; soon-to-expire hosts may be tested for observation but should not dominate decisions. |
| `test_budget_gb` / window | Bound high-rate probes and sweeps by quota, billing period, and peak/off-peak timing. |
| `permission_boundary` | Inspect, test, recommend, apply, reboot, MTU, shaping, cleanup, third-party script/kernel swap. Persistent apply still requires explicit approval of the recommendation. |

If these are missing, ask before remote work. If the user already provided some fields, ask only for the missing/high-risk ones. Do **not** SSH, inspect, test, or recommend until both identity-gate fields are confirmed: role (落地 / 线路 / 中转) and nominal bandwidth. Then ask target, path, critical direction, and permission boundary; defer region/RTT to buffer sizing and peers/lifecycle to testing, and auto-discover proxy software/protocols/ports only after the gate (see `SKILL.md`).

## Read-Only Inspection

Collect enough evidence to explain current state before changing it:

```bash
hostname; uname -r; uname -m; cat /etc/os-release
lscpu | sed -n '1,20p'; free -h; swapon --show
route_target=<representative-peer-literal-ip>
route_source=${ROUTE_SOURCE:-}
ip -br addr show
if [ -n "$route_source" ]; then ip route get "$route_target" from "$route_source"; else ip route get "$route_target"; fi
ss -s
sysctl net.ipv4.tcp_available_congestion_control \
  net.ipv4.tcp_congestion_control net.core.default_qdisc \
  net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem \
  net.ipv4.tcp_wmem net.core.somaxconn \
  net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog \
  net.ipv4.tcp_notsent_lowat net.ipv4.ip_forward \
  net.ipv6.conf.all.forwarding net.ipv4.tcp_fastopen \
  net.ipv4.tcp_ecn net.ipv4.tcp_syncookies net.ipv4.tcp_mtu_probing

tc -s qdisc show
dev=$(if [ -n "$route_source" ]; then ip -o route get "$route_target" from "$route_source"; else ip -o route get "$route_target"; fi | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
tc -s class show dev "$dev" 2>/dev/null || true
tc filter show dev "$dev" 2>/dev/null || true
ethtool -k "$dev" 2>/dev/null || true
cat /proc/net/softnet_stat 2>/dev/null | head
find /etc/sysctl.d -maxdepth 1 -type f -name '*.conf' -print -exec sed -n '1,160p' {} \;
systemctl --type=service --state=running --no-pager | grep -Ei 'sing-box|xray|realm|gost|nodepass|hysteria|tuic|nginx|caddy|apache|iperf3|qos-agent' || true
ls /etc/sysctl.d/*.profile.md 2>/dev/null | xargs -r sed -n '1,160p'

# Dual-stack, conntrack, and receive-scaling evidence when relevant
ip -4 route; ip -6 route
getent ahosts <real-service-hostname> 2>/dev/null || true
sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max 2>/dev/null || true
nstat -az 2>/dev/null | grep -Ei 'conntrack|listen|retrans|timeout|drop' || true
grep -E 'NET_RX|NET_TX' /proc/softirqs 2>/dev/null || true
grep -Ei 'virtio|eth|ens|enp' /proc/interrupts 2>/dev/null || true
find /sys/class/net/<dev>/queues -maxdepth 2 \
  \( -name rps_cpus -o -name rps_flow_cnt -o -name xps_cpus \) \
  -print -exec cat {} \; 2>/dev/null
```

## PMTU and iperf3 Tests

Run peers sequentially. Freeze each sample to a literal peer IP, IP family, source IP, egress NIC, and port; when a service binds a source, use `ip route get <literal-peer-ip> from <source-ip>` before and after the window, and discard a sample whose route tuple changes. Preserve each `iperf3 -J` document whole — never combine sender/receiver fields from different rounds. If the peer inventory includes soon-to-expire or throwaway VPSs, test them only when they help diagnose reachability; base persistent sysctl/qdisc/MTU/shaping decisions on the durable peers that match the user's real traffic path.

Before a bandwidth probe or shaping sweep, estimate the lower-bound transfer
volume and compare it with `test_budget_gb`; include warm-up (`-O`), retries, baseline, reverse,
and verification overhead. Specify GB/GiB, retry/step/time ceilings and a
remaining-budget stop before the first probe. `-b` applies per stream with `-P`;
an aggregate HTB rate is counted once. The calculator accepts `--sweep-omit`
for warm-up but does not enforce a quota. A nearby high-capacity peer answers “where is the VPS
port/policer knee,” while durable business-path peers answer “what improves the
real service.” Keep those roles separate. For the detailed tcpfit-derived sweep
method and its qdisc-restoration limits, read `tcpfit-review.md`.

PMTU ladder for IPv4:

```bash
tracepath -n <peer> || true
for s in 1472 1452 1432 1412 1392 1352 1332 1312 1292; do
  mtu=$((s+28))
  ping -M do -s "$s" -c 2 -W 1 <peer> >/dev/null 2>&1 \
    && echo "payload=$s mtu=$mtu OK" \
    || echo "payload=$s mtu=$mtu FAIL"
done
```

iperf3 pattern; run only the approved subset and adapt direction to the user-critical path. Each `-t 12 -O 2` example sends for about 14 seconds; these TCP commands are uncapped and require a capacity-based budget first. For a paced test, budget `-P × -b`; do not add `-w` to the autotuning baseline:

```bash
# When a source is bound, use it in both places: --route-source <source-ip>
# and iperf3 -B <source-ip>.
scripts/measure-window.sh --route-target <literal-peer-ip> --label p1-fwd -- \
  iperf3 -c <literal-peer-ip> -p <port> -t 12 -O 2 -P 1 -J
scripts/measure-window.sh --route-target <literal-peer-ip> --label p4-fwd -- \
  iperf3 -c <literal-peer-ip> -p <port> -t 12 -O 2 -P 4 -J
scripts/measure-window.sh --route-target <literal-peer-ip> --label p1-rev -- \
  iperf3 -c <literal-peer-ip> -p <port> -t 12 -O 2 -P 1 -R -J
scripts/measure-window.sh --route-target <literal-peer-ip> --label p4-rev -- \
  iperf3 -c <literal-peer-ip> -p <port> -t 12 -O 2 -P 4 -R -J
```

Record bitrate, retransmits, cwnd/RTT clues, startup behavior, single-flow vs multi-flow differences, qdisc drops/backlog deltas, and TCP retransmission counter deltas.

Installing iperf3 and opening its port are changes: ask before installing packages, prefer non-persistent firewall rules for the test window, and remove every rule this run added during cleanup.

```bash
# choose the tool the host actually uses; delete the rule in cleanup
ufw allow <port>/tcp                    # ufw persists: 'ufw delete allow <port>/tcp' in cleanup
firewall-cmd --add-port=<port>/tcp      # runtime only (no --permanent); '--remove-port' in cleanup
iptables -I INPUT -p tcp --dport <port> -j ACCEPT   # not saved to disk; 'iptables -D ...' in cleanup
```

Safer temporary server lifecycle:

```bash
# On the peer under test. Avoid pkill -f because the pattern may match
# the current SSH shell command line and kill the session before setup.
mkdir -p /root/network-tuning-$RUN_ID/tests/$peer
PIDFILE=/root/network-tuning-$RUN_ID/tests/$peer/iperf3-server.pid
LOGFILE=/root/network-tuning-$RUN_ID/tests/$peer/iperf3-server.log
if [ -f "$PIDFILE" ]; then
  oldpid=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$oldpid" ] && ps -p "$oldpid" -o comm= 2>/dev/null | grep -q '^iperf3$'; then
    kill "$oldpid" || true
  fi
  rm -f "$PIDFILE"
fi
iperf3 -s -p <port> -D --forceflush --pidfile "$PIDFILE" --logfile "$LOGFILE"
# Cleanup: kill only the verified PID from PIDFILE, then remove temporary firewall rules that this run added.
```

## Interpretation Rules

| Evidence | Likely meaning |
| --- | --- |
| Single-flow low, multi-flow high | BDP, per-flow path limits, loss recovery, or congestion-control behavior. |
| qdisc drop/backlog increases during test | Local egress queue/shaping may matter. |
| qdisc drop/backlog stays zero but retransmits high | Suspect path, upstream, or remote receiver before local buffer/shaping changes. |
| Durable peers clean but temporary peers weak | Tune for durable peers; report temporary-peer weakness separately. |
| High retransmits with low cwnd | Loss/congestion is more likely than missing buffer. |
| One peer bad, others clean | Do not downsize global capacity from one weak peer. |
| HY2/TUIC/QUIC issue | Validate MTU/qdisc/CPU and app loss; TCP buffer may be irrelevant. |

Relay hosts: identify where traffic enters and leaves; a user download may correspond to relay egress toward the line or landing. Kernel forwarding means TCP buffer/BBR might not affect forwarded TCP the same way userspace proxy termination does.

Line hosts: treat as a path hop. Forwarding, qdisc, and the line's own policer usually dominate; do not apply landing-style endpoint extras unless the host also terminates TCP.

Landing hosts: if they terminate or re-originate TCP, BBR/fq/buffers/notsent/TFO/ECN can matter more directly. Separate web/proxy TCP behavior from UDP/QUIC behavior.

Protocol × knob impact (from the source article):

| Traffic type | Linux TCP congestion control | qdisc | TCP socket buffers | MTU/PMTU |
| --- | --- | --- | --- | --- |
| TCP endpoint, including userspace relay TCP legs | direct | yes | direct | direct |
| Kernel-forwarded TCP (nftables DNAT) | no local TCP endpoint | yes | none for forwarded flow | direct |
| UDP/QUIC (HY2, TUIC, WireGuard) | none for outer transport | yes | none for outer transport | direct |

Symptom → role hint: high-concurrency forwarding loss and queue backlog point at the relay side; slow page starts, video stalls, and long-RTT window growth point at the landing/endpoint side.

## Candidate Tuning Decisions

- BBR/fq: prefer when available and appropriate; verify the actual implementation from kernel/package provenance, not an assumed `bbr3` name. After recommending `default_qdisc=fq`, verify the **live** topology and plan owner-aware persistence; preserve `mq` and its eligible leaves.
- Buffers: estimate from bandwidth-delay product, memory, host role, **explicit expected concurrency**, socket workload, and service_region. Rough BDP bytes ≈ `Mbps × RTT_ms × 125`. Compare 2×BDP with tcpfit v0.5.9's 2×BDP+2MiB candidate, then cap from an explicit RAM/4 budget divided by concurrency. Pass `getconf PAGE_SIZE` from the target to `scripts/derive-candidates.py --workload <proxy|bulk|mixed>`; `tcp_mem` is pages. Do not infer workload from 落地 / 线路 / 中转, and do not produce an endpoint-buffer candidate for a pure kernel forwarder without a terminating TCP workload. Use Asia/overseas ladders in `vps-tcp-tune-review.md` as candidates (overseas often larger, commonly capped near 64 MiB); small RAM hosts stay conservative. Prefer known port speed over public speedtests when they disagree. The source article's role tiers are upper-bound candidates: conservative caps for 100M relays; 64–128 MiB for 1G relay/landing when RTT and memory support it; 128–256 MiB only for high-bandwidth long-RTT landing hosts with BDP and retransmit evidence. Where this clashes with the one-click 64 MiB overseas cap, prefer the smaller value unless measured BDP, ample free RAM, and clean loss data justify more.
- MTU: walk the decision chain in order — (1) is the public interface currently 1500; (2) is PMTU to durable peers clean; (3) is a tunnel/WireGuard/overlay/nested proxy in the path; (4) is the real protocol TCP or UDP/QUIC; (5) is there fragmentation/black-hole/retransmit/QUIC-loss evidence. Keep 1500 when clean. Consider 1450-1460 for mild tunnel/provider overhead, or 1400-1440 for nested encapsulation/consumer ISP/UDP paths, only with evidence. Prefer `tcp_mtu_probing` (TCP-only) over cargo-cult interface MTU 1440 when black holes are TCP-specific.
- HTB/TBF: test practical stable uplink with a repeated ladder. A provider-policer knee may sit above unpaced goodput, but only a capable nearby peer and reproducible transition can establish that. Choose the highest cap that lowers retransmits/drops without harming critical throughput; improved short-connection/web/video startup behavior also counts in favor of a cap. For peer-specific bottlenecks, scope shaping to those peers. For an evidenced shared-egress policer, an approved aggregate cap may be appropriate; validate healthy peers and critical traffic, and raise/remove the cap if their regression outweighs the intended benefit. Keep fq as the child qdisc. “No observed knee” means no cap, not “use the scan ceiling.”
- qos-agent: reserve for adaptive per-peer/per-port/per-source control; do not deploy by default.
- IPv4 preference: compare real IPv4 and IPv6 service paths first. `/etc/gai.conf` changes libc address selection; it does not rewrite DNS responses. Do not permanently disable IPv6 as a default optimize step.
- Conntrack: inspect whether the host actually traverses NAT/firewall conntrack and compare `nf_conntrack_count` with the limit. Do not derive table size from RAM alone or hardcode popular script values.
- RPS/RFS: use only when queue topology and per-CPU softirq evidence show a receive-side bottleneck. The per-queue `rps_flow_cnt` values should add up sensibly to `rps_sock_flow_entries`; RSS may already make RPS redundant.
- MSS clamp: use on a forwarding/tunnel path only when PMTU evidence supports it, and persist the rule through the host's nftables/iptables/UFW ownership model.
- File limits: inspect the daemon's current and systemd limits; prefer a service drop-in over an indiscriminate global million-entry limit.
- initcwnd/initrwnd: optional on default route after baseline; do not set 32 on a path at or below 100 Mbps without a first-second burst measurement. Re-check after DHCP/NetworkManager or reboot.
- Endpoint extras (`tcp_notsent_lowat`, keepalive, `tcp_fin_timeout`, TFO): optional for landing/proxy TCP termination; not universal for pure L4 relays.
- Realm/L4 relay extras: only when that software is present (conntrack pressure, nodelay/reuse_port, unit `LimitNOFILE`).

For a detailed audit of the ideas and failure modes in `Madhatter2099/TCP-Optimize`, read `tcp-optimize-review.md`. For `Eric86777/vps-tcp-tune` (XanMod/BBRv3 one-click, menu 3/66, Realm fix), read `vps-tcp-tune-review.md`. For `Kylin010/tcpfit` (BDP/RAM candidate math, test-volume estimation, port-policer sweep, qdisc restore caveats), read `tcpfit-review.md`.

## Recommendation and Safe Apply Process

1. Explain the planned change and measurements that justify it.
2. Present exact recommended config before applying: proposed `/etc/sysctl.d/*.conf` content, any qdisc/systemd/MTU/qos-agent commands, rejected candidate knobs, risk/interruption notes, verification plan, and rollback plan.
3. Stop for user approval unless the current session already authorizes applying the recommendation.
4. After approval, take a validated pre-change snapshot for the representative route with `ROUTE_TARGET=<literal-peer-ip> bash scripts/backup-snapshot.sh`; add `ROUTE_SOURCE=<bound-source-ip>` when the service binds a source. Include affected units/scripts and a planned-path manifest. A failed or incomplete snapshot blocks application; diagnostic command output alone is not an executable rollback. Use the authoritative qdisc/network owner for exact restoration.
5. Write one consolidated sysctl.d file for active tuning; inventory and neutralize higher-priority conflicting drop-ins before apply.
6. Apply the approved drop-in with `sysctl -p <file>`. Use `sysctl --system` only when a full reload is authorized and the other files have been checked; it can activate unrelated pending settings. If recommending live `fq`/MSS clamp/initcwnd, apply those explicitly and install persistence only when approved.
7. Confirm SSH and critical services still work.
8. Read back effective sysctl/qdisc values, buffer bytes, and any route/RPS changes — including the live root qdisc on the egress interface, not just `net.core.default_qdisc`:

   ```bash
   route_target=<representative-peer-literal-ip>
   route_source=${ROUTE_SOURCE:-}
   dev=$(if [ -n "$route_source" ]; then ip -o route get "$route_target" from "$route_source"; else ip -o route get "$route_target"; fi | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
   sysctl -n net.ipv4.tcp_congestion_control net.core.default_qdisc
   tc -s qdisc show dev "$dev"
   ```
9. Rerun the most important tests.
10. Roll back or revise if worse.
11. Write `/etc/sysctl.d/*.profile.md` with role, durable peers, tests, chosen values, reasoning, caveats, backup path, and rollback commands.

When writing profile Markdown from shell, use quoted heredocs for static content or avoid backticks in unquoted heredocs:

```bash
cat > /etc/sysctl.d/99-zz-tcp-tuning.profile.md <<'EOF'
# profile text with literal backticks is safe here
EOF
```

An unquoted heredoc containing Markdown code fences can trigger command substitution and accidentally run rollback-looking commands.

## Final Report Checklist

- Inspected hosts and roles.
- Durable peers used for decisions, and any temporary/non-renewing peers intentionally excluded.
- Tests run and user-critical results.
- Changes applied and explicit non-changes.
- Retransmission, qdisc, PMTU, and bottleneck interpretation.
- Backup/profile paths and rollback commands.
- Remaining uncertainty and next tests.
- Mask IPs unless the user asked for raw addresses.
