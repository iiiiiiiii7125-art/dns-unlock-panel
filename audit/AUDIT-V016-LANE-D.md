# D 线审计报告：v0.1.6 全仓库回归扫荡

- 审计对象：`~/workspace/dns-unlock-panel-v016`，分支 `feature/v0.1.6-takeover`，tip `374e7b7`
- 基底：v0.1.5（main `817c606`）
- 实测 diff：`git diff 817c606..HEAD --stat` = **40 files changed, 5230 insertions, 198 deletions**（与任务所述 40 个文件一致）
- 审计方式：只读。未改代码，未 push/tag/发版，未碰生产面板 https://dns.0v0.baby
- 结论：**无 P0、无 P1；6 项 P2（均为计划符合度偏离 / 功能缺口，无开放代理、无 token 泄露、无数据丢失路径），9 项 P3。** P1(a)/(b) 修复在代码层复核通过（见 §5）。是否带 P2 发版，由父级 / 用户定夺——计划与用户决定要求的是全量范围，P2-01～P2-05 都是计划内已承诺项的缺口，不建议静默放过。

## 0. 实跑验证输出（只读命令的实际结果）

| 检查 | 命令 | 结果 |
|---|---|---|
| 构建 | `go build ./...`（`~/go/bin/go`，go1.25.1） | EXIT 0（仅 GOPATH/GOROOT 同目录 warning，与代码无关） |
| 静态检查 | `go vet ./...` | EXIT 0 |
| 测试 | `go test ./...` | EXIT 0：`dnsagent ok (11.2s)`、`panel ok`、`sniproxy ok`，其余无测试文件 |
| 测试（fresh） | `go test -count=1 ./...` | 输出同上，全部 ok（11.4s）。**注意：该次调用返回了 `userConfirmationRequired: timed_out`，但终端输出已完整显示通过结果；按指令不重试，特此说明，审批状态未明不影响已看到的输出** |
| 还原同步 | `scripts/check-restore-sync.sh` | EXIT 0：`还原脚本双份来源一致（两份 install.sh 内嵌 == scripts/restore-resolv.sh，且两份 install.sh identical）` |
| 脚本语法 | `bash -n` 全部 `.sh`（install/restore/uninstall/check-restore-sync/test-takeover-rig/rig-inner/全部 stubs/build/install-panel/install-unlock-node/cloudflare-tunnel） | 全部 OK。`scripts/sync-restore.sh` 是 Python（shebang `python3`），`bash -n` 对它报错属预期；`python3 -c compile(...)` 检查通过 |
| 前端 JS | 提取 `web/index.html` 内唯一 `<script>` 块，`node --check`（node v24.22.1） | OK。`node --check index.html` 本身对 HTML 无意义，故改为抽 JS 检查 |
| shellcheck | 不可用（`shellcheck: command not found`），未执行 |

## 1. 嵌入式资产三对字节一致（已验证）

| 对 | 结果 |
|---|---|
| `web/index.html` vs `internal/panel/assets/index.html` | IDENTICAL（sha256 前 16 位 `bf96083145a8fa2e`） |
| `scripts/install.sh` vs `internal/panel/assets/install.sh` | IDENTICAL（`2c286b62365781cb`） |
| `data/platforms.json` vs `internal/panel/assets/platforms.json` | IDENTICAL（`cc3e2110b96392d3`），本次 diff 未改动 platforms.json |

## 2. 发现清单

### P2-01 — PreferFastest 没有 UI 开关：后端 + agent 已实现，用户在界面上永远打不开
- 证据：
  - `grep prefer_fastest web/index.html` = **0 命中**；`internal/panel/assets/index.html` 同样 0 命中。
  - 规则编辑器只有 `auto_failover` 复选框（`web/index.html:354,541`）；三处保存路径（卡片保存 `:381`、编辑器保存 `:547`、批量保存 `:604,627`）构造的请求体都不含 `prefer_fastest`，`PENDING` 构造（`:505`）也不含。
  - 后端已接好：`internal/panel/panel.go` 的 `handleRules` / `domainConflict` 解析 `prefer_fastest`，`resolveIP` 有最快节点分支，`regionCandidates` 生成 `candidates`；agent 侧 `pickFastest` / `refreshFastest` / `checkHealth` 探候选节点也已实现。
- 影响：计划第 3 项“做成按规则的独立开关（默认关）”只完成了一半——功能只能走 API 直接调用才能开启，UI 用户无法使用。定 P2（非破坏性，功能不可达）。
- 修复方向：卡片编辑器 + 规则编辑器加 `prefer_fastest` 复选框，三处保存路径透传该字段。

### P2-02 — 计划第 3 项“安装端并行测速”未做：`probe_panel` 与 817c606 字节一致，`pick_fastest_ip` 只删了一个变量
- 证据：
  - 逐函数提取比对：`probe_panel()` 与 `817c606:scripts/install.sh` **完全一致**（仍为顺序试候选、第一个有 HTTP 响应就赢，无 curl 计时、无排序、无排名打印）。
  - `pick_fastest_ip()` 与基底仅差一行：`local best="" ip ok` → `local best="" ip`（0874b2e 的 SC2034 修复）。仍为顺序 `/dev/tcp` 探测、第一个通的就赢，无计时、无并行。
  - 计划原文要求：安装端“改成并行测全部候选端点（curl 计时，8 秒超时不变），按延迟排序，选最快且可达的做 PANEL_BASE，并打印排名”。
- 影响：面板在同一台机器时，配置的公网 URL 先被试中（即使本机 `:8080` 更快）；`--unlock-ips` 多 IP 时第一个通的即当默认解锁 IP，而非最快。定 P2（计划偏离；不断网、不出错，只是不是最优）。

### P2-03 — 计划第 4 项“接管前后基线对比”未接线：`dnsunlock check` 存在但 installer 从未调用
- 证据：
  - `grep -n "dnsunlock check\|--via\|RunCheck" scripts/install.sh`：仅命中 `[0/6]` 的旧注释“装前基线测试（P1-11…)”，无任何调用。`internal/dnsagent/check.go`（`RunCheck`）+ `cmd/dnsunlock/main.go`（`runCheck`，exit 0/1/2 契约）+ 测试（`check_test.go`）都已实现，但安装流程接管前/后均未执行，接管前后无并排对比输出。
  - 计划原文：“installer 在接管前跑一次基线（规则域名走上游直接解析的结果），接管后再跑一次（走 agent），两次结果并排打印，用户当场看到变化。实现首选 Go 的 `dnsunlock check` 模式”。
- 影响：用户无法在安装现场看到接管是否改变了解析结果；第 4 项只完成了一半（面板自测按钮已做，installer 基线未做）。定 P2。

### P2-04 — `verify_rule_domain` 取的是最后一条规则，不是注释说的第一条 address 规则；末条 `node_ip` 为空时误判“无规则”跳过
- 位置：`scripts/install.sh:268-300`（`verify_rule_domain`），注释称“取自面板 … 的第一条 address 模式规则”。
- 红证（沙箱复现，复现脚本 `/tmp/v016-audit/lane-d/vrd-repro.sh`）：
  - 场景 A：配置含两条 address 规则（tiktok `203.0.113.99` 在前，netflix `1.2.3.4` 在后）→ 提取到 `domain=netflix.com node_ip=1.2.3.4`（取到最后一条）。
  - 场景 B：末条为 nameserver 模式规则（`node_ip=""`）→ 提取到 `domain=sora.com node_ip=''` → 函数走“当前没有 address 模式的规则”分支返回 rc=2 跳过，尽管前面明明有 address 规则。
  - 根因：两处 `sed 's/.*\"domains\"…/'` / `s/.*\"node_ip\"…/'` 的贪婪 `.*` 在单行 JSON 上恒取最后一次出现。
- 与 rig S14 的关系：MEMORY 交接称 rig “126 PASS + 1 FAIL（S14 verify_rule_domain）”。本缺陷的表现（应通过却跳过/验错规则）与该 FAIL 一致，是合理解释；但 rig 当时的真实规则排序无日志留存，**无法断定 S14 就是此次触发**，故 S14 根因标为“未完全确认”，本条以函数本身的沙箱复现定级。定 P2（接管后验证不可靠：多规则 / 混合模式下可能跳过或验错规则；不破坏 DNS 本身）。
- 修复方向：用 python3/`jq` 按规则数组解析，取第一条 `mode=address` 且 `node_ip` 非空的规则；无 `jq` 时至少按规则对象切分而非贪婪全文匹配。

### P2-05 — 临时模式（`--temp`）留下永久状态，与“重启后失效 / 不停任何管理器”的承诺不符
- 证据（执行顺序）：
  - `scripts/install.sh:620-650` 的 stub 处理块在 `--temp` 分支（`:831-835`）之前执行：只要 `:53` 被 resolved stub 占着，就会调 `disable_stub_listener`（`:207`）写持久 drop-in `/etc/systemd/resolved.conf.d/dnsunlock.conf`（`DNSStubListener=no`）并 `systemctl restart systemd-resolved`。
  - `systemctl enable --now dnsunlock-agent`（`:803`）同样在 temp 分支之前执行，服务永久启用。
  - `apply_temp_dns`（`:459`）本身确实不写永久备份、不加 chattr 锁，但上述两处持久化发生在它之前，且 temp 流程无任何清理。
- 后果推演（代码级）：重启后 agent 自启；resolvectl 设置虽失效，但静态 resolv.conf（直接写路径时已去掉软链）仍写 `nameserver 127.0.0.1`，或走 stub 地址 `127.0.0.53`（通配符 `:53` + P1(b) pktinfo 回包仍能答）——两种路径下系统 DNS 实际上**继续走 agent**，“重启后失效”不成立。计划第 5 项还要求临时模式“不停任何管理器”，而 drop-in + restart 已动了 resolved。定 P2（语义违背；不导致断网，反而是“关不掉”的临时模式）。
- 修复方向：`--temp` 时跳过 `disable_stub_listener` 的持久 drop-in（改走临时端口监听或仅本次生效的 stub 处理），或在 temp 说明中明确列出重启后残留项及清理命令；`dnsunlock-restore-dns` 的无备份提示也应提及 drop-in 残留。

### P2-06 — 提交进仓库的构建产物：`scripts/__pycache__/sync-restore.cpython-312.pyc`
- 证据：`git ls-files | grep pyc` 命中该文件（2024 字节），`git log --diff-filter=A` 显示由 `0874b2e`（“删 pick_fastest_ip 未用的 ok 变量”）顺带提交；`.gitignore` 只有 `data/panel.json`、`data/panel.json.bak`、`dist/`、`*.log`，未覆盖 `__pycache__`。
- 根因关联：`scripts/sync-restore.sh` 实际是 Python 脚本却用 `.sh` 后缀，某次直接 `python3 scripts/sync-restore.sh` 运行即在仓库内生成 `__pycache__`。
- 定 P2（按任务要求“提交进仓库的任何构建产物/缓存文件都算发现”；文件本身无害，但属仓库污染，且每次运行同步脚本都会再生）。修复：从 git 删除该文件，`.gitignore` 加 `__pycache__/` 与 `*.pyc`，或把同步脚本改名为 `.py`。

### P3-01 — 自定义 `--dns-listen` 非 53 端口时，接管/临时模式仍写 `nameserver 127.0.0.1`（端口隐含 :53），系统 DNS 必然指错地方
- 位置：`scripts/install.sh:962-964`（接管）、`:452-454`（临时模式 `write_temp_resolv_conf`）。resolv.conf 没有端口字段，`127.0.0.1:5353` 无法表达。
- 证据：`git show 817c606:scripts/install.sh:558` 在基底已是同样写法，**属前置缺陷，非 v0.1.6 引入**；v0.1.6 的临时模式继承了它。流程上：`probe_agent_transport` 按 `$_dl_host:$_dl_port`（5353）探测是通过的，但写盘后 `verify_system_dns`（查 :53）失败 → 升级停用 resolved → 仍失败 → 只剩警告 + 还原命令。
- 定 P3（前置缺陷 + 有警告兜底 + 需用户同时用两个冷门选项才触发）。修复方向：监听端口 ≠53 时拒绝接管/临时模式并明说，或提示改回 :53。

### P3-02 — 自测结果在 heartbeat 发送前就被清空：heartbeat 失败则结果永久丢失，UI 等满 90 秒才报错
- 位置：`internal/dnsagent/agent.go` `sendHeartbeat`（约 :820-850）：`stResult := a.selftestResult; a.selftestResult = nil` 在前，随后 `panelDo`；`if err != nil { fmt.Printf("[agent] heartbeat failed…"); return }`，无恢复。面板侧 `LastSelftest` 永远收不到，`web/index.html` 的 `runSelftest` 轮询 30 次 × 3 秒后报“90 秒内未收到结果”。
- 定 P3（仅当 heartbeat 恰好失败时丢一次自测结果；重试需等 10 分钟 pending 过期后重新 POST）。

### P3-03 — 面板在下发配置时即消费自测请求：agent 取到配置后崩溃/未执行，10 分钟内无法重新排队
- 位置：`internal/panel/panel.go:1381-1475`（`handleAgentConfig` 下发后第二个 `store.Update` 直接 `delete(d.SelftestPending, serverID)`）；`handleServerByID` 的 POST 自测在 10 分钟内未消费请求返回 409。agent 侧虽有 `selftestDone` 去重，但消费与执行之间无确认。
- 定 P3（窄窗口 + 有 10 分钟后自愈）。

### P3-04 — 还原时 `record_and_stop_agent` 的 `:53` 占用检查会把 resolved stub 本身当成障碍而误中止
- 位置：`scripts/restore-resolv.sh` `record_and_stop_agent`：`ss -tuln | grep -qE ':53[[:space:]]'`，10 秒等不到空闲即 `exit 1`。
- 红证（沙箱 grep 模拟）：`127.0.0.53:53` 的 ss 行命中该模式（`:5353` 行不命中，模式本身无误）。正常接管后 stub 已关，此分支不触发；可达场景：用户接管后手动重开了 stub、或 agent 监听非 :53 端口但 stub 仍在跑。此时还原本应重启 resolved 接管，却先被自己的检查挡住。
- 定 P3（边缘场景误中止；中止时未改任何文件，安全但困惑）。

### P3-05 — `dnsunlock check` 的手写 DNS 客户端：固定查询 ID `0x1234` 且不校验 ID/RCODE；标签超长会溢出
- 位置：`internal/dnsagent/check.go`：`buildQuery` 写死 `0x12, 0x34`；`parseAnswerA` 只看 ANCOUNT，不校验 ID 与 RCODE；`byte(len(l))` 在标签 >63 字节时回绕。
- 定 P3（查询是顺序的、3 秒 deadline、UDP 走 connected socket，实际串扰概率极低；属于手写解析器的健壮性债）。

### P3-06 — 过时注释：`install.sh:824` 引用不存在的 `run_speed_test`，并称“测速环节缺 dig 仍是致命的”
- 证据：`grep -rn run_speed_test scripts/ internal/` 全仓库仅该行注释；`pick_fastest_ip`（`:65`）用 `/dev/tcp`，根本不用 dig；其头注释还称“有 python3 就用它计时”，函数内无任何计时。属 P2-02 未做并行测速后留下的文档漂移。
- 定 P3。

### P3-07 — `uninstall.sh` 只认 `/etc/dnsunlock/resolv.conf.orig`：该文件丢失时即使结构化备份齐全也跳过 DNS 还原
- 位置：`scripts/uninstall.sh:11` 以 `[ -e /etc/dnsunlock/resolv.conf.orig ]` 为唯一触发条件；`do_backup` 写 `.orig` 时有 `|| true` 静默失败路径。随后步骤仍会 `rm -rf /etc/dnsunlock`。
- 定 P3（`.orig` 正常存在时不受影响；丢失属边缘情况，但后果是卸载后 DNS 保持被接管状态）。

### P3-08 — 自测去重表 `selftestDone` 永不清理；`verify_rule_domain` 用固定 `/tmp` 文件名
- 位置：`internal/dnsagent/agent.go` `selftestDone map[string]bool`（每次请求一个条目，永不删除；量极小）；`scripts/install.sh` `verify_rule_domain` 用固定 `/tmp/dnsunlock-agent-config.json`（并行安装会互踩）。
- 定 P3（均为微小健壮性项）。

### P3-09 — 老路还原（`restore_legacy`）不恢复 nsswitch / resolved.conf，不重新启用被升级停用的 resolved
- 位置：`scripts/restore-resolv.sh` `restore_legacy`：只删 drop-in、`restart systemd-resolved`、恢复 NM/dhclient/netplan。`systemctl restart` 对已 `disable --now` 的单元只会本次启动，不恢复 enable；nsswitch 的 `dns` 补位也不回滚。
- 定 P3（仅影响 v0.1.6 之前版本留下的单份 `.orig` 备份；v0.1.6 的结构化路径 `restore_from_dir` 会按 metadata `enable --now`，不受影响）。

## 3. 复核通过、无发现的项

- **allowlist 默认拒绝（DNS 与 SNI 两端）**：部署入口 `cmd/dnsunlock/main.go:140-149` 的 `failClosedAllowlist` 在 `runAgent`（`:220`）与 `runProxy`（`:351,354`，含 HTTP 代理）均调用：空 allowlist + 非回环监听直接 `log.Fatalf` 拒绝启动；仅回环监听放行本地测试。库层 `Agent`/`Proxy` 空 allowlist 只警告（`agent.go:189-193`、`proxy.go:104-105`），但无效条目在 `Run()` 拒绝启动（`agent.go:1305-1308`、`proxy.go:304-306`）。安装脚本侧：DNS allowlist 必填循环（`install.sh` P0-04 段），SNI 空 allowlist 直接 `exit 1`。三层一致，无缺口。**本次 diff 未改动该逻辑**（agent 侧仅把无 allowlist 警告从 stdout 移到 stderr，避免污染 `dnsunlock check` 的机器可读输出，正确）。
- **token / 密码处理（未改动，本次复核无新问题）**：token 只走 `DNS_AGENT_TOKEN` 环境变量或 `/dev/tty` 交互输入（无 `--token` 参数），只写 0600 配置与 0600 curl 配置（`AUTH_CFG`，trap 删除），不进启动命令/日志；面板 reveal 接口（`panel.go:728,1133`）为 admin 会话鉴权、按需返回；admin 密码 bcrypt（`panel.go:162,182,530-534`），默认密码首次登录强制改密（`must_change` 门禁 `:402-406`，改密后作废全部会话 `:544`）。`copyNodeInstall`（`web/index.html`，374e7b7 新增）逐台调 reveal 取完整 IP 拼 allowlist——在已登录 admin 会话内操作，符合既有 reveal 语义。
- **备份 / 还原路径（结构化部分实现正确）**：`do_backup`（install 与 restore 各一份，注释说明了 drop-in stash 差异是故意的）写 `/var/lib/dnsunlock/backup/<时间戳>_<标签>/` + `metadata.txt`（时间、标签、当时 DNS、后端、resolved/NM/resolvconf active/enabled、NM 主连接 UUID），首份备份永不覆盖，`/etc/dnsunlock/resolv.conf.orig` 仅作兼容指针写一次；还原默认最早一份、可编号选择、还原前自动备份失败即中止、还原后 `verify_after_restore` 报告“已还原并验证通过 / 未通过”；`reload_dns_service` 按备份后端分发（resolved restart / `nmcli general reload` + 按 UUID 重新激活 / netplan apply / resolvconf -u），失败只警告。`restore_from_dir` 的 drop-in stash 三分支与 `resolved.conf.d` 恢复顺序复核无误。
- **SNI proxy 相关路径**：`internal/sniproxy/` 本次零改动；`scripts/install-panel.sh`、`scripts/install-unlock-node.sh` 零改动；`--unlock-node` 安装路径的 allowlist 校验与 600 配置保持不变。
- **“不做的”清单**：无下载/运行 akdns.sh（全仓库 grep 仅注释与既有文案提及 AKDNS），无硬编码节点列表抄录；stdin→`/dev/tty` 提问机制未动。
- **rig 台架文件**：`scripts/rig/*`、`scripts/test-takeover-rig.sh` 为测试专用（`unshare --mount` + `chroot /var/lib/machines/v016-test` 隔离，stub 仅在 chroot 内 PATH 前置），`rig-inner.sh:106,118` 的 `rm -rf` 均在 chroot 内目标路径，无生产影响。`bindhold`/`bindprobe` 仅为 `go build` 修冲突的探针小 main。

## 4. 8 项符合度表（对照 `audit/V016-PLAN.md`）

| 计划项 | 结论 | 证据 |
|---|---|---|
| 1. 接管加固 | **符合** | nsswitch 补 `dns`（`ensure_nsswitch_dns`，改不上只警告）；resolved 默认只关 stub、验证失败升级 `disable --now`；NM 改 `dns=none` conf.d + reload，保留 `nm-backup.txt` 还原路径；结构化备份 + metadata + 兼容指针；还原列备份/选编号/确认/还原前备份/还原后验证；双份来源由 `sync-restore.sh` + `check-restore-sync.sh` 约束，本次实测通过；use-vc 按 UDP/TCP 探测写；hpve-init 检测到即提示并二次确认；Tailscale 守卫原样保留（含临时模式） |
| 2. 验证不致命 | **符合**（可选子项除外，计划允许不做） | `[4/6]` 缺 dig 不再 `exit 1`（警告 + 继续，dig 在但无结果仍硬失败）；接管后 `verify_system_dns`（getent 优先，缺 getent 回退无 `@server` 的 dig）、`verify_rule_domain` 查规则域名（但见 P2-04）；缺 dig 自动装 dnsutils 未做——计划写明“默认不做也行” |
| 3. 测速选最优 | **偏离** | 节点延迟展示符合（节点表已有 `latency_ms` 列，本次只加了 `typeof` 守卫；规则下拉框带延迟已做）；PreferFastest 后端 + agent 符合，但 **UI 开关缺失（P2-01）**；**安装端并行测速未做（P2-02）**：`probe_panel` 与基底一致，`pick_fastest_ip` 仅删一变量；agent UDP→TCP 已有，只补了测试 |
| 4. 自测按钮 | **部分偏离** | 面板 `POST /api/v1/servers/{id}/selftest`（201/409/404）、config 下发 `selftest_request`、heartbeat 回传 `last_selftest`、服务器行自测按钮 + 就地展开、规则页“自测全部”、连通性免责文案均已做；**installer 接管前后基线对比未接线（P2-03）**，`dnsunlock check` 只存在未被调用 |
| 5. 临时模式 | **偏离** | `--temp`、resolvectl 路径、直接写 resolv.conf、不写永久备份、不加 chattr 锁、README 与无备份还原提示均已做；但 **临时模式留下持久 drop-in + 永久启用的 agent 服务（P2-05）**，“重启后失效”不成立，且与“不停任何管理器”冲突 |
| 补充 1：手动输入 DNS 入口 | **符合** | `resolve_panel_base`（探不到时手动输入，`valid_panel_url` + `validate_ipv4` 校验，无终端直接退出）；接管前操作摘要 + `[y/N]` 默认 N 确认 + `do_backup` 失败中止 |
| 补充 2：NM 按连接 UUID | **符合** | `get_active_nm_connection_uuid`（默认路由接口取 UUID，无路由回退首个活动连接）；接管、备份 metadata、还原 legacy 与 reload 均按 UUID；UUID 不存在时跳过并报错 |
| 补充 3：按后端重载 | **符合** | `reload_dns_service` + `reload_backends` 按备份 metadata 的后端分发，失败只警告 |
| 不做的 | **符合** | stdin→`/dev/tty` 未动；无 akdns.sh 下载/运行，无硬编码节点列表 |

## 5. P1(a)/(b) 修复复核（374e7b7 之前的两提交，代码层）

- **P1(a) `e5dafe6`（还原前先停 agent）**：`restore-resolv.sh` 的 `record_and_stop_agent` 在 `restore_from_dir` / `restore_legacy` 最前执行，停失败或 `:53` 10 秒未空闲即 `exit 1` 且此时只做了还原前备份、未改任何文件；`restore_agent_after` 按监听地址分流：通配符 `:53` 保持停止并明说重跑安装，具名地址重启恢复。逻辑自洽；边缘误中止见 P3-04。
- **P1(b) `ff006ca`（IP_PKTINFO 按查询目标地址回包）**：`agent.go` `newUDPPktinfo` / `dstFromOOB` / `replyOOB` 复核：IPv4 `in_pktinfo`（12 字节：ifindex + spec_dst + addr）与 IPv6 `in6_pktinfo`（20 字节）布局、`CmsgLen`/`CmsgSpace` 切片偏移与 `encoding/binary` 小端编码均正确；`dstFromOOB` 取 `ipi_addr`（目的地址）正确；`WriteMsgUDP` 失败时回退普通 `WriteToUDP`（有回包好过静默）；pktinfo 启用失败时退回旧行为并打日志。未在本机实跑复现（无 systemd 测试机），以代码复核 + rig 绿跑记录（父级交接）为准。
- **未覆盖的交接项**：特定监听地址（`127.0.0.1:53` / `:5353`）的还原后 agent 恢复分支（`restore_agent_after` 的 `*)` 分支）仍无实测记录——代码上与 stub（`127.0.0.53:53`）无冲突，逻辑成立，但未验证。

## 6. 回归结论

- diff 全量 40 文件已逐文件过：`install.sh`、`install-panel.sh`、`install-unlock-node.sh`、`uninstall.sh`、`restore-resolv.sh`、`sync-restore.sh`、`check-restore-sync.sh`、agent（`agent.go`、`check.go`、model、store）、panel（`panel.go`、assets）、SNI proxy（零改动）、rig 台架与测试文件。
- **无 P0、无 P1。** 未发现开放解析器/开放代理、token 或密码泄露、备份丢失、还原破坏系统 DNS 的新路径；P1(a)/(b) 修复代码层正确。
- **6 项 P2 建议修完或明确降级后再发版**：P2-01（PreferFastest UI 开关）、P2-02（安装端并行测速）、P2-03（installer 基线接线）、P2-04（`verify_rule_domain` 取规则逻辑）、P2-05（临时模式持久残留）、P2-06（已提交的 `.pyc` 产物）。其中 P2-01/P2-04/P2-05 是用户可感知的功能缺口或语义违背，P2-02/P2-03 是计划明确写明的实现项，P2-06 是仓库卫生。
- **9 项 P3**（§2）均为边缘场景或健壮性债，可随 P2 一并修或记入后续版本，不单独阻塞。
- 另：`~/MEMORY.md` 在审计中途被外部修改（注入副本与磁盘不一致的 watcher 提示），改动为删除若干 FLMX 旧行；与本审计无关，唯一相关的是它再次确认了 rig S14 与临时模式残留两项已列入审计范围——两者均已覆盖（P2-04/P2-05）。
