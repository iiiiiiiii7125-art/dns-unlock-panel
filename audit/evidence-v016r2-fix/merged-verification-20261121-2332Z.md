# 合并树沙箱验证（v0.1.6 修复轮 2，分支 feature/v0.1.6-takeover）

- 基线 commit：`98e03ce`（merge: fix round 2 rig lane (R2-14/15, G-1/G-2)）
- 验证时间：2026-11-21 22:51–23:32Z
- 结论：**合并树未通过台架门（PASS=138 FAIL=5，exit 1），不是要求的 PASS=143 FAIL=0。**
  5 项失败全部是合并且引入的期望漂移（见根因），在两次独立台架运行（全量 + R2-15 干跑）中逐项复现，确定性问题，非偶发。

## 1. go test ./...

- `go test ./...` exit 0：dnsagent ok（17.0s），panel/sniproxy ok（cached）。
- 另强制新鲜跑 `go test -count=1 ./...` exit 0：dnsagent 17.8s，panel 1.3s，sniproxy 0.3s。
- 日志：`go-test-merged-20261121-2251Z.log`；vet + 强刷结果在 `static-merged-20261121-2251Z.log`。

## 2. 完整台架 scripts/test-takeover-rig.sh

- `rig-20261121-2308Z.log`：**PASS=138 FAIL=5，exit 1**（逐场景日志 `rig-20261121-2308Z-scenarios/`，30 文件）。
- 失败项（5）：
  1. S11 输出升级处理
  2. S11 输出验证未通过警告
  3. S11 systemctl 记了 disable --now resolved
  4. S11 resolv.conf 仍是 127.0.0.1
  5. S14 verify_rule_domain 规则 IP 一致 → rc 0
- 其余 138 项全过；S0/S13 容器阶段各 1 条 SKIP-容器阶段（沙箱预期，共 2 条）。

### 根因 A：S11（4 项）—— R2-02 修复改了行为，台架期望还是旧行为

- S11 用 `--dns-listen 127.0.0.1:15353` 跑安装，旧期望：照常尝试接管 → 验证失败 → 打印“升级处理/验证未通过”→ disable resolved。
- 合并树行为（`scripts/install.sh:1179`，shell lane `effa9bb fix(R2-02)`）：非 53 端口直接拒绝接管（`监听端口不是 53……本次不接管`，TAKEOVER="n"），根本不到验证环节。见 `rig-20261121-2308Z-scenarios/s11.log`。
- 为什么 rig lane 自己的 2218Z 跑过了：那次基线是 `570b631`，`git merge-base --is-ancestor effa9bb 570b631` 为假——rig lane 从 7b86d49 分支，未含 shell lane 的 R2-02 修复，其 install.sh 里没有该守卫（`grep -c '监听端口不是 53'`：570b631=0，98e03ce=2）。即 rig lane 验证的是合并且前的 install.sh。
- 定性：台架期望过期，不是产品回归；S11 需按 R2-02 新行为改期望（或协调员另定）。佐证：S6 的“验证失败后 disable resolved”升级路径本身仍通过，升级逻辑未坏。

### 根因 B：S14 verify_rule_domain（1 项）—— R2-09 删了 grep 兜底，chroot 里无 JSON 解析器

- 合并树 `verify_rule_domain`（`scripts/install.sh:318`）：只认 python3 或 jq 解析 agent 配置；两者皆无则 return 2（跳过）。R2-09 删掉了旧的 grep/paste 兜底（570b631 仍有该兜底，98e03ce 无）。
- chroot 里：真 python3/jq 均无（重建的 rootfs 未含；`ls /usr/bin` 确认），PATH 上的 python3 是台架 stub，只实现 can_bind_listen，其他调用一律 exit 1（`scripts/rig/stubs/python3`）。故解析失败 → return 2 → 断言 rc 0 失败。另一条“非规则 IP → rc 1”通过（expect_fail 对 rc 2 也放行，不能反证解析成功）。
- 定性：合并集成缺口。修法由协调员定：给台架 rootfs 装 python3/jq、或改 S14 期望、或产品恢复安全兜底。

## 3. R2-15 干跑（RIG_CONTAINER_STAGE=1）

- `rig-20261121-2321Z.log`：**PASS=138 FAIL=7，exit 1**（逐场景 `rig-20261121-2321Z-scenarios/`，30 文件）。
- **SKIP-容器阶段 = 0 条**：容器分支真正执行。
- 7 项失败 = 上述 5 项合并缺口 + S0/S13 容器阶段 UDP 断言各 1 项（沙箱 UDP 回环不通，预期失败；TCP 对照均通过）。
- 与 rig lane 2228Z 干跑（PASS=143 FAIL=2）相比，多的 5 项正是根因 A/B。

## 4. 静态复核（全过，见 static-merged-20261121-2251Z.log）

- `go vet ./...` exit 0。
- `bash -n` 全部 `*.sh`：真 shell 脚本全过；唯一“失败”是 `scripts/sync-restore.sh`——它是 Python 脚本（shebang `#!/usr/bin/env python3`），`python3 -m py_compile` 通过，非缺陷。
- `scripts/check-restore-sync.sh` exit 0（双份来源一致）。
- 两份 index.html 内联 JS：各 1 个 `<script>` 块（39445 字符），`node --check` 均通过。
- 三对嵌入资产字节一致（cmp）：web/index.html、scripts/install.sh、data/platforms.json 与 internal/panel/assets/ 内对应文件 sha256 相同。

## 5. 台架 rootfs 重建（本次验证的环境事件）

- 22:51 检查时 `/var/lib/machines/v016-test` 还在（243M）；23:02 起跑时已消失（目录为空），首跑以 `台架 rootfs 不存在` exit 1（`rig-20261121-2302Z.log`）。消失原因不明，未追查（非本任务范围；沙箱 /var/lib/machines 在此期间被清空）。
- 按 B 线先例（AUDIT-V016-LANE-B.md）重建：`debootstrap --variant=minbase` Ubuntu noble；首试 `--include=dnsutils` 失败（noble 无 dnsutils 包），改用 `bind9-dnsutils,bind9-host` 后 exit 0。最终命令：
  `debootstrap --variant=minbase --include=curl,bind9-dnsutils,bind9-host,iproute2,procps,util-linux,ca-certificates noble /var/lib/machines/v016-test http://archive.ubuntu.com/ubuntu`
  （curl/dig/host 是台架必需，minbase 不含）。重建后 206M，curl/dig/getent/host/ip/script/ss 俱全。日志：`rebuild-rootfs-20261121-2303Z.log`。
- 注意：rig lane 原 rootfs（217M）的精确 debootstrap 参数仓库里无记录；本次重建参数如上，供后续复现。

## 6. 跑后状态

- 两次台架跑完均确认：无残留 rig 进程；127.0.0.1:53、127.0.0.53:53、127.0.0.1:15353、127.0.0.1:18180 全空闲；单跑锁已释放（文件在，无持有者，flock 机制正常）。R2-14 跑前检查（单跑锁 + 端口复查）两次均正常生效。

## 遗留项（等协调员）

1. **合并树台架门未过**：S11（R2-02 期望漂移）与 S14（R2-09 解析器缺失）需一轮修复/期望调整，再重跑台架复核。
2. 容器阶段 UDP 断言（S0/S13）仍只能在 nspawn 真容器里验证，沙箱预期失败。
3. `/var/lib/machines/v016-test` 曾在 22:51–23:02 间无故消失；本次已重建（206M），后续 lane 共用该 rootfs 时注意它可能再次被清。
4. 沙箱 exec 曾两次报“approval timed out / pending approval correlation”横幅，但命令输出证明实际均已执行完成（go test/vet/rig 日志齐全）；如协调员侧的审批记录有异，以日志文件为准。
5. 未动产品代码，未 push，未打 tag，未发版；未碰共享树 ~/workspace/dns-unlock-panel、生产面板与测试机。
