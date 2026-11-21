# v0.1.6 复审报告（Re-audit）

- **复审对象**：`~/workspace/dns-unlock-panel-v016`，分支 `feature/v0.1.6-takeover`，tip `7b86d49`，修复区间 `374e7b7..7b86d49`，基底 v0.1.5（main `817c606`）
- **复审方式**：只审修复 diff + 重跑审计 §4 的动态验证计划。不重审整个仓库。5 条并行复审线（A：P1 深挖；B：P2；C：P3；D：证据与台架；E：对抗评审），各线原文：`AUDIT-V016-REAUIDT-LANE-A.md` ~ `LANE-E.md`；C7br/C7cr 裁决：`AUDIT-V016-REAUIDT-C7-ADJUDICATION.md`；总 ledger：`findings-ledger-v016.csv`（37 行状态已更新 + 新增 R2-01~R2-18）。
- **浏览器点通**：父代理并行安排，本地 tip 源码构建面板（served index.html `b6143a72` 与源码及内嵌副本一致），证据在 `audit/evidence-v016-fix/browser/`（19 张截图 + results.json、results-retest.json、复制出的命令原文、export.json）。结论已纳入本报告第 5 节。
- **复审结论：FAIL（不可发版）**

## 结论（先说）

R1 审计的 37 项，**31 项已修、1 项部分修（V016-08）、5 项仅记录确认未动**。三个 P1（原 P1 + V016-01 + V016-02）均已修，且有复审方自己的红/绿证。但复审挖出 **2 个新的发版阻塞 P2**，另有 1 个 P2 与 1 批 P3 建议同轮修：

| 类别 | 数量 |
|---|---|
| R1 原 37 项：已修 | 31 |
| R1 原 37 项：部分修 | 1（V016-08，剩 `%lo` 误判 P3） |
| R1 原 37 项：仅记录，确认未动 | 5（V016-27、29、35、36、37） |
| 新阻塞 P2 | 2（R2-01、R2-02） |
| 新 P2（不单独挡，建议同轮修） | 2（R2-04、R2-13） |
| 新 P3（含观察与旧 cosmetic） | 13（R2-03、05~12、14~18，其中 R2-12 仅观察、R2-17/18 为旧 cosmetic 登记） |

**必须修完复验通过才能发版的清单**（见末节“发版门”）：R2-01、R2-02；建议同轮修：R2-03、R2-04、R2-13 与 R2-06~R2-11、R2-14~R2-16。

## 1. R1 原 37 项逐项复核

| ID | 级别 | 复审结论 | 证据 |
|---|---|---|---|
| V016-00 | P1 | 已修 | A：红 r00 10/10（还原后 agent 仍跑、stub 死、系统 DNS 死、rc=0）；绿 g00 13/13（stub 恢复、裸探针回包源 127.0.0.53:53、agent 保持停止）。e5dafe6+ff006ca 在 tip 上仍成立 |
| V016-01 | P1 | 已修 | A：红 r01p1 8/9 + r01p2 9/9（--temp 写永久 drop-in、agent enable、重启后自启、stub 永久关、分流静默变永久；p1 唯一 FAIL 已解释：红版 resolvectl 把上游列在 127.0.0.1 前，getent 先走上游）；绿 01a 11/11+6/6、01b 9/9+8/8（无 drop-in、只 start、重启后 agent 不自启、stub 在、分流失效、01b oneshot 实际触发且自删） |
| V016-02 | P1 | 已修 | A：红 r02 17/17；绿 A 段 15/15、B 段 10/10、C 段 14/14（停后复查中止 + 待办标记 + 停 restart 循环后重跑恢复，agent 新 pid，标记清除） |
| V016-03 | P2 | 已修 | B：两份 index.html 各 9 命中、字节一致；卡片行内 + 编辑弹窗双开关；panel handler → model.Rule → agent 配置 → agent 使用全链路接线核对；协调员抽查一致 |
| V016-04 | P2 | 已修 | B：probe_panel md5 由 29aafc27→901afcf0，真改了；自测两个 3s 延迟候选总耗时 3.12s（串行应 ~6s），排名打印、挑最快 |
| V016-05 | P2 | 已修 | B：install.sh 真调 `dnsunlock check`（接管前基线 --via upstream + 接管后复测 --via agent + 对比表）；容器日志 step1-install.log:39/77/95-111 实证跑通；run_speed_test 全仓 0 引用 |
| V016-06 | P2 | 已修 | B：python3/jq/grep 三路都取第一条 address 且 node_ip 非空；自测含旧 bug 精确复现情形（末条 nameserver、node_ip 为空）三路全对 |
| V016-07 | P2 | 已修 | B：git ls-files 0 命中；diff 删文件；.gitignore 已加两行；协调员抽查一致 |
| V016-08 | P2 | **部分修** | B：free-case 已修（自测台架：实测空闲、保持停止、boot-race 警告、fail-closed 明说；green-08 21/21）。**新残留 → R2-03**：`measure_53` 的 stub 判定认不出真实 ss 输出 `127.0.0.53%lo:53`，误报 held 并错说“stub 未在监听”、误导用户“处理占位服务”（实为 resolved 自身 stub）。自动行为仍安全，定 P3；修法约 2 行（`_addr_host` 剥 `%…` 后缀）。协调员复核：`_addr_host`（restore-resolv.sh:122）只剥端口和方括号，确无 `%` 处理 |
| V016-09 | P2 | 已修 | B：端口兜底代码完整；绿跑 green-09 20/20（无 unit，pid 1104→1339，双 dig UDP 应答） |
| V016-10 | P2 | 已修 | E：两还原出口（CHOSEN/legacy）均在 `restore_agent_after` 之后按 `VERIFY_RC` 退出 1；uninstall 失败即停、不删 agent。产品决定见第 6 节（`--force` 逃生口） |
| V016-11 | P2 | 已修 | B：按套接字能力先试 v6 再试 v4、双败记日志；红 FAIL→绿 PASS，go test 全 ok。E：`newUDPPktinfo` 先试 IPv6 再试 IPv4；`trySet` 每次重置 `setErr` 并先查 `Control` 错误；双失败记日志，无静默回退 |
| V016-12 | P2 | 已修（口径说明） | B：v016-12.log 28/28 逐项核对（7+3+3+4+8+3），step 3 新 pid + UDP 双 dig 共存实证。D：28/28 证据核对通过。说明：绿基线是 3550ebc 非 tip，但 tip 后唯一代码改动 f1b0722 只碰通配符 free-case 分支，不触及具体地址分支，证据仍有效。建议顺手补一次 tip 重跑（5 分钟量级），非发版必要条件 |
| V016-13 | P2 | 已修 | D：台架重跑两遍，第二遍 143/0、exit 0（第一遍 135+8 全在 S11，是并行 lane 残留 agent 占 15353 的碰撞，作废）；S14 自给自足 + 前置断言已落地 |
| V016-14 | P2 | 已修 | D：S9b 断言已改（`--backup` 显式还原当次备份）；计数对账见第 4 节 |
| V016-15 | P2 | 已修 | D：rig 已补 P1 断言（stop 行为、agent 状态、dig @127.0.0.53）；但容器阶段 UDP 断言在任何日志里一次都没真正跑过（沙箱 SKIP，nspawn 脚本不调 rig-inner），UDP 证据走容器 harness 手写 dig，等效覆盖但机制不同 → R2-15 |
| V016-16 | P3 | 已修 | C：面板保留无法解析规则，check 出 FAIL 行 exit 1，agent 服务端跳过不可用规则；3 个新测试本地重跑通过 |
| V016-17 | P3 | 已修 | C：窗口 90s→150s、超时后 watchLate 再等 10 分钟并清 error、detailRow 按 request_id 对账、探活改 16 并行（4 条黑洞 20.0s→5.0s）；UI harness 17a–d 全过；浏览器端到端亦通过（见第 5 节） |
| V016-18 | P3 | 已修 | C：runCheck 传配置 allowlist + 仅 check 置位 QuietAllowlistWarning；agent/sni 警告与 fail-closed 不动 |
| V016-19 | P3 | 已修 | C：copyNodeInstall/copyUnlock 零服务器时不复制、提示先登记并说明 token 原因；浏览器亦通过 |
| V016-20 | P3 | 已修 | C：三处文案如实说明目标机上还要输 agent token（含无 TTY 退出提醒）；浏览器亦通过 |
| V016-21 | P3 | 已修 | C：每行传 nodeId、命令首行注释标明节点；reveal 全失败不复制、部分失败点名。残留 → R2-16：reveal 成功但 IP 为空的服务器会被静默跳过、不点名 |
| V016-22 | P3 | 已修 | C：两处中止文案 + 注释改为“只写了一份还原前备份”，三份脚本同步；残留的该表述只在备份失败分支，为真 |
| V016-23 | P3 | 已修 | C：新增 listen_blocked 按实际冲突分类，stub 地址/被占地址保持停止并明说，起失败警告写明分流已丢 + 分有无 unit 的恢复办法 |
| V016-24 | P3 | 已修（字面） | C：6 处 keep-stopped 分支都调 _enabled_boot_warn（比宣称的 5 处多 1 处 free 分支）。是否直接 disable 见第 6 节（产品决定） |
| V016-25 | P3 | 已修 | C：SyscallConn() 失败补 log，新测试通过 |
| V016-26 | P3 | 已修 | C：补内核 OOB 活体、活体回包源、两条失败路径测试；附带修了真 bug（Control 错误被丢弃致已关闭套接字谎报 active=true）。限制：活体回包源断言在本沙箱 SKIP（环境门）；修复方绿日志有一次已解释的 flake（固定 :15353 碰撞），tip 版已改临时端口重试 |
| V016-27 | P3 | 仅记录，确认未动 | C：接管仍无条件写 nameserver 127.0.0.1。但容器轮的新表现见 R2-02（同根因不同表现，本轮升级定级） |
| V016-28 | P3 | 已修 | C：失败时放回结果（有更新结果时不覆盖），-race 通过 |
| V016-29 | P3 | 仅记录，确认未动 | C：panel.go 本区间只有 V016-16 的 18 行 |
| V016-31 | P3 | 已修 | C：随机 ID + 校验 ID/RCODE + 标签/域名长度检查 |
| V016-32 | P3 | 已修 | C：全仓 0 命中 |
| V016-33 | P3 | 已修 | C：改认三种接管痕迹（.orig / 结构化备份 / temp-state） |
| V016-34 | P3 | 已修 | C：记时间戳、轮询清 >1 小时条目；verify_rule_domain 改 mktemp 且无泄漏路径 |
| V016-35 | P3 | 仅记录，确认未动 | C：restore_legacy 仍不恢复 nsswitch/enable |
| V016-36 | P3 | 仅记录，确认未动 | C：diff 里 flock 只在审计文档中 |
| V016-37 | P3 | 仅记录，确认未动 | C：enable --now 只有缩进移动 |

（V016-30 不存在，见 R1 报告。）

## 2. 新阻塞项（P2，修完复验通过才能发版）

### R2-01（E-R1，P2）：永久还原不清理临时状态，残留开机 unit 可在还原后的首次重启把 DNS 改回接管态

- **位置**：`scripts/restore-resolv.sh` 的 CHOSEN 分支与 legacy 分支（内嵌于两份 `install.sh` 的同一份还原脚本，三份一致，口子三份同在）。
- **证据（协调员已独立复核代码）**：`restore-resolv.sh` 内 `temp-state` 只出现在 `cleanup_temp_state()`（约 813–880 行）与无永久备份分支（约 984 行）；CHOSEN 分支（`restore_from_dir` → `verify` → `restore_agent_after` → `exit 0`）与 legacy 分支全程不碰临时状态、不删开机 unit。`restore-resolv.sh` 里根本不存在 `clear_temp_state` 这个函数；对照：`install.sh` 永久接管分支在 `do_backup "pre-takeover"` 之后立即调 `clear_temp_state`（约 1183 行），注释明确写了理由——“避免开机 unit 把刚接管的 DNS 还原回去”。还原路径存在完全相同的 hazard，却没有等价调用——同一轮修复里一处修了、一处漏了。
- **复现序列（代码级可推导，未在真机跑——需修复方容器重验）**：永久接管（resolv.conf → `nameserver 127.0.0.1`，agent 已 enable）→ 跑一次 `--temp` 且走到 direct-write 模式（resolved 未跑、或 resolvectl 失败）：`write_temp_resolv_conf` 把当时的 resolv.conf（即接管态）存入 `temp-state/resolv.conf.orig`，并装开机 unit `dnsunlock-temp-restore.service` → 跑 `dnsunlock-restore-dns`：resolv.conf 恢复原状，agent 按规则停掉；但 `temp-state/` 与开机 unit 原样残留 → 重启：开机 unit 跑 `--temp-cleanup` → direct-write 分支把 resolv.conf 从 `temp-state/resolv.conf.orig` 恢复为 `nameserver 127.0.0.1`。
- **后果分两支**：永久 agent 若监听通配符 `:53` 且还原已把 resolved stub 请回 127.0.0.53，则 agent 开机自启绑不上 `:53`（`Restart=always` 空转），系统 DNS 指向无人监听的 127.0.0.1:53——**系统 DNS 死**；若永久 agent 监听 127.0.0.1:53，则绑得上，**分流在还原后静默复活**。uninstall 路径同理：uninstall 调 `restore --yes` 后删 agent，残留 unit 在下次重启把 resolv.conf 改回 127.0.0.1，而 agent 已删——系统 DNS 死。
- **定级 P2 不是 P1**：后果最坏一支是 P1 级的，但触发要走“永久接管 → direct-write 临时 → 还原 → 重启”四步，且 direct-write 只在 resolved 缺席/失败时才走，不是常规 resolved 机器的默认路径。V016-01 本体是默认路径 P1；这是它修复的残留口子，评 P2、本轮必修。
- **修法注意**：还原成功路径上要调的是 `clear_temp_state` 的等价物（删 `temp-state/` + `disable` 并删开机 unit + `daemon-reload`），**绝不能调 `cleanup_temp_state`**——后者会按记录把 resolv.conf 恢复成临时原状（即接管态 127.0.0.1），等于亲手撤销还原。`restore-resolv.sh` 需新增该函数（或内联三行），位置在 `restore_from_dir`/`restore_legacy` 成功之后、中止路径不调（中止时 DNS 未改，临时状态仍有效）。
- **同根 benign 变体（R2-05）**：resolvectl 模式的临时状态在重启后同样残留（无开机 unit、无 DNS 效应）——即容器轮登记的“01a lazy residue”，已由 `green-01a-part2.log:59` 原文佐证（“temp-state after reboot: state (resolvectl path writes a record but no boot unit; DNS effect is gone)”）。无害，但与本项同根；修 R2-01 时顺手让 `clear_temp_state` 也覆盖它（永久接管/还原成功时都清）。
- **重验要求**：容器里跑完整序列（永久接管 → `--temp` direct-write → 还原 → 重启），断言重启后 `temp-state/` 不存在、开机 unit 不存在、resolv.conf 保持还原态、系统 DNS 正常。现有 green-01a 台架只验了“临时→重启”，未覆盖“临时→还原→重启”，须补这一段。

### R2-02（P2，挡发版）：非 53 监听端口接管——安装器自己把用户往断 DNS 的路引

- **事实**：安装器自身宣传并推荐 `--dns-listen 127.0.0.1:5353`（帮助文案 `:166`；`:53` 被占时的退路文案四处有：install.sh:875、883、894、898）。永久接管、临时直写、临时 resolvectl 三路径全无端口守卫，写死 `nameserver 127.0.0.1`；摘要把矛盾直接印出还继续走。容器实证（B 线 step 4）：写死后系统 DNS 死，安装器随即自动执行 `systemctl disable --now systemd-resolved`（install.sh:1262-1263 的升级处理），直到手动还原才恢复；还原 rc=0 干净恢复。A 线 lane 外观察亦证实：g02b 的 `:5353` 安装触发了同一升级处理。
- **定级裁决（协调员）**：P2，挡发版。B 线定 P2 挡发版；D 线定 P3（D-NEW-02）；E 线未升级（仍按 V016-27 登记）。采纳 B 的理由：(1) 安装器主动推荐该路径，触发不是用户误操作，是按指引走；(2) 容器已证实后果是系统 DNS 死 + resolved 被自动停用，且该升级在 5353 下是确定性触发（接管后解析永不走 agent）；(3) 修复只是接管前按端口拒绝/跳过并明说（约 10 行），另加非 53 时不触发停用 resolved 的守卫。R1 时评 P3 的前提是“有警告兜底”，B 的容器实证推翻了它——摘要印出矛盾照样继续走，警告没有兜住。非 P1：默认 `:53` 路径不受影响、须显式选非 53 端口 + 确认接管、失败响亮、还原已验证干净。
- **若用户决定不修就发版**，最低限度是三件套：摘要明确警告 + 非 53 时不触发停用 resolved 的升级 + 发版说明登记；静默发版不可接受。

## 3. 新 P2（不单独挡发版，建议同轮修）

### R2-04（V016-02-R1，P2）：agent 未在跑时 unit 路径的早返回跳过了 stub_blockers 检查

- **证据（协调员已独立复核代码）**：`record_and_stop_agent()` 里 `[ "$AGENT_WAS_ACTIVE" = 1 ] || return 0` 在 `stub_blockers` 检查之前。agent 未在跑（且无待办标记）时函数直接返回，`:53` 上有外来通配符占位也发现不了。A 线 g02probe 实测：外来通配符 `:53` 占位时还原先改了 resolv.conf、后验证失败才 exit 1，系统 DNS 死，无标记；清占位后重跑可恢复。
- **定级**：P2，不单独挡发版（须外来占位 + agent 未跑同时成立，且可重跑恢复）。建议同轮顺手修（把检查提到早返回之前，与无 unit 路径对齐），反正修复轮为 R2-01/R2-02 总要重开。

### R2-13（S6/E-R9，P2）：`probe_panel` 把任何非 000 的 HTTP 响应都算“面板可达”，并行测速放大了冒名者胜出的概率

- **事实**：`probe_panel`（v0.1.3 语义，plan3 继承，本轮未改判定条件）不校验响应形态。`whoami` 不带 token 时真面板回 401 + JSON `{"error":"unauthorized: agent token required"}`（panel.go:216-232）；别家 lane 遗留的 python3 HTTP 服务回 404 + HTML，同样算可达。R1 的 S6：当时 :8080 上有别的 lane 遗留的 python 服务，`probe_panel` 选中了它。**本轮的新变化（V016-04）让旧语义更危险**：以前是顺序 fallback——只有 443 不通才试 :8080；现在是并行测速取最快——本机冒名者（~1ms）几乎每次都会赢过经 Caddy 的真面板。判定条件没变，但触发概率从“443 故障时”放大到“每次安装”。选错的后果不止“连不上”：选中之后安装脚本用 `-K` 带 agent token 调 `whoami` 并拉取 agent 配置——token 会发给冒名者。威胁模型上限很明确：冒名者必须已监听在**面板机自己的 :8080** 上，即面板机本身已被误配/入侵或台架残留服务；在真实部署里 :8080 本来就是面板，冒名者不存在。
- **裁决（采纳 E 线）**：立项加固，定 P2。理由：判定条件可以且应当校验形态——`whoami` 的合法响应只有两种：401 + JSON 含 `agent token`，或 200 + JSON 含 `server_id`。改动约 10 行（`curl` 取 body 后校验），无行为回归面。**不单独挡发版**：利用前提是面板机 :8080 上已有 rogue 监听，这在真实部署里不是攻击面而是机器已被占的前提；且 S6 本就不在 R1 审计清单内、无计划承诺。**但建议本轮顺手修**：V016-04 是本轮引入的放大器，修判定条件与修测速是同一处代码；若本轮关闭时仍未修，须把“:8080 冒名者可赢得测速、token 会发给它”写进发版说明的已知限制，并把“台架不得残留 :8080 服务”记为台架纪律。

## 4. 新 P3 与观察

| ID | 级别 | 内容 | 修法/处置 |
|---|---|---|---|
| R2-03 | P3 | V016-08 残留：`measure_53` 的 stub 判定认不出真实 ss 输出 `127.0.0.53%lo:53`（测试机快照即此格式），误报 held 并错说“stub 未在监听”、误导用户“处理占位服务”（实为 resolved 自身 stub）。自动行为仍安全 | 修，约 2 行（`_addr_host` 剥 `%…` 后缀），用真实 ss 输出重验 |
| R2-05 | P3 | 01a 惰性残留：resolvectl 路径的临时状态文件重启后仍在（无开机 unit、DNS 效果已无）。A 线 g01ap2 实测 + E 线 green-01a-part2.log:59 佐证 | 不挡发版；修 R2-01 时顺手让 `clear_temp_state` 覆盖，或下轮把状态放 /run、或下次安装时清理 |
| R2-06 | P3 | E-R2：`copyServerInstall` 未做 V016-21 同款 reveal 失败处理。`await api(reveal)` 后直接写剪贴板、无 try/catch；reveal 一旦失败（会话过期、强制改密后 401——浏览器复核轮已记录同类 401），promise 静默 reject：什么都没复制、没有任何提示，用户只看到登录框突然出现 | 修，与 `copyNodeInstall` 对齐：try/catch 包住 reveal，失败时 alert 如实报错、不复制；`j.token` 为空时同样不复制 |
| R2-07 | P3 | E-R3：`cleanup_temp_state` 恒返回 0 且照常打印“清理完成”，revert 失败时 fail-open 呈报。revert 失败只打一条警告，随后照常“停 agent → `rm -rf temp-state` → 删 unit → 打印‘临时模式清理完成’→ `return 0`”。失败后状态记录已被删，下次重跑只会说“没有临时状态记录，无需清理”——失败态不可再现、不可重试 | 修：交互路径上 revert 失败时返回非零并保留状态文件（开机 unit 调用时可继续返回 0 但须把警告写进日志）；或至少失败时不打印“清理完成” |
| R2-08 | P3 | E-R4：`write_temp_state` 与开机 unit 的写顺序存在 kill 窗口。顺序是 `write_temp_resolv_conf` → `install_temp_boot_unit` → `write_temp_state`；进程若在此时被杀，开机 unit 已存在（或 orig 已写）而 `state` 文件不存在；开机 `--temp-cleanup` 只认 `state` 文件，缺失即返回 0，direct-write 的临时 DNS 失去自动恢复 | 修：先写 `state` 文件再装开机 unit（或把写 `state` 合进 `write_temp_resolv_conf` 内） |
| R2-09 | P3 | E-R5（稳健性）：`verify_rule_domain` 的 grep 兜底注释的不变量是假的（`model.NodeCandidate` 同样有 `json:"node_ip"`，一个带 N 个候选节点的 region 规则贡献 N+1 个 `node_ip`）。但 live bug 不成立（对抗自查：`awk` 取第一个非空配对，而第一个配对恒为首条规则自己的 `node_ip`；首条 `node_ip` 为空 ⟺ `resolveIP` 失败 ⟺ `regionCandidates` 同样为空，错位配对永远走不到；nameserver 规则无 candidates，同样安全） | 修：删掉 grep 兜底、改走“无 python3/jq 则跳过（return 2）”，或把兜底改成按规则切分的解析 |
| R2-10 | P3 | E-R6（卫生）：`run_dnsunlock_check` 的 mktemp 文件泄漏（`BASELINE_CHECK_FILE`/`AFTER_CHECK_FILE` 及 `"$outfile.err"`，每次安装留 2–3 个小文件在 /tmp；安装中途 abort 同样残留） | 修：安装末尾 `trap` 清理（已有 `trap 'rm -f ...' EXIT` 的先例） |
| R2-11 | P3 | E-R7：节点安装命令注释头显示的是掩码 IP（`203.0.*.*`），行绑定标识打了折扣。与浏览器复核轮的同名 P3 候选一致 | 修：点按钮时对该节点调一次 reveal 取完整 IP 拼头，或头里去掉 IP 只留名 + 地区 |
| R2-12 | P3 观察 | E-R8：`stop_agent_no_unit` 有两处“失败当成功”的角落（`kill` 因 EPERM 失败时同样返回 0；有 `ss` 无 `pgrep` 且 ss users 字段为空时误判“已停”）。还原正常以 root 跑，两者都窄；且 KILL 后 `_pid_gone` 仍会兜底 | 仅观察，不要求本轮修（顺手修可把首行改成只在 ESRCH 时返回 0） |
| R2-14 | P3 | D-NEW-01（台架）：台架对 15353 外来占用无跑前检查，外层脚本重建目录会删 `$STATE/agent.pid`，跨跑残留 agent 无法被停掉 | 修：起跑前检查端口并清理残留 |
| R2-15 | P3 | D-NEW-03（证据）：V016-15 的 rig 容器断言零执行 | 下次容器验证以 `RIG_CONTAINER_STAGE=1` 跑一次 rig-inner，或改以容器 harness 为准 |
| R2-16 | P3 观察 | C 残留：V016-21——reveal 成功但 IP 为空的服务器会被静默跳过、不点名 | 同轮顺手修（点名）或登记 |
| R2-17 | P3 登记 | favicon 404（面板没配 favicon）。v0.1.6 之前就有，非回归，零 pageerror | 登记，下版本 |
| R2-18 | P3 登记 | 强制改密码流程：doChangePw 成功后调 doLogout，此时 session 已被改密码作废，于是 logout 401。v0.1.6 之前就有，非回归，零 pageerror | 登记，下版本 |

## 5. 浏览器点通结果与 C7br/C7cr 裁决

- **v0.1.5 回归全过**：12 张卡片、二级弹窗 16 地域、选 JP 保存后 API 确认、搜索、备注 localStorage、导出/导入、删除清空、15 秒轮询不丢搜索/焦点/待保存修改（B6 初判 FAIL 是脚本顺序 bug，重测 B6r 通过）。
- **v0.1.6 新 UI 全过**：最快开关默认关、文案诚实、徽章出现、PUT 后 prefer_fastest=true、刷新后仍在；节点复制安装命令：零服务器时不生成命令并提示先登记（V016-19），登记两台后 allowlist 是 reveal 取的完整 IP（203.0.113.50,203.0.113.60），按钮旁有 443 提示，复制后诚实说明目标机还要输 agent token（V016-20）；服务器页每行命令带本台 token 与名；自测端到端（本地真 agent 用 SIGSTOP 冻住）：点后出现进行中行（“最长约 150 秒”+ request_id st-1795270662007361352），150 秒无结果显示超时 error，解冻后结果到达、error 被清掉、同一 request_id 展开。
- **C7br/C7cr 裁决：脚本断言 artifact，不是产品 bug，不列入修复清单**（详见 `AUDIT-V016-REAUIDT-C7-ADJUDICATION.md`；C 线与 E 线独立复核，结论一致）。四重证据：(1) retest detail 原始长度 55 字符，解码后是 `clip has rev1 token=true name=true has rev2 token=false`（C7cr 反过来）——三子条件全过但 `pass` 仍为 false，脚本的 pass 计算本身有 bug；(2) 验证脚本自己保存的两个 retest 命令文件各含恰好一个 32 位 token，互不相同，名与 IP 对得上；(3) 前端追踪：`copyServerInstall(id)` 按 id 找本行、按 id 调 reveal、只传一个 token 写剪贴板，该路径无共享可变状态；(4) 后端 reveal（panel.go:1133-1143）按 `sv.ID == nid` 返回该台自己的 token。首轮 C7b（剪贴板里是正确的命令全文仍判 FAIL）与 C7c（剪贴板空——`writeText` 未 await 又弹 `alert` 的时序窗口）同样指向脚本侧。建议：验证脚本修好 pass 计算后再跑一次 C7（纯脚本问题，无需改产品代码）；读剪贴板前等 `writeText` 落定，避免时序窗口重现。
- **浏览器发现的两项旧 cosmetic**：见 R2-17、R2-18（v0.1.6 之前就有，非回归）。

## 6. 两个产品决定（给建议，用户最后定）

### V016-10：还原验证失败 fail-closed exit 1，无 `--force` 逃生口——要不要加？

- **A 线建议：加**（仅还原 + uninstall 透传，大声警告、绝不默认）。理由：fail-closed 无逃生口会困住验证永不过的环境（离线机器、R2-04 中占位者暂清不掉时）；操作者是 root，且还原前已有 pre-restore 备份，可逆。
- **E 线记录**：修复方已单边选了“不给 `--force`”的实现；若用户要 `--force`，两处出口都要返工。
- **协调员意见：同意 A 线，加。** 逃生口的用途正是 fail-closed 误伤时的自救，且有备份兜底；不加的话，验证环境问题会把用户锁在还原之外，只能手动改文件。若用户定了加，进下一修复轮。

### V016-24：5 处（实为 6 处）有意 keep-stopped 分支只警告开机竞态——要不要直接 `disable` agent？

- **C 线建议：直接 `disable`**（仅当曾 enabled 时），并改文案说明可手动 start、重跑安装会恢复自启。理由：警告渠道不可靠（uninstall 以 --yes 调还原时根本没人读输出）、留下的 enabled 状态与还原本意矛盾且会在下次开机复活抢 :53 竞态、disable 代价极小且可逆、修复方自己的文案已认定 disable 是正确动作。
- **E 线记录**：修复方选了“警告”（`_enabled_boot_warn`）而非“直接 disable”；若用户要 disable，须返工。
- **协调员意见：同意 C 线，直接 disable。** 理由同上。若用户定了，进下一修复轮。

## 7. 其它裁决与说明

- **审计预测修正（“系统 DNS 死”分支），措辞以实测为准**（A 线实测 + E 线复核归档证据，无分歧；严重性不变，仍为 P1）：临时模式的重启后后果，在 Debian 12 + 软链 resolv.conf 的实测容器中**未按“系统 DNS 失效”的字面含义复现**：stub 关闭后，`stub-resolv.conf` 改列上游 DNS，系统 DNS 经上游仍可用；静态 resolv.conf 变体中，系统 DNS 经 agent 仍可用。实测的真正后果是两项：(1) **分流静默变永久**（agent 常驻 :53，重启后仍劫持规则域名）；(2) **stub 永久关闭**（drop-in 残留，resolved 的 stub 不再监听）。“重启后系统 DNS 失效”仅在静态 resolv.conf 且 agent 未能提供解析时才成立，不是本轮实测的默认分支。**严重性不变（仍为 P1）**：静默永久分流 + stub 永久关闭仍违背“重启后失效”的明确承诺，且用户无法从表面察觉；修正的只是失效机理的描述，不是定级。证据：`red-01-part2.log:45-47,52-53`（软链变体）、`red-01-static-part2.log:19-25`（静态变体）、`green-01a-part2.log:51-58`（修复对照）。
- **V016-02 附带发现（Restart=always + binder 晚到 C2 分支）：无问题，无需修**（A 线裁决）。重启循环是自愈收敛（占位者消失后自行恢复，标记下次运行被正确消费）；C2（binder 晚到，还原完成但验证失败）是合法 fail-closed 分支；5ms 轮询 binder 可稳定命中 C1。
- **S14 计数对账（D 线）**：B 线 125+2 已实证解释——S9b 旧断言错（`s9b-restore.log.B-lane-pre-fix` 原文：`--yes` 还原的是最早一份 base 备份 198.19.0.1，不是 hpve）；S14 单行 FAIL 是 live-getent 断言，顺序依赖与 verify_rule_domain 贪婪 bug 两腿并存，日志本身无法区分，两边都已修。shell 线 126+1 已解释（该分支已含 V016-06，S14 通过，只剩 S9b）。127→143 的 +16 新断言已逐段对清（S0+1、S9b+1、S11+4、S13+7、S14+3）。实施时的“127”无日志留存、全量干净 store 下 S9b 旧断言确定性失败，无法复现，记为“无日志、未复现”，不作发版门依据。
- **台架重跑说明（D 线）**：tip 上重跑两遍。第一遍 135+8，8 个 FAIL 全在 S11：安装瞬间已有外来进程占着 127.0.0.1:15353 UDP（另一 lane 的残留 agent），且还原后 15353 照答规则 IP 而 stop/start marker 全 FAIL，证明是外来 agent；`f1b0722..7b86d49` 是纯文档 diff，排除 tip 回归。第二遍（跑前确认无 rig 进程、端口全空闲）**143/0、exit 0**，S11 11/11 全过，第一遍不复现，定性为并行碰撞作废件。教训：多 lane 并行跑台架须错开端口或串行，见 R2-14。
- **go test**：D 线在 tip 上重跑 `go test ./...`，EXIT 0，dnsagent ok 17.5s、panel ok、sniproxy ok，与归档日志逐包一致，本次无审批提示。C、E 两线亦观察到全部通过（各有一次审批超时未答复，按 R1 惯例只记“已观察到通过”）。正式采信以用户已批准的正式重跑归档日志（`go-test-merged-20261121-1330Z.log`）为准，D 线的 tip 重跑为佐证。
- **证据缺口（D 线 §6，流程 hygiene，不推翻结论）**：G-1 台架/go 日志无基线 commit 戳；G-2 1350 合并跑只有外层 stdout、无逐场景日志（S9b 走 rc=0 还是 rc=1 兜底无法从档案查证，D 两遍均为 rc=1 兜底）；G-3 UI harness 无运行输出日志；G-4 1340“env-kill”定性无日志内证据；G-5 红绿二进制未入库（untracked）；G-6 测试机宿主机清理状态本线未验证（沙箱无 SSH 通道）。其中 G-6 由 A 线补足：宿主核对通过（`/etc/resolv.conf` sha 与跑前一致 `4443d364…`，宿主 panel/agent 仍为 v0.1.5 原 pid 2652616/2652618，二进制仍为 `1084e5e9…`）。
- **范围外改动检查（E 线）**：产品代码无清单外顺手改动（逐文件核对，全部映射到 ledger 项）；区间内非修复内容是审计报告提交与修复证据归档，属审计流程产物。工作区卫生：worktree 根下有未入库目录 `dist-green/`、`dist-red/`（构建产物，未提交，不在 diff 内），建议修复方清理或入 `.gitignore`。
- **对抗复核通过项（E 线 §5，抽查证据）**：V016-16 面板/agent 协同无跨平台 stale IP；V016-11 pktinfo 双失败记日志、无静默回退；V016-02 停前按冲突检查、停后复查、中止恢复 agent、待办标记防谎报；V016-34/28 Go 改动加锁路径全覆盖、`go test -race ./internal/dnsagent/` 沙箱实测 ok 19.8s（审批超时未答复，只记“已观察到通过”）；V016-05 基线/复测接线与字段布局一致；V016-04 测速 `tail -1` 契约未变、失败 fail-closed；V016-03 UI 全链路接线、无重置路径；同步与语法（`check-restore-sync.sh` 通过、6 个脚本 `bash -n` 全过、两份 index.html `node --check` 全过、`go vet ./...` EXIT 0、`.pyc` 已删 + `.gitignore` 已加）。

## 8. 发版门（下一修复轮必须全部完成，再走一次聚焦复审）

1. **R2-01**（P2）：还原成功路径清临时状态（新增 `clear_temp_state` 等价物，禁调 `cleanup_temp_state`）；容器重验完整序列（永久接管 → `--temp` direct-write → 还原 → 重启），断言重启后 `temp-state/` 不存在、开机 unit 不存在、resolv.conf 保持还原态、系统 DNS 正常；R2-05 顺手覆盖。
2. **R2-02**（P2）：接管前按端口守卫（监听端口 ≠53 时拒绝/跳过接管并明说）+ 非 53 时不触发停用 resolved 的升级；容器重验。
3. **R2-03**（P3）：`_addr_host` 剥 `%…` 后缀；用真实 ss 输出（`127.0.0.53%lo:53`）重验。
4. **R2-04**（P2）：`stub_blockers` 检查提到 unit 路径早返回之前；容器重验（外来 `:53` 占位 + agent 未跑）。
5. **R2-13**（P2）：`probe_panel` 校验 whoami 响应形态（401 + JSON 含 `agent token`，或 200 + JSON 含 `server_id`）；重验。
6. **P3 同轮**：R2-06、R2-07、R2-08、R2-09、R2-10、R2-11、R2-14、R2-15、R2-16。
7. **复验**：台架全绿（注意多 lane 并行碰撞，见 R2-14）、`go test ./...`、容器红/绿跑日志归档进仓库、浏览器重查 `copyServerInstall`/`copyNodeInstall` 的 reveal 失败路径。
8. **再走一次聚焦复审**（只审新 diff + 第 7 项的动态验证），通过方可发版。
9. **用户定两件事后再开修复轮**：V016-10 是否加 `--force`、V016-24 是否直接 `disable`（见第 6 节；两处都要返工，先定再修）。

## 9. 残留风险登记

- R2-12、R2-17、R2-18：仅观察/登记，下版本。
- V016-27、29、35、36、37：仍仅记录，下版本；其中 V016-36（install/restore 无锁）与 E-R1 同属“还原窗口”家族。
- V016-12 的 tip 重跑：建议顺手补，非发版必要条件。
- S14 的“127”：无日志、未复现，不作发版门依据。
- 修复方容器证据缺失的流程风险已闭合：本轮红/绿日志已归档进仓库（`audit/evidence-v016-fix/`），但 G-1~G-5 的 hygiene 缺口仍在，下轮注意。

## 10. 自查

- 本复审每条 P1/P2 均有红证或容器/代码级实证（A 线 nspawn 红/绿、D 线台架重跑、B 线容器 step 4、E 线代码对照 + 归档日志原文），非复述修复方说法；协调员对两处阻塞项（R2-01、R2-02 的关键代码点）与 R2-04 做了独立代码复核。
- 跨线冲突已裁决：非 53 缺陷（B P2 挡 vs D P3 vs E 登记 → 协调员裁决 P2 挡，理由见 R2-02）；V016-12 证据基线（B 口径说明 + D 核对 → 接受，tip 重跑非必要）；S14 计数（D 对账 → “127”记为无日志未复现）；C7br/C7cr（三线一致：脚本误判）。
- 复审过程未改代码、未 push/tag/发版、未碰生产面板；测试机宿主机状态经 A 线核对仍为 v0.1.5 原状（`/etc/resolv.conf` sha 一致，panel/agent 原 pid，二进制 `1084e5e9…`）。
