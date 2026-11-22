# v0.1.6 聚焦复审报告（Focused Re-audit）

- **复审对象**：`~/workspace/dns-unlock-panel-v016`，分支 `feature/v0.1.6-takeover`，tip `1f24428`
- **审的 diff**（只审改动 + 直接关联路径，用户 2026-11-22 定“只对事论事”，全量 30 分区只在他明确要求时才做）：
  - 修复轮 2：`7b86d49..fa946e8`（18 个 R2 项 + `--force` + 直接 disable；shell / UI / rig / rigfix 四 lane）
  - F1：`fa946e8..1f24428`（`web/index.html:714` 一行，`runSelftest` 的 POST 成功分支补一次 `renderServers()`）
- **上一轮**：`audit/AUDIT-REPORT-V016-REAUIDT.md`（FAIL，55 行台账 `audit/findings-ledger-v016.csv`）；本轮逐项复核其 18 个未修项 + 2 个产品决定，不重复报已修问题。
- **动态验证**：容器证据 `audit/evidence-v016r2-fix/test-machine-container/{red,green,host}/` + `RUN-NOTES.md` 逐项核对日志原文（非只信手记数字）；沙箱重跑 `go test ./...` 全量 + `scripts/test-takeover-rig.sh` 全量（145/0）；F1 浏览器重验复核 `results.json`（9/9）；测试机宿主机只读核对（未做任何写操作，未碰生产面板）。
- **复审结论：修后发版（FIX THEN RELEASE）—— 2 个新 P2 必修，1 个同机制 P3 同轮必修，修完按第 8 节复验通过方可发版。**

## 结论（先说）

| 类别 | 数量 |
|---|---|
| R2 项（复审时未修）：已修 | 15（R2-01~R2-11、R2-13~R2-16；R2-05 顺手覆盖） |
| R2 项：仅记录，确认未动 | 3（R2-12、R2-17、R2-18 仍登记） |
| R1 残留：本轮闭合 | V016-08（R2-03 修后完整）、V016-12（tip 现货证据 v12 24/3）、V016-27（由 R2-02 守卫修掉） |
| V016-37（原登记 P3）：升级 | 容器实测复现 → **F3-02（P2，必修）** |
| 新 P2（必修） | 2（F3-01 还原顺序闪烁、F3-02 重装不重启 agent） |
| 新 P3（同轮必修，同机制族） | 1（F3-03 还原未跑分支漏 disable） |
| 台架问题（非产品） | 3 处记录（v12 步 4“本次不接管”断言不可达、r201 p2 复活分支断言与最坏分支不匹配、r204/g204“占位已清”时序竞态） |

**发版门**：F3-01、F3-02、F3-03 修完，按第 8 节做针对性容器复验 + `go test` + 台架 145/0，复审确认后发版。**不修不得发版**——两个 P2 都是容器实测的真产品 bug，不是推测。

## 1. R2 项逐项复核（复审基线 7b86d49 时未修 → 本轮 tip 1f24428）

| ID | 级别 | 复审结论 | 证据 |
|---|---|---|---|
| R2-01 | P2 | **已修** | 代码：`scripts/restore-resolv.sh:827` 新增 `clear_temp_state`（只删 `temp-state/` + disable 并删开机 unit，不动 resolv.conf），CHOSEN 分支 `:1021` 与 legacy 分支 `:1051` 成功路径各调一次，注释明说“只在还原成功路径调，中止路径不调”。容器：绿 g201 p1 `[PASS] 还原后 temp-state 已清`、`[PASS] 还原后开机 unit 已删`（`green/g201.p1.log:34-35`）；绿 p2 5/5（`green/g201.p2.log:29`）。红 r201 p1 `[PASS] 还原后 temp-state 还在`、`[PASS] 开机 unit 还在`（`red/r201.p1.log:34-35`），红 p2 走最坏分支（见 §2）。R2-05 顺手覆盖：`clear_temp_state` 无条件 `rm -rf /etc/dnsunlock/temp-state`，resolvectl 路径残留同清；g201 p2 证实重启后无 temp-state。 |
| R2-02 | P2 | **已修** | 代码：`scripts/install.sh:1177-1184` 守卫——TAKEOVER=y 且端口 ≠53 时置 `TAKEOVER="n"` 并明说原因，agent 照常跑在该端口；接管体不进，停用 resolved 的升级（接管体内）不触发；临时分支同款守卫（`:682` 注释）。容器：绿 g202 18/18（`green/g202.log:45`），日志明说“本次不接管”、resolv.conf 未动、resolved 仍在跑、agent 在 5353 上跑且 UDP dig 回规则 IP；红 r202 21/21（`red/r202.log:39`），红版写死后系统 DNS 死 + `red/r202-install.log:76` 升级处理原文“彻底停用 systemd-resolved”。 |
| R2-03 | P3 | **已修** | 代码：`scripts/restore-resolv.sh` 的 `_addr_host` 现剥 `%…` 后缀（`${a%%\%*}`）。容器实测 ss 输出即 `127.0.0.53%lo:53` 格式（`red/r201.p2.log` 快照行），还原各分支照常工作，无误报。V016-08 由此完整闭合（见 §5）。 |
| R2-04 | P2 | **已修** | 代码：`scripts/restore-resolv.sh:411` 的 `stub_blockers` 检查已提到 unit 路径早返回（`:415` 的 `[ "$AGENT_WAS_ACTIVE" = 1 ] \|\| return 0`）之前。容器：红 r204 复现成立（`red/r204-restore.log:9-11`：还原先改 resolv.conf、后验证失败 exit 1）；绿 g204 22/23（`green/g204.log:46`），`green/g204-restore.log:7` 原文“错误: :53 上已有其他服务监听（0.0.0.0:53）……还原已中止（agent 未动，系统 DNS 未改……）”，清占位后重跑 rc=0 恢复。唯一 FAIL 是“占位已清”台架时序竞态（见 §7）。 |
| R2-05 | P3 | **已修** | 见 R2-01（同清）。 |
| R2-06 | P3 | **已修** | 代码：`web/index.html:775-783` 的 `copyServerInstall` 已包 try/catch，reveal 失败 alert 如实报错、不复制；token 为空同样不复制。浏览器复查 21/21（修复轮 2 证据）覆盖该路径；F1 未动该函数。 |
| R2-07 | P3 | **已修** | 代码：`scripts/restore-resolv.sh` 的 `cleanup_temp_state` 引入 `_revert_failed`，revert 失败时保留状态文件与开机 unit、不打印“清理完成”、返回 1（尾部注释明说）。lane 测试日志 `audit/evidence-v016r2-fix/shell/r2-07.log`。 |
| R2-08 | P3 | **已修** | 代码：`scripts/install.sh:701-702` 与 `:707-708` 均先 `write_temp_state` 再 `install_temp_boot_unit`，kill 窗口已堵。lane 测试 `audit/evidence-v016r2-fix/shell/r2-08-test.sh` + `r2-08.log`。 |
| R2-09 | P3 | **已修** | 代码：`scripts/install.sh:318` 起的 `verify_rule_domain` 已无 grep 兜底——python3 → jq → 无则 return 2 跳过并明说（注释“grep 兜底已删”）。lane 测试 `audit/evidence-v016r2-fix/shell/r2-09-test.sh` + `r2-09.log`。 |
| R2-10 | P3 | **已修** | 代码：`scripts/install.sh:1012` 的 EXIT trap 已覆盖 `BASELINE_CHECK_FILE` / `AFTER_CHECK_FILE` 及其 `.err`。lane 测试 `audit/evidence-v016r2-fix/shell/r2-10-test.sh` + `r2-10.log`。 |
| R2-11 | P3 | **已修** | 代码：`web/index.html:806` 注释“注释头不再带节点 IP”，头里只留名 + 地区。浏览器复查 21/21 覆盖。 |
| R2-12 | P3 | **仅观察，确认未动** | `stop_agent_no_unit` 仍是 `kill -TERM … || return 0`（EPERM 当成功）与 ss users 为空误判已停；本轮 diff 只 1 处提及（上下文），未修。维持登记，下版本。 |
| R2-13 | P2 | **已修** | 代码：`scripts/install.sh:781-786` 的 `probe_panel` 校验 whoami 响应形态——401 须含 `agent token`，200 须含 `server_id`，其余一律不算面板。lane 测试 `audit/evidence-v016r2-fix/shell/r2-13-test.sh` + `r2-13.log`；容器动态佐证：v12 s4 安装测速只选中回 401 的真面板（`green/v12-s4-install.log:10` “HTTP 401，1 ms”）。 |
| R2-14 | P3 | **已修** | 代码：`scripts/test-takeover-rig.sh:125-157` 跑前检查（flock 单跑锁 → 清残留 agent → 端口复查，任一被占报错退出）。本轮沙箱重跑无并行碰撞，145/0（见 §6）。 |
| R2-15 | P3 | **已修** | 容器阶段真跑：r215 三次跑的 rig-inner 日志 `green/rig-inner-container-run1/2/3.log`，第三次 137/10（见 §4）；`SKIP-容器阶段` 出现 0 次；`dig @127.0.0.53` UDP 断言真执行且 PASS（run3 `:32`、`:151`）。 |
| R2-16 | P3 | **已修** | 代码：`web/index.html:795-801`，reveal 成功但 IP 为空的服务器点名记进 emptyIp 并提示“未返回 IP，已跳过”，不静默。浏览器复查 21/21 覆盖。 |
| R2-17 | P3 | 登记，未动 | favicon 404，v0.1.6 之前就有，非回归。 |
| R2-18 | P3 | 登记，未动 | 强制改密后 logout 401，v0.1.6 之前就有，非回归。 |

## 2. R2-01 / R2-02 / R2-04 逐项裁定（容器红/绿）

### R2-01：红复现成立（最坏分支），绿两段确认

- **红 p1**（`red/r201.p1.log`，29/30）：永久接管 → `--temp` direct-write → 还原。还原 rc=0、resolv.conf 回 stub 软链、drop-in 已删、resolved 在跑、系统 DNS 可用；但 temp-state 与开机 unit 仍在（`:34-35` PASS，bug 复现）。唯一 FAIL 是 `:33`（F3-01 闪烁，非 R2-01）。
- **红 p2**（`red/r201.p2.log`，1/4）：重启后开机 unit 确实跑了（journal 有临时模式清理，PASS）；其余 3 项 FAIL 是**台架期望分支与实际分支不符**（见 §7），不是产品未复现。实测走的是复审报告写的“最坏情况：系统 DNS 死”分支，证据链完整：
  - journal：`dnsunlock-temp-restore.service` 启动，`cleanup_temp_state` 按 temp-state 记录把 resolv.conf 从临时状态恢复；
  - 快照：resolv.conf 仍是软链 → `/run/systemd/resolve/stub-resolv.conf`，但**目标文件内容已被写穿为 `nameserver 127.0.0.1`**（红版 `cleanup_temp_state` 的 direct-write 分支无 `.link` 记录时走 `cp -L orig /etc/resolv.conf`，内容透过软链写进 stub 目标文件本身）；
  - 清理同时停掉了临时模式启动的 agent，127.0.0.1:53 无人监听；`getent hosts example.com` 与 `getent hosts tiktok.com` 均为空，**系统 DNS 已死**；agent inactive；temp-state 与开机 unit 已自删（一次性，下次启动不再跑）。
  - 即：还原 + 重启后机器丢了全部 DNS（stub 目标文件被污染，需 `systemctl restart systemd-resolved` 重生成或再重启一次才恢复）。**与复审报告的“最坏情况”逐字一致**，红复现成立，且是最坏分支。
- **绿 p1**（`green/g201.p1.log`，29/30）：temp-state 已清、开机 unit 已删（`:34-35`），修复成立；唯一 FAIL 是 `:33`（F3-01 闪烁，红绿共有，不计入 R2-01 判定——见 §3）。
- **绿 p2**（`green/g201.p2.log`，5/5）：重启后 resolv.conf 仍是 stub 软链、tiktok 走上游、系统 DNS 可用、无 temp-state、无开机 unit。**R2-01 绿两段确认。**

### R2-02：红 21/21，绿 18/18，确认

- 红（`red/r202.log:39`）：`--dns-listen 127.0.0.1:5353` 写死 nameserver 127.0.0.1、系统 DNS 死、resolved 被自动停用（`red/r202-install.log:76` 升级处理原文）、agent 在 5353 上跑且 UDP `dig -p 5353 tiktok` 回规则 IP；还原 rc=0 干净恢复。
- 绿（`green/g202.log:45`）：日志明说“本次不接管”、resolv.conf 未动、resolved 仍在跑且 enabled、系统 DNS 可用、tiktok 走上游、agent 在 5353 上跑且 UDP dig 回规则 IP。**R2-02 确认。**

### R2-04：红复现成立，绿确认（唯一 FAIL 是台架竞态）

- 红（`red/r204.log`，22/23）：agent 已停 + 通配符占位时还原 rc=1、resolv.conf 已改、drop-in 已删、日志含“验证未通过”、系统 DNS 死、agent 仍停、无待办标记（`red/r204-restore.log:9-11`）；清占位后重跑还原 rc=0 恢复。
- 绿（`green/g204.log`，22/23）：还原 rc=1 停前中止、日志明说“已有其他服务监听”、resolv.conf 未动、drop-in 还在、agent 未动；清占位后重跑 rc=0、resolv.conf 回 stub、系统 DNS 恢复、agent 仍停（不谎报）。**R2-04 确认。**
- 两边唯一 FAIL 相同：“占位已清”——`stop_wildhold` 后 sleep 1 秒时进程尚未完全退出，ss 仍见 0.0.0.0:53；其后重跑还原 rc=0 且系统 DNS 恢复已证明 :53 当时已空。属台架时序竞态，非产品问题（见 §7）。

## 3. 新发现 1（F3-01，P2）：还原顺序闪烁——resolved 重启先于 resolv.conf 软链恢复，全局 DNS 被污染

### 现象（容器实测，红绿共有）

- r201 p1 与 g201 p1 的唯一 FAIL 相同：`[FAIL] 还原后 getent tiktok 走上游（分流已断）`（`red/r201.p1.log:33`、`green/g201.p1.log:33`）。
- 现场复核：`dig @127.0.0.53 tiktok.com A` 5 次里第 1 次返回规则 IP 203.0.113.99、其余返回上游 IP；`resolvectl dns` 显示 `Global: 127.0.0.1`、`Link host0: 1.1.1.1`；快照（数秒后）与还原自检均显示分流已断——即**还原后分流闪烁复活**，不是持续复活。

### 根因（代码 + 实测双重确认）

- 代码：`scripts/restore-resolv.sh` 的 `restore_from_dir` 先调 `reload_backends`（第 5 步，`systemctl restart systemd-resolved`），**最后**才恢复 `/etc/resolv.conf` 软链（第 6 步）。重启那一刻 resolv.conf 仍是外来文件 `nameserver 127.0.0.1`，新起的 resolved 把 127.0.0.1 当全局 DNS 导入；软链恢复后该导入不清掉。
- 同款顺序亦在 `restore_legacy`：第 6 行 `systemctl restart systemd-resolved`，第 16–19 行才恢复软链——**老路同病**，修时两处一起改。
- 决定性验证（RUN-NOTES 现场实测）：还原后手动 `systemctl restart systemd-resolved` 一次（此时 resolv.conf 已是 stub 软链），`Global:` 变空，`dig @127.0.0.53 tiktok.com A` ×4 与 `getent hosts tiktok.com` ×3 全部返回上游 IP，闪烁消失。缓存假说已排除：`resolvectl dns` 的 `Global: 127.0.0.1` 是污染的直接证据，且重启清掉 Global 即清掉闪烁。
- 发生条件：闪烁只在还原后 agent 仍在跑时现形——r201 p1 里 agent 监听 127.0.0.1:53（特定地址分支），还原后 `restore_agent_after` 把它恢复运行（`red/r201-restore.log:11-12` “agent 已恢复运行（监听 127.0.0.1:53）”），stub 便把查询同时发给 agent（规则 IP）与上游 1.1.1.1，按快慢取胜。通配符 :53 的 agent 还原后保持停止，Global 127.0.0.1 无人应答时查询只走上游、不出规则 IP（至多一次超时抖动）。

### 定级：P2，必修

- 还原的操作契约是“系统 DNS 回到接管前状态，分流彻底断开”；闪烁违背该契约——用户还原后仍可能间歇性走解锁 IP，且无法从表面察觉（快照与自检都显示已断）。与 R2-01 同属“还原后状态残留”家族，但比 R2-01 轻：不死 DNS、不留持久状态，重启后（p2）干净（g201 p2 5/5、r201 p2 的 DNS 死与闪烁无关），一次 resolved 重启即可清掉。定 P2，不定 P1。
- **修法（二选一，推荐前者）**：(a) 调换顺序——先恢复 resolv.conf 软链（第 6 步提前），再 `reload_backends` 重启 resolved；重启时读到的是 stub 软链，`Global:` 为空（手动重启实验已证明该顺序有效）；(b) 重启后显式清全局 DNS（`resolvectl revert` / `resolvectl dns <link> ""`）。两处还原路径（CHOSEN + legacy）都要改。
- **同机制族横扫**（已枚举到闭合）：`cleanup_temp_state` 不重启 resolved（注释明说绝不能直接 restart），不受影响；接管体先写 drop-in 再重启 resolved、后写 resolv.conf，顺序正确，不受影响；`reload_dns_service` 的 NM 分支（`nmcli general reload` + 按 UUID 重激活）推的是 DHCP 的链路 DNS，不读 resolv.conf，不受影响；`uninstall.sh` 只调还原，不自带顺序问题。
- **复验要求**：容器里还原后立即 `dig @127.0.0.53 tiktok.com A` ×5 全走上游 + `resolvectl dns` 的 `Global:` 为空 + `getent hosts tiktok.com` 走上游；CHOSEN 与 legacy 两路各一遍。

## 4. 新发现 2（F3-02，P2）：重装不重启 agent——`enable --now` / `start` 在已运行服务上是 no-op，新配置从未加载

### 现象（容器实测，v12 步 4）

- `green/v12.log:28,29,33`：步 4（agent 已在 :53 跑时重装 `--dns-listen 127.0.0.1:5353`）3 FAIL——安装 rc=1、无“本次不接管”、dig -p 5353 无应答；但 resolv.conf 未动、resolved 仍在跑、系统 DNS 可用（守卫侧无破坏）。
- 日志逐秒对证（`green/v12-s4-install.log`）：[2/6] 已按新地址写好配置（`:7` “监听地址 127.0.0.1:5353 可绑定”）；[3/6] 的 `systemctl status` 行显示 `Main PID: 12325`（`:24`，步 2 还原时起的 :53 agent，02:41:14，`:32-33` journal 同一时间戳）；[4/6] 按新地址 dig @127.0.0.1 -p 5353 → 无监听 → “验证失败” → exit 1（`:36`）。
- 同一条安装在 g202 能过，只因当时 agent 没在跑、`enable --now` 真启动了它。**真产品 bug，不是台架用法问题**——台架跑的是文档化的重装命令，失败是确定性的（服务在跑时每次都失败）。

### 根因（代码确认）

- `scripts/install.sh:1119`（永久分支）：`systemctl enable --now dnsunlock-agent`；`:1117`（临时分支）：`systemctl start dnsunlock-agent`。服务已在跑时两者都是 no-op，写好的新配置从未加载，随后的 [4/6] 验证按新地址探测必然失败。
- **V016-37 的活体复现**：该项在复审台账里原登记为 P3（“重装时对已运行 unit 的 `enable --now` 是 no-op：旧 agent 进程继续跑旧配置”，处置“下版本重装时若 unit 已 active 则 restart”）。容器现给出红证，升级为 P2（F3-02），原登记项闭合。

### 定级：P2，必修

- 重装是正常操作（改监听地址、改 allowlist 都靠重装），在 agent 已运行这个最常见的前提下确定性失败，且留下“配置文件已改、运行中进程仍是旧配置”的分裂状态；用户重跑安装会以同样方式再失败一次，只能手动 `systemctl restart` 解套。系统 DNS 不受损（失败响亮、无静默破坏），不定 P1。
- **同机制族横扫**（已枚举到闭合，3 处）：
  1. `install.sh:1119` 永久分支 `enable --now dnsunlock-agent`——本次红证。
  2. `install.sh:1117` 临时分支 `systemctl start dnsunlock-agent`——同款 no-op：临时重装且 agent 已在跑时新配置同样不加载、[4/6] 同样失败。修时一起改。
  3. `install.sh:1048` SNI 代理 `systemctl enable --now dnsunlock-proxy`——**同款问题且更坏**：重装解锁节点改 allowlist 时旧代理继续跑旧 allowlist，而脚本随后直接打印“完成: SNI 代理已在 :443 运行”并 exit 0，**无验证步骤，静默成功**。allowlist 是用户防泄漏的真实防线（见 MEMORY.md），旧 allowlist 残留意味着已删的 IP 仍能用代理（泄漏）或新加的 IP 用不了。修时一起改，并给 SNI 路径补一个“新配置已加载”的验证（至少确认监听进程的启动时间晚于本次安装）。
  - 已排除：`restore_agent_after` / `abort_restore_agent` 的 `restart_agent`（`systemctl start`）——中止/恢复路径上 agent 刚被停掉，start 是正确动作，且无配置改写；`uninstall.sh` 只停不停启；`install-panel.sh` 面板重装时 8080 被占直接拒绝，不走 no-op。
- **修法**：[3/6] 改为“unit 已 active 时 `restart`，否则 `enable --now` / `start`”（或无条件 `restart`——对未运行的 unit，restart 即启动；但须保留 `enable` 以保开机自启）。三处同改。
- **复验要求**：容器里 agent 在跑时重装 `--dns-listen 127.0.0.1:5353` → rc=0 + Main PID 变化 + dig -p 5353 回规则 IP；SNI 重装改 allowlist → 新 allowlist 生效（旧 IP 拒绝 / 新 IP 放行至少验一侧）。
- **台架记录**：v12 步 4 的 3 个 FAIL 里，“无‘本次不接管’”不是产品问题——接管提问（`install.sh:1174` 的 `ask TAKEOVER`）在 [4/6] 验证（`:1126`）之后，安装在 [4/6] 退出时根本没走到提问，守卫文案不可能出现；该断言不可达，台架应修正（只在安装走到接管提问时才断言守卫文案）。其余 2 个 FAIL（rc=1、无 5353 监听）是 F3-02 的真证据。

## 5. R2-15 与 V016-12 裁定

### R2-15：已修，零产品 FAIL 站得住

- 容器阶段真跑了 rig-inner 三次：run1 55/92 → run2 128/19 → run3 **137/10**（`green/rig-inner-container-run3.log:193`）；`SKIP-容器阶段` 出现 0 次；`dig @127.0.0.53` UDP 断言真执行且 PASS（run3 `:32` S0、`:151` S13，TCP 对照亦 PASS）；S14 用真 python3 跑通（run3 `:160-164`）。
- 剩余 10 项逐项核对（run3 FAIL 行 `:30`、`:49`、`:56`、`:65`、`:70`、`:72`、`:94`、`:95`、`:136`、`:152`），**全是环境 artefact，无一产品 FAIL**：
  - 夹具 DNS 198.19.0.1 容器内不通 6 项：S0、S3×3（restore rc、还原后验证、还原后 getent）、S11、S13——容器内 dig 直证 no servers；沙箱里它能应答，故干跑能过；夹具值本身被台架断言（S1b metadata 含 198.19.0.1），不能改。
  - 沙箱专属期望 3 项：S1b use-vc（断言名自述“沙箱 UDP 回环不通”；容器 UDP 通故不写 use-vc，产品行为正确）、S6×2（容器上游 1.1.1.1 通，验证通过故不升级、不警告；沙箱 chroot 上游不通才升级。产品按实测验证结果行动，正确）。
  - getent-hosts IPv6 quirks 1 项：S1b 接管后 example.com——台架内 `getent hosts` 对双栈域名只回 AAAA，断言 grep IPv4 恒失败；与 harness 已修的同类问题同根（`getent ahosts` 列双栈）。
- r215 场景断言仍 11/1（`green/r215.log`），仅 rig-inner rc=1（上述 10 项 artefact 的后果）。**R2-15 闭合。**

### V016-12：tip 现货证据已补，步骤 4 的 FAIL 就是 F3-02

- 复审曾要求“顺手补一次 tip 重跑（非发版必要条件）”；本轮 v12 五步在 tip 1f24428 的绿二进制上跑了：**24/3**（`green/v12.log:44`）。
- 步 1–3 全过：永久安装 :53、还原 rc=0、**还原后 agent 已恢复运行（特定地址分支），dig @127.0.0.1 tiktok → 规则 IP（UDP）、dig @127.0.0.53 example 通（UDP）**——P1(a) 特定地址分支在真 resolved 下再次证实。
- 步 4 的 3 FAIL：2 个是 F3-02 的真证据（rc=1、无 5353 监听），1 个是台架断言不可达（见 §4 末）。**步 4 就是新发现 2**，与 V016-12 本身无关。
- 步 5（127.0.0.53:53 反向安装）记录：安装器先检测到 stub 占位并提问“是否关掉 stub 监听”，台架答 y 批准后装上（rc=0，agent 在 127.0.0.53:53 跑），还原 rc=0、agent 仍停、stub 回来、系统 DNS 可用——行为有提示、还原干净，无缺陷；仅记录在案。
- **V016-12 的 tip 重跑要求已满足**，证据现货有效。

## 6. 沙箱动态验证（本轮自己动手）

- **`go test ./...`（tip 1f24428）全绿**：dnsagent ok 21.4s、panel ok、sniproxy ok，其余无测试文件。Go 代码本轮区间无改动（F1 只改 HTML），结果与修复轮 2 的归档日志一致。
- **`scripts/test-takeover-rig.sh`（tip 1f24428）145/0，exit 0**：逐场景日志归档 `audit/evidence-v016r2-fix/rig-20261122-0253Z-scenarios/`（30 个文件）。容器阶段 2 项 UDP 断言（S0、S13 的 `dig @127.0.0.53`）在沙箱干跑中为 SKIP（沙箱回环 UDP 不通的已知预期），但该 2 项已由真容器 r215 run3 执行并 PASS（§5），覆盖完整，无缺口。
- **F1 浏览器重验复核**：`audit/evidence-v016r2-fix/browser/f1/results.json` 9/9 全过——F1a 首次见到 request_id 耗时 0.165s（要求 <1s），F1b 结果 30.6s 后到达、同一 request_id（st-1795305967905041301）展开；R1 12 张卡、R2 选 JP 保存、R3 搜索 netflix 剩 2 张；E1/E2/E3 零 pageerror / 零 console 报错 / 零失败请求。截图 3 张在档。diff 核对：F1 只改一行（`web/index.html:714` 补 `renderServers();`），两份 index.html 字节一致（sha256 `a667dddd…`），served 哈希与源码一致。**F1 修复成立，无回归。**
- **静态检查**：两份 index.html `node --check` 通过（F1 报告）；两份 install.sh 字节一致（sha256 `780364ac…`）；`scripts/check-restore-sync.sh` 通过（“还原脚本双份来源一致”）。
- **测试机宿主机只读核对**（本轮实测，未做写操作）：resolv.conf sha256 `4443d364e93cbe02f76a7adff16bad35872ad3307cb4d5421b837833fd81584f`（基线未动）、panel pid 2652616、agent pid 2652618、二进制 `1084e5e9…` 均为放行前原状；`machinectl` 无机器；br-v016 已删；`/var/lib/machines/` 为空。宿主机干净。

## 7. 台架问题记录（非产品，修台架）

1. **v12 步 4“本次不接管”断言不可达**（见 §4 末）：接管提问在 [4/6] 验证之后，安装在 [4/6] 退出时没走到提问。台架应修正该断言的触发条件。
2. **r201 p2 复活分支断言与最坏分支不匹配**：台架按“分流静默复活”分支断言（resolv.conf 为普通文件 127.0.0.1、agent 在跑、tiktok 走规则），实际走的是复审报告的“最坏情况：系统 DNS 死”分支（stub 目标文件被写穿、agent 已停、getent 全空）。红复现成立，台架期望缺口已记录，不改判。台架 p2 应按分支断言（先判走哪支再断言该支的末态），或只断言“重启后 temp-state/unit 已清 + 系统状态与任一已知分支一致”。
3. **r204/g204“占位已清”时序竞态**：`stop_wildhold` 后 sleep 1 秒时 wildhold 进程尚未完全退出，ss 仍见 0.0.0.0:53；其后重跑还原 rc=0 且系统 DNS 恢复已证明 :53 当时已空。台架应在断言前轮询等进程退出（或 sleep 加长 + 重试），非产品问题。
4. **RUN-NOTES 台架修补已核对**：`stub_listening` 的 grep 改为 `127.0.0.53`（Debian 12 ss 印 `127.0.0.53%lo:53`，与 R2-03 同类）；`getent_example_ok` 与两处“系统 DNS 已死”断言改用 `getent ahosts`（容器内 `getent hosts` 对双栈域名只回 AAAA）。两次基线 FAIL 均为台架量测问题，修补后 r201 p1 基线 9/9 全过。合理。

## 8. 发版门（修复轮 3 必须全部完成，再走一次聚焦复审）

| # | 项 | 级别 | 修法 | 复验 |
|---|---|---|---|---|
| 1 | F3-01 还原顺序闪烁 | P2 | 调换顺序（先恢复 resolv.conf 软链，再 `reload_backends` 重启 resolved），CHOSEN + legacy 两路；或重启后显式清全局 DNS | 容器：还原后立即 `dig @127.0.0.53 tiktok.com A` ×5 全走上游 + `resolvectl dns` 的 `Global:` 为空 + `getent hosts tiktok.com` 走上游；两路各一遍 |
| 2 | F3-02 重装不重启 agent | P2 | [3/6]：unit 已 active 时 `restart`（否则 `enable --now` / `start`），三处同改——agent 永久分支 `:1119`、agent 临时分支 `:1117`、SNI 代理 `:1048`；SNI 路径补“新配置已加载”验证 | 容器：agent 在跑时重装 `--dns-listen 127.0.0.1:5353` → rc=0 + Main PID 变化 + dig -p 5353 回规则 IP；SNI 重装改 allowlist → 新 allowlist 生效（至少验一侧） |
| 3 | F3-03 还原未跑分支漏 disable | P3 | `restore_agent_after` 首分支（`AGENT_WAS_ACTIVE != 1`）补 `_enabled_boot_disable` 调用（函数内已有 `AGENT_WAS_ENABLED=1` 守卫，未 enabled 时是 no-op） | 容器：agent enabled 但已停时还原 → 还原后 agent 为 disabled；下次启动不抢 :53 |
| 4 | 台架修正 | — | v12 步 4 断言触发条件、r201 p2 按分支断言、`stop_wildhold` 轮询等进程退出 | 随 F3-01/02 复验一并跑通 |
| 5 | 复验 | — | `go test ./...` 全绿；台架 145/0；容器红/绿跑日志归档进仓库；宿主机核对收尾 | 再走一次聚焦复审（只审新 diff + 本节动态验证），通过方可发版 |

## 9. 残留风险登记

- R2-12、R2-17、R2-18：仍仅观察/登记，下版本。
- V016-29、V016-35、V016-36 仍仅记录，下版本；V016-37 已升级为 F3-02（P2），由 F3-02 跟踪，台账里标注升级关系（duplicate_of）。其中 V016-36（install/restore 无锁）与 F3-01 同属“还原窗口”家族，F3-01 的修法不涉及加锁，V016-36 仍登记。
- V016-08、V016-12、V016-27：本轮闭合（见 §1、§5）。
- 修复轮 2 的台账状态已同步更新到 `audit/findings-ledger-v016.csv`（R2-01~R2-11、R2-13~R2-16 改 fixed，V016-08/V016-12/V016-27 改 fixed，V016-37 标注升级为 F3-02，新增 F3-01~F3-03）。
- 工作区卫生：worktree 根下仍有未入库目录 `dist-green/`、`dist-red/`（构建产物，未提交，不在 diff 内）与浏览器证据目录，建议修复方清理或入 `.gitignore`（复审轮已提两轮，未处理）。
- 本复审未改产品代码、未 push/tag/发版、未碰生产面板；测试机宿主机只读核对通过（见 §6）。

## 10. 自查

- 每条 P1/P2 均有红证或容器/代码级实证（容器红/绿日志原文行号见 §2–§5、代码行号见 §1/§3/§4），非复述修复方说法；F3-01/F3-02 的根因均在代码中逐行确认，机制族横扫到闭合清单（F3-01：5 处已枚举，2 处同病；F3-02：3 处已枚举，另 3 处已排除并写明理由）。
- 与 RUN-NOTES 的分歧已裁决并记录：v12 步 4 的“无‘本次不接管’”不是产品问题（断言不可达）；r201 p2 的 3 个 FAIL 不是产品未复现（分支不匹配，实际是最坏分支）；r204/g204 的“占位已清”是台架竞态。RUN-NOTES 的其余结论（红复现、绿通过、r215 artefact 分类、V016-12 步 5 记录）逐项核对日志原文后采纳。
- F1 只改一行，浏览器重验 9/9 已复核 results.json 与截图，无回归；`go test` 与台架均由本轮在 tip 上亲手重跑（非引用修复方日志）。
