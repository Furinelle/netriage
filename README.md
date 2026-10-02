# netriage

> net + triage（分诊）：先评估链路的轻重缓急，拿到证据再决定动不动手。

一个给 Codex / Claude Code 复用的 VPS TCP / 网络调优 Skill（原名 `vps-tcp-tuning`），用于让 agent 按证据检查、测试、推荐并在用户确认后应用 Linux VPS 网络配置。

本 Skill 基于 Lide / iBytebox 的文章整理而来：

- 原文：[让 AI 帮你调 VPS 网络：中转机和落地机 TCP 调优笔记](https://blog.ibytebox.com/posts/ai-agent-vps-tcp-tuning/)
- 作者：Lide / iBytebox
- 原文标注许可：CC BY-NC-SA 4.0

并参考了常见一键调优脚本的模块设计（吸收工作流，不照搬参数）：

- [`Madhatter2099/TCP-Optimize`](https://github.com/Madhatter2099/TCP-Optimize)（`tcp.sh` v2.0 完整审阅 + v2.1 增补审阅）
- [`Eric86777/vps-tcp-tune`](https://github.com/Eric86777/vps-tcp-tune)（`net-tcp-tune.sh` v5.4.4 审阅；2026-09-06 复查至 **v5.4.8**：菜单 3 / buffer 未变，v5.4.7 起 ARM64 不再装 XanMod/BBRv3）
- [`Kylin010/tcpfit`](https://github.com/Kylin010/tcpfit)（2026-10-02 复查 **v0.5.9** / `38fbf5a`：吸收有界扫描、样本质量与路由持久化经验，核对流量预算和 qdisc 恢复限制，不运行其自动调优）
- [`ike-sh/bbrv3-lite`](https://github.com/ike-sh/bbrv3-lite)（v8.0.3 工作流交叉核验：吸收路径冻结、样本质量与 fail-closed 回滚，不引入其一键控制面）

网络调优经验另交叉核对了 Linux 内核文档、ESnet、Cloudflare 工程博客与 Red Hat 文档；来源、适用条件和不应照搬的参数见 [`references/current-evidence.md`](references/current-evidence.md)。

> 这个仓库不是“一键复制 sysctl 参数”的清单，也不是 `curl | bash` 包装器。它更像是一套给 AI 运维 agent 使用的工作流：先问清楚链路，再检查，再测试，再给出推荐配置，最后由用户决定是否应用。

## 这个 Skill 解决什么问题

很多 VPS 网络调优容易变成照抄参数，例如：

- 直接把 MTU 改成 `1440`
- 直接套 `TBF=1000Mbit`
- 直接把 TCP buffer 拉到 `256MB` / 海外档 `64MB`
- 看到重传就马上限速
- 不区分落地、线路、中转，也不问标称带宽就开调
- 不区分 TCP 协议和 HY2 / TUIC / QUIC 这类 UDP 协议
- 直接跑一键菜单（DNS 净化、永久关 IPv6、Realm 改配置）却不做证据核对

这个 Skill 强制 agent 按证据判断：

- 当前机器是什么角色：**落地 / 线路 / 中转**（未确认前不检查、不测、不推荐）
- 标称带宽是多少 Mbps（套餐/端口速率，上下行分开）
- 真实业务链路怎么走，服务地区 / RTT 档位（亚太短 RTT vs 美欧长 RTT）
- 用户关键方向是哪一段
- 当前 sysctl / qdisc / MTU / 服务状态是什么
- PMTU 是否真的有问题
- iperf3 的重传是否和本机 qdisc drop / backlog 对得上
- 是否真的需要 BBR、fq、buffer、MTU、HTB/TBF 或 qos-agent
- 是否真的需要 IPv4 优先、conntrack 扩容、RPS/RFS、MSS Clamp、initcwnd 或全局文件句柄扩容
- 写了 `default_qdisc=fq` 之后，**live** qdisc/叶子队列是否正确使用 `fq`，以及是否保留了 `mq` 拓扑

## 默认节省测试流量

- 先看现有业务、socket 和计数器，复用路径与负载条件相符的近期结果。
- 必要时只跑一个 peer、关键方向、单流短时限速测试；示例为 20 Mbps × 5 秒，约 12.5 MB payload，实际按链路和预算下调。
- 未指定预算时，初步诊断按每台主机累计不超过 64 MiB 规划，包含重试与验收余量；这是计划上限，不是自动硬限额或新增测试授权。更小的用户预算优先，不按 peer 或对话轮次重置。
- 不默认跑满 P1/P4 × 正反向，不自动全速测速、遍历公共端点或做 policer sweep；只有明确未决问题才升级，预算是上限，不是必须用完的额度。
- 证据足够就停，修改后只复测受影响路径。短时限速样本不能证明峰值带宽或长期稳定性；需要稳态数据时单独预算充分测量。

## 核心原则

- 用户说 `tcp调优`、`进行TCP调优`、`VPS网络调优`、`BBR调优`、`网络优化`、`开启BBR`、`测速慢`/`高重传`排查等时，应自动使用这个 Skill。
- agent 必须先确认角色（落地 / 线路 / 中转）和标称带宽，不能只看主机名猜；未确认前不 SSH、不检查、不测、不推荐。
- 默认只做检查、测试和推荐，不默认写持久配置。
- 所有持久配置变更前，必须先给出推荐配置。
- 是否应用推荐配置，由用户决定。
- 不把 `MTU 1440`、`TBF 1000Mbit`、固定大 buffer、一键菜单默认值当万能答案。
- 缓冲区按 BDP、并发、内存、角色和 `service_region` 估算；公共 speedtest 只作参考，已知端口带宽优先。
- 测试 peer 必须逐个测试，不默认并发压测；持久参数以长期 peer 为依据。
- 高速 probe/sweep 前先估算流量和时间，确认配额/账期/测试窗口；测试后报告接口字节 delta。
- 附近高容量 peer 用来测端口/policer，长期业务 peer 用来决定持久配置，两者不能混为一谈。
- 临时替换根 qdisc 前必须证明能恢复完整 class/filter/参数；只记 qdisc 类型不算回滚。
- 必须保留备份、验证步骤和回滚路径。
- 不静默执行第三方一键脚本或 menu 66 式连锁副作用。

## 安装到 Codex

```bash
git clone https://github.com/Furinelle/netriage.git ~/.agents/skills/netriage
```

如果已经安装过，可以更新：

```bash
cd ~/.agents/skills/netriage
git pull
```

## 安装到 Claude Code

```bash
git clone https://github.com/Furinelle/netriage.git ~/.claude/skills/netriage
```

如果已经安装过，可以更新：

```bash
cd ~/.claude/skills/netriage
git pull
```

> 若本机 skill 目录是普通文件夹而不是 git clone，可重新 clone 覆盖，或从本仓库拷贝 `SKILL.md`、`references/`、`scripts/`、`templates/`、`agents/`。
>
> 升级时不要在 skills 目录下保留旧版本副本（如 `netriage.bak-*`）：两个描述相近的 skill 会互相竞争触发，模型可能选中旧版。

## 前置依赖

目标机与测试 peer 上建议具备：

- 基础工具：`iproute2`（`ip`/`ss`/`tc`）、`sysctl`；主流 systemd 发行版（Debian/Ubuntu/RHEL 系）自带
- 测试工具：`iperf3`（吞吐测试）、`tracepath` 或 `ping`（PMTU）、`ethtool`（可选）
- 本地候选计算：Python 3（仅 `scripts/derive-candidates.py` 使用，不需要第三方包）；必须输入**目标机**的 `getconf PAGE_SIZE` 与预期并发，不能沿用运行 agent 的机器参数
- 装包本身属于变更：默认权限边界下 agent 会先征求同意再安装 iperf3；为测试临时放行的防火墙端口会在本轮结束时清理

## 触发方式

显式调用：

```text
Use $netriage to inspect and tune my relay or landing VPS networking safely.
```

中文直接说也应触发：

```text
帮我对这台 VPS 进行 TCP 调优。
```

```text
参考这个链路，帮我做 VPS 网络调优。
```

```text
检查一下这台中转机的 tcp调优 有没有问题。
```

```text
按 Eric 那个 bbr 脚本的思路，帮我推荐落地机参数（先别改）。
```

```text
参考 tcpfit 的方法，测一下这台 VPS 有没有端口限速器拐点，先给测试预算和方案。
```

## agent 会先问什么

agent 不会一次抛出十几个问题，而是分层询问：

**身份门（缺一不可；未确认前不 SSH / 不检查 / 不测 / 不推荐）：**

- `machine_role`：这台 VPS 是 **落地**、**线路** 还是 **中转**
  - 落地：终结或发起用户访问公网的那一跳
  - 线路：专线/优化线路跳（既不是用户入口，也不是最终出口）
  - 中转：在用户（或上一跳）和下一跳之间转发
- `advertised_bandwidth`：套餐/端口**标称**带宽（Mbps；上下行不对称就分开写）。优先买到的端口速率，不用公共测速替代。

**首轮其余必问（缺失时）：**

- `target_ssh`：目标机器的 SSH alias 或 SSH 命令
- `traffic_path`：例如 `用户 -> 中转 -> 线路 -> 落地 -> internet`
- `critical_direction`：用户真正关心的方向，例如下载、上传、视频秒开
- `permission_boundary`：只检查 / 允许测试 / 只给计划 / 允许应用；是否允许重启、改 MTU、临时替换根 qdisc、限速/qos-agent、清理备份日志、跑第三方脚本/换内核

**优先从只读检查自动发现，发现不了再问：**

- `proxy_software` / `proxy_protocols`：sing-box、xray、realm、gost、Hysteria2、TUIC、WireGuard、nginx、caddy、nftables 等
- `service_ports`：代理、Web、中转、iperf3 等相关端口

**到相应阶段再问：**

- 定 buffer 前：`service_region` / RTT 档（亚太短延迟 vs 美欧长延迟）、预期大 socket 并发、目标机 page size 和 socket workload（`proxy`=高并发用户态 TCP 终止；`bulk`=少量长 TCP；`mixed`=两者）。workload 不是从落地 / 线路 / 中转自动推导；纯内核转发可能根本不需要 endpoint buffer 候选。标称带宽已在身份门问过，不要拖到这一步。
- 测试前：`test_peers`（标签、**literal IP**、IP family、iperf3 端口、是否允许 ping、是否能 SSH）、`peer_lifecycle`（持久参数以长期续费 peer 为依据）、`test_budget_gb` 与配额/账期/峰谷窗口
- 相关时：Realm 等 L4 中转是否在链路中、是否必须保持双栈

## 推荐配置再应用

这个 Skill 明确要求：**先给推荐配置，再由用户决定是否应用。**

推荐配置至少应包含：

- 证据摘要：角色、关键链路、peer 用途/生命周期、测试流量、PMTU、带宽/RTT 档、iperf/counter delta、瓶颈判断
- 精确候选配置：拟写入的 `/etc/sysctl.d/*.conf` 内容
- 可能的 qdisc / systemd / MTU / qos-agent / initcwnd / RPS 命令或 unit
- 不建议修改的项目和理由（含一键脚本的激进副作用）
- 风险说明：是否需要重启、是否会中断服务、是否换内核
- 验证计划：应用后如何读回 live cc/qdisc/buffer 并复测
- 回滚方案：备份路径和恢复命令

如果用户没有明确说“应用这个推荐配置”“按推荐应用”“直接应用”，agent 不应写入持久网络配置。

## 典型工作流

1. 先问清角色（落地 / 线路 / 中转）和标称带宽，再问其余上下文。
2. 只读检查主机：OS、kernel/**架构**、CPU、内存、接口、MTU、实际 peer 路由、socket、sysctl、qdisc、服务进程；识别已安装的一键脚本版本与产物。
3. 读取已有 `/etc/sysctl.conf`、`/etc/sysctl.d/*.conf` 和 `*.profile.md`。
4. 区分附近高容量 peer、长期业务 peer、临时/即将弃用 peer；持久参数以匹配真实路径的长期 peer 为依据。
5. 先复用近期有效测量并观察现有业务流量；确有需要时，仅选一个长期 peer、关键方向、短时限速 P1。多流、反向、其他 peer 和扫描只用于解决尚未回答的问题；固定 literal IP、family、source、egress NIC、port。
6. 用 `scripts/measure-window.sh --route-target <literal-peer-ip> [--route-source <bound-source-ip>]` 记录接口字节、qdisc/class/filter 拓扑、softnet、route tuple 和 TCP counter delta；若给了 source，iperf3 也须以 `-B <bound-source-ip>` 绑定同一 source，或直接测实际绑定的服务。路径/拓扑漂移的样本作废，保留完整 `iperf3 -J` 文件。
7. 按落地 / 线路 / 中转（及出口/Web）解释结果；用 `scripts/derive-candidates.py --page-size <target> --concurrency <expected> --workload <proxy|bulk|mixed>` 输出 BDP、内存/并发上限和截断原因；不要把 host role 硬映射成 workload。
8. 只有在 nearby peer 足够快、拐点可重复且 qdisc 能精确恢复时，才设计 policer sweep；无稳定 knee 就不整形。
9. 给出推荐配置和不改项。
10. 没有适用的既有授权时，等用户确认；不重复索取同一授权。
11. 应用前以 `ROUTE_TARGET=<literal-peer-ip>` 备份并处理 sysctl 冲突；服务绑定 source IP 时另加 `ROUTE_SOURCE=<bound-source-ip>`。需要 `fq` 时同时处理 live qdisc 与持久化。
12. 应用后验证 SSH、关键服务、live 参数，并写 profile 与最终报告。

## 一次典型运行的样子

> 以下为流程示意，数值是虚构占位，不是推荐值。

1. 你说：`帮我对 hk-relay 做 TCP 调优`。
2. agent 先问身份门（落地 / 线路 / 中转 + 标称 Mbps），再问目标 SSH、链路、关键方向、权限边界。
3. 只读检查（`scripts/inspect.sh`）：内核 6.1、`bbr` 可用但当前是 `cubic`、根 qdisc 是 `fq_codel`、发现某一键脚本残留的 `99-xxx.conf`。
4. 逐 peer 测试：PMTU 1500 干净；iperf3 到长期落地机反向 P1 只有 180 Mbps、重传 2.1%，本机 qdisc drop 为 0。
5. 给出推荐 bundle（按 `templates/recommendation.md` 六段式）：BBR + fq、buffer 按 BDP 给候选值、列明不改 MTU / 不限速的理由、附验证与回滚方案。
6. 你说"按推荐应用"后，agent 先跑 `ROUTE_TARGET=<literal-peer-ip> bash scripts/backup-snapshot.sh` 快照（服务绑定 source 时再加 `ROUTE_SOURCE`），再写入配置、读回 live 状态、复测关键方向、落 profile。

## FAQ

**会不会直接改我的服务器？** 不会。默认边界是只检查 + 测试 + 给推荐；所有持久变更必须先给出推荐配置，等你明确说"按推荐应用"。

**目标机需要装什么？** 见"前置依赖"。装 iperf3 这类包也算变更，agent 会先问。

**对 HY2 / TUIC 这类 UDP 协议有用吗？** 分层看：外层 UDP/QUIC 不吃 Linux TCP buffer，但 MTU、qdisc、CPU 调度、出口 shaping 仍有影响；VPS 作为出口访问网站时，出口 TCP 仍受 BBR/buffer/PMTU 影响。

**和一键脚本什么区别？** 一键脚本按预设参数直接写；这个 Skill 先测你的真实链路，给出带证据和回滚方案的推荐，参数是从测量推出来的候选值。被审阅工具的可取思路已按"候选 + 证据门"吸收，激进副作用和不完整回滚被明确拦住。

**为什么推荐配置里有很多"不改"项？** 不改也是结论。例如 PMTU 干净就不动 MTU；本机 qdisc 无 drop 的高重传不该用限速掩盖。

## 实战经验更新

2026-10-02 基于 tcpfit v0.5.9 和工程资料更新：

- **有界测试**：上游 50 GB 只是确认阈值；第一次探测前就需预算与停止条件。预算包含 `iperf3 -O` 预热、重复与验证；`-P` 下的 `-b` 按每流计速，HTB 总速率不重复乘流数。计算器新增 `--sweep-omit`，估算器不承担硬配额控制。
- **分层诊断**：同时看吞吐、空闲/负载 RTT、应用首包/尾延迟、CPU/steal、socket 和内存压力。先区分应用慢读、接收窗口、NIC/softnet、路径及 provider policer，再选参数。
- **缓冲区语义**：区分 TCP 自动调节与应用显式 socket buffer；保留合理默认值，只调整证据支持的上限。RAM/4 ÷ 并发是候选，不能忽略双向内存、代理双腿、cgroup 和其他服务。
- **旧建议过滤**：不搬用 Cloudflare 的 512 MiB/custom patch 或 ESnet 的 10G/100G 参数；`tcp_adv_win_scale` 自 Linux 6.6 起废弃。BBR 版本查实际内核来源，不凭版本号或名称猜测。
- **持久化与回滚**：保留 `mq`；按实际路由/配置管理器验证无 `via`、DHCP/PPP 场景。新增 initcwnd 产物纳入检查和备份；未获准重启/重连时明确标注持久化未实测。
- **按需加载**：保留本机已有的简洁 `SKILL.md`，详细流程放到 `references/operations.md`，技术依据按场景读取。


2026-09-06 参考 tcpfit v0.5.7 与同类测量工具后更新：

- **推导账本**：buffer 推荐必须显示 BDP、2×BDP、2×BDP+2MiB（tcpfit 的竞争候选）、RAM/4 ÷ 并发 cap、最终值和截断原因；`tcp_mem` 必须按目标机 page size 展示，不能把页当字节。
- **测试成本门**：probe/sweep 前估算流量下界并确认配额与窗口，测试后用接口 RX/TX delta 报实际消耗（注明同接口业务流量会污染计量）。
- **样本冻结**：每轮固定 literal IP、family、source、egress NIC、port，测试前后核验 `ip route get`；路径或 tc topology 漂移、CPU 饱和或结果不稳定时不产出整形推荐。
- **policer 实验法**：先验证 nearby peer 能力，疑似跳变要重复、交错 A/B/A，粗扫后细扫；扫描范围干净时结论是“本次未观察到 knee”，不是把上界当成整形值。
- **qdisc 事务安全**：tcpfit v0.5.7 修复了 v0.3.8 遗留临时 HTB 与 `mq 0:` 兼容问题，但仍只按 kind 恢复，不能重建 HTB class/filter/参数；复杂 qdisc 无精确恢复方案就不替换。

2026-07-09 对 `dmit-lax` 做 TCP/UDP 调优后，补充了几条更强约束：

- **长期 peer 优先**：如果一些 VPS 即将不续费，只把它们当作观察样本，不要让它们决定长期主机的持久参数。
- **HY2 判断要分层**：HY2 外层是 UDP/QUIC，不直接吃 TCP buffer；但 VPS 作为出口访问网站时，出口 TCP 仍受 BBR、TCP buffer、PMTU、qdisc 影响。
- **不要用 `pkill -f` 清 iperf3**：远端 SSH 脚本里包含同样命令文本时，`pkill -f` 可能杀掉当前 shell。应使用 `iperf3 -D --pidfile`，清理时只 kill pidfile 里的 `iperf3` PID。
- **profile heredoc 要 quoted**：写 Markdown profile 时如果包含反引号代码块，必须使用 `<<'EOF'` 这类 quoted heredoc，避免 shell 命令替换误执行回滚命令。
- **限速要有本机出口证据**：高重传但本机 egress qdisc drop/backlog 为 0 时，不应默认落盘 HTB/TBF/qos-agent。

## 对第三方一键脚本的参考

### Kylin010/tcpfit

吸收（作为实验设计，不直接运行上游自动调优）：

- BDP × RAM × 角色的透明候选计算，并展示被哪个 cap 截断
- probe/sweep 前的流量预算与测试后的接口字节计量
- 附近容量 peer 与真实业务 durable peer 分工
- 疑似 policer 拐点重复确认、粗扫 + 细扫、无 knee 不整形
- 参数先校验、破坏性测试加互斥锁和中断清理、变更清单与回滚清单对称

明确拦截：

- `qdisc_save` 只保存类型（`mq` 另记叶子 kind），不能恢复 HTB class/filter/自定义参数
- v0.3.8 自动 sweep 的临时 HTB 遗留路径已于 v0.5.4 修复，但**不**代表 classful qdisc 可精确回滚
- qdisc snapshot 仍不是可执行的拓扑恢复；v0.5.9 虽改善路由 token 保留和错误传播，仍需独立的精确回滚
- 默认 150ms RTT、计算/显示均假设 4 KiB page、`0.1%`/1448 MSS loss proxy、固定部分 qdisc 参数、整套 sysctl 和 CLI 的 `initcwnd 32` 不能直接通用化
- v0.5.9 保留菜单 opt-out telemetry；netriage 不执行它，用户坚持运行时须披露并以 `TCPFIT_NO_TELEMETRY=1` 禁用，除非明确同意该请求

完整静态审阅见 [`references/tcpfit-review.md`](references/tcpfit-review.md)。若用户明确要跑上游本体，pin **v0.5.9** / `38fbf5a` 并校验其中记录的 SHA-256；新版 guard 不等于硬预算或完整 qdisc 回滚。

### Madhatter2099/TCP-Optimize

吸收：按功能拆分、展示 live 状态、先检查 BBR 支持、加载 conntrack、独立评估 RPS/RFS、明确清理项。

不直接通用化：总内存 5% buffer、`udp_mem` 当字节、盲目 IPv4 优先 / RPS / conntrack / MSS / 百万 nofile、用内核版本推断 BBRv3、把 `cubic+fq_codel` 当万能回滚默认值。

版本状态：v2.0（`e43b4ba`）完整审阅；v2.1（`c508c1e`，2026-07-13 重写）已复查增补——上游修正了 BBRv3 版本误判，但新增的 RPS/MSS systemd 持久化服务经实测是坏的（开机假成功、什么都没应用），4 个工作负载模板对所有角色无条件开 `ip_forward`，"最大吞吐"模板无视内存直接写 256MB buffer。

完整审阅见 [`references/tcp-optimize-review.md`](references/tcp-optimize-review.md)（含 2026-07-26 v2.1 增补节）。

### Eric86777/vps-tcp-tune

吸收（作为**候选**与工作流，不是静默一键）：

- 带宽 × 服务地区（亚太 / 美欧）缓冲区阶梯，并用 BDP 交叉校验
- 写 `default_qdisc=fq` 的同时对物理网卡做 live `tc qdisc replace`，并考虑开机持久化
- 应用前清理 sysctl 冲突、应用后读回验证
- 倾向 `tcp_mtu_probing`，而不是默认改接口 MTU 1440
- Realm / conntrack、initcwnd、RPS 等拆成可选模块，各自过证据门

明确拒绝默认照搬：

- menu 66 连锁（DNS 净化 + Realm 改配置 + 永久关 IPv6）
- 未 pin 版本的 `curl | bash`
- 把任意 XanMod / `bbr` 都叫 BBRv3，或在 ARM64 上装 XanMod / 承诺 BBRv3
- 无压力证据就写死 `nf_conntrack_max=262144`
- 无双栈对比就永久禁用 IPv6

版本状态：v5.4.4 完整审阅；2026-09-06 复查至 **v5.4.8** (`573c66d`)——菜单 3 / buffer 阶梯 / 产物文件仍未变化。v5.4.7 起功能 1 在 ARM64 上不再下载第三方内核脚本，并写明主线没有 BBRv3、XanMod 只有 x86_64。若要运行上游工具箱本体，pin v5.4.8；ARM64 不要跑功能 1 / menu 66 的换内核阶段。

完整审阅见 [`references/vps-tcp-tune-review.md`](references/vps-tcp-tune-review.md)。

## 仓库结构

```text
.
├── SKILL.md                         # Skill 主说明
├── references/
│   ├── blog-method.md               # 从原文整理出的详细方法和命令模式
│   ├── tcpfit-review.md             # tcpfit v0.5.9 静态审阅与运行边界
│   ├── tcp-optimize-review.md       # 对 TCP-Optimize 的证据化参考与边界（含 v2.1 增补）
│   └── vps-tcp-tune-review.md       # 对 Eric86777/vps-tcp-tune 的审阅与候选表
├── scripts/
│   ├── inspect.sh                   # 只读检查采集（可经 SSH 远程执行）
│   ├── pmtu-probe.sh                # PMTU 阶梯探测（只读）
│   ├── derive-candidates.py         # BDP / RAM÷并发 / tcpfit 竞争候选与 sweep 下界
│   ├── measure-window.sh            # 单次测试前后 route + qdisc/class/filter delta
│   └── backup-snapshot.sh           # 对实际业务 route 的应用前全量快照
├── templates/
│   ├── recommendation.md            # 推荐配置六段式模板
│   └── profile.md                   # 调优 profile 模板
├── tests/                           # 标准库候选计算与 Linux qdisc 回归测试
├── agents/
│   └── openai.yaml                  # Codex UI metadata
├── CHANGELOG.md                     # 更新日志
├── README.md                        # 中文说明
└── LICENSE                          # 来源和许可说明
```

## 开发验证

```bash
python3 -B -m unittest discover -s tests -v
bash -n scripts/*.sh tests/*.sh
```

`test_backup_snapshot.sh` 与 `test_measure_window.sh` 需要 Linux 的 `/sys` / `/proc`；前者还因复用生产快照路径而需要 root。macOS 上会跳过，可在 root Linux 容器或测试机运行。

## 注意事项

- 不要把私钥、云厂商 token、代理密码直接发给 agent。
- 如果是生产节点，建议先只允许检查和测试。
- HY2 / TUIC / QUIC 不吃 Linux TCP buffer，但仍会受 MTU、qdisc、CPU 调度和出口 shaping 影响。
- qdisc drop/backlog 为 0 但 iperf3 高重传时，不要急着全局限速；更可能是路径、上游或对端问题。
- 一个弱 peer 的结果不能直接推导为全局配置。
- tcpfit v0.5.7 的默认 telemetry 是外部请求；除非用户明确同意，否则禁用后才运行。
- `backup-snapshot.sh` 必须以 `ROUTE_TARGET=<literal-peer-ip>` 运行；服务绑定 source IP 时还要传 `ROUTE_SOURCE=<bound-source-ip>`，不允许回退到无关的默认路由。
- 换内核 / 跑一键脚本前必须 pin 版本、全量备份，并列出副作用文件清单。

## 许可与署名

本仓库内容是对原文方法的 Skill 化整理，并保留原文链接和作者信息。原文标注为 CC BY-NC-SA 4.0，请在使用和二次分发时遵守相应要求。

对第三方脚本的审阅仅为互操作与安全边界说明，不构成对其代码的再授权或背书。
