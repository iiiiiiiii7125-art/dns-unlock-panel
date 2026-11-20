# 修复报告 — DNS 分流解锁面板第三轮审计新问题（M-01…M-05）

- 依据：`audit/AUDIT-REPORT-3.md`（2026-11-20，结论：可以推仓库；新发现 5 条，全部 P3：M-01…M-05）
- 修复时间：2026-11-20（用户 16:56 CST 明确说“全修，且再次审计，整个功能实现的情况”后修复）
- 范围调整：用户 2026-11-20 16:58 CST 补充说明“只服务器安装，不需要cloudflare”——M-05 按此调整（见 M-05 一节）：不做 Cloudflare 双层反代的修法，只核对直连与单层 Caddy 两种部署，并注明 Cloudflare 双层反代本次不做、不支持。
- 代码：`~/workspace/dns-unlock-panel/`，本地修复，**未 push、未打 tag、未发 Release**
- 仓库：https://github.com/iiiiiiiii7125-art/dns-unlock-panel（公开、空）
- 结论：**M-01…M-05 全部 5 条已修并逐项复测通过**。复测：面板接口 30/30、DNS+M-03 19/19、M-04 沙箱演练 7/7、`go vet`/`go test` 通过、双架构重建 + 分架构 sha256 校验通过、`bash -n` 全部脚本通过。

## M-01…M-05 逐条

| 编号 | 问题 | 修复 | 证据 |
|---|---|---|---|
| M-01 (P3) | 种子默认规则自带域名冲突：`youtube → US` 与 `youtube-premium → HK` 共用 `youtube.com`，用户点保存任一条都拿 409 | 种子规则里 `youtube` 由 US 改为 HK，与 `youtube-premium` 同地区，两条规则解析到同一 IP，冲突检测不再触发。改动最小且与 agent 实际行为一致：agent 本来就按 Tier 先赢者定，youtube-premium（Tier 1）胜出，youtube.com 本来就走 HK。`youtu.be`（只有 youtube 有）不受影响，仍走 HK。种子里其他平台之间无共用域名。 | 实测（面板 18096，HK-1/US-1 两节点在册）：保存 youtube HK → 200、保存 youtube-premium HK → 200、再保存 youtube HK → 200；对照：保存 youtube US（不勾强制）→ 409，说明冲突检测本身仍在工作 |
| M-02 (P3) | 安装时 agent token 短暂出现在 curl 命令行（`install.sh:111/126` 的 `-H "X-Agent-Token: $TOKEN"`，ps 可见） | token 改走 curl 配置文件：安装脚本在 token 输入后写 0600 临时文件 `header = "X-Agent-Token: <token>"`，两次 curl（whoami、下二进制）改用 `curl -K "$AUTH_CFG"`；脚本退出时 trap 删掉该文件与 whoami 回包。token 是 hex 串，写进配置文件无需转义。两份 install.sh（`scripts/` 与面板内嵌 `internal/panel/assets/`）同步改动，diff 一致。全仓检查：其余 curl 调用（install-panel.sh 拉 GitHub Release、sha256 文件）本来就不带 token。 | 实测：curl -K 调 whoami → 200 且 server_id 一致；curl -K 下二进制 → 200，sha256 与分架构文件一致；慢速服务端实测：curl -K 传输期间 `ps -ef` 里 token 0 处，请求正常返回。旧写法 `curl -fsSL -H "X-Agent-Token` 全仓 0 处（只剩注释里一句旧写法说明，已改写避免 grep 误报） |
| M-03 (P3) | `--allowlist` 旗标仍在，手动调用仍可把 allowlist 写进进程列表；SNI 帮助文字仍写“empty = allow all”，与现行 fail-closed 不符 | 删掉 `dns-agent` 与 `sni-proxy` 的 `--allowlist` 旗标与 `DNS_ALLOWLIST` / `SNI_ALLOWLIST` 环境变量回退：allowlist 只走 600 配置文件（`--config` 里的 allowlist 项）。`usage()` 里的两行环境变量说明改为“已废弃”；`failClosedAllowlist` 的报错改为提示写配置文件；agent/sniproxy 里“Empty = allow all”的注释与启动警告改为 fail-closed 口径（库内空 allowlist 仍放行，但部署入口拒绝空 allowlist 非 loopback 启动）；两份 index.html 里教用户加 `--allowlist` 的安全提示改为写 600 配置文件；README 对应一处同步改。install.sh 本来就不向二进制传 `--allowlist`（一直走 `--config`），无需改。注意：install.sh 自身的 `--allowlist` 输入参数保留（那是安装脚本自己的输入项，默认走交互提示；与二进制旗标是两回事）。 | 实测：`dns-agent --allowlist x` / `sni-proxy --allowlist x` → rc=2（未知旗标）；`--help` 输出里 `--allowlist` 与 "empty = allow all" 均为 0 处；空 allowlist 配置 + 环境变量已设 + 非 loopback 监听 → 仍拒绝启动（环境变量不再生效）；有 allowlist 的配置文件 → 正常启动 |
| M-04 (P3) | 卸载脚本 `rm -rf /etc/cloudflared` 在 `if` 块之外，每次卸载都执行，会删掉用户为别的隧道自己装的 cloudflared 配置 | 加安装标记区分归属：`cloudflare-tunnel.sh` 装 tunnel 时留标记 `/etc/dnsunlock/cloudflared-by-dnsunlock`；`uninstall.sh` 只有在有标记时才清 cloudflared 服务与 `/etc/cloudflared`，无标记时一律不动并打印提示。另核对卸载脚本其余删除项：删的都是 dnsunlock 自己的东西（自家 systemd unit、自家 Caddyfile.d 文件、`/etc/dnsunlock`、自家二进制；面板数据只在 `--purge` 时删；Caddy import 行只在目录已空时删），无其他无条件删用户自有配置的地方。 | 沙箱演练（替身路径 + 假 systemctl/cloudflared）7/7：有标记 → 服务文件与配置目录都删掉；无标记 → 服务文件与配置目录都保留、打印“不碰它”提示，二进制仍正常删除。`rm -rf /etc/cloudflared` 现只在标记条件块内出现 |
| M-05 (P3) | 双层反代（Cloudflare → Caddy）下登录锁按 Cloudflare 出口 IP 计，一人输错 5 次会连累同出口用户 | **按用户补充说明调整修法，不做 Cloudflare 双层反代**：用户只服务器安装、不需要 Cloudflare，所以本次不加 CF-Connecting-IP 信任（该头直连 Caddy 即可伪造，信任它会把锁变回可伪造）。本次做的是核对 + 写明：直连面板时锁按 TCP 连接 IP 计（XFF 直接忽略）；单层 Caddy 反代（Caddy 与面板同机）时锁按 XFF 最后一个值计（N-07 原逻辑不变，代码未动）；双层反代（Cloudflare → Caddy → 面板）本版明确不支持——锁会按外层出口 IP 计，同出口用户共用一把锁。取舍写进代码注释（`panel.go:clientIP`）、DESIGN.md 安全设计、README 登录一节，并给 `TestClientIP` 加了一个用例把“双层反代下锁按出口 IP 计”这个已知行为钉死，防止日后悄悄改动信任模型。 | 实测（面板 18097）：直连错 5 次后第 6 次 → 429；伪造 CF-Connecting-IP（无 XFF）→ 仍 429（该头被忽略，躲不过锁）；XFF 最后一个值换成新 IP → 401（不同锁，各计各的）；XFF 只伪造第一个值、最后一个仍是被锁 IP → 仍 429。`go test` 8 个 clientIP 用例通过（含新增的双层反代用例） |

## 复测证据（沙箱本地，诚实记录）

- 面板接口 **30/30 通过**（`/tmp/dns-test4/m_test.py`）：登录/改密/旧密码失效、must_change 403、节点创建打码与非法 IP 400、M-01 三项 + 对照 409、服务器登记与 token 打码/reveal、M-02 curl -K whoami 与下载 sha256、query token 401、伪造心跳 403、panel.json 写坏后从 `.bak` 恢复登录成功、M-05 锁的四项行为、M-02 ps 无 token。
- DNS+M-03 **19/19 通过**（`/tmp/dns-test4/dns_test.py`，TCP 路径）：netflix A → 203.0.113.10、AAAA/TXT NODATA、RD 位按请求、缓存 ID 改写（0xAAAA/0xBBBB 各对）、改规则 HK→US 约 7 秒生效（→ 203.0.113.20）、nameserver 模式端到端返回真实 IP、M-03 旗标/帮助文字/环境变量忽略/配置文件启动 9 项。
- M-04 沙箱演练 **7/7 通过**（`/tmp/dns-test4/m04_test.sh`）。
- `go vet ./...`、`go test ./...` 通过（含新增 `TestClientIP` 第 8 个用例）；`bash scripts/build.sh` 双架构重建，amd64 `8a517a1a…`、arm64 `71fae23b…`，分架构与合集 sha256 全部校验通过；`bash -n` 7 个脚本通过；两份 install.sh diff 一致、两份 index.html diff 一致；重建后冒烟验证：面板首页含“600 配置文件”、不含 `--allowlist`，面板测试重跑 30/30。
- 密钥扫描：代码/脚本/前端/README/DESIGN 里 `xhj028` 0 处（仅 AUDIT-PENDING.md 的文字提及中有该字符串），`gho_/ghp_/github_pat_` 无命中；示例 IP 均为文档段。测试进程已全部清理。

## 没修的

- 无。M-01…M-05 全部修完。以下为此前已定性、保持不变的项：P3-02 平台库双份源（`data/platforms.json` 与 `internal/panel/assets/platforms.json`，两份 diff 一致，以 `data/platforms.json` 为准）；EDNS OPT 仍不解析；P0-05“agent 配置含全部全局规则 IP”是设计使然（agent 必须知道 IP 才能答 DNS）。

## 仍未验证的部分

UDP DNS 路径（沙箱禁一切 UDP，`sendto` 返回 EPERM）；install-panel.sh/install.sh 真机全流程（含 `systemctl is-active` 收尾探活、Caddy 安装分支）；resolv.conf 接管/还原真机；真实流媒体解锁；failover/failback 实况（仅代码核对）；EDNS 客户端行为；Caddy 真实反代与自动 HTTPS（本机无 caddy）；Release 公开下载（资产清单 5 个文件，需发版后在真机验证）。另：`cloudflare-tunnel.sh` 的标记写入与卸载清理只在沙箱演练层面验证，未在真机跑过 cloudflared。

## 建议

可以进入第四轮审计，重点是 M-01…M-05 的复核与本次新增的改动面（install.sh 的 curl -K 机制、allowlist 只走配置文件、卸载标记逻辑）；通过后再推仓库、打 tag、发 Release。
