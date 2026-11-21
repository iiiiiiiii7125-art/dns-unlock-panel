# v0.1.6 全量审计 — C 线：3 个 P3 裁决 + 节点一键安装命令评审

- 审计员：C 线（只读审计；未改代码、未 push/tag/发版、未碰生产面板 https://dns.0v0.baby）
- Worktree：`~/workspace/dns-unlock-panel-v016`，分支 `feature/v0.1.6-takeover`，tip `374e7b7d8e5c868721b98d563cd37732f35e72f4`（审计结束时 `git status` 干净，HEAD 仍为 374e7b7）
- 方法：代码精读 + 本地实测复现。实测用沙箱内临时面板（`127.0.0.1:18080`，临时数据文件 `/tmp/v016-audit/lane-c/paneldata/panel.json`，与生产无关），二进制为 worktree 现场构建（`go1.25.1`，`/tmp/v016-audit/lane-c/bin/dnsunlock`）。实测结束后测试进程（面板/agent/TLS 黑洞）已全部停止，测试端口已释放；同机其他 rig 进程（`127.0.0.1:18180` 面板、`/root/rig/bin/dnsunlock`）未动。
- 结论总览：**3 个 P3 全部属实，均裁决为修（P3）。节点一键安装命令实现基本正确，无 P0/P1；但零服务器路径实际跑不通（P3，C-04a），另有 2 个 P3 文案/静默失败问题（C-04b、c）。本线无 P0/P1。**

---

## C-01 — bbciplayer（GB 区无节点）在 `dnsunlock check` 里静默漏掉

- **Severity：P3。裁决：修。**
- **用户影响：** 用户在面板里明明设了规则（种子规则含 `bbciplayer→GB`），`dnsunlock check` 却印 `NO_RULES`、exit 0——和“一条规则都没设”完全无法区分。installer 的接管前后基线对比会把“规则存在但无解锁 IP”误读成“无规则可测”，甚至误报“全部 OK”。DNS 本身的行为（无可用 IP 时域名走上游真实 IP）是设计如此且安全的，损害只在诊断口径上，所以定 P3 而非 P1。

### 根因核实：属实——面板下发 agent 配置时直接丢掉了无法解析的规则

`internal/panel/panel.go:1447-1449`（`handleAgentConfig`）：

```go
if !ok || !validIP(ip) {
    continue // no usable IP for that rule: leave platform on upstream
}
```

`resolveIP`（`internal/panel/panel.go:305-353`）在 GB 区无启用节点、无 `CustomIP`、无默认解锁 IP 时返回 `("", "", false)`；`handleAgentConfig` 随即在 `continue` 处把整条规则丢出 `cfg.Rules`，且不留任何标记。`dnsunlock check` 只遍历 `cfg.Rules`（`internal/dnsagent/check.go:206`），所以这条规则永远到不了 check。

### “每条规则一行、未解析出 IP 时该字段印 `-`”的约定只覆盖了一半情况

`internal/dnsagent/check.go:9-14` 约定“一行一条规则……未解析出 IP 印 `-`”，`CheckResult.Line()`（`check.go:37-53`）也确实在 `ResolvedIP == ""` 时印 `-`。但这个 `-` 只在**规则已下发、解析失败**时出现；**规则被面板丢掉时连行都没有**。两者在输出上完全不可区分。

### 实测复现（临时面板，种子规则 16 条，0 个节点，无默认解锁 IP）

```
$ curl -s -H "Authorization: Bearer <admin>" http://127.0.0.1:18080/api/v1/rules | …
BBCI RULE: {"has_rule": true, "platform": {"id": "bbciplayer", ... "domains": ["bbci.co.uk", "bbc.co.uk"], "tier": 2}, "rule": {"platform_id": "bbciplayer", "region": "GB"}}

$ curl -s "http://127.0.0.1:18080/api/v1/agent/config?server_id=srv-1795260082201253195" -H "X-Agent-Token: <token>"
agent config rules count: 0
platform_ids: []
bbciplayer present: False
# 原始响应：{"version": 1, "upstream": "1.1.1.1", "rules": null}
# 16 条种子规则全部消失，不只是 bbciplayer。

$ /tmp/v016-audit/lane-c/bin/dnsunlock check --config check-config.json --via upstream
NO_RULES        # stdout；exit=0
```

对照实验——只加一个 GB 节点（`203.0.113.20`），规则立即出现：

```
rules count: 1
platform_ids: ['bbciplayer']
bbciplayer: [{'platform_id': 'bbciplayer', 'tier': 2, 'domains': ['bbci.co.uk', 'bbc.co.uk'], 'node_id': 'node-1795260094443008309', 'node_ip': '203.0.113.20', 'region': 'GB', ...}]
```

`-` 约定本身有效的对照——规则已下发但 agent 未启动时：

```
$ dnsunlock check --config check-config.json --via agent
bbciplayer	bbci.co.uk	-	FAIL	no reply from DNS 127.0.0.1:15353     # exit=1
```

### 用户能不能分清“规则未设”和“规则设了但解析不出来”？

**不能。** 两个状态在 `check` 输出上逐字节相同（`NO_RULES` / exit 0）。面板规则页能看到 `has_rule: true`，但那是另一个界面；`check` 是 installer 基线对比的唯一口径，两个口径互相矛盾。修复方向（二选一即可）：面板在 `cfg.Rules` 里保留无法解析的规则并打显式标记（如 `node_ip: ""` + 原因），由 check 印 `FAIL` 行；或 check 直接读面板规则（而非仅 agent 配置）并对被丢掉的规则补 `FAIL` 行。修到“设了但无 IP”时 check 至少出一行、exit 非 0 为止。

---

## C-02 — 自测结果可能晚于界面 90 秒轮询窗口

- **Severity：P3。裁决：修。**
- **用户影响：** 节点全挂（正是用户最需要自测结果的时候）时，自测耗时可超 90 秒；界面随后显示“自测失败”，而实际上测试已完成、结果已躺在 `last_selftest` 里。更糟的是：结果到了之后界面**仍然不显示**（见下“刷新可见”核实），用户只能重跑一次再等 90 秒以上，或误以为节点/自测功能坏了。

### 数字核实：任务陈述的分解有两处不准确，但“会超时”的结论成立

逐项核对代码常量（`internal/dnsagent/agent.go`、`web/index.html`）：

| 任务陈述 | 核实结果 |
|---|---|
| agent 约 30 秒轮询 | **不属实。** 配置轮询是 5 秒：`agent.go:633` `time.NewTicker(5 * time.Second)`（`pollLoop`，自测请求经 `/api/v1/agent/config` 下发）。30 秒是**心跳/健康检查**间隔：`agent.go:664` `healthLoop` 每 30 秒 `checkHealth()` 后才 `sendHeartbeat()`。30 秒应算在“等下次心跳”里，不应再单独算一次轮询。 |
| 14 条 × 约 3 秒探活超时 | **低估。** `probeIP`（`agent.go:681-700`）：dial 超时 3 秒，dial 成功后 TLS 握手另有 `SetDeadline(now+5s)`——单条最坏约 3+5=8 秒；接受连接但不握手的节点（黑洞）每条固定吃满 **5 秒**握手时限，不是 3 秒。 |
| 界面每 3 秒轮询、最多 90 秒 | **属实。** `web/index.html:707-713`：`for(let i=0;i<30;i++){ await sleep(3000); … }`，超时后置 `state='error'`，文案“90 秒内未收到结果……”。 |
| “实测 POST 后 103 秒才进 last_selftest” | **仓库内无记录可独立复核**（全仓 grep `103` 无相关记录）。但按修正后的上界 `5（取请求）+ 14×5（握手挂起）+ 30（等心跳相位）= 105 秒`（另有同 tick 内 `checkHealth` 的串行探活会再拖），103 秒落在合理区间内，可信。 |

### 实测：14 条全挂规则，POST → `last_selftest` 实测 84.1 秒（心跳相位幸运时）

环境：临时面板 + 本地 agent（`127.0.0.1:15353`）+ 14 条 GB 规则全部指向 `127.0.0.1`，`127.0.0.1:443` 上挂只接受、不握手的 TLS 黑洞（每条探活吃满 5 秒握手时限）。

```
POST selftest -> request_id=st-1795260281570595333 at t=0.00s
t=84.1s: last_selftest ARRIVED request_id=st-1795260281570595333 results=14 ok=0 ran_at=2026-11-21T11:24:44Z
```

分解（UTC 时钟对齐）：POST ≈ 11:24:41 → `ran_at` 11:24:44（取请求约 3 秒，符合 5 秒轮询）→ 运行恰好 70.0 秒（`14 × 5.0 秒`，与 agent 日志 `[agent] selftest … done: 14 platforms` 11:25:54 一致）→ 等心跳约 1 秒。**本次 84.1 秒只因心跳相位幸运；相位不幸时再加近 30 秒，约 113 秒，必超 90 秒窗口。** 结论：90 秒窗口在节点全挂场景下结构性不足，不是偶发抖动。

### “结果仍保留在 last_selftest 里，刷新可见”——只对整页重载成立，页内刷新不可见

- 后端属实：面板收到心跳后持久保存最新结果，`internal/panel/panel.go:1513-1514`（`if hb.SelftestResult != nil { d.Servers[i].LastSelftest = hb.SelftestResult }`）。
- 前端**不属实**（页内刷新）：`web/index.html:679-684` `selftestDetailRow` 的分支顺序是 `pending → error → last_selftest`；一旦超时置为 `state='error'`，此后任何一次 `renderServers()`（含 15 秒 `pollStatus`/`refreshData` 触发的重绘）都只显示错误行，迟到的 `last_selftest` 被 `error` 分支永久遮住。`SELFTEST` 是内存对象，页内刷新不清除。
- 用生产文件的原函数实测证明（node 24，函数逐字提取，仅补 `PLATFORMS`/`esc` 桩）：

```
ERROR-state row: <tr><td colspan="8" style="color:#991b1b">自测失败：90 秒内未收到结果（agent 可能未取到请求或测试耗时较长），可稍后查看本行下方结果。</td></tr>
FRESH-PAGE row (no SELFTEST entry): <tr><td colspan="8"><div class="muted">自测结果（2026-11-21T11:25:54Z，请求 st-1）— 只验证能否连通，…
```

即：**只有 F5 整页重载（`SELFTEST` 被重置）才能看到迟到的结果；** 而错误文案说的是“可稍后查看本行下方结果”，用户按字面意思等在原地永远看不到。修复方向：超时后继续后台等结果、结果到达时清除 `error` 状态并自动展开；或把窗口放宽到 ≥150 秒；或 agent 侧并行探活（14 条串行是耗时主因）。三者任选其一，修到“超时文案不再对已完成测试说失败、迟到结果能自动出现”为止。

---

## C-03 — `dnsunlock check` 印无关的 allowlist 警告

- **Severity：P3。裁决：修。**
- **用户影响：** 用户跑基线自测时会看到一条吓人的警告（“this resolver answers anyone……will be abused for DNS amplification”），以为自己的 DNS 正在裸奔。实际上 `check` 从不监听任何端口、从不回答任何查询，警告内容在 check 语境下是假的；更糟的是它会训练用户忽略这条真正的 P0-04 警告（在 `dns-agent` 模式下这条警告是真实有效的安全提醒）。

### 核实：属实，且比任务陈述更严重——配了 allowlist 也照样警告

根因：`cmd/dnsunlock/main.go:272-274`（`runCheck`）构造 agent 时根本不传 allowlist：

```go
a := dnsagent.New(dnsagent.Config{
    Listen: listen, PanelURL: panelURL, Token: token, ServerID: fc.ServerID,
})
```

`dnsagent.New`（`internal/dnsagent/agent.go:192-194`）在 allowlist 为空时无条件向 stderr 打印警告：

```go
a.allowlistErr = ValidateAllowlist(cfg.Allowlist)
if len(a.allowNets) == 0 && len(a.allowIPs) == 0 {
    // Stderr, not stdout: stdout is machine-readable output for
    // `dnsunlock check` (and nothing here is a query answer).
    fmt.Fprintln(os.Stderr, "[agent] WARNING: no DNS allowlist set — this resolver answers anyone. ...")
}
```

### 实测（stdout/stderr 分离捕获）

```
$ dnsunlock check --config check-config.json --via upstream
--- stdout:
NO_RULES
--- stderr:
[agent] WARNING: no DNS allowlist set — this resolver answers anyone. On a public VPS set the allowlist in the 0600 config file (e.g. your client IPs / 192.168.1.0/24) or firewall port 53, or it will be abused for DNS amplification.
exit=0
```

对照实验——配置文件里**已配** `"allowlist":"127.0.0.1"`，警告**依然原样出现**（因为 `runCheck` 从不读 `fc.Allowlist`）：

```
$ dnsunlock check --config check-config-allow.json --via agent
--- stdout:
bbciplayer	bbci.co.uk	-	FAIL	no reply from DNS 127.0.0.1:15353
--- stderr:
[agent] WARNING: no DNS allowlist set — this resolver answers anyone. ...
exit=1
```

值得肯定的一点：警告只走 stderr，stdout 的机器可读契约未被破坏（`NO_RULES` / 结果行干净，exit 码正确）。修复方向：`runCheck` 把配置文件里的 allowlist 传进 `New()`（治标——配了就不警告），或 check 专用构造路径直接抑制该警告（治本——check 根本不监听，警告语义上就不适用）。修到“check 的 stderr 里不再出现与本次运行无关的警告”为止。

---

## C-04 — 节点一键安装命令评审（commit 374e7b7）

评审对象：`web/index.html` 与 `internal/panel/assets/index.html` 的 374e7b7 改动（节点页每行“复制安装命令”，allowlist 自动取已登记 DNS 服务器公网 IP）。

### 通过项（有证据）

- **两份 `index.html` 字节一致：** `cmp web/index.html internal/panel/assets/index.html` → `IDENTICAL`（均为 59464 字节；`git show 374e7b7` 两文件 diff 内容逐行相同）。另：`scripts/install.sh` 与 `internal/panel/assets/install.sh` 也字节一致。
- **命令生成逻辑——多台拼接正确：** `web/index.html:757-767` `copyNodeInstall()` 逐台调 `reveal` 取完整 IP、去重、`ips.join(',')`、整体包进 `sq()`。服务器 IP 在登记时已由后端校验（`internal/panel/panel.go:1092-1094`：`sv.IP != "" && !validIP(sv.IP)` 则 400），空 IP 被 `if(j.ip&&…)` 跳过。
- **引用/转义正确：** `web/index.html:738` `function sq(v){return "'"+String(v).replace(/'/g,"'\\''")+"'"}`——标准单引号转义，单引号外无注入点；IP 逗号串整体包在单引号内。`serverInstallCmd`（`:739-744`）对 token/name/allowlist 同样用 `sq()`，本改动沿用同一做法。
- **`--panel` 地址正确：** 生成的命令里**没有** `--panel` 参数；面板地址来自两处同一来源——curl URL 用 `location.origin`，脚本内 `PANEL_URL` 由面板下发时按请求 Host 烘焙（`internal/panel/panel.go:572-584` `handleInstallScript`，`__PANEL_URL__` → `scheme://Host`）。实测：面板在 `http://127.0.0.1:18080` 时下发的脚本首行即 `PANEL_URL="http://127.0.0.1:18080"`，与 origin 一致。唯一边界：管理员若用 `http://127.0.0.1:8080` 打开面板再复制命令，烘焙的是本机回环地址，到目标 VPS 上不可用（此时安装脚本会走 v0.1.6 的手动输入面板地址入口兜底；同款问题在已有的 `copyServerInstall` 上一样存在，非本次引入）。
- **无未登录接口泄露私有 IP：** 命令只在登录后界面内生成。IP 来源是逐台 `GET /api/v1/servers/{id}/reveal`，该路由挂在 `s.auth(...)` 下（`internal/panel/panel.go:385`）；列表接口本身打码（实测 `203.0.*.*`）。`/install.sh` 是公开接口，但只烘焙面板 URL、不含任何 IP（`handleInstallScript` 注释 + 代码）；`/dl/` 需 admin 会话或 agent token。命令里只含管理员自己的 DNS 服务器公网 IP、且**不含任何 secret**（无 token，比 `copyServerInstall` 更干净）；IP 进入的是管理员自己要装节点的 VPS 的 shell 历史，与面板已有行为一致，不构成新增泄露面。
- **空 allowlist 不会导致 SNI 拒绝启动：** 任务所问的这一点答案是否定的——`scripts/install.sh:717-720`（`--unlock-node` 分支）先 `ask SNI_ALLOW` 交互问，仍为空才 `exit 1` 并明说“不填 allowlist 就不启动，避免变成公开代理”；SNI 代理本身绝不会以空 allowlist 启动（运行时 `failClosedAllowlist` 同样拦截）。空 allowlist 的处理是 fail-closed 的，正确。

### C-04a — 零台服务器时，生成的命令根本跑不通（P3，修）

- **Severity：P3。裁决：修（修文案 + 修流程，二者至少做文案）。**
- 代码注释称“一台都没登记就不带这个变量，安装脚本到机器上交互问”（`web/index.html:753-756`），UI 提示也说“安装时按提示输入”。但这条命令在到达 allowlist 提问之前就已失败：**安装脚本在任何模式下都先强制要求 agent token**，而零台服务器时根本不存在任何有效的 agent token。
  - `scripts/install.sh:654-660`：`TOKEN` 为空 → `ask TOKEN … silent`，无 TTY 直接 `no_input` 退出；有 TTY 则停下问 token。
  - `scripts/install.sh:686-689`：`curl … /api/v1/agent/whoami` 校验 token，失败即 `exit 1`（“面板连不上或 agent token 不对”）。
  - 上述两步都在 `--unlock-node` 分支（`:715` 起）之前；SNI 自身并不需要 token，token 只是 `/dl/` 下载二进制的凭证（`internal/panel/panel.go:594-596`）。
- 实测（下发的真实脚本，`PANEL_URL=http://127.0.0.1:18080` 已烘焙）：
  - 无 TTY、无 token：`=== dnsunlock 安装 === / 面板: http://127.0.0.1:18080 / 错误：无法读取输入（stdin 已关闭且无可用终端）。请用面板生成的安装命令（自带 DNS_AGENT_TOKEN），或先把脚本下载下来再执行。`——脚本自己的恢复提示指向的“自带 token 的安装命令”，恰恰是节点命令没有提供的东西。
  - 假 token：`[0/6] 装前检查…… / curl: (22) The requested URL returned error: 401 / 面板连不上或 agent token 不对：请检查面板地址和 token（token 是每台服务器单独的那串，不是 admin 密码）。`
- 用户影响：按“先装 SNI 节点、再登记 DNS 服务器”的自然顺序首次使用时，命令必失败，且报错（token 不对）与真正原因（还没有任何服务器/token）无关，用户无从自行纠正。修复方向：UI 在零服务器时不生成“可直接粘贴”的命令，改为明确提示“先登记一台 DNS 服务器（拿到 token 后再装节点）”；或安装脚本在 `--unlock-node` 模式下跳过 token/whoami（`/dl/` 需另给匿名下载口径——涉及 P0-06，需另行决策，不建议顺手改）。

### C-04b — “一键”名不副实：有服务器时命令仍会在 token 处停下问（P3，修文案）

- **Severity：P3。裁决：修（文案）。**
- 同 C-04a 的 token 门：节点命令不带 `DNS_AGENT_TOKEN`（SNI 节点没有自己的 token 可带），所以即使 allowlist 已填好，粘贴后仍需在目标机上交互输入**任意一台已登记服务器的 agent token**（有 TTY 时）；无 TTY（如非交互 ssh/自动化）则直接退出。按钮提示“到节点机器粘贴执行即可”与复制成功提示“安装命令已复制，到节点机器粘贴执行即可”均未提 token 这一步。与之对比，`copyServerInstall` 的命令自带 token，是真一键。修复方向：提示文案补一句“执行时会问 agent token，填任意一台已登记 DNS 服务器的 token”；`install.sh` 的 token 提问处也可注明“节点模式仅用作下载凭证”。

### C-04c — 两个静默类小问题（P3，修）

- **Severity：P3。裁决：修。**
- **（1）reveal 失败被静默吞掉，提示文案随之说错话。** `web/index.html:757-767`：`try{…reveal…}catch(e){}`——某台 reveal 失败时该 IP 无声跳过；若全部失败，`ips` 为空，提示却说“未登记 DNS 服务器”，而实际上服务器是登记了的，只是取 IP 失败。用户会粘贴一条自以为填好 allowlist、实际为空的命令。修到“reveal 失败时提示取 IP 失败、而非谎称未登记”为止。
- **（2）每行按钮生成的命令完全相同。** `web/index.html:646` 每行都渲染 `<button onclick="copyNodeInstall()">`，而 `copyNodeInstall()` 不取任何节点参数；N 行 N 个按钮全是同一条命令。按提交信息“节点页每行加复制安装命令”这是有意的落点，但用户极易误以为命令与该行节点绑定。修到“按钮文案或位置不再暗示与行绑定”（如只放一个按钮，或文案改为“复制节点安装命令（通用）”）为止。
- 另有一行备注（不单独定级）：allowlist 取的是登记的 `ip` 字段原文；若管理员登记的是内网/NAT 地址，SNI 会按该地址放行、真实出口 IP 反而被拒。建议在节点页提示“allowlist 用登记的 IP，请确认是 DNS 服务器的公网出口 IP”。

---

## 未发现项

- 本线范围内（3 个 P3 + 374e7b7 节点命令）**未发现 P0/P1**。按任务规则，无红证的 P0/P1 不算数——本线没有要报的 P0/P1，故无红证项。上述 P3 的每一条均有代码位置 + 实测输出为证（见各节）。
- 374e7b7 之外未顺手扩大审计范围；生产面板未碰；worktree 未改动。

## 附：实测环境清理

- 临时面板（`127.0.0.1:18080`）、本地 agent（`127.0.0.1:15353`）、TLS 黑洞（`127.0.0.1:443`）均已停止，端口已释放；同机其他 rig 进程未动。复现数据仅在 `/tmp/v016-audit/lane-c/`（临时面板数据、check 输出、agent 日志、时序脚本 `selftest-timing.py`、UI 分支验证 `detailrow.js`）。
