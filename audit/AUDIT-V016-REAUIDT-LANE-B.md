# v0.1.6 复审 B 线报告（只审修复 diff 374e7b7..7b86d49）

- **审计员**：B 线（复审，只审修复 diff，不重审全仓库）
- **对象**：`~/workspace/dns-unlock-panel-v016`，分支 `feature/v0.1.6-takeover`，修复区间 `374e7b7..7b86d49`（tip `7b86d49`），基底 v0.1.5（`817c606`）
- **方法**：只读复审。逐项对照代码验收，不采信实施方报告；关键项自己重跑（沙箱 fake-ss/systemctl 台架 + 双慢候选并行测速实测 + 三路 verify_rule_domain 复现）；容器证据逐行核对修复轮归档日志。
- **结论：CONDITIONAL FAIL（有条件不通过）**——9 项中 7 项已修、1 项部分修（V016-08 残留新问题）、1 项证据口径需说明（V016-12 基线非 tip）；另裁决 1 项新事项 **P2、建议挡发版修**（非 53 监听端口接管写死 nameserver，V016-27 升级）。

## 总表

| ID | 级别 | Verdict | 一句话 |
|---|---|---|---|
| V016-03 | P2 | **已修** | 两份 index.html 都有开关、字节一致、开关真接线到规则 prefer_fastest |
| V016-04 | P2 | **已修** | probe_panel 真改了（md5 变了），并行探全部候选、按延迟挑最快；自测双 3s 候选总耗时 3.12s |
| V016-05 | P2 | **已修** | install.sh 真调 `dnsunlock check`：接管前基线 + 接管后复测 + 对比表；run_speed_test 引用已清零 |
| V016-06 | P2 | **已修** | 三路（python3/jq/grep）都取第一条 address 且 node_ip 非空；旧 bug 精确复现情形已验证 |
| V016-07 | P2 | **已修** | `git ls-files` 无 .pyc；diff 删文件；.gitignore 已加两行 |
| V016-08 | P2 | **部分修** | free-case 已修（自测台架 at tip 通过）；但 stub 分支在真实 ss 输出下误判（新残留，见下） |
| V016-09 | P2 | **已修** | 无 unit agent 端口兜底已做；绿跑 green-09 20/20（无 unit，pid 1104→1339） |
| V016-11 | P2 | **已修** | pktinfo 族按套接字实际能力判定；红 FAIL→绿 PASS，go test 全 ok |
| V016-12 | P2 | **已修（证据口径说明）** | 五步补验 28/28 已核对；但绿基线是 3550ebc 不是 tip，好在 tip 之后的代码改动不碰该分支 |
| 新事项：非 53 监听端口接管 | — | **P2，建议挡发版修** | `--dns-listen 127.0.0.1:5353` 时接管仍写 `nameserver 127.0.0.1`，系统 DNS 死 + 安装器自动停用 resolved；还原可干净恢复 |

证据目录：`audit/evidence-v016-fix/lane-b-reaudit/`（harness.sh、harness2.sh、probe_panel.sh、run_probe.sh、slow_server.py、fakebin/、harness-restore.log、harness-measure53.log、probe-parallel.log）。

---

## V016-03 PreferFastest UI 开关 — 已修

- 两份 `index.html`（`web/index.html` 与 `internal/panel/assets/index.html`）各 9 处 `prefer_fastest` 命中，`cmp` 字节一致（md5 `f6119829…`）。
- 开关在两处出现：规则卡片行内 checkbox（`data-f="prefer_fastest"`，带 title 说明“默认关”“可能偏离你点的地区”）与编辑弹窗 checkbox（`#ed-fastest`）；规则行显示“优先最快”badge（line 345/439）。
- 接线完整：行内保存 `g('prefer_fastest')`（line 382）、弹窗保存 `g('ed-fastest')`（line 551）、批量保存（line 608）、导入（line 631）都把该字段放进提交体；面板侧 `internal/panel/panel.go:984/1053` 的保存 handler 接收 `json:"prefer_fastest"` 并写入 `model.Rule.PreferFastest`；agent 配置下发含该字段（`panel.go:1460`，含 Candidates）；agent 侧使用（`agent.go:396` 初始选择、`678` 重选）。
- 缺口说明：本线只做了代码接线核对；ui-lane 的 harness（`audit/evidence-v016-fix/ui-lane/v016-ui-harness.js`）里 `prefer_fastest` 0 命中，无自动化 UI 证据。浏览器点按由复审并行线覆盖，不在本线 verdict 内扣分。

## V016-04 安装端并行测速 — 已修

- `probe_panel()` 真改了：与 `817c606` 的 md5 由 `29aafc27…` 变为 `901afcf0…`（上轮审计时与基底字节一致）。
- 实现：候选入口（原地址、同主机 :8080、解析 IP :8080、本机 127.0.0.1:8080，去重后）全部 `curl --max-time 8 … &` 后台并行 + `wait`，按 `%{time_total}` 排序打印排名，取最快且可达的做 `PANEL_BASE`；诊断打 stderr，stdout 只输出选中地址（调用点 `install.sh:833/849` 用 `$(probe_panel …)` 承接，正确）。
- **自测实证**（非复述实施方报告）：从 tip 提取 `probe_panel` 原函数，两个 3 秒延迟的 fake 面板（`127.0.0.1:18081` 与 `127.0.0.1:8080`，各 3s）——总耗时 **3.12s**（并行，串行应为 ~6s），排名输出两条均为 3002/3004ms，选中其一。日志 `lane-b-reaudit/probe-parallel.log`。
- 小注：并列最快时 `sort -n | head -1` 取排序首位，行为确定，无问题。

## V016-05 installer 基线对比接线 — 已修

- `install.sh` 内 `dnsunlock check` 真调用：`run_dnsunlock_check`（line 372 起）封装调用，`--via` 值由 `cmd/dnsunlock/main.go:236` 的 flag 支持（`agent|upstream`，非法值 exit 2）。
- 接线位置：接管前基线 `--via upstream`（line ~1112，agent 配置已写入之后）；临时模式复测 `--via agent`；永久接管后复测 `--via agent`；两次结果由 `print_check_comparison`（line 413）并排对比打印；未接管时只基线、明说无复测。失败只警告不致命（符合“验证不致命”）。
- **容器实证**（修复轮日志，非实施方口头）：`v016-12-step1-install.log:39/77/95-111`——基线跑了、复测跑了、对比表逐平台打印（tiktok：基线 `23.214.22.237(OK)` → 复测 `203.0.113.99(FAIL)` [变化]）。
- 表中大量 FAIL 是环境所致，非接线问题：`check.go: RunCheck` 的 OK 判定含 TCP :443/TLS 探活，规则 IP `203.0.113.99` 是 TEST-NET 文档段、不可达，故 FAIL；无规则平台的 FAIL 行是 V016-16 修过的“无可用解锁 IP”行。
- `run_speed_test` 全仓引用 0 处（V016-32 的过时注释已删，见 commit `f50de66`）。

## V016-06 verify_rule_domain 贪婪取最后一条 — 已修

- 新实现按规则数组顺序取第一条 `mode=address` 且 `node_ip` 非空且 `domains` 非空的规则：python3 路径逐项循环 `sys.exit(0)`、jq 路径 `select(…) | head -1`、grep 回退按出现顺序 `paste` 配对 + `awk '$2 != "" … exit'`。
- **自测实证**（构造 JSON，三路各跑）：nameserver 规则在前、address 在后 → 取 address；**旧 bug 精确复现情形**（address 在前、末条 nameserver 且 `node_ip=""`）→ 三路都返回 `tiktok.com / 203.0.113.99`，不再误判跳过。
- grep 回退的配对错位风险已排除：`node_ip` 字段无 `omitempty`（`internal/model/model.go:229`），每条规则必出该字段，出现顺序与 domains 一一对应；且回退只在无 python3 又无 jq 时走。
- 另：`mktemp` 替代固定 `/tmp` 文件名（V016-34 一并修了，commit `11aa83b`）。

## V016-07 已提交 .pyc — 已修

- `git ls-files | grep -i pyc` 0 命中；diff 删文件（`Bin 2024 -> 0 bytes`）；`.gitignore` 第 5-6 行已有 `__pycache__/` 与 `*.pyc`（commit `3cda138` + 补 `73935d5`）。

## V016-08 谎报 resolved 已占用 :53 — 部分修（新残留）

**已修的部分**（自测 at tip）：用 fake `ss`/`systemctl` 台架直接跑 tip 的 `restore_agent_after`（`lane-b-reaudit/harness-restore.log`，9/10）：
- free-case：`:53` 空闲时输出“实测 :53 当前空闲（systemd-resolved 的 stub 并未在监听），按还原设计不自动恢复 agent，避免分流静默残留”，并明说“验证会如实报告（验证失败则还原退出码为 1）”，agent 保持停止；`AGENT_WAS_ENABLED` 被 `_enabled_boot_warn` 读取并输出下次启动抢端口警告（V016-24 一并修了）。
- held-case：外来通配符占位时点名“仍被占”，不再谎称 stub。
- 修复轮绿跑 green-08（21/21，基线 3550ebc）佐证测量本身：还原报“实测 :53 空闲”，rc=1 fail-closed。

**新残留（本线自测发现，V016-08 未完全修好）：**
- `measure_53` 的 stub 判定用 `case " $addrs " in *" 127.0.0.53:53 "*)`，但真实 `ss` 输出的 stub 地址带接口后缀——测试机自己的快照就是 `127.0.0.53%lo:53`（见 `v016-12.log` step 3 快照、`green-02.log` 各快照）。实测：
  - `measure_53`（`%lo` 格式）→ `held 127.0.0.53%lo:53`；同样输入去掉 `%lo` → `stub 127.0.0.53:53`。
  - `_addr_host '127.0.0.53%lo:53'` → `127.0.0.53%lo`，`_is_stub_host` 判定为 NO。
- 后果：真实主机上 stub 分支是死代码。通配符 agent + stub 正常监听时还原走 held 分支，文案错说“systemd-resolved 的 stub 未在 :53 上监听”，并建议“请先处理占 :53 的服务”——占着的正是 resolved 自己的 stub。自动行为仍安全（保持停止、不重启 agent、不改系统 DNS），所以定 **P3**，不是 P1/P2；但它与 V016-08 的原要求“实测 stub 才说已占用”直接冲突，且修复轮的容器证据从未跑过通配符+stub 组合（green-08 是 free-case，green-02 是具体地址），故漏网。
- 修法建议（约 2 行）：`_addr_host` 里剥掉 `%…` 后缀（所有调用点一并受益），或 `measure_53` 里归一化后再比对；同时给台架/容器补一个“通配符 agent + stub 在监听”的还原场景。未修之前，held 分支的“处理占位服务”建议会误导用户去动 resolved 的 stub。

## V016-09 无 unit 的 agent 对 P1 修复不可见 — 已修

- 代码：`record_and_stop_agent` 无 unit 时分流到 `record_and_stop_agent_no_unit`（按配置 listen 用 `ss` users 字段找 dnsunlock pid，`pgrep -f dns-agent` 回退，配置过期时按实际监听处理）；停之前先做 `stub_blockers` 冲突检查（外来占位先中止、agent 不动）；停完仍有占位时 `abort_restore_agent` 起回来；`restart_agent` 无 unit 分支直接起二进制并确认端口上确为 dnsunlock。
- **容器实证**：green-09 20/20——unit 文件移走、手动起 agent（pid 1104，`127.0.0.1:53`），还原按端口找到它、停掉、经端口回退重启（新 pid 1339），`dig @127.0.0.1` 与 `dig @127.0.0.53`（UDP）双答。`green-09-restore.log` 亦在档。
- 小注：`restart_agent` 无 unit 分支用 `nohup … &` 起进程，无 `Restart=always` 兜底，崩溃后不自启；与有 unit 行为不对称，但属已知取舍，不扣分。

## V016-11 pktinfo 族按地址字符串判定 — 已修

- `newUDPPktinfo`（`internal/dnsagent/agent.go:1239` 起）不再用监听地址字符串定族：先试 `IPV6_RECVPKTINFO`，套接字拒绝（ENOPROTOOPT，如 IPv6 禁用主机上 Go 建的 AF_INET 套接字）再试 `IP_PKTINFO`；两者都失败才回退明文回包并记日志；`SyscallConn()` 失败也记日志（V016-25）；`Control` 回调未执行时 `setErr` 保持 nil 不再误读为成功（V016-26）。
- **红/绿实证**：`go-lane/V016-11-red.log`——AF_INET 套接字 + 通配符地址旧代码 `pktinfo inactive` FAIL；`go-lane/V016-11-green.log`——同场景 `IPV6_RECVPKTINFO not supported … using IP_PKTINFO instead` PASS；`final-go-test.log` 三包全 ok（dnsagent 18.657s）。

## V016-12 指定地址恢复分支 nspawn 真容器验证 — 已修（证据口径说明）

- `v016-12/v016-12.log`：**28/28**，计数可复核：step 0 基线 7 + step 1（`127.0.0.1:53` 安装）3 + step 2（还原）3 + step 3（共存断言）4 + step 4（`:5353`）8 + step 5（负向 `127.0.0.53:53`）3 = 28，无 FAIL。
- 关键点逐项在日志里：step 3 agent 是新进程（pid 3506→3765，`restore_agent_after` 重启），`dig @127.0.0.1 tiktok.com`（UDP）返回规则 IP、`dig @127.0.0.53 example.com`（UDP）有结果（stub 与 agent 共存，快照 ss 证实双监听）；step 4 `dig @127.0.0.1 -p 5353` 规则 IP；step 5 agent 保持停止、不抢 stub、stub 在监听、系统 DNS 可用。
- **口径说明**：该 log 头注明 `baseline=3550ebc`，不是 tip `7b86d49`。核查 tip 之后的 commit：`f1b0722` 只改了 `restore_agent_after` 的通配符 free-case 分支 + rig 断言，`8af995d/7b86d49` 是文档/证据归档；v016-12 行使的全是具体地址分支（`listen_blocked`/`_is_stub_host`），f1b0722 零触及。故证据对 v016-12 仍有效，但严格说 tip 的完整代码未经 nspawn 重跑——若求全，补跑一次只需重跑该脚本（5 分钟量级），建议复审收尾时顺手补。
- 本线未再自建 nspawn：沙箱 nspawn 早先已证实不可行（`nspawn-smoke-FAIL-20261121-1244Z.log`：`/sys` 只读、sysfs 挂载 EPERM）；测试机宿主机按红线只读，不在上面跑新容器。修复轮的真容器证据本身完整可信，无需重复。

---

## 新事项裁决：非 53 监听地址时接管写死 nameserver 127.0.0.1

### 事实（代码 + 容器实证）

1. 安装器自身把非 53 端口作为合法选项宣传并推荐：用法 `--dns-listen 127.0.0.1:5353`（`install.sh:10/166`）；`:53` 被占时的退路文案四处写“请用 `--dns-listen` 换个空闲端口（如 `127.0.0.1:5353`）”（lines 875/883/894/898）。
2. 三条接管路径都无端口守卫，全部写死 `nameserver 127.0.0.1`（resolv.conf 无端口字段，系统 DNS 永远到不了 `:5353`）：
   - 永久接管：`install.sh:1251`（及 NM/resolvconf/dhclient/netplan 各后端同步写 127.0.0.1）；
   - 临时直写：`write_temp_resolv_conf`（lines 657/659）；
   - 临时 resolvectl：`resolvectl dns "$iface" 127.0.0.1`（同样无端口）。
3. 接管前摘要把矛盾直接印出来还继续走：`v016-12-step4-install.log:60`——`DNS：nameserver 127.0.0.1（agent 监听 127.0.0.1:5353）`，用户答 y 后执行。
4. 容器实证（`v016-12-step4-install.log:72-78`）：写死 nameserver 后 `getent hosts example.com` 无结果；安装器随即触发升级路径——**`systemctl disable --now systemd-resolved`**（彻底停用 resolved）；再验仍失败，才大声警告并给还原命令。step 4 期间系统 DNS 完全死亡（resolv.conf 指无监听的 127.0.0.1:53，resolved 又被停掉），直到用户手动还原。
5. 还原可干净恢复：`v016-12-step4-restore.log`——rc=0，resolv.conf 恢复 stub 软链，验证通过，agent 在 `:5353` 上恢复运行，`dig @127.0.0.1 -p 5353` 规则 IP。

### 定级：P2，建议挡发版修

- **不是 P1 的理由**：默认 `:53` 路径完全不受影响；触发须用户显式 `--dns-listen` 非 53 端口 + 回答 y 确认接管；失败是响亮的（验证警告 + 自检 FAIL，不是静默），还原一键干净恢复（已验证 rc=0）。
- **应当挡发版修的理由**：(a) 这是安装器自己推荐的退路——`:53` 被占的用户按指引换 5353 就会确定性踩中；(b) 摘要文案具有误导性，普通用户无法从“nameserver 127.0.0.1（agent 监听 127.0.0.1:5353）”看出 DNS 会死；(c) 升级路径（停用 resolved）在错误前提下自动执行了破坏性操作，把“分流不生效”升级成“系统 DNS 全死 + resolved 被停”；(d) 修复成本极小——接管确认前按监听端口拒绝/跳过接管并明说即可（agent 本身仍可装、仍可在 `:5353` 上跑，供手动指 DNS 的用户用；临时路径同理）。
- **修法建议**：接管确认摘要前加一道端口检查：`_dl_port != 53` 时不执行接管（永久与临时三路径都跳过），打印“监听端口不是 53，resolv.conf 写不下端口，接管后系统 DNS 到不了 agent；agent 已装好在 `:5353` 上，如需本机走分流请改回 `:53` 重装，或手动把 DNS 指到能到 `:5353` 的转发器”，并跳过“停用 resolved”升级（升级只应在端口为 53 且验证失败时触发）。
- **若用户决定不修就发版**：最低限度——摘要里必须明确警告（不是现在这样把矛盾藏在一行里），升级路径不得在非 53 端口时触发；发版说明登记该已知问题。静默发版不可接受。
- 关系说明：这是上轮 V016-27（P3、仅记录、前置缺陷）的升级——上轮只在代码层面登记，本轮在真容器里实测复现了完整破坏链（写死 nameserver → 验证失败 → 自动停用 resolved → 系统 DNS 全死），且安装器推荐语使触发路径真实存在，故升为 P2 并建议挡发版。

---

## 本线 verdict：CONDITIONAL FAIL

- 9 项中 7 项已修（V016-03/04/05/06/07/09/11），1 项部分修（V016-08：free-case 已修，stub 误判残留 P3），1 项已修但证据基线非 tip（V016-12，实质不受影响）。
- 发版门：修掉 **非 53 接管守卫（新 P2）** 与 **V016-08 的 `%lo` 误判（新 P3，可顺手同轮修，约 2 行）**，并对这两处补跑验证（容器或本线同款台架），即可转 PASS。V016-12 的 tip 重跑（5 分钟量级）建议顺手补，但不是转 PASS 的必要条件。
- 其余说明：本线未碰生产面板与测试机宿主机；测试机宿主机 `/etc/resolv.conf` 未动；未 push/tag/发版；沙箱内自建的 fake 服务已停（`/tmp/lane-b-v016` 临时文件未留进程，另有其他 lane 的残留 `dnsunlock` 进程在 `:53`/`:18080` 上，本线未碰）。
