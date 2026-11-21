# v0.1.6 修复轮 · 台架线证据（audit/evidence-v016-fix/）

审计硬性要求：本轮起所有台架/验证日志归档进仓库，每次运行写清时间、基线
commit、命令、结果。P1 修复方上轮“容器红跑绿跑”无任何可查日志，审计是靠
自己重跑才信的——本目录就是对该缺口的补救。

## 运行记录

| 运行 | 时间（UTC） | 基线 commit | 命令 | 结果 |
|---|---|---|---|---|
| B 线 run 1（审计） | 2026-11-21 约 11:28–11:37 | 374e7b7 | `scripts/test-takeover-rig.sh` | 125 PASS + 2 FAIL（S14 + S9b） |
| B 线 run 2（审计） | 2026-11-21 约 11:32–11:39 | 374e7b7 | 同上 | 125 PASS + 2 FAIL（S14 + S9b） |
| 修复轮第 1 跑 | 2026-11-21 12:16:20–12:19:25 | 8ce547b（fix/v016-rig tip，产品代码仍为 374e7b7） | `bash scripts/test-takeover-rig.sh` | 98 PASS + 45 FAIL——**作废**，见下“并发碰撞” |
| 修复轮第 2 跑（干净） | 2026-11-21 12:20:40–12:28:59 | 8ce547b（同上） | `bash scripts/test-takeover-rig.sh` | **143 PASS + 0 FAIL** |

基线说明：本 worktree 分支 fix/v016-rig 的产品代码仍是 374e7b7（v0.1.6
实施 + P1 修复后的 tip），未含 shell/Go 线的修复。沙箱全绿不等于发版门
已过——合并后（V016-01/02/06 等产品改动落地）必须重跑全台架作回归门；
容器阶段的 UDP 断言仍待 nspawn 补验（V016-12）。

## 文件清单

- `rig-run-B-lane-1.log` / `rig-run-B-lane-2.log`：B 线两次全量重跑的
  stdout（审计留下的 /tmp/rig-run-1.log、/tmp/rig-run-2.log 原样归档），
  125+2，与上报的 126+1 / 127 对不上——见下 S9b 对账。
- `s9b-restore.log.B-lane-pre-fix`：B 线重跑留下的 s9b-restore.log
  （chroot 内 /root/rig/logs/ 的最后一份；最早备份 20261121-113248、
  pre-restore 20261121-113711，应为 run 2 的）。
- `rig-run-fix-20261121-1216-COLLIDED.log`：修复轮第 1 跑，作废，见下。
- `rig-run-fix-20261121-1220.log`：修复轮第 2 跑（干净），143+0。
- `s9b-restore.log`：第 2 跑的 s9b-restore.log（本次 --backup 显式还原）。

## S9b 对账（V016-14）

B 线日志原文（`s9b-restore.log.B-lane-pre-fix`）：

```
非交互模式：默认还原最早的一份（原始状态）: /var/lib/dnsunlock/backup/20261121-113248_pre-takeover
已还原 /etc/resolv.conf <- /var/lib/dnsunlock/backup/20261121-113248_pre-takeover/resolv.conf
```

即 `--yes` 按设计还原了最早一份（base，198.19.0.1），旧断言期待 hpve
（1.1.1.1）是错的；B 线 125+2 与上报 126+1 / 127 的差额正是这一项
（另一项 S14 见 V016-13）。本轮 S9b 改用 `--backup <本次备份> --yes`
显式还原，第 2 跑日志（`s9b-restore.log`）原文：

```
从备份还原: /var/lib/dnsunlock/backup/20261121-122612_pre-takeover/（pre-takeover，2026-11-21T12:26:12+0000）
已还原 /etc/resolv.conf <- /var/lib/dnsunlock/backup/20261121-122612_pre-takeover//resolv.conf
```

12:26:12 正是 S9b 当次接管前备份（hpve 内容），断言通过。

## 并发碰撞（第 1 跑作废的原因）

第 1 跑（12:16:20 起）与另一条 lane 的台架全量重跑在同一沙箱内撞车，
共享 `/var/lib/machines/v016-test`（rootfs + $RIG）与 `/tmp/rig-panel/`：
对方 12:17:57 在 18181 起了第二个 panel（本跑面板在 18180），`rm -rf $RIG`
清掉了本跑的台架文件，两边互相覆盖备份/agent pid/markers/logs。证据：
本跑 agent.log 同时出现 18180 与 18181 两个面板的 agent；markers.log 全程
无 `stop dnsunlock-agent`；s3.log 走进“没有找到永久备份”分支；S4 起安装
一律报 `:53 已被占用`。第 1 跑的 98+45（含 S14/S9b 的个别 PASS）均不可采信。
第 2 跑起跑前已确认无残留 rig/panel 进程、18180–18185 端口全空闲，单跑，
143+0 可采信。教训：台架共享 rootfs 与 /tmp 路径，多 lane 并行必撞——
以后重跑前先确认无他人在跑（`ps` + `ss -tln`）。

## 断言分阶段表（V016-15）

沙箱阶段（第 2 跑已跑，全部 PASS）：

- S0/S13：`dig +tcp @127.0.0.53` 返回规则 IP（TCP 对照）；
- S13：还原前 agent 在运行、还原调过 `stop dnsunlock-agent`、还原后
  agent 已停、`:53` 已释放、还原后 `.53` 不再应答、二次还原仍保持停止；
- S11：还原调过 stop/start、还原后 agent 已恢复运行、15353 端口 dig
  返回规则 IP。

容器阶段（沙箱里只打印 `[SKIP-容器阶段]`，不计 PASS/FAIL）：

- S0/S13：`dig @127.0.0.53`（UDP）返回规则 IP——沙箱回环 UDP 本身不通，
  绝不在沙箱硬编通过；入口见 `scripts/rig/nspawn-v016-verify.sh`
  （V016-12 补验步骤 3/4，UDP 真查回包源）。

## nspawn 补验准备状态（V016-12，只准备，未跑）

- 镜像 `/var/lib/machines/v016-nspawn`（本沙箱内，Ubuntu 24.04 +
  systemd + resolved + dig，375M；resolved 上游 198.19.0.1；
  systemd-networkd 已 mask；`/root/v016/case.env` 含面板
  http://127.0.0.1:18280 + token + server id）与宿主面板数据
  `/tmp/nspawn-panel/panel.json`（服务器 nspawn-dns、节点 nspawn-jp
  203.0.113.99、tiktok 规则）均确认仍在；测试机上两者均不存在。
- 补验脚本：`scripts/rig/nspawn-v016-verify.sh`（审批门
  `NSPAWN_VERIFY_APPROVED=1`，未跑，等用户放行）。
- 续跑后轮换/删除测试服务器，日志归档进本目录（`nspawn-verify-<时间>.log`）。
