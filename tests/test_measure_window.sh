#!/usr/bin/env bash
# Regression: a stable mq root with a changed leaf must invalidate the sample.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/scripts/measure-window.sh"

if [ ! -d /sys/class/net/lo/statistics ]; then
  echo "SKIP: requires Linux /sys counters"
  exit 0
fi

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin"
export NETRIAGE_TEST_STATE="$test_root/leaf-changed"

cat > "$test_root/bin/ip" <<'EOF'
#!/bin/sh
echo "198.51.100.10 via 192.0.2.1 dev lo src 192.0.2.10"
EOF

cat > "$test_root/bin/tc" <<'EOF'
#!/bin/sh
case "$*" in
  "-s qdisc show dev lo"|"qdisc show dev lo")
    echo "qdisc mq 0: root"
    if [ -f "$NETRIAGE_TEST_STATE" ]; then
      echo "qdisc fq 0: parent :1"
    else
      echo "qdisc fq_codel 0: parent :1"
    fi
    ;;
  "class show dev lo") echo "class htb 1: root" ;;
  "filter show dev lo") : ;;
esac
EOF
chmod +x "$test_root/bin/ip" "$test_root/bin/tc"

set +e
output=$(PATH="$test_root/bin:$PATH" bash "$script" --dev lo \
  --route-target 198.51.100.10 --route-source 192.0.2.10 --label topology -- \
  bash -c 'touch "$NETRIAGE_TEST_STATE"')
status=$?
set -e

test "$status" -eq 3
grep -Fqx 'qdisc_before=qdisc mq 0: root' <<<"$output"
grep -Fqx 'qdisc_after=qdisc mq 0: root' <<<"$output"
grep -Fqx 'egress_dev=lo route_target=198.51.100.10 route_source=192.0.2.10' <<<"$output"
grep -Fqx 'route_tuple_unchanged=yes' <<<"$output"
grep -Fqx 'tc_topology_unchanged=no' <<<"$output"
grep -Fqx 'sample_valid=no' <<<"$output"

cat > "$test_root/bin/ip" <<'EOF'
#!/bin/sh
calls=$(cat "$NETRIAGE_ROUTE_CALLS" 2>/dev/null || echo 0)
calls=$((calls + 1))
echo "$calls" > "$NETRIAGE_ROUTE_CALLS"
expires=2
[ "$calls" -lt 2 ] || expires=1
echo "198.51.100.10 via 192.0.2.1 dev lo src 192.0.2.10 cache expires ${expires}sec"
EOF
chmod +x "$test_root/bin/ip"
rm -f "$NETRIAGE_TEST_STATE" "$test_root/route-calls"

output=$(NETRIAGE_ROUTE_CALLS="$test_root/route-calls" PATH="$test_root/bin:$PATH" \
  bash "$script" --dev lo --route-target 198.51.100.10 --label volatile-expiry -- true)

grep -Fqx 'route_tuple_unchanged=yes' <<<"$output"
grep -Fqx 'tc_topology_unchanged=yes' <<<"$output"
grep -Fqx 'sample_valid=yes' <<<"$output"

cat > "$test_root/bin/ip" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$test_root/bin/ip"
rm -f "$NETRIAGE_TEST_STATE"

set +e
output=$(PATH="$test_root/bin:$PATH" bash "$script" --dev lo \
  --route-target 198.51.100.10 --label route-unreadable -- true 2>&1)
status=$?
set -e

test "$status" -eq 2
grep -Fqx 'FATAL: could not read the route tuple for --route-target' <<<"$output"

cat > "$test_root/bin/ip" <<'EOF'
#!/bin/sh
echo "198.51.100.10 via 192.0.2.1 dev not-lo src 192.0.2.10"
EOF
chmod +x "$test_root/bin/ip"

set +e
output=$(PATH="$test_root/bin:$PATH" bash "$script" --dev lo \
  --route-target 198.51.100.10 --label wrong-device -- true 2>&1)
status=$?
set -e

test "$status" -eq 2
grep -Fqx 'FATAL: --dev lo does not match route egress device not-lo' <<<"$output"
