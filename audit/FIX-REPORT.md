# 修复报告 — DNS 分流解锁面板审计修复（AUDIT-REPORT.md 38 条）

- 审计报告：`audit/AUDIT-REPORT.md`（2026-11-20，P0 7 / P1 15 / P2 10 / P3 6，共 38 条，结论：不建议发版）
- 修复时间：2026-11-20（用户 11:16 CST 明确确认“确认，继续修”后恢复）
- 代码：`~/workspace/dns-unlock-panel/`，本地修复，**未 push、未打 tag、未发 Release**
- 仓库：https://github.com/iiiiiiiii7125-art/dns-unlock-panel（公开、空）

## 结论

38 条中 **37 条已修，1 条未修（P3-02 平台库双份源，见下）**。复测 16/16 项面板接口测试通过，DNS 真实解析（TCP 路径）通过，规则立即生效、allowlist 拦截、SNI 拒启动均实测通过。

**建议：可以进入下一轮审计；通过后再推仓库、打 tag、发 Release。** 仍有 4 项未验证（见“仍未验证”一节），主要是沙箱环境限制（UDP 全禁）和真实解锁节点缺失，不建议在这些项验证前声称“全链路已验证”。

## P0（7/7 已修）

| 编号 | 问题 | 修复 | 证据 |
|---|---|---|---|
| P0-01 | `scripts/install-panel.sh` 不存在，README 一键部署跑不起来 | 新建 `scripts/install-panel.sh`：填域名自动 Caddy 反代 + 自动 HTTPS；域名为空只跑 8080；80/443 被占提示退出、不覆盖；端口/systemd/依赖预检；下载必须 sha256 校验；`bash -n` 通过。另修了一个实测发现的旗标 bug：原草稿用 `--listen/--data`，面板实际旗标是 `-addr/-data` | `bash -n scripts/install-panel.sh` 通过；Caddyfile 生成演练见下 |
| P0-02 | 旧共享 token `xhj028`（12 处），无登录/改密/session | 面板登录改 admin/admin（bcrypt 哈希存，首次 `must_change=true`）；登录失败 5 次锁 60 秒；session 随机 32 字节、24 小时过期；`POST /api/v1/change-password`（新密码 ≥6 位，改完清空全部 session）；DNS 机器改每台随机 agent token | 全仓 `xhj028` 0 处（代码/脚本/前端/README/DESIGN）；登录/改密/旧密码失效实测通过（见复测） |
| P0-03 | `/install.sh` 不登录就能拿面板 token，启动日志打 token | `/install.sh` 只 baked 面板地址，不含任何 token；agent token 安装时人工输入（不回显）；删除 `PANEL_TOKEN`/`xhj028`，启动日志不打任何凭证；面板 `handleInstallScript` 只替换 `__PANEL_URL__` | 未登录调 `/install.sh`，`xhj028`/`agent_token` 引用 0 处；复测 16/16 |
| P0-04 | DNS/SNI 默认公开递归/公开代理，安装脚本主动放行 53 | allowlist 为空且监听非 loopback 时**拒绝启动**（dns-agent 与 sni-proxy，`failClosedAllowlist`）；只听 127.0.0.1 时才放行本机测试；安装时 allowlist 必填；安装脚本**不自动放行防火墙 53** | SNI 无 allowlist 听 `:18443`：exit 1，拒启动（实测）；allowlist=10.255.255.1 的 agent：127.0.0.1 查询被 reset（实测） |
| P0-05 | 列表接口直接返回完整解锁 IP 和服务器 token；agent 配置返回全部全局规则 | 列表接口只返回打码 IP（`203.0.*.*`）；完整 IP/token 只有管理员点“显示”单独调 reveal 接口；agent 配置只返回本台服务器的规则（全局 + 本机专属），且按 Tier 排序、共享域名先赢者定 | 节点列表打码、reveal 返回完整 IP、服务器列表 token 打码，实测通过 |
| P0-06 | 一个 token 通吃面板/agent/下载；可伪造任意 server_id 上报心跳 | 三套凭证分开：面板登录 session、每台 agent token（只能拉自己配置、上报自己心跳）、下载（session 或任一 agent token）；心跳校验 body 的 `ServerID` 必须与 token 对应服务器一致，否则 403；新增 `GET /api/v1/agent/whoami`（token 换 server_id，供安装脚本用） | 伪造心跳（token A + server_id B）→ 403；自己心跳 → 200；`/dl` 无 token → 401、有 agent token → 200 |
| P0-07 | `dist/` 二进制是旧版，`go.mod` 升 go 1.24 加 `x/crypto` 没重构建，arm64 包不存在 | 重构建 amd64 + arm64（`go build -trimpath`，CGO_ENABLED=0），`sha256sum -c` 通过；`go vet ./...`、`go test ./...` 通过 | `dist/dnsunlock-linux-amd64`（9,702,048 字节）、`dist/dnsunlock-linux-arm64`（9,109,429 字节），`dnsunlock.sha256` 校验 OK；go.mod `go 1.24.0`，构建用 go1.25.0 工具链 |

## P1（15/15 已修）

| 编号 | 问题 | 修复 |
|---|---|---|
| P1-01 | DNS 只答 A/AAAA、其他类型绕开、固定 flags/TTL 60、不认 EDNS、超 4096 截断、上游挂了没回应 | 命中域名其他类型回 NODATA；未命中类型转发上游原样回传；上游失败回 SERVFAIL 不静默；保留请求 RD 位；UDP 缓冲 8192、TCP 上限 65535、UDP 并发信号量 256；上游双备选（面板上游 + 8.8.8.8）；转发答案 60 秒小缓存（上限 512）。EDNS：仍不解析 OPT（最小实现，见“未修/说明”） |
| P1-02 | `youtube.com` 等 9 条域名多平台共用，后规则悄悄覆盖 | 面板与 agent 双侧按 Tier 排序、共享域名先赢者定（确定性）；规则保存做域名冲突检测，不同 IP 冲突时返回 409，需 `force=true` 才强制保存；前端 409 时提示并可强制保存 |
| P1-03 | `apple.com`/`amazon.com`/`bbc.com`/`bing.com` 等域名收得太宽 | 删宽域名：primevideo 的 `amazon.com`、appletv/applemusic 的 `apple.com`、bbciplayer 的 `bbc.com`、copilot 的 `bing.com`、meta-ai 的 `facebook.com`；删未验证域名 `hbomaxcdn.com`、`daznservices.com`（最小化原则，需用时走自定义域名） |
| P1-04 | 自定义域名没校验（填 `com` 能拐走全部 `.com`） | 自定义域名拒绝单段、顶级域和过宽的知名二段域名（google.com、apple.com 等） |
| P1-05 | IP 没校验、填错静默回空 | 节点/规则/服务器/custom 域名/public 源的 IP、地区、端口均校验；无效解锁 IP 时转发上游而非静默回空 |
| P1-06 | 备用 IP 切过去回不来 | 主 IP 恢复自动切回并记事件；备用 IP 也探活；探活改 TLS 握手（只拨通 TCP 不算数） |
| P1-07 | 默认解锁 IP 是摆设 | 明确取舍：默认解锁 IP 仅在规则指定地区无可用节点时作备用，不用于无规则平台（无规则域名仍走上游）；安装脚本与 README/DESIGN 写明此语义 |
| P1-08 | 改节点不填 `enabled` 就禁用 | 节点更新用 `Enabled *bool`，不传不改动 |
| P1-09 | resolv.conf 备份拷软链、接管两次丢原备份、还原不完整、NetworkManager 只改第一个连接、不管 IPv6 | 备份拷内容（`cp -L`）不拷软链，只备一次原文件（`.orig` 已存在不再覆盖）；还原时 `chattr -i`、恢复软链目标；NetworkManager 改**全部**活动连接并记原值（含 IPv6）；处理 resolvconf（head drop-in）、dhclient（supersede）、cloud-init（`manage-resolv-conf: false`）、netplan（备份 yaml、改 addresses、需确认才 apply）；接管后 `chattr +i`，还原时去掉 |
| P1-10 | 安装脚本缺 systemd/端口检查、sha256 下不到跳过校验、token 露在启动命令 | 预检 systemd/端口（53 被占停下）；sha256 下不到即停；token 只放 600 配置文件，systemd 用 `--config`，启动命令不带 token；agent 加 `--config`（默认 `/etc/dnsunlock/config.json`，0600） |
| P1-11 | 无装前基线测试和装后验证 | 装前：面板连通 + token 校验（`whoami`）；装后：dig 测 example.com 走上游、提示测规则域名；不通就报错退出，不说“安装完成”；测速不用 `date +%s%N`（Alpine 不可靠），有 python3 才计时，否则只按通/不通排序 |
| P1-12 | 平台库地区 AT/DK/ES/FI/NO/NZ/PL/SE 在面板 26 个地区里没有；`abema` 对不上 `abematv` | 地区补到 34 个（+AT/DK/ES/FI/NO/NZ/PL/SE），`RegionValid` 校验；`abema`：ID 保持 `abematv`（已有规则引用 ID，改 ID 会断规则），名称已是 AbemaTV，不作 cosmetic 改名 |
| P1-13 | `install-unlock-node.sh` 空地址即停、拼错地址、SNI 不配 allowlist | 重写：面板地址参数必填（空即停并打印用法）；先下载 install.sh 到临时文件再执行（不拼错地址）；`--unlock-node` 分支里 allowlist 必填，不填不启动 |
| P1-14 | `data/panel.json` 是 644、无备份、损坏就起不来 | 保存改为 0600；每次保存先把旧文件拷为 `.bak`（0600）；解析损坏时先试 `.bak` 恢复 |
| P1-15 | Cloudflare Tunnel 脚本关键步骤失败也继续、凭据靠 `awk` 抠；卸载失败还继续删备份、防火墙/Caddy 没清 | Tunnel 脚本：去掉关键步骤的 `|| true`（失败即停）；凭据改扫描 `~/.cloudflared/*.json` 按 `TunnelName` 匹配（python3 解析 JSON）；去掉验证命令里的 `xhj028`。卸载脚本：先还原 DNS，还原失败立即停、不删备份；再删服务/二进制；清理 ufw/firewalld 的 53 规则与 Caddy 反代；面板数据默认保留，`--purge` 才删 |

## P2（10 条：9 已修，1 条部分）

| 编号 | 状态 | 说明 |
|---|---|---|
| P2-01 | 已修 | 上游双备选 + 60 秒转发缓存（上限 512） |
| P2-02 | 已修 | 登录失败 5 次锁 60 秒（防暴力破解） |
| P2-03 | 已修 | SNI 大 ClientHello：32K 缓冲读；转发全程 120 秒总时限；挂住连接由 deadline 清理 |
| P2-04 | 已修 | 前端用户填内容渲染时转义（`esc()`），不直接拼 innerHTML |
| P2-05 | 已修 | Netflix 自测链接由写死片单 ID 改为首页 |
| P2-06 | 已修 | `hbomaxcdn.com`、`daznservices.com` 未验证域名已删（见 P1-03） |
| P2-07 | 已修 | 探活改 TLS 握手（见 P1-06） |
| P2-08 | 已修 | 节点只改名称/备注不涨配置版本；只有 IP/地区/enabled 变化才涨 |
| P2-09 | 已修 | 面板失联超 60 秒 agent 日志明确提示“仍用旧规则” |
| P2-10 | 已修 | `/api/`、`/install.sh`、`/dl/` 均返回 `Cache-Control: no-store` |

## P3（6 条：5 已修，1 条未修）

| 编号 | 状态 | 说明 |
|---|---|---|
| P3-01 | 已修 | 地区优先级补 MO、IT |
| P3-02 | **未修** | 平台库仍有两份源：`data/platforms.json`（源）与 `internal/panel/assets/platforms.json`（面板内嵌用）。本次已同步内容一致，但未改成“构建时复制一份”的机制。原因：Go embed 只能读包内文件，改构建流程需改 Makefile/构建脚本，属构建重构，风险大于收益；已在 README/DESIGN 注明以 `data/platforms.json` 为准，改库后同步复制。下一轮审计可再议 |
| P3-03 | 已修 | Go 版本统一：go.mod `go 1.24.0`，README/DESIGN 写 Go 1.24+（构建工具链 go1.25.0） |
| P3-04 | 已修 | 删死代码 `proxyConn`（从未被调用）；`DefaultUnlockIP` 逻辑已按 P1-07 明确语义，非死代码，保留 |
| P3-05 | 已修 | 同 P2-05 |
| P3-06 | 已修 | 测速不用 `date +%s%N`（见 P1-11） |

## 复测中发现并修复的额外问题（审计报告之外）

1. **agent 用 `?token=` 传 token，面板只认 `X-Agent-Token` 头**：agent 拉配置 401（`agent token and server_id required`），DNS 全不通。这是 MVP 遗留的接口不一致，复测时发现。修复：agent 的 config 与 heartbeat 改用 `X-Agent-Token` 头传 token（URL 里不再放 token，也避免进日志）。修复后拉配置成功（version 3）。
2. **TCP 客户端 5 秒时限掐断上游 TCP 回退**：沙箱禁 UDP 时，上游需 3 秒 UDP 尝试 + 3 秒 TCP 尝试，5 秒 deadline 导致连接被关（dig 报 `end of file`）。修复：handleTCP 时限改为 15 秒。真实 VPS 上 UDP 上游通常 <100ms，此问题只在禁 UDP 环境出现。
3. **install-panel.sh 旗标错误**：草稿用 `panel --listen :$PORT --data ...`，面板实际旗标是 `-addr`/`-data`。已修正为 `-addr :$PORT -data /var/lib/dnsunlock/panel.json`。教训：脚本里的命令必须以实测为准。

## 复测证据（2026-11-20 04:0x UTC，本地沙箱）

工具链：Go 1.25.0（`~/workspace/.tools/go/bin/go`），go.mod `go 1.24.0`。

- `go vet ./...`：通过；`go test ./...`：通过（sniproxy ok，其余包无测试文件）。
- `bash -n`：`scripts/install.sh`、`scripts/install-panel.sh`、`scripts/restore-resolv.sh`、`scripts/uninstall.sh`、`scripts/install-unlock-node.sh`、`scripts/cloudflare-tunnel.sh` 全部通过。
- 重构建：amd64（9,702,048 字节）+ arm64（9,109,429 字节），`sha256sum -c dnsunlock.sha256`：`dnsunlock-linux-amd64: OK` / `dnsunlock-linux-arm64: OK`。
- 面板接口复测（`/tmp/dns-test2/retest.sh`，面板 127.0.0.1:18080）：**16/16 通过**——
  install.sh 无 xhj028；`/dl` 无 token → 401、有 agent token → 200；登记服务器返回一次性 token、列表打码 token；agent 配置自己 token → 200；伪造心跳（token A + server_id B）→ 403、自己心跳 → 200；节点列表打码 IP、reveal 返回完整 IP；规则保存 → 200；非法节点 IP → 400；自定义域名 `com` → 400；改密 → 200、旧密码登录 → 401、新密码登录成功；未登录调节点接口 → 401。
- DNS 真实解析（agent 127.0.0.1:15353，TCP 路径）：
  `dig +tcp netflix.com A` → `203.0.113.10`（规则）；`netflix.com AAAA` → NODATA（空）；`www.netflix.com A` → `203.0.113.10`（后缀匹配）；`example.com A` → `172.66.147.243`、`104.20.23.154`（上游 TCP 回退，真实 IP）；`example.com TXT` → 真实 TXT（`v=spf1 -all` 等）。
- 规则立即生效：面板把 netflix 规则改到第二节点 `203.0.113.99`，7 秒后 `dig +tcp netflix.com A` → `203.0.113.99`。
- allowlist 拦截：allowlist=10.255.255.1 的 agent（15354），127.0.0.1 的 TCP 查询被 reset。
- SNI 拒启动：无 allowlist 听 `:18443` → exit 1；只听 127.0.0.1 时启动并打印警告。
- Caddyfile 演练：生成反代配置（`dns.example.com → 127.0.0.1:8080`）；本机无 caddy，`caddy validate` **未实跑**（见“仍未验证”）。

## 仍未验证的部分

1. **UDP DNS 路径**：本沙箱禁一切 UDP 发送（连 loopback UDP `sendto` 都返回 `EPERM`，python/socat/dig 均验证）。agent 的 UDP 监听已绑定（`ss` 可见 127.0.0.1:15353 UDP），UDP 处理与 TCP 共用同一 `handlePacket`（TCP 已实测通过），但 UDP 收包/回包**未在本机实跑**。需在真实 VPS 上 `dig @127.0.0.1 -p 53`（UDP 默认）验证。
2. **nameserver 模式端到端**：规则转发到公共源 DNS IP 的路径未实跑（无可用公共源 IP，且沙箱禁 UDP 上游）。代码路径与 address 模式共用 `forwardTo`（TCP 回退已验证）。
3. **install-panel.sh 全流程**：只做了 `bash -n` + Caddyfile 生成演练；未在真实 VPS 上跑（会改 80/443、装 systemd 服务）。Caddy 未装，`caddy validate` 未实跑。install.sh 的 resolv.conf 接管/还原全流程同样未在真实机器上跑（会改本机 DNS）。
4. **真实流媒体解锁**：需真实解锁节点 + 真实 Netflix 等账号测试（审计原文也列为未验证）。本次只验证到“DNS 返回解锁 IP”这一步。
5. **EDNS**：仍不解析 OPT 记录（最小实现）。EDNS 客户端（如 `dig +edns`）的 OPT 会被原样转发（未命中域名）或忽略（命中域名回标准应答），未实测 EDNS 客户端行为。

## 建议

- **可以进入下一轮审计**：38 条中 37 条已修，复测证据完整；剩余未验证项主要是环境限制，不是代码未完成。
- 下一轮审计重点建议：UDP 实跑（真实 VPS）、install-panel.sh / install.sh 全流程实跑（真实 VPS）、nameserver 模式、EDNS 客户端行为、P3-02 平台库双份源是否接受现状。
- **不要在下一轮审计通过前推仓库、打 tag、发 Release**（当前仍停在本地）。

## 文件清单（本次改动）

- `internal/panel/panel.go`：鉴权/session/改密/锁、打码 + reveal、校验、冲突 409、agent 配置按 Tier 去重、whoami 端点、节点版本涨落（P2-08）、死代码清理
- `internal/store/store.go`：0600 保存、`.bak` 备份、损坏恢复、admin 字段
- `internal/model/model.go`：34 地区、`RegionValid`、地区优先级 MO/IT、节点 allowlist 字段
- `internal/dnsagent/agent.go`：header 传 token、SERVFAIL、双上游 + TCP 回退、60 秒缓存、UDP 缓冲/并发上限、TLS 握手探活、主备切回、TCP 时限 15 秒
- `internal/sniproxy/proxy.go`：32K ClientHello 缓冲、120 秒总时限、删死代码 `proxyConn`
- `cmd/dnsunlock/main.go`：删 `PANEL_TOKEN`/`xhj028`、启动日志不打凭证、agent `--config`、fail-closed allowlist、no-store
- `data/platforms.json` + `internal/panel/assets/platforms.json`：删宽域名/未验证域名（已同步）
- `internal/panel/assets/index.html` + `web/index.html`：admin 登录、改密/退出、sessionStorage、reveal、409 冲突提示、XSS 转义（两份已同步）
- `internal/panel/assets/install.sh` + `scripts/install.sh`：重写（token 人工输入、allowlist 必填、sha256 强校验、基线/装后验证、resolv.conf 全套处理）
- `scripts/install-panel.sh`：新建；`scripts/restore-resolv.sh`、`scripts/uninstall.sh`、`scripts/install-unlock-node.sh`、`scripts/cloudflare-tunnel.sh`：重写
- `README.md`、`DESIGN.md`：按修复后现实更新；新增 `.gitignore`（`data/panel.json`、`dist/`）、`LICENSE`（MIT）
- `dist/`：重构建 amd64 + arm64 + sha256（`dist/` 不进仓库）
