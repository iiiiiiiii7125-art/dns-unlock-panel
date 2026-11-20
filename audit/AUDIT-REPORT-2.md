# DNS 分流解锁面板 — 第二轮审计报告（独立复核）

- 审计对象：`~/workspace/dns-unlock-panel/`（修复后状态，2026-11-20 14:54 CST 用户选“先第二轮审计，再推仓库”后复核）
- 对照材料：第一轮 `audit/AUDIT-REPORT.md`（P0 7 / P1 15 / P2 10 / P3 6，共 38 条，结论不建议发版）；修复报告 `audit/FIX-REPORT.md`（声称 37/38 已修）；待审清单 `AUDIT-PENDING.md`
- 审计方式：只审计、不改代码、不 push、不打 tag、不发 Release。逐条读代码核对修复是否真实落地（文件+行号/关键片段见下表），并重跑动态验证：`go vet`、`go test`、重建 amd64+arm64 并 `sha256sum -c`、`bash -n` 全部脚本、面板接口、DNS TCP 路径。**没有下载、没有运行任何第三方安装脚本**（包括 AKDNS 的），只用其公开文档对照。
- **结论先说：还不能推仓库。** 修复本身大部分是真的（19/38 全修，另有动态验证通过多项），但复核发现 **2 个新的 P0**：一键安装脚本在最后一步必定失败（N-01），且安装脚本要下载的分架构 sha256 文件根本不存在（N-02）——等于一键安装这条路现在走不通；另有 **3 个新的 P1**：转发 DNS 缓存会把错误的交易 ID 发回去、导致重复查询被客户端丢弃（N-03）；无效 allowlist 会静默变成公开解析器（N-04）；SNI 的明文 HTTP :80 绕过了 fail-closed（N-05）。这 5 条修好并重验之后，才能推仓库。

## 汇总

| | 数量 |
|---|---|
| 第一轮 38 条中：已修 | 19 |
| 第一轮 38 条中：部分修 | 18 |
| 第一轮 38 条中：未修 | 1（P3-02，修复方已承认并写明原因） |
| 新发现问题 | P0 2 / P1 3 / P2 4 / P3 3，共 12 条（N-01…N-12） |

> 编号说明：FIX-REPORT 里 P1 的编号与第一轮审计报告错了一位（它把“install-unlock-node 空地址”写成 P1-13、把 panel.json 写成 P1-14、把 Tunnel+卸载写成 P1-15）。下表按**第一轮审计报告的编号**复核，括号里注明对应关系，避免对不上。

## 动态验证结果（本轮实测，沙箱本地）

- `go vet ./...` 通过；`go test ./...` 通过（只有 sniproxy 有测试文件，其余包无测试）。
- 重建 amd64+arm64：哈希与 `dist/` 已发文件**完全一致**（amd64 `a8c55d63…`、arm64 `1bd13475…`），`sha256sum -c dist/dnsunlock.sha256` 通过；两个包均为静态链接 ELF，架构正确。
- `bash -n`：6 个脚本 + 内嵌 install.sh 全部通过。
- 面板接口（127.0.0.1:18081/18082/18083，三次独立启动）：
  - 登录 admin/admin 成功，`must_change=true`；改密成功，旧密码再登录 → 401，新密码 → 200，改密后旧 session → 401。
  - 未登录调节点接口 → 401；节点/服务器列表 IP 打码（`203.0.*.*`）；reveal 返回完整 IP；服务器创建时一次性返回完整 token。
  - `/dl/` 无 token → 401，有 agent token → 200；伪造心跳（query 的 server_id 不对 → 401；body 的 server_id 不对 → 403）；agent 配其他 server_id → 401。
  - 非法节点 IP → 400；自定义域名 `com` → 400；域名冲突 → 409（force=true 后放行）；改节点名不传 enabled → 仍启用。
  - `panel.json` 0600、`.bak` 存在；故意写坏 panel.json 后重启，面板从 `.bak` 恢复，登录与节点数据完好。
- DNS TCP 路径（agent 127.0.0.1:15353/15355）：
  - `netflix.com A` → `203.0.113.10`；`www.netflix.com` 同值；AAAA → NODATA（AN=0）；TXT → NODATA；`example.com A` 经上游 TCP 回退返回真实 IP（172.66.147.243）。
  - 改规则后约 2 秒生效（`203.0.113.10` → `203.0.113.99`）。
  - nameserver 模式端到端通过：netflix 规则指向上游 1.1.1.1 后，查询返回真实 IP 207.45.72.1（不是解锁 IP）。
  - allowlist=10.255.255.1 时（上一轮）/ allowlist 拦截逻辑在代码与实测中一致；本轮另测无效 allowlist 见 N-04。
- 本轮复核中**证实为假 / 未达标**的修复声明（详见新发现问题 N-01…N-08）：
  - “首次必须改密”只在前端 `alert`，服务端不强制（must_change=true 的 session 调 `/api/v1/status` 仍返回 200）。
  - agent token“URL 里不再放”只改了 agent 客户端；服务端仍接受 `?agent_token=`（实测 200）。
  - 登录锁 5 次/60 秒是真的（第 6 次 → 429），但 `X-Forwarded-For` 可伪造，换个头就绕过（实测 429 → 401）。
  - `/dl/dnsunlock-linux-amd64.sha256` → 404（安装脚本要的就是这个文件）；合集 `dnsunlock.sha256` 存在，但只放一个架构的包时 `sha256sum -c` 必失败（实测 exit 1）。

## 逐条复核表（38 条）

### P0（7 条）：已修 2，部分修 5

| 编号 | 结论 | 证据 / 说明 |
|---|---|---|
| P0-01 面板一键安装脚本不存在 | **部分修** | `scripts/install-panel.sh` 已新建，`bash -n` 通过，Caddy 反代生成、端口预检、sha256 强校验的架子都在。但它**装不完**：见新问题 N-01（最后一步必失败）、N-02（要下载的 `$BIN.sha256` 不存在）。另：域名/端口未校验格式；`ss` 不存在时端口预检静默跳过；Caddy 不存在时才装，`caddy validate` 只在装好后跑。 |
| P0-02 admin/admin 登录 | **部分修** | 登录/ bcrypt 哈希（`panel.go:New`，`$2a$10$`）/ session（随机 32 字节，24h）/ 改密后旧密码与旧 session 立即失效，**全部动态验证通过**。但“首次必须改密”未在服务端强制（见 N-06）；新密码只要求 ≥6 位，无复杂度要求。 |
| P0-03 /install.sh 泄露 token | **已修** | 下载的 install.sh 里 `xhj028` 0 处，`agent_token` 只出现在安装时填入配置的模板行（`install.sh:164`）；启动日志只打监听地址与数据文件路径（实测 `panel.log`）。小残留：`--token` 命令行参数仍可用（会进 shell 历史），见 N-12。 |
| P0-04 DNS/SNI 默认公开 | **部分修** | `main.go:failClosedAllowlist` 在入口处拦截（空 allowlist + 非 loopback 监听 → 拒绝启动）；安装脚本 allowlist 必填、不自动放行防火墙 53。但有两条绕过，见 N-04（无效 allowlist 静默变公开）、N-05（SNI HTTP :80 不受 fail-closed 管）。`dnsagent.New` / `sniproxy.New` 本身仍是“空 allowlist = 放行 + 警告”，只靠 main.go 一层挡。 |
| P0-05 列表接口返回完整 IP | **部分修** | 列表打码、reveal 单独接口、agent 配置按 token 锁定到一台服务器，**全部动态验证通过**。但 agent 配置仍返回**全部全局规则**的 IP（实测：一台新登记服务器的 config 里有 netflix/disneyplus/youtube-premium 三条全局规则的 `203.0.113.10`）——全局规则本来就是共享的，设计上如此，但 FIX-REPORT“只返回本台服务器的规则”的说法不准确；一台 agent 失守仍会漏出全部全局解锁 IP。 |
| P0-06 一个 token 通吃 | **部分修** | 三套凭证已分开（面板 session / 每台 agent token / 下载用 session 或 agent token），伪造心跳被拒（body 不符 → 403、query 不符 → 401，实测）。残留：服务端仍接受 URL 查询串里的 agent token（见 N-08），与“token 不进 URL/日志”的宣称不符。 |
| P0-07 二进制旧、无 arm64 | **已修** | 本轮重建的 amd64/arm64 与 `dist/` 文件哈希完全一致，`sha256sum -c` 通过，`go vet`/`go test` 通过。但安装脚本消费 sha256 的方式是断的，见 N-02（这是安装流程问题，二进制本身没问题）。 |

### P1（15 条，按第一轮编号）：已修 6，部分修 9

| 编号 | 结论 | 证据 / 说明 |
|---|---|---|
| P1-01 DNS 只答 A/AAAA 等 | **部分修** | 命中域名其他类型回 NODATA（TXT 实测 AN=0）、上游失败回 SERVFAIL、双上游 + TCP 回退（example.com 实测）、UDP 缓冲 8192、并发信号量 256，代码均在 `internal/dnsagent/agent.go`。残留：EDNS OPT 仍不解析（FIX-REPORT 已承认）；回应固定写 RD=1（`buildResponse` 用 `0x8180` 打底，请求 RD=0 也会被置 1）；QDCOUNT≠1 的查询直接无回应（`parseQuestion` 返回 nil）。另见新问题 N-03（缓存）。 |
| P1-02 共享域名悄悄覆盖 | **已修** | 规则保存冲突检测 + 409（实测 youtube vs youtube-premium → 409，force=true 放行）；面板与 agent 双侧按 Tier 排序、先赢者定（`panel.go:handleAgentConfig`、`agent.go:fetchConfig`）。小毛病：冲突提示里两个 IP 都打码成 `203.0.*.*`，同网段时分不清谁是谁（见 N-10）。 |
| P1-03 域名收太宽 | **已修** | `apple.com`/`amazon.com`/`bbc.com`/`bing.com` 已从对应平台删除；`hbomaxcdn.com`/`daznservices.com` 全库 0 处（grep 验证）。`facebook.com` 仍在，但只在 facebook 平台自身（其核心域名，留着是对的）；meta-ai 已只剩 `meta.ai`。共享域名从 9 条降到 7 条（netflix.com、nflxvideo.net、youtube.com、openai.com、chatgpt.com、dazn.com、sky.com）。 |
| P1-04 自定义域名无校验 | **已修** | `com` → 400（实测）；单段/顶级域/7 个知名宽域名被拒（`panel.go:validCustomDomain`）。残留：`youtube.com`、`netflix.com` 这类平台核心域名不在黑名单里，管理员自己加自定义域名仍可能抢占（自伤性质，P3）。 |
| P1-05 IP 无校验 | **部分修** | 面板侧校验到位（非法节点 IP → 400，实测）；agent 侧无效 IP 改走上游而非静默回空（`agent.go:handlePacket`）。但 `scripts/install.sh` 的 `valid_ip_cidr` 只是 `*.*.*.*` 花纹匹配，`999.999.1.1`、`a.b.c.d` 都能过，IPv6 反而被拒；与 agent 静默丢弃无效 allowlist 条目叠加后会变成公开解析器（见 N-04）。 |
| P1-06 备用 IP 切回不来 | **部分修（仅代码核对，未动态验证）** | 主 IP 恢复自动切回并记事件、备用 IP 也探活、主 IP 变化时清掉覆盖，逻辑都在 `agent.go:checkHealth/fetchConfig`。未动态验证：要等 30 秒探活循环对坏 IP 连续失败 2 次再恢复，沙箱里没跑完这条时间线，真机上需补测。 |
| P1-07 默认解锁 IP 是摆设 | **部分修** | 语义已在代码里明确：只在“规则存在但该地区无可用节点”时作备用，无规则平台仍走上游（`panel.go:handleAgentConfig`）。但 `internal/model/model.go:200` 的注释仍写反（“used when a platform has no rule”）；README/DESIGN 里没写这条语义（grep：README 只有一句“默认解锁 IP（可空）”，DESIGN 无），FIX-REPORT“README/DESIGN 已写明”的说法不实。 |
| P1-08 改节点丢 enabled | **已修** | 实测：只改名字不传 enabled，节点仍为 enabled=true（`panel.go:handleNodeByID` 用 `Enabled *bool`）。 |
| P1-09 resolv.conf 接管/还原 | **部分修（仅代码核对，未真机验证）** | `cp -L` 拷内容、`.orig` 只备一次、`chattr +i`、resolvconf/dhclient/cloud-init/netplan、NetworkManager 改全部连接含 IPv6，都在 `scripts/install.sh` 与内嵌还原脚本里。未真机验证（会改本机 DNS，沙箱里不跑）。残留边角：原 resolv.conf 是软链时，还原只恢复软链、不恢复备份的内容（目标文件若已被删就丢了）；NM 还原时原值为空会静默失败（`|| true`）；netplan 的 python 正则只改第一处。 |
| P1-10 安装脚本缺检查/校验可绕过/token 露进程列表 | **部分修** | systemd/端口预检、token 只放 0600 配置、systemd 用 `--config`，都在。但 sha256 校验在安装路径上是断的（见 N-02）；SNI 服务的 `ExecStart` 把 allowlist 明文写进启动命令（`install.sh:121`，ps 可见，见 N-12）。 |
| P1-11 无装前/装后验证 | **部分修** | 装前 whoami 校验 token、装后 dig 测 example.com，代码里有。但没装 dig 的机器会跳过验证仍打印“安装完成”；没有真正的基线解锁测试（只测面板通不通、token 对不对，不测解锁 IP 能不能解锁）。 |
| P1-12 地区选不到 | **已修** | 地区补到 34 个（`model.go:Regions`，含 AT/DK/ES/FI/NO/NZ/PL/SE），平台库 33 种地区值全是其子集；`abematv` ID 保留（改 ID 会断已有规则）、名称已是 AbemaTV，处理合理。 |
| P1-13 panel.json 0644、无备份（第一轮编号；FIX-REPORT 写成 P1-14） | **已修** | 保存 0600、每次保存先写 `.bak`（0600）、损坏时用 `.bak` 恢复——**动态验证通过**：写坏 panel.json 后重启，面板正常启动，admin 登录成功、节点数据完好（`store.go:New/saveLocked`）。 |
| P1-14 Tunnel 脚本失败也继续（第一轮编号；FIX-REPORT 写成 P1-15 前半） | **部分修** | 关键步骤去掉 `|| true`（set -e 下失败即停）、凭据改 python 解析 JSON（`cloudflare-tunnel.sh`）。残留：缓存规则仍只是口头提醒（脚本不做不检查）；凭据扫描路径写死 `/root/.cloudflared/*.json`；`tunnel list | grep "$NAME"` 未锚定，可能误匹配名字相近的 tunnel。 |
| P1-15 卸载删备份（第一轮编号；FIX-REPORT 写成 P1-15 后半） | **部分修** | 先还原、还原失败立即停不删备份、面板数据默认保留（`uninstall.sh`）。残留：防火墙清理会删掉用户本来就有的 53 规则（见 N-09）；cloudflared 没清；Caddy 主配置里追加的 `import Caddyfile.d/*` 一行留下来了。 |

### P2（10 条）：已修 7，部分修 3

| 编号 | 结论 | 证据 / 说明 |
|---|---|---|
| P2-01 无 DNS 缓存、上游单一 | **部分修（引入新问题）** | 双上游（面板上游 + 8.8.8.8）与 60 秒缓存（上限 512）已做。但缓存实现有 bug，见新问题 N-03：缓存的回应原样返回，交易 ID 是第一次查询的，重复查询会被客户端丢弃。 |
| P2-02 防暴力破解 | **部分修** | 5 次失败锁 60 秒是真的（第 6 次 → 429，实测）；session 放 sessionStorage（不是 localStorage）、有退出登录。但锁的 key 取自 `X-Forwarded-For`（可伪造），见 N-07。 |
| P2-03 SNI 大 ClientHello/挂住不断 | **已修** | 32K 缓冲读、120 秒总时限（`proxy.go:handleTLS`）；`go test ./...` 通过（含 sniproxy 测试）。 |
| P2-04 前端 innerHTML 注入 | **部分修** | 用户填的内容大多已用 `esc()` 转义（节点名/备注/服务器名等，`index.html:139`）。但事件表（`index.html:273`）把 `e.from_node / e.to_node / e.reason` 直接拼进 HTML——这些字段来自 agent 上报的心跳，见 N-11。 |
| P2-05 解锁节点脚本空地址乱跑（第一轮编号；FIX-REPORT 写成 P1-13） | **已修** | 空面板地址直接打印用法退出；先下载 install.sh 到临时文件再执行（`install-unlock-node.sh`）。 |
| P2-06 平台库域名未验证 | **已修** | `hbomaxcdn.com`、`daznservices.com` 已删（grep 0 处）。 |
| P2-07 探活只拨 TCP | **已修（仅代码核对）** | 探活改 TLS 握手（`agent.go:probeIP`，InsecureSkipVerify 只证明对方会 TLS）。未动态验证（需真实解锁 IP）。 |
| P2-08 改节点也涨配置版本 | **已修** | 只有 IP/地区/enabled 变化才涨版本（`panel.go:handleNodeByID`）；改名/备注不涨。 |
| P2-09 面板挂了无人知 | **已修（仅代码核对）** | 面板失联超 60 秒打印“仍用旧规则”警告（`agent.go:pollLoop`）。未动态验证（需断面板 60 秒以上）。 |
| P2-10 文档与代码不一致 | **已修** | `/api/`、`/install.sh`、`/dl/` 均返回 `Cache-Control: no-store`（`main.go:107` 包装器 + panel 内两处）；README 已写 Go 1.24+。 |

### P3（6 条）：已修 4，部分修 1，未修 1

| 编号 | 结论 | 证据 / 说明 |
|---|---|---|
| P3-01 地区优先级漏 MO/IT | **部分修** | MO、IT 已补进 `RegionPriority`，但新加的 8 个地区（AT/DK/ES/FI/NO/NZ/PL/SE）没补；且 `RegionPriority` 全仓无任何引用，是死代码，补不补都不影响行为。 |
| P3-02 平台库双份源 | **未修（修复方已承认）** | `data/platforms.json` 与 `internal/panel/assets/platforms.json` 仍是两份，本轮 diff 验证内容完全一致。可以接受现状，但改库后必须两边同步，否则必分叉。 |
| P3-03 构建 Go 版本对不上 | **已修** | README 写 Go 1.24+，`go.mod` 为 go 1.24.0。 |
| P3-04 死代码 | **已修** | `proxyConn` 已删（grep 0 处）；`DefaultUnlockIP` 已有真实逻辑，不再是死代码。 |
| P3-05 自测链接过期 | **已修** | Netflix 自测链接已改为首页（`panel.go:unlockChecks`）。 |
| P3-06 测速 date +%s%N | **已修** | 脚本里已无 `date +%s%N`（只剩注释里提及）。注：无 python3 时 `pick_fastest_ip` 只返回第一个能通的 IP，并非真正“最快”，函数名言过其实。 |

## 新发现问题（修复引入 / 第一轮没发现）

### P0

#### N-01 install-panel.sh 最后一步必定失败，装完也报失败
- 位置：`scripts/install-panel.sh` [4/4] 检查段：`curl -fsS "http://127.0.0.1:$PORT/api/v1/status"`。
- 问题：`/api/v1/status` 需要登录（`panel.go:Handler` 用 `s.auth` 包着），未登录必回 401；`curl -f` 遇 401 退出码 22；脚本有 `set -euo pipefail`，管道失败即整个脚本退出。等于面板明明装好了、服务也起来了，脚本最后一步必定报错退出，永远打不出“安装完成”。
- 证据：本轮实测 `curl -fsS http://127.0.0.1:18081/api/v1/status` 未登录退出码 22；同一接口未登录返回 401。
- 修法：最后一步改成不鉴权的探活（例如 `curl -fsS http://127.0.0.1:$PORT/ | grep -q dnsunlock` 或直接 `systemctl is-active dnsunlock-panel`），不要拿要登录的接口当探活。

#### N-02 安装脚本要下载的分架构 sha256 文件不存在，一键安装走不通
- 位置：`scripts/install.sh`（`curl -fsSL "$PANEL_URL/dl/$BIN.sha256"`）、`scripts/install-panel.sh`（`curl -fsSL "$REPO/releases/latest/download/$BIN.sha256"`）；`dist/` 里只有合集 `dist/dnsunlock.sha256`。
- 问题：面板 `/dl/` 是按文件名直接读 `dist/` 目录的，`dnsunlock-linux-amd64.sha256` 与 `dnsunlock-linux-arm64.sha256` 两个文件都不存在。实测：`/dl/dnsunlock-linux-amd64.sha256` → 404，`/dl/dnsunlock-linux-arm64.sha256` → 404；两个安装脚本都用 `curl -f`，404 即退出，装不下去。就算改成下载合集文件也一样失败：合集里列了两个架构，在只装一个包的机器上 `sha256sum -c` 必报另一个架构缺失，实测 exit 1（`dnsunlock-linux-arm64: FAILED open or read`）。
- 影响：P0-01、P0-07 宣称的“一键安装 + sha256 强校验”在安装路径上是断的；Release 资产清单也必须跟着改，否则发了 Release 也装不上。
- 修法（二选一）：① 构建时同时生成 `dnsunlock-linux-amd64.sha256` 与 `dnsunlock-linux-arm64.sha256` 两个单文件并作为 Release 资产；② 脚本改取合集文件后只校验本架构那一行（`grep "$BIN" dnsunlock.sha256 | sha256sum -c -`）。① 更干净。

### P1

#### N-03 转发 DNS 缓存返回错误的交易 ID，重复查询会被客户端丢弃
- 位置：`internal/dnsagent/agent.go:forwardWithCache`——缓存的回应原样返回，未按当前查询改写 ID。
- 问题：DNS 客户端按交易 ID 认回应。第一次查 `example.com`（ID 0xAAAA）得到回应并被缓存；60 秒内第二次查同一域名（ID 0xBBBB）拿到的是缓存回应，里面还是 0xAAAA，客户端直接丢弃、等超时、重试、再丢弃，直到缓存过期。等于所有走上游转发的域名（即没有规则的绝大多数域名）在 60 秒窗口内重复查询基本查不到。
- 证据：本轮实测：`example.com A #1 qid=0xAAAA → respID=0xAAAA`；`#2 qid=0xBBBB → respID=0xAAAA`（应为 0xBBBB）；`example.com TXT` 不走缓存路径时 ID 正确。
- 修法：返回缓存回应前，把前两字节改写成当前查询的 ID（并注意缓存里存的回应本身不要被改坏，复制后再改）。

#### N-04 无效 allowlist 会静默变成公开解析器 / 公开代理
- 位置：`cmd/dnsunlock/main.go:runAgent/runProxy`（只看 allowlist 列表非空就放行）+ `internal/dnsagent/agent.go:New` / `internal/sniproxy/proxy.go:New`（解析失败的条目静默丢弃）。
- 问题：allowlist 写错一个字符（例如 `not-an-ip` 或 `192.168.1.0/33`），main 认为“填了”，agent/proxy 却一条有效规则都没解析出来，`allowed()` 回到“空 = 全部放行”。等于填错 = 没填，但没有任何报错。
- 证据：本轮实测：agent 用 `-allowlist "not-an-ip"` 启动，日志只打一行 WARNING“no DNS allowlist set”，随后 `netflix.com A` 查询照常得到回答（若 allowlist 有效且不含 127.0.0.1，应被拒绝）。
- 修法：启动时校验 allowlist 每一项（IP 或 CIDR），有一项非法就拒绝启动并指明是哪一项；`install.sh` 的 `valid_ip_cidr` 也要改成真校验（现在只是 `*.*.*.*` 花纹，`999.999.1.1` 都能过，IPv6 反被拒）。

#### N-05 SNI 的明文 HTTP :80 绕过了 fail-closed，等于一个公开 HTTP 代理
- 位置：`cmd/dnsunlock/main.go:runProxy`——`failClosedAllowlist` 只检查了 TLS 监听地址，HTTP 监听（默认 `:80`，即全部网卡）没检查。
- 问题：TLS 只听 127.0.0.1 时 fail-closed 放行，但 HTTP 代理仍在 `:80` 对全网开放，且 allowlist 为空时 `allowed()` 全放行。任何人只要能连上 80 端口，就能按任意 Host 头中继明文 HTTP 流量。
- 证据：本轮实测：`sni-proxy -listen 127.0.0.1:18443 -http :18080`（空 allowlist）正常启动；`ss` 显示 TLS 只在 `127.0.0.1:18443`，HTTP 在 `*:18080`；随后用本地 :80 的 HTTP 服务验证：经 `:18080` 发 `Host: example.com` 的请求，代理原样中继并返回了源站响应（即功能上就是公开代理）。
- 修法：对 HTTP 监听也做同样的 fail-closed 检查；更稳妥的是把 HTTP 默认改为空（禁用），只有明确指定才开。

### P2

#### N-06 “首次必须改密”服务端不强制，默认口令可一直用
- 位置：`internal/panel/panel.go:auth` 不检查 `AdminMustChange`；前端只在登录后 `alert` 一句（`index.html:154`）。
- 证据：本轮实测：admin/admin 登录返回 `must_change=true`，拿这个 session 调 `/api/v1/status` 返回 200，全套管理接口都能用。
- 修法：`auth` 里 `AdminMustChange` 为真时，除改密/退出接口外一律拒绝（或至少在登录响应里强制前端跳改密页且后端配合）。

#### N-07 登录锁可被伪造 X-Forwarded-For 绕过
- 位置：`internal/panel/panel.go:clientIP` 无条件信任 `X-Forwarded-For` 第一个值；`handleLogin` 按它限流。
- 证据：本轮实测：同一 IP 连续 5 次错密码后第 6 次 → 429；同一请求只加一个头 `X-Forwarded-For: 198.51.100.99`，立即回到 401（锁被绕过）。攻击者每次换个头就有无限次尝试。
- 修法：只在反代可信时才信任 XFF（例如 RemoteAddr 是 127.0.0.1/Caddy 时）；否则按 RemoteAddr 限流。注意面板常在 Caddy 后面，直接按 RemoteAddr 会把所有用户算成一个 IP，两种情况要分开处理。

#### N-08 agent token 仍可走 URL 查询串
- 位置：`internal/panel/panel.go:agentAuth`、`handleAgentWhoami`、`handleDownload` 都有 `r.URL.Query().Get("agent_token")` 的回退。
- 证据：本轮实测：`GET /api/v1/agent/config?server_id=…&agent_token=…` 返回 200；whoami 同样 200。FIX-REPORT“URL 里不再放 token”只改了 agent 客户端，服务端仍接受，token 会进面板访问日志与中间件日志。
- 修法：去掉查询串回退，只认 `X-Agent-Token` 请求头。

#### N-09 卸载会删掉用户本来就有的防火墙 53 规则
- 位置：`scripts/uninstall.sh`——`ufw delete allow 53/udp|tcp`、`firewall-cmd --permanent --remove-service=dns`。
- 问题：安装流程本身从不自动放行 53（这是对的），所以卸载时这些删除针对的是用户自己原先配的规则；一卸载，用户自己的 DNS 服务防火墙就被拆了。另：cloudflared 没清；Caddy 主配置里追加的 `import Caddyfile.d/*` 一行留下来了。
- 修法：只删安装时自己加过的规则（安装没加就不要删）；卸载清单补上 cloudflared 与 Caddy import 行的清理。

### P3

#### N-10 域名冲突提示里两个 IP 打码后无法区分
- 位置：`internal/panel/panel.go:domainConflict` 用 `maskIP` 拼提示。
- 证据：本轮实测 409 提示：“现有规则指向 203.0.*.*，新规则指向 203.0.*.*”——同网段的两个 IP 看起来一模一样，用户无法判断冲突双方。
- 修法：提示里改用节点名/地区（例如“现有规则指向 HK 节点 HK-1，新规则指向自定义 IP”），不要用打码 IP。

#### N-11 事件表未转义，失守的 agent 可向管理员浏览器注脚本
- 位置：`internal/panel/assets/index.html:273`（`eventsBody`）把 `e.from_node / e.to_node / e.reason` 直接拼进 innerHTML；`web/index.html` 同款。
- 问题：这些字段来自 agent 上报的心跳（`panel.go:handleHeartbeat` 原样存入 Events）。一台失守或被冒用的 agent 往事件里写 `<img onerror=…>`，管理员一打开事件页就会执行。节点名等其他字段已用 `esc()`，唯独事件表漏了。
- 修法：事件表四列也走 `esc()`。

#### N-12 凭证/敏感信息仍会出现在进程列表与命令行
- 位置：`scripts/install.sh:121`——SNI 服务的 `ExecStart` 把 `--allowlist` 明文写进启动命令（ps 可见，含客户端 IP 段）；`--token` 参数允许把 agent token 写进命令行（进 shell 历史）。
- 另：SNI 模式写进 `/etc/dnsunlock/config.json` 的配置（`install.sh:112`）从未被读取——`sni-proxy` 没有 `--config` 旗标，真正生效的是命令行里的 allowlist，配置与实际行为两张皮。
- 修法：SNI 也走 `--config` 配置文件（与 dns-agent 一致）；文档里去掉 `--token` 命令行用法，只保留交互输入。

## 仍未验证清单

1. **UDP DNS 路径**：沙箱禁一切 UDP 发送（连 loopback `sendto` 都返回 EPERM，本轮复测），agent 的 UDP 监听已绑定、与 TCP 共用 `handlePacket`（TCP 已验证），但 UDP 收包/回包未实跑——需真实 VPS 上 `dig @127.0.0.1 -p 53`（UDP 默认）验证。
2. **install-panel.sh / install.sh 真机全流程**：只做了 `bash -n` 与逻辑审查；未在真实 VPS 上跑（会改 80/443、装 systemd 服务、改本机 DNS）。且 N-01/N-02 已证明这两条脚本按当前写法在真机上也会在校验/收尾步骤失败——修好后必须在真机重跑。
3. **resolv.conf 接管/还原全流程**：代码已审，未在真实机器上跑（会改本机 DNS）；`chattr +i`、NetworkManager/dhclient/cloud-init/netplan 各分支只在脚本层面核对。
4. **真实流媒体解锁**：需真实解锁节点 + 真实 Netflix 等账号测试；本轮只验证到“DNS 返回解锁 IP / nameserver 转发到真实上游 IP”这一步。
5. **failover / failback 实况**：P1-06、P2-07、P2-09 的逻辑只在代码层面核对（30 秒探活循环、连续失败 2 次切换、主 IP 恢复切回、失联 60 秒警告），未在沙箱跑完时间线。
6. **EDNS 客户端行为**：OPT 记录仍不解析；`dig +edns` 的客户端在命中域名时拿到的回应不带 OPT，未实测其表现。
7. **Caddy 真实反代与自动 HTTPS**：本机无 caddy，`caddy validate` 未实跑；域名解析到机器、80/443 通、证书签发，全未验证。
8. **Release 公开下载流程**：Release 不存在，未验证；且 N-02 表明资产清单（单文件 sha256 还是分架构 sha256）必须先定下来再发。

## 核心链结论（四问，复核后）

- **会不会断网：仍会。** N-03（缓存错 ID）会让无规则域名的重复查询在 60 秒内查不到；N-01/N-02 让一键安装走不通；resolv.conf 接管/还原仍只在代码层面核对，未真机验证。
- **会不会漏 IP：比上一轮好，但仍有口子。** 列表打码与 token 分离是真的；但一台 agent 失守仍能看到全部全局规则 IP（P0-05 设计使然），token 仍可走 URL（N-08），默认口令可一直不改（N-06），锁可被 XFF 绕过（N-07）。
- **会不会被别人蹭用：仍有口子。** 主链路的 fail-closed 是真的，但无效 allowlist（N-04）与 SNI HTTP :80（N-05）两条绕过是新开的公开代理口子。
- **改错了能不能还原：比上一轮好。** panel.json 损坏恢复已动态验证通过；resolv.conf 还原只在代码层面核对，卸载删防火墙规则的问题见 N-09。

## 推仓库前必须做的事（按顺序）

1. 修 N-01（install-panel.sh 收尾探活不用鉴权接口）、N-02（生成分架构 sha256 文件并作为 Release 资产，或改脚本只校验本架构行）。
2. 修 N-03（缓存回应按当前查询改写交易 ID）、N-04（allowlist 启动时真校验，非法即拒启；install.sh 的校验改真）、N-05（HTTP 监听同样 fail-closed，或默认禁用 HTTP）。
3. 修 N-06（服务端强制首次改密）、N-07（XFF 只在可信反代时信任）、N-08（去掉 query 传 token）。
4. 修 N-09（卸载不删用户原有防火墙规则、补 cloudflared 清理）、N-11（事件表转义）、N-12（SNI 走配置文件）。
5. 上述修完后**重跑本轮的动态验证全套**（面板接口 + DNS TCP + 缓存 ID + 无效 allowlist + SNI 双监听 + install-panel.sh 收尾逻辑），再做第三轮审计或由用户确认。
6. 只有上述通过后，才 `git init`、提交、push 到 https://github.com/iiiiiiiii7125-art/dns-unlock-panel、打 tag、发 Release；发版后在真实 VPS 上验证安装全流程、UDP DNS、真实流媒体解锁（仍未验证清单 1/2/4/7）。

---

*第二轮审计结论：还不能推仓库。先修 N-01…N-06，再重验。*
