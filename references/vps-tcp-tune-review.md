# Eric86777/vps-tcp-tune Review Notes

Source reviewed: [`Eric86777/vps-tcp-tune`](https://github.com/Eric86777/vps-tcp-tune), main script `net-tcp-tune.sh` **v5.4.4** (commit pin the tree you download; this review follows the 2026-07-22 main tip), reviewed 2026-07-22.

Recheck 2026-07-26: upstream is now **v5.4.6** (`44b2870`, 2026-07-23). v5.4.5/v5.4.6 are security hardening only — `mktemp`-randomized temp files for the Xray/sing-box/cloudflared/China-IP downloads and access-key auth for the menu 32-7 Responses proxy — with zero changes to menu 3, the buffer ladder, sysctl values, the Realm fix, menu 66, or the owned artifacts. Everything below remains accurate for v5.4.6.

Use these notes when a user asks to copy, compare, audit, or run that script, or mentions `bbr` one-click, XanMod + BBRv3 menus, menu `3`/`66`, Realm timeout fix, or “一键全自动优化”. They are a static review of the cited revision; re-inspect the current upstream file before acting.

This skill must **not** become a silent wrapper around `curl | bash net-tcp-tune.sh`. Extract reusable workflow ideas, keep evidence gates, and prefer recommendation-before-apply.

## What the Script Is

- A large interactive **VPS toolbox** (~25k lines), not a pure TCP skill.
- Core network path (author-recommended): install **XanMod + BBR v3** (menu 1, reboot) → **BBR 直连/落地** (menu 3, bandwidth + region → buffer) → optional DNS purify / Realm fix / IPv6 disable.
- Menu **66** auto-chains: kernel install (phase 1) then `bbr_configure_direct` → DNS 国外模式 → `realm_fix_timeout` → optional permanent IPv6 disable.
- Also ships proxy installers, IP quality tools, port billing (menu 33), Cloudflare Tunnel, etc. Those are out of scope for this skill unless the user explicitly asks.

Owned artifacts commonly created by menu 3 (inventory before any apply/rollback):

| Path | Role |
| --- | --- |
| `/etc/sysctl.d/99-bbr-ultimate.conf` | Main BBR/fq/buffer/sysctl profile |
| `/etc/sysctl.conf.bak.original`, `.bak.conflict` | Backups / conflict comments |
| `/usr/local/bin/bbr-optimize-apply.sh` | Boot restore: live `fq`, MSS clamp, THP, initcwnd, RPS/RFS |
| `/etc/systemd/system/bbr-optimize-persist.service` | Enables the apply script on boot |
| `/etc/security/limits.conf` append (`* soft/hard nofile 524288`) | Global FD ceiling |
| Realm path extras | `/etc/sysctl.d/60-realm-tune.conf`, `/etc/modules-load.d/conntrack.conf`, `/etc/systemd/system/realm.service.d/override.conf`, edits to `/etc/realm/config.json` |

## Ideas Worth Reusing

### 1. Bandwidth × region buffer ladders (not fixed %RAM)

Menu 3 estimates upload Mbps (speedtest or manual tier), then picks a **region**:

- **asia** (港/日/新/韩, RTT often &lt; 100ms): smaller ceilings.
- **overseas** (US/EU, RTT often 150–300ms): larger ceilings, hard cap **64 MiB**.

Author presets (Mbps → buffer MiB):

| Bandwidth tier | Asia buffer | Overseas buffer |
| --- | ---: | ---: |
| 100 | 6 | 8 |
| 200 | 8 | 16 |
| 300 | 10 | 20 |
| 500 | 12 | 32 |
| 700 | 14 | 48 |
| 1000 | 16 | 64 |
| 1500 | 20 | 64 |
| 2000 | 24 | 64 |
| 2500 | 28 | 64 |
| non-preset ranges | 8–32 (stepped) | 16–64 (stepped, cap 64) |

Skill treatment:

- Treat the table as a **candidate BDP-informed ladder**, not a mandatory default.
- Prefer real path RTT/BDP from durable peers + memory/concurrency over Ookla alone.
- Cap buffers by free RAM and concurrent flows; do not hide loss with huge windows.
- When the user already knows port speed, **manual tier** beats flaky public speedtests.

Rough BDP check (bytes):

```text
BDP ≈ bandwidth_Mbps * RTT_ms * 125
# 500 Mbps × 40 ms  ≈ 2.5 MiB
# 500 Mbps × 200 ms ≈ 12.5 MiB
# 1000 Mbps × 200 ms ≈ 25 MiB
```

Overseas 2.5×-ish headroom and a 64 MiB cap is reasonable as an upper candidate; asia values are often enough for short RTT landing/relay hops.

### 2. Live `fq` + boot persistence (not only `default_qdisc`)

Writing `net.core.default_qdisc=fq` does not retarget an already-created root qdisc. The script:

1. `tc qdisc replace dev <eligible> root fq` immediately.
2. Installs a oneshot systemd unit to re-apply after boot.

Skill treatment: when recommending `fq`, include **live** `tc` verification and a **persistence** plan (systemd oneshot, networkd, or distro-native). Skip virtual/tunnel ifaces (`lo`, `docker*`, `veth*`, `br-*`, `wg*`, `tun*`, …) unless the user wants shaping there.

### 3. sysctl conflict hygiene

Before writing a consolidated drop-in:

- Backup `/etc/sysctl.conf` once.
- Comment conflicting `tcp_rmem`/`tcp_wmem`/`rmem_max`/`wmem_max`/`default_qdisc`/`tcp_congestion_control` lines in `/etc/sysctl.conf`.
- Detect higher-priority `/etc/sysctl.d/99+` files that re-set the same keys; disable/rename only with inventory + backup.

Skill treatment: keep this; never “clean conflicts” without listing files and asking when permission is inspect-only.

### 4. Prefer `tcp_mtu_probing` over cargo-cult interface MTU 1440

The script removed standalone MTU rewrite in favor of `net.ipv4.tcp_mtu_probing=1` and optional FORWARD MSS clamp. Legacy `mtu-optimize` units are auto-cleaned.

Skill treatment:

- Keep PMTU ladder tests for real peers first.
- Use `tcp_mtu_probing` as a **TCP-only** candidate when black holes exist.
- MSS clamp only on **forwarding/tunnel** roles with evidence; persist with the host’s firewall owner (iptables-persistent / nft / firewalld), not a silent mangle rule alone.

### 5. Read-back verification after apply

Menu 3 checks live: congestion control, default qdisc, buffer bytes, `initcwnd`, and RPS masks. Prefer this pattern over “file written = success”.

### 6. Role-specific extras (optional modules)

| Module | Reusable idea | Gate |
| --- | --- | --- |
| Realm fix | Load/persist `nf_conntrack`; raise `nf_conntrack_max` when NAT/forward tables pressure; realm `resolve=ipv4`, `nodelay`, `reuse_port`; per-unit `LimitNOFILE` | Only if Realm (or equivalent relay) is actually used and counts/pressure justify it |
| Low-spec profile | Smaller buffers (e.g. 8 MiB), lower somaxconn/backlog on 512MB–1GB hosts | Free memory / OOM risk |
| Reality-ish knobs | `tcp_notsent_lowat=16384`, shorter keepalive, `tcp_fin_timeout=15`, `tcp_fastopen=3` | Endpoint/proxy TLS chatty workloads; measure before keep |
| IPv4 preference / IPv6 disable | gai.conf / disable IPv6 | Only after dual-stack comparison; never default-disable IPv6 on dual-stack production without approval |
| Global `nofile 524288` | Convenience for many sockets | Prefer per-service `LimitNOFILE` when one daemon is the limit |

### 7. Author recommended flow vs skill flow

Script author flow: kernel → menu 3 → (optional) DNS/Realm/IPv6.

Skill flow stays: **question → inspect → durable-peer tests → recommend → approve → apply → verify → profile**.

If the user wants “按 Eric 脚本那套做”, map:

1. Kernel provenance / BBR availability (do not claim BBRv3 from `uname` alone).
2. Bandwidth + **service_region** → candidate buffer table.
3. Conflict scan + consolidated `/etc/sysctl.d/*.conf`.
4. Live fq + optional MSS clamp with persistence.
5. Optional Realm/conntrack only when role matches.
6. Explicit non-goals: do not auto-run DNS purify, permanent IPv6 off, or menu 66 side effects unless requested.

## Do Not Adopt as Universal Defaults

| Upstream behavior | Skill treatment |
| --- | --- |
| One-click menu 66 (DNS 国外 + Realm + optional IPv6 off) | Never auto-chain; each step needs role evidence and approval |
| `curl \| bash` / always-latest alias | Pin URL+commit or download, SHA-256, offline inspect first |
| Calling every BBR install “BBRv3” | Verify XanMod/package docs or BBR implementation; sysctl name stays `bbr` |
| Overseas buffers always up to 64 MiB | Check RAM, concurrency, measured RTT; cap for small VPS |
| Always enable MSS clamp on FORWARD | Need forwarding/tunnel + PMTU evidence; nft-only hosts need nft form |
| Always set `initcwnd/initrwnd=32` on default route | Candidate only; may be reset by DHCP/NetworkManager; verify after reboot/route change |
| RPS mask = all CPUs on every “physical” NIC | Check RSS/IRQ/softnet first; `2**nproc-1` breaks for large CPU counts / multi-word masks |
| Global `* nofile 524288` | Prefer unit drop-ins for the busy service |
| `vm.overcommit_memory=1`, THP `never`, `sched_autogroup_enabled=0` | Host-wide; require explicit approval and workload justification |
| Hardcode `nf_conntrack_max=262144` for Realm | Size from count/max and insert/drop pressure |
| Force Realm `resolve=ipv4` and rewrite `::` listen | Breaks IPv6-only designs; ask first |
| Permanent IPv6 disable as part of “full optimize” | High-risk; dual-stack comparison + approval |
| Temporary “Reality终极” via `sysctl -w` only | Warn that reboot restores drop-in files; prefer durable recommendation files |

## Suggested Candidate Knobs (Landing / Direct Endpoint)

When evidence supports a **landing/exit/web** profile similar to menu 3, a conservative starting *candidate* (still subject to measurement) looks like:

```conf
# example candidate only — fill BUFFER_BYTES from BDP/region table + memory cap
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=${BUFFER_BYTES}
net.core.wmem_max=${BUFFER_BYTES}
net.ipv4.tcp_rmem=4096 87380 ${BUFFER_BYTES}
net.ipv4.tcp_wmem=4096 65536 ${BUFFER_BYTES}
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192
net.core.netdev_max_backlog=5000
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.tcp_syncookies=1
```

Plus **live** actions when approved:

```bash
# eligible physical NICs only
tc qdisc replace dev "$dev" root fq
# optional, forwarding roles only:
# iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

Relay-heavy hosts may need less aggressive endpoint knobs and more attention to forward path, conntrack, and shaping evidence.

## Inspection Additions When Comparing to This Script

```bash
# ownership from a previous Eric run
ls -la /etc/sysctl.d/99-bbr-ultimate.conf /usr/local/bin/bbr-optimize-apply.sh \
  /etc/systemd/system/bbr-optimize-persist.service 2>/dev/null
systemctl is-enabled bbr-optimize-persist.service 2>/dev/null
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc \
  net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
  net.ipv4.tcp_mtu_probing net.ipv4.tcp_notsent_lowat
ip route show default
tc -s qdisc show
# dual-stack / IPv6 disable leftovers
sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null
ls /etc/sysctl.d/*disable-ipv6* 2>/dev/null
```

## Evidence Gate Summary

| Decision | Minimum evidence |
| --- | --- |
| Buffer size from Asia/Overseas table | Advertised or measured bandwidth + RTT class of **real** user path; memory headroom |
| BBR + fq | `tcp_available_congestion_control` contains bbr; live qdisc after apply; useful iperf/path result |
| Kernel / XanMod install | User allows reboot; understand vendor kernel swap risk |
| MSS clamp | Forward/tunnel role + PMTU/MSS problem |
| initcwnd 32 | Optional after baseline; re-check after DHCP/reboot |
| RPS/RFS | Multi-vCPU, softnet/IRQ concentration, insufficient RSS |
| Realm/conntrack pack | Realm (or heavy NAT relay) present; conntrack pressure |
| Disable IPv6 / force IPv4 | Dual-stack comparison; no IPv6-only dependency |
| Run upstream script as-is | User explicitly wants the toolbox; pin version (**≥ v5.4.6** — earlier versions used predictable `/tmp` paths for downloaded payloads, a local symlink-attack surface); full backup; list side effects (DNS, IPv6, proxy menus) |

## Primary References

- Upstream: https://github.com/Eric86777/vps-tcp-tune
- Kernel IP sysctl: https://docs.kernel.org/networking/ip-sysctl.html
- Scaling (RPS/RFS): https://docs.kernel.org/networking/scaling.html
- Google BBR: https://github.com/google/bbr
