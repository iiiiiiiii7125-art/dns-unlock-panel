# DNS 分流解锁面板 — 第四轮审计报告（独立复核）

- 审计对象：`~/workspace/dns-unlock-panel/`（M-01…M-05 修复后状态，2026-11-20 用户 16:56 CST 说“全修，且再次审计”后复核；用户 16:58 CST 补充“只服务器安装，不需要cloudflare”，M-05 已按此范围调整）
- 对照材料：第三轮 `audit/AUDIT-REPORT-3.md`（结论可以推仓库；新发现 5 条全部 P3：M-01…M-05）；第三轮修复 `audit/FIX-REPORT-3.md`（声称 M-01…M-05 全部修完，面板接口 30/30、DNS+M-03 19/19、M-04 演练 7/7）；第一轮 `audit/AUDIT-REPORT.md`、第二轮 `audit/AUDIT-REPORT-2.md` 与修复 `audit/FIX-REPORT.md`、`audit/FIX-REPORT-2.md`；待审清单 `AUDIT-PENDING.md`；设计 `DESIGN.md`
- 审计方式：只审计、不改代码、不 push、不打 tag、不发 Release。逐条读代码核对修复是否真实落地（文件+行号/关键片段见下表），并重跑动态验证：`go vet`、`go test`、重建 amd64+arm64 并 `sha256sum -c`（含分架构 sha256）、`bash -n` 全部脚本、面板接口、DNS TCP 路径、M-02 的 ps 实测、M-04 的沙箱卸载演练。**没有下载、没有运行任何第三方安装脚本**（包括 AKDNS 的），只用其公开文档对照。
- **结论先说：可以推仓库。** M-01…M-05 全部 5 条经代码核对与动态验证确认已修（5/5），未发现新的 P0/P1/P2。本轮新发现 3 条，全部是 P3（见“新发现问题”），都不拦推仓库。但**推仓库 ≠ 全链路已验证**：UDP DNS、安装脚本真机全流程、Caddy 真实反代与自动 HTTPS、真实流媒体解锁、failover 实况这 5 项在沙箱里无法验证，必须在推仓库、发 Release 后在真实 VPS 上补验，补验通过前不要对外宣称“全链路已验证”（见“仍未验证清单”与“推仓库前必须做的事”）。整个功能实现情况见 `audit/FEATURE-STATUS.md`。

## 汇总

| | 数量 |
|---|---|
| 第三轮 M-01…M-05 中：已修 | 5（P3 5） |
| 第三轮 M-01…M-05 中：部分修 / 未修 | 0 |
| 本轮新发现问题 | P0 0 / P1 0 / P2 0 / P3 3，共 3 条（Q-01…Q-03） |
| 前三轮遗留的已知未实现项 | EDNS OPT 仍不解析；P3-02 平台库双份源仍在（两份内容 diff 一致）；P0-05“agent 配置含全部全局规则”是设计使然（agent 必须知道 IP 才能答 DNS），接受现状 |

## 动态验证结果（本轮实测，沙箱本地）

- `go vet ./...` 通过；`go test ./...` 通过（含 `TestClientIP` 8 个用例，`-count=1` 重跑通过；dnsagent/model/store 无测试文件）。Go 1.25.1 工具链，`go.mod` 为 go 1.24.0。
- `bash scripts/build.sh` 重建：amd64 `8a517a1a…`、arm64 `71fae23b…`，与 FIX-REPORT-3 声称的哈希**完全一致**，分架构与合集 `sha256sum -c` 全部通过；两个包均为静态链接 ELF，架构正确。`bash -n`：8 个脚本（含面板内嵌 install.sh）全部通过。
- 面板接口 + DNS TCP（`/tmp/dns-audit4/panel_dns_test.py`，本轮新写）：**31/31 通过**：
  - 登录 admin/admin 成功，`must_change=true`；must_change 的 session 先改密才能用管理接口（改密 → 200，旧密码再登录 → 401，新密码 → 200）。
  - 节点创建 IP 打码（`203.0.*.*`）；节点列表打码。
  - M-01：保存 youtube HK → 200、保存 youtube-premium HK → 200；对照保存 youtube US（不勾强制）→ 409，提示含节点名（“现有规则指向 节点 HK-1（HK），新规则指向 节点 US-1（US）”），冲突检测本身仍在工作。
  - 服务器登记一次性返回 token；agent 配置用 `X-Agent-Token` 头 → 200，用 `?agent_token=` → 401。
  - DNS TCP：`netflix.com A` → `203.0.113.10`；AAAA → NODATA（AN=0）；缓存 ID 改写（example.com 第一查 qid 0xAAAA → resp 0xAAAA，第二查 qid 0xBBBB → resp 0xBBBB，两次拿到同一组上游真实 IP）；改规则 HK→US 约 7 秒内生效（→ `203.0.113.20`）；nameserver 模式端到端（netflix 指向上游 1.1.1.1 后返回真实 IP 207.45.73.1 / 207.45.72.1，不是解锁 IP）。
  - M-05：直连连续 5 次错密码后第 6 次 → 429；伪造 `CF-Connecting-IP` → 仍 429（该头被忽略）；XFF 最后一个值换成新 IP → 401（不同锁，各计各的）；只伪造 XFF 第一个值、最后一个仍是被锁 IP → 仍 429。
- M-02 ps 实测（`/tmp/dns-audit4/m02_test.py`）：慢速服务端（4 秒延迟）传输期间 `ps -ef` 里 token 出现 0 次，服务端收到的 `X-Agent-Token` 头正确，curl 退出 0。
- M-04 沙箱卸载演练（`/tmp/dns-audit4/m04_test.sh`，路径替换 + stub systemctl/cloudflared）：**9/9 通过**——无标记时用户自有 cloudflared 配置目录与服务文件均保留并打印“不碰它”提示、二进制仍正常删除；有标记时配置目录与服务文件均删除且调了 `cloudflared service uninstall`；默认保留面板数据，`--purge` 才删。
- M-03 CLI 实测：`dns-agent --allowlist x` 与 `sni-proxy --allowlist x` 均 rc=2（未知旗标）；`--help` 输出里 `--allowlist` 与 "empty = allow all" 均为 0 处；`DNS_ALLOWLIST` 环境变量已设 + 空 allowlist 配置 + 非 loopback 监听 → 仍 rc=1 拒绝启动（环境变量不再生效）；SNI TLS loopback + HTTP `:18080` 空 allowlist → rc=1 拒绝启动；`dns-agent --token x` → rc=2。
- 密钥扫描：代码/脚本/前端/README/DESIGN 里 `xhj028` 0 处（仅 AUDIT-PENDING.md 的文字提及中有该字符串）；`gho_`/`ghp_`/`github_pat_` 无真实命中（仅 AUDIT-PENDING.md 里写明的 pattern 名称本身）；示例 IP 均为文档段。两份 install.sh diff 一致，两份 index.html diff 一致，两份 platforms.json diff 一致。
- 本轮复核中**证实为真**的修复声明：种子规则冲突消除且冲突检测仍在工作（M-01）；curl -K 传 token 且 ps 无 token（M-02）；allowlist 只走 600 配置文件（M-03）；卸载标记制（M-04）；M-05 按“只服务器安装，不需要 Cloudflare”取舍并写明（见下表）。

## 逐条复核表（M-01…M-05）

| 编号 | 结论 | 证据 / 说明 |
|---|---|---|
| M-01 (P3) 种子默认规则自带域名冲突 | **已修** | `internal/panel/panel.go:seedDefaults`（约 267–290 行）：`youtube` 由 US 改为 HK，与 `youtube-premium` 同为 HK；注释写明两条规则共用 youtube.com、必须指同一地区。动态验证：保存 youtube HK → 200、保存 youtube-premium HK → 200、保存 youtube US → 409（冲突检测仍在）。另用 `data/platforms.json` 全量核对：7 条共用域名中，种子规则涉及的平台对（youtube/youtube-premium、chatgpt/chatgpt-plus、dazn/daznjp、netflix/netflix-jp-anime、openai.com 三方）全部同地区；`resolveIP`（panel.go:305–333）对 region 规则取区内第一个在线节点，两条同地区规则解析到同一 IP，不会触发冲突。种子规则只在无规则时写入一次，老用户已有规则不受影响。残留见 Q-03（DESIGN.md 的种子清单仍写 YouTube→US，与代码不一致）。 |
| M-02 (P3) 安装时 token 进 curl 命令行 | **已修** | `scripts/install.sh:109–136` 与面板内嵌 `internal/panel/assets/install.sh`（diff 一致）：token 输入后写 `mktemp` 的 0600 临时文件（`header = "X-Agent-Token: ..."`），whoami（:120）与下载二进制（:135）两次 curl 均改用 `curl -K "$AUTH_CFG"`；`trap ... EXIT` 删临时文件与 whoami 回包。动态验证：慢速传输期间 ps 里 token 0 处，服务端收到正确的头。旧写法 `curl -fsSL -H "X-Agent-Token` 全仓 0 处（只剩注释里一句旧写法说明）。全仓检查：其余 curl 调用（install-panel.sh 拉 GitHub Release、sha256 文件、install-unlock-node.sh 下 install.sh）本来就不带 token。微残留（不单独立项）：`trap` 设在 `printf` 写 token 之后一行，中间窗口可忽略；AUTH_CFG 文件路径本身会进 ps，但路径里不含 token（FIX-REPORT-3 已写明）。 |
| M-03 (P3) `--allowlist` 旗标仍在、SNI 帮助文字过时 | **已修** | `cmd/dnsunlock/main.go:runAgent`（约 157–162 行）与 `runProxy`（约 238–243 行）：`--allowlist` 旗标已删，注释写明只走 600 配置文件；allowlist 只从 `--config` 文件的 `allowlist` 项读（`allow := ""` 起始，不读环境变量）；`usage()` 里 `DNS_ALLOWLIST` / `SNI_ALLOWLIST` 两行标为“已废弃”。动态验证：两处 `--allowlist` 均 rc=2；`--help` 里 `--allowlist` 与 "empty = allow all" 均为 0 处；环境变量已设仍 rc=1 拒启。install.sh 自身的 `--allowlist` 输入参数保留（:82）——那是安装脚本自己的输入项，写进 600 配置文件，不传给二进制；两处 `ExecStart` 均只带 `--config`（install.sh:159/217）。库内注释（agent.go:40、proxy.go:27）仍写 "Empty = allow all inside this library"，但后半句已是 fail-closed 口径（“部署的二进制拒绝空 allowlist 非 loopback 启动，生产不要依赖空值”），与 M-03 投诉的 CLI 帮助文字不是同一处；CLI 帮助本身已干净。残留见 Q-02（usage 里仍列出已废弃的环境变量名）。 |
| M-04 (P3) 卸载无条件删 `/etc/cloudflared` | **已修** | `scripts/cloudflare-tunnel.sh:47–51`：装 tunnel 末尾 `mkdir -p /etc/dnsunlock && touch /etc/dnsunlock/cloudflared-by-dnsunlock` 留标记；`scripts/uninstall.sh:33–41`：只有有标记时才 `cloudflared service uninstall` + 删服务文件 + `rm -rf /etc/cloudflared`，无标记时一律不动并打印提示（elif 分支检测到 cloudflared 服务存在时提示“疑似用户自有配置，本次卸载不碰它”）。动态验证：沙箱演练 9/9（无标记保留、有标记删除、`--purge` 行为均正确）。残留见 Q-01（标记只记录“tunnel 脚本跑过”，不记录“此前有无自有 cloudflared”）。 |
| M-05 (P3) 双层反代下登录锁按出口 IP 计 | **已修（按用户范围调整）** | 用户 2026-11-20 16:58 CST 明确“只服务器安装，不需要cloudflare”，本次不做 Cloudflare 双层反代修法（与 FIX-REPORT-3 的范围调整一致）。核对 + 写明三处一致：① 代码注释 `internal/panel/panel.go:clientIP`（约 379–396 行）：只支持直连（锁按 TCP 连接 IP，XFF 直接忽略）与单层 Caddy 反代（锁按 XFF 最后一个值）；双层反代（Cloudflare → Caddy → 面板）本版**不支持**，锁会按外层出口 IP 计；不加 `CF-Connecting-IP` 信任（直连 Caddy 即可伪造该头躲锁）。② `DESIGN.md:93` 同样写明两种部署与不支持声明。③ `TestClientIP` 第 8 个用例把“双层反代下锁按出口 IP 计”钉死（panel_test.go:24–29），`go test -run TestClientIP -count=1` 8 个用例通过。动态验证：直连 5 次错密码后第 6 次 → 429；伪造 `CF-Connecting-IP` → 仍 429（该头被忽略）；XFF 最后一个值换新 IP → 401。代码里 `CF-Connecting-IP` 只出现在注释中，无任何信任逻辑。 |

## 回归复核（前三轮关键修复，本轮重验通过）

| 项 | 本轮结果 |
|---|---|
| 登录 admin/admin + 首次强制改密（P0-02/N-06） | 通过：must_change session 改密 → 200，旧密码 → 401 |
| 列表打码（P0-05） | 通过：节点创建与列表均返回 `203.0.*.*` |
| query token 拒绝（N-08） | 通过：config 用 `?agent_token=` → 401，用头 → 200 |
| 缓存交易 ID 改写（N-03） | 通过：0xAAAA/0xBBBB 各对 |
| 规则即时生效（设计目标 ~5 秒） | 通过：改规则约 7 秒内生效 |
| nameserver 模式端到端（P1-12 相关） | 通过：返回 1.1.1.1 的真实 IP 207.45.73.1 / 207.45.72.1 |
| allowlist 拒启（P0-04/N-04） | 通过：非 loopback 空 allowlist rc=1；SNI HTTP 同样 rc=1 |
| 分架构 sha256（N-02） | 通过：重建哈希与 FIX-REPORT-3 声称完全一致（amd64 `8a517a1a…`、arm64 `71fae23b…`），`sha256sum -c` 通过 |

## 新发现问题（本轮，全部 P3）

### Q-01 标记制仍可能误删用户自有的其他 cloudflared 隧道（P3）
- 位置：`scripts/cloudflare-tunnel.sh:34–35` 与 `scripts/uninstall.sh:33–38`。
- 问题：标记只记录“tunnel 脚本跑过”，不记录“此前有无自有 cloudflared”。若用户此前已有自己的 cloudflared 隧道（`/etc/cloudflared/config.yml` 里已有别的隧道配置），再跑一次 `cloudflare-tunnel.sh` 会先用 `cat > /etc/cloudflared/config.yml` **无条件覆盖**原配置文件（当场丢配置），且留下标记；日后卸载 dnsunlock 时 `rm -rf /etc/cloudflared` 会连同原有隧道的凭据一起删掉。M-04 修的是“没跑过 tunnel 脚本就别删”，没修“跑过一次就全删”。
- 修法：tunnel 脚本写配置前先备份已有的 `/etc/cloudflared/config.yml`（如 `.bak`），或改用独立的 `config-dnsunlock.yml`；卸载时只删标记对应的文件/服务，不整目录删除。
- 影响面：只影响“已有自有 cloudflared 隧道又跑 tunnel 脚本”的用户；按用户“只服务器安装，不需要 Cloudflare”的范围，tunnel 脚本本身就是可选的，不拦推仓库。

### Q-02 usage 里仍列出已废弃的环境变量名（P3，纯文档）
- 位置：`cmd/dnsunlock/main.go:usage()`（约 71–79 行）。
- 问题：`DNS_ALLOWLIST` / `SNI_ALLOWLIST` 已废弃且代码不再读取，但 `--help` 输出里仍列出这两个名字（只在同一行标了“已废弃”）。用户照着 help 设置这两个变量会被静默忽略——fail-closed 所以安全，不会变成公开解析器，只是容易误导。
- 修法：从 usage 里删掉这两行，或写明“设置无效，会被忽略”。

### Q-03 文档漂移：DESIGN.md 与 model.go 注释跟不上代码（P3，纯文档）
- 位置：`DESIGN.md:42`（AI 服务写 19 个，实际 `data/platforms.json` 统计为 20 个）、`DESIGN.md:45`（默认规则清单写 YouTube→US，代码种子规则是 HK；Disney+ 在同一清单里出现两次）、`internal/model/model.go:9`（注释写 “26 supported unlock regions”，实际 `Regions` 为 34 个）。
- 问题：文档与代码不一致，会让照文档核对的人误判；不影响运行。
- 修法：改三处文字与注释，与代码一致。

## 仍未验证清单

1. **UDP DNS 路径**：沙箱禁一切 UDP 发送（连 loopback `sendto` 都返回 EPERM），agent UDP 监听已绑定、与 TCP 共用 `handlePacket`（TCP 已验证），但 UDP 收包/回包未实跑——需真实 VPS 上 `dig @127.0.0.1 -p 53`（UDP 默认）验证。
2. **install-panel.sh / install.sh 真机全流程**：只做了 `bash -n`、函数抽测与面板侧下载流程演练；未在真实 VPS 上跑（会改 80/443、装 systemd 服务、改本机 DNS）。其中 `systemctl is-active` 收尾探活在沙箱（无 systemd）未实跑；Caddy 安装分支（apt/dnf/yum）未实跑。
3. **resolv.conf 接管/还原真机**：代码与还原脚本已对齐（两份内容一致），未在真实机器上跑；`chattr +i`、NetworkManager/dhclient/cloud-init/netplan 各分支只在脚本层面核对。
4. **真实流媒体解锁**：需真实解锁节点 + 真实账号；本轮只验证到“DNS 返回解锁 IP / nameserver 转发到真实上游 IP”这一步。
5. **failover / failback 实况**：P1-06、P2-07、P2-09 的逻辑只在代码层面核对（30 秒探活循环、连续失败 2 次切换、主 IP 恢复切回、失联 60 秒警告），未在沙箱跑完时间线。
6. **EDNS 客户端行为**：OPT 记录仍不解析；`dig +edns` 的客户端在命中域名时拿到的回应不带 OPT，未实测其表现。
7. **Caddy 真实反代与自动 HTTPS**：本机无 caddy，`caddy validate` 未实跑；域名解析到机器、80/443 通、证书签发，全未验证。
8. **Release 公开下载流程**：Release 不存在，未验证；资产清单已定（5 个文件，见 N-02），发版后需在真实 VPS 上按清单验证下载；`.gitignore` 含 `dist/`，二进制不在 git 里，Release 资产必须从本地 `dist/` 上传。
9. **cloudflared 标记写入与卸载清理真机**：只在沙箱演练层面验证（路径替换 + stub），未在真机跑过 cloudflared。

## 核心链结论（四问，复核后）

- **会不会断网：沙箱能验证的部分已通过。** 规则即时生效、nameserver 转发、上游 TCP 回退、缓存 ID 改写均实测通过；种子规则冲突已消除。剩余风险只在未验证清单：UDP 路径、resolv.conf 真机接管/还原、failover 实况。
- **会不会漏 IP：比上一轮好，残留均为 P3。** 列表打码与 token 分离是真的；query token 已删；安装时 token 不进 ps；allowlist 只走 600 配置文件。残留：agent 失守仍能看到全部全局规则 IP（P0-05 设计使然——agent 必须知道 IP 才能答 DNS）；usage 里仍列已废弃变量名（Q-02）。
- **会不会被别人蹭用：主链路已堵死。** 空 allowlist + 非 loopback 拒绝启动（DNS 与 SNI HTTP 均实测 rc=1）；安装脚本不自动放行防火墙 53；登录锁直连与单层反代两种部署均实测正确。
- **改错了能不能还原：比上一轮好。** 卸载标记制已演练 9/9 通过；panel.json 损坏恢复在前两轮动态验证通过（本轮未重跑）；resolv.conf 还原只在代码层面核对（未真机验证）；Q-01 是标记制下仍存的窄口径残留（已有自有 cloudflared 隧道又跑 tunnel 脚本时）。

## 推仓库前必须做的事（按顺序）

1. `git init`、首次提交、push 到 https://github.com/iiiiiiiii7125-art/dns-unlock-panel（公开空仓，仍无任何提交）。提交前再扫一遍敏感信息：代码/脚本/前端/README/DESIGN 里 `xhj028` 0 处（本轮复核：仅 AUDIT-PENDING.md 的文字提及中有该字符串，代码里无）；`gho_`/`ghp_`/`github_pat_` 无真实命中；示例 IP 均为文档段。
2. 打 tag v0.1.0，发 Release，资产为 5 个文件：`dnsunlock-linux-amd64`、`dnsunlock-linux-arm64`、`dnsunlock-linux-amd64.sha256`、`dnsunlock-linux-arm64.sha256`、`dnsunlock.sha256`（从本地 `dist/` 上传，`dist/` 在 `.gitignore` 里，不在 git 里）。
3. 发版后在真实 VPS 上验证（仍未验证清单 1/2/3/4/7）：UDP DNS、install-panel.sh 与 install.sh 真机全流程、Caddy 真实反代与自动 HTTPS、真实流媒体解锁；验证通过前不要对外宣称“全链路已验证”。
4. Q-01…Q-03 可在发版后下一轮修（均为 P3，不拦发版）；其中 Q-01 只影响“已有自有 cloudflared 隧道又跑 tunnel 脚本”的用户，按用户“只服务器安装，不需要 Cloudflare”的范围，tunnel 脚本本身就是可选的。

---

*第四轮审计结论：可以推仓库。M-01…M-05 全部 5 条已修并实测通过，无新的 P0/P1/P2；新发现 3 条 P3 不拦发版。*
