# v0.1.6 全量审计报告

- **审计对象**：`~/workspace/dns-unlock-panel-v016`，分支 `feature/v0.1.6-takeover`，tip `374e7b7`，基底 v0.1.5（main `817c606`）
- **审计方式**：只读审计。5 条并行审计线（A：P1 修复深挖；B：三件待裁决事项；C：3 个 P3 + 节点一键安装命令；D：全仓库回归；E：对抗评审），各线 findings 原文附后：`AUDIT-V016-LANE-A.md` ~ `AUDIT-V016-LANE-E.md`；总 ledger：`findings-ledger-v016.csv`。
- **实测 diff**：相对 817c606 共 **40 个文件**、+5230/−198（任务简报称 42 个文件，经 `git diff --stat` 实测为 40，特此纠正；内容为 39 项 v0.1.6 实施 + 3 个 P1 修复 commit）。
- **审计结论：FAIL（不可发版）**

## 结论（先说）

原 P1（还原弄坏系统 DNS）**真修了**，两处子修复均有审计方独立重跑的红/绿证。但审计另挖出 **2 个新 P1**，且计划承诺的 3 项功能未交付、台架本身有 3 个 P2 缺陷：

| 严重度 | 数量 | 状态 |
|---|---|---|
| P0 | 0 | — |
| P1 | 3 行 | 1 已修（原 P1，V016-00）+ **2 未修（V016-01、V016-02）** |
| P2 | 13 行 | 全部未修 |
| P3 | 21 行 | 16 未修（裁决修）+ 5 仅记录 |
| **合计** | **37 行** | **36 未修 + 1 已修** |

**必须修完复验通过才能发版的清单**（见末节“结论与发版门”）：V016-01、V016-02（两个新 P1）；V016-03、V016-04、V016-05（计划已承诺项缺口，修或用户明确降级）；V016-06、V016-07、V016-08、V016-09、V016-10、V016-11；V016-12（nspawn 真容器验证）；V016-13、V016-14、V016-15（台架修）。其余 P3 在同轮顺手修（V016-16~26、28、31~34），仅记录的 5 项（V016-27、29、35、36、37）留待下版本。

## 原 P1 验证：已修（V016-00，closed）

“还原会弄坏系统 DNS”由两个 commit 修：`e5dafe6`（还原前先停 agent）+ `ff006ca`（agent 用 IP_PKTINFO 按查询目标地址回包）。审计结论是**真修了**，但证据是审计方自己重跑的，不是修复方声称的那份：

- **P1(a) 停 agent 再还原（A 线）**：自建台架（mount 命名空间 + stub systemctl/ss）在新旧两版还原脚本上跑 10 个场景。旧版红证：还原 markers 只有 `enable → restart`，无 `stop dnsunlock-agent`，还原后 agent 仍在运行占 :53；新版绿证：`stop → enable → restart`，通配符保持停止、指定地址恢复、无配置默认 :53、未运行不动，四个分支逐项按设计工作；停失败或 :53 10 秒未空闲时在任何文件变更前退出。
- **P1(b) IP_PKTINFO 回包（A 线）**：cmsg 布局与内核头文件逐字节核对一致（`in_pktinfo` 12 字节、`in6_pktinfo` 20 字节、`CmsgLen`/`CmsgSpace` 偏移与小端编码）；测试机 netns 新旧二进制对照：旧版 `dig @127.0.0.53` 超时、裸探针证实回包源错为 127.0.0.1；新版正常返回、回包源为 127.0.0.53。
- **E 线对抗复核**：容器内 RED（旧还原 + 旧 agent）复现缺陷（stub EADDRINUSE ×2、exit 0、agent 存活）；GREEN（新还原 + 新 agent，`:53`）证明修复（stub 绑上 ×2、无警告、agent 已停、`dig +tcp @127.0.0.53` 有应答）。另证实 Go UDP 套接字不设 `SO_REUSEADDR`，故停 agent 是必要条件。
- **证据缺口（流程问题，非产品问题）**：修复方声称的“容器红跑复现 P1、绿跑全部通过”**无任何可查证据**——本地 `/tmp/p1-rig-rerun.log` 仅 2 行（rootfs 不存在）、worktree 无日志/汇总、测试机 `machinectl` 为 `No machines.`、`/root/rig` 不存在。本审计的红/绿证是 A/E 两线独立重跑的，结论成立，但修复轮必须把红/绿跑日志归档进仓库（本次审计的证据在各线 findings 文件与 `/tmp/lane-e/`、测试机 `/tmp/p1live/`）。
- **rig 不能为 P1(a)/(b) 作证（A E-2）**：`rig-inner.sh` 无任何断言检查 stop 行为或 agent 状态；所有 dig 均为 `+tcp @127.0.0.1`，无 `dig @127.0.0.53`；沙箱 UDP 回环本身不通。见 V016-15。

## 新 P1-1：临时模式留下持久状态（V016-01）

三线独立命中同一根因，合并为一个 P1（B 定 P1 发版阻塞，D 定 P2，本协调裁决 P1：可致重启后系统 DNS 失效，违背“重启后失效”与“不停任何管理器”的明确承诺）：

- `--temp` 的分流发生在 stub 检查与 agent enable **之后**：stub 冲突时 `disable_stub_listener`（`install.sh:207-222`）写**永久** drop-in `/etc/systemd/resolved.conf.d/dnsunlock.conf` 并 restart resolved；`systemctl enable --now dnsunlock-agent`（`install.sh:803`，含 `Restart=always`）对临时/永久一视同仁；临时模式不写任何备份，还原脚本无备份时只打印提示、不会删 drop-in。
- 重启后两条路都不符合“重启后失效”：resolved 在跑时 stub 仍关 + agent 自启占 `:53`，resolv.conf 若仍指 stub（127.0.0.53）则系统 DNS 直接失效；resolved 未跑时静态 resolv.conf（127.0.0.1）跨重启保留 + agent 自启，分流静默变永久。
- E 线补一刀（F-06）：临时模式的**退出路径本身复现 P1**——`install.sh:482` 与 `restore-resolv.sh:466` 指示的清理办法是 `systemctl restart systemd-resolved`，而此时 agent 还占着 `:53`、stub 从未被关掉；restart 既绑不上 stub、又清掉 resolvectl 设的 per-link DNS，重启后 stub 与 agent 双双不答。只咬 resolvectl 子路径（直接写文件的子路径不受影响）。
- 台架盲区：S4/S5 从未覆盖“`--temp` + stub 冲突”组合，只验了文案输出，未验重启后状态。
- 修复方向：`--temp` 不写持久 drop-in（stub 冲突时拒绝或改走临时端口）、agent 只 `start` 不 `enable`、留临时状态记录供还原清理；临时退出路径改 `resolvectl revert`（或先停 agent 再 restart resolved）；台架补 `--temp` + stub 冲突 + 模拟重启场景。

## 新 P1-2：还原 :53 检查误判且在停 agent 后中止（V016-02）

E 线活体红证（SS-FALSEPOS）+ A 线台架红证合并，定 P1：

- `record_and_stop_agent`（`restore-resolv.sh:129-143`）的 `:53` 占用检查用 `ss -tuln | grep -qE ':53[[:space:]]'`，匹配**任何** `:53` 监听——包括 resolved 自己的 stub（127.0.0.53:53）和一切不冲突的地址；且检查跑在 agent **已经停掉之后**，中止路径永不到 `restore_agent_after`。
- E 线红证：agent 监听 `127.0.0.1:53`、stub 预先起在 .53——还原 exit 1、agent DEAD、`dig @127.0.0.1` 拒绝而 `.53` stub 正常应答。还原前 agent 本来在答 127.0.0.1，中止后无人应答——还原本身把 DNS 搞得更坏，还拒绝继续。
- A 线补证（A-F1，台架两阶段复现）：中止后重跑，agent 已是 inactive，`restore_agent_after` 输出“agent 还原前未在运行，保持停止（未改动）”——与第一次运行前 agent 在运行的事实直接矛盾；agent 从此悄悄丢失，分流静默失效。另 A-F4：stub 已起时会误中止并同样触发 A-F1；D P3-04 为同一检查的另一表述。
- 修复方向：按**冲突**地址检查（通配符 vs agent 实际监听地址），不要按任意 `:53`；检查移到停 agent 之前，或中止时按 `AGENT_WAS_ACTIVE`/`AGENT_LISTEN` 把 agent 起回来（起不回来也要明说）；`:53` 检查排除 127.0.0.53 stub 自身。

## S14 裁决（V016-06 + V016-13 合并说明）

rig 126 PASS + 1 FAIL（S14 `verify_rule_domain`）的根因有**两条并存的解释**，修两边：

1. **台架顺序依赖（主因，B 线以日志链证实）**：S14 用 `getent` 走系统解析器，调用前把 resolv.conf 写成 `nameserver 127.0.0.1`，断言成立当且仅当 agent 当时正在 `:53` 上监听；S14 自身从不启动 agent，隐含假设“S13 残留的 agent 还在跑”。P1(a) 之前还原不停 agent 所以通过；P1(a) 之后 S13 的还原（通配符分支保持停止）使 S14 确定性失败。B 线两次全量重跑一致，且 run 1 日志直接证实状态链（S13 安装起 agent → S13 第一次还原停掉它 → 直至 S14 再无启动）。实施方“不是它的改动造成的”不成立——正是 P1(a) 经由 agent 生命周期状态翻转了 S14；但这不是产品回归。定台架 P2（V016-13）：S14 自给自足（开头显式起 agent、结尾停掉）+ 前置断言。
2. **函数本身的真 bug（D 线沙箱复现）**：`verify_rule_domain`（`install.sh:268-300`）注释称取“第一条 address 模式规则”，实际两处 `sed` 的贪婪 `.*` 在单行 JSON 上恒取**最后一次**出现；末条为 nameserver 模式（`node_ip=""`）时走“当前没有 address 模式的规则”分支返回 rc=2 跳过，尽管前面明明有 address 规则。复现脚本 `/tmp/v016-audit/lane-d/vrd-repro.sh`。定 P2（V016-06）：用 python3/jq 按规则数组解析，取第一条 `mode=address` 且 `node_ip` 非空的规则。
3. **数字对不上（B 线附加）**：B 线两次重跑是 **125 PASS + 2 FAIL**，多出 S9b（台架断言与“`--yes` 还原最早一份”语义矛盾，V016-14，台架 P2）；先前 127 / 126+1 的数字在本次环境下无法复现。需 P1 修复方提供当次 `s9b-restore.log` 对账。E 线另核：磁盘上的 rig 日志同样是 125+2；S14 从日志无法 adjudicate（assert 吞掉了函数输出），且无 P1 机制与之相连（走 TCP `use-vc`）。

## 指定地址恢复分支裁决（V016-12）

- 分支实现（`restore-resolv.sh:145-170`）设计正确：指定地址不与 stub（127.0.0.53）冲突；解析失败默认走安全的“保持停止”；失败有警告且系统 DNS 不受影响。B 线与 A 线均复核通过。
- 但验证缺口真实存在：台架 S11 虽执行过该分支，但**零断言**（无 start 标记、无还原后 dig、无 stub 共存断言）；绿跑只走了通配符分支。残留风险：恢复成功只验 `is-active` 不验端口/解析；重装时对已运行 unit 的 `enable --now` 是 no-op（旧 agent 进程继续跑旧配置，V016-37 仅记录）。
- **缺口已缩小**：E 线 SS-RESTART 在容器内活体证明该分支端到端成立——agent `127.0.0.1:53` 被停、stub 绑上 .53、`restore_agent_after` 重启 agent（新 pid）、stub 与 agent 双答。A 线台架也证实两分支行为与文案一致。
- 裁决仍为 P2：SS-RESTART 用的是 fake systemctl + 真实应答 stub，未覆盖**真 systemd-resolved** 的交互；B 线备好的 nspawn 真容器验证（Ubuntu 24.04 + systemd + resolved，镜像 `/var/lib/machines/v016-nspawn`、面板 token 在 `/root/v016/case.env`）被系统安全检查阻塞未执行。发版前必须补跑该验证——与 P1 修复复验同批做，需用户明确放行（见末节“需用户放行的两件事”）。

## 逐项核查表（ledger 摘要；完整版见 findings-ledger-v016.csv）

| ID | 级别 | 状态 | 标题 | 证据 |
|---|---|---|---|---|
| V016-00 | P1 | 已修 | 原 P1：还原弄坏系统 DNS | A 10 场景台架 + netns 新旧对照；E RED/GREEN 容器 |
| V016-01 | P1 | 未修 | 临时模式留持久状态，重启后断 DNS 或分流变永久；退出路径复现 P1 | B/E/D 三线；`install.sh:207-222,803,482` |
| V016-02 | P1 | 未修 | 还原 :53 检查误判且在停 agent 后中止，agent 悄悄丢失 | E SS-FALSEPOS 活体；A 两阶段复现 |
| V016-03 | P2 | 未修 | PreferFastest 无 UI 开关 | D；协调员抽查：两份 index.html 0 命中 |
| V016-04 | P2 | 未修 | 安装端并行测速未做 | D；协调员抽查：probe_panel md5 与 817c606 一致 |
| V016-05 | P2 | 未修 | installer 基线对比未接线 | D；协调员抽查：install.sh 内 0 处调用 |
| V016-06 | P2 | 未修 | verify_rule_domain 取最后一条规则 | D 沙箱复现 |
| V016-07 | P2 | 未修 | 已提交 .pyc 构建产物 | D；`git ls-files` 命中，0874b2e 带入 |
| V016-08 | P2 | 未修 | restore_agent_after 谎称 resolved 已重新占用 :53 | E NORESOLVED 活体（:53 实测空闲） |
| V016-09 | P2 | 未修 | 无 unit 的 agent 对 P1 修复不可见 | E NOUNIT 活体（新代码复现旧版失败原样） |
| V016-10 | P2 | 未修 | 还原后验证恒返回 0，stub 已死仍 exit 0 | E RED run（两警告 + exit 0） |
| V016-11 | P2 | 未修 | pktinfo 族按地址字符串判定，IPv6 禁用主机静默回退 | A-F7 + E F-04；setsockopt 探针 ENOPROTOOPT(92) |
| V016-12 | P2 | 未修 | 指定地址恢复分支缺真 resolved 容器验证 | B；E SS-RESTART 已活体证分支逻辑，缺真 resolved 一层 |
| V016-13 | P2 | 未修 | 台架 S14 顺序依赖（修台架） | B 两次全量重跑 + 状态链日志 |
| V016-14 | P2 | 未修 | 台架 S9b 断言与“还原最早一份”语义矛盾 | B 两次重跑；需 s9b-restore.log 对账 |
| V016-15 | P2 | 未修 | rig 不能证明 P1(a)/(b) | A E-2；无 stop 断言、无 @127.0.0.53 |
| V016-16 | P3 | 未修 | bbciplayer 在 check 里静默漏掉 | C 实测（16 规则 0 节点 → rules: null → NO_RULES） |
| V016-17 | P3 | 未修 | 自测超 90 秒窗口；error 分支永久遮住迟到结果 | C 实测 84.1 秒（相位不幸约 113 秒）；页内刷新不可见 |
| V016-18 | P3 | 未修 | check 印无关 allowlist 警告（配了也印） | C 实测 stdout/stderr 分离 |
| V016-19 | P3 | 未修 | 零台服务器时节点安装命令跑不通（先卡 token） | C 实测（无 TTY 死在 token 提问；假 token 401） |
| V016-20 | P3 | 未修 | “一键”名不副实：仍要在目标机输 token | C；文案问题 |
| V016-21 | P3 | 未修 | reveal 失败静默吞掉；每行按钮生成同一条命令 | C；`catch{}` + `copyNodeInstall()` 无节点参数 |
| V016-22 | P3 | 未修 | 中止文案“未改任何文件”不实 | A 台架（backups 1→2） |
| V016-23 | P3 | 未修 | restore 按字符串分类：127.0.0.53:53 落入恢复分支 | A 台架 NEW-listen-127.0.0.53-startfail |
| V016-24 | P3 | 未修 | AGENT_WAS_ENABLED 死变量 | A；全文件无读取 |
| V016-25 | P3 | 未修 | SyscallConn() 失败无日志直接回退 | A；代码 |
| V016-26 | P3 | 未修 | udp_stub_test 自洽循环，未覆盖活体与失败路径 | A；头文件对照补了正确性 |
| V016-27 | P3 | 仅记录 | 自定义非 53 监听端口时接管写错 resolv.conf | D；前置缺陷（817c606 已有） |
| V016-28 | P3 | 未修 | 自测结果在 heartbeat 发送前清空，失败即丢失 | D；代码 |
| V016-29 | P3 | 仅记录 | 面板下发配置即消费自测请求 | D；窄窗口 + 10 分钟自愈 |
| V016-31 | P3 | 未修 | check 手写 DNS 客户端：固定 ID、不校验 ID/RCODE | D；代码 |
| V016-32 | P3 | 未修 | 过时注释引用不存在的 run_speed_test | D；全仓仅一处 |
| V016-33 | P3 | 未修 | uninstall 只认 .orig，丢失时跳过 DNS 还原 | D；代码 |
| V016-34 | P3 | 未修 | selftestDone 永不清理；verify_rule_domain 固定 /tmp 文件名 | D；代码 |
| V016-35 | P3 | 仅记录 | 老路还原不恢复 nsswitch/resolved enable 状态 | D；仅影响旧版 .orig 备份 |
| V016-36 | P3 | 仅记录 | install 与 restore 间无锁 | E；代码级，未实测竞态 |
| V016-37 | P3 | 仅记录 | 重装对已运行 unit 是 no-op，旧 agent 跑旧配置 | B；与 V016-12 相关 |

（V016-30 不存在：D P3-04 已合并进 V016-02，不再单独编号。）

## 计划符合度（对照 audit/V016-PLAN.md）

| 计划项 | 结论 | 证据 |
|---|---|---|
| 1. 接管加固 | 符合（另见 V016-01/02） | nsswitch、stub-only、NM conf.d、结构化备份 + metadata、还原列表/备份/验证、双源收敛、use-vc 按探测、hpve-init 提示、Tailscale 守卫均已做 |
| 2. 验证不致命 | 符合 | [4/6] 缺 dig 警告继续；getent 优先验证；但 V016-06（verify_rule_domain 取错规则）削弱了它 |
| 3. 测速选最优 | **偏离** | 节点延迟展示符合；PreferFastest 后端 + agent 符合，但 UI 开关缺失（V016-03）；安装端并行测速未做（V016-04） |
| 4. 自测按钮 | **部分偏离** | 面板自测按钮 + 下发 + 回传均已做；installer 接管前后基线未接线（V016-05） |
| 5. 临时模式 | **偏离** | --temp、resolvectl、直接写、不写备份、不加锁均已做；但留持久状态、“重启后失效”不成立（V016-01） |
| 补充 1：手动输入 DNS 入口 | 符合 | resolve_panel_base + 校验；摘要 + 确认 + 备份失败中止 |
| 补充 2：NM 按连接 UUID | 符合 | 接管/备份/还原/reload 均按 UUID |
| 补充 3：按后端重载 | 符合 | reload_dns_service 按备份后端分发，失败只警告 |
| 不做的 | 符合 | 无 akdns.sh 下载/运行，无硬编码节点列表；stdin→/dev/tty 未动 |

另纠正实施方报告两处说法：①“installer 并行探测候选入口”不成立（probe_panel 与基底字节一致）；②“installer 接管前后用 dnsunlock check 做基线/复测”不成立（install.sh 内 0 处调用）。两处均为协调员独立抽查证实。

## 变体扫荡（E 线对抗评审）

- 同根因（还原时 agent 占 :53）变体：还原脚本（已修主路径）、uninstall.sh（调还原脚本，继承其行为 + V016-10 的 fail-open 出口）、install.sh 重跑（`can_bind_listen` 失败即停，fail-closed，清除）、接管时的 resolved restart（先写 `DNSStubListener=no` 再重启，无冲突，清除）、面板驱动（panel Go 代码无 exec/systemctl，无驱动路径，清除）。漏网：无 unit 的 agent（V016-09）、install/restore 间无锁（V016-36，仅记录）。
- UDP 回包源变体：`grep WriteToUDP` 全仓仅 `serveUDP()` 内两处，均走 pktinfo 路径；`forwardUDP`/`forwardTCP`/check 模式为客户端 connected socket，无需 pktinfo；TCP 不受影响（RED run 中 `dig +tcp @127.0.0.53` 经旧 agent 正常应答，证实破损仅 UDP）。
- 故障注入：stop 失败 → exit 1、agent 存活（E STOPFAIL 活体 PASS）；agent 中途崩溃 → 未注入（unit `Restart=always` 使窗口可达，见 V016-36）；IP_PKTINFO sendmsg 失败 → 回退 `WriteToUDP`（旧行为，有回包好过静默）；IPv6 禁用 → 静默回退旧行为（V016-11）；resolved 未重启 → 谎报已占用（V016-08）。

## 回归套件

- `go build ./...`、`go vet ./...` EXIT 0；`go test ./...` 输出全部 ok（dnsagent 11.5s、panel、sniproxy）。**但正式采信有保留**：D 线与协调员两次重跑均出现 `userConfirmationRequired: timed_out`（输出完整、全部通过，但审批超时）。按规则不重试，测试证据以“已观察到通过、未获正式审批”记录，需用户放行后重跑一次（见末节）。
- 三对嵌入资产字节一致（D 线实测：index.html `bf960831…`、install.sh `2c286b62…`、platforms.json `cc3e2110…`）；`check-restore-sync.sh` 通过（三份还原脚本一致）；全部脚本 `bash -n` 通过；index.html 内联 JS `node --check` 通过；shellcheck 不可用未执行。
- allowlist 默认拒绝：DNS 与 SNI 两端成立（`failClosedAllowlist` 在 `runAgent`/`runProxy` 调用；空 allowlist + 非回环直接拒绝启动；仅回环放行）。token/密码处理未改动、无新问题（0600 配置、curl -K、bcrypt、首次登录强制改密、reveal 需 admin 会话）。SNI proxy 本次零改动；`install-panel.sh`、`install-unlock-node.sh` 零改动。
- 台架：B 线两次全量重跑 **125 PASS + 2 FAIL**（S14 + S9b），与修复方上报的 126+1 / 实施方的 127 对不上（见 V016-14）。台架本身不能证明 P1(a)/(b)（V016-15）。

## 发版与脚本复核

- 未发版，未打 tag，未 push。本审计只读，未改代码。
- 三份还原脚本（`scripts/restore-resolv.sh` + 两份 install.sh 内嵌）经 `check-restore-sync.sh` 验证一致；但 `scripts/__pycache__/sync-restore.cpython-312.pyc` 已提交进仓库（V016-07），须删。
- 存量部署注意（A-F6 观察）：测试机 `/usr/local/bin/dnsunlock-restore-dns` 中 `record_and_stop_agent` 出现 0 次——修复只存在于仓库与新安装包，存量安装必须重跑安装脚本才拿到新还原脚本。发版说明里须写明。

## 动态验证计划（修复轮必须重跑，日志归档进仓库）

1. 容器红/绿跑：旧代码复现两个新 P1（临时模式重启后状态、还原中止路径），新代码证明已修；`dig @127.0.0.53`（UDP）必须出现在绿跑证据里，`dig +tcp` 不能替代。
2. nspawn 真容器验证（B 线已备好镜像 `/var/lib/machines/v016-nspawn` 与面板 token `/root/v016/case.env`）：真 systemd + 真 resolved 下跑 V016-12 的 5 步补验（127.0.0.1:53 与 127.0.0.1:5353 两个端口 + 负向 127.0.0.53:53 可选）。需用户先放行（见末节）。
3. 台架全绿：修 S14（V016-13）与 S9b（V016-14）后，`scripts/test-takeover-rig.sh` 必须回到全 PASS；补 P1 断言（stop 行为、agent 状态、`dig @127.0.0.53` UDP）——V016-15。
4. `go test ./...` 在用户放行后重跑一次，正式采信。
5. 修复轮 UI 改动（V016-03、V016-17、V016-19~21）须在浏览器里点一遍（v0.1.5 时父代理做过同类 24 项验证）。

## 结论与发版门

**结论：FAIL，不可发版。** 原 P1 已修，但两个新 P1 + 三项计划承诺缺口 + 台架缺陷未修。

发版前必须全部完成的清单：

1. **V016-01**（P1）：修临时模式——不写持久 drop-in、agent 只 start 不 enable、留临时状态记录、退出路径改 `resolvectl revert`；台架补 `--temp` + stub 冲突 + 模拟重启场景。
2. **V016-02**（P1）：修还原 :53 检查——按冲突地址检查（先于停 agent）、中止时恢复 agent、排除 127.0.0.53 stub。
3. **V016-03/04/05**（P2，计划承诺）：PreferFastest 加 UI 开关；安装端并行测速；installer 接线 `dnsunlock check` 基线对比。三项修，或用户逐项明确降级（降级须记入计划文件）。
4. **V016-06**（P2）：修 `verify_rule_domain` 取规则逻辑（按数组取第一条 address 且 node_ip 非空）。
5. **V016-07**（P2）：删已提交的 `.pyc`，`.gitignore` 加 `__pycache__/` 与 `*.pyc`。
6. **V016-08/09/10/11**（P2，还原路径）：谎报 resolved 占用改为实测；无 unit 时加端口兜底；验证失败改为非零退出；pktinfo 族按套接字判定或失败回退 `IP_PKTINFO`。
7. **V016-12**（P2）：补 nspawn 真容器验证（需用户放行，见下）。
8. **V016-13/14/15**（P2，台架）：S14 自给自足、S9b 改断言、补 P1 断言；台架回到全绿。
9. **P3 顺手修**：V016-16~26、28、31~34（共 16 项；C 线 6 项 + A 线 5 项 + D 线 5 项）。仅记录的 5 项（V016-27、29、35、36、37）留待下版本。

修完后走**复审**（只审修复 diff + 重跑第 4 节的动态验证计划），复审通过方可发版。时间估计：修复轮半天到 1 天 + 复审半天，顺利 1~2 天；以复审结论为准。

## 残留风险登记

- V016-27/29/35/36/37（仅记录的 5 项 P3）：已知未修，留待下版本；其中 V016-36（install/restore 无锁）与 V016-29（自测请求消费时序）在特定时序下可致 DNS 或自测静默失败，概率低、影响有界。
- V016-11（pktinfo 族判定）：正常双栈主机 latent；IPv6 禁用主机上 P1(b) 静默失效，修复轮若未修须在发版说明里写明。
- V016-12 的真 resolved 一层：SS-RESTART 已活体证分支逻辑，但真 resolved 交互未验；若用户不放行 nspawn，该层残留须在发版说明里写明。
- 修复方容器证据缺失是流程风险：本轮结论不依赖它（审计方独立重跑），但修复轮必须把红/绿跑日志归档进仓库，否则下轮审计同样无法采信。

## 覆盖 ledger

- 审过：40 文件 diff 全量（D 线逐文件）；P1 两 commit 逐行（A/E 两线独立）；8 项计划符合度（D 线表）；3 个 P3 裁决（C 线实测）；台架全量重跑（B 线两次，125+2）；容器活体（A netns 新旧对照、E RED/GREEN/NORESOLVED/NOUNIT/SS-RESTART/STOPFAIL 全场景）；浏览器点按未做（UI 改动在修复轮，见动态验证计划第 5 条）。
- 未审：真实流媒体解锁（测试 IP 均为文档段 203.0.113.x，与此前版本相同）；Caddy 真实反代 + 自动 HTTPS（80/443 被占，与此前版本相同）；生产面板（未碰）。

## 下轮复审条件

复审只在以下条件全部满足时启动：①发版门清单 1~8 项全部落地且有 commit；②动态验证计划 1~4 项的日志已归档进仓库；③台架全绿；④ `go test ./...` 在放行后重跑通过。

## 自查

- 本报告每条 P0/P1 均有红证（旧代码复现、新代码证明），红证来源为审计方独立重跑（A 线台架 + netns、E 线容器场景），非复述实施方说法。
- 跨线冲突已裁决：临时模式（B P1 vs D P2 → 裁决 P1，理由见 V016-01）；S14 根因（B 状态链 vs D 函数 bug → 两条并存，修两边）；P1(b) 族判定（A-F7 与 E F-04 同根因 → 合并）。
- 审计过程未改代码、未 push/tag/发版、未碰生产面板；测试机宿主机只读检查，panel :8080 + agent :53 仍为 v0.1.5（`1084e5e9…`），`/etc/resolv.conf` 未动。

## 需用户放行的两件事（转交父代理）

1. **nspawn 真容器验证**：B 线备好的验证（Ubuntu 24.04 + systemd + resolved，`/var/lib/machines/v016-nspawn`，token 在 `/root/v016/case.env`）被系统安全检查拦住未执行。续跑需用户明确放行（沿用此前 FLMX 发版重试的同类处理）；或由父代理另行安排具备执行权限的代理。续跑命令：`systemd-nspawn --boot --machine=v016-nspawn --directory=/var/lib/machines/v016-nspawn`（沙箱禁 NET_ADMIN，`--network-veth`/NAT 不可用，容器与宿主共享网络命名空间，镜像内 `systemd-networkd` 保持 mask；续跑后轮换/删除测试服务器）。
2. **`go test ./...` 正式重跑**：D 线与协调员两次重跑均输出完整通过、但审批超时未答复。正式采信须用户放行后重跑一次。

## 测试机遗留清理（供父代理）

- 测试机 `/tmp/p1live/`（A 线新旧 agent 二进制、fake panel、探针脚本与日志，备查）；`/root/v016/` + `/var/lib/machines/v016-nspawn`（B 线备好的验证镜像与面板 token，续跑前勿删，续跑后轮换/删除 token）；容器内 `/root/lane-e/`（E 线证据记录）；`/var/lib/machines/v016-test`（B 线重建的台架 rootfs）。宿主机 panel/agent/resolv.conf 均未动。
