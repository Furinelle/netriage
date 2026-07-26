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

set -u
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
case $RUN_ID in
  *[!A-Za-z0-9._-]*) echo "FATAL: RUN_ID may only contain [A-Za-z0-9._-], got: $RUN_ID" >&2; exit 1 ;;
esac

backup=/root/network-tuning-$RUN_ID/pre-change
mkdir -p "$backup" || { echo "FATAL: cannot create $backup" >&2; exit 1; }

cp -a /etc/sysctl.conf "$backup"/ 2>/dev/null || true
cp -a /etc/sysctl.d "$backup"/ 2>/dev/null || true
cp -a /etc/security/limits.conf /etc/security/limits.d "$backup"/ 2>/dev/null || true
cp -a /etc/gai.conf "$backup"/ 2>/dev/null || true

sysctl -a > "$backup/sysctl-a.txt" 2>/dev/null || true
tc -s qdisc show > "$backup/tc-qdisc.txt" 2>/dev/null || true
ip route show > "$backup/ip-route.txt" 2>/dev/null || true
ip -6 route show > "$backup/ip6-route.txt" 2>/dev/null || true
ip -br addr show > "$backup/ip-addr.txt" 2>/dev/null || true
iptables-save > "$backup/iptables-save.txt" 2>/dev/null || true
ip6tables-save > "$backup/ip6tables-save.txt" 2>/dev/null || true
nft list ruleset > "$backup/nft-ruleset.txt" 2>/dev/null || true
ulimit -n > "$backup/ulimit-n.txt" 2>/dev/null || true

# Units and scripts owned by known one-click tools, if present.
# --parents keeps the original path under $backup for unambiguous restore.
for f in /etc/systemd/system/bbr-optimize-persist.service \
         /usr/local/bin/bbr-optimize-apply.sh \
         /etc/systemd/system/rps-optimize.service \
         /etc/systemd/system/mss-clamp.service \
         /usr/local/bin/tcp.sh; do
  if [ -e "$f" ]; then
    cp -a --parents "$f" "$backup"/ 2>/dev/null \
      || cp -a "$f" "$backup"/ 2>/dev/null || true
  fi
done

# Self-check: refuse to report success without the essential artifacts.
fail=0
[ -s "$backup/sysctl-a.txt" ] || { echo "MISSING: sysctl-a.txt" >&2; fail=1; }
[ -s "$backup/tc-qdisc.txt" ] || { echo "MISSING: tc-qdisc.txt" >&2; fail=1; }
[ -e "$backup/sysctl.d" ] || { echo "MISSING: sysctl.d copy" >&2; fail=1; }
if [ "$fail" -ne 0 ]; then
  echo "FATAL: snapshot incomplete under $backup — do not apply changes" >&2
  exit 1
fi

echo "snapshot written to: $backup"
ls -la "$backup"
