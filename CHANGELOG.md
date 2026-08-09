# Changelog

## 2026-08-09

### Added

- Reviewed [`Kylin010/tcpfit`](https://github.com/Kylin010/tcpfit) v0.3.8 (`5671da0`) from source and added `references/tcpfit-review.md`. Reused its transparent BDP/RAM/role derivation ledger, test-traffic budgeting, peer-purpose split, repeated coarse/fine policer-knee experiment, and no-knee/no-shaper rule as evidence-gated methods.
- Added `scripts/derive-candidates.py`, a no-mutation JSON calculator for BDP, 2×BDP, RAM/concurrency caps, role defaults, page-aware `tcp_mem` candidates, and linear sweep payload estimates.
- Added `scripts/measure-window.sh`, a measurement-only wrapper that reports interface bytes, TCP retrans/out-segment, qdisc, and softnet deltas around one approved test command.
- Extended recommendation/profile templates with peer purpose, approved/actual test volume, derivation provenance, and qdisc restoration verification.

### Changed

- Added an explicit high-volume test budget/window gate and separated nearby capacity/policer peers from durable business-path peers.
- Strengthened qdisc safety: serialize temporary replacements, capture the authoritative topology owner, require exact class/filter/parameter restoration, and avoid destructive sweeps when only a qdisc kind is recoverable.
- Expanded `scripts/inspect.sh` with optional route-target selection, page size, virtualization, link/queue/interface counters, socket stats, page-sensitive sysctls, JSON qdisc topology, and tcpfit/nettune artifact discovery.
- Hardened `scripts/backup-snapshot.sh` with per-run earliest-snapshot retention, an optional planned-path state/metadata manifest, route/qdisc JSON and class/filter evidence, tcpfit/nettune artifacts, interface/TCP counters, checksums, and a completion marker.
- Updated the SKILL trigger and docs for tcpfit, BDP calculation, policer/knee/sweep requests; removed the nonstandard `license` frontmatter key so only `name` and `description` remain.

### Safety findings

- tcpfit v0.3.8 does not provide exact qdisc/route rollback: it saves only the qdisc kind, and automatic sweep can clear the saved interface before later test HTB steps, leaving a temporary shaper on some exit paths. netriage therefore documents the method but does not run or wrap the upstream auto-sweep on production hosts.
- tcpfit's fixed RTT targets, 4 KiB page assumption, retransmission-derived `0.1%` loss proxy, margin tiers, HTB/fq constants, broad sysctl set, and initcwnd 32 remain candidates behind independent evidence gates.

## 2026-07-26

### Added

- Rechecked all three upstream sources and recorded baselines for the next recheck:
  - `Eric86777/vps-tcp-tune` v5.4.4 → v5.4.6 (`44b2870`, 2026-07-23): security hardening only, zero TCP-path changes; the review remains valid, pin ≥ v5.4.6 when running the toolbox.
  - `Madhatter2099/TCP-Optimize` v2.0 → v2.1 (`c508c1e`, 2026-07-13): added a dated addendum covering the fixed BBRv3 claim, the broken RPS/MSS persistence services (verified: exit 0 without applying anything), the option-8 workload profiles (`ip_forward=1` everywhere, 256 MiB max-throughput buffers, doubled `udp_mem` still in pages), the option-9 benchmark blind spots, and the v2.0→v2.1 `gai.conf` rollback gap.
  - Blog qos-agent sequel: still unpublished as of 2026-07-26 (noted in `references/blog-method.md`).
- Added `scripts/` — read-only inspection (`inspect.sh`, `pmtu-probe.sh`) plus a pre-change snapshot writer (`backup-snapshot.sh`) — and `templates/` (`recommendation.md`, `profile.md`); wired them into the SKILL.md workflow. No apply-side scripts by design.
- Absorbed previously missed source-article details into `references/blog-method.md`: the 5-step MTU decision chain, role-based buffer upper tiers (with the 64 MiB one-click cap tension noted), two extra shaping-ladder criteria (startup behavior; never hurt healthy peers), iperf3 firewall-port patterns, a protocol × knob matrix, a symptom → role mapping, and inline pre-change snapshot / live qdisc read-back blocks in the safe-apply process.
- Added `.gitignore` for local memory dirs and OS files.

### Changed

- Renamed the project from `vps-tcp-tuning` to `netriage` (net + triage: assess the path before touching it) to stop shadowing `Eric86777/vps-tcp-tune`; updated the repo name, SKILL.md `name`, README title/clone paths, script headers, and Codex UI metadata. Old GitHub URLs redirect.
- Restructured the questioning gate into first-round core questions (target, role + path, critical direction, permission boundary), auto-discovered fields, and stage-deferred fields; `permission_boundary` now consistently includes cleanup across SKILL.md and README.
- Rewrote the frontmatter description with a purpose prefix and wider Chinese trigger coverage (网络优化 / 网络加速 / 开启BBR / 测速慢 / 高重传 / 丢包 etc.); narrowed bare retransmission/throughput/latency to the Linux VPS context.
- Clarified that installing test tools and opening firewall ports count as changes; temporary rules must be removed in the same run.
- New policy: persistence units must inline concrete commands and be verified after reboot (motivated by TCP-Optimize v2.1's broken units).
- README: layered questioning list, prerequisites, a schematic run walkthrough, FAQ, upstream version status, and an upgrade note about stale skill copies competing for triggers.

## 2026-07-22

### Added

- Added a commit-reviewed reference for [`Eric86777/vps-tcp-tune`](https://github.com/Eric86777/vps-tcp-tune) (`net-tcp-tune.sh` v5.4.4) in `references/vps-tcp-tune-review.md`.
- Documented the bandwidth × service-region buffer candidate ladder (Asia / overseas), BDP cross-check (`Mbps × RTT_ms × 125`), live `fq` apply + boot persistence, sysctl conflict hygiene, and owned-file inventory for menu 3 artifacts.
- Extended active-questioning fields with `service_region` / RTT class and optional third-party-script / kernel-swap permission.
- Expanded skill triggers for `BBR调优`, XanMod, one-click `bbr` menus, Realm timeout fix, and menu `3`/`66` style requests.

### Changed

- Upgraded `SKILL.md` workflow: size buffers from evidence after peer tests; verify live qdisc after `default_qdisc=fq`; prefer `tcp_mtu_probing` over cargo-cult interface MTU 1440; keep recommendation-before-apply for all persistent changes.
- Extended `references/blog-method.md` candidate decisions for live fq persistence, initcwnd, endpoint extras, Realm/conntrack modules, and conflict-aware apply/read-back.
- Clarified that this skill must not silently wrap `curl | bash` or auto-run menu-66 chains (DNS purify, permanent IPv6 disable, Realm rewrite) without per-step evidence and approval.

### Notes

- Reusable ideas from Eric's script are absorbed as **candidates with evidence gates**, not as universal defaults.
- Do not infer BBRv3 from `uname -r` alone; sysctl name remains `bbr` across variants.

## 2026-07-12

### Added

- Added a commit-pinned review of `Madhatter2099/TCP-Optimize` covering reusable workflow ideas, parameter caveats, static implementation findings, and evidence gates.
- Added read-only collection guidance for dual-stack routing, conntrack pressure, RX queue topology, IRQ distribution, RPS/RFS, and per-CPU softirq state.

### Changed

- Extended tuning policy for IPv4 address selection, conntrack sizing, RPS/RFS, MSS clamping, service limits, live qdisc verification, and third-party script ownership.
- Clarified that `udp_mem` uses memory pages, RAM percentages are not a buffer-sizing formula, and BBRv3 must not be inferred from kernel version alone.
- Expanded the Chinese README with a concise comparison and link to the detailed review.

## 2026-07-09

### Added

- Added `peer_lifecycle` to the required tuning context so agents distinguish long-term/renewing peers from temporary or soon-to-expire VPSs.
- Added guidance to base persistent tuning decisions on durable peers that match the real traffic path.
- Added safe temporary `iperf3` server lifecycle guidance using `iperf3 -D --pidfile` instead of `pkill -f`.
- Added quoted-heredoc guidance for writing Markdown tuning profiles that contain backticks or rollback commands.
- Added README practical notes from the `dmit-lax` tuning run: HY2 layering, durable-peer priority, safe iperf cleanup, and evidence requirements before HTB/TBF/qos-agent.

### Changed

- Updated the workflow to explicitly choose peers before testing and to record durable peers in the final profile/report.
- Updated interpretation rules: weak or temporary peers should not downsize or reshape a long-term host when durable peers are clean.
- Clarified that high retransmission without local egress qdisc drop/backlog is not enough to justify local shaping.

### Fixed

- Documented a recurring pitfall where `pkill -f` can match the current SSH shell script and terminate the session before `iperf3` setup completes.
- Documented a shell heredoc pitfall where unquoted Markdown code fences can trigger command substitution while writing profile files.

## 2026-07-08

### Added

- Initial public skill release for evidence-based VPS TCP/network tuning.
- Added Chinese README covering purpose, source attribution, installation for Codex and Claude Code, active-questioning fields, recommendation-before-application gate, workflow, and operational cautions.
