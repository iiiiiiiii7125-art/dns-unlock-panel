# DNS 分流解锁面板 — 第三轮审计报告（独立复核）

- 审计对象：`~/workspace/dns-unlock-panel/`（N-01…N-12 修复后状态，2026-11-20 用户 16:10 CST 选“修 N-01 到 N-12，再审一次”后复核）
- 对照材料：第二轮 `audit/AUDIT-REPORT-2.md`（结论还不能推；新发现 P0 2 / P1 3 / P2 4 / P3 3，共 N-01…N-12）；第二轮修复 `audit/FIX-REPORT-2.md`（声称 N-01…N-12 全部修完，面板接口 32/32、DNS+SNI 23/23）；第一轮 `audit/AUDIT-REPORT.md` 与 `audit/FIX-REPORT.md`；待审清单 `AUDIT-PENDING.md`
- 审计方式：只审计、不改代码、不 push、不打 tag、不发 Release。逐条读代码核对修复是否真实落地（文件+行号/关键片段见下表），并重跑动态验证：`go vet`、`go test`、重建 amd64+arm64 并 `sha256sum -c`（含分架构 sha256）、`bash -n` 全部脚本、面板接口、DNS TCP 路径、SNI 双监听。**没有下载、没有运行任何第三方安装脚本**（包括 AKDNS 的），只用其公开文档对照。
- **结论先说：可以推仓库。** N-01…N-12 全部 12 条经代码核对与动态验证确认已修（12/12），未发现新的 P0/P1。本轮新发现 5 条，全部是 P3（种子规则自带冲突、安装时 token 短暂进 curl 命令行、`--allowlist` 旗标仍在、卸载无条件删 `/etc/cloudflared`、双层反代下登录锁按出口 IP 计），都不拦推仓库，见“新发现问题”。但**推仓库 ≠ 全链路已验证**：UDP DNS、安装脚本真机全流程、Caddy 真实反代与自动 HTTPS、真实流媒体解锁、failover 实况这 5 项在沙箱里无法验证，必须在推仓库、发 Release 后在真实 VPS 上补验，补验通过前不要对外宣称“全链路已验证”（见“仍未验证清单”与“推仓库后必须做的事”）。

## 汇总

| | 数量 |
|---|---|
| 第二轮 N-01…N-12 中：已修 | 12（P0 2、P1 3、P2 4、P3 3） |
| 第二轮 N-01…N-12 中：部分修 / 未修 | 0 |
| 本轮新发现问题 | P0 0 / P1 0 / P2 0 / P3 5，共 5 条（M-01…M-05） |
| 第一轮 38 条中第二轮未修完的残留 | 本轮复核：P1-07、P1-09、P1-11、P1-15、P3-01 的残留已补（见下）；P0-05“agent 配置含全部全局规则”是设计使然（agent 必须知道 IP 才能答 DNS），接受现状；EDNS 仍不解析（两轮已承认）；P3-02 平台库双份源仍在，两份内容 diff 一致 |

## 动态验证结果（本轮实测，沙箱本地）

- `go vet ./...` 通过；`go test ./...` 通过（含新增 `internal/panel/panel_test.go:TestClientIP` 7 用例与既有 sniproxy 测试；dnsagent/model/store 无测试文件）。Go 1.25.1 工具链，`go.mod` 为 go 1.24.0。
- `bash scripts/build.sh` 重建：amd64 `c3650971713f9d0352d9b5f1b11ed983d818b27fc3de4d043cf011cd69d5cafb`、arm64 `5d93fe6f1a82f593aa4028ffc7c6f9c1e4f5d71dd5e917425b7526fa0ed668ab`，与 FIX-REPORT-2 声称的哈希**完全一致**，`sha256sum -c` 分架构与合集文件全部通过；两个包均为静态链接 ELF，架构正确。`bash -n`：7 个脚本全部通过。
- 面板接口（127.0.0.1:18091，`/tmp/dns-audit3/panel_test.py`）：**36/37 通过**，唯一 1 项失败是测试脚手架的期望写错（见下），产品行为本身是对的：
  - 登录 admin/admin 成功，`must_change=true`；must_change 的 session 调 `/api/v1/status`、`/api/v1/nodes` → 403；退出 → 200；改密 → 200，旧 session → 401、旧密码 → 401、新密码登录 `must_change=false` 且接口 200。
  - 登录锁：同一 IP 连续 5 次错密码后第 6 次 → 429；只伪造 XFF 第一个值（`1.1.1.1, 127.0.0.1`，最后一个仍是被锁 IP）→ 仍 429。
  - 节点创建 IP 打码（`203.0.*.*`）、非法 IP → 400、只改名不传 enabled → 仍启用；服务器登记一次性返回 token、列表里 token 值不可见、reveal 返回完整 token。
  - `?agent_token=` 调 config / whoami / `/dl/` 二进制 → 401；`X-Agent-Token` 头调同样接口 → 200；`/dl/` 二进制无鉴权 → 401；`/dl/dnsunlock-linux-amd64.sha256` 与 arm64 版无鉴权 → 200。
  - 伪造心跳（query 的 server_id 不对 → 401；body 的 server_id 不对 → 403）；含 `<img onerror>` / `<script>` 的事件可存入（JSON 编码），前端事件表已走 `esc()`（代码核对，`web/index.html:281` 与 assets 版一致）。
  - 域名冲突 → 409，提示为“现有规则指向 节点 US-1（US），新规则指向 节点 HK-1-renamed（HK）”，`203.0.*.*` 出现 0 次。
  - 唯一失败项：测试先设 `youtube-premium → HK` 却拿到 409——原因是面板种子默认规则本身就含 `youtube → US` 与 `youtube-premium → HK` 两条共用 `youtube.com` 的规则（见新问题 M-01），产品按冲突规则正确拒绝，不是修复失效。
  - `panel.json` 故意写坏后重启：面板从 `.bak` 恢复，新密码登录成功（0600 权限，实测）。
- DNS TCP 路径（agent 127.0.0.1:15353，`/tmp/dns-audit3/dns_test.py` + 补测 `/tmp/dns-audit3/rulechange.py`）：**19/19 实质通过**（原始脚本 17/19，2 项失败均为测试脚手架问题，补测已证实产品行为正确）：
  - `netflix.com A` 按面板规则返回解锁 IP；AAAA/TXT → NODATA（AN=0）；RD=0 的请求回 RD=0、RD=1 回 RD=1；QDCOUNT=0 → FORMERR（rcode 1）。
  - N-03 缓存 ID：`example.com` 第一查 qid 0xAAAA → resp 0xAAAA，第二查 qid 0xBBBB → resp 0xBBBB（第二轮是 0xAAAA），两次拿到同一上游真实 IP。
  - 规则即时生效（补测）：netflix 规则 HK → 7 秒内查到 `203.0.113.10`；改 US → 7 秒内查到 `203.0.113.20`。
  - nameserver 模式端到端：netflix 规则指向上游 1.1.1.1 后，查询返回真实 IP（不是解锁 IP）。
  - 无效 allowlist：agent `-allowlist "not-an-ip"` 与 `192.168.1.0/33` 均拒绝启动（rc=1）；SNI 配置里非法 allowlist 同样 rc=1。
  - SNI：TLS 只听 127.0.0.1 + HTTP `:18080` 空 allowlist → 拒绝启动；TLS `:18443` 空 allowlist → 拒绝启动；HTTP 配 allowlist=10.255.255.1 时，127.0.0.1 发 `Host: example.com` 请求连接被 RST、0 字节中继（原始脚本把 RST 当异常计为失败，实质是拦截成功）；SNI `--config`（allowlist 127.0.0.1）正常启动。
  - `dns-agent --token x` 与 `sni-proxy --token x` → rc=2（未知旗标，旗标已删）。
- 安装下载流程模拟（N-02）：用 agent token 头从面板 `/dl/` 下载二进制 + 分架构 sha256，`sha256sum -c` 通过（OK）。
- Shell 函数抽测：`valid_ip_cidr` 12/12（`999.999.1.1`、`a.b.c.d`、`1.2.3`、`/33`、IPv6 `/129` 均拒绝；`2001:db8::1`、`2001:db8::/64`、`::1`、`192.168.1.0/24` 均通过）；`port_in_use` 2/2（19876 占用检出、19877 空闲通过）。

## 逐条复核表（N-01…N-12）

| 编号 | 结论 | 证据 / 说明 |
|---|---|---|
| N-01 (P0) install-panel.sh 收尾必 401 | **已修** | `scripts/install-panel.sh` 收尾改为 `systemctl is-active --quiet dnsunlock-panel` + `curl -fsS http://127.0.0.1:$PORT/ \| grep -q "登录面板"`；`/api/v1/status` 不再出现在收尾。首页实测 200 且含“登录面板”（面板测试第 1 项）。`systemctl is-active` 本身沙箱无 systemd 未实跑，见“仍未验证”。 |
| N-02 (P0) 分架构 sha256 不存在 | **已修** | 新增 `scripts/build.sh`：构建双架构的同时生成 `dnsunlock-linux-amd64.sha256` / `dnsunlock-linux-arm64.sha256`（各只含本架构一行）+ 合集；`dist/` 现有 5 个文件；`/dl/*.sha256` 实测 200；模拟安装下载后 `sha256sum -c` 通过；本轮重建哈希与 FIX-REPORT-2 声称完全一致。README:154 写明 5 文件资产清单。注意：`.gitignore` 含 `dist/`，push 不会带二进制，Release 资产必须从本地 `dist/` 另行上传（见“推仓库前必须做的事”）。 |
| N-03 (P1) 缓存返回错误交易 ID | **已修** | `internal/dnsagent/agent.go:forwardWithCache`：缓存命中时先复制回应，再把前两字节改写成当前查询的 ID，缓存里的原字节不动（`resp := append([]byte(nil), e.resp...)`）。动态验证：0xAAAA/0xBBBB 各对。 |
| N-04 (P1) 无效 allowlist 静默变公开解析器 | **已修** | 三层都在：① `dnsagent.ValidateAllowlist` / `sniproxy.ValidateAllowlist`（逐项真校验）；② `cmd/dnsunlock/main.go:runAgent/runProxy` 启动前校验，非法即 `log.Fatalf`；③ `New` 里记 `allowlistErr`，`Run()` 拒启、`allowed()` 全拒。动态验证：agent 两处非法 allowlist 均 rc=1；SNI 配置非法 allowlist rc=1。`install.sh:valid_ip_cidr` 重写为真校验（IPv4 逐段 0–255/前缀 0–32；IPv6 用 python3 ipaddress，无 python3 时拒绝），抽测 12/12。 |
| N-05 (P1) SNI 明文 HTTP 绕过 fail-closed | **已修** | ① 明文 HTTP 默认禁用（`main.go:runProxy` 的 `httpDef` 默认为空，只有环境变量/旗标/配置文件显式指定才开）；② `main.go` 对 HTTP 监听做与 TLS 同样的 fail-closed 检查；③ `sniproxy.Proxy.Run()` 内再检查一次（双监听任一非 loopback + 空 allowlist 即拒启）。动态验证：两处拒启均 rc=1；配 allowlist 不含本机时 HTTP 请求被 RST、0 字节中继。 |
| N-06 (P2) 首次改密服务端不强制 | **已修** | `internal/panel/panel.go:auth`：`AdminMustChange` 为真时，除 `/api/v1/change-password` 与 `/api/v1/logout` 外一律 403（`must_change_password`）；前端登录后 `must_change` 时只显示改密码卡片、不调用 init。动态验证：must_change session 调 status/nodes → 403、改密 → 200、退出 → 200。 |
| N-07 (P2) 登录锁可被伪造 XFF 绕过 | **已修** | `internal/panel/panel.go:clientIP`：只在直连方是 loopback（127.0.0.1/::1，即本机 Caddy）时才信任 XFF，且取**最后一个**值（反代把真实 IP 追加在末尾，第一个值仍是攻击者可控的）；直连方非 loopback 时完全忽略 XFF。动态验证：锁后只伪造第一个值仍 429；`TestClientIP` 7 用例通过（含“直连 + 伪造 XFF → 取远端 IP”、“127.0.0.2 不算可信反代”）。残留见 M-05（双层反代下锁按出口 IP 计，非安全漏洞）。 |
| N-08 (P2) agent token 可走 URL 查询串 | **已修** | 三处 `r.URL.Query().Get("agent_token")` 回退全部删除（`handleAgentWhoami`、`agentAuth`、`handleDownload`），只认 `X-Agent-Token` 头；全仓 grep `Query().Get("agent_token")` 0 处。动态验证：config / whoami / `/dl/` 二进制用 `?agent_token=` → 401，用头 → 200。 |
| N-09 (P2) 卸载删用户原有防火墙规则 | **已修** | `scripts/uninstall.sh`：删掉 ufw/firewall-cmd 的 53 规则删除（只剩说明性注释）；增加 cloudflared 清理（`cloudflared service uninstall` + 停服务 + 删 unit）。grep 验证：卸载脚本里已无任何可执行的防火墙删除命令。残留见 M-04（`rm -rf /etc/cloudflared` 无条件执行）。 |
| N-10 (P3) 冲突提示打码后无法区分 | **已修** | `panel.go:describeRuleTarget`：有 NodeID 报节点名+地区；region 规则先经 `resolveIP` 解析到实际节点再报节点名；自定义 IP 只露末段（`*.*.*.99`）；nameserver 报上游末段。动态验证：409 提示含“节点 HK-1-renamed（HK）”与“节点 US-1（US）”，`203.0.*.*` 出现 0 次。 |
| N-11 (P3) 事件表未转义 | **已修** | `web/index.html` 与 `internal/panel/assets/index.html`（diff 一致）的事件表六列全部走 `esc()`（`index.html:281`）；动态验证：含 `<img onerror>` / `<script>` 的事件可存入，渲染处已转义。`loadChecks` 的 `c.method/c.expect` 未转义，但那是服务端写死的常量（`panel.go:unlockChecks`），不是用户/agent 可控输入，不算同类问题。 |
| N-12 (P3) 凭证上命令行 / SNI 配置无人读 | **已修** | ① `dns-agent` 删掉 `--token` 旗标（token 只走 600 配置文件或 `DNS_AGENT_TOKEN` 环境变量）；② `sni-proxy` 增加 `--config`（0600 配置文件，含 allowlist；`http_listen` 键存在时才覆盖，空值 = 禁用）；③ `install.sh` 的 SNI 分支改成 `--config` 启动，`ExecStart` 不再带 `--allowlist`，`http_listen` 写 `""`；④ `install.sh` 删掉 `--token` 参数（只留交互输入）。动态验证：`--token` 旗标已删（rc=2）；SNI `--config` 启动正常；全仓 grep `sni-proxy --allowlist` 0 处。残留见 M-02、M-03（安装时 curl 传 token、CLI 仍有 `--allowlist` 旗标）。 |

## 第二轮“部分修”残留复核（FIX-REPORT-2 声称顺带补的 7 处）

| 残留 | 结论 | 证据 |
|---|---|---|
| P0-01 域名/端口未校验；ss 缺失时端口预检静默跳过 | **已补** | `install-panel.sh`：域名正则 + 端口 1–65535 校验；`port_in_use()`：有 ss 用 ss，无 ss 用 bash `/dev/tcp` 探 127.0.0.1。抽测 2/2。 |
| P1-01 回应固定 RD=1；QDCOUNT≠1 静默无回应 | **已补** | `agent.go:buildResponse/buildErrorResponse` 基数由 0x8180 改为 0x8080（QR+RA），RD 只从请求取；新增 `buildFormErr`（QDCOUNT≠1 / 截断 / 压缩问句回 FORMERR）。动态验证：RD=0→0、RD=1→1、QDCOUNT=0→FORMERR。 |
| P1-07 默认解锁 IP 语义注释写反、README/DESIGN 没写 | **已补** | `model.go` 注释修正；README 新增“默认解锁 IP 的语义”一节、DESIGN 同步：只在规则存在但该地区无可用节点时作备用，无规则平台不用它。 |
| P1-09 软链还原丢内容；NM 还原空值静默失败；netplan 只改第一处 | **已补（代码核对，未真机验证）** | 内嵌还原脚本与 `restore-resolv.sh` 内容一致（除文件头注释）；软链还原后目标不存在时把备份内容写回目标；NM 还原失败报错（不再 `|| true`）；netplan 正则去掉 `count=1`（全改）。 |
| P1-11 没 dig 时跳过验证仍打印“安装完成” | **已补** | `install.sh:229-232`：没装 dig 直接报错退出。 |
| P1-15 Caddy import 残留行 | **已补（演练层面）** | `uninstall.sh`：删 `/etc/caddy/Caddyfile.d/dnsunlock` 后，若目录已空则删主配置里的 `import Caddyfile.d/*` 行，有其他文件时保留。 |
| P3-01 RegionPriority 漏新 8 地区 | **已补** | AT/DK/ES/FI/NO/NZ/PL/SE 已补进表；表本身仍无引用（死代码），行为不变。 |

## 新发现问题（本轮，全部 P3）

### M-01 种子默认规则自带域名冲突（P3）
- 位置：`internal/panel/panel.go:seedDefaults`——`youtube → US` 与 `youtube-premium → HK` 共用 `youtube.com`。
- 问题：面板自己的默认规则就是一对冲突规则：用户在面板里点保存其中任意一条都会拿到 409（本轮实测），只能勾选“强制”才能保存；agent 侧按 Tier 先赢者定（youtube-premium Tier 1 胜出），行为是确定的，不会乱，但默认状态本身就是面板口径里的“冲突态”。
- 修法：种子规则里二选一（例如 youtube-premium HK、youtube 不预设，或两条都指同一地区），或在种子规则写入时跳过冲突检测并在 README 注明先赢者是 youtube-premium。

### M-02 安装时 agent token 仍短暂出现在 curl 命令行（P3）
- 位置：`scripts/install.sh:111`（whoami）与 `:126`（下载二进制）——`curl -fsSL -H "X-Agent-Token: $TOKEN" ...`。
- 问题：token 以 curl 参数形式出现在进程列表里（`ps` 可见），与 N-12“token 不上命令行”的宣称不完全一致。窗口很短（两次 curl 的存活期）、只有本机 root 能看 ps，且 token 只在安装那台机器上出现，不影响已装好的服务；但严格说，N-12 只修了 systemd `ExecStart`，没修安装脚本的 curl 传 token。
- 修法：curl 改用 `-H @头文件` 或 `--config` 文件传 token，或把 token 写进 600 临时头文件再删。

### M-03 `--allowlist` 旗标仍在，CLI 还能把 allowlist 写进进程列表（P3）
- 位置：`cmd/dnsunlock/main.go:runAgent`（`--allowlist` 旗标仍在）与 `runProxy`（同上）；SNI 旗标的帮助文字仍写“empty = allow all”。
- 问题：安装脚本已改走 `--config`，但手动命令行仍可传 `--allowlist`（ps 可见客户端 IP 段）；帮助文字与现行 fail-closed 行为不符（空 allowlist + 非 loopback 是拒绝启动，不是放行）。
- 修法：删掉两个 `--allowlist` 旗标（只留环境变量 + 配置文件），或至少修正 SNI 的帮助文字。

### M-04 卸载无条件删除 `/etc/cloudflared`（P3）
- 位置：`scripts/uninstall.sh`——`rm -rf /etc/cloudflared` 在 `if` 块之外，每次卸载都执行。
- 问题：cloudflared 若是用户之前为别的隧道自己装的，卸载 dnsunlock 会连它的配置目录一起删掉。安装流程本身没有装 cloudflared（只有可选的 `cloudflare-tunnel.sh`），卸载应只清自己装过的。
- 修法：把 `rm -rf /etc/cloudflared` 移进“检测到 dnsunlock 装过 cloudflared”的条件里（例如只有 `cloudflared.service` 存在时才删）。

### M-05 双层反代下登录锁按出口 IP 计（P3，非安全漏洞）
- 位置：`internal/panel/panel.go:clientIP` 取 XFF 最后一个值。
- 问题：面板前面若有两层反代（例如 Cloudflare → Caddy），最后一个值是 Cloudflare 出口 IP，不是真实用户 IP；所有经同一出口的用户共用一个登录锁，一个人输错 5 次会把同出口的其他人也锁 60 秒。反过来取第一个值会被攻击者伪造，所以当前取最后一个值是对的取舍，只是多层反代时限流粒度变粗。
- 修法：暂不改。若未来接 Cloudflare，在面板前明确只信任一层反代（或按 `CF-Connecting-IP` 取值并校验来源 IP 段），并在 DESIGN 里注明。

## 仍未验证清单

1. **UDP DNS 路径**：沙箱禁一切 UDP 发送（连 loopback `sendto` 都返回 EPERM），agent UDP 监听已绑定、与 TCP 共用 `handlePacket`（TCP 已验证），但 UDP 收包/回包未实跑——需真实 VPS 上 `dig @127.0.0.1 -p 53`（UDP 默认）验证。
2. **install-panel.sh / install.sh 真机全流程**：只做了 `bash -n`、函数抽测与面板侧下载流程演练；未在真实 VPS 上跑（会改 80/443、装 systemd 服务、改本机 DNS）。其中 `systemctl is-active` 收尾探活在沙箱（无 systemd）未实跑；Caddy 安装分支（apt/dnf/yum）未实跑。
3. **resolv.conf 接管/还原真机**：代码与还原脚本已对齐（两份内容一致），未在真实机器上跑；`chattr +i`、NetworkManager/dhclient/cloud-init/netplan 各分支只在脚本层面核对。
4. **真实流媒体解锁**：需真实解锁节点 + 真实账号；本轮只验证到“DNS 返回解锁 IP / nameserver 转发到真实上游 IP”这一步。
5. **failover / failback 实况**：P1-06、P2-07、P2-09 的逻辑只在代码层面核对（30 秒探活循环、连续失败 2 次切换、主 IP 恢复切回、失联 60 秒警告），未在沙箱跑完时间线。
6. **EDNS 客户端行为**：OPT 记录仍不解析；`dig +edns` 的客户端在命中域名时拿到的回应不带 OPT，未实测其表现。
7. **Caddy 真实反代与自动 HTTPS**：本机无 caddy，`caddy validate` 未实跑；域名解析到机器、80/443 通、证书签发，全未验证。
8. **Release 公开下载流程**：Release 不存在，未验证；资产清单已定（5 个文件，见 N-02），发版后需在真实 VPS 上按清单验证下载；`.gitignore` 含 `dist/`，二进制不在 git 里，Release 资产必须从本地 `dist/` 上传。

## 核心链结论（四问，复核后）

- **会不会断网：沙箱能验证的部分已通过。** 缓存错 ID（N-03）已修并实测；规则即时生效、nameserver 转发、上游 TCP 回退均实测通过。剩余风险只在未验证清单：UDP 路径、resolv.conf 真机接管/还原、failover 实况。
- **会不会漏 IP：比上一轮好，残留均为 P3。** 列表打码与 token 分离是真的；query token 已删；默认口令服务端强制改密；锁的 XFF 绕过已修。残留：agent 失守仍能看到全部全局规则 IP（P0-05 设计使然——agent 必须知道 IP 才能答 DNS）；安装时 token 短暂进 curl 命令行（M-02）；`--allowlist` 旗标仍在（M-03）。
- **会不会被别人蹭用：主链路已堵死。** 无效 allowlist 与 SNI HTTP 两条绕过已修并实测拒启/拦截；空 allowlist + 非 loopback 拒绝启动；安装脚本不自动放行防火墙 53。
- **改错了能不能还原：比上一轮好。** panel.json 损坏恢复已动态验证通过；卸载不删用户防火墙规则；resolv.conf 还原只在代码层面核对（未真机验证）；卸载无条件删 `/etc/cloudflared` 是新发现的 P3（M-04）。

## 推仓库前必须做的事（按顺序）

1. `git init`、首次提交、push 到 https://github.com/iiiiiiiii7125-art/dns-unlock-panel（公开空仓，仍无任何提交）。提交前再扫一遍敏感信息：代码/脚本/前端/README/DESIGN 里 `xhj028` 0 处（本轮复核：仅审计报告文档与 AUDIT-PENDING.md 的文字提及中有该字符串，代码里无）；`gho_`/`ghp_`/`github_pat_` 无命中；示例 IP 均为文档段。
2. 打 tag v0.1.0，发 Release，资产为 5 个文件：`dnsunlock-linux-amd64`、`dnsunlock-linux-arm64`、`dnsunlock-linux-amd64.sha256`、`dnsunlock-linux-arm64.sha256`、`dnsunlock.sha256`（从本地 `dist/` 上传，`dist/` 在 `.gitignore` 里，不在 git 里）。
3. 发版后在真实 VPS 上验证（仍未验证清单 1/2/3/4/7）：UDP DNS、install-panel.sh 与 install.sh 真机全流程、Caddy 真实反代与自动 HTTPS、真实流媒体解锁；验证通过前不要对外宣称“全链路已验证”。
4. M-01…M-04 可在发版后下一轮修（均为 P3，不拦发版）；M-05 暂不改。

---

*第三轮审计结论：可以推仓库。N-01…N-12 全部 12 条已修并实测通过，无新的 P0/P1；新发现 5 条 P3 不拦发版。*
