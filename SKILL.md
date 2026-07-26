---
name: netriage
description: Evidence-based Linux VPS TCP/network tuning workflow — question, inspect, test, recommend, then apply only after user approval. Use when the user asks to perform TCP tuning, 进行TCP调优, tcp调优, VPS网络调优, BBR调优, 网络优化, 网络加速, 开启BBR, 魔改bbr, bbrplus, 锐速, 调整TCP参数, sysctl优化, 内核参数优化, 测速慢, 下载慢, 高重传, 丢包, 中转机/落地机优化, or to audit, plan, recommend, apply, or verify Linux VPS networking for relay, landing, exit, proxy, or web hosts with SSH access, especially BBR, fq, sysctl, qdisc, MTU/PMTU, iperf3, TBF, HTB, qos-agent, XanMod, workload profiles, Eric86777/vps-tcp-tune, Madhatter2099/TCP-Optimize, one-click bbr scripts, or TCP retransmission/throughput/latency problems on a Linux VPS.
license: CC-BY-NC-SA-4.0 (derived content; see LICENSE)
---

# netriage — VPS TCP Tuning

## Overview

Use evidence, not cargo-cult values. Treat `MTU 1440`, `TBF 1000Mbit`, huge TCP buffers, BBR, fq, HTB, qos-agent, and one-click BBR menus as candidates that must be justified by host role, traffic direction, path tests, and rollback safety.

Before live tuning or a concrete plan, read `references/blog-method.md` for the detailed checklist and command patterns distilled from the source article. When the user mentions a one-click tuning script, IPv4 priority, conntrack sizing, RPS/RFS, UDP buffers, MSS clamping, workload profiles (选项 8), or `Madhatter2099/TCP-Optimize`, also read `references/tcp-optimize-review.md`. When the user mentions `Eric86777/vps-tcp-tune`, `net-tcp-tune.sh`, menu `3`/`66`, XanMod + BBRv3 one-click, Realm timeout fix, or “按 bbr 脚本那套”, also read `references/vps-tcp-tune-review.md`.

Reusable helpers in this skill: `scripts/` holds read-only inspection (`inspect.sh`), PMTU probing (`pmtu-probe.sh`), and a pre-change snapshot (`backup-snapshot.sh`); `templates/` holds the recommendation and profile skeletons.

Do **not** silently wrap or auto-run third-party installers (`curl | bash`, `bbr` alias, menu 66). Pin/download, inventory side effects, backup, then recommend.

## Mandatory Active Questioning Gate

When this skill is invoked, actively ask the user for missing intent before touching remote hosts. Ask concise grouped questions; do not assume the business path from hostname alone. Do not dump every field at once: ask a small core set first, discover what read-only inspection can answer, and defer stage-specific fields to the stage that needs them.

First-round core questions (ask whenever missing):

- `target_ssh`: SSH alias or SSH command for each target.
- `machine_role` + `traffic_path` (one combined question): relay, landing, mixed, exit, web, or test peer; e.g. `user -> relay -> landing -> internet`.
- `critical_direction`: which direction maps to the user's real experience.
- `permission_boundary`: inspect only, test only, plan only, apply allowed, reboot allowed, MTU changes allowed, shaping/qos-agent allowed, cleanup of backups/logs allowed, third-party script / kernel swap allowed.

Discover before asking (from read-only inspection; ask only when discovery is inconclusive):

- `proxy_software` and `proxy_protocols`: sing-box, xray, realm, gost, Hysteria2, TUIC, WireGuard, nginx/caddy, nftables/iptables, etc.
- `service_ports`: proxy/web/relay/iperf ports.

Ask when the stage needs them:

- Before buffer sizing: `advertised_bandwidth` (practical or advertised up/down/port speed in Mbps; prefer known port speed over flaky public speedtests) and `service_region` or path RTT class (asia/short-RTT vs overseas/long-RTT — affects BDP-informed buffer candidates).
- Before testing: `test_peers` (label, host/IP, iperf3 port, ICMP allowed, SSH access, role) and `peer_lifecycle` (long-term/renewing versus temporary/soon-to-expire; only durable peers drive persistent tuning decisions unless the user explicitly says otherwise).
- Optional when relevant: whether Realm (or similar L4 relay) is in path; whether dual-stack must stay intact.

Defaults when the user is terse: inspect + test + recommendation only; no persistent changes, no reboot, no MTU change, no HTB/TBF/qos-agent, no DNS rewrite, no permanent IPv6 disable, no cleanup of backups/logs, no third-party script execution. Installing test tools (e.g. iperf3) and opening firewall ports are changes too: ask before installing packages on the target or peers, prefer non-persistent firewall rules for test windows, and remove every rule this run added before finishing. Never ask for private keys, tokens, or provider credentials.

## Recommendation Before Application Gate

Always produce a recommended configuration before applying persistent changes. The user decides whether to apply it. Even if inspection and testing are allowed, do not write persistent sysctl/qdisc/MTU/qos-agent/service changes until the user explicitly approves the recommended config or says to apply it.

A recommendation must include:

- Evidence summary: role, critical path, PMTU, bandwidth/RTT class, iperf/counter deltas, bottleneck interpretation.
- Exact candidate config: proposed `/etc/sysctl.d/*.conf` content and any qdisc/systemd/MTU/qos-agent/initcwnd/RPS commands or units.
- Non-changes: candidate knobs rejected because evidence is insufficient (including aggressive one-click side effects).
- Risk and interruption notes: whether restart/reboot/service reload/kernel swap is needed.
- Verification plan: exact read-back checks and retests after apply (live cc/qdisc/buffers, not only “file written”).
- Rollback plan: backup location and restore commands for every owned file/unit/rule.

Use `templates/recommendation.md` as the skeleton so every recommendation carries the same six sections.

After presenting the recommendation, stop and ask the user for approval unless the current user message already contains an explicit approval such as "应用这个推荐配置", "按推荐应用", or "直接应用".

## Workflow

1. **Clarify and scope**: Use the questioning gate. State role, traffic path, service_region/RTT class, and durable-peer assumptions back to the user before tests or changes.
2. **Inspect read-only first**: Run `scripts/inspect.sh` over SSH (`ssh <host> bash -s < scripts/inspect.sh`) when available, or fall back to the inline commands in `references/blog-method.md`. Collect OS/kernel, CPU/memory, interfaces/MTU/routes, socket summary, sysctl TCP state, qdisc/class/filter state, softnet/RPS/XPS if relevant, existing `/etc/sysctl.conf`, `/etc/sysctl.d/*.conf`, prior one-click ownership (`99-bbr-ultimate.conf`/`bbr-optimize-persist.service` from Eric's script; `10-bbr.conf`/`99-network-performance.conf`/`rps-optimize.service`/`mss-clamp.service` from TCP-Optimize), running proxy/web/systemd units, and any `*.profile.md` tuning profile.
3. **Choose peers deliberately**: Use all peers for broad observation only when useful, but let long-term/production peers drive persistent config; do not tune a lasting host around a soon-to-expire VPS.
4. **Test one peer at a time**: Ping if allowed; test PMTU before MTU/MSS decisions (`scripts/pmtu-probe.sh`); run iperf3 P1/P4 forward and reverse for user-critical directions; record bitrate, retransmits, RTT/cwnd clues, and qdisc/TCP counter deltas during each window. Test ports opened for iperf3 use temporary firewall rules that must be removed in the same run.
5. **Interpret by role**: For relays, map ingress/egress to user experience. For landing/exit/web hosts, separate TCP endpoint behavior from UDP/QUIC behavior. Do not generalize from one weak or temporary peer.
6. **Size buffers from evidence**: Combine advertised/measured bandwidth, path RTT class, concurrency, and free RAM. Use the Asia/Overseas ladder in `references/vps-tcp-tune-review.md` as a **candidate** table; cross-check with BDP (`Mbps × RTT_ms × 125` bytes). Prefer known port speed over public Ookla when they disagree.
7. **Recommend exact config first**: Produce the recommendation bundle. Include exact candidate files/commands, rejected knobs, verification, and rollback. Stop for user approval unless the user already explicitly approved applying the recommendation.
8. **Apply only after approval**: Before persistent changes, take a full pre-change snapshot with `scripts/backup-snapshot.sh` (or the snapshot block in `references/blog-method.md`) covering sysctl files, `sysctl -a`, qdisc, firewall state, and any units/scripts you will replace. Resolve sysctl conflicts by inventory + comment/disable higher-priority duplicates. Use a consolidated `/etc/sysctl.d/` file, apply with `sysctl -p`/`sysctl --system`, apply **live** `fq` when recommended, verify SSH/service health, rerun the important tests, and roll back if worse.
9. **Write profile and report**: Record role, durable peers, bandwidth/region assumptions, tests, chosen values, reasoning, caveats, backup path, and rollback commands in a small `/etc/sysctl.d/*.profile.md` following `templates/profile.md`. Final reports should prefer aliases and masked IPs.

## Tuning Policy

- Prefer BBR + fq only when the kernel exposes BBR and measurements/role support it.
- Do not infer BBRv3 from `uname -r` alone. Verify the installed kernel package/patch set or implementation provenance; the congestion-control name remains `bbr` across variants. XanMod install requires explicit reboot permission and risk acknowledgment.
- Size TCP buffers from measured or estimated BDP, memory, concurrency, role, and service_region; do not increase buffers to hide path loss. Treat fixed percentages of total RAM and one-click overseas 64 MiB caps as ceilings/candidates, not formulas.
- Remember that `net.ipv4.udp_mem` is expressed in memory pages, while `udp_rmem_min` and `udp_wmem_min` are bytes.
- Keep MTU unchanged when PMTU and real application paths are clean. Prefer `tcp_mtu_probing` (TCP-only) over rewriting interface MTU to 1440 without evidence.
- Treat `net.core.default_qdisc` as the default for newly created qdiscs; always inspect the live root qdisc. When `fq` is recommended, include immediate `tc qdisc replace` on eligible NICs plus a reboot-persistence mechanism.
- Persistence units for live settings (fq replace, RPS, MSS clamp) must inline the exact commands in the unit or a dedicated non-interactive script. Never point `ExecStart` back at an interactive tuning script, and verify the live state after reboot instead of trusting the unit's exit status.
- Use HTB/TBF only when local egress shaping is likely to reduce retransmits, queue drops, or backlog. Test caps as a ladder and keep fq below the shaping class.
- Consider qos-agent only for adaptive per-port/per-peer/per-source shaping with a clear target; never deploy it as a default tuning step.
- UDP/QUIC protocols such as HY2/TUIC do not consume Linux TCP buffers, but they still care about MTU, qdisc, CPU scheduling, and local egress shaping.
- Enable IPv4 address-selection preference only after comparing IPv4/IPv6 reachability and latency. `gai.conf` changes `getaddrinfo` address ordering, not authoritative DNS answers. Never permanently disable IPv6 as a default “full optimize” step.
- Resize conntrack only when NAT/firewall/relay use and `nf_conntrack_count`, table pressure, or insert/drop counters justify it. Load `nf_conntrack` before applying and verify the value after reboot. Do not hardcode `262144` without pressure evidence.
- Enable RPS/RFS only when multi-vCPU receive processing is measurably concentrated or dropping and RSS/RX queues are insufficient. Scope it to selected physical interfaces, derive valid CPU bitmaps for the actual CPU count (watch multi-word masks), and size per-queue RFS entries consistently with the global table.
- Apply `ip_forward`, MSS clamp, socket/file limits, queue expansions, and `initcwnd`/`initrwnd` only to roles that need them. Persist firewall rules with the host's existing firewall system and prefer per-service `LimitNOFILE` when a specific daemon is the constraint. Re-check route `initcwnd` after DHCP/NetworkManager changes.
- Realm / L4 relay extras (`nodelay`, `reuse_port`, resolve policy, unit `LimitNOFILE`) only when that software is present and the user wants relay-specific fixes.
- Endpoint-oriented knobs often seen in one-click landing profiles (`tcp_notsent_lowat`, shorter keepalive, `tcp_fin_timeout`, `tcp_fastopen`) remain optional; recommend after role fit, not by brand name (“Reality终极”).
- Before using a third-party one-click script, pin/download and inspect it, inventory every file/rule it owns, and take a real baseline backup. Never let its rollback replace pre-existing values with guessed distribution defaults. Never auto-run menu-66 style chains (DNS purify + Realm + IPv6 off) without per-step approval.

## Common Mistakes

- Applying `MTU 1440`, `TBF 1000Mbit`, or `256MB`/`64MB` buffers because they appeared in a previous case or a popular script ladder.
- Applying a fixed RAM percentage as TCP/UDP buffer sizing without BDP, concurrency, unit, and memory-pressure checks.
- Assuming every Linux 6.12+ or XanMod kernel supplies BBRv3 just because the module name is `tcp_bbr`.
- Writing only `default_qdisc=fq` and reporting success without checking live `tc -s qdisc`.
- Enabling IPv4 preference, forwarding, conntrack expansion, MSS clamping, RPS/RFS, global million-entry file limits, or permanent IPv6 disable on every host regardless of role and measured pressure.
- Calling removal of owned files plus `cubic/fq_codel` a rollback without restoring the values and rules that existed before the run.
- Running multiple peers concurrently and losing attribution.
- Letting soon-to-expire or non-renewing VPS peers drive persistent tuning for a long-term host.
- Treating absolute retransmit counters as evidence without before/after deltas.
- Assuming qdisc-free retransmits are local queue problems.
- Using TCP iperf results as proof for all UDP/QUIC protocol behavior.
- Killing the current remote SSH shell with `pkill -f` because the iperf pattern appears in the shell script text; prefer iperf3 `--pidfile` and kill that PID only.
- Writing Markdown profile files with unquoted heredocs containing backticks; use quoted heredocs or avoid command-substitution characters.
- Leaving persistent config without a backup path and profile.
- Running `curl | bash` “latest” BBR scripts without pin, SHA, side-effect inventory, or user approval of non-TCP extras (DNS, IPv6, proxy installers).
- Trusting a one-click script's persistence unit because `systemctl status` shows success; a unit can exit 0 without applying anything (TCP-Optimize v2.1 ships such units) — read back live state after reboot instead.
