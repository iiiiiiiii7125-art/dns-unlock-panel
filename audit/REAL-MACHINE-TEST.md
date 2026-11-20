# DNS 分流解锁面板 v0.1.0 — 真机实测报告

- 测试时间：2026-11-20 12:13–12:20 UTC（20:13–20:20 CST）
- 测试机：ip-172-26-15-152，Tailscale 100.110.88.49，Debian 12，root
- 连接方式：SSH 经 Tailscale 隧道代理（`/tmp/ssh_test.sh`），面板通过同一代理访问
- 代码/发版：v0.1.0（commit c859db4，tag v0.1.0，Release 5 个资产）
- 测试范围：面板一键安装、面板登录/改密、节点/服务器/规则管理、DNS agent（UDP/TCP）、规则即时生效、nameserver 模式、allowlist 拦截、SNI 代理端到端

> ⚠️ 这台不是干净空机器，是用户正在用的 FLMX/OpenVPN 机器：FLMX 面板容器（6365/6366）、openvpn、sing-box、xray、danted、Caddy（80/443）、systemd-resolved（127.0.0.53:53），resolv.conf 是 Tailscale 生成的。测试全程未动 80/443/6365/6366/22，未停任何已有服务，未接管或改写 /etc/resolv.conf，未装 Docker，未动 /root 下已有文件。

## 总结论

面板与 DNS agent 在真机上**跑起来了，核心分流功能全部通过**（UDP DNS 首次在真机跑通）。但 **v0.1.0 的一键安装脚本本身是装不上的**：install-panel.sh 与 install.sh 都存在 sha256 文件名不匹配的 bug，校验必失败（P0，见下）。本次是绕过该 bug 手动装的，面板/agent 留在机器上未删。

## 发现的问题（按严重程度）

### P0-REAL-01：install-panel.sh 一键安装必定失败——sha256 文件名不匹配

- 现象：`curl -fsSL .../install-panel.sh | bash` 在 `[1/4] 下载面板二进制` 后报：
  `dnsunlock-linux-amd64: FAILED open or read` / `sha256 校验失败，停止安装`
- 根因：Release 的 `dnsunlock-linux-amd64.sha256` 文件内容是
  `7a2eb801…  dnsunlock-linux-amd64`（文件名是 `dnsunlock-linux-amd64`），
  但脚本把二进制下载为 `$TMP/dnsunlock`，然后在 `$TMP` 里 `sha256sum -c`，
  目录里根本没有叫 `dnsunlock-linux-amd64` 的文件，校验永远失败。
- 复现（真机实测）：二进制下载成功（9,726,167 字节），sha256 文件下载成功，
  `sha256sum -c` exit=1；把文件改名为 `dnsunlock-linux-amd64` 后同一文件校验 OK。
- 影响：v0.1.0 的面板一键安装在任何机器上都装不上；install.sh 里是同一个写法
  （二进制存为 `/usr/local/bin/dnsunlock`，却在 `/usr/local/bin` 里 `sha256sum -c`
  那个同名文件），DNS 一键安装同样必失败。
- 备注：之前四轮审计/修复报告里写的“模拟安装下载流程 sha256 通过”，
  是按匹配的文件名模拟的，没跑过脚本本身的下载+校验路径，所以没发现。
- 修法建议：脚本里下载时就用 `$BIN` 当文件名（或校验时用 `sha256sum -c <(sed …)` 改名），
  并把“按脚本原样跑一遍”加入发版门禁。

### P1-REAL-01：install.sh 在 systemd-resolved 机器上直接拒绝运行（:53 被占）

- 现象（未直接跑 install.sh，按代码+机器状态确认）：脚本开头
  `ss -tuln | grep -q ':53 '`，本机 systemd-resolved 占着 127.0.0.53:53 与 127.0.0.54:53，
  检查必触发，脚本直接退出（“53 端口已被占用，请先停掉它或改 DNS_LISTEN”）。
- 影响：绝大多数 Debian/Ubuntu（默认开 systemd-resolved）都装不上 DNS agent，
  除非先手动停 systemd-resolved 的 stub——脚本没给这个选项，也没说明。
  注意脚本里提到的 `DNS_LISTEN` 改法并没有对应的命令行参数，改监听端口
  只能手动改配置，等于这条路在文档里是断的。
- 另外：install.sh 的 resolv.conf 接管是可选项（最后一步问 `[y/N]`，默认不接管），
  本次没走到那一步，未验证接管/还原逻辑；Tailscale 生成的 resolv.conf 绝对不能接管。

### P3-REAL-01：面板默认监听 `*:8080` 明文 HTTP，无反代时登录走明文

- 面板无域名安装时只跑 `:8080`，监听所有网卡，明文 HTTP。登录有密码+5 次锁定，
  但密码本身走明文传输。内网/Tailscale 环境可接受；公网直接暴露 8080 则不建议。
  （本次未填域名，未测 Caddy 反代 + 自动 HTTPS：80/443 已被机器原有 Caddy 占用，
  且无域名可用，见“未验证”。）

### 观察（不算问题，记录在案）

- 面板启动日志会打印 `log in as admin (default password admin — change it after first login)`，
  只是提示默认账号，不含任何 token，可接受。
- `systemctl is-active flmx-panel-backend` 这类名字查不到 systemd 服务是正常的——
  FLMX 面板跑在 Docker 容器里，不走 systemd；容器本身 Up (healthy)。
- allowlist 拦截测试时，用 `pkill -f` 杀测试 agent 会把 pkill 自己的 ssh 会话
  也匹配进去（命令行里含有该字符串），导致那次 ssh 直接断开、exit 255。
  测试 agent 本身已死，主 agent 不受影响。这是测试手法问题，不是产品问题。

## 测试结果（逐项）

| # | 测试 | 结果 | 证据 |
|---|---|---|---|
| 1 | install-panel.sh 一键安装（不填域名） | ❌ 失败 | P0-REAL-01：sha256 校验必失败，脚本退出，未装完 |
| 2 | 手动装面板（二进制+校验+systemd，与脚本同款配置） | ✅ 通过 | sha256 OK；`dnsunlock-panel` active；首页含“登录面板”；监听 *:8080 |
| 3 | 面板经 Tailscale 代理访问 | ✅ 通过 | `curl --proxy … http://100.110.88.49:8080/` 200，首页含“登录面板” |
| 4 | 登录 admin/admin（must_change=true） | ✅ 通过 | 200，`must_change: true` |
| 5 | must_change 会话调管理接口 | ✅ 通过 | `/api/v1/status` → 403 `must_change_password` |
| 6 | 改密后旧密码失效、新密码可用 | ✅ 通过 | 旧密码 → 401；新密码登录 → 200，`must_change: false` |
| 7 | 登记 DNS 服务器 TEST-DNS-01 | ✅ 通过 | 201，返回一次性 agent token（仅显示一次） |
| 8 | 加节点 TEST-HK-1 / TEST-US-1 | ✅ 通过 | 201；列表接口 IP 打码 `203.0.*.*` |
| 9 | 面板 /install.sh 端点 | ✅ 通过 | 返回脚本，含面板地址；`xhj028`/`agent_token=` 0 处 |
| 10 | DNS agent 手动装（loopback 高端口 127.0.0.1:15353，不接管 resolv.conf） | ✅ 通过 | `dnsunlock-agent` active；UDP+TCP 均监听 15353 |
| 11 | **UDP**查 netflix.com A | ✅ 通过 | → `203.0.113.10`（TEST-HK-1），0ms；**沙箱里从未跑通过的 UDP 路径首次实测通过** |
| 12 | UDP 查 netflix.com AAAA | ✅ 通过 | NODATA（ANSWER: 0） |
| 13 | UDP 查 example.com（上游） | ✅ 通过 | → 172.66.147.243 / 104.20.23.154，4ms |
| 14 | TCP 查 netflix.com A | ✅ 通过 | → 203.0.113.20（改规则后） |
| 15 | 规则改动即时生效 | ✅ 通过 | netflix HK→US，约 3 秒内从 .10 切到 .20；恢复 HK 后约 6 秒回到 .10 |
| 16 | nameserver 模式（hulu → 1.1.1.1） | ✅ 通过 | hulu.com → 23.59.88.38 / 23.59.88.34（真实 IP） |
| 17 | allowlist 外 IP 被拒 | ✅ 通过 | 另起 allowlist=10.255.255.1 的 agent，127.0.0.1 查询超时无应答（dig exit 9） |
| 18 | SNI 代理端到端（127.0.0.1:18443，allowlist 127.0.0.1） | ✅ 通过 | `openssl s_client -servername example.com` 返回 example.com 真实证书（Cloudflare TLS Issuing ECC CA 3），Verify 0 |
| 19 | install.sh 直接跑 | ⛔ 未跑 | P1-REAL-01：:53 被 systemd-resolved 占用，脚本会直接拒绝；且 resolv.conf 绝不能接管，未冒险 |
| 20 | Caddy 反代 + 自动 HTTPS | ⛔ 未验证 | 80/443 已被原有 Caddy 占用，无域名可用；未动现有 Caddy 配置 |

## 机器现状（测试后核对）

- resolv.conf 未动：仍是 Tailscale 生成的内容（nameserver 100.100.100.100），未被 `chattr +i`，未被改写。
- FLMX 容器：flmx-panel-backend / frontend / postgres 均为 Up (healthy)；6365/6366 仍在监听。
- Caddy（80/443）、systemd-resolved 均为 active。
- openvpn、sing-box（含 1.14.4-flmx1）、xray、danted 进程均在跑。
- 新增的服务：`dnsunlock-panel`（:8080）、`dnsunlock-agent`（127.0.0.1:15353），均为 active；文件：`/usr/local/bin/dnsunlock`、`/etc/dnsunlock/config.json`（0600）、`/var/lib/dnsunlock/panel.json`（0600）及 `.bak`。

## 留在机器上的测试数据（与真实数据区分）

- 面板登录：admin / **`DnsTest2026!Real`**（测试密码，已改；请用户尽快改成自己的密码）
- 测试节点：TEST-HK-1（203.0.113.10，HK）、TEST-US-1（203.0.113.20，US）——203.0.113.0/24 是文档示例段，不是真实解锁 IP
- 测试服务器：TEST-DNS-01（srv-1795176921657651630），agent token 仅在面板登记时显示一次，已写入测试机 `/etc/dnsunlock/config.json`（0600）
- 规则已恢复为种子状态：netflix → HK，hulu → US（address 模式）
- SNI 测试进程已杀掉，18443 已释放；allowlist 测试 agent 已杀掉，15354 已释放

## 未验证的项

- Caddy 真实反代 + 自动 HTTPS（需域名 + 空闲 80/443，本机不具备条件）
- 真实流媒体解锁（测试 IP 是文档示例段，未连真实解锁节点；DNS 改写本身已验证）
- failover/failback 实况（需等 30 秒探活循环 + 弄坏一个节点，未跑时间线）
- resolv.conf 接管/还原（本机绝对不能接管，未尝试）
- install.sh 全流程（被 :53 检查挡住，未跑）
- EDNS（OPT 不解析，已知未实现）

## 建议

1. 先修 P0-REAL-01（两个安装脚本的 sha256 文件名问题），修完重新发版（v0.1.1 或重新打 v0.1.0 的资产），再让用户在真机上重跑一键安装。
2. 再修 P1-REAL-01：install.sh 在 systemd-resolved 机器上的出路（检测到 :53 被占时给出可行的处理选项，而不是直接退出；`DNS_LISTEN` 要有真实可用的入口）。
3. 本次手动装的面板/agent 先留着，等用户决定是留着用还是清掉；测试密码请尽快更换。
