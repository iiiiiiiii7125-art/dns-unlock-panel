# 真机 DNS 操作实测（2026-11-20 21:30–21:40 CST，测试机 ip-172-26-15-152）

用户要求：在测试机上实测 DNS 操作是否生效。面板与 agent 均为 v0.1.1
一键安装（面板 :8080、agent :53，allowlist 仅 127.0.0.1）。

## 结论：DNS 操作全部生效

| 操作 | 结果 |
|---|---|
| 规则域名返回解锁 IP（netflix、www.netflix、youtube、disneyplus、hulu） | 通过，返回 203.0.113.10（HK）/ .20（US） |
| AAAA 查询 | 通过，NOERROR 且 0 条答案（NODATA） |
| 无规则域名走上游（example.com、tv.apple.com 清规则后） | 通过，返回真实 IP |
| TCP 查询 | 通过，同样返回规则 IP |
| 改规则即时生效（disneyplus HK→US→HK） | 通过，7 秒内切换并切回 |
| nameserver 模式（hulu → 1.1.1.1） | 通过，返回真实 IP；恢复地区规则后回到 203.0.113.20 |
| 新建规则（appletv → TEST-HK-1） | 通过，tv.apple.com 返回 203.0.113.10 |
| 清除规则（PUT 空字段） | 通过，tv.apple.com 恢复真实 Apple IP（151.101.x） |
| 地区无节点时的规则（bbciplayer→GB、dazn→JP） | 通过，优雅回落到上游真实 IP，不报错 |
| 白名单外来源查询 | 通过，超时无应答 |
| 面板与 agent 服务、机器原有服务 | 全部 active，未受影响 |

## 发现的小问题

- `DELETE /api/v1/rules` 返回 405：没有删规则的接口，规则靠 PUT 空字段
  清除（`{"cleared":true}`）。面板 UI 应走 PUT 清除路径；直接调 API 的人
  会撞上 405。建议后续补一个 DELETE 入口或在文档里写明。
- 测试中途 SSH 断过一次（broken pipe），重连后正常，与面板无关。

## 未验证

- 真实流媒体解锁：测试 IP 是文档示例段（203.0.113.x），不是真实解锁
  服务器；DNS 分流本身已验证，真正解锁取决于用户在面板里填的真实
  解锁 IP 背后的服务器。
- failover 实况时间线、EDNS、Caddy 真实反代 + 自动 HTTPS。

## 测试后状态

- 面板 admin / DnsTest2026!Real；规则恢复种子状态（netflix→HK、
  hulu→US，appletv 测试规则已清除）；节点 TEST-HK-1（203.0.113.10）、
  TEST-US-1（203.0.113.20）保留。

## 2026-11-21 补充：安装改成交互式问域名

- 用户反馈不知道域名往哪填；`install-panel.sh` 改为交互式：不传
  `--domain` 时安装中途提示输入域名，留空只跑 8080，填了走 Caddy
  自动反代 + HTTPS；`--domain` 照常可用；无终端（自动化）时静默
  跳过，默认 8080（commit d32652c）。
- 沙箱验证：留空、填域名、非法域名（格式拒绝）、无终端四种情况
  均通过；中途发现并修了两个小毛病：无控制终端时 `/dev/tty`
  报错会打出来、read -p 的提示被 `2>/dev/null` 吃掉看不见。
- 测试机真机验证：留空回车安装成功，面板恢复运行，旧数据都在
  （登录密码、规则、节点未变，netflix/hulu 解析正常）；填域名
  `dns.example.com` 时正确走到 Caddy 分支，因 80 端口被机器原有
  Caddy 占用而停下，未覆盖他人服务；随后留空重装恢复面板。

## 2026-11-21 补充：安装命令自动生成 + 修 401（commit df6b336）

- 用户现网装机报 401：`curl | bash` 时 stdin 是脚本本身，token
  提问的 read 会把脚本内容当成 token，拿垃圾去验证。根因是之前
  测试都走下载后执行，没走过管道这条路。
- 修法：面板登记服务器后直接给出填好的一键安装命令（token/名称/
  默认解锁 IP/allowlist 都带好，环境变量形式），每行也可点“复制
  安装命令”；install.sh 支持 DNS_AGENT_TOKEN 等环境变量，没带就
  交互问；所有提问改从 /dev/tty 读；无终端且没带 token 时明确
  报错，不再拿垃圾 token 撞 401。
- 沙箱验证：A 管道+环境变量、B 管道+终端手输 token、C 管道无
  终端无变量（明确报错）三条路全过；沙箱 UDP 被禁（send 直接
  PermissionError），UDP 只在测试机上验。
- 测试机真机验证：新面板二进制已换上（旧二进制备份在
  /tmp/dnsunlock-v011.bak），面板提供的新 /install.sh 与首页均含
  新代码；按面板生成命令的原样重装 agent：token 验证通过、sha256
  通过、UDP 查 netflix 得 203.0.113.10、AAAA 为 NODATA；随后恢复
  原 agent 配置（TEST-DNS-01），netflix/hulu 解析正常，测试服务
  器已删除。测试机现跑的是未发版的新构建，等用户定是否发 v0.1.2。



## 2026-11-21 补充：面板端点容错 v0.1.3（443 被挡自动走 :8080）

- 背景：用户香港机器 pride-bubble2（NAT 后，源 IP 10.188.154.184）
  连面板 https://dns.0v0.baby:443 时 TCP 挂起 134 秒后超时（curl 28）；
  面板本身正常，权威 DNS（Cloudflare，TTL 300）也没错；面板直连
  :8080 是通的（http://218.188.154.184:8080/install.sh 返回 200）。
  用户要求：不许再硬依赖 443，要做容错。
- 改动：install.sh 增加 probe_panel——候选顺序 (a)配置的 PANEL_URL、
  (b)同主机 http :8080、(c)同主机解析出的 IP :8080；每个候选只探一次
  --max-time 8，任何 HTTP 响应都算通（没 token 的 whoami 回 401 也算）；
  第一个通的作为本次安装的实际地址，都不通则列出试过的地址并提示用
  --panel 指定内网地址后退出。安装器用的地址与写进配置文件的规范
  地址分开（PANEL_BASE vs PANEL_URL）。dns-agent（Go）同款回退：
  启动时算好候选列表，config/heartbeat 每次按“上次通的优先，其余按
  顺序”逐个试，单次超时 5 秒；上次通的只放内存，不写磁盘。allowlist
  默认拒绝没动；没加 Cloudflare/中继/新端口。面板 UI 生成的安装命令
  不变（仍是 https 源地址，脚本自己回退）；服务器页加了一行说明。
  换成明文 http :8080 是用户明确要的取舍，写进 release notes。
- 沙箱验证：probe_panel 三条路全过——(1)死 443
  https://127.0.0.1:8443 立刻回退到 http://127.0.0.1:8080；
  (2)通的主 http://127.0.0.1:8080 原样使用；(3)全死
  https://10.255.255.1 时 0.86 秒退出 1 并列出试过的地址。
  panelCandidates 单测新增（internal/dnsagent/panel_fallback_test.go）；
  沙箱解析器会把未知域名解析成 198.18.x.x，单测只断言 (c) 的形状。
- 测试机真机验证（2026-11-21 06:18 UTC，ip-172-26-15-152）：
  新 amd64 二进制分 10 个 1M 块上传（隧道不稳，part-04/05/06/08 各
  重试 1-4 次才上齐），拼回调放后 sha256 与本地构建一致
  8de74f19…cea548a；面板二进制已换上（旧 v0.1.2 备份在
  /tmp/dnsunlock-v012.bak），dist 的 amd64 二进制+sha256 已更新，
  服务端 /install.sh 含 probe_panel、首页含回退说明。
  - (A) 装机回退：临时服务器 测试-自动3（srv-1795241899451629752），
    --panel https://127.0.0.1:8443（死）安装完成，结尾明确写“面板
    443 不通，已自动改走 http://127.0.0.1:8080”；装完 dig
    netflix.com → 203.0.113.10、hulu.com → 203.0.113.20、
    disneyplus.com → 203.0.113.10。此时 agent 配置里记的仍是死的
    https://127.0.0.1:8443，解析正常本身就是 agent 运行时回退的证据。
  - (B) agent 运行时回退：保持死的 panel_url，面板里把 disneyplus
    由 HK 改 US，5 秒内 dig 变 203.0.113.20；再改回 HK，8 秒后 dig
    回 203.0.113.10；journal 里无 poll 失败。
  - (C) 回归：--panel http://127.0.0.1:8080（通）直接用主地址，
    无探测失败、无“改走”提示，安装完成，netflix 解析正常。
  - (D) 全死：--panel https://10.255.255.1（SYN 挂起）+ --dns-listen
    127.0.0.1:5353，16.1 秒退出 1，报错列出两个试过的地址；复测一次
    确认退出码确为 1，agent 配置未被改动，两个服务仍 active。
  - 恢复：agent 配置已还原为 TEST-DNS-01（/tmp/agent-config-v012.bak），
    netflix/hulu/disneyplus 解析正常，临时服务器已删（只剩
    TEST-DNS-01），面板+agent 均 active。测试机现跑的是 v0.1.3 构建。

## v0.1.4：本机回环列入面板端点降级最后一环（2026-11-21，待发版）

背景：用户机器 pride-bubble2 既是面板机又是香港机器，公网 IP 218.188.154.184
从本机连不上（无 hairpin NAT，443 134 秒超时）；v0.1.3 的三个候选都解析到
同一个公网 IP，全灭。能通的是 http://127.0.0.1:8080（用户已用
--panel http://127.0.0.1:8080 装好 agent，server srv-1795240892073778844，
:53 正常）。

改动（仅 4 个文件，agent.go / panel_fallback_test.go / install.sh 两份）：
- probe_panel() 与 panelCandidates() 候选末尾追加 http://127.0.0.1:8080
  （无本机面板时连接被拒，瞬间失败，无代价；已有时去重）。全灭报错信息
  列出全部试过的端点（含本机），并提示同机时用 --panel http://127.0.0.1:8080。
- 其余行为不变：allowlist 默认拒绝不动，不加端口/中继/Cloudflare。

沙箱验证：
- go vet + go test ./... 全绿（含新增用例：黑洞公网 IP 候选
  [https://203.0.113.99:443, http://203.0.113.99:8080, http://127.0.0.1:8080]，
  主机名输入时本机候选必为最后一个）。
- probe_panel 全灭：0.99 秒退出 1，报错列出 https://10.255.255.1、
  http://10.255.255.1:8080、http://127.0.0.1:8080。

测试机验证（ip-172-26-15-152，2026-11-21 07:03–07:07 UTC）：
- 新 amd64 二进制（sha256 1084e5e9b3c7b2446fb32f7e43614cef2fa897cea410f30bf00666937305b66e）
  分 128KB 块上传：1MB 块在隧道里断流（part-08 三次重试全失败，拼出的文件
  哈希不对）；128KB 块逐块哈希校验后重拼一致。另：第一次重拼用了 /tmp/c*
  通配，误把测试机 /tmp 里其它 c 开头文件（约 89KB）拼了进去，改用
  /tmp/v014-c* 前缀后重拼哈希一致。教训：重拼通配必须用唯一前缀。
- 面板换新二进制（旧 v0.1.3 备份 /tmp/dnsunlock-v013.bak），dist amd64 +
  sha256 已更新（sha256sum -c 全 OK），served /install.sh 含 127.0.0.1:8080。
- (A) 安装降级——通过。--panel https://10.255.255.1（黑洞）：探测
  https://10.255.255.1 与 http://10.255.255.1:8080 各 8 秒超时后自动改走
  http://127.0.0.1:8080，6 步完成（16.3 秒），token 验证通过，sha256 通过，
  agent 配置记 panel_url https://10.255.255.1（死主地址，运行时再降级）；
  dig netflix.com → 203.0.113.10，disneyplus → 203.0.113.10。
  附带发现（旧问题，非本次改动）：stdin 关掉（</dev/null）且无 tty 时，
  ask() 里 read 遇 EOF 返回非零，set -e 直接静默退出（卡在 [1/6] 后无报错）。
  交互终端不受影响；本次测试改用管道喂换行通过。
- (B) agent 运行时降级——通过。配置里主地址已死的情况下，面板改规则
  disneyplus HK→US，25 秒内生效（dig → 203.0.113.20），再改回 HK 同样生效。
- (C) 回归——通过。--panel http://127.0.0.1:8080 直接用主地址，无探测失败、
  无“自动改走”提示，6 步完成。
- (D) 全灭——沙箱见上，0.99 秒退出 1，报错列出全部三个端点。
- 恢复：agent 配置已还原为 TEST-DNS-01（srv-1795180697363504777，
  panel_url http://127.0.0.1:8080），netflix/hulu/disneyplus 解析正常，
  临时服务器 测试-自动4（srv-1795244580078270475）已删（只剩 TEST-DNS-01），
  面板+agent 均 active，resolv.conf 未动（Tailscale 托管）。
  注意：测试机面板现跑的是从 ui/rules-refresh 树构建的二进制（含未发布的
  规则页重做），与 v0.1.4 发版构建的差异仅在 served index.html，降级代码
  完全一致。
