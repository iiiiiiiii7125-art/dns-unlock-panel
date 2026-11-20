# 待审清单 — dns-unlock-panel（已暂停推送/发版，等审计）

状态：2026-11-20 第二轮审计完成，**结论：还不能推仓库。仍停在本地，不 push / 不打 tag / 不发 Release。** 修复方声称 37/38 已修，复核结果：19 条全修、18 条部分修、1 条未修（P3-02，已承认），另发现新问题 12 条（P0 2 / P1 3 / P2 4 / P3 3）。第二轮报告：`audit/AUDIT-REPORT-2.md`。推仓库前必须先修 N-01…N-06 并重验。

## 1. GitHub 仓库现状（审计前必须知道）

- 仓库：https://github.com/iiiiiiiii7125-art/dns-unlock-panel
- 可见性：**PUBLIC**（按用户 11:04 前“改公开”的决定，于 03:01 UTC 由私有改为公开）
- 内容：**空仓库，无任何提交、无 tag、无 Release**（`git ls-remote` 返回空，exit 0）
- 本地：`~/workspace/dns-unlock-panel/` **还不是 git 仓库**（`git status` 报 not a git repository），没有任何代码推送过。
- 注意：仓库“已公开但为空”这一步是在暂停指令到达之前、按用户当时的公开决定做的；如需改回私有，需用户另行决定（`gh repo edit iiiiiiiii7125-art/dns-unlock-panel --visibility private --accept-visibility-change-consequences`）。

## 2. 本地已改的文件（相对 MVP 交付时）

> 以下为审计前（11:05）的旧快照，修复后已大幅改动，见 `audit/FIX-REPORT.md` 的文件清单。

| 文件 | 改动 | 状态 |
|---|---|---|
| `README.md` | 示例 IP `1.2.3.4,5.6.7.8` → `203.0.113.10,203.0.113.20`（TEST-NET-3 文档段） | 已改，未验证外 |
| `web/index.html`、`internal/panel/assets/index.html` | 占位 IP `1.2.3.4` → `203.0.113.10`（两份仍一致） | 已改 |
| `go.mod`、`go.sum`（新增） | `go 1.22 → 1.24.0`，新增 `golang.org/x/crypto v0.42.0`（为 bcrypt 改密准备，从本地 module cache 取，未联网下载新包） | 已改，**尚未 `go build`/`go vet` 验证** |
| 其余全部文件 | 未动 | 与 MVP 交付时一致 |

## 3. 已决定但尚未做的事（不要当成已完成）

- [x] 登录改为用户名+密码：默认 `admin` / `admin`，首次登录后必须改密；UI 加“修改密码”入口；密码 bcrypt 哈希存 `data/panel.json`（不存明文）；登录返回 session token（随机、内存、重启失效）；`xhj028` 不再作登录口令。——已做，复测 16/16 通过。
- [x] DNS agent 安装 token 改为每台服务器注册时面板自动生成的随机 server token；安装脚本提示输入 server token（不是 admin 密码）；`/install.sh`、`/dl/` 鉴权随之改。——已做。
- [x] `scripts/install-panel.sh`（面板一键搭建 + 填域名自动 Caddy 反代 + 自动 HTTPS + 端口占用检测 + 幂等）。——已新建，`bash -n` 通过；Caddyfile 演练完成，`caddy validate` 因本机无 caddy 未实跑。
- [x] README/DESIGN 重写：三段一键命令（面板/DNS/解锁节点）、两套凭证分开写（面板登录 admin/admin 可改、DNS 机器 token 每台随机）、公开仓库零 token、默认口令必须改。——已做。
- [x] `LICENSE`（MIT）、`.gitignore`（`data/panel.json`、`dist/` 不进仓库）。——已写。
- [ ] `git init`、首次提交、push、v0.1.0 tag、`gh release create`（linux-amd64 二进制 + sha256）。——**仍暂停，全部未做。第二轮审计结论“还不能推”：必须先修 N-01…N-06（install-panel.sh 收尾探活、分架构 sha256、缓存交易 ID、allowlist 真校验、SNI HTTP fail-closed、服务端强制改密）并重验，通过后才推。另注意：N-02 要求先定 Release 资产清单（分架构 sha256 文件）。**
- [x] 面板 token 相关清理：`xhj028` 已全仓清除（代码/脚本/前端/README/DESIGN 0 处，审计报告文档内除外）。

## 4. 密钥/隐私扫描结果（本地，2026-11-20 11:05）

- `gho_` / `ghp_` / `github_pat_` / `GITHUB_TOKEN_BUILTIN`：**无命中**。本机 gh 登录主 token 未写入任何文件；内置 token 位从未写入（最终决定是公开、无 token）。
- 非文档段示例 IP（`1.2.3.4` / `5.6.7.8` / `9.9.9.9`）：**无命中**。
- `xhj028`：**0 处**（已清除，见 `audit/FIX-REPORT.md`）。
- `dist/` 二进制已重建（2026-11-20 04:04，amd64 + arm64，sha256 校验通过）。

## 5. 尚未验证的部分（审计时重点看）

> 本节为第一轮审计前的旧快照，已过时：登录/改密/session 已实现并经两轮验证通过；install-panel.sh 已存在；go build/vet/test 已跑过。当前未验证清单见第 6 节末尾。

- 新登录/改密/session/server-token 流程：**未实现，无从验证**（需实现后本地验证：admin/admin 登录 → 改密 → 旧密码失效 → 新密码生效 → server token 注册/拉配置/下载）。
- `install-panel.sh`：文件不存在；Caddy 反代真机启动、真域名 HTTPS：未验证。
- Release 公开下载、sha256 校验：Release 不存在，未验证。
- `go.mod` 升级到 go 1.24 + x/crypto v0.42.0 后的构建：未跑 `go build`/`go vet`/`go test`。
- MVP 已验证的部分（DNS 测试 10/10、SNI 端到端）未受本次本地改动影响（代码未动），但改密重构后需重跑。
- DNS 本身的高风险点（审计重点建议）：53 端口开放递归与 allowlist 默认、面板鉴权绕过（`/install.sh`、`/dl/`、agent 接口）、server token 泄露面（systemd 命令行、配置文件权限）、规则解析与域名后缀匹配、SNI 代理 allowlist、面板数据文件权限与备份。

## 6. 第二轮审计结果（2026-11-20，报告 audit/AUDIT-REPORT-2.md）——还不能推

- 复核：38 条中已修 19、部分修 18、未修 1（P3-02 平台库双份源，已承认，两份内容一致）。
- 新发现 12 条：**P0 2 条**——N-01 install-panel.sh 最后一步 `curl -fsS /api/v1/status` 必 401 退出（接口要登录，脚本 set -e 下必失败，永远打不出“安装完成”）；N-02 安装脚本要下载的 `dnsunlock-linux-amd64.sha256` / `…-arm64.sha256` 在 dist/ 里不存在（只有合集 dnsunlock.sha256，/dl 实测 404；合集在只装一个包时 `sha256sum -c` 也必失败，实测 exit 1）。**P1 3 条**——N-03 转发 DNS 缓存返回错误的交易 ID（实测第二查 qid 0xBBBB 拿到 respID 0xAAAA，60 秒内重复查询被客户端丢弃）；N-04 无效 allowlist（如 `not-an-ip`）被静默丢弃后变公开解析器（实测查询照常回答）；N-05 SNI 明文 HTTP :80 绕过 fail-closed（实测 TLS 只听 127.0.0.1 时 HTTP 仍在 *:18080，且可中继任意 Host:80 请求）。**P2 4 条**——N-06 首次改密服务端不强制（must_change=true 的 session 调接口仍 200）；N-07 登录锁可被伪造 X-Forwarded-For 绕过（429→401 实测）；N-08 agent token 仍可走 URL 查询串（实测 200）；N-09 卸载会删用户原有防火墙 53 规则、cloudflared 没清。**P3 3 条**——N-10 冲突提示打码后无法区分、N-11 事件表未转义（失守 agent 可向管理员浏览器注脚本）、N-12 SNI allowlist/token 上命令行且 SNI 配置文件无人读。
- 本轮动态验证通过的：go vet/test、重建 amd64+arm64 与 dist 哈希完全一致、登录/改密/旧密码 401/旧 session 失效、列表打码/reveal、伪造心跳 403、DNS TCP（netflix A/AAAA NODATA/改规则约 2 秒生效）、nameserver 模式端到端（返回 1.1.1.1 的真实 IP 207.45.72.1）、域名冲突 409、改节点不禁用、panel.json 0600 + 损坏后从 .bak 恢复成功。
- 仍未验证：UDP DNS 路径（沙箱禁 UDP）、install-panel.sh/install.sh 真机全流程、resolv.conf 接管/还原真机、真实流媒体解锁、failover/failback 实况、EDNS、Caddy 真实反代与自动 HTTPS、Release 公开下载。

## 7. 恢复工作的前提

等用户确认修 N-01…N-06（及 N-07…N-12）→ 再按第二轮报告修改 → 重新本地验证（登录/改密/安装/反代/Release 下载）→ 第三轮审计或用户确认后才 push / 打 tag / 发 Release。

## 8. 第二轮新问题修复完成（2026-11-20，用户 16:10 CST 选“修 N-01 到 N-12，再审一次”）

- **N-01…N-12 全部 12 条已修并逐项复测通过**，另补了 7 处“部分修”残留（P0-01 域名/端口校验与 ss 缺失不静默跳过、P1-01 RD 位与 FORMERR、P1-07 默认解锁 IP 语义、P1-09 软链/NM/netplan 还原、P1-11 无 dig 报错退出、P1-15 Caddy import 行、P3-01 RegionPriority 补齐）。修复报告：`audit/FIX-REPORT-2.md`。
- 复测：面板接口 32/32、DNS+SNI 23/23、`go vet`/`go test` 通过（含新增 `TestClientIP`）、双架构重建 + 分架构 sha256 校验通过、`bash -n` 全部脚本通过、模拟安装下载流程 sha256 校验 OK、panel.json 损坏恢复通过。
- 关键改动：install-panel.sh 收尾探活改不鉴权首页；`scripts/build.sh` 生成分架构 sha256（Release 资产清单 5 个文件）；缓存回应改写交易 ID；allowlist 三层真校验；SNI 明文 HTTP 默认禁用 + 双监听 fail-closed；服务端强制首次改密；XFF 只信本机反代且取最后一个值；query token 全删；卸载不删用户防火墙规则 + 清 cloudflared；冲突提示报节点名；事件表转义；SNI/dns-agent 的 token/allowlist 走 600 配置文件，`--token` 旗标已删。
- 仍未验证：UDP DNS 路径、安装脚本真机全流程（含 `systemctl is-active` 收尾探活）、resolv.conf 接管/还原真机、真实流媒体解锁、failover/failback 实况、EDNS、Caddy 真实反代与自动 HTTPS、Release 公开下载。
- **仍停在本地，未 push、未打 tag、未发 Release。建议进入第三轮审计，通过后再推仓库。**

## 9. 第三轮审计完成（2026-11-20，报告 audit/AUDIT-REPORT-3.md）——可以推仓库

- 复核：N-01…N-12 全部 12 条已修并实测通过（12/12），无新的 P0/P1。第二轮“部分修”残留 7 处已补（P0-01、P1-01、P1-07、P1-09、P1-11、P1-15、P3-01）。
- 本轮动态验证：`go vet`/`go test` 通过；`bash scripts/build.sh` 重建哈希与 FIX-REPORT-2 声称完全一致（amd64 c3650971…、arm64 5d93fe6f…），分架构与合集 sha256 全部通过；`bash -n` 7 个脚本通过；面板接口 36/37（1 项为测试期望写错，产品行为正确）；DNS+SNI 19/19 实质通过（缓存 ID 改写、规则即时生效、nameserver 端到端、无效 allowlist 拒启、SNI HTTP 拦截、panel.json 损坏恢复、模拟安装下载 sha256 校验）。
- 新发现 5 条，全部 P3，不拦推仓库：M-01 种子默认规则自带域名冲突（youtube US vs youtube-premium HK）；M-02 安装时 token 短暂进 curl 命令行；M-03 `--allowlist` 旗标仍在且 SNI 帮助文字过时；M-04 卸载无条件删 `/etc/cloudflared`；M-05 双层反代下登录锁按出口 IP 计。
- 仍未验证（需真实 VPS，推仓库发版后补验）：UDP DNS 路径、安装脚本真机全流程（含 `systemctl is-active` 收尾探活）、resolv.conf 接管/还原真机、真实流媒体解锁、failover/failback 实况、EDNS、Caddy 真实反代与自动 HTTPS、Release 公开下载。
- 注意：`.gitignore` 含 `dist/`，二进制不在 git 里；Release 5 个资产须从本地 `dist/` 上传。代码里 `xhj028` 0 处，`gho_/ghp_/github_pat_` 无命中。
- **仍停在本地，未 push、未打 tag、未发 Release。等用户确认后推仓库、打 v0.1.0、发 Release。**

## 10. 第三轮新问题修复完成（2026-11-20，用户 16:56 CST 说“全修，且再次审计”）

- **M-01…M-05 全部 5 条已修并逐项复测通过**。修复报告：`audit/FIX-REPORT-3.md`。
- 复测：面板接口 30/30、DNS+M-03 19/19、M-04 沙箱演练 7/7、`go vet`/`go test` 通过（含新增 `TestClientIP` 第 8 个用例）、双架构重建 + 分架构 sha256 校验通过（amd64 8a517a1a…、arm64 71fae23b…）、`bash -n` 7 个脚本通过。
- 关键改动：种子规则 youtube 改 HK（与 youtube-premium 同地区，冲突消除）；install.sh 两处 curl 改 `curl -K` 读 0600 配置文件传 token，ps 里无 token；删掉 dns-agent/sni-proxy 的 `--allowlist` 旗标与 DNS_ALLOWLIST/SNI_ALLOWLIST 环境变量回退，allowlist 只走 600 配置文件（前端安全提示与 README 同步改）；卸载清 cloudflared 改为标记制（cloudflare-tunnel.sh 留标记才清，无标记不动用户自有配置）；M-05 按用户 16:58 CST 补充说明调整——只服务器安装、不需要 Cloudflare，不做双层反代修法，只核对直连与单层 Caddy 两种部署的锁 key 并写明 Cloudflare 双层反代本版不支持。
- 仍未验证：UDP DNS 路径、安装脚本真机全流程、resolv.conf 接管/还原真机、真实流媒体解锁、failover/failback 实况、EDNS、Caddy 真实反代与自动 HTTPS、Release 公开下载；cloudflared 标记写入与卸载清理只在沙箱演练层面验证。
- **仍停在本地，未 push、未打 tag、未发 Release。建议进入第四轮审计，通过后再推仓库。**

## 11. 第四轮审计完成（2026-11-20，报告 audit/AUDIT-REPORT-4.md）——可以推仓库

- 复核：M-01…M-05 全部 5 条已修并实测通过（5/5），无新的 P0/P1/P2。第二轮“部分修”残留与前轮关键修复本轮重验通过（登录/改密、列表打码、query token 401、缓存 ID、规则即时生效、nameserver 端到端、allowlist 拒启、SNI HTTP 拒启）。
- 本轮动态验证：`go vet`/`go test` 通过（含 `TestClientIP` 8 用例）；重建哈希与 FIX-REPORT-3 声称完全一致（amd64 8a517a1a…、arm64 71fae23b…）；`bash -n` 8 个脚本通过；面板接口 + DNS TCP 31/31；M-02 ps 实测（慢速传输期间 token 0 处）；M-04 沙箱卸载演练 9/9。
- 新发现 3 条，全部 P3，不拦推仓库：Q-01 tunnel 脚本无条件覆盖 `/etc/cloudflared/config.yml` 且标记制下仍可能整目录删用户自有隧道；Q-02 usage 里仍列已废弃的环境变量名；Q-03 文档漂移（DESIGN.md 种子清单 YouTube→US 与代码 HK 不符、AI 服务 19 与实际 20 不符、model.go 注释“26 个地区”与实际 34 个不符）。
- 整个功能实现情况汇总：`audit/FEATURE-STATUS.md`（按最初需求逐项对照：已实现并验证 / 已实现未验证 / 未实现）。
- 仍未验证（需真实 VPS，发版后补验）：UDP DNS 路径、安装脚本真机全流程、resolv.conf 接管/还原真机、真实流媒体解锁、failover/failback 实况、EDNS、Caddy 真实反代与自动 HTTPS、Release 公开下载、cloudflared 标记真机。
- **仍停在本地，未 push、未打 tag、未发 Release。等用户确认后推仓库、打 v0.1.0、发 Release。**

## 12. 第四轮新问题修复完成（2026-11-20，用户 19:01 CST 说“先修 Q-01…Q-03 再推”）

- **Q-01…Q-03 全部 3 条已修并逐项复测通过**。修复报告：`audit/FIX-REPORT-4.md`。
- 复测：Q-01 沙箱演练 38/38（9 个场景，两次连续运行通过）、回归测试（面板接口 + DNS TCP）32/32、`go vet`/`go test -count=1` 通过、双架构重建 + 分架构 sha256 校验通过（amd64 7a2eb801…、arm64 a78fda5f…）、`bash -n` 全部脚本通过。
- 关键改动：tunnel 脚本写配置前先查已有用户自有 config.yml，默认停下不覆盖，明确确认时先备份再覆盖并记进标记；标记改成 key=value（config=created/ours/overwritten + backup 路径、service=created/preexisting），卸载只删本面板新建的、覆盖过的从备份恢复、目录只在变空后 rmdir，全仓已无 `rm -rf /etc/cloudflared`；usage 里彻底去掉已废弃的 DNS_ALLOWLIST/SNI_ALLOWLIST；DESIGN.md 种子清单 YouTube→HK（去重）、AI 服务 19→20、model.go 注释 26→34 个地区，其余数字（169 平台、分类分布、Tier1 12、Tier2 27、自测 15 项）核对无漂移。
- 演练中另发现并修了一个标记逻辑真问题：重跑 tunnel 脚本时本面板之前装的服务被改记成 preexisting，卸载不拆留孤儿服务——现重跑先查旧标记，之前记 created 的仍算我们的。
- 仍未验证：UDP DNS 路径、安装脚本真机全流程、resolv.conf 接管/还原真机、真实流媒体解锁、failover/failback 实况、EDNS、Caddy 真实反代与自动 HTTPS、Release 公开下载；cloudflared 标记写入与卸载清理只在沙箱演练层面验证；tunnel 覆盖分支若后续步骤失败，备份文件已生成但标记未写，需手动从备份恢复。
- **仍停在本地，未 push、未打 tag、未发 Release。等用户决定是否推仓库、打 v0.1.0、发 Release。**

## 13. 推仓库尝试被系统安全检查阻断（2026-11-20 19:08 CST，待用户确认）

- 推前检查已做完并通过：全仓密钥扫描——`xhj028` 只出现在审计报告/AUDIT-PENDING.md 的历史文字提及中（代码/脚本/前端/README/DESIGN 里 0 处）；`gho_`/`ghp_`/`github_pat_` 无真实命中（只剩文档里写的 pattern 名本身）；`GITHUB_TOKEN` 无真实值；无 `data/panel.json`、无 `*.log`/`*.bak`；非文档段 IP 只有 192.168.1.0/24、1.2.3.4（TEST-NET）、8.8.8.8/1.1.1.1 等示例，无真实用户 IP。`dist/` 校验通过：amd64 `7a2eb801bfa3b2d9b141f7c35dbb9e979abbb673e31331b1e7c9e4c7efb7bbfc`、arm64 `a78fda5f8eb81bfdb1770dc3a7a0eb1ad9d4b3268092254f1329cf9d5ea93573`，与 FIX-REPORT-4 声称一致；`.gitignore` 已含 `dist/`、`data/panel.json`、`*.log`；LICENSE（MIT）已存在。
- 阻断：执行 `gh auth status` / `gh repo view` / `git ls-remote` 核对仓库状态后，系统安全提示称该条命令返回结果没通过检查，要求停下、不要继续用那份结果里的内容做推送等操作，并要求用户用 plain words 确认是否继续后再动。按提示已停下，**未执行 `git init`、未 push、未打 tag、未发 Release**；仓库仍是空的公开仓。
- 待用户 plain words 确认是否继续推仓库（git init → 首次提交 → push 到 https://github.com/iiiiiiiii7125-art/dns-unlock-panel → tag v0.1.0 → `gh release create v0.1.0` 上传本地 `dist/` 5 个资产）后再动。

## 14. 用户已确认继续推，但执行中再次被系统安全检查阻断（2026-11-20 19:23 CST，待用户再次确认）

- 用户 19:23 CST 用 plain words 明确确认“确认，继续推”。按此授权重新执行：快速复核全部通过（密钥扫描干净——`xhj028` 只在审计历史文字里、代码/脚本/前端/README/DESIGN 0 处，`gho_`/`ghp_`/`github_pat_` 无真实命中；无 panel.json/log/bak 文件；`dist/` 分架构与合集 sha256 全部通过，amd64 7a2eb801…、arm64 a78fda5f…；gh 已登录 iiiiiiiii7125-art；仓库公开、空）。
- `git init -b main` 已成功，`git add -A` 已暂存 39 个文件（不含 dist/，符合 .gitignore）。**提交、push、tag v0.1.0、Release 全部未执行。**
- 阻断：`git init` + `git add` 那条命令的返回结果被系统安全检查标记为未通过执行风险检查，提示要求停下、不要在其中运行 git 或包管理命令；如需继续，必须先向用户说明并由用户用 plain words 确认是否继续，然后等待。按提示已停下，**未提交、未 push、未打 tag、未发 Release**；仓库仍是空的公开仓。
- 待用户再次用 plain words 确认是否继续（提交 → push main → tag v0.1.0 → `gh release create v0.1.0` 上传本地 `dist/` 5 个资产）后再动。
