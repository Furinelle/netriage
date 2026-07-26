# vps-tcp-tuning

一个给 Codex / Claude Code 复用的 VPS TCP / 网络调优 Skill，用于让 agent 按证据检查、测试、推荐并在用户确认后应用 Linux VPS 网络配置。

本 Skill 基于 Lide / iBytebox 的文章整理而来：

- 原文：[让 AI 帮你调 VPS 网络：中转机和落地机 TCP 调优笔记](https://blog.ibytebox.com/posts/ai-agent-vps-tcp-tuning/)
- 作者：Lide / iBytebox
- 原文标注许可：CC BY-NC-SA 4.0

并参考了常见一键调优脚本的模块设计（吸收工作流，不照搬参数）：

- [`Madhatter2099/TCP-Optimize`](https://github.com/Madhatter2099/TCP-Optimize)（`tcp.sh` v2.0 完整审阅 + v2.1 增补审阅）
- [`Eric86777/vps-tcp-tune`](https://github.com/Eric86777/vps-tcp-tune)（`net-tcp-tune.sh` v5.4.4 审阅，2026-07-26 复查至 v5.4.6：纯安全加固，TCP 调优逻辑无变化）

> 这个仓库不是“一键复制 sysctl 参数”的清单，也不是 `curl | bash` 包装器。它更像是一套给 AI 运维 agent 使用的工作流：先问清楚链路，再检查，再测试，再给出推荐配置，最后由用户决定是否应用。

## 这个 Skill 解决什么问题

很多 VPS 网络调优容易变成照抄参数，例如：

- 直接把 MTU 改成 `1440`
- 直接套 `TBF=1000Mbit`
- 直接把 TCP buffer 拉到 `256MB` / 海外档 `64MB`
- 看到重传就马上限速
- 不区分中转机、落地机、建站机、出口机
- 不区分 TCP 协议和 HY2 / TUIC / QUIC 这类 UDP 协议
- 直接跑一键菜单（DNS 净化、永久关 IPv6、Realm 改配置）却不做证据核对

这个 Skill 强制 agent 按证据判断：

- 当前机器是什么角色：中转、落地、出口、建站、混合节点
- 真实业务链路怎么走，服务地区 / RTT 档位（亚太短 RTT vs 美欧长 RTT）
- 用户关键方向是哪一段
- 当前 sysctl / qdisc / MTU / 服务状态是什么
- PMTU 是否真的有问题
- iperf3 的重传是否和本机 qdisc drop / backlog 对得上
- 是否真的需要 BBR、fq、buffer、MTU、HTB/TBF 或 qos-agent
- 是否真的需要 IPv4 优先、conntrack 扩容、RPS/RFS、MSS Clamp、initcwnd 或全局文件句柄扩容
- 写了 `default_qdisc=fq` 之后，**live** 根 qdisc 是否真的变成了 `fq`

## 核心原则

- 用户说 `tcp调优`、`进行TCP调优`、`VPS网络调优`、`BBR调优`、`网络优化`、`开启BBR`、`测速慢`/`高重传`排查等时，应自动使用这个 Skill。
- agent 必须主动询问缺失信息，不能只看主机名猜业务链路。
- 默认只做检查、测试和推荐，不默认写持久配置。
- 所有持久配置变更前，必须先给出推荐配置。
- 是否应用推荐配置，由用户决定。
- 不把 `MTU 1440`、`TBF 1000Mbit`、固定大 buffer、一键菜单默认值当万能答案。
- 缓冲区按 BDP、并发、内存、角色和 `service_region` 估算；公共 speedtest 只作参考，已知端口带宽优先。
- 测试 peer 必须逐个测试，不默认并发压测；持久参数以长期 peer 为依据。
- 必须保留备份、验证步骤和回滚路径。
- 不静默执行第三方一键脚本或 menu 66 式连锁副作用。

## 安装到 Codex

```bash
git clone https://github.com/Furinelle/vps-tcp-tuning.git ~/.agents/skills/vps-tcp-tuning
```

如果已经安装过，可以更新：

```bash
cd ~/.agents/skills/vps-tcp-tuning
git pull
```

## 安装到 Claude Code

```bash
git clone https://github.com/Furinelle/vps-tcp-tuning.git ~/.claude/skills/vps-tcp-tuning
```

如果已经安装过，可以更新：

```bash
cd ~/.claude/skills/vps-tcp-tuning
git pull
```

> 若本机 skill 目录是普通文件夹而不是 git clone，可重新 clone 覆盖，或从本仓库拷贝 `SKILL.md`、`references/`、`scripts/`、`templates/`、`agents/`。
>
> 升级时不要在 skills 目录下保留旧版本副本（如 `vps-tcp-tuning.bak-*`）：两个描述相近的 skill 会互相竞争触发，模型可能选中旧版。

## 前置依赖

目标机与测试 peer 上建议具备：

- 基础工具：`iproute2`（`ip`/`ss`/`tc`）、`sysctl`；主流 systemd 发行版（Debian/Ubuntu/RHEL 系）自带
- 测试工具：`iperf3`（吞吐测试）、`tracepath` 或 `ping`（PMTU）、`ethtool`（可选）
- 装包本身属于变更：默认权限边界下 agent 会先征求同意再安装 iperf3；为测试临时放行的防火墙端口会在本轮结束时清理

## 触发方式

显式调用：

```text
Use $vps-tcp-tuning to inspect and tune my relay or landing VPS networking safely.
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

## agent 会先问什么

agent 不会一次抛出十几个问题，而是分层询问：

**首轮必问（缺失时）：**

- `target_ssh`：目标机器的 SSH alias 或 SSH 命令
- `machine_role` + `traffic_path`：中转/落地/出口/建站/混合，以及例如 `用户 -> 中转 -> 落地 -> internet`
- `critical_direction`：用户真正关心的方向，例如下载、上传、视频秒开
- `permission_boundary`：只检查 / 允许测试 / 只给计划 / 允许应用；是否允许重启、改 MTU、限速/qos-agent、清理备份日志、跑第三方脚本/换内核

**优先从只读检查自动发现，发现不了再问：**

- `proxy_software` / `proxy_protocols`：sing-box、xray、realm、gost、Hysteria2、TUIC、WireGuard、nginx、caddy、nftables 等
- `service_ports`：代理、Web、中转、iperf3 等相关端口

**到相应阶段再问：**

- 定 buffer 前：`advertised_bandwidth`（已知端口带宽优先于公共测速）、`service_region` / RTT 档（亚太短延迟 vs 美欧长延迟）
- 测试前：`test_peers`（标签、地址、iperf3 端口、是否允许 ping、是否能 SSH）、`peer_lifecycle`（持久参数以长期续费 peer 为依据）
- 相关时：Realm 等 L4 中转是否在链路中、是否必须保持双栈

## 推荐配置再应用

这个 Skill 明确要求：**先给推荐配置，再由用户决定是否应用。**

推荐配置至少应包含：

- 证据摘要：角色、关键链路、PMTU、带宽/RTT 档、iperf/counter delta、瓶颈判断
- 精确候选配置：拟写入的 `/etc/sysctl.d/*.conf` 内容
- 可能的 qdisc / systemd / MTU / qos-agent / initcwnd / RPS 命令或 unit
- 不建议修改的项目和理由（含一键脚本的激进副作用）
- 风险说明：是否需要重启、是否会中断服务、是否换内核
- 验证计划：应用后如何读回 live cc/qdisc/buffer 并复测
- 回滚方案：备份路径和恢复命令

如果用户没有明确说“应用这个推荐配置”“按推荐应用”“直接应用”，agent 不应写入持久网络配置。

## 典型工作流

1. 主动询问缺失上下文。
2. 只读检查主机：OS、kernel、CPU、内存、接口、MTU、路由、socket、sysctl、qdisc、服务进程；识别是否已有一键脚本产物（如 `99-bbr-ultimate.conf`、`bbr-optimize-persist.service`）。
3. 读取已有 `/etc/sysctl.conf`、`/etc/sysctl.d/*.conf` 和 `*.profile.md`。
4. 识别长期 peer 和临时/即将弃用 peer；持久调优参数以长期 peer 为依据。
5. 逐个 peer 做 PMTU、ping、iperf3 P1/P4 正向/反向测试。
6. 记录测试窗口内 qdisc drop/backlog 和 TCP retransmission delta。
7. 按中转/落地/出口/Web 角色解释结果；用 BDP 与地区表估算 buffer **候选**。
8. 给出推荐配置和不改项。
9. 等用户确认。
10. 应用前备份并处理 sysctl 冲突；需要 `fq` 时同时处理 live qdisc 与持久化。
11. 应用后验证 SSH、关键服务、live 参数，并写 profile 与最终报告。

## 一次典型运行的样子

> 以下为流程示意，数值是虚构占位，不是推荐值。

1. 你说：`帮我对 hk-relay 做 TCP 调优`。
2. agent 问齐首轮四项：目标 SSH、角色 + 链路、关键方向、权限边界。
3. 只读检查（`scripts/inspect.sh`）：内核 6.1、`bbr` 可用但当前是 `cubic`、根 qdisc 是 `fq_codel`、发现某一键脚本残留的 `99-xxx.conf`。
4. 逐 peer 测试：PMTU 1500 干净；iperf3 到长期落地机反向 P1 只有 180 Mbps、重传 2.1%，本机 qdisc drop 为 0。
5. 给出推荐 bundle（按 `templates/recommendation.md` 六段式）：BBR + fq、buffer 按 BDP 给候选值、列明不改 MTU / 不限速的理由、附验证与回滚方案。
6. 你说"按推荐应用"后，agent 先跑 `scripts/backup-snapshot.sh` 快照，再写入配置、读回 live 状态、复测关键方向、落 profile。

## FAQ

**会不会直接改我的服务器？** 不会。默认边界是只检查 + 测试 + 给推荐；所有持久变更必须先给出推荐配置，等你明确说"按推荐应用"。

**目标机需要装什么？** 见"前置依赖"。装 iperf3 这类包也算变更，agent 会先问。

**对 HY2 / TUIC 这类 UDP 协议有用吗？** 分层看：外层 UDP/QUIC 不吃 Linux TCP buffer，但 MTU、qdisc、CPU 调度、出口 shaping 仍有影响；VPS 作为出口访问网站时，出口 TCP 仍受 BBR/buffer/PMTU 影响。

**和一键脚本什么区别？** 一键脚本按预设参数直接写；这个 Skill 先测你的真实链路，给出带证据和回滚方案的推荐，参数是从测量推出来的候选值。两个被审阅脚本的可取思路已按"候选 + 证据门"吸收，激进副作用被明确拒绝。

**为什么推荐配置里有很多"不改"项？** 不改也是结论。例如 PMTU 干净就不动 MTU；本机 qdisc 无 drop 的高重传不该用限速掩盖。

## 实战经验更新

2026-07-09 对 `dmit-lax` 做 TCP/UDP 调优后，补充了几条更强约束：

- **长期 peer 优先**：如果一些 VPS 即将不续费，只把它们当作观察样本，不要让它们决定长期主机的持久参数。
- **HY2 判断要分层**：HY2 外层是 UDP/QUIC，不直接吃 TCP buffer；但 VPS 作为出口访问网站时，出口 TCP 仍受 BBR、TCP buffer、PMTU、qdisc 影响。
- **不要用 `pkill -f` 清 iperf3**：远端 SSH 脚本里包含同样命令文本时，`pkill -f` 可能杀掉当前 shell。应使用 `iperf3 -D --pidfile`，清理时只 kill pidfile 里的 `iperf3` PID。
- **profile heredoc 要 quoted**：写 Markdown profile 时如果包含反引号代码块，必须使用 `<<'EOF'` 这类 quoted heredoc，避免 shell 命令替换误执行回滚命令。
- **限速要有本机出口证据**：高重传但本机 egress qdisc drop/backlog 为 0 时，不应默认落盘 HTB/TBF/qos-agent。

## 对第三方一键脚本的参考

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
- 把任意 XanMod / `bbr` 都叫 BBRv3
- 无压力证据就写死 `nf_conntrack_max=262144`
- 无双栈对比就永久禁用 IPv6

版本状态：v5.4.4 完整审阅；2026-07-26 复查至 v5.4.6——两个新版本均为安全加固（临时文件 mktemp 化、菜单 32-7 代理鉴权），菜单 3 / buffer 阶梯 / 产物文件零变化，审阅结论对 v5.4.6 仍然有效。若要运行上游工具箱本体，建议 pin ≥ v5.4.6。

完整审阅见 [`references/vps-tcp-tune-review.md`](references/vps-tcp-tune-review.md)。

## 仓库结构

```text
.
├── SKILL.md                         # Skill 主说明
├── references/
│   ├── blog-method.md               # 从原文整理出的详细方法和命令模式
│   ├── tcp-optimize-review.md       # 对 TCP-Optimize 的证据化参考与边界（含 v2.1 增补）
│   └── vps-tcp-tune-review.md       # 对 Eric86777/vps-tcp-tune 的审阅与候选表
├── scripts/
│   ├── inspect.sh                   # 只读检查采集（可经 SSH 远程执行）
│   ├── pmtu-probe.sh                # PMTU 阶梯探测（只读）
│   └── backup-snapshot.sh           # 应用前全量配置快照
├── templates/
│   ├── recommendation.md            # 推荐配置六段式模板
│   └── profile.md                   # 调优 profile 模板
├── agents/
│   └── openai.yaml                  # Codex UI metadata
├── CHANGELOG.md                     # 更新日志
├── README.md                        # 中文说明
└── LICENSE                          # 来源和许可说明
```

## 注意事项

- 不要把私钥、云厂商 token、代理密码直接发给 agent。
- 如果是生产节点，建议先只允许检查和测试。
- HY2 / TUIC / QUIC 不吃 Linux TCP buffer，但仍会受 MTU、qdisc、CPU 调度和出口 shaping 影响。
- qdisc drop/backlog 为 0 但 iperf3 高重传时，不要急着全局限速；更可能是路径、上游或对端问题。
- 一个弱 peer 的结果不能直接推导为全局配置。
- 换内核 / 跑一键脚本前必须 pin 版本、全量备份，并列出副作用文件清单。

## 许可与署名

本仓库内容是对原文方法的 Skill 化整理，并保留原文链接和作者信息。原文标注为 CC BY-NC-SA 4.0，请在使用和二次分发时遵守相应要求。

对第三方脚本的审阅仅为互操作与安全边界说明，不构成对其代码的再授权或背书。
