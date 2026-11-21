# v0.1.6 修复轮 — 测试机真 systemd 容器验证证据

测试机：ip-172-26-15-152（Tailscale 100.110.88.49），Debian 12，systemd-nspawn
容器 `v016-test`（debootstrap Debian 12，420MB，见 `host/rootfs-build.log`），
宿主桥 `br-v016` 10.0.5.1/24 + NAT。容器内跑真 systemd-resolved（stub 在
127.0.0.53:53），宿主跑 scratch 面板 10.0.5.1:18280（服务器 nspawn-dns，
节点 nspawn-jp 203.0.113.99 JP，tiktok 规则 → 该节点；上游 1.1.1.1）。
规则 IP 203.0.113.99；上游对 example.com 的回答如 104.20.23.154 /
172.66.147.243；tiktok 上游约 23.214.22.x。

- 红基线：`374e7b7`（二进制 sha256 `72d67c83…089955f`）
- 绿基线：`3550ebc`（二进制 sha256 `70efb3fa…b8e6ef3`）
- 时间：2026-11-21 13:34–14:07 UTC。全部 `dig` 均为 UDP（`dig +tcp` 未用作替代）。
- Token 已脱敏（日志中从未打印明文 token；归档前 scrub 校验 0 个文件含 token）。

## 红跑（旧代码，复现两个新 P1）

| 文件 | 结果 |
|---|---|
| `red/red-02.log`（+ restore1/2）| 25/25。V016-02 全复现：永久 agent 127.0.0.1:53 + stub 重开 .53 → 还原 rc=1（"agent 已停，但:53 仍被占"），agent 丢失，`dig @127.0.0.1` UDP refused，`dig @127.0.0.53 example.com` UDP 有结果，resolv.conf 仍指 127.0.0.1，系统 DNS 死；二次还原谎报 "agent 还原前未在运行"，agent 仍死。|
| `red/red-01-part1.log` / `red-01-part2.log` | 15/15 + 10/10。`--temp` + stub 冲突（答 y）写永久 drop-in `DNSStubListener=no`，stub 关，agent enabled+active（通配符 :53），无临时状态；重启后 drop-in 与自启 agent 均残留，stub 仍关。|
| `red/red-01-static-part1.log` / `red-01-static-part2.log` | 16/16 + 8/8。静态 resolv.conf（`nameserver 127.0.0.53`）变体：重启后 `getent tiktok.com` 仍走自启 agent 返回 203.0.113.99——"分流静默变永久"分支得证。|
| `red/red-01-f06.log` | 20/20。文档化 temp 退出路径（`systemctl restart systemd-resolved`，agent 占 :53）：journal 实证 `Another process is already listening on UDP socket 127.0.0.53:53.` + `Turning off local DNS stub support.`——绑定冲突得证。|

**两处审计预测修正（红跑实测）：**
- (a) V016-01 "系统 DNS 死"分支在 Debian 12 软链 resolv.conf 下**未按字面复现**：stub 关后 stub-resolv.conf 改列上游（1.1.1.1/8.8.8.8），系统 DNS 经上游仍活；`dig @127.0.0.53` 也被通配符 agent 截获而有应答。真正后果是分流静默变永久 + stub 永久关闭（静态变体得证），不是 DNS 死。
- (b) F-06 同理：绑定冲突实证，但后果是静默永久分流 + stub 死，不是 DNS 死。

## 绿跑（当前 tip，证明两 P1 已修）

| 文件 | 结果 |
|---|---|
| `green/green-02.log`（+ a/b/c 子日志）| **49/49**。V016-02：A 段 stub 误判消除（还原 rc=0，agent 新 pid 重启，`dig @127.0.0.1` tiktok UDP + `dig @127.0.0.53` example UDP 双答，resolv.conf 恢复）；B 段外来通配符 :53 持有者（还原 rc=1，"已有其他服务监听"，"agent 未动"，agent 同 pid 存活应答，resolv.conf 不变）；C 段停后出现占用者（5ms 轮询 binder 抢 :53，还原 rc=1 报 "agent 已停，但 :53 仍被占"，中止时尝试恢复 agent，待办标记已写；重跑认出上次中止、不再谎报未在运行，rc=0，agent 恢复，标记清除，双 dig UDP 应答）。附带发现：unit 的 `Restart=always` 会在占用者消失后自行复活 agent——标记路径需显式停掉 restart 循环才能测到（脚本内已注）。另：C 段一次未命中分段时走了另一合法分支（binder 晚到一步、打断 stub 重绑 → 验证失败 fail-closed，`restore_agent_after` 报 "已被占（0.0.0.0:53）"），见绿跑过程记录。|
| `green/green-01a-part1.log` / `green-01a-part2.log` | 20/20 + 8/8。`--temp` resolvectl 路径：自动改走 127.0.0.1:53（stub 不关），无 drop-in，agent 只 start 不 enable（disabled），临时状态 mode=resolvectl，无开机 unit；重启后 agent 未自启、stub 在监听、resolv.conf 指 stub、系统 DNS 正常、getent tiktok 回上游、分流失效。注：resolvectl 路径的临时状态文件重启后仍在（无开机 unit、DNS 效果已无），属惰性残留，见 part2 observation。|
| `green/green-01b-part1.log` / `green-01b-part2.log` | 21/21 + 9/9。`--temp` direct-write 路径（先停 resolved、保持 enabled）：静态 resolv.conf，临时状态 mode=direct-write（存原 resolv.conf + 原软链目标），开机清理 unit 已启用；**重启后 boot oneshot 实际触发**，journal 14:00:33：`Starting dnsunlock-temp-restore.service …`，`dnsunlock-restore-dns[53]: 临时模式清理：按 /etc/dnsunlock/temp-state 的记录恢复 DNS…`，`已恢复 /etc/resolv.conf 软链 -> /run/systemd/resolve/stub-resolv.conf`，`Deactivated successfully`；临时状态已清、unit 已自删、agent 已停、resolv.conf 回 stub 软链、resolved 在跑、stub 监听、系统 DNS 正常、分流失效。|
| `green/green-08.log` | 21/21。resolved 事先 disabled（备份 metadata resolved_enabled=no）：还原报 "实测 :53 当前空闲"，不报旧谎言 "systemd-resolved 已重新占用 :53"，agent 重启（新 pid，仍占通配符 :53），`dig @127.0.0.1` tiktok UDP 规则 IP；还原 rc=1（验证未通过，V016-10 fail-closed：resolved 仍停、resolv.conf 指死 stub）。注：原断言 "dig @127.0.0.53 无应答" 是 harness 前提错——通配符 agent 会代答 .53（ss 证实 stub 确未监听，.53 的 tiktok 应答为规则 IP，证明是 agent 代答）；断言已修正为 ss 无 stub + .53 tiktok 规则 IP。|
| `green/green-09.log` | 20/20。agent 有进程无 unit（unit 文件移走，手动 `dnsunlock dns-agent`）：还原按端口找到它、停掉、经端口回退重启（新 pid），`dig @127.0.0.1` + `dig @127.0.0.53` UDP 双答。|

## V016-12 五步补验（第二遍，最终遍，真 resolved）

`v016-12/v016-12.log`：**28/28**。
- 步 1：`--dns-listen 127.0.0.1:53` 安装 rc=0，getent tiktok 规则 IP，example 走上游。
- 步 2：还原 rc=0，resolv.conf 恢复原内容。
- 步 3：agent 恢复运行且为新 pid（2142→2401，`restore_agent_after` 重启），`dig @127.0.0.1` tiktok UDP 规则 IP，`dig @127.0.0.53` example UDP 有结果（stub 与 agent 共存）。
- 步 4：同流程于 127.0.0.1:5353：安装 rc=0，还原 rc=0，resolv.conf 恢复，agent 恢复，`dig @127.0.0.1 -p 5353` tiktok UDP 规则 IP，`dig @127.0.0.53` example 有结果，系统 DNS 可用。注：原断言 "getent tiktok 规则 IP" 是 harness 前提错——resolv.conf 无端口字段，系统 DNS 永远到不了 :5353；安装日志还显示它把 `nameserver 127.0.0.1` 写进 resolv.conf（而 agent 在 :5353），自检随即报 "验证未通过"——这是非 53 监听地址下 "系统 DNS → 127.0.0.1" 选项写死 nameserver 的产品瑕疵（V016-12 范围外，还原可干净恢复），已在步 4 断言中记录，不计失败。
- 步 5（负向）：`--dns-listen 127.0.0.53:53` 安装 rc=0（答 stub 问题 y → stub 关），还原报警告（监听地址就是 stub 地址），agent 保持停止（不抢 stub），stub 在监听，系统 DNS 可用。

## 清理（测试机）

- Scratch 服务器 `srv-1795261390217084056`（nspawn-dns）已删，token 作废（agent-config 复查 HTTP 401）。说明：API DELETE 未走成——复用的 panel.json 里 admin 密码早已不是默认（实测存储 hash ≠ bcrypt("admin")，沙箱前期已改密）；按 rig 脚本要求不猜密码，改走数据文件删除（停面板 → 删 servers/server_rules 条目 → 重启验证 401 → 再停面板），见 `host/panel-green-post-delete.log`。只动 scratch 面板，生产 `https://dns.0v0.baby` 与宿主机 panel/agent 未碰。
- `host-down.sh` 执行后核对：容器已 terminate 并删除 rootfs、iptables 规则（NAT MASQUERADE、FORWARD ×2、INPUT 18280）已删、桥 br-v016 已删、宿主机 resolv.conf sha256 与基线 `4443d364…` 一致、宿主机 panel :8080 + agent :53 原 pid 在位、machinectl 无机器、10.0.5 无残留规则。宿主机 `/root/v016-verify/`（scratch 面板数据/日志/二进制）随后整目录删除。
- 遗留：见主汇报——(1) 01a resolvectl 路径临时状态文件重启后惰性残留；(2) 非 53 监听地址写死 `nameserver 127.0.0.1` 的瑕疵；(3) V016-02 C 段 binder 晚到时走的 stub-重绑失败分支（已记录，非失败）；(4) 两处审计预测修正（上文 (a)(b)）；(5) scratch 面板 admin 密码非默认，API 删除路径不可用（数据文件删除已代行）。
