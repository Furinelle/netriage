#!/usr/bin/env bash
# netriage: pre-change configuration snapshot.
# Creates a timestamped backup under /root/network-tuning-<RUN_ID>/pre-change.
# Run on the target host AFTER the user approves a recommendation and BEFORE
# writing any persistent change. Copies state; modifies nothing else.
# Exits non-zero if the snapshot could not be created — treat that as a hard
# stop: do NOT apply persistent changes without a verified snapshot.
#
# Restore notes:
# - sysctl.d is a directory snapshot. Rolling back must also REMOVE conf files
#   added after the snapshot, e.g.: rsync -a --delete "$backup/sysctl.d/" /etc/sysctl.d/
# - One-click tool files are copied with their path hierarchy preserved under
#   "$backup" (e.g. $backup/etc/systemd/system/...), so restore is a plain copy back.
#
# Usage: bash scripts/backup-snapshot.sh
#   Honors an existing RUN_ID env var so the whole run shares one directory.
#   ROUTE_TARGET is the required literal representative peer IP used to select
#   the egress qdisc/class/filter snapshot. Set optional ROUTE_SOURCE when the
#   service binds a source IP; a RUN_ID cannot be reused for a different tuple.
#   Optional PLANNED_PATHS_FILE points to a newline-delimited list of absolute
#   paths the approved change may write/delete; their pre-run state is recorded.

set -u
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
case $RUN_ID in
  *[!A-Za-z0-9._-]*) echo "FATAL: RUN_ID may only contain [A-Za-z0-9._-], got: $RUN_ID" >&2; exit 1 ;;
esac
route_target=${ROUTE_TARGET:-}
route_source=${ROUTE_SOURCE:-}
[ -n "$route_target" ] || {
  echo "FATAL: set ROUTE_TARGET to the literal representative peer IP" >&2
  exit 1
}
route_lookup() {
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
route_get=$(route_lookup)
route_tuple=$(normalize_route_tuple "$route_get")
dev=$(printf '%s\n' "$route_get" \
  | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
[ -n "$dev" ] || {
  echo "FATAL: could not resolve an egress device for ROUTE_TARGET=$route_target" >&2
  exit 1
}

backup=/root/network-tuning-$RUN_ID/pre-change
if [ -f "$backup/.complete" ]; then
  if [ ! -s "$backup/route-target.txt" ]; then
    echo "FATAL: existing snapshot predates route-target binding; choose a new RUN_ID" >&2
    exit 1
  fi
  if [ ! -e "$backup/route-source.txt" ]; then
    echo "FATAL: existing snapshot predates route-source binding; choose a new RUN_ID" >&2
    exit 1
  fi
  existing_route_target=$(tr -d '\r\n' < "$backup/route-target.txt")
  if [ "$existing_route_target" != "$route_target" ]; then
    echo "FATAL: $backup belongs to ROUTE_TARGET=$existing_route_target, not $route_target" >&2
    exit 1
  fi
  existing_route_source=$(tr -d '\r\n' < "$backup/route-source.txt")
  if [ "$existing_route_source" != "$route_source" ]; then
    echo "FATAL: $backup belongs to ROUTE_SOURCE=${existing_route_source:-<kernel-selected>}, not ${route_source:-<kernel-selected>}" >&2
    exit 1
  fi
  if [ -s "$backup/sysctl-a.txt" ] && [ -s "$backup/tc-qdisc.txt" ] \
    && [ -s "$backup/ip-route-target.txt" ] && [ -s "$backup/tc-qdisc-egress.txt" ] \
    && [ -e "$backup/sysctl.d" ] \
    && [ -s "$backup/SHA256SUMS" ] \
    && (cd "$backup" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
    echo "existing complete snapshot retained: $backup"
    exit 0
  fi
  echo "FATAL: $backup is marked complete but essential artifacts are missing" >&2
  exit 1
fi
if [ -d "$backup" ] && find "$backup" -mindepth 1 -print -quit | grep -q .; then
  echo "FATAL: partial snapshot already exists at $backup — choose a new RUN_ID or inspect it manually" >&2
  exit 1
fi
mkdir -p "$backup" || { echo "FATAL: cannot create $backup" >&2; exit 1; }

cp -a /etc/sysctl.conf "$backup"/ 2>/dev/null || true
cp -a /etc/sysctl.d "$backup"/ 2>/dev/null || true
cp -a /etc/security/limits.conf /etc/security/limits.d "$backup"/ 2>/dev/null || true
cp -a /etc/gai.conf "$backup"/ 2>/dev/null || true
cp -a /etc/fstab "$backup"/ 2>/dev/null || true

cat > "$backup/RESTORE-NOTES.txt" <<'EOF'
This directory is a pre-run evidence bundle. tc/ip JSON and text are diagnostic
snapshots, not a generic executable restore format. Before changing a classful
or custom qdisc, the recommendation must include an authoritative owner/config
and exact tested rebuild commands. Rollback succeeds only after live read-back.
The selected qdisc/class/filter evidence is for the representative route target
recorded in route-target.txt; it is not necessarily the default Internet path.
EOF

if [ -n "${PLANNED_PATHS_FILE:-}" ]; then
  [ -f "$PLANNED_PATHS_FILE" ] \
    || { echo "FATAL: PLANNED_PATHS_FILE not found: $PLANNED_PATHS_FILE" >&2; exit 1; }
  : > "$backup/planned-owned-paths.tsv"
  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    case "$path" in /*) ;; *) echo "FATAL: planned path must be absolute: $path" >&2; exit 1 ;; esac
    if [ -e "$path" ] || [ -L "$path" ]; then
      kind=$(stat -c '%F' "$path" 2>/dev/null || echo unknown)
      mode=$(stat -c '%a' "$path" 2>/dev/null || echo unknown)
      owner=$(stat -c '%u:%g' "$path" 2>/dev/null || echo unknown:unknown)
      checksum=-
      [ -f "$path" ] && checksum=$(sha256sum "$path" 2>/dev/null | awk '{print $1}')
      printf 'present\t%s\t%s\t%s\t%s\t%s\n' \
        "$path" "$kind" "$mode" "$owner" "${checksum:--}" >> "$backup/planned-owned-paths.tsv"
    else
      printf 'absent\t%s\t-\t-\t-\t-\n' "$path" >> "$backup/planned-owned-paths.tsv"
    fi
  done < "$PLANNED_PATHS_FILE"
else
  printf '%s\n' 'PLANNED_PATHS_FILE was not supplied; use the approved recommendation as the ownership manifest.' \
    > "$backup/planned-owned-paths.txt"
fi

sysctl -a > "$backup/sysctl-a.txt" 2>/dev/null || true
tc -s qdisc show > "$backup/tc-qdisc.txt" 2>/dev/null || true
route_get_after=$(route_lookup)
route_tuple_after=$(normalize_route_tuple "$route_get_after")
dev_after=$(printf '%s\n' "$route_get_after" \
  | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
if [ -z "$dev_after" ] || [ "$dev_after" != "$dev" ] || [ "$route_tuple_after" != "$route_tuple" ]; then
  echo "FATAL: route tuple changed before selected-route qdisc capture; choose a new RUN_ID after the path stabilizes" >&2
  exit 1
fi
printf '%s\n' "$route_target" > "$backup/route-target.txt"
printf '%s\n' "$route_source" > "$backup/route-source.txt"
printf '%s\n' "$route_get" > "$backup/ip-route-target.txt"
printf '%s\n' "${dev:-}" > "$backup/egress-dev.txt"
if [ -n "${dev:-}" ]; then
  tc -s qdisc show dev "$dev" > "$backup/tc-qdisc-egress.txt" 2>/dev/null \
    || { echo "FATAL: could not capture qdisc on $dev" >&2; exit 1; }
  tc -s class show dev "$dev" > "$backup/tc-class-egress.txt" 2>/dev/null \
    || { echo "FATAL: could not capture classes on $dev" >&2; exit 1; }
  tc -s filter show dev "$dev" > "$backup/tc-filter-egress.txt" 2>/dev/null \
    || { echo "FATAL: could not capture filters on $dev" >&2; exit 1; }
  tc -j -s qdisc show dev "$dev" > "$backup/tc-qdisc-egress.json" 2>/dev/null || true
  tc -j -s class show dev "$dev" > "$backup/tc-class-egress.json" 2>/dev/null || true
  tc -j -s filter show dev "$dev" > "$backup/tc-filter-egress.json" 2>/dev/null || true
  ip -s link show dev "$dev" > "$backup/ip-link-egress.txt" 2>/dev/null || true
  ethtool -i "$dev" > "$backup/ethtool-driver.txt" 2>/dev/null || true
fi
ip route show > "$backup/ip-route.txt" 2>/dev/null || true
ip -6 route show > "$backup/ip6-route.txt" 2>/dev/null || true
ip -br addr show > "$backup/ip-addr.txt" 2>/dev/null || true
ip -j route show > "$backup/ip-route.json" 2>/dev/null || true
ip -j addr show > "$backup/ip-addr.json" 2>/dev/null || true
iptables-save > "$backup/iptables-save.txt" 2>/dev/null || true
ip6tables-save > "$backup/ip6tables-save.txt" 2>/dev/null || true
nft list ruleset > "$backup/nft-ruleset.txt" 2>/dev/null || true
ulimit -n > "$backup/ulimit-n.txt" 2>/dev/null || true
cat /proc/net/snmp > "$backup/proc-net-snmp.txt" 2>/dev/null || true
nstat -azs > "$backup/nstat.txt" 2>/dev/null || true

# Units and scripts owned by known one-click tools, if present.
# --parents keeps the original path under $backup for unambiguous restore.
for f in /etc/systemd/system/bbr-optimize-persist.service \
         /usr/local/bin/bbr-optimize-apply.sh \
         /etc/systemd/system/rps-optimize.service \
         /etc/systemd/system/mss-clamp.service \
         /usr/local/bin/tcp.sh \
         /etc/sysctl.d/99-tcpfit.conf \
         /etc/modules-load.d/tcpfit-bbr.conf \
         /etc/systemd/system/tcpfit-qdisc.service \
         /usr/local/sbin/tcpfit-qdisc.sh \
         /etc/networkd-dispatcher/routable.d/50-tcpfit-initcwnd \
         /usr/local/bin/tcpfit \
         /etc/sysctl.d/99-nettune.conf \
         /etc/systemd/system/nettune-qdisc.service; do
  if [ -e "$f" ]; then
    cp -a --parents "$f" "$backup"/ 2>/dev/null \
      || cp -a "$f" "$backup"/ 2>/dev/null || true
  fi
done

# State directories are copied separately so a later migration or rollback does
# not erase the original tool-owned snapshot/result metadata.
for d in /var/lib/tcpfit /var/lib/nettune; do
  if [ -d "$d" ]; then
    cp -a --parents "$d" "$backup"/ 2>/dev/null \
      || cp -a "$d" "$backup"/ 2>/dev/null || true
  fi
done

# Self-check: refuse to report success without the essential artifacts.
fail=0
[ -s "$backup/sysctl-a.txt" ] || { echo "MISSING: sysctl-a.txt" >&2; fail=1; }
[ -s "$backup/tc-qdisc.txt" ] || { echo "MISSING: tc-qdisc.txt" >&2; fail=1; }
[ -s "$backup/ip-route-target.txt" ] || { echo "MISSING: selected-route record" >&2; fail=1; }
[ -s "$backup/tc-qdisc-egress.txt" ] || { echo "MISSING: selected-route qdisc evidence" >&2; fail=1; }
[ -e "$backup/sysctl.d" ] || { echo "MISSING: sysctl.d copy" >&2; fail=1; }
if [ "$fail" -ne 0 ]; then
  echo "FATAL: snapshot incomplete under $backup — do not apply changes" >&2
  exit 1
fi

# Integrity manifest makes a rollback bundle auditable. The completion marker
# is written last; a repeated call with the same RUN_ID retains this baseline.
(
  cd "$backup" || exit 1
  find . -type f ! -name SHA256SUMS -exec sha256sum {} \; | LC_ALL=C sort -k2 > SHA256SUMS
) || { echo "FATAL: failed to create snapshot checksums" >&2; exit 1; }
: > "$backup/.complete"

echo "snapshot written to: $backup"
ls -la "$backup"
