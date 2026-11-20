# 修复报告 — DNS 分流解锁面板第二轮审计新问题（N-01…N-12）

- 依据：`audit/AUDIT-REPORT-2.md`（2026-11-20，结论：还不能推仓库；新发现 P0 2 / P1 3 / P2 4 / P3 3，共 12 条）与第一轮 `audit/AUDIT-REPORT.md`
- 修复时间：2026-11-20（用户 16:10 CST 明确选“修 N-01 到 N-12，再审一次”后修复）
- 代码：`~/workspace/dns-unlock-panel/`，本地修复，**未 push、未打 tag、未发 Release**
- 仓库：https://github.com/iiiiiiiii7125-art/dns-unlock-panel（公开、空）
- 结论：**N-01…N-12 全部 12 条已修并逐项复测通过**；另补了第二轮报告点出的 7 处“部分修”残留。复测：面板接口 32/32、DNS+SNI 23/23、`go vet`/`go test` 通过、双架构重建 + 分架构 sha256 校验通过。

## N-01…N-12 逐条

| 编号 | 问题 | 修复 | 证据 |
|---|---|---|---|
| N-01 (P0) | install-panel.sh 收尾 `curl -fsS /api/v1/status` 必 401，脚本永远打不出“安装完成” | 收尾改成 `systemctl is-active --quiet dnsunlock-panel` + `curl -fsS http://127.0.0.1:$PORT/ \| grep -q "登录面板"`（首页不鉴权） | 面板实测：首页 200 且含“登录面板”；脚本 `bash -n` 通过。`systemctl is-active` 本身沙箱无 systemd 未实跑，见“仍未验证” |
| N-02 (P0) | 安装脚本要下载的 `dnsunlock-linux-amd64.sha256` / `…-arm64.sha256` 不存在，/dl 404 | 新建 `scripts/build.sh`：构建双架构的同时生成两个分架构 sha256 文件（各只含本架构一行）+ 合集 `dnsunlock.sha256`；Release 资产清单定为 5 个文件（2 二进制 + 2 分架构 sha256 + 合集），README/DESIGN 已写明 | `dist/` 现有 5 个文件；`/dl/dnsunlock-linux-amd64.sha256`、`/dl/dnsunlock-linux-arm64.sha256` 实测 200；模拟安装下载流程：下载的二进制 `sha256sum -c` 通过（OK） |
| N-03 (P1) | 转发 DNS 缓存原样返回旧交易 ID，重复查询被客户端丢弃 | `forwardWithCache` 缓存命中时先复制回应，再把前两字节改写成当前查询的 ID（缓存里的原字节不动） | 实测：example.com #1 qid 0xAAAA → resp 0xAAAA；#2 qid 0xBBBB → resp 0xBBBB（原来是 0xAAAA）；两次都拿到上游真实 IP（an=2） |
| N-04 (P1) | 无效 allowlist 被静默丢弃后变公开解析器；install.sh 的 valid_ip_cidr 只是花纹匹配 | 三层：① `dnsagent.ValidateAllowlist` / `sniproxy.ValidateAllowlist`（新导出函数，逐项真校验）；② `main.go` 启动前校验，非法即 `log.Fatalf` 指明是哪一项；③ `New` 里记 `allowlistErr`，`Run()` 拒启、`allowed()` 全拒（fail-closed 第二层）。`install.sh` 的 `valid_ip_cidr` 重写：IPv4 逐段 0–255、前缀 0–32；IPv6 用 python3 的 ipaddress 真校验（无 python3 时拒绝并提示） | agent `-allowlist "not-an-ip"` 启动 rc=1（“invalid allowlist”）；`192.168.1.0/33` rc=1；SNI 配置里非法 allowlist rc=1。valid_ip_cidr 抽测 12/12：999.999.1.1、a.b.c.d、1.2.3、/33、IPv6 /129 均拒绝；2001:db8::1、2001:db8::/64、::1、192.168.1.0/24 均通过 |
| N-05 (P1) | SNI 明文 HTTP :80 绕过 fail-closed | ① 明文 HTTP 默认改为禁用（`HTTP_LISTEN` 默认空，以前默认 `:80`）；② `main.go` 对 HTTP 监听做与 TLS 同样的 fail-closed 检查；③ `sniproxy.Run()` 内再检查一次（双监听任一非 loopback + 空 allowlist 即拒启） | TLS loopback + HTTP `:18080` 空 allowlist → rc=1 拒启；TLS `:18443` 空 allowlist → rc=1；不带 `-http` 且有 allowlist 时正常运行；HTTP 监听配 allowlist=10.255.255.1 时，127.0.0.1 发 Host 请求被关闭、0 字节中继（连接被 RST，无数据） |
| N-06 (P2) | “首次必须改密”只在前端 alert，服务端不强制 | `auth()` 里 `AdminMustChange` 为真时，除 `/api/v1/change-password` 与 `/api/v1/logout` 外一律 403（`must_change_password`）；前端登录后 `must_change` 时只显示改密码卡片、不调用 init（否则会 403）；`api()` 增加 403 分支 | 实测：must_change session 调 `/api/v1/status`、`/api/v1/nodes` → 403；调改密 → 200；退出 → 200；改密后旧 session → 401、旧密码 → 401、新密码登录 must_change=false |
| N-07 (P2) | 登录锁可被伪造 X-Forwarded-For 绕过 | `clientIP` 只在直连方是本机反代（127.0.0.1/::1）时才信任 XFF，且取**最后一个**值——反代会把真实 IP 追加在末尾，第一个值仍是攻击者可控的；直连方非 loopback 时完全忽略 XFF | 实测（loopback）：同一 last-XFF 连续错 5 次后第 6 次 → 429；换 last-XFF → 401；只伪造第一个值（`1.1.1.1, 198.51.100.77`）→ 仍 429。非 loopback 分支沙箱无法实跑（loopback 只通 127.0.0.1），由新增 Go 单元测试 `TestClientIP`（internal/panel/panel_test.go，7 个用例）覆盖：直连 + 伪造 XFF → 取远端 IP |
| N-08 (P2) | agent token 仍可走 URL 查询串 | 删掉三处 `r.URL.Query().Get("agent_token")` 回退（`handleAgentWhoami`、`agentAuth`、`handleDownload`），只认 `X-Agent-Token` 头 | 实测：config / whoami / `/dl/` 二进制用 `?agent_token=` → 401；用头 → 200 |
| N-09 (P2) | 卸载删用户原有防火墙 53 规则，cloudflared 没清 | 卸载脚本删掉 ufw/firewall-cmd 的 53 规则删除（安装本身从不加这些规则）；增加 cloudflared 清理（`cloudflared service uninstall` + 停服务 + 删 /etc/cloudflared） | grep 验证：卸载脚本里已无任何可执行的防火墙删除命令（只剩一句说明性注释，后已改写避免误报）；含 cloudflared 清理块 |
| N-10 (P3) | 域名冲突提示里两个 IP 都打码成 203.0.*.*，无法区分 | 冲突提示改用节点名/地区：`describeRuleTarget`——有 NodeID 用节点名；region 规则先经 `resolveIP` 解析到实际节点再报节点名；自定义 IP 只露末段（`*.*.*.99`）；nameserver 报上游末段 | 实测 409：“现有规则指向 节点 HK-1（HK），新规则指向 节点 US-1（US）”；提示里 203.0.*.* 出现 0 次 |
| N-11 (P3) | 事件表未转义，失守 agent 可注脚本 | `web/index.html` 与 `internal/panel/assets/index.html`（两份已同步一致）的事件表六列全部走 `esc()` | 代码核对 + 实测：心跳上报含 `<img src=x onerror=alert(1)>`、`<script>` 的事件能存入；前端渲染处 `esc(e.time/platform/region/from_node/to_node/reason)` 全在 |
| N-12 (P3) | SNI allowlist/token 上命令行；SNI 配置文件无人读 | ① `dns-agent` 删掉 `--token` 旗标（token 只走 600 配置文件或 `DNS_AGENT_TOKEN` 环境变量）；② `sni-proxy` 增加 `--config`（0600 配置文件，含 allowlist；`http_listen` 键存在时才覆盖，空值 = 禁用）；③ `install.sh` 的 SNI 分支改成 `--config` 启动，`ExecStart` 不再带 `--allowlist`，`http_listen` 写 `""`；④ 删掉 install.sh 的 `--token` 参数（只留交互输入） | 实测：`dns-agent --token x` / `sni-proxy --token x` → rc=2（未知旗标）；SNI 用 `--config`（allowlist 127.0.0.1）正常启动；grep 全仓已无 `sni-proxy --allowlist` 用法、无 `:80` 的 http_listen 残留 |

## 顺带补的“部分修”残留（第二轮报告点出）

| 残留 | 修复 |
|---|---|
| P0-01 域名/端口未校验格式；ss 缺失时端口预检静默跳过 | install-panel.sh 增加域名正则与端口 1–65535 校验；新增 `port_in_use()`：有 ss 用 ss，无 ss 用 bash `/dev/tcp` 探 127.0.0.1，不再静默跳过。抽测：19876 占用检出、19877 空闲通过 |
| P1-01 回应固定 RD=1；QDCOUNT≠1 静默无回应 | `buildResponse` / `buildErrorResponse` 基数由 0x8180 改为 0x8080（QR+RA），RD 只从请求取；新增 `buildFormErr`：QDCOUNT≠1 / 截断 / 压缩问句回 FORMERR（rcode 1）。实测：RD=1 → 回 RD=1；RD=0 → 回 RD=0；QDCOUNT=0 → 收到 FORMERR |
| P1-07 默认解锁 IP 语义注释写反、README/DESIGN 没写 | `model.go` 注释修正；README 新增“默认解锁 IP 的语义”一节、DESIGN 的 DNSServer 行同步：只在规则存在但该地区无可用节点时作备用，无规则平台不用它 |
| P1-09 软链还原丢内容；NM 还原空值静默失败；netplan 只改第一处 | 两份还原脚本（install.sh 内嵌 + restore-resolv.sh，已 diff 验证内容一致）：软链还原后若目标文件不存在，把备份内容写回目标；NM 还原失败报错（不再 `\|\| true`）；netplan python 正则去掉 `count=1`（全改），sed 兜底加 `g` |
| P1-11 没 dig 时跳过验证仍打印“安装完成” | 没装 dig 时直接报错退出（装 dnsutils/bind-utils 后再验证），不再谎称安装完成 |
| P1-15 Caddy import 残留行 | 卸载时删 `/etc/caddy/Caddyfile.d/dnsunlock` 后，若 Caddyfile.d 已空则删掉主配置里的 `import Caddyfile.d/*` 行（有其他文件时保留）。临时文件演练：有其他文件时保留、目录空时删除，均通过 |
| P3-01 RegionPriority 漏新 8 地区（死代码） | 补齐 AT/DK/ES/FI/NO/NZ/PL/SE（表本身仍无引用，行为不变） |

## 没修的

- **P3-02 平台库双份源**（`data/platforms.json` 与 `internal/panel/assets/platforms.json`）：仍不改构建（Go embed 只能读包内文件，改构建流程属构建重构，风险大于收益）。本次 diff 验证两份内容完全一致；改库后必须两边同步。以 `data/platforms.json` 为准。

## 复测证据（2026-11-20，沙箱本地）

- `go vet ./...` 通过；`go test ./...` 通过（含新增 `internal/panel` 的 `TestClientIP` 7 用例与既有 sniproxy 测试）。Go 1.25.1 工具链，`go.mod` 为 go 1.24.0。
- `bash scripts/build.sh`：amd64 + arm64 重建，`sha256sum -c` 分架构与合集文件全部通过。amd64 `c3650971713f9d0352d9b5f1b11ed983d818b27fc3de4d043cf011cd69d5cafb`、arm64 `5d93fe6f1a82f593aa4028ffc7c6f9c1e4f5d71dd5e917425b7526fa0ed668ab`（静态链接 ELF，架构正确）。
- `bash -n` 全部脚本通过（scripts/*.sh + 内嵌 install.sh）。
- 面板接口测试 **32/32 通过**（`/tmp/dns-test3/panel_test.py`）：登录/改密/旧密码失效、must_change 服务端强制、登录锁 + XFF（loopback 实测 + Go 单元测试覆盖非 loopback）、query token 拒绝、列表打码/reveal、伪造心跳 403、域名冲突 409（节点名可区分）、事件 XSS 载荷存储 + 前端转义、`/dl/` 分架构 sha256 公开可取、panel.json 损坏后从 .bak 恢复且新密码可登录。
- DNS+SNI 测试 **23/23 通过**（`/tmp/dns-test3/dns_test.py`，TCP 路径）：netflix.com A → 203.0.113.10、AAAA/TXT NODATA、RD 位按请求、QDCOUNT=0 → FORMERR、缓存 ID 改写（0xAAAA/0xBBBB 各对）、example.com 上游真实 IP、改规则约 7 秒生效（→ 203.0.113.20）、nameserver 模式端到端（返回 1.1.1.1 的真实 IP 207.45.72.1）、无效 allowlist 三处拒启、SNI HTTP fail-closed + allowlist 拦截（0 字节中继）、SNI `--config` 启动、`--token` 旗标已删。
- Shell 函数抽测：`valid_ip_cidr` 12/12、`port_in_use` 2/2；N-02 模拟安装下载流程：二进制 + 分架构 sha256 下载后 `sha256sum -c` OK；卸载脚本无可执行防火墙删除命令；Caddy import 行清理演练通过。

## 复测中发现并修了的额外问题

1. **N-10 初版只报地区名**：region 规则初版提示仍是“HK 地区节点”，同一地区两条规则无法区分——已改成先 `resolveIP` 解析到实际节点再报节点名（复测 409 已含 HK-1/US-1）。
2. **N-07 取 XFF 第一个值仍可伪造**：Caddy 会把真实 IP 追加在 XFF 末尾，取第一个值等于仍信攻击者的值——已改成取最后一个值，并写进 DESIGN。
3. 测试脚手架自伤两处（不影响产品）：shell 测试脚本用了 bash 只读变量名 `PPID` 导致 kill 失效（已用脚本文件清理残留进程，现无测试进程在跑）；一次 `pkill` 模式串写进了执行命令本身导致自杀（AGENTS.md 已有此教训）。

## 仍未验证清单

1. **UDP DNS 路径**：沙箱禁一切 UDP 发送（连 loopback `sendto` 都 EPERM），agent UDP 监听已绑定、与 TCP 共用 `handlePacket`（TCP 已验证），但 UDP 收包/回包未实跑——需真实 VPS 验证。
2. **install-panel.sh / install.sh 真机全流程**：只做了 `bash -n`、函数抽测与面板侧下载流程演练；未在真实 VPS 上跑（会改 80/443、装 systemd 服务、改本机 DNS）。其中 `systemctl is-active` 收尾探活在沙箱（无 systemd）未实跑。
3. **resolv.conf 接管/还原真机**：代码与还原脚本已对齐（两份内容一致），未在真实机器上跑；`chattr +i`、NetworkManager/dhclient/cloud-init/netplan 各分支只在脚本层面核对。
4. **真实流媒体解锁**：需真实解锁节点 + 真实账号；本轮只验证到“DNS 返回解锁 IP / nameserver 转发到真实上游 IP”这一步。
5. **failover / failback 实况**：P1-06、P2-07、P2-09 的逻辑只在代码层面核对（30 秒探活循环、连续失败 2 次切换、主 IP 恢复切回、失联 60 秒警告），未在沙箱跑完时间线。
6. **EDNS 客户端行为**：OPT 记录仍不解析；`dig +edns` 的客户端在命中域名时拿到的回应不带 OPT，未实测其表现。
7. **Caddy 真实反代与自动 HTTPS**：本机无 caddy，`caddy validate` 未实跑；域名解析到机器、80/443 通、证书签发，全未验证。
8. **Release 公开下载流程**：Release 不存在，未验证；资产清单已定（5 个文件，见 N-02），发版后需在真实 VPS 上按清单验证下载。

## 改动文件清单

- `internal/panel/panel.go`：N-06/N-07/N-08/N-10、冲突提示解析到节点
- `internal/panel/panel_test.go`（新增）：`TestClientIP`（N-07，7 用例）
- `internal/panel/assets/index.html`、`web/index.html`：N-11 事件表转义、N-06 登录流程
- `internal/dnsagent/agent.go`：N-03 缓存 ID 改写、N-04 allowlist 校验、`buildResponse` RD 位、`buildFormErr`
- `internal/sniproxy/proxy.go`：N-04 allowlist 校验、N-05 双监听 fail-closed
- `cmd/dnsunlock/main.go`：N-04 启动校验、N-05 HTTP fail-closed、N-12 删 `--token`、SNI `--config`、HTTP 默认禁用
- `internal/model/model.go`：P1-07 注释修正、RegionPriority 补齐 8 地区
- `scripts/install-panel.sh`：N-01 收尾探活、域名/端口校验、`port_in_use`（ss 缺失不静默跳过）
- `scripts/install.sh`（+ 同步 `internal/panel/assets/install.sh`）：N-04 `valid_ip_cidr` 真校验、N-12 删 `--token`、SNI 走 `--config`、P1-11 无 dig 报错退出、P1-09 还原修复（软链/NM/netplan）
- `scripts/restore-resolv.sh`：与内嵌还原脚本同步的 P1-09 修复
- `scripts/uninstall.sh`：N-09 不删用户防火墙规则 + cloudflared 清理、P1-15 Caddy import 行清理
- `scripts/install-unlock-node.sh`：注释同步（明文 HTTP 默认禁用）
- `scripts/build.sh`（新增）：N-02 双架构构建 + 分架构 sha256
- `dist/`：amd64 + arm64 重建 + `dnsunlock-linux-amd64.sha256` / `dnsunlock-linux-arm64.sha256`（新增）+ 合集 `dnsunlock.sha256`
- `README.md`、`DESIGN.md`：P1-07 默认解锁 IP 语义、N-02 Release 资产清单、N-06/N-07 凭证说明

## 建议

**N-01…N-12 已修完并复测通过，可以进入第三轮审计。** 第三轮重点：UDP 实跑（真实 VPS）、安装脚本真机全流程、nameserver/EDNS、Caddy 真实反代。通过后再 `git init`、push、打 tag、发 Release。
