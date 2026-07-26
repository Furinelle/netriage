# Tuning Recommendation — <host alias> (<date>)

Skeleton for the recommendation bundle required by SKILL.md ("Recommendation
Before Application Gate"). Fill every section, write in the user's language,
then STOP and wait for explicit approval before any persistent change.

## 1. Evidence summary

- Role and traffic path:
- Critical direction:
- Bandwidth / RTT class (source: known port speed | speedtest | measured):
- PMTU findings:
- iperf3 results per durable peer (P1/P4, forward/reverse, retransmits):
- qdisc drop/backlog and TCP counter deltas during test windows:
- Bottleneck interpretation:

## 2. Exact candidate configuration

Proposed `/etc/sysctl.d/<file>.conf` content (complete, ready to write):

```conf
# fill in — every value must trace back to section 1
```

Other commands/units (live `tc qdisc replace`, MSS clamp, initcwnd, RPS,
systemd persistence — persistence units must inline concrete commands):

```bash
# fill in, or state "none"
```

## 3. Rejected candidates (non-changes)

Non-changes are conclusions too; list every knob considered and dropped.

| Knob | Why not (missing evidence / wrong role / one-click side effect) |
| --- | --- |
| | |

## 4. Risk and interruption notes

- Restart/reload/reboot needed:
- Kernel swap involved:
- Services that may blip:

## 5. Verification plan

- Live read-back (congestion control, root qdisc on the egress dev, buffer bytes):
- Retests to run (same peers/directions as baseline):

## 6. Rollback plan

- Backup location (from `scripts/backup-snapshot.sh`):
- Exact restore commands per owned file/unit/rule:
