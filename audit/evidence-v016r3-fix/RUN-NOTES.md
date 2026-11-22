# 容器验证运行手记（2026-11-22，修复轮 3 F3-01/F3-02/F3-03 红/绿复验）

## 结论先说

| 项 | 红 7b86d49 | 绿 65a817e |
|---|---|---|
| F3-01 CHOSEN | 20/2，复现：立即 dig #1 回规则 IP 203.0.113.99 + `Global: 127.0.0.1` | **22/0 全过**：dig ×5（立即+延迟）全走上游，`Global:` 为空 |
| F3-01 legacy | 23/2，复现：同上两项（日志含“走老路还原”） | **25/0 全过**（日志含“走老路还原”） |
| F3-02 agent | 15/3，复现：重装 rc=1、PID 2415 不变、dig -p 5353 无应答 | **19/0 全过**：rc=0、PID 5039→5234、dig -p 5353 回规则 IP |
| F3-02 SNI | 18/3，复现：重装 rc=0 静默成功、无“新 allowlist 已加载”、PID 3035 不变、127.0.0.1 仍被放行 | **21/0 全过**：rc=0、日志有验证、PID 5688→5802、127.0.0.1 被拒（探针 DENIED） |
| F3-03 | 18/2，复现：还原后仍 enabled、无 disable 说明 | **20/0 全过**：还原后 disabled、日志有“已直接改为不开机自启” |

红/绿基线：红二进制 `53ea9f83…`（dist-red/，与 R2 基线一致，未重建）；
绿二进制 `9155bca6…`（本轮 tip 65a817e 现编译，含 F3-01/02/03 + stub 修补）。
绿 install.sh 服务端校验：面板 served 的 install.sh 含 5 处 `restore_resolv_conf_file`、
2 处 `systemctl restart dnsunlock-agent`；红版两者均为 0。
`go test ./...` 全绿（dnsagent/panel/sniproxy）；台架 `scripts/test-takeover-rig.sh` **145/0**，
exit 0（逐场景日志 `audit/evidence-v016r2-fix/rig-20261122-0406Z-scenarios/`，30 文件；
注：目录名沿用 r2-fix 是台架脚本的归档路径，本次跑在 tip 65a817e）。
本轮容器步骤**未被系统执行风险检查拦停**（R2 的两次拦停未重现），全程按任务跑完。

## 环境（重建，R2 收尾时桥与镜像已删）

- 测试机 ip-172-26-15-152（Tailscale 100.110.88.49），经隧道代理 + `~/workspace/tools/tsconnect.py`
  CONNECT 中继 + `~/.ssh/id_ed25519` 以 root 登录。
- 桥 br-v016 10.0.5.1/24 + NAT（MASQUERADE 10.0.5.0/24）+ FORWARD 两条；
  另补了一条 R2 手记未明写但必需的规则：宿主 INPUT 策略是 DROP（ufw 链），
  容器最初 curl 面板超时，补 `INPUT -i br-v016 -p tcp --dport 18280 -j ACCEPT` 后才通。
  收尾时已用改前基线恢复（v016 规则 0 残留，见下）。
- 容器镜像：debootstrap Debian 12 bookworm（`--variant=minbase`，
  include 清单与 `scripts/rig/provision-rootfs.sh` 一致：
  curl,bind9-dnsutils,bind9-host,iproute2,procps,util-linux,ca-certificates,python3，
  另加 systemd,systemd-resolved,dbus），约 420MB；networkd 静态 10.0.5.2/24、
  网关 10.0.5.1、DNS 1.1.1.1（host0）；systemd-resolved + systemd-networkd 已启用。
  注：provision-rootfs.sh 本身写的是 noble（Ubuntu 24.04），与 R2 手记“Debian 12”
  不一致；本轮按任务明文与 R2 实际镜像用了 Debian 12 bookworm。
- 容器 `v016-test`，`systemd-nspawn --boot --network-bridge=br-v016`。
- Scratch 面板：红/绿两色二进制各带自家 dist 目录轮换，同一份
  `/root/v016-r3/panel.json`；服务器 nspawn-dns（srv-1795319566432586049）、
  节点 nspawn-jp 203.0.113.99 JP（node-1795319566434548222）、tiktok 规则 → 该节点；
  agent 配置校验含 tiktok → 203.0.113.99；case.env（0600）进镜像。
  首登须改密：按面板默认流程改成测试机本地随机密码，只存 `/root/v016-r3/admin-pass`（0600）。
  换色时 setup-panel.sh 初版有个 bug（`call()` 未接 HTTPError，admin/admin 401 直接抛异常，
  没走到备用密码），已修（接 HTTPError 返回码 + 体）后绿切成功。
- 规则 IP 203.0.113.99；tiktok 上游约 23.214.22.x；example 上游如 104.20.23.154 / 172.66.147.243。
  全部 `dig` 均为 UDP。

## 台架修正（复审 §8 第 4 项，全部落地，见 harness-guest.sh）

1. v12 步 4“本次不接管”断言只在安装走到接管提问时才断言
   （日志含“是否把本机系统 DNS”才断言，否则 `[SKIP]` 不计入）。
   本轮实证：红 f302a 重装死在 [4/6]，该断言正确 SKIP；绿 f302a 走到提问，
   该断言命中且通过。
2. r201 p2 按分支断言：先判走“分流静默复活”还是“系统 DNS 死”分支，
   再断言该支末态；两支都是红复现成立；未走任一已知分支时 FAIL 并快照。
   （本轮未重跑 r201 p2——F3 场景不含重启段；修正已进 guest.sh 且 `bash -n` 通过，
   未在容器内实跑验证。）
3. `stop_wildhold` 后轮询等进程退出再返回（进程死 + :53 无 0.0.0.0 监听，
   最多 10 秒），不再 sleep 1 秒就断言。
   （同上，本轮 F3 场景不用 wildhold；修正已进 guest.sh 且 `bash -n` 通过，未实跑。）
4. 另补一处本轮发现的台架证据缺口：断言函数的 stdout 会被 `assert` 的 `>/dev/null`
   吞掉，F3-01 的逐次 dig 与 resolvectl 原文之前只进内存、不进日志。
   现同时写进场景证据文件（f301c/f301l-dig5.txt）；SNI 探针结果文件改到
   `/root/v016/sni-probe-last.txt`（进归档）。

## 红跑逐项

### f301c（CHOSEN）20/2——复现成立

- 永久安装 rc=0、getent tiktok 走规则、resolv.conf=127.0.0.1、agent 在跑。
- 还原 rc=0 后立即：dig #1 回 **203.0.113.99**（规则 IP，闪烁现形）；
  `resolvectl dns`：`Global: 127.0.0.1`、`Link 2 (host0): 1.1.1.1`（污染的确定性证据）。
- 其余：getent tiktok 走上游、延迟 3 秒后 dig ×5 全走上游（闪烁是间歇性的，
  延迟批未命中）、resolv.conf 回 stub 软链、resolved 在跑、系统 DNS 可用、agent 已恢复运行。
- 注：本场景共跑了 3 遍。第 1 遍（证据修补前）20/1：dig ×5 全走上游、getent 走上游，
  仅 Global FAIL——当时逐次 dig 原文未落盘；修补证据捕获后重跑 2 遍均为 20/2，
  第 3 遍（归档的这遍）立即 dig #1 即命中规则 IP。3 遍的 Global 均为 127.0.0.1，
  机制确定性成立，与 dig 竞态的偶然性无关。

### f301l（legacy）23/2——复现成立

- 永久安装后：`.orig` 与 `.orig.link` 存在（install 的 do_backup 首份备份时写的兼容指针），
  删全部结构化备份目录后还原，日志含“走老路还原”。
- 还原 rc=0 后立即：dig #1 回 **203.0.113.99**；`Global: 127.0.0.1`。
- 其余全过（getent 走上游、延迟 ×5 全走上游、stub 软链、resolved 在跑、系统 DNS 可用、agent 恢复）。

### f302a（agent）15/3——复现成立

- 首次安装 rc=0，agent MainPID=2415 在 :53 跑。
- 重装 `--dns-listen 127.0.0.1:5353`：rc=1（[4/6]“验证失败: example.com 解析无结果”）、
  MainPID 仍 2415、dig -p 5353 无应答；[3/6] 状态行 Main PID: 2415（首次安装时起的 :53 agent）。
- 守卫文案断言正确 SKIP（安装死在 [4/6]，没走到接管提问）。
- 还原 rc=0、resolv.conf 回 stub、系统 DNS 恢复。

### f302s（SNI）18/3——复现成立

- 前置：容器直连 egress 可用（curl example.com）、:443 空闲。
- 首次安装 allowlist A=127.0.0.1：rc=0、代理在跑、:443 监听、MainPID=3035、
  探针 ALLOWED（TLS 握手成功，TLSv1.3）。
- 重装改 allowlist B=203.0.113.7：rc=0，日志只有“完成: SNI 代理已在 :443 运行”，
  **无“新 allowlist 已加载”验证**；MainPID 仍 3035；配置文件已写 B，
  但探针仍 ALLOWED——旧 allowlist 静默残留（已删的 IP 仍能用代理）。

### f303 18/2——复现成立

- 永久安装后 agent enabled+active；`systemctl stop` 后 inactive 但仍 enabled。
- 还原 rc=0；还原后仍 enabled；日志只有“agent 还原前未在运行，保持停止（未改动）。”，
  无 disable 说明。

## 绿跑逐项（tip 65a817e，二进制 9155bca6…）

### f301c（CHOSEN）22/0 全过

- 还原后立即 dig ×5 全走上游（23.214.22.137/143/144/140），
  `resolvectl dns`：`Global:`（空）、`Link 2 (host0): 1.1.1.1`；
  getent 走上游、延迟 3 秒后 ×5 仍全走上游；其余（stub 软链、resolved 在跑、
  系统 DNS 可用、agent 恢复运行）全过。

### f301l（legacy）25/0 全过

- 同上，legacy 路（日志含“走老路还原”），立即 + 延迟 dig ×10 全走上游，Global 为空。

### f302a（agent）19/0 全过

- 重装 rc=0；MainPID 5039→5234；dig -p 5353 tiktok 回规则 IP（UDP）；
  重装日志明说“本次不接管”（监听端口不是 53…本次不接管）；
  resolv.conf 仍是接管态；还原 rc=0、系统 DNS 恢复。

### f302s（SNI）21/0 全过

- 首次安装 A：rc=0、:443 监听、MainPID=5688、探针 ALLOWED。
- 重装改 B：rc=0；日志“验证通过: SNI 代理已按新配置启动（PID 5802），新 allowlist 已加载。”；
  MainPID 5688→5802；配置文件含 B；探针 DENIED（握手 EOF，连接被关）。

### f303 20/0 全过

- 还原 rc=0；还原后 agent 为 disabled；日志：
  “agent 还原前是开机自启（enabled），已直接改为不开机自启（systemctl disable dnsunlock-agent），
  下次启动不会再抢 :53；……”；agent 仍停着；stub 软链；系统 DNS 可用。

## 清理收尾（2026-11-22 ~04:17 UTC，全部完成）

- 容器 v016-test 已 poweroff（machinectl: No machines），镜像目录
  `/var/lib/machines/v016-test` 已删。
- 绿 scratch 面板已停，:18280 已关。
- `/root/v016-r3` 整目录已删（含 panel.json、dist-red/dist-green、admin-pass、
  case.env 镜像内副本随镜像同删、证据暂存）；核查无残留：
  `/root/v016/case.env`、`/root/v016-r2/case.env`、`/root/v016-r2/panel.json` 均不存在
  （R2 时已删）；测试机 /root 下只剩 R2 的 `v016-r2` 目录（凭据已清）。
- iptables 已用改前基线恢复（v016 相关规则 0 条残留；NAT POSTROUTING 无 10.0.5，
  INPUT 无 18280），br-v016 已删。
- 宿主机最终核对：resolv.conf sha256 `4443d364e93cbe02f76a7adff16bad35872ad3307cb4d5421b837833fd81584f`
  （基线未动）、panel pid 2652616、agent pid 2652618、二进制 `1084e5e9…` 均与放行前一致；
  :53/:8080 在听，面板 :8080 HTTP 200，panel/agent 均为 active。
  `net.ipv4.ip_forward=1` 保持原样（R2 同样留 1，未核到改前值，不动）。
- 生产面板 https://dns.0v0.baby 未碰；无 push/tag/发版。

## 证据归档

- `red/`（19 文件）：f301c/f301l/f302a/f302s/f303 的场景日志 + 各步 install/restore 日志
  + dig5 证据 + sni-probe-last.txt。
- `green/`（19 文件）：同上（绿）。
- `host/`（7 文件）：panel-red.log、panel-green.log、iptables-before.save、
  nspawn-boot.log、debootstrap.log、setup-panel.sh、cleanup-r3.sh。
- `harness-guest.sh`：本轮最终版 guest.sh（含 F3 五场景 + 三处台架修正 + 证据捕获补丁）。
- 台架 145/0 逐场景日志在 `audit/evidence-v016r2-fix/rig-20261122-0406Z-scenarios/`（30 文件）。
- 证据 token 扫描：无 agent token 明文（仅 server/node id）；case.env 只在测试机镜像内，
  已随镜像删除。
- 注：`rig-merged.log`（03:42，基线 01a6ef8）是本轮开始前已在目录里的文件，
  属 03:32Z 另一轮台架跑的产物，非本轮容器验证产生，留置未动。

## 遗留

- r201 p2 按分支断言与 `stop_wildhold` 轮询两处台架修正已进 guest.sh 但本轮未在容器内实跑
  （F3 场景不含重启段、不用 wildhold）；v12 步 4 修正已在红/绿 f302a 中双向实证。
- 红 f301c 第一遍（20/1，证据修补前）的逐次 dig 原文未落盘，只有 SUMMARY 行在当时的
  工具输出里；归档的是修补后重跑的 20/2 两遍中的最后一遍。
- 本轮一次本地 `go test + rig` 联合执行后，系统提示有一项审批未及时答复而超时；
  输出显示 go test 全绿、台架 145/0 exit 0、逐场景日志 30 文件齐全，未见缺失项，
  未重跑；复审时如需可再跑一次确认。
