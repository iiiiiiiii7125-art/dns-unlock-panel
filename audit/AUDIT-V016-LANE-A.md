# v0.1.6 全量审计 — A 线：P1 修复深挖（findings）

- 审计范围：worktree `~/workspace/dns-unlock-panel-v016`，分支 `feature/v0.1.6-takeover`，tip `374e7b7`（基底 v0.1.5/main `817c606`）
- P1 修复两 commit：`e5dafe6`（P1(a) 还原前先停 agent）、`ff006ca`（P1(b) agent 用 IP_PKTINFO 按查询目标地址回包）
- 只读审计：未改 worktree 代码，未 push/tag/发版，未碰生产面板 https://dns.0v0.baby（测试机宿主机仅只读检查）
- 审计方法：逐行读代码 + 内核头文件对照 + Go 单元测试 + 自建台架（mount 命名空间 + stub systemctl/ss）在新旧两版还原脚本上跑 10 个场景 + 测试机 netns 活体复现（新旧二进制对照，已完成）
- Go：`~/go/bin/go`（go1.25.1）

## 证据总览（先说结论）

| 声称 | 核查结果 |
|---|---|
| P1 修复方：容器红跑复现了 P1、绿跑全部通过（dig @127.0.0.53 正常、还原已验证、临时模式正常） | **证据缺失**：本地、worktree、测试机三处均找不到容器日志 / dig 输出 / journal / rig 汇总。见 [E-1](#e-1-p1-红绿跑证据缺失) |
| rig 126 PASS + 1 FAIL（S14 verify_rule_domain） | worktree 内无 126 PASS 汇总产物；`rig-inner.sh` 中没有任何断言覆盖 P1(a) 的 stop 行为或 P1(b) 的 127.0.0.53 回包；S14 的 dig 一律 `+tcp @127.0.0.1`，与 P1(b) 无关。见 [E-2](#e-2-rig-不能证明-p1ab) |
| /tmp/p1-rig-rerun.log（本地可读） | 仅 2 行：`台架 rootfs 不存在: /var/lib/machines/v016-test`、`RIG-RERUN-EXIT=1`。本地 rootfs 已不存在，复跑失败。测试机上 `machinectl list` 为 `No machines.`，`/var/lib/machines/` 为空。 |

## A-1 P1(a)：还原前先停 agent

### 代码位置

`scripts/restore-resolv.sh:100-168`（`record_and_stop_agent` / `restore_agent_after`），
两份内嵌副本经 `scripts/check-restore-sync.sh` 验证与之一致（本审计实测通过，输出
`还原脚本双份来源一致（两份 install.sh 内嵌 == scripts/restore-resolv.sh，且两份 install.sh identical）`）。

### 核查结论（逐项）

1. **agent 在哪里停**：`restore_from_dir()`（:280）与 `restore_legacy()`（:353）的第一行即调
   `record_and_stop_agent`，在 `chattr -i`、删 drop-in、恢复任何后端文件、`systemctl restart/enable --now systemd-resolved`
   之前。主流程先跑 `do_backup "pre-restore"`（只写一份新备份目录，不动 resolved、不重启任何服务），再进还原函数。
   台架 markers 顺序证实：`stop dnsunlock-agent → enable --now systemd-resolved → restart systemd-resolved`。
2. **停不掉 / :53 仍被占时是否在任何还原变更之前退出**：是。`systemctl stop` 失败 → `exit 1`（:124-127）；
   停后 10×1s 轮询 `ss -tuln | grep -qE ':53[[:space:]]'` 仍被占 → `exit 1`（:131-140）。两个退出点都在
   `restore_from_dir`/`restore_legacy` 的任何文件变更之前。台架证实：中止场景 resolv.conf 原样
   （`nameserver 127.0.0.1` 未动）、无 `restart systemd-resolved` marker。**但见发现 A-F1**：退出时 agent 已停且无人恢复。
3. **还原分支**：
   - 通配符 `:53` / `0.0.0.0:53` / `[::]:53` → 保持停止并明说原因 + 给出重跑安装脚本的指引（:151-155）。正确：此时 resolved 已重新占住 127.0.0.53:53，通配符绑不上。
   - 其余监听地址（`127.0.0.1:53`、`127.0.0.1:5353` 等）→ `systemctl start` + `is-active` 复核，成功报“已恢复运行”，失败报警告且明确“系统 DNS 不受影响”（:156-163）。台架证实两分支行为与文案一致。
   - agent 还原前未运行 → 不动，报“保持停止（未改动）”（:147-150）。台架证实。
   - 无 config.json 时 `AGENT_LISTEN` 默认 `:53`（:122）→ 走保持停止分支。保守正确。
   - `127.0.0.53:53` 这类与 stub 冲突的具体地址 → 落入 `*)` 分支尝试启动，失败只警告（rc 仍 0）。分类按语法而非实际冲突，见发现 A-F3（P3）。
4. **最终状态是否明确**：成功路径的三类终态（保持停止 / 已恢复 / 恢复失败警告）都有明确输出；**中止路径的终态不明确**，见 A-F1。

### 台架红/绿证（自建 harness，mount 命名空间 + stub systemctl/ss，宿主 /etc 未动）

harness：`/tmp/p1live/harness/`（stubs/systemctl、ss、chattr、getent、netplan；drive.sh/run-scenario.sh）。
旧版脚本取自 `git show e5dafe6^:scripts/restore-resolv.sh`，新版取自 `HEAD:scripts/restore-resolv.sh`。

| 场景 | 脚本 | 结果 |
|---|---|---|
| OLD-wildcard-agent-running（agent 运行、占 :53） | 旧版 | **红证**：rc=0，markers 只有 `enable --now systemd-resolved restart systemd-resolved`，**无 `stop dnsunlock-agent`**；`agent.active.after=yes`（还原后 agent 仍在运行、仍占 :53）。旧代码全程不停 agent——P1(a) 缺陷复现。 |
| NEW-wildcard（监听 `:53`） | 新版 | rc=0；markers `stop → enable → restart`；resolv.conf 已还原为 1.1.1.1/1.0.0.1；agent 保持停止并输出保持停止原因 + 重装指引。 |
| NEW-specific-5353（监听 `127.0.0.1:5353`） | 新版 | rc=0；markers `stop → enable → restart → start dnsunlock-agent`；agent 恢复运行，输出“agent 已恢复运行”。 |
| NEW-legacy-wildcard（老路 .orig） | 新版 | rc=0；同样先 stop 再 restart；保持停止分支正确。 |
| NEW-no-config-default53（无 config.json） | 新版 | rc=0；默认 `:53` 走保持停止分支。 |
| NEW-agent-inactive | 新版 | rc=0；无 stop marker；输出“agent 还原前未在运行，保持停止（未改动）”。 |
| NEW-abort-53-still-held（stop 成功但 :53 仍被占） | 新版 | rc=1；resolv.conf 未动；无 restart marker；**agent.active.after=no（见 A-F1）**；另 backups 1→2（见 A-F2）。 |
| NEW-abort-stop-fails | 新版 | rc=1；resolv.conf 未动；agent 仍在运行（stop 失败，状态一致）；backups 1→2（见 A-F2）。 |
| NEW-stub-held-after-stop（127.0.0.53:53 已被 resolved stub 占住） | 新版 | rc=1 误中止；agent.active.after=no（见 A-F1/A-F4）。 |
| NEW-listen-127.0.0.53-startfail | 新版 | rc=0；start 失败报警告，系统 DNS 已还原；agent 保持停止（见 A-F3）。 |

### 发现

#### A-F1（P2）：中止路径把 agent 停了却不恢复，且重跑后谎报历史
- 文件：`scripts/restore-resolv.sh:124-140`（`record_and_stop_agent` 内的两个 `exit 1`）
- 代码片段：
  ```bash
  if ! systemctl stop "$AGENT_UNIT" 2>/dev/null; then
    echo "错误: 停 dnsunlock-agent 失败，还原已中止（未改任何文件）；..." >&2
    exit 1
  fi
  # ...
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    if ! ss -tuln 2>/dev/null | grep -qE ':53[[:space:]]'; then return 0; fi
    sleep 1
  done
  echo "错误: agent 已停，但 :53 仍被占（可能是别的服务），还原已中止（未改任何文件）；..." >&2
  exit 1
  ```
- 实际命令输出（台架 NEW-abort-53-still-held）：
  ```
  ### NEW-abort-53-still-held rc=1
  错误: agent 已停，但 :53 仍被占（可能是别的服务），还原已中止（未改任何文件）；请先处理占 :53 的服务后重跑
  --- markers: stop dnsunlock-agent
  --- resolv.before=[nameserver 127.0.0.1 ] resolv.after=[nameserver 127.0.0.1 ] backups: 1 -> 2 agent.active.after=no
  ```
- 问题：`:53` 仍被占的退出分支里 agent **已经停掉**，脚本直接 `exit 1`，`restore_agent_after` 永远没机会跑，
  输出里一个字不提 agent 已被停掉。用户按提示处理占位服务后重跑：此时 agent 已是 inactive，
  `AGENT_WAS_ACTIVE=0`，`restore_agent_after` 输出“agent 还原前未在运行，保持停止（未改动）”——
  这句话在事实上是错的（第一次运行前 agent 在运行），且 agent 从此悄悄丢失，不再有任何恢复路径
  （除非用户手动 `systemctl start dnsunlock-agent` 或重跑安装）。
  后果是 DNS 分流静默丢失：系统 DNS 本身已还原所以用户不易察觉，TikTok/AI 等规则不再走解锁出口。
- 两阶段复现（同一台架状态，先中止、再重跑）：
  ```
  phase1 done: agent.active=no
  ### PHASE2-re-run rc=0
  已还原 /etc/resolv.conf <- /var/lib/dnsunlock/backup/20261121-100000_pre-takeover/resolv.conf
  已还原并验证通过（getent hosts example.com 有结果）
  agent 还原前未在运行，保持停止（未改动）。
  --- markers: enable --now systemd-resolved restart systemd-resolved
  --- agent.active.after=no resolv.after=[nameserver 1.1.1.1 nameserver 1.0.0.1 ]
  ```
  重跑 rc=0、还原成功，但全程无 `start dnsunlock-agent`，agent 保持停止，输出却称“还原前未在运行”——
  与第一阶段运行前 agent 在运行的事实直接矛盾。
- 定级 P2（主路径正确，中止路径丢状态 + 误导性文案；红证如上）。
- 修复方向（二选一）：中止分支退出前按 `AGENT_WAS_ACTIVE`/`AGENT_LISTEN` 把 agent 起回来
  （若起不回来也要明说）；或至少在中止文案中写明“agent 已停、未恢复，请手动 systemctl start dnsunlock-agent”。

#### A-F2（P3）：中止文案“未改任何文件”与事实不符
- 文件：`scripts/restore-resolv.sh:125,138`（两处错误文案），注释 `:112` 自承“只做了还原前备份”
- 证据：两个中止场景 backups 均为 `1 -> 2`——主流程在调还原函数之前已跑 `do_backup "pre-restore"`，
  写了一份新备份目录（`/var/lib/dnsunlock/backup/<ts>_pre-restore/`）。写备份是预期行为、无害，
  但文案称“未改任何文件”是错的（与代码注释“此时还没改任何文件（只做了还原前备份）”自相矛盾）。
- 定级 P3（文案准确性）。

#### A-F3（P3）：`restore_agent_after` 按监听字符串语法分类，而非按实际冲突分类
- 文件：`scripts/restore-resolv.sh:151-163`
- 证据：监听 `127.0.0.53:53`（install.sh `--dns-listen` 可合法指定）落入 `*)` 分支尝试启动，
  与已重新占住 127.0.0.53:53 的 resolved stub 冲突，启动失败。台架 NEW-listen-127.0.0.53-startfail：
  rc=0、输出警告“agent 恢复启动失败（监听 127.0.0.53:53），系统 DNS 不受影响；请看 journalctl -u dnsunlock-agent”，
  agent 保持停止。行为本身是 fail-closed、无错误断言，降级为警告是设计选择；但分支逻辑
  没有识别这类“具体地址但冲突”的情况，警告也没有告诉用户 agent 分流已丢、如何恢复。
  另：`127.0.0.1:53` 等不冲突地址的恢复路径已验证正确。
- 定级 P3。

#### A-F4（P3）：`:53` 占用检查分不清“agent 的 :53”和“resolved 自己的 stub :53”，stub 已起时会误中止
- 文件：`scripts/restore-resolv.sh:131-140`
- 证据：台架 NEW-stub-held-after-stop（`ss` 只报 `127.0.0.53:53` 被占，即 stub 本身已在监听）：
  rc=1，`错误: agent 已停，但 :53 仍被占（可能是别的服务）`，agent.active.after=no。
  若用户在跑还原前已手动恢复过 stub（或 stub 从未被关掉），还原本可直接成功，却被当成“别的服务占位”中止，
  且同样触发 A-F1 的 agent 丢失。检查应排除 127.0.0.53:53 自身（或直接区分占位进程），文案也不应把 stub 称为“别的服务”。
- 定级 P3（边缘场景：正常接管流程里 stub 是关掉的；但与 A-F1 叠加后危害放大）。

#### A-F5（P3）：`AGENT_WAS_ENABLED` 只写不读
- 文件：`scripts/restore-resolv.sh:102,114,116`（`AGENT_WAS_ENABLED=0` / 置 1 的两处）；全文件无任何读取。
- `restore_agent_after` 只认 `AGENT_WAS_ACTIVE`，enabled 状态对任何分支都没有影响。死变量，
  删掉或在“保持停止”分支的文案中加以区分均可。
- 定级 P3。

#### A-F6（观察，非缺陷）：已部署机器上的还原脚本还是旧版，P1(a) 修复需重装才生效
- 证据：测试机（只读检查）`/usr/local/bin/dnsunlock-restore-dns` 中 `record_and_stop_agent` 出现次数为 0，
  该机 agent 二进制 sha256 前缀 `1084e5e9…` 与已知 v0.1.5 一致，panel :8080 + agent :53 均为已恢复的 v0.1.5，
  `/etc/resolv.conf` 为 Tailscale 管理（未动）。这是部署时效问题而非代码问题：修复只存在于仓库与新安装包里，
  存量安装必须重跑安装脚本才会拿到新还原脚本。

### A 线小结（P1(a)）
主路径**真修了**：两个还原入口都在任何 resolved/文件变更之前停 agent，停失败或 :53 仍被占时在变更前退出；
通配符保持停止、具体地址恢复、未运行不动、无配置默认 :53 四个分支在台架上全部按设计工作；旧版不停 agent 的缺陷有红证。
但中止路径有 P2 缺陷（A-F1：agent 停后不恢复且重跑谎报历史），另有 4 个 P3（文案、分类、stub 误判、死变量）。
rig 不能为 P1(a) 作证（见 E-2）。

## A-2 P1(b)：agent 用 IP_PKTINFO 按查询目标地址回包

### 代码位置

`internal/dnsagent/agent.go:1099-1241`（`serveUDP` + `newUDPPktinfo` + `dstFromOOB` + `replyOOB`），
测试 `internal/dnsagent/udp_stub_test.go`（84 行，新增）。

### 核查结论（逐项）

1. **四种情况**：
   - **纯 IPv4**（监听 `127.0.0.1:53` / `0.0.0.0:53`）：`newUDPPktinfo` 判 `v6=false`，置 `IP_PKTINFO`；
     收包 `dstFromOOB` 取 `in_pktinfo.ipi_addr`（`m.Data[8:12]`），回包 `replyOOB` 同时填 `ipi_spec_dst` 与 `ipi_addr`。与内核头文件一致（见下）。
   - **IPv4 映射 IPv6**（监听 `:53` 双栈套接字，查询发往 127.0.0.53）：内核经 `IPV6_PKTINFO` 给出 `::ffff:127.0.0.53`，
     `dstFromOOB` 取前 16 字节，`replyOOB` 以 `in6_pktinfo.ipi6_addr=::ffff:127.0.0.53` 回包，内核以 127.0.0.53 为源。正确。
   - **纯 IPv6**（监听 `[::1]:53` 或 `[::]:53`，目标如 `2001:db8::1`）：同 v6 路径，`replyOOB` 填 16 字节地址 + ifindex 0。正确。
   - **IP_PKTINFO 未启用**（`SetsockoptInt` 失败）：`newUDPPktinfo` 打一条 `log.Printf("dns-agent: cannot enable pktinfo ...")` 后返回 `active=false`，
     `dstFromOOB`/`replyOOB` 均返回 nil，`serveUDP` 走旧 `WriteToUDP`。是“打日志 + 静默回退旧行为”，不是报错退出。
     另：`SyscallConn()` 失败时无日志直接回退（`newUDPPktinfo` 内 `if err != nil { return p }`），见 A-F8。
2. **cmsg 构造与解析**：与内核头文件逐字节核对一致——
   - `struct cmsghdr`（`/usr/include/x86_64-linux-gnu/bits/socket.h:280`）：`size_t cmsg_len`（64 位占 8 字节）+ `int cmsg_level` + `int cmsg_type` = 16 字节头。
     代码 `PutUint64(oob[0:8], CmsgLen)` + `PutUint32(oob[8:12], level)` + `PutUint32(oob[12:16], type)`，小端序，与 amd64/arm64 一致。
   - `struct in_pktinfo`（`/usr/include/linux/in.h:246`）：`int ipi_ifindex; struct in_addr ipi_spec_dst; struct in_addr ipi_addr;`（12 字节）。
     代码回包：`[16:20]=ifindex 0`、`[20:24]=spec_dst`、`[24:28]=addr`；收包解析：`m.Data[8:12]` = `ipi_addr`（目标地址）。一致。
   - `struct in6_pktinfo`（`/usr/include/netinet/in.h:559`）：`struct in6_addr ipi6_addr; unsigned ipi6_ifindex;`（20 字节）。
     代码回包：`[16:32]=ipi6_addr`、`[32:36]=ifindex 0`；收包解析：`m.Data[:16]`。一致。
   - 数值实测（临时测试，仅放在 /tmp 副本树内，未动 worktree）：`CmsgSpace(20)=40 CmsgLen(20)=36 CmsgSpace(12)=32 CmsgLen(12)=28`；
     v6 oob `len=36 level=41(IPPROTO_IPV6) type=50(IPV6_PKTINFO) addr=127.0.0.53 ifindex=0`；
     v4 oob `len=28 level=0(IPPROTO_IP) type=8(IP_PKTINFO) ifindex=0 spec_dst=127.0.0.53 addr=127.0.0.53`。与头文件常量一致。
3. **回包失败时**：`WriteMsgUDP` 出错 → 回退 `WriteToUDP`（旧行为，源地址可能错但至少有回包），注释写明了取舍。正确。
4. **setsockopt 失败时**：打日志 + 回退旧行为，不报错、不退出。设计如此；日志进 systemd journal（agent 以服务运行时 stderr 进 journal）。
5. **其余正确性**：`ReadMsgUDP` 的 oob 缓冲 64 字节 ≥ 单条 cmsg 所需（v6 `CmsgSpace(20)=40`）；`dst`/`pktBytes` 每包新变量、goroutine 捕获无竞态；
   allowlist 检查在回包之前；TCP 不受影响（accepted 连接的回包源即连接目标地址）。
6. **测试覆盖判定**：`TestPktinfoOOBRoundTrip` 只证明“自己编的 cmsg 自己能解回来”（自洽性），
   编码与解码共用同一组偏移假设——两边同时写错同一偏移也能通过；它不能证明偏移与内核结构体一致（这一点本审计用头文件对照补上了）。
   `TestServeUDPStarts` 只证明 `:53` 能绑上、进程不死，不发任何查询、不校验回包源。两个测试均未覆盖：
   setsockopt 失败路径、WriteMsgUDP 失败回退路径、真实回包源地址。测试文件注释自承活体检查“由测试机 nspawn 容器覆盖”，
   但该容器证据缺失（见 E-1）。本地实测：`go test ./internal/dnsagent/ -run 'TestPktinfoOOBRoundTrip|TestServeUDPStarts' -v` 均 PASS；
   全包 `go test ./internal/dnsagent/ -count=1` PASS（12.6s）。

### 活体复现（测试机 netns，新旧 agent 二进制对照）

方法（宿主机只做只读检查，未动 panel/agent/resolv.conf）：测试机 `ip-172-26-15-152` 上
`unshare -n` 新网络命名空间（独立 lo，与宿主机网络隔离），`ip addr add 127.0.0.53/8 dev lo`，
fake panel（`GET /api/v1/agent/config` 回一条 tiktok.com → 203.0.113.99 规则，`POST /heartbeat` 回 200），
agent 监听 `:5353`、allowlist `127.0.0.1`。新旧二进制均由本机离线构建（`go build ./cmd/dnsunlock`），
旧版取 `ff006ca^` 树、新版取 `HEAD` 树，经分块传到测试机并校验 sha256 一致：
旧 `d98db4ea15dd01a3f85ca78b460a6ebfebc8e9c729e22a0f49b567ee11b78475`，
新 `53785b5680c12066fd824dbae493f3b08e9dbba660712c178addae419fb1bbfe`。
测试机 `/tmp/p1live/` 留有两二进制、脚本与日志备查；宿主机事后复核：无残留进程，`:53`/`:8080` 仍为 v0.1.5，
`/usr/local/bin/dnsunlock` 仍为 `1084e5e9…`。

实际命令输出（`unshare -n bash /tmp/p1live/netns-run.sh`，已略去 lo 地址行）：

```
=== OLD agent (pre-ff006ca) ===
AGENT-READY after 6s (TCP tiktok.com -> 203.0.113.99)
--- dig UDP @127.0.0.1 (control):
203.0.113.99
--- dig UDP @127.0.0.53 (P1(b) case):
;; communications error to 127.0.0.53#5353: timed out
--- raw probe (reply source):
PROBE 127.0.0.1:5353 tiktok.com: reply-from=127.0.0.1:5353 rcode=0 answer=203.0.113.99 id-ok=True
PROBE 127.0.0.53:5353 tiktok.com: reply-from=127.0.0.1:5353 rcode=0 answer=203.0.113.99 id-ok=True
--- agent log (pktinfo line if any):
(no pktinfo log line)
DONE /tmp/p1live/agent-old

=== NEW agent (ff006ca) ===
AGENT-READY after 6s (TCP tiktok.com -> 203.0.113.99)
--- dig UDP @127.0.0.53 (P1(b) case):
203.0.113.99
--- raw probe (reply source):
PROBE 127.0.0.1:5353 tiktok.com: reply-from=127.0.0.1:5353 rcode=0 answer=203.0.113.99 id-ok=True
PROBE 127.0.0.53:5353 tiktok.com: reply-from=127.0.0.53:5353 rcode=0 answer=203.0.113.99 id-ok=True
DONE /tmp/p1live/agent-new
```

- **红证（旧版）**：`dig @127.0.0.53` 超时；裸 UDP 探针证明回包内容正确（answer=203.0.113.99、ID 正确），
  但源地址是 `127.0.0.1:5353` 而非查询目标 `127.0.0.53`——正是 P1(b) 描述的“内容对、源地址错、被源校验丢弃”。
  对照组 `@127.0.0.1` 与 TCP 均正常，排除规则/配置问题。
- **绿证（新版）**：`dig @127.0.0.53` 直接返回 `203.0.113.99`；裸探针回包源为 `127.0.0.53:5353`；
  `@127.0.0.1` 回包源仍为 `127.0.0.1`（未误伤正常查询）。两版 agent 均无 pktinfo 报错日志
  （新版 setsockopt 成功，故无 `cannot enable pktinfo` 行；旧版无此代码）。
- 注意：本机沙箱无法做此实验（UDP 套接字 `bind`/`sendto` 均 `EPERM`，`unshare -rn` 内亦然），故在测试机 netns 内完成；
  修复方声称的容器红/绿跑本身仍无证据（见 E-1），此处红/绿证是本审计独立重跑的。

### 发现

#### A-F7（P3）：套接字族按监听地址字符串判定，与真实套接字可能错配；IPv6 被禁用的主机上 P1(b) 静默失效
- 文件：`internal/dnsagent/agent.go`（`newUDPPktinfo`，`v6: addr.IP == nil || addr.IP.To4() == nil`）
- 依据：Go 1.25 `net/ipsock_posix.go:134 favoriteAddrFamily`——listen + 通配符地址时，若 `supportsIPv4map() || !supportsIPv4()` 才建 AF_INET6 双栈套接字；
  否则 `laddr == nil`（即监听 `:53`）时建 **AF_INET** 套接字。也就是说 IPv6 被禁用的主机上，`:53` 实际是 IPv4 套接字，
  而 `newUDPPktinfo` 仍按地址字符串判 `v6=true`，对 IPv4 套接字下 `IPPROTO_IPV6/IPV6_RECVPKTINFO` → `ENOPROTOOPT` →
  打日志后 `active=false`，回退旧行为，发往 127.0.0.53 的查询仍会被源地址校验丢弃。
  主路径（正常双栈主机）不受影响；失效时有日志、无崩溃，等同旧行为，故定 P3。
- 修复方向：按套接字本身判定族（例如建套接字后 `GetsockoptInt(IPPROTO_IPV6, IPV6_V6ONLY)` 或 `LocalAddr` 的族），
  或先试 `IPV6_RECVPKTINFO`、失败再试 `IP_PKTINFO`。

#### A-F8（P3）：`SyscallConn()` 失败时无日志直接回退
- 文件：`internal/dnsagent/agent.go`（`newUDPPktinfo`）
  ```go
  raw, err := c.SyscallConn()
  if err != nil {
      return p   // active=false，无日志
  }
  ```
  与 setsockopt 失败分支（有 `log.Printf`）不一致：同一“pktinfo 未启用”状态，一种有日志一种没有，
  排障时无法区分。定 P3（极小）。

#### A-F9（P3）：测试是自洽循环，未覆盖活体行为与失败路径
- 文件：`internal/dnsagent/udp_stub_test.go`
- `TestPktinfoOOBRoundTrip`：`replyOOB` → `dstFromOOB` 的往返，不能发现编解码共用的偏移错误；
  未覆盖纯 IPv4 套接字上的真实收发、IPv4 映射地址的真实回包源、setsockopt 失败、WriteMsgUDP 失败回退。
  `TestServeUDPStarts`：只断言绑定成功。活体 127.0.0.53 回包源检查无任何自动化测试承载
  （注释称由 nspawn 容器覆盖，但容器证据缺失，见 E-1）。
- 定级 P3（测试缺口；代码本身经头文件对照无误）。

### A 线小结（P1(b)）
**真修了，活体红/绿证齐全**：cmsg 布局与内核头文件逐字节一致，四种情况的分支逻辑正确，回包失败有回退，
setsockopt 失败打日志回退；测试机 netns 内新旧二进制对照：旧版 `dig @127.0.0.53` 超时且裸探针证实
回包源为错误的 127.0.0.1，新版 `dig @127.0.0.53` 正常返回且回包源为 127.0.0.53。
遗留 3 个 P3（A-F7：IPv6 禁用主机上静默回退旧行为；A-F8：SyscallConn 失败无日志；A-F9：测试自洽循环、未覆盖活体与失败路径）。

## E-1 P1 红/绿跑证据缺失
- 本地 `/tmp/p1-rig-rerun.log`（2 行）：
  ```
  台架 rootfs 不存在: /var/lib/machines/v016-test
  RIG-RERUN-EXIT=1
  ```
- 本地 `/tmp/` 仅剩 P1 修复会话的零碎产物：`/tmp/dnsunlock-fixed-linux-amd64`（11:16 的二进制）、`/tmp/kill-s14.sh`，
  无容器日志、无 `dig @127.0.0.53` 输出、无 journal。
- worktree 内无任何 `*.log`、无 rig 汇总、无“126 PASS”产物（grep `126 PASS` 无结果）。
- 测试机（只读）：`machinectl list` → `No machines.`；`/var/lib/machines/` 为空；`/root/rig` 不存在；
  `/tmp/` 仅有 `/tmp/p1-debootstrap.log`（v016-p1test 容器的 debootstrap 构建日志，尾部多次 `Failure while configuring base packages`，
  与 P1 红/绿跑无关）与空目录 `/tmp/p1-chunks/`；无 s3/restore/dig 相关日志。
- 结论：修复方声称的“容器红跑复现 P1、绿跑全部通过”**无任何可查证据**。本审计已用自建台架对 P1(a) 补红/绿证（见 A-1），
  P1(b) 的活体对照已由本审计在测试机 netns 内独立重跑并拿到红/绿证（见 A-2）。

## E-2 rig 不能证明 P1(a)/P1(b)
- `scripts/rig/rig-inner.sh` 全文核查：没有任何断言检查还原是否调了 `stop dnsunlock-agent`
  （`grep "stop dnsunlock-agent" rig-inner.sh test-takeover-rig.sh` 无结果），也没有任何断言检查还原后 agent 状态；
  所有 dig 均为 `+tcp @127.0.0.1`（TCP 不受 P1(b) 影响），没有任何 `dig @127.0.0.53`；
  沙箱 UDP 回环本身不通（rig-inner.sh 文件头自述），P1(b) 的活体路径在 rig 里不可测。
  因此 rig 的“绿跑”即使为真，也不能作为 P1(a)/P1(b) 已修的证据——P1(a) 的“resolved 抢不到 stub”在 rig 里是被 stub 掉的
  （`systemctl restart` 只是记 marker、不真绑端口），P1(b) 的回包源在 rig 里根本不产生。
- S14 唯一的 FAIL（`verify_rule_domain`）：该检查走 `getent` + `resolv.conf` 的 `options use-vc` → TCP 到 agent，
  与 `ff006ca` 改动的 UDP 路径无交集，按代码路径可排除是 P1(b) 改动直接导致；但因 rig 日志缺失（E-1），
  其真实失败原因无法核实，“与本次改动无关”的说法同样无证据。本审计不将其计入 P1(b) 的结论。
- 另：rig 的 stub `systemctl` 在 `e5dafe6` 中补了 `stop`/`start`/`cat dnsunlock-agent.service` 三个分支，
  但 rig-inner.sh 没有用上它们来断言，属“搭了台没唱戏”。

## A 线结论
- **P1(a)：真修了（主路径），但带一个 P2 尾巴**。两个还原入口均在变更前停 agent、失败即退，分支终态在台架上逐项验证通过，
  旧版缺陷有红证。P2（A-F1）：中止路径 agent 停后不恢复且重跑谎报历史；另 4 个 P3（A-F2~A-F5）+ 1 个部署观察（A-F6）。
- **P1(b)：真修了（活体红/绿证齐全）**。cmsg 与内核头文件逐字节一致，四种情况逻辑正确，失败有回退；
  测试机 netns 对照：旧版 `dig @127.0.0.53` 超时、回包源错为 127.0.0.1，新版正常返回、回包源为 127.0.0.53。
  遗留 3 个 P3（A-F7~A-F9）。修复方声称的容器红/绿跑本身仍无证据（E-1），本审计的红/绿证是独立重跑的。
