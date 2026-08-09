#!/usr/bin/env bash
# netriage: read-only host inspection.
# Collects the evidence baseline this skill needs before any recommendation.
# Strictly read-only: no sysctl writes, no tc changes, no file modifications.
#
# Usage:
#   ssh <host> bash -s < scripts/inspect.sh
#   ssh <host> bash -s -- <route-target> < scripts/inspect.sh
#   bash scripts/inspect.sh            # on the host itself

set -u
route_target=${1:-1.1.1.1}

section() { printf '\n===== %s =====\n' "$*"; }

show_sysctl() {
  local key
  for key in "$@"; do
    printf '%s = %s\n' "$key" "$(sysctl -n "$key" 2>/dev/null || echo '<absent>')"
  done
}

section "system"
hostname
uname -r
head -5 /etc/os-release 2>/dev/null
uptime
virt=$(systemd-detect-virt 2>/dev/null || true)
printf 'virtualization: %s\n' "${virt:-none/unknown}"
printf 'page size: '; getconf PAGE_SIZE 2>/dev/null || getconf PAGESIZE 2>/dev/null || echo unknown

section "cpu / memory"
lscpu 2>/dev/null | sed -n '1,20p'
nproc
free -h
swapon --show 2>/dev/null || true

section "interfaces / routes"
ip -br addr show
ip route show
ip -6 route show 2>/dev/null | head -20
printf 'route target: %s\n' "$route_target"
ip -o route get "$route_target" 2>/dev/null || true

section "sockets"
ss -s
ss -tlnp 2>/dev/null | head -40
cat /proc/net/sockstat 2>/dev/null || true
cat /proc/net/sockstat6 2>/dev/null || true

section "tcp sysctl"
show_sysctl \
  net.ipv4.tcp_available_congestion_control \
  net.ipv4.tcp_congestion_control \
  net.core.default_qdisc \
  net.core.rmem_max net.core.wmem_max \
  net.core.rmem_default net.core.wmem_default \
  net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
  net.ipv4.tcp_mem net.ipv4.tcp_moderate_rcvbuf \
  net.ipv4.tcp_window_scaling net.ipv4.tcp_adv_win_scale \
  net.core.somaxconn net.ipv4.tcp_max_syn_backlog \
  net.core.netdev_max_backlog net.core.netdev_budget \
  net.core.netdev_budget_usecs net.core.optmem_max \
  net.ipv4.tcp_notsent_lowat net.ipv4.tcp_fastopen \
  net.ipv4.tcp_ecn net.ipv4.tcp_syncookies \
  net.ipv4.tcp_mtu_probing net.ipv4.tcp_slow_start_after_idle \
  net.ipv4.tcp_no_metrics_save net.ipv4.tcp_sack \
  net.ipv4.tcp_dsack net.ipv4.tcp_timestamps \
  net.ipv4.tcp_fin_timeout net.ipv4.tcp_tw_reuse \
  net.ipv4.tcp_keepalive_time net.ipv4.ip_local_port_range \
  net.ipv4.ip_forward net.ipv6.conf.all.forwarding \
  net.ipv6.conf.all.disable_ipv6 \
  net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min net.ipv4.udp_mem \
  vm.min_free_kbytes vm.swappiness fs.file-max

section "live qdisc (root qdisc on egress, not just default_qdisc)"
dev=$(ip -o route get "$route_target" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
echo "egress dev: ${dev:-<unknown>}"
tc -s qdisc show
if [ -n "${dev:-}" ]; then
  section "egress interface evidence"
  ip -s link show dev "$dev" 2>/dev/null
  ethtool -i "$dev" 2>/dev/null
  printf 'link speed: '; cat "/sys/class/net/$dev/speed" 2>/dev/null || echo unknown
  printf 'rx queues: '; find "/sys/class/net/$dev/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | wc -l | tr -d ' '
  printf 'tx queues: '; find "/sys/class/net/$dev/queues" -maxdepth 1 -type d -name 'tx-*' 2>/dev/null | wc -l | tr -d ' '
  for stat in rx_bytes tx_bytes rx_packets tx_packets rx_dropped tx_dropped; do
    printf '%s: ' "$stat"
    cat "/sys/class/net/$dev/statistics/$stat" 2>/dev/null || echo unknown
  done

  section "full qdisc topology (JSON when supported)"
  tc -j -s qdisc show dev "$dev" 2>/dev/null || true
  tc -j -s class show dev "$dev" 2>/dev/null || true
  tc -j -s filter show dev "$dev" 2>/dev/null || true

  section "qdisc classes / filters / offloads"
  tc -s class show dev "$dev" 2>/dev/null
  tc filter show dev "$dev" 2>/dev/null
  ethtool -k "$dev" 2>/dev/null | grep -E 'segmentation|offload' | head -10
fi

section "softirq / rps"
head -3 /proc/net/softnet_stat 2>/dev/null
grep -E 'NET_RX|NET_TX' /proc/softirqs 2>/dev/null
if [ -n "${dev:-}" ]; then
  find "/sys/class/net/$dev/queues" -maxdepth 2 \
    \( -name rps_cpus -o -name rps_flow_cnt -o -name xps_cpus \) \
    -print -exec cat {} \; 2>/dev/null
fi
show_sysctl net.core.rps_sock_flow_entries

section "conntrack"
show_sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max
# -s keeps nstat from writing its /tmp history file (stays read-only)
nstat -azs 2>/dev/null | grep -Ei 'conntrack|listen|retrans|timeout|drop' || true

section "sysctl files"
ls -la /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null
# -L follows symlinks (Debian's 99-sysctl.conf -> /etc/sysctl.conf, symlinked drop-ins)
find -L /etc/sysctl.d -maxdepth 1 -name '*.conf' -print -exec sed -n '1,160p' {} \; 2>/dev/null
grep -En 'tcp_rmem|tcp_wmem|rmem_max|wmem_max|default_qdisc|congestion_control' /etc/sysctl.conf 2>/dev/null || true

section "one-click script artifacts"
# Eric86777/vps-tcp-tune (menu 3 / Realm fix)
ls -la /etc/sysctl.d/99-bbr-ultimate.conf /usr/local/bin/bbr-optimize-apply.sh \
  /etc/systemd/system/bbr-optimize-persist.service \
  /etc/sysctl.d/60-realm-tune.conf /etc/modules-load.d/conntrack.conf 2>/dev/null
systemctl is-enabled bbr-optimize-persist.service 2>/dev/null
# Madhatter2099/TCP-Optimize (v2.x)
ls -la /etc/sysctl.d/10-bbr.conf /etc/sysctl.d/99-network-performance.conf \
  /etc/systemd/system/rps-optimize.service /etc/systemd/system/mss-clamp.service \
  /usr/local/bin/tcp.sh 2>/dev/null
systemctl is-enabled rps-optimize.service 2>/dev/null
systemctl is-enabled mss-clamp.service 2>/dev/null
# Kylin010/tcpfit (and its former nettune name)
ls -la /etc/sysctl.d/99-tcpfit.conf /etc/modules-load.d/tcpfit-bbr.conf \
  /etc/systemd/system/tcpfit-qdisc.service /usr/local/sbin/tcpfit-qdisc.sh \
  /etc/networkd-dispatcher/routable.d/50-tcpfit-initcwnd \
  /var/lib/tcpfit /etc/sysctl.d/99-nettune.conf \
  /etc/systemd/system/nettune-qdisc.service /var/lib/nettune 2>/dev/null
systemctl is-enabled tcpfit-qdisc.service 2>/dev/null
grep -n 'precedence ::ffff:0:0/96' /etc/gai.conf 2>/dev/null
# iptables-save only walks already-loaded tables; a plain `iptables -t mangle -S`
# would auto-load the mangle module and break the read-only promise
iptables-save 2>/dev/null | grep -i tcpmss
# only query nftables when the module is already loaded, for the same reason
if [ -d /sys/module/nf_tables ]; then
  nft list ruleset 2>/dev/null | grep -i mss | head -5
fi

section "services"
systemctl --type=service --state=running --no-pager 2>/dev/null \
  | grep -Ei 'sing-box|xray|realm|gost|nodepass|hysteria|tuic|nginx|caddy|apache|iperf3|qos-agent' || true

section "tuning profiles"
for f in /etc/sysctl.d/*.profile.md; do
  [ -e "$f" ] || continue
  printf -- '--- %s ---\n' "$f"
  sed -n '1,160p' "$f"
done

section "done"
echo "inspection complete (read-only)"
