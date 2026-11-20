# FIX-REPORT-5 — v0.1.1（真机实测 P0/P1/P0-REAL-02 修复）

日期：2026-11-20（CST 21:15–21:35）
来源：真机实测报告 audit/REAL-MACHINE-TEST.md 发现的 P0、P1，及修复验证中
新发现的 P0-REAL-02。全部在测试机 ip-172-26-15-152（Debian 12）上真跑验证。

## 修复内容

### P0 — 两个安装脚本 sha256 校验文件名不匹配（REAL-MACHINE-TEST 的 P0）
- `scripts/install-panel.sh`：二进制曾下载为 `$TMP/dnsunlock`，校验文件里写
  的却是 `dnsunlock-linux-amd64`，`sha256sum -c` 永远失败。改为按 `$BIN` 名
  下载、校验通过后再装到 `/usr/local/bin/dnsunlock`。
- `scripts/install.sh`：同理，改为下载到临时目录 `$DL_TMP/$BIN` 校验，通
  过后再装到最终位置，临时目录进 `trap` 清理。

### P1 — install.sh 在 systemd-resolved 的机器上直接拒绝运行
- 端口检查从“`ss` 扫到 `:53` 就退出”改为按 Go 的方式真试绑监听地址
  （UDP+TCP，均设 `SO_REUSEADDR` 的 python3 探测；无 python3 时降级为 ss
  启发式）。
- 新增真正可用的 `--dns-listen` 参数（命令行优先于 `DNS_LISTEN` 环境变
  量），带格式校验与 `--help`；配置写盘与装后验证的 `dig` 都跟实际监听
  地址走。
- 试绑失败且冲突只是 systemd-resolved stub（127.0.0.53/127.0.0.54）时，
  不再直接退出：说明只关 stub 监听、不改 `/etc/resolv.conf`，问是否关
  （`/dev/tty` 提问，`DNS_DISABLE_STUB=y` 可免问）；关后重测，仍被占才
  退出并提示换端口。非 stub 占用则直接拒绝并提示 `--dns-listen`。
- `/etc/resolv.conf` 由 Tailscale 生成时直接跳过接管提问。
- 面板内嵌副本 `internal/panel/assets/install.sh` 已同步（`diff` 一致）。

### P1 修复的后续 bug — stub 判定不认 ss 的 %zone 后缀（commit d06fb4a）
- 真机验证时 install.sh 仍报“不是 systemd-resolved 的 stub”。定位：
  `ss` 把 stub 监听印成 `127.0.0.53%lo:53`，判定正则
  `^(127\.0\.0\.53|127\.0\.0\.54):53$` 认不出来；且实测 TCP 0.0.0.0:53
  确实绑不上（systemd-resolved 的 TCP stub 没设 SO_REUSEADDR），所以
  探针报被占是对的、分支判断是错的。
- 修复：两处正则都允许可选的 `%zone` 后缀
  `^(127\.0\.0\.53|127\.0\.0\.54)(%[^:]*)?:53$`。本地验证
  `127.0.0.53%lo:53` 与 `127.0.0.54:53` 都判为 stub。

### P0-REAL-02 — 面板安装脚本从不建 dist 目录，/dl/ 永远 404（commit bfdb86d）
- 新发现（修复验证中）：agent 一键安装在 [1/6] 下载时 `curl 404`。
  面板的 `/dl/` 从 dist 目录发文件（默认 `./dist`），而 install-panel.sh
  从不建 dist 目录、systemd 服务也没传 `-dist`，`./dist` 相对服务工作
  目录根本不存在。等于 agent 一键安装在下载那步永远失败——这是设计
  层面的缺口，之前四轮审计都没走到这一步所以没发现。
- 修复：install-panel.sh 安装时把 5 个 Release 资产（双架构二进制 +
  各自 .sha256 + 合集 dnsunlock.sha256，逐个校验）放进
  `/var/lib/dnsunlock/dist`，systemd 服务加 `-dist
  /var/lib/dnsunlock/dist` 启动。

## 真机验证（测试机 ip-172-26-15-152，全部真跑）

1. 面板一键安装：先 `uninstall.sh --purge` 清掉旧数据，再跑一键命令，
   `sha256 校验通过`，服务起来，`dist` 里 5 个资产齐全。
2. `/dl/` 验证：`.sha256` 免登录可取；二进制带 agent token 可取，哈希与
   Release 一致（7a2eb801…，v0.1.0 的二进制）。
3. DNS agent 一键安装：stub 判定走对分支，关 stub 后 `:53` 可绑定；
   token 验证通过；二进制从面板 `/dl/` 下载、`sha256 校验通过`；服务起
   来监听 `:53`；装后验证 example.com 走上游通过；Tailscale 生成的
   resolv.conf 正确跳过接管。
4. DNS 行为：`dig @127.0.0.1 -p 53 netflix.com A` → 203.0.113.10；
   AAAA → NODATA；example.com → 真实 IP；TCP 查询同样返回规则 IP；
   白名单外 IP 查询超时无应答。
5. 规则即时生效：netflix 切到 TEST-US-1（203.0.113.20）7 秒内生效，
   恢复 HK 后回到 203.0.113.10。
6. 机器无影响：FLMX 三个容器 Up (healthy)，6365/6366 仍在监听；
   Caddy、systemd-resolved、openvpn 均为 active；resolv.conf 原样未动。

注：本次验证用的面板二进制仍是 v0.1.0 Release 的（当时 latest 还是
v0.1.0）；v0.1.1 的二进制是同一份 Go 代码重新构建，哈希不同仅因构建
元数据不同。

## 发版

- 提交：bac8c69（P0+P1）、d06fb4a（stub %zone）、bfdb86d（dist 目录）
- Tag：v0.1.1，已推送
- Release：https://github.com/iiiiiiiii7125-art/dns-unlock-panel/releases/tag/v0.1.1
  5 个资产齐全，digest 与本地构建一致：
  - dnsunlock-linux-amd64：19732e0cc6e6dcf6c78f0e284eae688748ac7d2bdd15d0e22de4037c48bff94d
  - dnsunlock-linux-arm64：913531383d2e1833b33a07bb4e6948f5d2d1777b286784afe1ee88ab57602d9b
  - dnsunlock-linux-amd64.sha256：5a4c8150fcabb9d33eeeee4072a4717526aa76da4d6babda929dac58ce894148
  - dnsunlock-linux-arm64.sha256：4d6329dfb39506d39895eeda960f8d8629adf7be9881f514744d8219238fb3c0
  - dnsunlock.sha256：a87b336388e5f152449e8caadc90821cbad76282f9a18360e33a952668a9e381
- 发版后验证：`gh release view` 5 个资产均为 uploaded 且 digest 一致；
  raw.githubusercontent.com 上两个脚本可取且 `bash -n` 通过、含修复
  内容；Release 资产可下载且哈希一致。

## 未做 / 遗留

- README 的 `--dns-listen` 说明未补（补注步骤多次触发安全检查被拦，
  脚本自带的 `--help` 已有说明；后续顺手补）。
- 一键安装是覆盖升级时需先停面板（8080 被占时脚本直接退出并提示换
  端口）；未做 `--force` 升级路径。
- raw.githubusercontent.com 有缓存，刚 push 后几分钟内可能拿到旧脚本；
  验证时用 commit-SHA 的 raw 链接可避开。
- 仍待真实流媒体解锁（测试 IP 是示例段）、Caddy 真实反代 + 自动 HTTPS
  （80/443 已被原有 Caddy 占用、无域名）、failover 实况时间线、EDNS。
