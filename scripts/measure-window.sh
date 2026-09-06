#!/usr/bin/env bash
# netriage: run one approved test command and report host-counter deltas.
# Measurement-only: does not change sysctl, qdisc, routes, firewall, or services.
# Interface byte deltas include unrelated traffic sharing the same interface.
# Exits 3 when the wrapped command succeeds but its route or tc topology sample
# is invalid, so callers cannot treat a drifting path as a valid measurement.
# --route-source only verifies a route; bind the wrapped client to that same
# source (for example, `iperf3 -B SOURCE_IP`) when the workload does so.
#
# Usage:
#   ./measure-window.sh --route-target LITERAL_PEER_IP [--route-source SOURCE_IP] --label p1-fwd -- \
#     iperf3 -c PEER -p 5201 -t 12 -O 2 -P 1 -J
#   ./measure-window.sh --dev eth0 --route-target LITERAL_PEER_IP --label p4-rev -- iperf3 ... -R -J

set -u

die() { printf 'FATAL: %s\n' "$*" >&2; exit 2; }

dev=""
route_target=""
route_source=""
label=measurement
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dev) [ "$#" -ge 2 ] || die "--dev needs a value"; dev=$2; shift 2 ;;
    --route-target) [ "$#" -ge 2 ] || die "--route-target needs a value"; route_target=$2; shift 2 ;;
    --route-source) [ "$#" -ge 2 ] || die "--route-source needs a value"; route_source=$2; shift 2 ;;
    --label) [ "$#" -ge 2 ] || die "--label needs a value"; label=$2; shift 2 ;;
    --) shift; break ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# *//'; exit 0 ;;
    *) die "unknown option before --: $1" ;;
  esac
done
[ "$#" -gt 0 ] || die "provide a test command after --"
[ -n "$route_target" ] || die "--route-target must be the literal peer IP"
cmd=("$@")

route_get() {
  if [ -n "$route_source" ]; then
    ip -o route get "$route_target" from "$route_source" 2>/dev/null || true
  else
    ip -o route get "$route_target" 2>/dev/null || true
  fi
}

normalize_route_tuple() {
  printf '%s\n' "$1" \
    | sed -E 's/(^|[[:space:]])expires[[:space:]]+[0-9]+sec//g; s/[[:space:]]+/ /g; s/^ //; s/ $//'
}

route_before=$(route_get)
route_tuple_before=$(normalize_route_tuple "$route_before")
route_dev=$(printf '%s\n' "$route_before" \
  | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
if [ -z "$dev" ]; then
  dev=$route_dev
elif [ -z "$route_before" ] || [ -z "$route_dev" ]; then
  die "could not read the route tuple for --route-target"
elif [ "$route_dev" != "$dev" ]; then
  die "--dev $dev does not match route egress device $route_dev"
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

tc_topology_checksum() {
  local topology
  topology=$(
    tc qdisc show dev "$dev" 2>/dev/null || exit 1
    tc class show dev "$dev" 2>/dev/null || exit 1
    tc filter show dev "$dev" 2>/dev/null || exit 1
  ) || return 1
  [ -n "$topology" ] || return 1
  printf '%s\n' "$topology" | LC_ALL=C cksum | awk '{print $1 ":" $2}'
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
before_topology=$(tc_topology_checksum)
started=$(date +%s)

printf '===== netriage measurement: %s =====\n' "$label"
printf 'egress_dev=%s route_target=%s route_source=%s\n' \
  "$dev" "$route_target" "${route_source:-<kernel-selected>}"
printf 'route_before=%s\n' "${route_before:-<unknown>}"
printf 'qdisc_before=%s\n' "${before_qdisc:-<unknown>}"
"${cmd[@]}"
test_status=$?

finished=$(date +%s)
after=$(snapshot)
after_qdisc=$(tc qdisc show dev "$dev" 2>/dev/null | head -1)
after_topology=$(tc_topology_checksum)
route_after=$(route_get)
route_tuple_after=$(normalize_route_tuple "$route_after")

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
printf 'route_after=%s\n' "${route_after:-<unknown>}"
sample_valid=yes
if [ -z "$route_before" ] || [ -z "$route_after" ]; then
  echo 'route_tuple_unchanged=unknown'
  echo 'warning=route tuple could not be read; discard this sample'
  sample_valid=no
elif [ "$route_tuple_before" = "$route_tuple_after" ]; then
  echo 'route_tuple_unchanged=yes'
else
  echo 'route_tuple_unchanged=no'
  echo 'warning=route tuple changed during the window; discard this sample until the path is stable'
  sample_valid=no
fi
printf 'tc_topology_before_checksum=%s tc_topology_after_checksum=%s\n' \
  "${before_topology:-<unknown>}" "${after_topology:-<unknown>}"
if [ -z "$before_topology" ] || [ -z "$after_topology" ]; then
  echo 'tc_topology_unchanged=unknown'
  echo 'warning=tc qdisc/class/filter topology could not be read; discard this sample'
  sample_valid=no
elif [ "$before_topology" = "$after_topology" ]; then
  echo 'tc_topology_unchanged=yes'
else
  echo 'tc_topology_unchanged=no'
  echo 'warning=tc qdisc/class/filter topology changed during the window; do not attribute results until ownership is explained'
  sample_valid=no
fi
printf 'sample_valid=%s\n' "$sample_valid"
printf '%s\n' 'note=use a literal peer IP and preserve the complete iperf3 JSON sample; interface byte deltas include unrelated traffic'

if [ "$test_status" -ne 0 ]; then
  exit "$test_status"
fi
[ "$sample_valid" = yes ] || exit 3
