# DESIGN.md — DNS 分流解锁面板设计

## 目标

akcdn 式无日志 DNS 复写系统：用户一次接入 DNS，后续分流规则全在面板管，改完约 5 秒生效。主用途：**社交媒体、流媒体、AI 服务**。单 Go 二进制 + 本地数据文件，任意 VPS 跑 `dnsunlock panel` 即可。

## 架构

```
用户设备 --DNS(53)--> dns-agent (VPS A) --轮询--> 面板 (任意 VPS, :8080)
   |                    |  命中平台域名 -> 返回解锁 IP
   |                    |  未命中 -> 转发上游 1.1.1.1 (UDP, 不通则 TCP 53 兜底)
   |                    v
   +--TLS(SNI)--> 解锁节点 IP (VPS B, 可选 sni-proxy :443) --> 真实源站 :443
   +--或 nameserver 模式--> 公共解锁源 DNS IP (Alice/AKDNS 等, 用户注册后填入)
```

三种运行模式，一个二进制：

| 模式 | 命令 | 说明 |
|---|---|---|
| 面板 | `dnsunlock panel` | Web 面板 + API + 静态前端，`:8080`，数据 `./data/panel.json` |
| DNS agent | `dnsunlock dns-agent` | DNS 服务 `:53`（UDP+TCP），每 5 秒轮询面板 |
| SNI 代理 | `dnsunlock sni-proxy` | 可选，`:443` 解析 SNI 转发，`:80` 按 Host 转发 |

## 数据模型

```go
Node            {id, name, ip, region(仅标签), port(默认443), enabled, status, latency_ms, note}
                // 只是 IP 记录：不要求在该机器装任何东西
Rule            {platform_id, node_id?, region?, custom_ip?, backup_ip?,
                 auto_failover?, mode(address|nameserver), nameserver?}
                // 解析顺序：node_id -> custom_ip -> region 自动选
                // auto_failover 只有用户明确开启才自动切备用 IP
DNSServer       {id, name, ip, token, default_unlock_ip(仅当规则存在但该地区无可用节点时作备用；无规则的平台不用它，仍走上游), status, last_seen, config_version}
FailoverEvent   {time, region, platform, from_node, to_node, reason, server_id}
PublicSourceIPs {source_id -> dns_ip}   // 用户注册公共源后自己填的 DNS IP
CustomDomains   {platform_id -> [domain...]}
Platform        {id, name, name_zh, category, regions_available, domains, tier}
```

- 平台库：`data/platforms.json`，169 个平台，7 类（流媒体 89 / 社交与娱乐 20 / AI 服务 20 / 日本专区 16 / 其他 15 / 台湾专区 6 / 香港专区 3），34 个地区（审计后补齐 AT/DK/ES/FI/NO/NZ/PL/SE）。分类对齐 AKDNS 六类（流媒体、AI 服务、日本专区、台湾专区、香港专区、社交与娱乐）+ 其他。
- 热度分级：Tier 1（12 个：Netflix、YouTube Premium、Disney+、ChatGPT、TikTok、Spotify、HBO Max、Claude、Gemini、Instagram、Prime Video、Hulu）→ Tier 2（27 个）→ Tier 3（地区专区 + 长尾）。规则表按 Tier、再按分类排序，不按字母序。
- 域名最小化（SukkaW/Surge 原则）：每平台 1–5 个真正做地域判定的核心域名；不收 `akamaihd.net` / `cloudfront.net` / `amazonaws.com` / `1e100.net` / `googlevideo.com` / `fbcdn.net` 等通用 CDN。缺的域名走自定义域名入口。
- 默认规则（首次启动种子）：Netflix→HK、Disney+→HK、ChatGPT→US、TikTok→US、Claude→US、Gemini→US、HBO Max→US、Hulu→US、Prime Video→US、Spotify→US、YouTube Premium→HK、DAZN→JP、Crunchyroll→US、BBC iPlayer→GB、Instagram→US、YouTube→HK。

## API 一览

三套凭证分开：① 管理 API 用登录 session（`X-Session-Token`，24 小时过期；登录失败 5 次锁 60 秒；X-Forwarded-For 只在直连方是本机反代时才信任，且取最后一个值——反代会把真实 IP 追加在末尾）；② agent 接口用每台服务器的 agent token（`X-Agent-Token` 头，URL 里不放 token）；③ `/dl/*` 需 ① 或 ②。`/install.sh` 公开但不含任何 token；`/dl/*.sha256` 公开。首次登录（`must_change=true`）的 session 在服务端被强制改密：除改密/退出外一切管理接口都拒绝。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/status` | 计数：节点/平台/规则/服务器在线数、配置版本 |
| GET | `/api/v1/regions` | 34 个地区 |
| GET | `/api/v1/platforms?q=&category=` | 平台库（搜索/分类） |
| GET/POST | `/api/v1/nodes` | 解锁 IP 记录 CRUD（PUT/DELETE `/api/v1/nodes/{id}`） |
| GET/PUT | `/api/v1/rules?server_id=` | 全局规则 + 单台服务器覆盖；PUT 改一条，配置版本 +1 |
| GET/POST | `/api/v1/servers` | DNS 服务器登记（DELETE `/api/v1/servers/{id}`） |
| GET | `/api/v1/events` | 故障切换记录（最新在前） |
| GET | `/api/v1/checks` | 解锁自测清单（15 项，手动核对方法，不做假检测） |
| GET/POST/DELETE | `/api/v1/custom-domains` | 每平台自定义域名 |
| GET/PUT | `/api/v1/public-sources` | 公共解锁源模板 + 用户填的 DNS IP |
| GET | `/api/v1/agent/config?server_id=`（头 `X-Agent-Token`） | agent 拉配置（只含本台服务器的规则，已解析成域名→IP） |
| POST | `/api/v1/agent/heartbeat?server_id=`（头 `X-Agent-Token`） | agent 上报探活状态 + 切换事件 + 计数器（body 的 server_id 必须与 token 对应，否则 403） |
| GET | `/install.sh` | 一键安装脚本（只 baked 面板地址，不含任何 token/私有 IP） |
| GET | `/dl/dnsunlock-linux-amd64[.sha256]` | 二进制分发（sha256 公开，binary 需登录 session 或 agent token；分架构 sha256 各只含本架构一行，见 scripts/build.sh） |

API 响应统一加 `Cache-Control: no-store`（Cloudflare 后也不被缓存）。

## DNS 流程

1. agent 启动时立即拉一次配置，之后每 5 秒轮询 `GET /api/v1/agent/config`，`version` 变了才重建域名表 → 规则改动 5 秒内生效。
2. 查询处理（UDP 与 TCP 都支持）：
   - 解析 DNS 问句（QDCOUNT=1，保留请求 RD 位；A/AAAA 以外类型对命中域名回 NODATA，对未命中域名转发上游原样回传；上游失败回 SERVFAIL，不静默无回应；UDP 缓冲 8192、TCP 上限 65535、UDP 并发信号量 256）。
   - 后缀匹配域名表（`www.netflix.com` → `netflix.com`）：命中且 `address` 模式 → 回 A 记录 = 解锁 IP，TTL 60；AAAA → NODATA（逼客户端走 IPv4 经解锁节点）。
   - 命中且 `nameserver` 模式 → 原包转发到规则指定的上游 DNS IP，答案原样回传。
   - 未命中 → 转发上游 `1.1.1.1:53`（备选 8.8.8.8）：先 UDP，失败自动走 **TCP 53 兜底**（沙箱/网络禁 UDP 时仍可用）；转发答案 60 秒小缓存（上限 512 条）。TCP 客户端连接总时限 15 秒（上游 UDP 3 秒 + TCP 3 秒的回退链不能被 5 秒掐断）。
3. 探活：每 30 秒对每个解锁 IP `:443` 做 **TLS 握手**探活（只拨通 TCP 不算数，3 秒拨号 + 5 秒握手时限），结果随 heartbeat 上报面板。失败只标红；**只有规则上明确开了 auto_failover 且填了 backup_ip，才在连续 2 次失败后切到备用 IP**（本机 override，面板配置不变，下次配置更新时以面板为准）；主 IP 恢复后自动切回并记一条事件。

## SNI 代理流程

1. 读首个 TLS 记录，解析 ClientHello 的 SNI（`server_name` 扩展）。
2. 拨 `SNI:443`，把已读的 ClientHello 原样发过去，双向透传字节。ClientHello 用 32K 缓冲读（分片大包不丢），整条连接 120 秒总时限（挂住的连接不永久占位）。
3. `:80` 按 HTTP `Host` 头拨 `Host:80` 透传。
4. 无 SNI（如 IP 直连）直接断开——这是正确的：没有名字就不知道往哪转。

## 安全设计

- **DNS 必须只对自己人开放**：任何能用你 DNS 的人用 `dig` 就能看到返回的解锁 IP。agent 与 SNI 代理的 allowlist 为空且监听非 loopback 时**拒绝启动**（P0-04），只听 127.0.0.1 时才放行本机测试；安装脚本不主动放行防火墙 53。
- **私有 IP 防泄露**：面板列表默认打码（`1.2.*.*`），点“显示”才单独调接口取完整 IP；未登录的 `/install.sh` 不含任何 token/私有 IP；`/dl/*` 需登录 session 或 agent token；agent 配置接口只返回该台机器的规则（全局规则 + 本机覆盖），心跳 body 的 server_id 必须与 token 对应。
- **公共源不硬编 IP**：模板只有名称/官网/免费额度/覆盖地区，DNS IP 由用户注册后自己填。
- **无日志**：DNS/SNI 路径不记录 qname、SNI、客户端 IP；只有聚合计数。代码里可用 `grep -rn "qname\|SNI" internal/dnsagent internal/sniproxy` 自查（除解析函数本身外无日志调用）。
- **登录防暴力破解的锁按谁计（M-05）**：只支持两种部署——① 直连面板（浏览器直接连 `:8080`）：锁按 TCP 连接 IP 计，X-Forwarded-For 直接忽略（直连时该头可伪造）；② 单层 Caddy 反代（Caddy 与面板同机）：锁按 XFF 最后一个值计，Caddy 会把真实客户端 IP 追加在末尾。双层反代（例如 Cloudflare → Caddy → 面板）本版**不支持**：XFF 最后一个值会是外层出口 IP，同出口用户共用一把锁，一人输错 5 次会连累同出口的其他人；本版也不加 CF-Connecting-IP 信任（直连 Caddy 即可伪造该头躲锁）。本次使用范围只有服务器安装，不用 Cloudflare。

## Cloudflare（可选入口）与 Workers 对比

- 首选：面板本体仍跑在 VPS 上（Go 单体不变），用 Cloudflare Tunnel（`scripts/cloudflare-tunnel.sh`）或 Cloudflare DNS 代理做入口；`/api/*`、`/install.sh`、`/dl/*` 必须 Bypass cache。
- 纯 Workers 方案：Workers 跑不了 Go 常驻进程 + 本地文件存储，要重写后端为 Workers + D1/KV；不作为 v1。

## 局限

- 无 SNI 的老设备（旧 Chromecast/PS3/部分电视）走不了 SNI 解锁。
- sniproxy 需占用 80/443。
- 面板只做 DNS 复写，不凭空让任意 IP 具备解锁能力。

## 经典栈对照（实现参考，非照搬）

dnsmasq/SmartDNS + sniproxy + Docker（ab77/netflix-proxy、myxuchangbin/dnsmasq_sniproxy_install、lthero-big/Smartdns_sniproxy_installer）是同一思路的经典实现；本项目用 Go 单二进制替代这套组合。域名库以 proxy-domains.txt 为参考源之一，但按最小化原则精简；解锁检测思路参考 yt1988/unlock-check 与 RegionRestrictionCheck。完整来源见 REFERENCES.md。
