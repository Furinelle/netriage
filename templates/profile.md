# Tuning Profile — target: /etc/sysctl.d/<name>.profile.md

Skeleton for the profile written after a successful apply (SKILL.md workflow
step 9). Write in the user's language; mask IPs and use peer aliases.

When writing this file over SSH, use a QUOTED heredoc (`<<'EOF'`): unquoted
heredocs containing backticks trigger shell command substitution and can
accidentally execute rollback-looking commands.

## Host

- Alias / role / traffic path:
- Kernel / distro:
- Date applied / RUN_ID:

## Assumptions

- Advertised bandwidth and its source:
- Service region / RTT class:
- Durable peers that drove decisions (and temporary peers deliberately excluded):
- Nearby capacity/policer peer, if any (do not conflate with durable path peers):
- Approved test budget/window and actual interface-byte delta:

## Tests

- Baseline (per peer: PMTU, iperf3 P1/P4 fwd/rev, retransmits, qdisc deltas):
- Post-apply retest:

## Applied configuration

- File(s) written:
- Chosen values with one-line reasoning each:
- Candidate derivation inputs/output and the limiting cap (BDP / RAM / concurrency):
- Live actions (tc replace, MSS clamp, RPS, initcwnd):
- Persistence mechanism:

## Explicit non-changes

-

## Caveats / remaining uncertainty

-

## Backup and rollback

- Backup path:
- Exact restore commands:
