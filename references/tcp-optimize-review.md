# TCP-Optimize Review Notes

Source reviewed: [`Madhatter2099/TCP-Optimize`](https://github.com/Madhatter2099/TCP-Optimize), `tcp.sh` at commit [`e43b4ba`](https://github.com/Madhatter2099/TCP-Optimize/blob/e43b4ba0a6ac0c4474bdd3b0ba7b5d7c902627cb/tcp.sh), reviewed 2026-07-12.

Recheck 2026-07-26: upstream `main` is now `c508c1e` (2026-07-13); `tcp.sh` was rewritten from v2.0 (501 lines) to "v2.1 (Enhanced)" (750 lines, sha256 `dcf8ea91694232d303f7e70493d74ec03bd0717cfbab22e4eaa295c4a38dcfff`). The sections below describe v2.0 unless marked; the dated addendum near the end covers what v2.1 changed.

Use these notes when a user asks to copy, compare, audit, or run that script. They are a static review of the cited commits; inspect the current upstream revision again before acting.

## Ideas Worth Reusing

- Separate features into visible modules: IPv4 address preference, BBR/fq, broader kernel tuning, RPS/RFS, update, and rollback.
- Show effective live state instead of reporting only that a file was written.
- Check BBR availability with `modprobe` plus `tcp_available_congestion_control`.
- Load `nf_conntrack` before reading or applying its sysctls.
- Inspect RX queues and expose RPS/RFS as a separate decision rather than burying it in sysctl.
- Make cleanup explicit and keep an inventory of created files, symlinks, and firewall rules.
- Snapshot live state before and after a change and compare (v2.1's benchmark module moves this way; pair it with the qdisc/counter deltas this skill already requires).

These are workflow patterns. Their concrete values still require host-role and path evidence.

## Do Not Adopt as Universal Defaults

| Upstream behavior | Skill treatment |
| --- | --- |
| TCP socket ceilings equal 5% of RAM, capped at 256 MiB | Estimate BDP and concurrency first; use memory as a safety bound. |
| `udp_mem = 65536 131072 262144` described like ordinary buffer bytes (v2.1 profiles double it to `131072 262144 524288`) | `udp_mem` uses pages and is calculated at boot by default; inspect real UDP pressure before overriding. |
| `somaxconn=65535`, `netdev_max_backlog=65535`, global `nofile=1048576` | Require listen/drop/softnet/service-limit evidence. |
| Enable IPv4 forwarding and IPv6 forwarding in the general profile | Enable only for an actual router/relay role. |
| Add global iptables TCPMSS clamp whenever iptables exists | Require forwarding/tunnel PMTU evidence and use the host's persistent firewall owner. |
| Enable `tcp_mtu_probing=1` for every host | Treat as a candidate for observed PMTUD black holes; it is TCP-specific. |
| Resize conntrack and its buckets only from total RAM | Inspect NAT/firewall use, count/max ratio, insert failures, drops, and boot persistence. |
| Apply RPS to every interface and all CPUs | Check RSS/RX queues, IRQ affinity, per-CPU softirq load, NUMA/locality, and valid bitmap width. |
| Infer BBRv3 from kernel version `>= 6.12` (fixed upstream in v2.1, which now states mainline ships BBRv1) | Keep the principle: verify kernel provenance or patch/package documentation; the sysctl value alone identifies `bbr`, not its generation. |
| Roll back to `cubic + fq_codel` (unchanged in v2.1) | Restore the captured pre-change values and files instead of guessing defaults. |
| v2.1 workload profiles (option 8) write `ip_forward=1` and call the MSS clamp for every role, web/game included | Enable forwarding and clamping only for actual router/relay/tunnel roles with evidence. |
| v2.1 "maximum throughput" profile hardcodes 256 MiB `tcp_rmem`/`tcp_wmem` ceilings regardless of RAM | Size from BDP and memory headroom; 256 MiB on a small VPS invites memory pressure/OOM. |
| v2.1 `rps-optimize.service` / `mss-clamp.service` persistence | Broken as shipped (see addendum): the unit exits 0 without applying anything — verify post-reboot state, never trust unit status. |

## Static Implementation Findings

### Live qdisc versus default qdisc

Writing `net.core.default_qdisc=fq` does not prove the already-created external interface now has `fq`. Verify with:

```bash
dev=$(ip -o route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
sysctl -n net.core.default_qdisc
tc -s qdisc show dev "$dev"
```

If an explicit live replacement is recommended, provide a persistent systemd/network-manager/networkd mechanism and rollback for that interface.

### IPv4 preference semantics

`/etc/gai.conf` controls address sorting used by libc `getaddrinfo`. It does not make a DNS server return only A records. Compare both families to the real service before recommending a preference:

```bash
getent ahosts <hostname>
ping -4 -c 5 <hostname>
ping -6 -c 5 <hostname>
curl -4 -o /dev/null -sS -w 'v4 connect=%{time_connect} total=%{time_total}\n' https://<hostname>/
curl -6 -o /dev/null -sS -w 'v6 connect=%{time_connect} total=%{time_total}\n' https://<hostname>/
```

### RPS/RFS correctness

The reviewed script computes the CPU mask with shell arithmetic and applies it broadly. That approach becomes fragile for large CPU counts, may include unsuitable interfaces, and reports an interface configured even if no queue file was successfully changed.

Collect this first:

```bash
nproc
find /sys/class/net/<dev>/queues -maxdepth 1 -type d -printf '%f\n'
grep -Ei '<dev>|virtio' /proc/interrupts
grep -E 'NET_RX|NET_TX' /proc/softirqs
cat /proc/net/softnet_stat
```

Kernel guidance says RPS can be redundant when RSS already maps a receive queue per CPU. For RFS, configure the global table and per-queue tables consistently; on a single RX queue, the per-queue value would normally match the global value.

### Configuration ownership and rollback

Before using any external tuning script, capture:

```bash
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
backup=/root/network-tuning-$RUN_ID/pre-script
mkdir -p "$backup"
cp -a /etc/sysctl.conf /etc/sysctl.d /etc/security/limits.d /etc/gai.conf "$backup"/ 2>/dev/null || true
sysctl -a > "$backup/sysctl-a.txt" 2>/dev/null || true
tc -s qdisc show > "$backup/tc-qdisc.txt"
iptables-save > "$backup/iptables-save.txt" 2>/dev/null || true
nft list ruleset > "$backup/nft-ruleset.txt" 2>/dev/null || true
```

Also record the exact script commit and SHA-256. Prefer a downloaded, inspected file over a moving `curl | bash` target.

## Evidence Gate for Each Extra Module

| Module | Minimum evidence before recommending apply |
| --- | --- |
| IPv4 preference | Real service IPv6 is broken or consistently worse; no IPv6-only dependency. |
| Queue/backlog expansion | Listen overflow, softnet drop/squeeze, or queue pressure during the critical workload. |
| Conntrack expansion | Host uses conntrack and count/insert/drop evidence approaches the effective limit. |
| RPS/RFS | Multi-vCPU, insufficient RX queues, concentrated NET_RX/IRQ load, and improved controlled retest. |
| MSS clamp | Forwarded/tunneled TCP path has a demonstrated PMTU/MSS problem. |
| Global/per-service limits | Actual daemon or accept path approaches the current limit. |

## 2026-07-26 Addendum: v2.1 (`c508c1e`)

Seven commits on 2026-07-13 rewrote `tcp.sh` (501 → 750 lines) and the README; no commits since. Pin against sha256 `dcf8ea91694232d303f7e70493d74ec03bd0717cfbab22e4eaa295c4a38dcfff` when downloading.

### Fixed upstream

The BBRv3-from-kernel-version claim is gone: `enable_bbr` now states that mainline kernels ship BBRv1 (with some v2-era improvements) and that BBRv3 requires Google's patches or custom kernels (XanMod/zen). The generic rule stands: the sysctl name is `bbr` for every generation.

### Persistence services are broken as shipped

v2.1 installs `rps-optimize.service` and `mss-clamp.service` (oneshot, `ExecStart=/usr/local/bin/tcp.sh --apply-rps|--apply-mss`). The argument-dispatch block sits at the top of the script, before the functions it calls are defined; bash does not hoist function definitions, so:

```console
$ bash tcp.sh --apply-rps
tcp.sh: line 18: optimize_nic: command not found
$ echo $?
0
```

The unit reports success while applying nothing — after reboot, RPS/MSS state silently reverts. Even if the ordering were fixed, the called functions contain interactive `read` prompts and a `systemctl start` of the same service, risking recursion/hangs in a service context. Skill guidance: persistence units must inline concrete commands (or call a dedicated non-interactive script), and post-reboot state must be read back instead of trusting `systemctl status`.

### Workload profiles (option 8)

Four templates (light web / high-concurrency proxy / game low-latency / maximum throughput), all writing the shared `/etc/sysctl.d/99-network-performance.conf`. Recurring problems: every profile sets `net.ipv4.ip_forward=1` and calls the MSS clamp regardless of role; the max-throughput profile pins 256 MiB buffer ceilings without checking RAM; `udp_mem` is hardcoded (doubled vs v2.0) and still treated as bytes although the unit is pages. The upstream README now recommends option 8 to new users, which raises the odds that a host you inspect carries these values.

### Benchmark module (option 9)

Reads live sysctl/conntrack/gai state, pings a hardcoded `1.1.1.1`, and prints suggested verification commands — a real step toward "show effective state", but it still reads only `net.core.default_qdisc` (never `tc qdisc show dev <egress>`) and does not test the user's real path. Keep this skill's per-interface qdisc verification and peer-based tests.

### Rollback and hygiene

- `rollback_all` still restores guessed `cubic + fq_codel` rather than captured pre-change values; v2.1 adds `remove_all_persistence` for the two services.
- Cross-version gap: v2.0 wrote `precedence ::ffff:0:0/96  100` (two spaces) into `gai.conf`; v2.1's state detection and sed-based rollback match only the single-space form, so a v2.0-era line is invisible to v2.1 when `/etc/gai.conf.bak` is missing.
- The header comment advertises "iptables/nftables MSS Clamp" but only iptables is implemented, and the dead `SYSCTL_BBR` variable now points at `rps-optimize.service` with a misleading comment — read the code, not the comments.

### Ownership inventory for inspection

When checking whether a host previously ran this script, look for: `/etc/sysctl.d/10-bbr.conf`, `/etc/sysctl.d/99-network-performance.conf`, `/etc/systemd/system/rps-optimize.service`, `/etc/systemd/system/mss-clamp.service`, `/usr/local/bin/tcp.sh`, `gai.conf` precedence lines (either spacing), and iptables mangle TCPMSS rules. `scripts/inspect.sh` covers these.

## Primary References

- [Linux kernel IP sysctl documentation](https://docs.kernel.org/networking/ip-sysctl.html)
- [Linux kernel networking scaling documentation](https://docs.kernel.org/networking/scaling.html)
- [Google BBR repository and v3 branch](https://github.com/google/bbr)
