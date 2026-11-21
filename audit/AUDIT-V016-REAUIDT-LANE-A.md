# v0.1.6 复审 A 线：P1 修复深挖（V016-00 / V016-01 / V016-02）

- 范围：只审修复 diff（`374e7b7..7b86d49`，tip `7b86d49`），不重审整个仓库。
- Worktree：`~/workspace/dns-unlock-panel-v016`，分支 `feature/v0.1.6-takeover`，基底 v0.1.5（`817c606`）。
- 复审人：A 线（P1 修复深挖）。日期：2026-11-21。
- 方法：先核对修复轮证据（`audit/evidence-v016-fix/test-machine-container/`），再用自建 nspawn 容器重跑红/绿对照；每个 P1 均有独立红/绿证。
- 本线证据归档：`audit/evidence-v016-reaudit-lane-a/`（37 个日志文件：各场景主日志 + install/restore 子日志）。
- `go test ./...` 已重跑：EXIT=0，全部 ok（dnsagent 17.132s，panel/sniproxy cached），日志 `/tmp/lane-a-gotest.log`（沙箱侧）。

## 验证环境（自建，与他人不冲突）

- 测试机 ip-172-26-15-152（Tailscale 100.110.88.49）宿主机**未动**：仍为已恢复的 v0.1.5（panel :8080 + agent :53，二进制 `1084e5e9…`），宿主 `/etc/resolv.conf`（Tailscale 管理）从未接管；跑前 sha 记录在宿主 `/root/lane-a/host-setup.log`。
- 容器：machine 名 `v016-lanea`，Debian 12 debootstrap rootfs `/var/lib/machines/v016-lanea`，桥 `br-v016a 10.0.6.1/24` + NAT，容器 10.0.6.2，上游 DNS 1.1.1.1。
- Fake 面板跑在宿主 10.0.6.1:18281：whoami → `srv-lanea`；config → tiktok.com → 203.0.113.99（JP），upstream 1.1.1.1；按 phase 文件（v015|red|green）下发对应相位的 install.sh 与二进制。测试 token `lane-a-test-token`（仅测试用）。
- 二进制溯源：dist-red `72d67c83…089955f` 与我从 `git archive 374e7b7` 重建的完全一致；dist-green `70efb3fa…b8e6ef3` 是 3550ebc 的构建（非 tip）；tip 重建 `640ad180…`，唯一差异原因是面板二进制内嵌 `assets/install.sh`，该文件在 f1b0722（V016-08 纯 shell 修复）中变过——3550ebc 与 7b86d49 间无任何 Go 改动，`git archive 7b86d49` 构建与 worktree 构建 hash 相同。因此绿跑用 tip 重建二进制，不用 dist-green。
- Harness：`/root/lane-a/guest.sh`（容器内）+ binder（5ms 轮询抢 :53）+ 裸 UDP 探针；场景用 transient systemd service 脱离跑（SSH 长会话会断，`machinectl shell` 退出码不可信，以日志内 `=== SUMMARY ===` 为准）。重启用 `machinectl reboot`，以 `journalctl --list-boots` 出现新 boot 为证。

## 总表

| 场景 | 相位 | 结果 | 结论 |
|---|---|---|---|
| r00 | v0.1.5（V016-00 红） | PASS=10 FAIL=0 | 还原后 agent 仍在跑、stub 死、系统 DNS 死、还原 rc=0 |
| g00 | tip（V016-00 绿） | PASS=13 FAIL=0（重跑；首跑 12/13，唯一 FAIL 是我方过严检查，已对齐产品标准） | 还原后 stub 恢复、裸探针回包源 127.0.0.53:53（pktinfo）、agent 保持停止、rc=0 |
| r02 | 374e7b7（V016-02 红） | PASS=17 FAIL=0 | 还原 rc=1、agent 悄悄丢失、二次还原谎报“未在运行” |
| g02a | tip（V016-02 绿 A 段） | PASS=15 FAIL=0 | stub 误判消除、还原 rc=0、agent 新 pid 恢复、双 dig 应答 |
| g02b | tip（V016-02 绿 B 段） | PASS=10 FAIL=0 | 外来通配符 :53 占位 → 停前中止 rc=1、agent 未动、resolv.conf 未动 |
| g02c | tip（V016-02 绿 C 段） | PASS=14 FAIL=0（最终；前两次命中 binder-晚到 C2 分支，见下） | 停后复查中止 + 待办标记 + 停 restart 循环后重跑恢复 |
| g02probe | tip（残留探针） | PASS=4 FAIL=0（观察项，不裁决） | **确认新残留 V016-02-R1（P2）**，见下 |
| r01p1 | 374e7b7（V016-01 红 p1） | PASS=8 FAIL=1（唯一 FAIL 已解释，见下） | --temp 写永久 drop-in、agent enable、无 temp-state、stub 关 |
| r01p2 | 374e7b7（V016-01 红 p2，重启后） | PASS=9 FAIL=0 | 持久状态全部残留；“系统 DNS 死”未按字面复现（见预测核对） |
| g01ap1 | tip（V016-01 绿 01a p1） | PASS=11 FAIL=0 | resolvectl 路径：无 drop-in、只 start、temp-state mode=resolvectl、无 boot unit |
| g01ap2 | tip（V016-01 绿 01a p2，重启后） | PASS=6 FAIL=0 | agent 未自启、stub 在、分流失效；**01a 惰性残留已确认** |
| g01bp1 | tip（V016-01 绿 01b p1） | PASS=9 FAIL=0 | direct-write 路径：mode=direct-write、开机 oneshot 已装并启用 |
| g01bp2 | tip（V016-01 绿 01b p2，重启后） | PASS=8 FAIL=0 | oneshot 实际触发、状态清、unit 自删、resolv.conf 回软链 |

---

## V016-00（原 P1：还原弄坏系统 DNS）—— verdict：已修

- 代码核对：e5dafe6 + ff006ca 均为 7b86d49 的祖先；`check-restore-sync.sh` 通过（三份还原脚本一致）；`record_and_stop_agent` 是 `restore_from_dir` 与 `restore_legacy` 的第一调用；pktinfo 代码仍在且含 V016-11 修复（先试 IPV6_RECVPKTINFO、失败回退 IP_PKTINFO 并记日志）。
- 红证 r00（v0.1.5）：还原后 agent 仍在运行、stub 死、dig @127.0.0.53 超时、裸探针回包源错为 127.0.0.1:53（内容对、has_rule_ip=True）、系统 DNS 死、还原 rc=0。10/10。
- 绿证 g00（tip）：还原 rc=0、agent 保持停止、stub 恢复、dig @127.0.0.53 tiktok UDP 返回规则 IP、裸探针回包源为 127.0.0.53:53（pktinfo 生效）。13/13（重跑；首跑唯一 FAIL 是我方 `getent_example_ok` 要求 IPv4 行、严于产品自身“getent 有任何结果即通过”的标准，已对齐后重跑全过）。
- 结论：修复在 7b86d49 上仍成立，未被修复轮其它改动破坏。

## V016-01（新 P1：临时模式留持久状态）—— verdict：已修

- 代码核对：临时模式绝不调 `disable_stub_listener`、通配符冲突自动改走 127.0.0.1:53、agent 只 start 不 enable、temp-state 三路径都写、开机 oneshot 只装 direct-write 路径、退出提示不再叫人直接 restart resolved、永久接管清 temp-state。
- 红证 r01p1 + r01p2（374e7b7）：p1 证实 --temp 写永久 drop-in（DNSStubListener=no）、agent 已 enable、temp-state 缺失、stub 已关；p2（重启后，journal 确认新 boot，agent pid 53 于 15:07:10 开机自启）证实 drop-in 还在、agent 仍自启、stub 仍关、resolv.conf 已无 127.0.0.53、getent tiktok 走上游、dig @127.0.0.1 与 @127.0.0.53 均返回规则 IP（通配符 agent 截获 .53 查询，分流静默变永久）。p1 8/9、p2 9/9。
  - p1 唯一 FAIL 说明：`安装后 getent tiktok 返回规则 IP`。原因是红版 --temp 的 resolvectl 路径在 stub-resolv.conf 里把上游 1.1.1.1 列在 127.0.0.1 之前，glibc getent 先走上游；agent 本身正常（同一快照内 `dig @127.0.0.1 tiktok` 返回规则 IP 203.0.113.99）。这是红版行为本身，不影响红证的 5 个持久化要点。
- 绿证 01a（resolvectl 路径）：g01ap1 11/11（无 drop-in、agent 未 enable 只 start、stub 未关、temp-state mode=resolvectl;iface=host0;listen=127.0.0.1:53;agent_was_active=0;agent_was_enabled=0、无 boot unit、getent tiktok 返回规则 IP、退出提示已改）；g01ap2 6/6（重启后 agent 未自启、stub 在、resolv.conf 指 stub、系统 DNS 正常、分流已失效）。
- 绿证 01b（direct-write 路径，先停 resolved）：g01bp1 9/9（mode=direct-write、开机清理 unit 已装并启用、resolv.conf 变成写有 127.0.0.1 的普通文件、getent tiktok 返回规则 IP）；g01bp2 8/8（重启后 oneshot 实际触发、临时状态已清、unit 已自删、resolv.conf 回到软链、stub 在、系统 DNS 正常、分流已失效）。
- 结论：已修。两条路径重启后均无持久分流、无自启 agent。

## V016-02（新 P1：还原 :53 检查误判且在停 agent 后中止）—— verdict：已修，另有 1 个新残留（P2，见 V016-02-R1）

- 代码核对：停前按冲突检查（stub_blockers，排除 127.0.0.53/54 stub 与 agent 自身）、停后 10 秒复查 + `abort_restore_agent`、待办标记 `/etc/dnsunlock/agent-restore-pending`、重跑认标记不再谎报。
- 红证 r02（374e7b7）：还原 rc=1、agent 悄悄丢失、dig @127.0.0.1 拒绝、resolv.conf 未还原、系统 DNS 死、二次还原谎报“agent 还原前未在运行”。17/17。
- 绿证 A 段 g02a：stub 误判消除、还原 rc=0、agent 新 pid 恢复、dig @127.0.0.1 与 @127.0.0.53 双答、resolv.conf 恢复。15/15。
- 绿证 B 段 g02b：外来通配符 :53 占位（agent 在 127.0.0.1:5353）→ 停前中止 rc=1、agent 未动（同 pid、仍应答）、resolv.conf 未动。10/10。
  - 附带 lane 外观察：`--dns-listen 127.0.0.1:5353` 的永久安装因系统 DNS 到不了 5353 上的 agent，安装脚本触发“升级处理，彻底停用 systemd-resolved（`systemctl disable --now systemd-resolved`）”（install.sh:1260-1263，代码注释中写明是预期行为）——与已登记的 V016-27（非 53 监听写死 nameserver 127.0.0.1）同源，记入即可，不属本线裁决。
- 绿证 C 段 g02c：最终 14/14。中止分支证据：还原 rc=1，日志报“agent 已停，但 :53 仍被占”（停后复查分支）、`abort_restore_agent` 尝试把 agent 起回来（agent 呈 activating，Restart=always 循环）、待办标记已写（listen=127.0.0.1:53，timestamp=2026-11-21T14:59:13+0000）、中止时 resolv.conf 未动（仍 nameserver 127.0.0.1）；清 binder、显式停 restart 循环后重跑：rc=0、不再谎报“还原前未在运行”、agent 已恢复（新 pid 6216）、标记已清、dig @127.0.0.1 tiktok 返回规则 IP。
  - 过程说明：前两次跑命中 binder-晚到分支（C2）：binder 在 post-stop 首次检查之后才抢到 :53，还原完成但验证失败 fail-closed rc=1，`restore_agent_after` 报“已被占（0.0.0.0:53）”。这是合法分支（见 Restart=always 裁决）。第三次用 5ms 轮询 binder（与修复轮一致，50ms 轮询两次都输给还原循环的即时首次检查）拿到 C1。
  - Harness bug 说明：中间一次 13/14 的唯一 FAIL 是我方检查 `ss | grep '0.0.0.0:53'` 会误匹配 resolved 的 LLMNR 端口 0.0.0.0:5355（子串），已改锚定 `'0.0.0.0:53 '` 后重跑 14/14。产品代码的 `stub_blockers` 用 `awk '$5 ~ /:53$/'` 锚定，无此问题。
- 结论：V016-02 指定的 A/B/C 三段均已修。

### V016-02-R1（新残留，P2，不挡发版）：agent 未在跑时 unit 路径跳过停前检查

- 代码位置：`scripts/install.sh`（与 `internal/panel/assets/install.sh` 同步）`record_and_stop_agent()`，`[ "$AGENT_WAS_ACTIVE" = 1 ] || return 0` 在停前 `stub_blockers` 检查之前；无 unit 路径 `record_and_stop_agent_no_unit()` 则先检查后动手，两路径不对称。
- 实测（g02probe，agent 已停 + 外来通配符 :53 占位）：还原 rc=1，但**先改了状态、后失败**——resolv.conf 软链已恢复（指 stub-resolv.conf）、drop-in 已删（resolved 尝试重开 stub 但抢不到 :53），最后 `verify_after_restore` 失败才 fail-closed exit 1（“已还原但验证未通过（getent hosts example.com 无结果）”）；终态：系统 DNS 死（stub 抢不到 :53）、agent 仍停、无待办标记；清除占位者后重跑可恢复。
- 定级：P2。触发条件窄（agent 已停 + 外来 :53 占位同时成立），fail-closed 兜底诚实（exit 1 + 明说重跑），恢复路径明确（清占位 → 重跑）。但“先改状态后失败”违背 V016-02 修复的设计意图（“此时还没改系统 DNS 配置，只写了一份还原前备份”）。建议下轮修：把 `stub_blockers` 停前检查提到 `AGENT_WAS_ACTIVE` 早返回之前（无论 agent 是否在跑都先查），与无 unit 路径对齐。修法小，列入下轮，不挡本次发版。

---

## 必须裁决的新事项

### 1. 01a 惰性残留 —— verdict：确认存在，P3，不挡发版，下轮修

- 实测（g01ap2）：重启后 temp-state 文件 `/etc/dnsunlock/temp-state/state` 仍在，内容 `mode=resolvectl;iface=host0;listen=127.0.0.1:53;agent_was_active=0;agent_was_enabled=0;timestamp=2026-11-21T15:09:38+0000;`；无开机 unit、无 DNS 效果（agent 未自启、stub 在、resolv.conf 指 stub、分流已失效）。
- 定级：P3。只是 /etc 下一条陈旧记录文件，无任何运行时影响；下次 --temp 安装会重写它。建议下轮修：resolvectl 路径的状态改放 /run（tmpfs，重启自动消失），或在下次安装/agent 启动时清理过期 temp-state。direct-write 路径已有 oneshot 清理，不受影响。

### 2. Restart=always 自行复活 agent + C 段 binder-晚到分支 —— verdict：无问题，无需修

- 实测（g02c）：中止后 agent unit 呈 activating，Restart=always + RestartSec=3 使其每 3 秒重试启动（占位者在时起不来，占位者消失后自行恢复）。这是自愈收敛，不是缺陷：待办标记在下次还原运行时被 `is-active` 检查正确消费（重跑不再谎报、agent 恢复、标记清除）。测试时须显式停掉 restart 循环才能测到标记路径——g02c 已如此做并通过。
- C2 分支（binder 晚到，还原完成但验证失败、agent 起不回）是合法的 fail-closed 分支：还原已完成、rc=1 诚实报错、agent 未悄悄丢失（unit 仍在重试循环里）。无需修；harness 侧用 5ms 轮询 binder 即可稳定命中 C1。
- 附带：V016-12 的 28/28 与修复轮证据一致，未发现回归。

### 3. 审计预测修正的实测核对（“系统 DNS 死”分支）—— verdict：实测成立，措辞以实测为准，严重性不变

- 实测（r01p2，红版重启后）：resolv.conf 仍为软链 → `/run/systemd/resolve/stub-resolv.conf`，但内容已改列上游 `nameserver 1.1.1.1`（两行）；getent example.com 与 tiktok 均经上游正常返回（tiktok 走上游 23.214.22.x，未进分流）；stub 永久关闭（drop-in 残留）；agent 仍占通配符 :53，dig @127.0.0.1/@127.0.0.53 tiktok 均返回规则 IP。
- 结论：Debian 12 软链 resolv.conf 下，“系统 DNS 死”未按字面复现——真正后果是**分流静默变永久 + stub 永久关闭**，系统 DNS 靠上游仍活。V016-01 的严重性不变（用户以为临时、实际永久，且 stub 被关），但审计报告与发布说明中的措辞应按此实测写，不再称“系统 DNS 死”。

## 产品决定建议：V016-10 —— 建议加 `--force`（仅还原 + uninstall 透传，大声警告，绝不默认）

- 现状确认：install.sh 全文无 `--force`；`verify_after_restore`（:1877）失败 → 还原 exit 1（:2246-2249、2266-2269），措辞“请检查 DNS 配置，确认无误后可重跑还原”。
- 建议加，理由：
  1. fail-closed 无逃生口会把验证永不过的环境困在脚本化路径之外：例如上游不可达的离线机器（getent/dig 验证永不过）、或 V016-02-R1 场景中占位者暂时清不掉但操作者明确要先恢复 resolv.conf 的情况——此时 exit 1 是正确的默认，但不应是唯一出口。
  2. 操作者本就是 root，且还原前已写 pre-restore 备份，`--force` 还原是可逆的（可再从备份恢复），风险可控。
  3. 形态：只给 `dnsunlock-restore-dns --force` 与 uninstall 透传；触发时大声警告（说明跳过了哪项验证、当前 DNS 状态、如何回滚）；绝不作为默认、不进入面板一键路径、不静默。
- 最终决定权在用户。

## Lane 外观察（记入，不裁决）

- g02b：`--dns-listen 127.0.0.1:5353` 永久安装触发 `systemctl disable --now systemd-resolved`（install.sh:1260-1263，代码内写明是预期升级处理），与 V016-27 同源。
- r01p1：红版 --temp 的 resolvectl 路径在 stub-resolv.conf 里把上游列在 127.0.0.1 之前，glibc getent 先走上游（agent 本身正常）。绿版无此问题（stub 在，getent 走 agent）。
- Harness 踩坑（已修，勿重犯）：`ss` 输出是 `127.0.0.53%lo:53`（grep 须用 `127.0.0.53`）；dig 的 communications error 写 stdout；`tee` 缓冲 + machinectl scope 拆除会丢 SUMMARY 尾行（summary 前 sleep 2）；`getent_example_ok` 应与产品标准对齐（有任何输出即通过）；reset 须先 `chattr -i` 再处理 resolv.conf 并 `systemctl enable systemd-resolved`；SSH 长会话会断——场景用 transient systemd service 脱离跑，只读日志文件轮询。

## 未覆盖（属 UI 线，不由本线裁决）

- 浏览器点按的 OPEN 项：results-retest.json 标 C7br/C7cr（分服务器复制命令）FAIL，但保存的命令文件显示单条正确 token——脚本与面板数据已删，父代理无法裁决。本线不覆盖，复审结论 PASS 之前该项须由 UI 线另行裁决（重跑检查或追踪 copyServerInstall）。

## 本线 verdict：PASS（有条件）

- V016-00、V016-01、V016-02 三个 P1 均已修，红/绿证据齐全（上表），go test 全过，修复轮证据计数核对一致。
- 条件：两个非阻塞残留列入下轮——V016-02-R1（P2：agent 未在跑时 unit 路径跳过停前检查）、01a 惰性残留（P3：resolvectl 路径 temp-state 重启后仍在）。均不挡本次发版。
- V016-10 建议加 `--force`（见上），由用户最后定。
