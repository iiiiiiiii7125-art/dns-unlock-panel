# v0.1.6 复审 — C 线：P3 修复 diff 复审（16 项裁决修 + 5 项仅记录 + 节点一键安装命令）

- 审计员：C 线（只读复审；未改代码、未 push/tag/发版、未碰生产面板 https://dns.0v0.baby；测试机未动）
- Worktree：`~/workspace/dns-unlock-panel-v016`，分支 `feature/v0.1.6-takeover`，修复区间 `374e7b7..7b86d49`（tip `7b86d49`），基底 v0.1.5（`817c606`）
- 方法：逐项读修复 commit diff + 当前代码复核 + 本地重跑（`go build`、`go vet`、`go test`、`node --check`、UI vm harness、shell 同步检查）。UI 相关项只做代码 + served 标记检查，未做任何浏览器操作。
- **本线 verdict：PASS** —— 16 项裁决修全部已修（代码级验证通过，无新引入的 P0/P1/P2；仅 2 处 P3 级残留观察，见 V016-21 与 V016-26）；5 项仅记录确认未被顺手改动；节点一键安装命令未被修复轮弄坏。UI 项标注“待浏览器点通确认”（见各节；另见末节关于父代理浏览器结果的备注）。V016-24 产品决定建议见专节。

## 逐项 verdict

| ID | 修复 commit | Verdict | 一句话证据 |
|---|---|---|---|
| V016-16 | 3e4c001 | 已修 | 面板保留无法解析规则（NodeIP 空），check 出 FAIL 行 exit 1；agent 服务端跳过不可用规则，DNS 行为不变；新测试全过 |
| V016-17 | 61ea337 + 9c661cf | 已修 | 窗口 90s→150s；超时后 watchLate 继续等 10 分钟、结果到即清 error；detailRow 按 request_id 对账；探活改 16 并行（4 条黑洞 20.0s→5.0s）；UI harness 17a–d 全过 |
| V016-18 | 6225189 | 已修 | runCheck 传配置 allowlist + 新增 QuietAllowlistWarning（仅 check 置位）；agent/sni 警告与 fail-closed 原样不动；新测试全过 |
| V016-19 | 171d919 | 已修 | 零服务器时 copyNodeInstall/copyUnlock 不复制、提示先登记服务器并说明 token 原因；旧错误注释已删；UI harness 19 全过 |
| V016-20 | 0cd05ff | 已修 | 三处文案均如实说明目标机上还要输 agent token（含无 TTY 直接退出）；“粘贴执行即可”已改掉；UI harness 20 全过 |
| V016-21 | 0e60544 | 已修（1 处小残留，见正文） | 每行传 nodeId、命令首行注释标明节点；reveal 全失败不复制、如实报错；部分失败点名缺失的服务器；UI harness 21 全过 |
| V016-22 | 103342f | 已修 | 两处中止文案 + 注释改成“只写了一份还原前备份，未改系统 DNS 配置”，PRE_RESTORE_BACKUP 三份同步；残留的“未改任何文件”只在备份失败分支，表述为真 |
| V016-23 | 159b82d | 已修 | 新增 listen_blocked 按实际冲突分类；stub 地址/被占地址保持停止并明说；起失败警告写明分流已丢 + 恢复办法（分有无 unit 两版） |
| V016-24 | 9a5e889 | 已修（字面）+ 产品决定待定 | AGENT_WAS_ENABLED 被 6 处 keep-stopped 分支读取（_enabled_boot_warn）；只警告不开机竞态，是否直接 disable 见专节建议 |
| V016-25 | b6523c8 | 已修 | SyscallConn() 失败分支补 log，与 setsockopt 分支一致；新测试全过 |
| V016-26 | 4e2daa8 | 已修（1 处环境限制，见正文） | 补内核 OOB 活体测试、活体回包源测试、两条失败路径测试；附带修了真 bug（Control 错误被丢弃致已关闭套接字谎报 active=true） |
| V016-28 | 11ad611 | 已修 | heartbeat 失败时把自测结果放回，下次再发；其间有更新结果时不覆盖新的；新测试全过 |
| V016-31 | f43721f | 已修 | 随机 ID + 校验 ID/RCODE + 标签/域名长度检查；新测试全过；调用方已同步改签名 |
| V016-32 | f50de66 | 已修 | 两处过时注释已删/改；全仓 grep run_speed_test 0 命中 |
| V016-33 | a54151f | 已修 | uninstall 改认三种接管痕迹（.orig / 结构化备份 / temp-state），任一存在都先还原；找不到还原脚本的报错同步改口径 |
| V016-34 | 435faa6 + 11aa83b | 已修 | selftestDone 记时间戳、每次轮询清 >1 小时条目（含无时间戳旧条目）；verify_rule_domain 改 mktemp，curl 失败分支也删临时文件，无泄漏路径 |
| V016-27 | — | 仅记录，未动 | 接管仍无条件写 nameserver 127.0.0.1（install.sh:1251-1253 等），diff 内无相关改动 |
| V016-29 | — | 仅记录，未动 | panel.go 本区间 diff 只有 V016-16 的 18 行；SelftestPending 消费逻辑 0 改动 |
| V016-35 | — | 仅记录，未动 | restore_legacy 仍只 restart resolved、不恢复 nsswitch、不重启用被停用的 resolved |
| V016-36 | — | 仅记录，未动 | 全区间 diff 里 "flock" 只出现在审计文档（lane E 报告 + ledger），代码 0 处加锁 |
| V016-37 | — | 仅记录，未动 | enable --now 两处只有缩进移动（进 temp/永久分支），未加“已 active 则 restart” |

## 逐项证据

### V016-16 — bbciplayer 静默漏规则：已修（3e4c001）

- 面板 `internal/panel/panel.go:1446`：删掉 `if !ok || !validIP(ip) { continue }`，无法解析的规则保留进 `cfg.Rules`（NodeIP 为空）；nameserver 模式无上游时同样保留（删掉 `Nameserver == ""` 的 `continue`）。
- check `internal/dnsagent/check.go`：NodeIP 为空的 address 规则出 FAIL 行（`no usable unlock IP for region GB`，无 region 时为 `no usable unlock IP for this rule`），nameserver 规则 Nameserver 为空时出 FAIL 行（`nameserver not set for this rule`）；均置 `anyFail`，不再拿上游真实 IP 探活误报 OK。
- agent 服务端 `internal/dnsagent/agent.go:rebuildDomainsLocked`：NodeIP/Nameserver 为空的规则跳过，不进 domain map——域名保持走上游转发，DNS 行为与修前一致（注释写明跳过的原因：否则会 NODATA 非 A 查询）。
- 测试：新增 `TestAgentConfigKeepsUnresolvableRules`（面板保留 bbciplayer，NodeIP 空、有 domains）、`TestRunCheckUnresolvableRuleFails`（FAIL 行、`-` IP、exit 1）、`TestRebuildDomainsSkipsUnresolvable`（lookup 不匹配 bbci、可解析规则仍匹配）。本地重跑三者全过；`go test -count=1 -race` 相关用例全过。
- 无新问题：`check` 在“真无规则”时仍印 `NO_RULES` exit 0（`TestRunCheckNoRules` 全过），与“有规则无 IP”可区分。

### V016-17 — 自测超 90 秒窗口 + error 永久遮住迟到结果：已修（61ea337 + 9c661cf）

三处原缺陷全部修掉（审计原裁决“三选一”，修复方三项全做）：

1. **窗口 90s→150s**：`web/index.html` `runSelftest` 轮询 `30×3s` 改为 `50×3s`；pending 文案改“最长约 150 秒”。
2. **error 不再永久遮住**：新增 `watchLateSelftest`——超时后每 15 秒查一次、最长 10 分钟，结果一到就把 error 清掉并展开；中途重跑（request_id 变了）即停。`selftestDetailRow` 开头按 request_id 对账：`last_selftest` 就是本次请求时直接清 error/pending 并展开结果——页内刷新（15 秒 pollStatus 触发的 renderServers）同样走这条路。超时文案改成“仍在后台等，结果到了会自动出现在这里”，不再谎称“可稍后查看本行下方结果”。全仓唯一残留的“90 秒”是 `index.html:703` 的一处代码注释，非用户可见文案。
3. **探活改并行**：`internal/dnsagent/agent.go:runSelftest` 改 16 并发有界并行，结果按索引收集、仍按平台排序，`last_selftest` 结构不变。并发安全核过：`resolveForSelftest` 经 `lookup()`（`a.mu.RLock` + `overrideMu`）读共享状态、`probeIP` 无状态（局部 dialer，只读包级 `probePort`）；规则快照在 `rulesMu` 下取。最坏耗时由约 113 秒（14×5s 串行 + 5s 取请求 + 30s 心跳相位）降到约 40 秒（探活约 5 秒 + 其余不变），150 秒窗口有裕量。
- 验证：修复方证据 `audit/evidence-v016-fix/go-lane/V016-17-green.log`（4 条黑洞规则 5.046s / 5.001s，旧代码 20.014s）；本地 `-race` 重跑 `TestSelftestProbesInParallel`、`TestSelftestRoundTrip`、`TestSelftestProbeFailure` 全过。UI vm harness（见下“UI harness”）17a–d 全部通过（窗口内出结果行、超时报 150s、文案承诺自动出现、迟到结果清 error、detailRow 对账）。
- 标注：**待浏览器点通确认**（按任务要求，本线不下浏览器结论）。

### V016-18 — check 印无关 allowlist 警告：已修（6225189）

- `cmd/dnsunlock/main.go:runCheck`：把配置文件里的 allowlist（逗号切分、去空白）传进 `New()`；并新增 `Config.QuietAllowlistWarning`，仅 check 置位。
- `internal/dnsagent/agent.go:198`：警告条件加 `&& !cfg.QuietAllowlistWarning`。全仓 grep：该标志只在 runCheck 一处被置位，dns-agent / sni-proxy 入口不动；fail-closed 启动检查未改。
- 测试：新增 `TestNewQuietAllowlistWarning`（quiet 不警告、非 quiet 照常警告、配了 allowlist 不警告）。本地重跑通过。修复方证据 `V016-18-green.log` 在档。
- 治标 + 治本双修：配了 allowlist 也不警告（传 allowlist），且 check 根本不监听、警告语义上就不适用（quiet 标志）。

### V016-19 — 零服务器时节点安装命令跑不通：已修（171d919）

- `copyNodeInstall()` 与 `copyUnlock()` 开头加 `if(!SERVERS.length)` 守卫：不写剪贴板、alert 提示先去「DNS 服务器」页登记一台，并说明原因（安装脚本先校验 agent token，没有服务器就没有可用 token）。
- 节点页提示与服务器页 `--unlock-node` 命令旁同步加“先登记一台再装”文案；旧错误注释（一台都没登记就不带 allowlist 变量、安装时按提示输入）已删掉。
- UI vm harness 19 全过（零服务器不复制、提示含“先登记”与 token 原因、unlockCmd 同样被守卫）。
- 标注：**待浏览器点通确认**。

### V016-20 — “一键”名不副实：已修（文案，0cd05ff）

- 复制成功提示改成“执行时会问 agent token：填任意一台已登记 DNS 服务器的 token（「DNS 服务器」页可查看）”；节点页提示与服务器页 `--unlock-node` 段同步补 token 说明（含无 TTY 直接退出的提醒）；“粘贴执行一次就装好”改成“粘贴执行就装好”+ 紧跟 token 说明，不再冒充真一键。另节点页提示补了 C-04 备注的 allowlist 公网出口 IP 确认句。
- `copyUnlock()` 本身无 alert，靠服务器页段落文案说明（已补）。UI vm harness 20 全过（含“无裸‘粘贴执行即可’”断言）。
- 标注：**待浏览器点通确认**。

### V016-21 — reveal 静默吞掉 + 每行按钮同一条命令：已修（0e60544），1 处小残留

- 每行按钮改传自己节点 id：`renderNodes` 渲染 `copyNodeInstall('${n.id}')`；`copyNodeInstall(nodeId)` 在复制的命令首行加注释 `# 在「<名>（<IP>，<地区>）这台机器上执行：装 SNI 解锁代理；执行时会问 agent token…`。注释写明行绑定只能落在注释里（安装脚本 `--unlock-node` 模式只认 `DNS_SNI_ALLOWLIST`，不认节点名），不冒充命令本身带节点身份。节点名里的 `\r\n` 先去掉，防注释断行注入；其余字符在 `#` 注释行内无执行意义。
- reveal 不再 `catch(e){}`：全失败时不复制、alert 如实报“取 DNS 服务器 IP 失败：<哪台>（原因）”；部分失败时复制已有 IP 的命令、alert 点名哪台没取到（allowlist 可能不全）。旧谎话“未登记 DNS 服务器”已删；`!ips.length` 时的提示改成“已登记的服务器没有可用的 IP，安装时按提示输入”，表述为真。
- UI vm harness 21 全过（全失败不复制且不谎称未登记、部分失败点名、两行命令不同且各带节点名、换行不破注释）。
- **残留观察（P3 级，不改 verdict）**：reveal 返回成功但 `ip` 为空的服务器（注册时 IP 字段可为空，后端只在非空时校验 `validIP`）会被静默跳过、不计入 `failed`，也不在提示里点名。多台中个别空 IP 时 allowlist 会悄悄缺一台且无提示。建议下轮把 `j.ip` 为空也计入 `failed`（或提示“某服务器未填 IP”）。
- 标注：**待浏览器点通确认**。

### V016-22 — 中止文案“未改任何文件”不实：已修（103342f）

- 两处中止文案（停失败、`:53` 仍被占）+ 注释改成“只写了一份还原前备份（${PRE_RESTORE_BACKUP}），未改系统 DNS 配置”；`PRE_RESTORE_BACKUP` 在结构化与老路两处主流程里都被赋值（`scripts/restore-resolv.sh:952,972`），未赋值时有 fallback 文案（见备份目录下最新一份）。三份还原脚本同步（`check-restore-sync.sh` 通过）。
- 全仓残留的“未改任何文件”只剩备份失败分支（`do_backup` 失败即中止、确实未改），表述为真；另 V016-02/V016-09 修复轮新增的中止文案已同步用“只写了一份还原前备份”口径。

### V016-23 — restore 按字符串分类：已修（159b82d）

- 新增 `listen_blocked <listen>`（`ss -tulnp` 全端口）：监听被挡 ⟺ 有监听占完全相同地址、或通配符监听占同端口；归属 dnsunlock 的行不算（自己刚停掉的残留）。`*)` 分支改为三档：监听地址就是 stub 地址（127.0.0.53/54:53，端口 53）→ 保持停止并解释会抢 stub + 恢复办法（重跑安装改 `--dns-listen`）；当前被别的进程挡住 → 保持停止并点名占用的监听地址 + 恢复办法；不冲突才起回来。
- 起失败警告改口径：写明“分流已停止；系统 DNS 不受影响”，分有无 unit 两版恢复办法（`systemctl start` / 直接跑二进制命令 + journalctl），失败仍写 pending marker。
- 辅助函数核过：`_addr_host`/`_addr_port`、`_is_wildcard_host`（`""`、`*`、`0.0.0.0`、`::`）、`_is_stub_host`（127.0.0.53/54）均已存在且语义正确；`ss -tulnp` 在非 root 下拿不到 users 字段时退化为保守判定（当作挡住），不误放。
- 小说明：被占分支的文案点名的是占用方的监听地址（如 `0.0.0.0:53`），不是进程名——符合“按实际冲突分类 + 写明分流已丢及恢复办法”的裁决要求。

### V016-24 — AGENT_WAS_ENABLED 死变量：已修（字面，9a5e889）+ 产品决定待定

- 新增 `_enabled_boot_warn`：agent 保持停止、且还原前是开机自启（`systemctl is-enabled` 置位，`restore-resolv.sh:392`）时，提醒下次启动还会绑 `:53` 与 resolved 抢端口，并建议 `systemctl disable` 或重跑安装。
- 调用点 6 处，覆盖全部 keep-stopped 分支：通配符 stub/free/held/unknown 四档 + 具体地址 stub-addr/blocked 两档（commit 信息称五处，实测六处——free 分支经 V016-08 修复后同样保持停止，也加了警告，比宣称的多一处）。`AGENT_WAS_ACTIVE != 1` 分支不是 keep-stopped，不调用，正确。
- 字面裁决（“删掉或用起来”）已满足；但只警告不处理，下节给出产品决定建议。

### V016-25 — SyscallConn() 失败无日志：已修（b6523c8）

- `newUDPPktinfo` 的 SyscallConn 失败分支补 `log.Printf`（与 setsockopt 失败分支同口径），仍返回 inactive。新增 `TestPktinfoSyscallConnFailureLogs`，本地重跑通过；修复方红/绿日志在档。

### V016-26 — udp_stub_test 自洽循环：已修（4e2daa8），1 处环境限制

- 新增：`TestPktinfoLiveKernelOOB`（真实发包到 127.0.0.2，`dstFromOOB` 读内核给的 OOB，不再自洽；畸形 cmsg 得 EINVAL 即失败，沙箱策略性 EPERM 可接受；回包发出时断言客户端看到的源为 127.0.0.2）；`TestServeUDPLiveReplySource`（真实 agent 实问实答，先以 total 计数证明查询已处理，再断言回包源为被查询的 127.0.0.2 与答案为规则 IP）；`TestPktinfoClosedConnInactive` 与 `TestPktinfoSetsockoptFailureLogged`（两条失败路径 + 日志断言）。
- 附带修了真 bug：`newUDPPktinfo` 原先丢弃 `raw.Control` 错误，已关闭套接字会谎报 `active=true`（setsockopt 从未执行）；现 Control 出错即记日志并返回 inactive（`trySet` 封装，两次 setsockopt 均覆盖）。
- 本地重跑：`TestPktinfo*` 全过（含 `TestPktinfoLiveKernelOOB` 真实内核 OOB 断言）；`TestServeUDPLiveReplySource` 在本沙箱 SKIP（`udpSendBlocked()` 判 EPERM，测试自述“回包源需真机”）——活体回包源断言在本环境未执行，这是测试自带的环境门，不是修复缺失；真机一层由容器验证（lane A/B 范围）承载。
- **证据瑕疵记录**：修复方归档的 `go-lane/V016-26-green.log` 本身含一次 FAIL（`TestServeUDPLiveReplySource: agent did not bind :15353`，当时测试绑固定端口，并行碰撞所致）；随后 `V016-26-flake.log` 与 `V016-26-rerun.log` 均为 PASS（含 SKIP）。tip 版测试已改临时端口 + 5 次重试绑定，本地重跑不再复现该 flake。commit 信息称“8 次连跑 8/8”与归档日志（1 FAIL + 2 PASS）对不上——数字口径问题，不影响结论。

### V016-28 — 自测结果在 heartbeat 发送前清空：已修（11ad611）

- `sendHeartbeat`：`panelDo` 失败时把已取出的结果放回（`selftestMu` 下，若 `selftestResult == nil` 才放回；其间已有更新的自测结果时旧结果被取代、不覆盖新的）。取结果与放回均在 `selftestMu` 锁内；`runSelftest` 的写结果同样在锁内，无新竞态。
- 测试：新增 `TestSelftestHeartbeatFailureRestores`（失败后恢复、成功后发送一次并清空），本地 `-race` 重跑通过；修复方红/绿日志在档。失败重试间隔为心跳周期（30 秒），结果不再永久丢失。

### V016-31 — check 手写 DNS 客户端：已修（f43721f）

- `buildQuery`：`crypto/rand` 每查询随机 ID（返回给调用方），拒空域名、>253 字节域名、空标签、>63 字节标签；`parseAnswerA` 校验应答 ID 与 RCODE==0；`resolveVia` 同步改签名并传 ID。调用方核过：`buildQuery`/`parseAnswerA` 仅 `check.go` 内与测试使用，无遗漏调用点（`go build` 通过为证）。
- 测试：新增 `TestBuildQueryRandomIDAndLabelChecks`、`TestParseAnswerAValidatesIDAndRcode`，本地 `-race` 重跑通过；既有 `TestRunCheck*` 全过；修复方红/绿日志在档。

### V016-32 — 过时注释 run_speed_test：已修（f50de66）

- 两处注释改掉“测速环节缺 dig 仍是致命的（见 pick_fastest_ip / run_speed_test 的约定）”旧说法；全仓 grep `run_speed_test` 0 命中。`scripts/install.sh` 与 `internal/panel/assets/install.sh` 同步改。

### V016-33 — uninstall 只认 .orig：已修（a54151f）

- `scripts/uninstall.sh`：TAKEOVER 改为三者任一存在即还原（`/etc/dnsunlock/resolv.conf.orig`、`/var/lib/dnsunlock/backup/*/`、`/etc/dnsunlock/temp-state/state`）；找不到还原脚本的报错同步改口径（列三种痕迹）。`set -euo pipefail` 下 `ls -d …/*/ && TAKEOVER=1` 的失败是 AND 列表，不会误退出；备份目录不存在时 `ls` 失败、TAKEOVER 保持 0，正确。
- 注意：temp-state-only 触发时调的还原脚本的临时清理本身随 V016-01 落地（commit 信息自述），属 A/B 线范围，本线不另判。

### V016-34 — selftestDone 永不清理 + 固定 /tmp 文件名：已修（435faa6 + 11aa83b）

- Go 部分：`selftestDoneAt map[string]time.Time` 记每条完成时间；`maybeStartSelftest` 每次轮询清掉 >1 小时的条目（含无时间戳的旧条目）；面板 10 分钟 pending 窗口远小于 1 小时，去重窗口不受影响。锁顺序核过：清理在函数开头 `selftestMu` 下做，无双重加锁。
- Shell 部分：`verify_rule_domain` 改 `mktemp /tmp/dnsunlock-agent-config.XXXXXX`；curl 失败分支删临时文件；其余返回点都在唯一的 `rm -f "$cfg"` 之后，无泄漏路径。
- 测试：新增 `TestSelftestDoneExpires`（过期/无时间戳重跑、新鲜仍去重），本地重跑通过；修复方红/绿日志在档。

### V016-27 / 29 / 35 / 36 / 37 — 仅记录：确认未被顺手改动

- **V016-27**：接管路径仍无条件写 `nameserver 127.0.0.1`（`scripts/install.sh:1251-1253` 静态写盘、`1209` resolvconf head、`657-661` 临时模式），本区间 diff 内无 `nameserver 127.0.0.1` 相关改动；V016-01 的临时模式改动只动了 `--temp` 分支（端口被占改走 127.0.0.1:53），未给永久接管加非 53 守卫。登记状态保持。
- **V016-29**：`internal/panel/panel.go` 本区间 diff 只有 V016-16 的 18 行（12+/6-）；`SelftestPending` 0 命中改动。下发即消费、10 分钟自愈的原状保持。
- **V016-35**：`restore_legacy` 现状仍只 `restart systemd-resolved`、不恢复 nsswitch、不重启用被 `disable --now` 停用的 resolved（其余还原项 NM/dhclient/netplan/resolvconf/cloud-init 均在）。登记状态保持。
- **V016-36**：全区间 diff 里 `flock` 只出现在审计文档（lane E 报告与 ledger 的登记行），代码 0 处加锁。登记状态保持。
- **V016-37**：`systemctl enable --now dnsunlock-agent` 两处只有缩进移动（进 temp/永久条件分支），未加“unit 已 active 则 restart”。登记状态保持。

## 节点一键安装命令（374e7b7 功能）——修复轮未弄坏

- **allowlist 取已登记服务器公网 IP**：`copyNodeInstall(nodeId)` 仍逐台调 `reveal` 取完整 IP、去重、`ips.join(',')`、整体 `sq()` 包进 `DNS_SNI_ALLOWLIST`；`serverInstallCmd` 同样用 `sq()`。两份 `index.html` 字节一致（`cmp` 通过）、两份 `install.sh` 字节一致、`check-restore-sync.sh` 通过。
- **零服务器时不带变量**：已升级为不生成命令（V016-19）：`!SERVERS.length` 时 alert 提示先登记服务器，`copyUnlock()` 同样被守卫；节点页与服务器页文案同步。
- **按钮旁 443 提示仍在**：节点页提示仍含“SNI 代理要占 443 端口，被 nginx/Caddy 占了要先让出来”（`web/index.html:174`），另新增 allowlist 公网出口 IP 确认句。
- **每行按钮**：V016-21 后各行命令首行注释不同（节点名/IP/地区），命令体仍相同（安装脚本只认 allowlist，不认节点名；注释已写明）。
- UI vm harness（修复方 `audit/evidence-v016-fix/ui-lane/v016-ui-harness.js`，路径改到本 worktree 后重跑）：**30 passed, 0 failed**（17/19/20/21 全项）。
- 标注：**待浏览器点通确认**。

## V016-24 产品决定建议：直接 disable agent

**建议：还原在有意 keep-stopped 的分支里直接 `systemctl disable dnsunlock-agent`（仅当还原前是 enabled 时），并把文案从“警告下次启动会抢端口”改成“已将其改为不开机自启（disable），手动 `systemctl start` 仍可用，重跑安装脚本会重新接管并恢复自启”。**

理由：

1. **警告的渠道不可靠**：还原可被非交互调用（`uninstall.sh` 以 `--yes` 调还原脚本），那时根本没人读 stdout；即使人工跑，警告也是一闪而过的单次输出，而后果发生在下次开机——时间与注意力完全错位。
2. **留下的状态与还原的本意直接矛盾**：还原的本意是去掉分流；一个 enabled 的 agent 下次开机仍会抢 `:53`，与 resolved 的 stub 争先——谁先绑上谁赢，另一方失败。agent 赢了则 stub 起不来、系统 DNS 异常；resolved 赢了则 agent 起不来、还可能因 `Restart=always` 反复拉起重试（本轮容器验证新发现的同类项）。这是一个已知会在重启后复活的竞态，只警告等于把确定性留给运气。
3. **disable 的代价极小且可逆**：`disable` 只关开机自启，不阻止手动 `systemctl start`，也不影响重跑安装脚本（安装流程本来就会 `enable --now`）。用户想恢复分流时一条命令即回；误还原时也不会丢数据（备份与配置都在）。
4. **与现有文案的判断一致**：修复方自己的警告文案已经认定“应执行 systemctl disable”，只是把执行推给用户；由脚本直接做完，是把已认定的正确动作落到实处，不是新增行为。
5. **范围收敛**：只在 6 处有意 keep-stopped 分支里做（且仅当 `AGENT_WAS_ENABLED=1` 时）；`free` 分支（stub 没起来、系统 DNS 可能已不可用）同样适用——此时留一个 enabled 的 agent 在下次开机抢端口，只会让故障更难定位。`AGENT_WAS_ACTIVE != 1`（还原前未运行）时不动。

不选“保持只警告”的理由：它把本可由脚本一次做对的事，变成依赖用户在正确的时间读到一行警告并手动执行；本轮审计已多次证明“用户按字面意思等在原地”类的文案依赖是靠不住的。

## 附录 A — C7br/C7cr 裁决（浏览器线 OPEN 项，本线顺带裁决）

MEMORY 更新称浏览器复测 `results-retest.json` 的 C7br/C7cr（每服务器复制命令）标 FAIL，脚本与面板数据已销毁、父代理无法直接对账，要求复审裁决。本线用保存的命令文件 + 代码追踪裁决如下：

- **结论：harness 误判，非产品缺陷。`copyServerInstall` 正确。**
- 保存的文件为证（token 值本身不抄录，只比对）：`server-install-cmd-01.txt` 与 `server-install-cmd-01-retest.txt` 字节完全相同（sha8 `7b3336c0`，184 字节）；`server-install-cmd-02-retest.txt`（158 字节）的 token 与 01 的 **不同**（sha8 `499a9adb` vs `b5c93e22`，均为 32 字符）；两条命令各带自己的服务器名与默认解锁 IP（TEST-SRV-01/203.0.113.50、TEST-SRV-02/203.0.113.60）。
- 代码为证：`copyServerInstall(id)` 按行 id 调 `reveal(id)`，`serverInstallCmd(s, j.token, …)` 嵌该 token 与该行名；`handleReveal`（`panel.go:1133`）按精确 server ID 查表返回该台 token。按构造就不可能两行拿同一 token。
- check 自身的 detail 与其 pass  flag 矛盾：解析后的 detail 为“本台 token=true、名=true、另一台 token=false”——即它采集到的证据满足它自己的检查名（带本台 token 与名、不含另一台 token），却仍标 `pass=false`。首轮 `results.json` 的 C7b/C7c 同样 FAIL（detail 为命令本身 / 空），同一模式。脚本已销毁，无法确定是 pass 计算写错还是拿了过期期望值；但保存文件 + 代码两路证据一致指向产品正确。
- 影响范围：C7 是 `copyServerInstall`（每服务器安装命令），不在本线原定的节点命令范围内；本线节点命令（`copyNodeInstall`）的 30 项 vm harness 断言全部通过，不受此项影响。

## 附录 B — 本轮复核的执行记录

- `go build ./...`、`go vet ./internal/dnsagent/ ./internal/panel/ ./cmd/dnsunlock/`：EXIT 0（仅 GOPATH/GOROOT 同目录 warning，与代码无关）。
- `go test -count=1 ./...`：全部 ok（dnsagent 18.5s、panel、sniproxy）。**注意**：该次调用返回了 `userConfirmationRequired: timed_out`，但终端输出已完整显示通过结果；按指令不重试，特此说明——正式采信需父代理/用户侧的审批口径处理（与前两轮相同的情况）。
- `go test -count=1 -race`（V016-16/17/18/25/26/28/31/34 相关用例）：全过。
- `node --check`（提取的 `web/index.html` 内联 JS）：通过。`cmp`：两份 index.html 一致、两份 install.sh 一致。`scripts/check-restore-sync.sh`：通过。
- UI vm harness（路径改到本 worktree 后重跑）：30 passed, 0 failed。
- 修复方证据抽查：go-lane 红/绿日志（V016-16/17/18/25/28/31/34）在档且与本轮重跑一致；V016-26 绿日志含一次 FAIL（见正文，已说明）；ui-lane harness 与本轮重跑结果一致。
- 本线未改 worktree 代码（`git status` 只有他线文件与既有 `dist-green/`、`dist-red/` 未跟踪目录）；生产面板未碰；测试机未动。

## 残留观察（不阻塞本线 PASS）

1. V016-21：reveal 成功但 IP 为空的服务器被静默跳过、不点名（见正文）。
2. V016-26：活体回包源断言在本沙箱 SKIP（环境门），真机一层由容器验证承载；修复方绿日志有一次已解释的 flake，tip 版已改临时端口重试。
3. V016-24：只警告、未 disable——产品决定待用户定（建议见专节；若用户选维持警告，本线 verdict 不变）。
4. UI 项（V016-17/19/20/21 及节点命令整体）：本线只做代码 + served 标记 + vm harness，浏览器点通按任务要求标注“待浏览器点通确认”。另注：MEMORY 在复审进行中更新，称父代理的浏览器点通已于 2026-11-21 22:24 完成并通过（含节点命令与自测 150s 端到端）；该结果由父代理持有，本线不代为下浏览器结论，请父代理以浏览器线的原始记录为准。
