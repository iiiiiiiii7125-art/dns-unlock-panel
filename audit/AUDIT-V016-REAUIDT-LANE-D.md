# D 线复审报告：v0.1.6 修复轮证据与台架线（REAUIDT）

- 审计对象：`~/workspace/dns-unlock-panel-v016`，分支 `feature/v0.1.6-takeover`，修复区间 `374e7b7..7b86d49`（tip `7b86d49`），基底 v0.1.5（`817c606`）
- 审计方式：只读复审（只审修复 diff 与证据，不重审整个仓库）。未改代码，未 push/tag/发版，未碰生产面板 https://dns.0v0.baby，未动测试机宿主机（未做任何测试机检查；测试机状态见 §6 未验证项）
- 复审执行时间：2026-11-21 14:12–14:35 UTC（22:12–22:35 CST）
- **本线 verdict：PASS**（5 项核查全部实质通过；证据缺口 6 项，见 §6，均为流程/证据 hygiene，不推翻结论；新观察 3 项，见 §7，其中 D-NEW-01 建议修台架）

## 0. 逐项 verdict 总表

| # | 核查项 | Verdict | 一句话结论 |
|---|---|---|---|
| 1 | 证据核对（台架/go test/容器/V016-12） | PASS（有保留） | 各份日志的断言计数与声称一致，关键断言逐项抽查对上；保留见 §1.5 |
| 2 | 台架重跑（沙箱，修复后 tip） | PASS | 第二遍 143/0、exit 0；第一遍 135+8 是偶发环境干扰，不复现，见 §2 |
| 3 | S14 计数对账（125+2 / 126+1 / 127） | PASS（“127”未完全闭合） | B 线 125+2 与 shell 线 126+1 均已实证解释；实施时的“127”无日志、无法复现，见 §3 |
| 4 | go test 重跑 | PASS | 我方重跑 EXIT 0，全包 ok，与归档日志一致（dnsagent 17.5s vs 17.962s） |
| 5 | 红/绿日志归档（上轮硬性要求） | PASS（有缺口） | 本轮已做到：台架/容器/go/plan3/shell/ui 证据均已进仓库；缺口见 §5 |

## 1. 证据核对

### 1.1 台架日志 rig-merged-20261121-1350Z.log（声称 143/0）—— PASS

- 文件 201 行，`=== RIG SUMMARY: PASS=143 FAIL=0 ===`（行 200），`台架退出码: 0`（行 201）。
- 计数自洽：`[PASS]` 标记出现 143 次（其中 11 次与 pty 提示同行，不在行首；按行首 grep 只能数出 132，是计数方法问题不是日志问题），`[FAIL]` 0 次。同样方法复核另两份：1335Z（137/6：PASS 标记 137、FAIL 标记 6）、1340Z（112/31：PASS 标记 112、FAIL 标记 31），均与各自 summary 一致；B 线两份（125+2）同样自洽。
- 关键断言抽查（全部在日志原文中）：
  - S0：`S0 P1(b) TCP 对照：dig +tcp @127.0.0.53 返回规则 IP` PASS；容器阶段 UDP 断言为 `[SKIP-容器阶段]`（未硬编通过，符合设计）。
  - S11（V016-15 P1(a) 指定地址分支）：stop/start marker、还原后 agent 恢复、15353 端口 dig 全部 PASS（11/11）。
  - S13（V016-15 P1(a) 通配符分支）：还原前 agent 在运行、stop marker、还原后 agent 已停、`:53` 已释放、`dig +tcp @127.0.0.53` 不再应答、二次还原仍保持停止，全部 PASS（11/11）。
  - S14：`前置：agent 已起并返回规则 IP`、`前置：agent 正在 :53 监听`、`verify_rule_domain 规则 IP 一致 → rc 0`、`结尾：agent 已停` 全部 PASS（28/28）。
  - S9b：`restore rc=0（或沙箱 1.1.1.1 不通时诚实的验证失败 rc=1）` PASS，`--backup 显式还原回 hpve 文件` PASS。注意：该断言走的是 rc=1 兜底分支（见 §1.5 第三点），不是干净 rc=0。
- 1335Z（137/6）与 1350Z 的差异已解释：1335 跑在 f1b0722 之前（13:35 跑，f1b0722 13:44 提交），其 6 个 FAIL（S9b restore rc=0、S13 P1(a)×4、S14 结尾）正是 f1b0722 修的 V016-08（free-case 静默重启 agent）与 S9b 断言收紧前的行为；1350 跑在 f1b0722 之后，全绿。时间线与 commit 时间（f1b0722 13:44:03，8af995d 13:53:22）吻合，不是随机抖动。
- 1340Z（112/31）为并行碰撞作废件：S7b 起级联失败（`wait_for_rule: 15 秒后 agent 仍未返回规则 IP`），与 1335 跑时间重叠（1335 约 13:35 起跑 8 分钟，1340 13:40 起跑），共享 `/var/lib/machines/v016-test` 与 `/tmp/rig-panel/`。但“env-kill”定性在日志内无直接证据（无 kill 记录），只是时间重叠推断——见缺口 G-4。

### 1.2 正式 go test 日志 go-test-merged-20261121-1330Z.log（声称全绿）—— PASS

- 文件 9 行：`dnsagent ok 17.962s`、`panel ok 1.522s`、`sniproxy ok 0.507s`，其余包 `[no test files]`，无 FAIL。内容与我方重跑一致（见 §4）。
- 缺口：日志内无时间/commit/命令头，基线只能靠 commit 3550ebc 的 message 与时间佐证——见缺口 G-1。

### 1.3 容器红/绿复验 test-machine-container/（声称 V016-01/02 通过，含 dig @127.0.0.53 UDP）—— PASS

逐文件计数与声称一致（PASS 标记数 = summary+1，系 summary 行自身含 PASS 字样；FAIL 标记均为 summary 行的 `FAIL=0`）：

| 文件 | 声称 | 实测 summary | UDP dig 证据抽查 |
|---|---|---|---|
| red/red-02.log | 25/25，V016-02 全复现 | PASS=25 FAIL=0 | 还原 rc=1；`dig @127.0.0.1` UDP connection refused；`dig @127.0.0.53 example.com` UDP 有结果；resolv.conf 仍指 127.0.0.1 |
| red/red-01-part1/2.log | 15/15 + 10/10，--temp 写永久 drop-in | PASS=15/10 FAIL=0 | 重启后 drop-in 与自启 agent 残留（日志内 snapshot） |
| red/red-01-static-part1/2.log | 16/16 + 8/8，分流静默变永久 | PASS=16/8 FAIL=0 | 重启后 `getent tiktok.com` 仍走自启 agent 返回 203.0.113.99 |
| red/red-01-f06.log | 20/20，退出路径绑定冲突 | PASS=20 FAIL=0 | journal 原文：`Another process is already listening on UDP socket 127.0.0.53:53.` + `Turning off local DNS stub support.` |
| green/green-02.log | 49/49，V016-02 三段 | PASS=49 FAIL=0 | A 段还原 rc=0，双 dig UDP 应答（.1 tiktok 规则 IP + .53 example 上游）；B 段外来通配符持有者还原 rc=1、agent 同 pid 存活；C 段 binder 抢 :53、待办标记、重跑 rc=0、agent 恢复、标记清除、双 dig UDP 应答 |
| green/green-01a-part1/2.log | 20/20 + 8/8，--temp resolvectl | PASS=20/8 FAIL=0 | 重启后 agent 未自启、stub 在监听、resolv.conf 指 stub、分流失效；临时状态文件惰性残留已在日志内注明（observation，见 §7） |
| green/green-01b-part1/2.log | 21/21 + 9/9，--temp direct-write | PASS=21/9 FAIL=0 | 重启后 boot oneshot journal 原文：`Starting dnsunlock-temp-restore.service …`、`临时模式清理：按 /etc/dnsunlock/temp-state 的记录恢复 DNS…`、`已恢复 /etc/resolv.conf 软链`；状态已清、unit 自删 |
| green/green-08.log | 21/21，V016-08 | PASS=21 FAIL=0 | 还原报“实测 :53 当前空闲”，不报旧谎言；还原 rc=1（V016-10 fail-closed，resolved 仍停）；`.53` tiktok 应答为规则 IP 且 ss 证实 stub 未监听（agent 代答，断言已修正） |
| green/green-09.log | 20/20，V016-09 | PASS=20 FAIL=0 | 无 unit agent 按端口找到、停掉、经端口回退重启（新 pid），双 dig UDP 应答 |
| v016-12/v016-12.log | 28/28，五步补验 | PASS=28 FAIL=0 | 步 3：`dig @127.0.0.1 tiktok.com（UDP）返回规则 IP` + `dig @127.0.0.53 example.com 有结果`（104.20.23.154 / 172.66.147.243）；步 4：`dig @127.0.0.1 -p 5353` UDP 规则 IP；步 5 负向：agent 保持停止、stub 在监听、系统 DNS 可用 |

- 红/绿二进制 sha256 已验证：`dist-green/dnsunlock-linux-amd64` = `70efb3fa…b8e6ef3`，`dist-red/dnsunlock-linux-amd64` = `72d67c83…089955f`，与 `test-machine-container/README.md` 声称的前缀一致。但两个二进制在 worktree 里是 **untracked**（`git status` 为 `?? dist-green/ dist-red/`），未随证据 commit 入库——见缺口 G-5。
- README 的两处“审计预测修正”有日志支撑：(a) Debian 12 软链 resolv.conf 下“系统 DNS 死”未按字面复现（stub 关后 stub-resolv.conf 改列上游，系统 DNS 经上游仍活），真正后果是分流静默变永久 + stub 永久关闭；(b) F-06 同理。修正本身是诚实的，未藏拙。
- nspawn 第一遍 smoke 失败日志 `nspawn-smoke-FAIL-20261121-1244Z.log` 已归档：沙箱 `/sys` 只读致 sysfs 挂载 EPERM，容器 90 秒未起，5 步补验一次未跑——环境阻断已如实记录，不是产品通过/失败；最终 28/28 是在测试机真容器上跑的第二遍。

### 1.4 V016-12 五步补验 28/28 证据 —— PASS

- `v016-12/v016-12.log`：`=== SUMMARY v016-12: PASS=28 FAIL=0 ===`（行 197）；`[PASS]` 28 条，`FAIL` 仅 summary 行的 `FAIL=0`。
- 步 1–5 逐项在 §1.3 表中；步 4 的非 53 端口瑕疵（安装把 `nameserver 127.0.0.1` 写进 resolv.conf 而 agent 在 :5353，自检报“验证未通过”）已在日志内记为“（记录）”断言，不计失败，还原可干净恢复——该瑕疵本身是真实产品问题（见 §7 D-NEW-02），但 V016-12 的验证目标（指定地址恢复分支）不受影响。
- 说明：步 3 无独立的 install/restore 日志文件（v016-12/ 下只有 step1/step2/step4/step5 的 install/restore 日志），因为步 3 本身不是一次安装/还原，只是对步 2 还原后 agent 恢复状态的验证，其 dig 输出与 snapshot 都在 `v016-12.log` 内（行 26–30、78–80）。不算缺口。

### 1.5 保留与说明

- S9b 在沙箱里从未拿到干净 rc=0：归档的 `s9b-restore.log`（1220 跑）与我方两遍重跑的 chroot 日志一致显示还原打印 `已还原但验证未通过（getent hosts example.com 无结果）`、退出码 1（沙箱 1.1.1.1 不通，getent 走上游失败）。S9b 断言能 PASS 是因为 f1b0722 把断言放宽为“rc=0 或（rc=1 且日志含‘验证未通过’）”。放宽本身是诚实的（函数名与断言文本都明说了），但 143/0 的标题数里有 1 项是“诚实失败”而非“干净通过”。不影响 PASS 结论，复审记录在案。
- V016-15 的容器阶段断言（`assert_container_only` 的 `dig @127.0.0.53` UDP）**在任何日志里一次都没真正跑过**：沙箱跑一律 `[SKIP-容器阶段]`，而 `scripts/rig/nspawn-v016-verify.sh` 并不调用 `rig-inner.sh`、也不设 `RIG_CONTAINER_STAGE=1`（全文 grep 无命中）。UDP 证据本身是有的，但走的是容器验证 harness 的手写 dig（green-02、v016-12），不是 rig 的断言。V016-15 的“补 P1 断言”在执行层面是“沙箱部分已跑、容器部分由等效 harness 覆盖”，不是“rig 容器断言已跑”。见 §7 D-NEW-03。

## 2. 台架重跑（沙箱，tip 7b86d49）

### 2.1 第二遍（干净）：143/0，exit 0 —— PASS

- 命令：`bash scripts/test-takeover-rig.sh`，2026-11-21 14:24:04–14:33 UTC，日志 `audit/evidence-v016-fix/rig-reaudit-lane-d-run2-20261121-1433Z.log`（已归档）。
- 结果：`=== RIG SUMMARY: PASS=143 FAIL=0 ===`，`RIG2_EXIT=0`。与 1350Z 日志逐段一致：S0 6、S1b 21、S2 5、S3 9、S4 7、S5 5、S6 8、S7a 2、S7b 5、S8 4、S9a 4、S9b 5、S10 5、S11 11、S12 4、S13 11、S14 28、S15 3。
- V016-13/14/15 的 diff 已在代码层核对（`git diff 374e7b7..7b86d49 -- scripts/rig/rig-inner.sh`）：
  - V016-13：S14 开头显式起 agent（`S14 前置：agent 已起并返回规则 IP` + `S14 前置：agent 正在 :53 监听`，`port53_busy` 前置断言），结尾停掉（`S14 结尾：agent 已停`，`port53_free`）；另加 `dig_53_tcp_ok` / `dig_53_udp_ok` 助手。
  - V016-14：S9b 改用 `--backup <本次备份> --yes` 显式还原，断言改为 `s9b_restore_rc_ok`（rc=0 或 rc=1+“验证未通过”）；旧断言（`--yes` 还原后期待 hpve）已删除。
  - V016-15：S0/S13 加 `dig +tcp @127.0.0.53` 对照断言与 `assert_container_only` 的 UDP 断言；S11/S13 加 stop/start marker 与 agent 状态断言（`markers_has "stop dnsunlock-agent"`、`agent_active` / `agent_inactive`、`:53` 释放断言）。容器阶段断言的执行缺口见 §1.5。

### 2.2 第一遍：135+8，全部集中在 S11 —— 偶发环境干扰，不复现

- 命令同上，2026-11-21 14:12–14:21 UTC，日志 `audit/evidence-v016-fix/rig-reaudit-lane-d-run1-20261121-1421Z.log`（已归档）。
- 结果：`=== RIG SUMMARY: PASS=135 FAIL=8 ===`，exit 1；8 个 FAIL 全在 S11（install rc=0、输出升级处理、验证未通过警告、disable marker、resolv.conf 仍是 127.0.0.1、stop marker、start marker、还原后 agent 已恢复运行）。其余 135 项（含 S9b、S13、S14 全部）PASS。
- 根因（已定位到日志行）：S11 安装 `--dns-listen 127.0.0.1:15353` 时 `can_bind_listen` 失败，`s11.log` 仅一行：`127.0.0.1:15353 已被占用（不是 systemd-resolved 的 stub）`；chroot `bindprobe.log` 对应行：`bind fail: listen udp 127.0.0.1:15353: bind: address already in use`。即 S11 安装瞬间已有外来进程占着 127.0.0.1:15353 的 UDP。
- 佐证它是外来进程而非本跑产物：
  - S11 还原后的 `S11 P1(a) 恢复的 agent 在 15353 上答规则 IP` 在第一遍里是 PASS 的，而 stop/start marker 与 `agent_active` 都是 FAIL——说明 15353 上答规则 IP 的 agent 不是本次还原经 stub systemctl 起的（否则 marker 与状态都会对上），而是事前已在的另一个 agent（规则相同故 dig 答案相同）。
  - `f1b0722..7b86d49` 是纯文档 diff（53 个文件全是 audit 证据），产品代码与 1350Z 跑的树一致，不存在“tip 回归”的可能。
  - 第二遍（同树、同沙箱，跑前确认无 rig 进程、18180/15353/:53 端口全空闲）S11 11/11 全过；第二遍 `bindprobe.log` 只有 S1b 预期的一行 `:53` 失败，无 15353 失败。
-  holder 身份未能最终确认：事后 `ss` 显示 15353 已空闲；复审期间其他 lane 也在并行跑台架/浏览器面板，共享 `/var/lib/machines/v016-test` 与 `/tmp/rig-panel/`，最可能是一个并行 lane 的 S11 agent 在 14:19:58 前后短暂占住了 15353（与修复轮 12:16 碰撞、13:40 碰撞同款）。本复审无法从残留日志里指认是哪个 lane（chroot 日志目录在两次跑之间被外层脚本重建，跨跑的 agent.pid 追踪已断）。结论：第一遍作废，第二遍采信；同时记为台架硬化建议，见 §7 D-NEW-01。

## 3. S14 计数对账

### 3.1 三组数字的差异来源（已对清）

| 数字 | 来源 | 断言总数 | FAIL 项 | 解释 |
|---|---|---|---|---|
| 125+2 | B 线两次重跑（374e7b7，旧 rig） | 127 | S9b 清理、S14 verify_rule_domain | 见 3.2 |
| 126+1 | shell 线干净单跑（`shell-lane/rig-clean-126-1.log`） | 127 | 仅 S9b 清理 | 见 3.3 |
| 127 | 实施时上报 | 127（总数） | 声称 0（无日志留存） | 无法复现，见 3.4 |
| 143+0 | 修复轮 1220 跑 / 合并后 1350 跑 / 本复审第二遍 | 143 | 0 | 新断言 +16，见 3.5 |

对账依据：`s9b-restore.log.B-lane-pre-fix`（B 线 run 2 的 chroot 日志）原文：

```
非交互模式：默认还原最早的一份（原始状态）: /var/lib/dnsunlock/backup/20261121-113248_pre-takeover
已还原 /etc/resolv.conf <- /var/lib/dnsunlock/backup/20261121-113248_pre-takeover/resolv.conf
```

最早一份是 11:32:48 的 base 备份（198.19.0.1），不是 S9b 当次的 hpve 备份（1.1.1.1）。`--yes` 按设计还原最早一份，旧断言期待 hpve 是错的——S9b 的 FAIL 是断言错，不是产品错。

### 3.2 B 线 125+2 的两项 FAIL

- S9b 清理：上文已解释（旧断言与“--yes 还原最早一份”语义矛盾，V016-14）。修复：S9b 改 `--backup` 显式还原当次备份（`s9b-restore.log` 1220 跑原文：`从备份还原: …/20261121-122612_pre-takeover/（pre-takeover，2026-11-21T12:26:12+0000）`，12:26:12 正是 S9b 当次接管前备份）。
- S14 `verify_rule_domain 规则 IP 一致 → rc 0`：该断言是**真 agent + 真 panel + live getent**（旧 rig S14 把 resolv.conf 写成 `nameserver 127.0.0.1` 再调 `verify_rule_domain`，函数内 `getent hosts $domain` 比对规则 IP）。它在两种情况下都会 FAIL，且 B 线日志的单行 FAIL 无法区分两者：
  1. 顺序依赖（V016-13）：S13 的还原（P1(a) 通配符分支保持停止）把 agent 停了，S14 自己不起 agent，live 查询走上游、拿不到规则 IP；
  2. 函数 bug（V016-06）：旧 `verify_rule_domain` 两处贪婪 `sed` 取最后一条规则，末条非 address 规则时误判跳过（D 线沙箱复现已证实函数本身有 bug）。
  两边都修了（V016-13 S14 自给自足 + V016-06 按规则数组取第一条 address 且 node_ip 非空，python3 优先、jq 其次、无两者时 grep 按字段顺序配对），修复后该断言在 1220/1350/复审第二遍三跑中均 PASS。审计报告“S14 两条并存解释”的定性准确。

### 3.3 shell 线 126+1 的一项 FAIL

- `shell-lane/rig-clean-126-1.log`：唯一 FAIL 是 `S9b 清理：还原回 hpve 文件`（旧断言）；S14 的 `verify_rule_domain` 两项全部 PASS。因为 shell 分支当时已含 V016-06 修复（取规则逻辑已改），S14 的函数 bug 腿已好；而 S9b 旧断言仍在，故 126+1。数字与 B 线的差额（S14 一项）正好是 V016-06 的修复效果，对得上。

### 3.4 实施时的“127”——无法复现，无日志留存

- 旧 rig 断言总数确为 127（B 线 125+2、shell 线 126+1 的总数都是 127），所以“127”最 plausibly 是断言总数被当作全绿数上报，或是一次非全量/非干净 store 的运行：
  - 全量干净 store 下 S9b 旧断言**确定性失败**（S1b 起即产生 base 备份，最早一份永远不是 S9b 的 hpve 备份），127+0 在 374e7b7/0874b2e 的旧 rig 上都不可能全绿；
  - 唯一能让 S9b 旧断言通过的情形是 store 里最早一份恰好是 S9b 自己的 hpve 备份（例如 S9b 单独跑、或 store 被清空后只跑了 S9b），但这只是推断，无日志可证。
- 结论：该数字已无从考证，也不必再追——审计当初要的 `s9b-restore.log` 已提供且已解释 B 线数字；“127”作为历史声称，建议在复审结论里记为“无日志、未复现”，不作为发版门依据。

### 3.5 127 → 143 的 +16 新断言

逐段对照 B 线 run 1 与 1350Z（另见复审第二遍，段数相同）：S0 +1（P1(b) TCP 对照）、S9b +1（新增 restore rc 断言）、S11 +4（P1(a) stop/start/恢复/15353）、S13 +7（P1(a)×5 + P1(b) TCP 对照 + 容器 SKIP 1 条不计）、S14 +3（前置×2 + 结尾×1），其余段 0。合计 127 + 16 = 143，与 summary 一致。

## 4. go test 重跑

- 命令：`go test ./...`（`~/go/bin/go`，go1.25.1，`PATH="$HOME/go/bin:$PATH"`），worktree tip 7b86d49，2026-11-21 14:15 UTC，日志 `audit/evidence-v016-fix/go-test-lane-d-reaudit-20261121.log`（已归档）。
- 结果：`GOTEST_EXIT=0`；`dnsagent ok 17.501s`、`panel ok 1.474s`、`sniproxy ok (cached)`，其余 `[no test files]`。与归档的 `go-test-merged-20261121-1330Z.log`（dnsagent 17.962s、panel 1.522s、sniproxy 0.507s）逐包一致，时间差异在正常抖动内。
- 本次重跑未遇到审批提示、无超时；用户已批准 go test 重跑的前提成立，归档日志与实测一致，正式采信无保留。
- 另抽查 go-lane 红/绿日志（V016-11、V016-31、V016-26）：V016-11 红（`TestPktinfoFamilyFromSocket FAIL`，pktinfo inactive）→ 绿（PASS，`using IP_PKTINFO instead` 日志）；V016-31 绿（随机 ID 与 RCODE 校验测试 PASS）；V016-26 的 `TestServeUDPLiveReplySource` 在沙箱 SKIP（`environment blocks UDP sends (EPERM); reply source needs a real machine`），诚实标注，live 回包源由容器 green-02 覆盖。红/绿配对真实。

## 5. 红/绿日志归档（上轮审计硬性要求）

上轮要求“修复轮必须把红/绿跑日志归档进仓库”，本轮**已做到**，清单如下（均在 `audit/evidence-v016-fix/`）：

| 类别 | 归档内容 | 状态 |
|---|---|---|
| 台架 | `rig-run-B-lane-1/2.log`（审计轮 125+2）、`rig-run-fix-20261121-1216-COLLIDED.log`（98+45 作废件，碰撞原因已写）、`rig-run-fix-20261121-1220.log`（143+0）、`rig-merged-20261121-1335Z.log`（137/6）、`rig-merged-20261121-1340Z.log`（112/31 碰撞作废）、`rig-merged-20261121-1350Z.log`（143+0）、`s9b-restore.log`（1220 跑）、`s9b-restore.log.B-lane-pre-fix` | 齐全；另有本复审新增 `rig-reaudit-lane-d-run1-20261121-1421Z.log`（135+8 碰撞作废）、`rig-reaudit-lane-d-run2-20261121-1433Z.log`（143+0）、`s9b-restore-lane-d-run2.log` |
| 容器红/绿 | `test-machine-container/`：red 6 份、green 13 份、host 5 份、v016-12 8 份 + README | 齐全；V016-01/02 红绿配对、V016-08/09、V016-12 28/28 均有日志 |
| go test | `go-test-merged-20261121-1330Z.log`、`go-lane/`（9 项红/绿 + `final-go-test.log`） | 齐全；另有本复审新增 `go-test-lane-d-reaudit-20261121.log` |
| plan3/shell/ui | `plan3-lane/`（check/check2/check3、panel-test3、red-evidence、rig.log 115+12 污染件已注明）、`shell-lane/rig-clean-126-1.log`、`ui-lane/v016-ui-harness.js` | 基本齐全，缺口见 §6 |
| nspawn 首遍 | `nspawn-smoke-FAIL-20261121-1244Z.log`（失败如实归档） | 已归档 |

缺口（不推翻“已做到”的结论，但复审如实记录，见 §6）：G-1（日志无基线 commit 戳）、G-2（1350 跑无逐场景日志）、G-3（UI harness 无运行输出日志）、G-5（红绿二进制未入库）。

## 6. 证据缺口清单

| # | 缺口 | 影响 | 建议 |
|---|---|---|---|
| G-1 | 台架日志（1220/1335/1340/1350）与 go-test 日志内**无基线 commit 戳**（无 `git rev-parse HEAD`、无时间头）；唯一带 commit 的是 nspawn-smoke 日志。基线只能靠 README 表格 + commit message + 文件时间佐证 | 复审无法仅凭日志本身证明某次跑用的是哪棵树；本次靠时间线（1350 跑在 f1b0722 之后）与我方在 tip 上的独立重跑（143/0）闭合 | 台架脚本与 go test 归档时先打印 `git rev-parse HEAD` + UTC 时间（D-NEW-04） |
| G-2 | 合并后 1350 跑**只有外层 stdout**，chroot 内逐场景日志（s9b-restore.log 等）未归档；归档的 `s9b-restore.log` 是 1220 预合并跑的。1350 跑 S9b 走 rc=0 还是 rc=1 兜底，无法从档案查证 | S9b 断言的分支归属只能靠我方重跑（两遍均为 rc=1 兜底）推断，不能直接证实 1350 跑 | 以后合并跑也要把 chroot `/root/rig/logs/` 整体归档 |
| G-3 | UI harness 只有 `ui-lane/v016-ui-harness.js`（内含 30 个 `check(`，与“30/30”声称的检查数一致），**无运行输出日志**；浏览器真点按另有专 lane，本线不代审 | “UI harness 30/30”无日志可查，只能数检查数；真浏览器点按结果以浏览器 lane 为准 | 补一份 harness 运行输出日志，或在报告里写明未留存 |
| G-4 | 1340 跑“env-kill”定性无日志内证据（无 kill 记录、无残留进程清单），仅靠与 1335 跑的时间重叠推断 | 该跑本就是作废件，不影响结论；但“碰撞”类定性以后应留一条 `ps`/`ss` 快照 | 碰撞作废时附跑前 `ps` + `ss -tln` 快照 |
| G-5 | 容器红/绿二进制 `dist-green/`、`dist-red/` 在 worktree 里是 **untracked**（`??`），未入库；其 sha256 已验证与 README 一致，但 worktree 一清理即失 | 红/绿二进制溯源依赖未入库文件 | 把两个二进制（+ .sha256）commit 进 evidence，或至少在 README 写明存放位置与未入库原因 |
| G-6 | 测试机宿主机状态（容器已删、iptables/桥已删、宿主机 resolv.conf sha256 `4443d364…`、panel/agent 原 pid 在位）**本线未验证**——沙箱内无 SSH 通道，本次未尝试连接测试机 | 容器 README 的清理声称采信自实施方记录，非复审独立验证 | 由父代理在测试机侧抽查，或在复审结论里标注“宿主机清理未独立验证” |

## 7. 新观察（复审中发现，非上轮 ledger 项）

- **D-NEW-01（台架 P3，建议修）：台架对 15353 外来占用无防护。** `run_install` 只在 `:53` 被占时打印警告（`port53_free` 检查），对 S11 用的 127.0.0.1:15353 无任何跑前检查；外层脚本重建台架目录时会删掉 `$STATE/agent.pid`，跨跑残留的 agent 无法被新跑停掉。本复审第一遍 135+8 就是因此作废。建议：台架起跑前 `ss` 检查 15353/:53/18180 并杀掉残留 `dnsunlock` 进程（或至少报错停下），多 lane 并行跑台架前先互相确认。
- **D-NEW-02（产品 P3，已在容器 README 记录，复审确认日志属实）：非 53 监听地址 flaw。** `--dns-listen 127.0.0.1:5353` 安装仍提供接管、写死 `nameserver 127.0.0.1`、自检报验证未通过（v016-12 步 4 日志行 84–85 与 step4-install.log 原文一致）。与 V016-27（仅记录）同根因不同表现：V016-27 是“端口无法表达”，本项是“安装流程在该配置下仍放行接管”。建议复审裁决：下版本修（监听端口≠53 时拒绝接管并明说），或记为已知限制。
- **D-NEW-03（证据 P3）：V016-15 的 rig 容器阶段断言零执行。** 见 §1.5：`assert_container_only` 的 UDP 断言在任何日志里都没跑过（沙箱 SKIP，容器验证脚本不调 rig-inner）。等效覆盖已由容器 harness 的手写 UDP dig 提供，不影响 V016-15 的实质结论，但“rig 容器断言”本身仍是未执行代码。建议：下次容器验证时以 `RIG_CONTAINER_STAGE=1` 跑一次 rig-inner，或删除该断言、改以容器 harness 为准。
- **容器 README 已记录的三项遗留（复审确认日志属实，不另开编号）：** (1) 01a resolvectl 路径临时状态文件重启后惰性残留（`green-01a-part2.log:59` observation 原文，无 DNS 效果）；(2) D-NEW-02 的非 53 端口瑕疵；(3) `Restart=always` 会在占用者消失后自行复活 agent（green-02.log 记载，C 段标记路径需显式停掉 restart 循环才能测到）。另两处审计预测修正（“系统 DNS 死”未按字面复现）见 §1.3。
- **本线不裁决：** MEMORY 同步新增的两项——V016-10 `--force` escape hatch 与 V016-24“直接 disable agent 还是警告 boot race”的产品决策、浏览器 lane 的 C7br/C7cr（per-server copy 命令）未决项——均属其他 lane / 父代理裁决范围，本线未验证，不表态。

## 8. 自查

- 本复审只读：未改产品代码；写入 worktree 的只有本报告与 §5 所列的 4 份复审重跑日志（`rig-reaudit-lane-d-run1/run2`、`s9b-restore-lane-d-run2`、`go-test-lane-d-reaudit`）；未 push/tag/发版；未碰生产面板与测试机宿主机。
- 台架重跑两次：第一遍 135+8（S11 碰撞作废，已归档并说明原因），第二遍 143/0（采信）；go test 一次，EXIT 0。
- 计数方法已说明：`[PASS]` 标记可能与 pty 提示同行，须按标记出现次数而非行首 grep 计数；各日志 summary 与标记数已逐份对过。
- 未验证项已明列：测试机宿主机状态（G-6）、浏览器真点按（另 lane）、C7br/C7cr（另 lane）、V016-10/V016-24 产品决策（待用户定）。
