#!/usr/bin/env bash
# Regression: the snapshot must use ROUTE_TARGET, never a generic default route.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/scripts/backup-snapshot.sh"

if [ ! -d /sys/class/net ]; then
  echo "SKIP: requires Linux"
  exit 0
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "SKIP: requires root because the production snapshot writes /root"
  exit 0
fi

test_root=$(mktemp -d)
backup_roots=()
networkd_fixture=
cleanup() {
  local root
  rm -rf "$test_root"
  [ -z "$networkd_fixture" ] || rm -rf "$networkd_fixture"
  for root in "${backup_roots[@]}"; do
    rm -rf "$root"
  done
}
trap cleanup EXIT
mkdir -p "$test_root/bin"
mkdir -p /etc/systemd/network
networkd_fixture=$(mktemp -d /etc/systemd/network/netriage-test-XXXXXX.network.d)
printf '[DHCPv4]\nInitialCongestionWindow=16\n' > "$networkd_fixture/50-tcpfit-initcwnd.conf"

cat > "$test_root/bin/ip" <<'EOF'
#!/bin/sh
if [ "$1" = "-o" ] && [ "$2" = "route" ] && [ "$3" = "get" ]; then
  dev=netriage-test0
  suffix=""
  if [ "${NETRIAGE_ROUTE_DRIFT:-}" = 1 ] || [ "${NETRIAGE_ROUTE_EXPIRES:-}" = 1 ]; then
    calls_file=${NETRIAGE_ROUTE_CALLS:?}
    calls=$(cat "$calls_file" 2>/dev/null || echo 0)
    calls=$((calls + 1))
    echo "$calls" > "$calls_file"
    if [ "${NETRIAGE_ROUTE_DRIFT:-}" = 1 ]; then
      [ "$calls" -lt 2 ] || dev=netriage-test1
    fi
    if [ "${NETRIAGE_ROUTE_EXPIRES:-}" = 1 ]; then
      suffix=" cache expires $((3 - calls))sec"
    fi
  fi
  echo "$4 via 192.0.2.1 dev $dev src 192.0.2.10$suffix"
fi
EOF

cat > "$test_root/bin/tc" <<'EOF'
#!/bin/sh
case "$*" in
  "-s qdisc show dev netriage-test0")
    [ "${NETRIAGE_FAIL_EGRESS_QDISC:-}" = 1 ] && exit 1
    echo "qdisc fq 0: root"
    ;;
  *qdisc*) echo "qdisc fq 0: root" ;;
  *class*) echo "class htb 1: root" ;;
esac
EOF
chmod +x "$test_root/bin/ip" "$test_root/bin/tc"

run_id="netriage-route-target-test-$$"
backup_root="/root/network-tuning-$run_id"
backup_roots+=("$backup_root")
backup="$backup_root/pre-change"
PATH="$test_root/bin:$PATH" RUN_ID="$run_id" ROUTE_TARGET=203.0.113.9 ROUTE_SOURCE=192.0.2.10 \
  bash "$script" >/dev/null

test "$(cat "$backup/route-target.txt")" = "203.0.113.9"
test "$(cat "$backup/route-source.txt")" = "192.0.2.10"
test "$(cat "$backup/egress-dev.txt")" = "netriage-test0"
cmp "$networkd_fixture/50-tcpfit-initcwnd.conf" "$backup$networkd_fixture/50-tcpfit-initcwnd.conf"
grep -Fqx '203.0.113.9 via 192.0.2.1 dev netriage-test0 src 192.0.2.10' \
  "$backup/ip-route-target.txt"

PATH="$test_root/bin:$PATH" RUN_ID="$run_id" ROUTE_TARGET=203.0.113.9 ROUTE_SOURCE=192.0.2.10 \
  bash "$script" >/dev/null

if PATH="$test_root/bin:$PATH" RUN_ID="$run_id" ROUTE_TARGET=198.51.100.9 \
  bash "$script" >/dev/null 2>&1; then
  echo "snapshot accepted a different route target for the same RUN_ID" >&2
  exit 1
fi

if PATH="$test_root/bin:$PATH" RUN_ID="$run_id" ROUTE_TARGET=203.0.113.9 ROUTE_SOURCE=192.0.2.11 \
  bash "$script" >/dev/null 2>&1; then
  echo "snapshot accepted a different route source for the same RUN_ID" >&2
  exit 1
fi

expiry_run_id="netriage-route-expiry-test-$$"
expiry_backup_root="/root/network-tuning-$expiry_run_id"
backup_roots+=("$expiry_backup_root")
rm -f "$test_root/expiry-calls"
PATH="$test_root/bin:$PATH" RUN_ID="$expiry_run_id" ROUTE_TARGET=203.0.113.9 \
  NETRIAGE_ROUTE_EXPIRES=1 NETRIAGE_ROUTE_CALLS="$test_root/expiry-calls" \
  bash "$script" >/dev/null
test -e "$expiry_backup_root/pre-change/.complete"

drift_run_id="netriage-route-drift-test-$$"
drift_backup_root="/root/network-tuning-$drift_run_id"
backup_roots+=("$drift_backup_root")
rm -f "$test_root/drift-calls"
if PATH="$test_root/bin:$PATH" RUN_ID="$drift_run_id" ROUTE_TARGET=203.0.113.9 \
  NETRIAGE_ROUTE_DRIFT=1 NETRIAGE_ROUTE_CALLS="$test_root/drift-calls" \
  bash "$script" >/dev/null 2>&1; then
  echo "snapshot accepted a drifting route tuple" >&2
  exit 1
fi
test ! -e "$drift_backup_root/pre-change/.complete"

qdisc_run_id="netriage-qdisc-capture-test-$$"
qdisc_backup_root="/root/network-tuning-$qdisc_run_id"
backup_roots+=("$qdisc_backup_root")
if PATH="$test_root/bin:$PATH" RUN_ID="$qdisc_run_id" ROUTE_TARGET=203.0.113.9 \
  NETRIAGE_FAIL_EGRESS_QDISC=1 bash "$script" >/dev/null 2>&1; then
  echo "snapshot accepted missing selected-route qdisc evidence" >&2
  exit 1
fi
test ! -e "$qdisc_backup_root/pre-change/.complete"
