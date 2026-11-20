# DNS 分流解锁面板 — 整个功能实现情况汇总

- 汇总时间：2026-11-20（第四轮审计后）
- 代码：`~/workspace/dns-unlock-panel/`，本地，未 push、未打 tag、未发 Release；公开空仓库 https://github.com/iiiiiiiii7125-art/dns-unlock-panel 仍是空的
- 依据：四轮审计报告 `audit/AUDIT-REPORT.md`、`AUDIT-REPORT-2.md`、`AUDIT-REPORT-3.md`、`AUDIT-REPORT-4.md`，三份修复报告 `audit/FIX-REPORT.md`、`FIX-REPORT-2.md`、`FIX-REPORT-3.md`，设计 `DESIGN.md`，以及本轮动态验证（面板接口 + DNS TCP 31/31、M-02 ps 实测、M-04 卸载演练 9/9、`go vet`/`go test`、双架构重建哈希与修复报告一致）
- 状态口径：**已实现并验证** = 代码在 + 沙箱动态验证通过；**已实现未验证** = 代码在，沙箱验不了（需真实 VPS）或本轮未重跑；**未实现** = 代码里没有。不要把“已实现未验证”读成“已验证”。

## 总结论

功能按用户最初的要求基本都实现了，沙箱能验证的部分全部通过（第四轮：面板 + DNS 31/31、M-02/M-04 专项全过），第四轮审计结论是**可以推仓库**。但“全链路已验证”还不是事实：UDP DNS、安装脚本真机全流程、Caddy 真实反代与自动 HTTPS、真实流媒体解锁、failover 实况这 5 项只能在真实 VPS 上补验，发版后补验通过前不要对外宣称全链路已验证。

## 1. 面板管理

| 需求（用户最初的要求） | 状态 | 证据 |
|---|---|---|
| 169 个平台、34 个地区 | 已实现并验证（数据层面） | `data/platforms.json` 实测 169 个，7 类（流媒体 89 / 社交与娱乐 20 / AI 服务 20 / 日本专区 16 / 其他 15 / 台湾专区 6 / 香港专区 3）；`internal/model/model.go:Regions` 34 个地区，无重复 |
| 按网友爱用的东西排序，不按字母序 | 已实现（代码核对） | `model.go:Tier1` 12 个（Netflix、YouTube Premium、Disney+、ChatGPT、TikTok、Spotify、HBO Max、Claude、Gemini、Instagram、Prime Video、Hulu）、Tier2 27 个；`handleRules` 按 Tier 再按分类排序。排序行为本身未在动态验证中单独核对 |
| 社交媒体、流媒体、AI 服务三类为主 | 已实现（数据层面） | 上述 7 类中前三类共 129 个平台；种子默认规则覆盖 Netflix/Disney+/ChatGPT/TikTok/Claude/Gemini/HBO Max/Hulu/Prime Video/Spotify/YouTube Premium/Instagram/YouTube/DAZN/Crunchyroll/BBC iPlayer |
| 规则改完立即生效 | 已实现并验证 | agent 每 5 秒轮询面板配置；本轮实测改规则约 7 秒内生效（netflix HK `203.0.113.10` → US `203.0.113.20`） |
| 解锁节点只是一条 IP 记录，随便填任意 IP，不用在那台机器装东西 | 已实现并验证 | 本轮建节点 HK-1 `203.0.113.10`、US-1 `203.0.113.20` 成功；节点只是 IP 记录（DESIGN.md 数据模型） |
| 每条规则可选手填自定义 IP / 选已有 IP | 已实现（代码核对） | Rule 有 `node_id` / `custom_ip` / `region` 三种解析顺序；自定义 IP 有格式校验（非法 IP → 400，前轮验证） |
| 自定义域名入口 | 已实现，前轮验证，本轮未重跑 | 自定义域名校验（`com` → 400，见第一轮 P1-04 修复与复核）；本轮未重跑该项 |
| 公共解锁源（Alice/AKDNS 等）可选、模板化，不硬编公共解锁 IP | 已实现（代码核对） | `model.go` 公共源模板只有名称/官网/免费额度/覆盖地区；代码里无硬编的公共解锁 IP；规则用 nameserver 模式走用户自己填的 DNS IP |
| 默认解锁 IP 的语义写清楚 | 已实现（文档 + 代码） | 只在“规则存在但该地区无可用节点”时作备用，无规则平台不用它；语义写进 DESIGN.md 与代码注释；该行为本身未单独动态验证 |
| DNS 服务器登记、每台服务器单独 token | 已实现并验证 | 本轮登记服务器一次性返回 token；agent 配置用头取回 200，用 query 传 token 401 |
| 域名冲突要提示，不要悄悄覆盖 | 已实现并验证 | 本轮保存 youtube US（与 youtube-premium HK 共用 youtube.com）→ 409，提示报节点名；种子规则冲突已消除（M-01），保存 youtube/youtube-premium HK 均 200 |

## 2. DNS 解锁

| 需求 | 状态 | 证据 |
|---|---|---|
| address 模式：DNS 直接返回解锁 IP | 已实现并验证 | 本轮 `netflix.com A` → `203.0.113.10`（TCP 路径） |
| nameserver 模式：该平台查询转发到指定上游 DNS | 已实现并验证 | 本轮 netflix 指向上游 1.1.1.1 后返回真实 IP 207.45.73.1 / 207.45.72.1 |
| SNI 代理（可选解锁节点，:443 解析 SNI 转发） | 已实现，部分验证 | `internal/sniproxy` 代码在，`go test` 通过；本轮只验证了 fail-closed（空 allowlist 拒启 rc=1、HTTP 拦截）；SNI 端到端转发本轮未重跑（首轮/MVP 做过端到端） |
| AAAA 回 NODATA（逼客户端走 IPv4 经解锁节点） | 已实现并验证 | 本轮 netflix AAAA → NODATA（AN=0） |
| 未命中域名转发上游（1.1.1.1，备选 8.8.8.8），TCP 兜底 | 已实现并验证 | 本轮 example.com 经上游返回真实 IP；缓存 ID 改写实测 0xAAAA/0xBBBB 各对 |
| 健康检查：TLS 握手探活，失败只标红；备用切换只有明确开启才切 | 已实现未验证 | 代码在（DESIGN.md DNS 流程第 3 条：每 30 秒 TLS 握手探活，auto_failover 且填 backup_ip 时连续 2 次失败才切，主 IP 恢复自动切回并记事件）；从未跑完时间线动态验证 |
| allowlist：只对自己人开放 DNS/SNI | 已实现并验证 | 空 allowlist + 非 loopback 拒绝启动（DNS 与 SNI HTTP 均实测 rc=1）；allowlist 只走 600 配置文件，`--allowlist` 旗标与环境变量回退已删（M-03，本轮实测 rc=2 / rc=1） |
| UDP DNS | 已实现未验证 | 代码监听 UDP，与 TCP 共用 `handlePacket`；沙箱禁一切 UDP 发送，UDP 收包/回包从未实跑，需真实 VPS 验证 |
| EDNS（OPT 记录） | 未实现 | 代码不解析 OPT；`dig +edns` 的客户端行为未实测 |

## 3. 安装部署（只服务器安装，不需要 Cloudflare）

| 需求 | 状态 | 证据 |
|---|---|---|
| 面板任意服务器部署：单二进制 + 本地数据文件，不强制 Docker、不强制 Cloudflare | 已实现（设计 + 代码） | `dnsunlock panel` 单二进制 + `panel.json`；Cloudflare Tunnel 只是 `scripts/cloudflare-tunnel.sh` 提供的可选入口，不是必需品（用户 2026-11-20 16:58 CST 确认只服务器安装，不需要 Cloudflare） |
| 面板一键安装 + 填域名自动 Caddy 反代 + 自动 HTTPS | 已实现未验证（真机） | `scripts/install-panel.sh` 存在，`bash -n` 通过；收尾探活已修（N-01：`systemctl is-active` + 不鉴权首页）；域名/端口校验、80/443 被占提示退出均在代码里；Caddy 安装分支、`caddy validate`、证书签发、真机全流程均未验证 |
| DNS 一键安装（`curl …/install.sh \| bash`） | 已实现未验证（真机） | `scripts/install.sh` 与面板内嵌版 diff 一致；装前基线测试（whoami 校验 token）、sha256 强校验（下不到就停）、token 只进 600 配置文件（M-02：curl -K，ps 实测无 token）、装后验证均在代码里；真机全流程未跑过 |
| 解锁节点可选安装（`--unlock-node` / install-unlock-node.sh） | 已实现未验证（真机） | 脚本与分支存在；真机未跑过 |
| 卸载 + 系统 DNS 还原 | 部分验证 | 卸载脚本存在；M-04 标记制本轮沙箱演练 9/9 通过（无标记不动用户自有 cloudflared、有标记才清、默认保留面板数据）；resolv.conf 接管/还原（`chattr +i`、NetworkManager/netplan 等分支）只在代码层面核对，未真机验证 |
| Release 资产（双架构二进制 + 分架构 sha256） | 已实现未验证（发版） | `scripts/build.sh` 生成 5 个文件；本轮重建哈希与 FIX-REPORT-3 声称完全一致（amd64 `8a517a1a…`、arm64 `71fae23b…`），`sha256sum -c` 通过；Release 本身不存在，公开下载未验证 |

## 4. 安全

| 需求 | 状态 | 证据 |
|---|---|---|
| 面板登录 admin/admin，首次登录必须改密 | 已实现并验证 | bcrypt 哈希存；本轮登录 admin/admin → `must_change=true`，改密 → 200，旧密码 → 401；must_change 的 session 除改密/退出外一律 403（前轮动态验证，本轮改密流程重验通过） |
| 三套口令分开（面板 session / 每台 agent token / 下载） | 已实现并验证 | 代码分开；伪造心跳 body server_id 不符 → 403（前轮验证）；agent token 只认 `X-Agent-Token` 头，query 传 token → 401（本轮验证）；安装时 token 不进命令行/ps（M-02，本轮实测） |
| 列表接口默认打码，完整 IP 单独 reveal | 已实现并验证 | 本轮节点创建与列表均返回 `203.0.*.*` |
| 白名单默认拒绝，不做公开解析器/公开代理 | 已实现并验证 | 见第 2 节 allowlist；安装脚本不自动放行防火墙 53 |
| 登录防暴力破解（5 次错锁 60 秒），锁的 key 讲清楚 | 已实现并验证 | 本轮直连 5 次错密码后第 6 次 → 429；伪造 `CF-Connecting-IP` → 仍 429（该头被忽略）；XFF 只在直连方是本机反代时信任且取最后一个值；双层反代（Cloudflare → Caddy）本版明确不支持（M-05，DESIGN.md 与代码注释一致，用户范围：只服务器安装，不用 Cloudflare） |
| 无日志（DNS/SNI 不记查询域名、SNI、客户端 IP） | 已实现（代码核对） | DESIGN.md 安全设计；未逐行审计全部日志调用 |
| 公开仓库零敏感信息 | 已实现并验证（本地） | 代码/脚本/前端/README/DESIGN 里 `xhj028` 0 处，`gho_`/`ghp_`/`github_pat_` 无真实命中，示例 IP 均为文档段；但仓库仍是空的，未推 |
| 卸载不删用户自有东西 | 已实现，部分验证 | 防火墙规则不删（安装本身不加）；cloudflared 标记制本轮演练通过；残留 Q-01（已有自有 cloudflared 隧道又跑 tunnel 脚本时，配置会被覆盖且卸载会整目录删） |

## 5. 已知未实现 / 未验证的项（汇总）

| 项 | 类别 | 说明 |
|---|---|---|
| UDP DNS 路径 | 未验证 | 沙箱禁 UDP，需真实 VPS `dig`（UDP 默认）验证 |
| install-panel.sh / install.sh 真机全流程 | 未验证 | 含 `systemctl is-active` 收尾探活、Caddy 安装分支 |
| resolv.conf 接管/还原真机 | 未验证 | 只在代码层面核对 |
| 真实流媒体解锁 | 未验证 | 需真实解锁节点 + 真实账号；只验证到“DNS 返回解锁 IP”这一步 |
| failover / failback 实况 | 未验证 | 只在代码层面核对，未跑完 30 秒探活时间线 |
| EDNS 客户端行为 | 未实现 + 未验证 | OPT 不解析 |
| Caddy 真实反代与自动 HTTPS | 未验证 | 本机无 caddy，`caddy validate` 未实跑；域名解析、80/443 通、证书签发全未验证 |
| Release 公开下载 | 未验证 | Release 不存在；资产清单已定（5 个文件），发版后需在真实 VPS 按清单验证 |
| cloudflared 标记写入与卸载清理真机 | 未验证 | 只在沙箱演练层面验证 |
| 平台库双份源（P3-02） | 已知未改（定性） | `data/platforms.json` 与 `internal/panel/assets/platforms.json` 两份内容 diff 一致，以 `data/platforms.json` 为准；改成构建时复制属构建重构，风险大于收益 |
| Q-01…Q-03（第四轮新发现，全部 P3） | 已修并验证（2026-11-20，用户 19:01 CST 选“先修 Q-01…Q-03 再推”后修复） | Q-01：tunnel 脚本已有用户自有 config.yml 时默认停下不覆盖，明确确认时先备份再覆盖并记进 key=value 标记，卸载只删本面板新建的、覆盖过的从备份恢复（沙箱演练 9 场景 38/38）；Q-02：usage 里已废弃的 DNS_ALLOWLIST/SNI_ALLOWLIST 彻底去掉，新编二进制 usage 输出 0 处；Q-03：DESIGN 种子 YouTube→HK（去重）、AI 服务 19→20、model.go 注释 26→34 个地区，其余数字核对无漂移。修复报告 `audit/FIX-REPORT-4.md` |
| agent 配置含全部全局规则 IP（P0-05） | 设计使然，接受现状 | agent 必须知道 IP 才能答 DNS；一台 agent 失守仍会漏出全部全局解锁 IP |

## 6. 四轮审计脉络（供对照）

- 第一轮（38 条：P0 7 / P1 15 / P2 10 / P3 6）：结论不建议发版。
- 第一轮修复：37/38 已修（P3-02 平台库双份源未改，已定性）。
- 第二轮：19 条全修、18 条部分修、1 条未修；新发现 N-01…N-12（P0 2 / P1 3 / P2 4 / P3 3）：结论还不能推。
- 第二轮修复：N-01…N-12 全修，复测面板 32/32、DNS+SNI 23/23。
- 第三轮：N-01…N-12 全修确认（12/12），无新的 P0/P1；新发现 M-01…M-05（全部 P3）：结论可以推仓库。
- 第三轮修复：M-01…M-05 全修，复测面板 30/30、DNS+M-03 19/19、M-04 演练 7/7。
- 第四轮（本轮）：M-01…M-05 全修确认（5/5），无新的 P0/P1/P2；新发现 Q-01…Q-03（全部 P3）：结论可以推仓库。
