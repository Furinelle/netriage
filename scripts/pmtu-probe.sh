#!/usr/bin/env bash
# netriage: read-only IPv4 PMTU probe toward one peer.
# Probes a DF-set ping payload ladder; payload + 28 = IPv4 MTU equivalent.
# Requires Linux iputils ping (-M do). busybox/BSD ping lack that option —
# there every rung shows FAIL, which means "no data", not a black hole.
#
# Usage: bash scripts/pmtu-probe.sh <peer> [start_payload]
#   start_payload defaults to 1472 (MTU 1500). The start value itself is
#   probed first, then the ladder rungs below it.

set -u
peer=${1:?usage: pmtu-probe.sh <peer> [start_payload]}
start=${2:-1472}

case $start in
  ''|*[!0-9]*) echo "start_payload must be an integer, got: $start" >&2; exit 1 ;;
esac

if ! ping -M do -s 56 -c 1 -W 2 "$peer" >/dev/null 2>&1; then
  echo "warning: baseline ping failed — ICMP may be blocked, or this ping lacks '-M do' (busybox/BSD)."
  echo "         all-FAIL below means NO DATA, not a PMTU black hole."
fi

if command -v tracepath >/dev/null 2>&1; then
  tracepath -n "$peer" | head -15
fi

probe() {
  s=$1
  mtu=$((s + 28))
  if ping -M do -s "$s" -c 2 -W 2 "$peer" >/dev/null 2>&1; then
    echo "payload=$s mtu=$mtu OK"
  else
    echo "payload=$s mtu=$mtu FAIL"
  fi
}

probe "$start"
floor=1292
if [ "$start" -lt "$floor" ]; then
  echo "note: start below ladder floor ($floor); probed the start value only."
fi
for s in 1472 1464 1452 1432 1412 1392 1372 1352 1332 1312 1292; do
  [ "$s" -ge "$start" ] && continue
  probe "$s"
done

echo "note: interpret with the MTU decision chain in references/blog-method.md;"
echo "a TCP-only black hole prefers tcp_mtu_probing over rewriting interface MTU."
