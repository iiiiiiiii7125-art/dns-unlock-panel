# v0.1.6 聚焦复审报告（第二轮，Focused Re-audit R2）

- **复审对象**：`~/workspace/dns-unlock-panel-v016`，分支 `feature/v0.1.6-takeover`，tip `749a155`
- **审的 diff**（只审改动 + 直接关联路径，用户 2026-11-22 定“只对事论事”，全量 30 分区只在他明确要求时才做）：
  - 修复轮 3：`1f24428..749a155`，共 5 个 commit——`9e2be69` F3-01、`c38e4e7` F3-03、`01a6ef8` F3-02、`65a817e` 台架 stub 修补、`749a155` 证据 commit（139 文件，仅证据，无产品改动）。
- **上一轮**：`audit/AUDIT-REPORT-V016-FOCUSED.md`（175 行，结论“修后发版”，F3-01/02 P2 + F3-03 P3 必修）。本轮逐项复核三项的修复是否真的落地、修法是否与报告一致，不重复报已修问题，只找新问题和回归。
- **动态验证**：容器证据 `audit/evidence-v016r3-fix/{red,green,host}/` + `RUN-NOTES.md`（180 行）逐项核对日志原文（非只信手记数字）；沙箱重跑 `go test ./...` 全量 + `scripts/test-takeover-rig.sh` 全量（145/0，本轮亲手跑，tip 749a155）；F3-01 尾部再确认逻辑在台架 rootfs chroot 内用函数原文跑了 9 项单元测试；测试机宿主机只读核对（未做任何写操作，未碰生产面板）。
- **复审结论：可发版（RELEASABLE）—— 无 P1，无 P2；F3-01/02/03 全部修复并有容器红/绿实证；新发现 5 项均为 P3 仅记录，不拦发版。**

## 1. 结论（先说）

| 类别 | 数量 |
|---|---|
| F3-01（P2）还原顺序闪烁 | **已修**，容器红 20/2 + 23/2 复现、绿 22/0 + 25/0 通过 |
| F3-02（P2）重装不重启 agent | **已修**，容器 agent 红 15/3 绿 19/0、SNI 红 18/3 绿 21/0 |
| F3-03（P3）还原未跑分支漏 disable | **已修**，容器红 18/2 绿 20/0 |
| 新 P1 / 新 P2 | **0** |
| 新 P3（仅记录，不拦发版） | 5（F4-01~F4-05，见 §7） |
| 第一轮 §8 发版门 | **全部满足**（见 §9） |

**发版前置动作（父代理做，不在本报告内）**：`scripts/build.sh` 在最终 commit 上重跑（哈希嵌 git HEAD）、打 tag v0.1.6、发布、给用户手动换二进制命令块。本复审未改产品代码、未 push/tag/发版。

## 2. F3-01 裁定：已修，闭合

### 修法核对（代码，`9e2be69`）

- `restore_resolv_conf_file`（`scripts/restore-resolv.sh:718`，新抽出）：软链优先恢复，P1-09 目标写回逻辑与旧代码**逐字一致**（目标不存在时 `cp -L` 写回，失败只警告）；无 `.symlink` 记录时按普通文件恢复。无行为漂移。
- `resolv_conf_matches_backup`（`:741`，新抽出）：软链比目标、文件比内容（`cmp -s`）。
- `restore_from_dir`：第 4 步先恢复 resolv.conf，再第 5 步重启用管理器（`enable --now`）、第 6 步 `reload_backends`、第 7 步尾部再确认（不符再恢复一次）。旧顺序（重启在前、恢复在后）已不存在。
- `restore_legacy`：先恢复 resolv.conf 再 `systemctl restart systemd-resolved`，NM/resolvconf/netplan 步骤之后尾部再确认。两路都改到。

### 任务要求的三个问题，逐项回答

1. **两路都先恢复软链再重启？是。** CHOSEN（`restore_from_dir` 第 4 步在第 5 步 `enable --now` 与第 6 步 `reload_backends` 之前）与 legacy（恢复在 `restart systemd-resolved` 之前）均已调换。另核：`reload_backends` 的无 metadata 老备份 blanket 分支（`restart resolved` + `resolvconf -u` + `netplan apply`）也在第 6 步、即恢复之后；`reload_dns_service` 的 resolved 分支（`:660`）同样在恢复之后重启。恢复之后不存在任何“读接管态文件导入全局 DNS”的重启点。
2. **尾部再确认是否可能把 resolved 刚导入的全局 DNS 之外的状态搞乱？不会。** 尾部只改 `/etc/resolv.conf` 文件本身（恢复为备份内容），不碰 resolved 的运行态。若某后端在重载时把 resolv.conf 改写为管理器 DNS，resolved 可能已将其导入为 Global；尾部把它改回 stub 软链后，resolved 经 inotify 重读会忽略 stub 软链、清空该导入。最坏情况（若某实现不重读）：残留的也是管理器给的上游 DNS（非规则 IP），系统 DNS 仍可用、无泄漏、无闪烁。且本轮容器绿跑两路 Global 均为空（见下），实测终态干净。
3. **NM/netplan/resolvconf 重载改写 resolv.conf 的场景是否覆盖？未在容器内覆盖，但不拦发版。** 容器后端只有 resolved + networkd（无 NM、无 netplan、无 resolvconf），尾部再确认的触发分支（后端改写后不符→再恢复）在容器里从未触发；台架（`scripts/test-takeover-rig.sh`）也无覆盖该分支的场景（grep `matches_backup` 0 命中）。作为补偿，本轮把两个函数**原文**抽出，在台架 rootfs chroot 内跑了 9 项单元测试（见 §8），软链/文件/目标缺失/改写检出/再恢复全部通过。记为 F4-03（P3，仅记录）：建议下次有 NM 的容器跑一次端到端；本次的 chroot 单元测试 + 代码检查已足以支撑发版。

### 容器实证（日志原文抽查，非只信手记）

- 红 f301c（CHOSEN，20/2）：还原后立即 dig #1 → **203.0.113.99**（规则 IP），`resolvectl dns` 显示 `Global: 127.0.0.1`（`red/f301c-dig5.txt`）；延迟 3 秒后 ×5 全走上游（闪烁间歇性，与第一轮描述一致）。复现成立。
- 红 f301l（legacy，23/2）：同款两项 FAIL（立即 dig #1 规则 IP、`Global: 127.0.0.1`），日志含“走老路还原”。复现成立。
- 绿 f301c（22/0）：立即 + 延迟 dig ×10 全走上游（23.214.22.137/143/144/140），`Global:` 为空（`green/f301c-dig5.txt`）。**F3-01 CHOSEN 绿确认。**
- 绿 f301l（25/0）：同上，`Global:` 为空。**F3-01 legacy 绿确认。**

## 3. F3-02 裁定：已修，闭合

### 修法核对（代码，`01a6ef8`）

三处同改，修法与第一轮报告一致：

| 处 | 旧 | 新（`scripts/install.sh`） |
|---|---|---|
| agent 永久分支 | `:1119` 前 `enable --now` | `enable`（保开机自启）+ 已 active 则 `restart`（`:1154`），否则 `start`（`:1156`） |
| agent 临时分支 | `:1117` 前 `start` | 已 active 则 `restart`（`:1143`），否则 `start`（`:1145`） |
| SNI 代理 | `:1048` 前 `enable --now` | `enable` + 已 active 则 `restart`（`:1056`），否则 `start`（`:1058`）；随后 PID 验证（见下） |

- **restart 分支正确性**：三处都是“先判 `is-active --quiet`，active 才 restart，否则 start”。unit 未在跑时不走 restart（`restart` 对未运行 unit 在 systemd 里本就是启动，但显式分支更稳妥且保留了 `enable` 的开机自启语义）。无“对没在跑的 unit 误 restart”的问题。
- **SNI“新配置已加载”验证**：重装前记 `_proxy_pid_before`，重装后记 `_proxy_pid_after`；要求 unit active 且新 PID 非空非 0，且（旧 PID 为空/0 或新旧不同），否则报错 exit 1；通过则打印“验证通过: SNI 代理已按新配置启动（PID …），新 allowlist 已加载。”
- **MainPID 变化是否充分？基本充分，本轮有探针实证兜底。** PID 变化证明重装后起了新进程；代理只在启动时读 allowlist，新进程即新配置。失效模式均已 fail-closed：restart 失败且旧进程仍在 → PID 不变 → exit 1；新进程起不来 → PID 为 0/空或 inactive → exit 1。剩余理论缺口：`Restart=always` 下新进程若启动即崩溃循环，`is-active` 仍可能报 active 且 PID 与旧不同——此时 PID 检查会误放。但该缺口要求新 allowlist 本身让二进制启动即崩溃，而 allowlist 只是逗号分隔的 IP 串、解析失败路径未在代码中证实；且本轮容器绿跑用真探针验证了新 allowlist 的实际放行/拒绝行为（见下），功能侧已有实证。记为 F4-04（P3，仅记录），不拦发版。

### 容器实证（日志原文抽查）

- agent 红 f302a（15/3）：重装 rc=1、MainPID 2415 不变、dig -p 5353 无应答；守卫文案断言正确 SKIP（安装死在 [4/6]，未走到接管提问——第一轮 §8-4 的台架修正已在红/绿双向实证，见 §6）。复现成立。
- agent 绿 f302a（19/0）：重装 rc=0、MainPID **5039→5234**、dig -p 5353 tiktok 回规则 IP（UDP）、日志明说“本次不接管”、resolv.conf 仍是接管态、还原 rc=0 干净。**F3-02 agent 绿确认。**
- SNI 红 f302s（18/3）：重装 rc=0（静默成功）、无“新 allowlist 已加载”、MainPID 3035 不变、探针仍 **ALLOWED**（TLSv1.3 握手成功，`red/sni-probe-last.txt`）——旧 allowlist 静默残留，红证成立。
- SNI 绿 f302s（21/0）：重装 rc=0、日志“验证通过: SNI 代理已按新配置启动（PID 5802），新 allowlist 已加载。”、MainPID **5688→5802**、探针 **DENIED**（握手 EOF，`green/sni-probe-last.txt`）。**F3-02 SNI 绿确认**——新 allowlist 实际生效（已删 IP 被拒），不只是 PID 变化。

### 台架 stub 修补（`65a817e`）

`scripts/rig/stubs/systemctl` 的 `restart` 对 `dnsunlock-agent` 按 stop+start 语义真重起（杀旧 PID、sleep 1、删 PID 文件、标 active、调 `start-agent`）。修补的动机属实：旧 stub 只记 markers、不真起进程，S5 [3/6] 走 restart 分支时 [4/6] 必然失败（上一轮台架 143/4 的 3 个 S5 FAIL 即此缺口）。本轮台架 145/0（见 §8），S5 已过。stub 只改了 agent 分支，未改 proxy 分支——台架不跑 SNI 安装路径，无影响；resolved 分支（杀 stub holder）未动。

## 4. F3-03 裁定：已修，闭合

- 修法（`c38e4e7`，一行）：`restore_agent_after` 首分支（`AGENT_WAS_ACTIVE != 1`）补 `_enabled_boot_disable` 调用（`scripts/restore-resolv.sh:533`），注释写明其余 6 个分支都调、本分支漏了。
- **守卫成立**：`record_and_stop_agent` 里 `AGENT_WAS_ENABLED` 的赋值（`systemctl is-enabled --quiet`）在 active 早返回（`[ "$AGENT_WAS_ACTIVE" = 1 ] || return 0`）**之前**；无 unit 路径下该变量恒为 0（`_enabled_boot_disable` 注释亦明说）。首分支调它时守卫有意义：未 enabled 时 no-op，enabled 但已停时 disable。闭合。
- **其余 6 个分支一致**：`_enabled_boot_disable` 调用点共 7 处——首分支 `:533` + 其余 6 处（`:547`、`:559`、`:565`、`:571`、`:584`、`:589`），与第一轮报告“6 个‘曾运行、保持停止’分支都已 disable，只剩这一处”一致。无遗漏分支。
- 容器实证：红 f303（18/2），2 个 FAIL 正是“还原后 agent 为 disabled”与“还原日志有 disable 说明”——还原后仍 enabled，复现成立；绿 f303（20/0），还原后 disabled，日志含“agent 还原前是开机自启（enabled），已直接改为不开机自启……下次启动不会再抢 :53”。**F3-03 绿确认。**

## 5. 机制族横扫：还原 / 重装还有没有同款 no-op 残留

对 `scripts/install.sh` 与 `scripts/restore-resolv.sh` 全量 grep `systemctl enable --now` / `start` / `restart`，逐项过：

| 位置 | 动作 | 裁定 |
|---|---|---|
| install.sh `:1056/:1058` SNI | restart / start（F3-02 已改） | 已修（§3） |
| install.sh `:1143/:1145` agent 临时 | restart / start（F3-02 已改） | 已修（§3） |
| install.sh `:1154/:1156` agent 永久 | restart / start（F3-02 已改） | 已修（§3） |
| install.sh `:261`、`:1280` | `restart systemd-resolved`（接管路径写 drop-in 后重启） | 非 no-op 残留：接管时 resolved 配置刚改（DNSStubListener=no），重启是必需的；且重启时 resolv.conf 仍是接管前状态，导入的是上游 DNS，正确。 |
| install.sh `:1678` / restore-resolv.sh `:295` `restart_agent` | `systemctl start`（agent 刚被停掉后恢复） | 非残留：停后起是正确动作，且有 `is-active` 复核与失败明说。 |
| install.sh `:2189/:2192`、restore-resolv.sh `:806/:809` | `enable --now systemd-resolved` / `resolvconf`（还原第 5 步重启用管理器） | 非残留：还原时管理器是被停掉的，`enable --now` 真启动它；若已在跑则无配置改动需加载（drop-in 已删，后续 `reload_backends` 会按后端重启 resolved）。 |
| restore-resolv.sh `:418`、`：937` | `systemctl stop` | 停动作，无 no-op 问题。 |
| install-panel.sh | 面板重装时 8080 被占直接拒绝 | 第一轮已排除，不走 no-op。 |

**横扫结论：还原/重装机制内无 `enable --now` / `start` no-op 残留。** F3-02 的 3 处是全部同款点（第一轮已枚举到闭合，本轮复核无新增）。

## 6. 两处遗留裁定（任务点名）

### (a) r201 p2 按分支断言与 `stop_wildhold` 轮询未在容器内实跑验证

- **代码检查通过**。`harness-guest.sh`（`audit/evidence-v016r3-fix/harness-guest.sh`）：
  - r201 p2：先判分支再断言该支末态——复活支（`resolv_is_127001 && agent_active`）断言文件 127.0.0.1 + getent 走规则 + agent 在跑；DNS 死支（`resolv_is_stub_link && agent_inactive`）断言 stub 软链 + 目标文件被写穿为 127.0.0.1 + agent 已停 + getent 全空；两支之外 FAIL 并快照（fail-safe，不静默放过）。分支覆盖与 R2 实测的两支逐字对应；第三态（普通文件 127.0.0.1 + agent 已停）会落入 else-FAIL——该态在本场景不可达（还原已跑，软链在重启时存在，写穿只走软链目标），不构成漏判。
  - `stop_wildhold`：20 次 × 0.5 秒轮询进程死 + `:53` 无 0.0.0.0 监听，最多 10 秒；超时仍返回、由调用方断言裁决（与注释一致）。
  - `bash -n` 通过。
- **裁定：不拦发版。** 两处都是台架改动、非产品代码；改动方向是 fail-safe（误判只会多报 FAIL，不会漏报 PASS）；逻辑经逐行检查成立。下次跑 r201/wildhold 相关容器场景时自然覆盖。记为 F4-05（P3，仅记录）。

### (b) 一次本地 `go test + rig` 联合执行时审批超时未答复

- **已由本轮亲手重跑解决。** 本轮在 tip 749a155 上重跑：`go test ./...` 全绿（§8）、`scripts/test-takeover-rig.sh` **145/0 exit 0**（§8），逐场景日志 30 文件齐全（`rig-20261122-0432Z-scenarios/`）。无未答复的审批、无缺失项。该遗留已闭合，不再是问题。

## 7. 新发现（F4-01~F4-05，全部 P3 仅记录，不拦发版）

| ID | 级别 | 内容 | 处置 |
|---|---|---|---|
| F4-01 | P3 | 证据 commit `749a155` 里混入一轮之前的台架日志：`audit/evidence-v016r3-fix/rig-merged.log`（基线 01a6ef8，03:32Z）与 `rig-20261122-0316Z-scenarios/`（基线 01a6ef8，stub 修补之前）。本轮权威台架证据是 0406Z（基线 65a817e，145/0）与本轮亲手重跑的 0432Z（基线 749a155，145/0）。RUN-NOTES 已披露 rig-merged.log 的来源。 | 仅记录：证据卫生，下次归档时勿把他轮日志混入；不影响本轮结论。 |
| F4-02 | P3 | `resolv_conf_matches_backup` 只比软链目标、不比目标文件内容：若 stub 目标文件本身被污染（如 r201 p2 的写穿），尾部检查会判“一致”。经核，该污染路径（开机 unit 的 `cleanup_temp_state` 写穿）只发生在还原前的 temp-state 清理，且绿版 `clear_temp_state` 已改为只删状态、不碰 resolv.conf，固定代码路径上不可达。 | 仅记录：观察项，无需为发版修；若将来有直接写目标文件的路径，再补内容比对。 |
| F4-03 | P3 | NM/netplan/resolvconf 改写 resolv.conf 的端到端场景无容器覆盖（见 §2 问题 3）。 | 仅记录：尾部逻辑已由 chroot 单元测试 9/9 覆盖；建议下次有 NM 的容器跑一次端到端；不拦发版。 |
| F4-04 | P3 | SNI“新配置已加载”验证只证重启（PID 变化），不证新进程实际服务；`Restart=always` 下启动即崩溃循环理论上可通过 is-active + PID 检查（见 §3）。 | 仅记录：本轮容器探针（DENIED）已从功能侧证实新 allowlist 生效；不拦发版。 |
| F4-05 | P3 | r201 p2 按分支断言与 `stop_wildhold` 轮询未在容器内实跑（见 §6(a)）。 | 仅记录：代码检查 + `bash -n` 通过，fail-safe 方向；下次相关容器场景自然覆盖。 |

## 8. 动态验证（本轮自己动手）

- **`go test ./...`（tip 749a155）全绿**：dnsagent ok 17.4s、panel ok、sniproxy ok，其余无测试文件。本轮区间 Go 代码无改动（F3 只改 shell），结果与修复轮 3 的归档日志一致。
- **`scripts/test-takeover-rig.sh`（tip 749a155）145/0，exit 0**：本轮亲手重跑（~9 分钟），逐场景日志归档 `audit/evidence-v016r2-fix/rig-20261122-0432Z-scenarios/`（30 文件），基线 commit `749a155445d5…`。容器阶段 2 项 UDP 断言（S0、S13 的 `dig @127.0.0.53`）在沙箱干跑中为 SKIP（沙箱回环 UDP 不通的已知预期），但该 2 项已由真容器 r215 run3 执行并 PASS（第一轮 §5），覆盖完整，无缺口。S5（含 restart 分支）在 stub 修补后已过。
- **F3-01 尾部再确认单元测试（本轮新做）**：把 `restore_resolv_conf_file` / `resolv_conf_matches_backup` **原文**（`scripts/restore-resolv.sh:718-751`）抽出，在台架 rootfs chroot（`/var/lib/machines/v016-test`）内跑 9 项：软链恢复 + 目标不动、匹配检查、管理改写检出、改写后再恢复、目标缺失时写回、文件恢复、文件匹配、文件改写检出——**9/9 全过**；跑完把 rootfs 的 `/etc/resolv.conf` 恢复为原值（`nameserver 198.19.0.1`），清掉测试残留。台架不在容器内覆盖的分支，由此补上。
- **静态检查**：`bash -n` 通过（restore-resolv.sh、install.sh、harness-guest.sh）；`scripts/check-restore-sync.sh` 通过（“还原脚本双份来源一致”）；两份 install.sh 字节一致（sha256 `0ec0b6c7…`）。
- **测试机宿主机只读核对**（本轮实测，未做写操作）：resolv.conf sha256 `4443d364e93cbe02f76a7adff16bad35872ad3307cb4d5421b837833fd81584f`（基线未动）、panel pid 2652616、agent pid 2652618、二进制 `1084e5e9…` 均为放行前原状；`machinectl` 无机器；br-v016 已删；`/var/lib/machines/` 为空；面板 :8080 HTTP 200，panel/agent 均为 active。宿主机干净。

## 9. 发版门核对（第一轮报告 §8 逐项）

| # | 项 | 状态 |
|---|---|---|
| 1 | F3-01 修完 + 容器复验（dig ×5 全走上游 + Global 为空 + getent 走上游，两路各一遍） | ✅ 绿 f301c 22/0、f301l 25/0 |
| 2 | F3-02 修完 + 容器复验（重装 rc=0 + PID 变化 + dig -p 5353；SNI allowlist 至少验一侧） | ✅ 绿 f302a 19/0、f302s 21/0（探针 DENIED） |
| 3 | F3-03 修完 + 容器复验（enabled-已停 agent 还原后为 disabled） | ✅ 绿 f303 20/0 |
| 4 | 台架修正（v12 步 4 断言、r201 p2 按分支断言、`stop_wildhold` 轮询） | ✅ v12 修正已在红/绿 f302a 双向实证；另两处代码检查通过，未容器实跑（F4-05，仅记录） |
| 5 | `go test` 全绿；台架 145/0；容器红/绿跑日志归档；宿主机核对收尾；再走一次聚焦复审 | ✅ 全部完成，本报告即第二次聚焦复审 |

**R2-01/02/04/15 与 V016-12 的状态未变**：第一轮已裁定全部已修，本轮 diff 不涉及其修复代码，无回归证据；R2-15 的 run3 137/10（零产品 FAIL）与台架 145/0 均由本轮重跑复核（rig 0432Z 145/0，基线 749a155）。

## 10. 残留登记

- F4-01~F4-05：全部 P3 仅记录，见 §7；台账已新增（`audit/findings-ledger-v016.csv`，59→64 行）。
- 仍仅记录：R2-12、R2-17、R2-18、V016-29、V016-35、V016-36（与 F3-01 同属“还原窗口”家族，但 F3-01 的修法不涉及加锁；V016-36 仍登记）。
- V016-37：已由 F3-02 跟踪（台账标注升级关系），本轮确认 fixed。
- 工作区卫生：worktree 根下仍有未入库目录 `dist-green/`、`dist-red/`（构建产物）与浏览器证据目录，建议清理或入 `.gitignore`（已提三轮，未处理）；证据 commit 里混入一轮之前的台架日志（F4-01）。
- 本复审未改产品代码、未 push/tag/发版、未碰生产面板；测试机宿主机只读核对通过（见 §8）。

## 11. 自查

- 每条 P1/P2 结论均有红证或容器/代码级实证（容器红/绿日志原文行号见 §2–§4、代码行号见 §2–§5），非复述修复方说法；F3-01/02/03 的根因均在代码中逐行确认，机制族横扫到闭合清单（还原/重装的 `enable --now` / `start` / `restart` 全量 grep，见 §5）。
- 与 RUN-NOTES 的分歧：无。手记数字逐项核对日志原文后全部采纳（红 f301c 20/2、f301l 23/2、f302a 15/3、f302s 18/3、f303 18/2；绿 f301c 22/0、f301l 25/0、f302a 19/0、f302s 21/0、f303 20/0）；手记披露的两处遗留已裁定（§6）。
- `go test` 与台架均由本轮在 tip 749a155 上亲手重跑（非引用修复方日志）；F3-01 尾部逻辑由本轮在 chroot 内用函数原文单元测试 9/9 补上容器未覆盖的分支。
