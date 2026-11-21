# v0.1.6 计划：AKDNS 五点（接管加固 / 验证不致命 / 测速选最优 / 自测 / 临时模式）

依据：`audit/AKDNS-ANALYSIS.md` §十一（akdns.sh v3.0.0 全文分析，只读，未下载未运行）。
用户决定（2026-11-21 15:16，主聊天）：五点做进 v0.1.6；等 v0.1.5 发完再开工，从 v0.1.5 后的 main 开分支，别动正在发的 v0.1.5。
流程（DNS 面板老规矩）：实现 → 测试机实测 → 全面审计 → 再发 v0.1.6。

## 现状核对（写计划前已读代码，2026-11-21）

- `scripts/install.sh`（615 行）：[4/6] 只用 `dig`，缺 dig 直接 `exit 1`（接管步根本跑不到）；接管已做 chattr +i 锁、只关 resolved stub（drop-in `DNSStubListener=no`，服务本身不停）、NM 逐连接改 `ipv4.dns`（原值记 `nm-backup.txt`）、resolvconf head 文件、dhclient supersede、cloud-init `manage-resolv-conf: false`、netplan 可选改、`options use-vc` 是**无条件写**的；备份是单份 `/etc/dnsunlock/resolv.conf.orig`（只备一次）；还原脚本以 heredoc 内嵌在 install.sh 里、另有一份 `scripts/restore-resolv.sh`（双份来源，有漂移风险）；**没有 nsswitch 处理，没有 hpve-init 处理**；Tailscale 守卫已在（resolv.conf 含 tailscale 或 100.100.100.100 时整段跳过接管）。
- `internal/dnsagent/agent.go`（949 行）：已同时提供 UDP + TCP DNS（`serveTCP`），上游转发已有 UDP→TCP 回退（`forwardTCP`）；健康循环每 30 秒对每个解锁 IP 做 TCP :443 + TLS 握手探活（`probeIP`），`LatencyMs` 已随 heartbeat 上报，面板已存入 `n.LatencyMs`（`panel.go:1417`）。**没有自测机制**：config/heartbeat 里无 selftest 字段，agent 没有本地 HTTP 接口。
- `internal/panel/panel.go`（1441 行）：`/api/v1/agent/config`、`/api/v1/agent/heartbeat` 已有；无自测相关端点。

## 1. 接管加固

目标：把 AKDNS 那套“停管理器 + 锁文件 + 结构化备份 + 一键还原”搬过来，保留我们已有的、比它细的部分（dhclient supersede、cloud-init、Tailscale 守卫）。

- **nsswitch**：新增 `ensure_nsswitch_dns` 等价逻辑——`hosts:` 行缺 `dns` 就补上，改前备份 `nsswitch.conf`（进备份目录）。文件：`scripts/install.sh`。
- **resolved**：默认保持“只关 stub”（破坏性小），接管后验证（见第 2 点）若系统解析仍不走 agent，再升级为 `systemctl disable --now systemd-resolved`。不默认全停——全停会影响依赖 resolved 的服务，升级路径写进脚本而不是让用户猜。文件：`scripts/install.sh`。
- **NetworkManager**：从“逐连接改 ipv4.dns”改成 AKDNS 式 `/etc/NetworkManager/conf.d/dnsunlock.conf`（`dns=none`）+ reload，不停用网络；新连接也不受影响。保留 `nm-backup.txt` 的还原路径不动（已按旧方式接管过的机器还能还原）。文件：`scripts/install.sh`、`scripts/restore-resolv.sh`。
- **resolvconf**：保持现有 head 文件做法（比 AKDNS 的直接停用更温和，resolvconf 还能正常工作），不改。
- **备份结构化**：从单份 `.orig` 改成 `/var/lib/dnsunlock/backup/<时间戳>_<标签>/`，附 `metadata.txt`（时间、标签、当时 DNS、后端、resolved/NM/resolvconf 的 active/enabled 状态）+ 各后端文件（resolved.conf/drop-in、NM conf.d、netplan yaml、nsswitch.conf、resolv.conf 内容及符号链接目标）。保留“不覆盖原备份”原则：第一次接管的备份就是原始状态，还原默认选最早的一份，用户也可挑。兼容：保留 `/etc/dnsunlock/resolv.conf.orig` 作为指向首份备份的兼容指针，老版本 `dnsunlock-restore-dns` 不会断。文件：`scripts/install.sh`、`scripts/restore-resolv.sh`。
- **还原**：`do_restore` 式流程——列出备份（时间倒序，带编号/时间/标签/DNS）→ 选编号 → 确认 → **还原前先自动备份当前状态，备份失败就中止** → 删 AKDNS/NM 的 `dns=none` 配置 → 恢复 resolv.conf（原先是符号链接就先恢复链接）→ 恢复各后端文件 → 重新启用之前开着的管理器 → 按后端重载服务 → **还原后验证**（getent/dig，见第 2 点）并报告“已还原并验证通过”或“已还原但验证未通过”。文件：`scripts/restore-resolv.sh`。
- **双份来源**：install.sh 内嵌 heredoc 与 `scripts/restore-resolv.sh` 必须一致。做法：仓库加一条构建/测试检查（diff 两份，还原脚本改了就必须同步），或把还原脚本收进 `internal/panel/assets/` 随面板下发、二选一，实现时定。文件：`scripts/install.sh`、`scripts/restore-resolv.sh`，另加检查脚本或 assets。
- **use-vc**：不再无条件写。接管前先探 UDP 到 agent（dig 不加 `+tcp`），不通再试 `+tcp`，TCP 通才写 `options use-vc`。本机 agent 场景下 UDP 几乎总通，常见情况不再写 use-vc。文件：`scripts/install.sh`。
- **hpve-init（待查，不猜）**：pride-bubble2 的 resolv.conf 由 hpve-init 管理，AKDNS 没这个概念，脚本也不认识它。计划：installer 检测到 hpve-init 痕迹时明确提示并询问，不静默接管；hpve-init 到底会不会改回 resolv.conf，只能在 pride-bubble2 上由用户在场时实测得知，测试机上测不了（见“测试约束”）。这是本点唯一的未决调查项。
- **Tailscale 守卫**：原样保留，绝不接管 Tailscale 管理的 resolv.conf。

## 2. 验证不致命

- **[4/6] 缺 dig 不再退出**：区分“测不了”和“测了不通”。缺 dig → 警告 + 继续安装（文案给手动验证命令），不要 `exit 1`；dig 在但解析无结果 → 仍是硬失败（agent 真有问题）。这是本次要修的 bug——用户香港机就是卡在这里，接管步没跑到。文件：`scripts/install.sh`。
- **接管后验证（新增，AKDNS 式）**：接管步完成后用**系统解析器**验证，而不是只 `@agent` 查。优先 `getent hosts example.com`（走 glibc，遵守 use-vc），缺 getent 回退不带 `@server` 的 `dig`；再查一条已设规则的域名，确认返回规则 IP。验证失败 → 大声警告 + 提示还原命令，不谎称成功；缺工具时只警告，不 abort。文件：`scripts/install.sh`。
- **可选**：缺 dig 时询问是否自动装 dnsutils/bind-utils（apt/yum/apk），用户确认才装。实现时定，默认不做也行。

## 3. 测速选最优

- **安装端（新增）**：`probe_panel()` 现在是“第一个通的就用”。改成并行测全部候选端点（curl 计时，8 秒超时不变），按延迟排序，选最快且可达的做 PANEL_BASE，并打印排名。本机安装时 localhost 通常最快——这是正确结果。文件：`scripts/install.sh`（+ 内嵌副本 `internal/panel/assets/install.sh` 保持字节一致）。
- **节点延迟（已有，只差展示）**：agent 每 30 秒探活已产出 `LatencyMs` 并随 heartbeat 上报，面板已存储。v0.1.6 只做展示：节点列表显示每节点延迟 ms；规则编辑器的节点下拉框里也带上延迟。文件：`web/index.html`（+ 内嵌副本）。
- **自动选最快（可选项，默认关）**：规则选了某地区、有多个可用节点时，优先延迟最低且健康的节点。做成按规则的独立开关（默认关），不与现有的 `auto_failover`（故障切换）混在一起。是否默认开、开关叫什么，实现前由用户定。文件：`internal/dnsagent/agent.go`（`lookup`/`failoverToBackup` 附近）、`internal/panel/panel.go`（规则字段）、`web/index.html`。
- **UDP→TCP（agent 侧已齐）**：agent 已有 TCP DNS 服务 + 上游 TCP 回退，不用新写；v0.1.6 只补测试（`dig +tcp @127.0.0.1`），并把 use-vc 的决定权交给第 1 点的探测。

## 4. 自测按钮

不用第三方脚本，内置实现，走现有轮询通道，不给 agent 加新端口。

- **通道设计**：面板在 `/api/v1/agent/config` 的响应里加 `selftest_request`（请求 id + 时间戳）；agent 下次轮询拿到后跑测试，把 `selftest_result` 放进下次 heartbeat。面板 API 新增 `POST /api/v1/servers/{id}/selftest`（入队，返回请求 id），结果随 `GET /api/v1/servers` 返回（最后一次结果 + 时间）。文件：`internal/panel/panel.go`、`internal/dnsagent/agent.go`。
- **测试内容（复用现有探活）**：对每条已设规则的平台域名，用 agent 自己的解析逻辑查出 IP，再对该 IP 做 TCP :443 + TLS 握手（复用 `probeIP`）。结果按平台列出：域名 → 解析 IP → 通/不通。UI 上明确这是连通性检查，不证明流媒体一定接受该流量（和 AKDNS 借用脚本的诚实度一致；健康探活的 P2-07 备注同样适用）。文件：`internal/dnsagent/agent.go`、`web/index.html`。
- **基线对比（AKDNS 流程：装前测一次、配完再测一次）**：installer 在接管前跑一次基线（规则域名走上游直接解析的结果），接管后再跑一次（走 agent），两次结果并排打印，用户当场看到变化。实现首选 Go 的 `dnsunlock check` 模式（复用 agent 的 lookup + probeIP，不依赖 dig）；若工期紧，退到 shell 里 dig/getent 实现。文件：`cmd/dnsunlock/main.go`（新增模式）或 `scripts/install.sh`。
- **UI 位置**：服务器页每台 server 一行一个“自测”按钮；规则页顶部也可放一个“自测全部”。结果就地展开，不跳页。文件：`web/index.html`。

## 5. 临时模式

- **新增 `install.sh --temp`**：把 agent 设为系统 DNS，但**不做永久接管**。systemd-resolved 在跑 → `resolvectl dns <主网卡> 127.0.0.1`（重启/服务重启后失效）；否则直接写 resolv.conf，**不加 chattr 锁、不停任何管理器、不动 netplan/cloud-init/dhclient**（下次 DHCP 续租或管理器运行时即失效）。全程不写永久备份（避免污染永久备份），并打印清楚：临时模式、重启后失效、要永久生效请重跑安装并选接管、还原办法。文件：`scripts/install.sh`、README。
- **退出路径**：`dnsunlock-restore-dns` 遇到“无永久备份”时不再只说无需还原，改为提示临时状态的清理办法（重启 resolved / 重新拉 DHCP / 手动改回）。文件：`scripts/restore-resolv.sh`。

## 不做的

- 管道 stdin → `/dev/tty`：已和 AKDNS v0.1.2 修法一致，不用再改。
- 不下载、不运行 akdns.sh；不抄它的硬编码节点列表（8 个 IP 是它家的，与我们无关）。

## 补充三项（用户 2026-11-21 15:27 定：全部加进 v0.1.6）

来源：脚本逐行核对（2026-11-21 15:25，`AKDNS-ANALYSIS.md` §十四），三项均有原文依据。

- **手动输入 DNS 入口**：AKDNS `menu_apply()` 在无测速结果时三选一（先测速 / 手动输入 DNS / 返回），手动输入过 `validate_ipv4` 校验（正则 + 每段 ≤255，可顺带抄这个一行函数），并可选择是否强制 TCP。对应到我们：installer 测速/探测无可用面板入口时，提供手动输入面板地址入口（带校验），而不是只报错退出；接管前照抄 `menu_apply` 的安全流程——打印操作摘要（模式、DNS、后端、接管方式、传输方式、防覆盖锁定）+ `[y/N]` 确认（默认 N）+ 自动备份（备份失败中止应用）。文件：`scripts/install.sh`（测速与接管两处），`validate_ipv4` 校验函数一并加入。
- **NM 按连接 UUID 操作**：AKDNS 用 `get_active_nm_connection_uuid()` 按默认路由接口取 NM 连接 UUID（连接名含冒号会被截断），无默认路由时回退取第一个活动连接。v0.1.6 凡是碰 NM 的地方（接管时改连接、还原时恢复连接）一律按 UUID 操作，不用连接名。文件：`scripts/install.sh`（接管 NM 块）、`scripts/restore-resolv.sh`（`nm-backup.txt` 改记 UUID）。
- **按后端重载 `reload_dns_service`**：还原后按备份里记的后端重载——restart resolved / `nmcli con reload` + 重新激活连接 / `netplan apply` / resolv.conf 直接生效，失败只警告不致命。我们的还原脚本已有零散的重载（restart resolved、nmcli up、netplan apply），v0.1.6 把它收成按后端分发的显式步骤。文件：`scripts/restore-resolv.sh`。

## 测试约束（重要）

- **测试机（ip-172-26-15-152）的 resolv.conf 是 Tailscale 生成的，绝不能接管**。因此接管/还原的实测**不能**在测试机宿主机上跑。方案：先在隔离环境里测接管 mechanics（systemd 容器 systemd-nspawn 或带 systemd 的特权容器，具体方式实现时验证可行性）；再由用户在场、在 pride-bubble2 上监督跑一次（只有那里能验证 hpve-init 的行为）。隔离环境方案未验证，是实现阶段的第一件事。
- 不碰接管的部分（安装端测速、自测、临时模式的 resolvectl 路径）可直接在测试机上验，走老流程。
- 审计：实现完按 DNS 面板老规矩做一次全面审计（脚本 + 安装 + DNS 设置），审计通过再发 v0.1.6。

## 分支与顺序

- 等 v0.1.5 发完，从 v0.1.5 后的 main 开新分支（建议名 `feature/v0.1.6-takeover`），别动正在发的 v0.1.5。
- 建议顺序：先 2（验证不致命，修 bug，独立可测）→ 1（接管加固，含备份/还原）→ 5（临时模式，复用 1 的代码）→ 3（测速）→ 4（自测）→ 审计 → 发版。

## 审计范围（用户 2026-11-21 16:15 定）

全量审计，按原计划，不压缩范围。发版前必须审干净（用户原规矩：DNS 不是小事情，不要出现纰漏）。审计对象是整个仓库，不只是本次改动的文件；审计发现的 P0/P1 必须修完复验通过才能发版。

## 收尾流程（用户 2026-11-21 16:16 定：全量审计，不压缩范围）

- 实现 + 沙箱验证 → rebase 到 v0.1.5 后的 main（817c606）→ 测试机验证 → 全量审计（整个仓库，不只是本次改动的文件）→ 审计通过、P0/P1 修完复验通过 → 发版。
- 审计不采用“只审改动文件”的省时间方案。
