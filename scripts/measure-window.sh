#!/usr/bin/env bash
# netriage: run one approved test command and report host-counter deltas.
# Measurement-only: does not change sysctl, qdisc, routes, firewall, or services.
# Interface byte deltas include unrelated traffic sharing the same interface.
#
# Usage:
#   ./measure-window.sh --route-target PEER --label p1-fwd -- \
#     iperf3 -c PEER -p 5201 -t 12 -O 2 -P 1 -J
#   ./measure-window.sh --dev eth0 --label p4-rev -- iperf3 ... -R -J

set -u

die() { printf 'FATAL: %s\n' "$*" >&2; exit 2; }

dev=""
route_target=1.1.1.1
label=measurement
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dev) [ "$#" -ge 2 ] || die "--dev needs a value"; dev=$2; shift 2 ;;
    --route-target) [ "$#" -ge 2 ] || die "--route-target needs a value"; route_target=$2; shift 2 ;;
    --label) [ "$#" -ge 2 ] || die "--label needs a value"; label=$2; shift 2 ;;
    --) shift; break ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# *//'; exit 0 ;;
    *) die "unknown option before --: $1" ;;
  esac
done
[ "$#" -gt 0 ] || die "provide a test command after --"
cmd=("$@")

if [ -z "$dev" ]; then
  dev=$(ip -o route get "$route_target" 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
fi
[ -n "$dev" ] || die "could not determine egress interface"
[ -d "/sys/class/net/$dev/statistics" ] || die "interface not found: $dev"

read_counter() {
  local value
  value=$(cat "$1" 2>/dev/null || true)
  case "$value" in ''|*[!0-9]*) echo 0 ;; *) echo "$value" ;; esac
}

tcp_snmp() {
  local key=$1
  awk -v wanted="$key" '
    $1 == "Tcp:" && ++row == 1 {
      for (i=2; i<=NF; i++) if ($i == wanted) column=i
      next
    }
    $1 == "Tcp:" && row == 2 {
      if (column) print $column; else print 0
      exit
    }
  ' /proc/net/snmp 2>/dev/null
}

qdisc_sum() {
  local field=$1
  tc -s qdisc show dev "$dev" 2>/dev/null | awk -v wanted="$field" '
    {
      for (i=1; i<NF; i++) if ($i == wanted) {
        value=$(i+1); gsub(/[^0-9]/, "", value); sum += value
      }
    }
    END { print sum+0 }
  '
}

softnet_totals() {
  local _processed dropped squeezed _rest drop_total=0 squeeze_total=0
  while read -r _processed dropped squeezed _rest; do
    [ -n "${dropped:-}" ] || continue
    drop_total=$((drop_total + 16#$dropped))
    squeeze_total=$((squeeze_total + 16#$squeezed))
  done < /proc/net/softnet_stat
  printf '%s %s\n' "$drop_total" "$squeeze_total"
}

snapshot() {
  local soft_drop soft_squeeze
  read -r soft_drop soft_squeeze <<EOF
$(softnet_totals)
EOF
  printf '%s %s %s %s %s %s %s %s %s\n' \
    "$(read_counter "/sys/class/net/$dev/statistics/rx_bytes")" \
    "$(read_counter "/sys/class/net/$dev/statistics/tx_bytes")" \
    "$(tcp_snmp RetransSegs)" \
    "$(tcp_snmp OutSegs)" \
    "$(qdisc_sum dropped)" \
    "$(qdisc_sum overlimits)" \
    "$(qdisc_sum requeues)" \
    "$soft_drop" "$soft_squeeze"
}

before=$(snapshot)
before_qdisc=$(tc qdisc show dev "$dev" 2>/dev/null | head -1)
started=$(date +%s)

printf '===== netriage measurement: %s =====\n' "$label"
printf 'egress_dev=%s route_target=%s\n' "$dev" "$route_target"
printf 'qdisc_before=%s\n' "${before_qdisc:-<unknown>}"
"${cmd[@]}"
test_status=$?

finished=$(date +%s)
after=$(snapshot)
after_qdisc=$(tc qdisc show dev "$dev" 2>/dev/null | head -1)

read -r brx btx bretrans bout bdrop bover brequeue bsoftdrop bsoftsqueeze <<EOF
$before
EOF
read -r arx atx aretrans aout adrop aover arequeue asoftdrop asoftsqueeze <<EOF
$after
EOF

rx_delta=$((arx - brx)); tx_delta=$((atx - btx))
total_delta=$((rx_delta + tx_delta))
printf '%s\n' '----- counter deltas -----'
printf 'duration_seconds=%s test_exit_status=%s\n' "$((finished - started))" "$test_status"
printf 'rx_bytes_delta=%s tx_bytes_delta=%s total_interface_bytes_delta=%s\n' \
  "$rx_delta" "$tx_delta" "$total_delta"
awk -v bytes="$total_delta" 'BEGIN { printf "total_interface_gib_delta=%.4f\n", bytes/1073741824 }'
printf 'tcp_retrans_segs_delta=%s tcp_out_segs_delta=%s\n' \
  "$((aretrans - bretrans))" "$((aout - bout))"
printf 'qdisc_dropped_delta=%s qdisc_overlimits_delta=%s qdisc_requeues_delta=%s\n' \
  "$((adrop - bdrop))" "$((aover - bover))" "$((arequeue - brequeue))"
printf 'softnet_dropped_delta=%s softnet_time_squeeze_delta=%s\n' \
  "$((asoftdrop - bsoftdrop))" "$((asoftsqueeze - bsoftsqueeze))"
printf 'qdisc_after=%s\n' "${after_qdisc:-<unknown>}"
if [ "$before_qdisc" = "$after_qdisc" ]; then
  echo 'qdisc_definition_unchanged=yes'
else
  echo 'qdisc_definition_unchanged=no'
  echo 'warning=qdisc definition changed during the window; do not attribute results until ownership is explained'
fi
printf '%s\n' 'note=interface byte deltas include unrelated traffic; compare qdisc strings and peer output before attributing changes'

exit "$test_status"
