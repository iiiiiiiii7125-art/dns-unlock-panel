# DNS 分流解锁面板 — 审计报告

- 审计对象：`~/workspace/dns-unlock-panel/`（MVP，2026-11-20 11:05 CST 时的状态）
- 审计方式：只审计、不改代码、不 push、不发版。逐行读了全部 Go 代码、全部 shell 脚本、前端、`data/platforms.json`（169 个平台，304 条域名）、`gen_platforms.py`、`/tmp/dns-test/run_tests.sh` 文本；用 grep / JSON 解析做了静态核查。
- **动态验证没做**：本次审计收到一条执行风险提示，禁止运行/构建/测试被审代码，所以 `go vet`、`go test`、重新跑 DNS 测试、启动面板/代理实测都没有重跑。下面引用的“10/10 通过”是 MVP 交付时留下的 `/tmp/dns-test/final-result.txt` 文本，不是本次重跑的结果。如需重跑动态验证，请用户另行确认后再做。
- 结论先说：**不建议发版。先修好 7 条 P0，再重跑一次动态验证。**
- 简化目标（按用户最后澄清）：只求一条链安全稳定跑通——面板（admin/admin，可改密）→ 香港机器装 DNS（一键脚本、备份/还原 resolv.conf）→ 解锁机（用户自己的机器，SNI 代理 443）→ 面板选平台/地区、改规则立即生效。围绕这条链只问四个问题：会不会断网、会不会漏 IP、会不会被别人蹭用、改错了能不能还原。

## 汇总

| 级别 | 数量 | 意思 |
|---|---|---|
| P0 阻塞发版 | 7 | 不修不能发，会断网、漏 IP 或被蹭用 |
| P1 必须修 | 15 | 不修迟早出问题 |
| P2 建议修 | 10 | 最好修，不修也能先跑 |
| P3 可改进 | 6 | 小毛病 |
| 合计 | 38 | |

> 备注一句：如需隐藏真实 IP，可后续再加中继，不在本版做、不作为阻塞项。

## 核心链结论（每段一句话）

- **搭建（面板部署）：不通过。** 面板一键安装脚本 `scripts/install-panel.sh` 根本不存在，GitHub 仓库是公开空仓、无提交、无 tag、无 Release，README 写的一键部署跑不起来。
- **安装（三条脚本）：不通过。** DNS 安装脚本有备份/还原的架子，但缺 chattr 锁定、缺 resolvconf/dhclient/cloud-init 处理、二次接管会丢原备份；且默认不设 allowlist，53 端口一开就对全网开放。
- **DNS 设置：不通过。** DNS 本身能按规则返回 IP、改规则 5 秒内生效（按旧测试文本），但 AAAA、其他查询类型、共享域名冲突、无效 IP 静默失败这些地方都会让解锁时灵时不灵，且上游一挂就直接没回应。
- **AKDNS 对照：不通过。** AKDNS 有的基线解锁测试、装完再验证、chattr +i 锁定、UDP 全超时自动切 TCP（use-vc），我们都没有或只有一半。
- **会不会断网：会。** 接管 resolv.conf 后 systemd-resolved / NetworkManager / netplan 任一环节没处理好，本机就可能没 DNS；还原也不完整。
- **会不会漏 IP：会。** 面板接口直接返回完整解锁 IP（前端打码只是障眼法），且 `/install.sh` 不登录就能拿到面板 token，拿到 token 就能拿到全部 IP。
- **会不会被别人蹭用：会。** DNS 和 SNI 默认谁都能用，没配 allowlist 就是公开代理/公开 DNS。
- **改错了能不能还原：不完全能。** resolv.conf 还原只认最新一次备份，卸载失败还会删掉备份。

---

## P0 — 阻塞发版（7 条，每条一句话说清问题和修法）

### P0-01 面板一键安装脚本不存在，仓库是空的
- 问题：`scripts/install-panel.sh` 不存在，GitHub 仓库 `iiiiiiiii7125-art/dns-unlock-panel` 是公开空仓、无提交、无 tag、无 Release，README 写的面板一键部署根本跑不起来。
- 位置：`scripts/`（缺文件）、README.md、AUDIT-PENDING.md。
- 修法：先写好 `install-panel.sh`（含填域名自动 Caddy 反代），本地验完再 `git init`、提交、打 tag、发 Release。

### P0-02 还是旧的共享 token，没做成 admin/admin 可改密
- 问题：代码里仍是默认 token `xhj028`（12 处），没有用户名密码、没有改密入口、没有 session，用户要的 admin/admin 一行都没实现。
- 位置：`cmd/dnsunlock/main.go:82,113`、`internal/panel/panel.go`（auth 函数）、`internal/panel/assets/index.html:35`。
- 修法：做成 admin/admin 登录、密码哈希存、登录后可改密、旧密码立即失效；DNS 机器改用每台随机 token。

### P0-03 `/install.sh` 不登录就能拿到面板 token，等于把管理员密码贴在门口
- 问题：`/install.sh` 不鉴权，里面直接 baked 了面板 token，任何人能访问面板就能拿到 token，再调全部 API。
- 位置：`internal/panel/panel.go:handleInstallScript`、`cmd/dnsunlock/main.go:104`（启动日志还把 token 打出来）。
- 修法：`/install.sh` 下发时不要 baked 真 token，改成安装时人工输入或每台机器的一次性 token；启动日志不打 token。

### P0-04 DNS 和 SNI 默认谁都能用，会被拿去做攻击和蹭流量
- 问题：allowlist 为空时默认全部允许，安装脚本还主动放行 53 端口，DNS 会变成公开递归解析器、SNI 会变成公开代理。
- 位置：`internal/dnsagent/agent.go:New`（空 allowlist 只警告）、`internal/sniproxy/proxy.go:New`、`scripts/install.sh`（ufw/firewall-cmd 放行 53）。
- 修法：默认拒绝，没填 allowlist 就拒绝启动或只听 127.0.0.1；SNI 同理，安装时必须填允许的 IP。

### P0-05 面板接口直接返回完整解锁 IP，前端打码没用
- 问题：`GET /api/v1/nodes`、`GET /api/v1/rules`、`GET /api/v1/servers`、`GET /api/v1/agent/config` 都返回完整 IP 和服务器 token，前端打码只遮住了显示，没遮住接口。
- 位置：`internal/panel/panel.go:handleNodes/handleRules/handleServers/handleAgentConfig`。
- 修法：列表接口默认只返回打码 IP，完整 IP 只有点“显示”时单独调一个接口拿；agent 配置只返回本台机器要用的规则。

### P0-06 一个 token 通吃面板、agent 和下载，一台机器丢了等于全丢
- 问题：面板 token、agent token、下载 token 是同一个，agent 被拿到 token 就能当管理员，还能伪造任意 server_id 上报心跳、改节点状态。
- 位置：`internal/panel/panel.go:auth/handleAgentConfig/handleHeartbeat`、`cmd/dnsunlock/main.go`。
- 修法：面板登录、agent token、下载 token 三套分开，agent token 每台随机且只能拉自己的配置、上报自己的心跳。

### P0-07 发的二进制是旧的，arm64 的包根本没有
- 问题：`dist/` 里的二进制是 11-20 02:54 旧版，之后 `go.mod` 升到 go 1.24、加了 `x/crypto` 却没重构建、没跑过构建验证；安装脚本要下的 `dnsunlock-linux-arm64` 在 `dist/` 里不存在，arm64 机器安装必失败。
- 位置：`dist/`、`go.mod`、`scripts/install.sh`（ARCH 分支）。
- 修法：重构建 amd64+arm64 两个包、校验 sha256、打 tag 发 Release 后再让脚本去下，本地先验一遍。

---

## P1 — 必须修（15 条）

### P1-01 DNS 只会答 A/AAAA，其他查询直接走样
- 问题：匹配到的域名问 CNAME、HTTPS、TXT 等类型时直接转发上游，拿到的 CNAME 后续解析可能绕开解锁，解锁时灵时不灵；而且返回的包固定写 0x8180、TTL 固定 60、不认 EDNS，超过 4096 字节的回答会被截断，上游一挂就直接没回应（连 SERVFAIL 都不回）。
- 位置：`internal/dnsagent/agent.go:parseQuestion/buildResponse/handlePacket/forwardUDP/forwardTCP`。
- 修法：匹配到的域名所有类型都按规则处理或明确说明只支持 A/AAAA；转发失败回 SERVFAIL；支持 EDNS、放大包上限。

### P1-02 好几个平台共用一个域名，后设置的会悄悄盖掉先设置的
- 问题：`youtube.com` 被 4 个平台共用、`facebook.com`、`netflix.com` 等也被共用，agent 里后一条规则直接覆盖前一条，用户在面板上看不出谁赢了。
- 位置：`internal/dnsagent/agent.go:fetchConfig`、`data/platforms.json`（共享域名 9 个）。
- 修法：面板保存时检测域名冲突并提示，agent 里冲突的域名只允许一条规则生效并写明是哪条。

### P1-03 有的平台域名收得太宽，会把不相关的流量也拐走
- 问题：`appletv` 收了 `apple.com`、`primevideo` 收了 `amazon.com`、`bbciplayer` 收了 `bbc.com`、`copilot` 收了 `bing.com`，这些域名下的其他服务也会被拐到解锁 IP。
- 位置：`data/platforms.json`（`appletv`、`primevideo`、`bbciplayer`、`copilot`、`meta-ai` 等）。
- 修法：只留真正做地域判定的域名，宽域名删掉或改成更具体的子域名。

### P1-04 自定义域名没校验，填个 `com` 就能拐走所有 `.com`
- 问题：自定义域名只判了非空、无空格，填 `com`、`google.com` 都能保存，等于把一大片域名都拐走。
- 位置：`internal/panel/panel.go:handleCustomDomains`。
- 修法：拒绝顶级域和过短后缀，保存前提示这条会覆盖多少平台。

### P1-05 IP 没校验，填错了只会静默失败
- 问题：节点、自定义 IP、备用 IP、nameserver、上游 IP 全都没校验格式，填错后 agent 解析不到 IP，A 查询直接回空答案，用户只看到打不开、不知道为什么。
- 位置：`internal/panel/panel.go:handleNodes/handleRules`、`internal/dnsagent/agent.go:buildResponse(net.ParseIP(t.ip))`。
- 修法：保存时校验 IP 格式，错了就报错不保存；agent 解析失败要记一条可查的错误，不要静默回空。

### P1-06 备用 IP 切过去就回不来了，改规则也清不掉
- 问题：自动切到备用 IP 后，面板上改了主 IP，agent 的覆盖还留着（只删了被删掉的平台），等于改了也白改；备用 IP 本身坏了也没人再检查。
- 位置：`internal/dnsagent/agent.go:fetchConfig/failoverToBackup`。
- 修法：主 IP 一改就清掉覆盖，备用 IP 也要探活，主 IP 恢复后自动切回并记一条记录。

### P1-07 默认解锁 IP 是摆设，填了也不生效
- 问题：面板上填的默认解锁 IP 只存着、agent 配置里也带着，但 agent 查域名时根本没用它，没有规则的平台还是走上游。
- 位置：`internal/panel/panel.go:handleAgentConfig`（只写了字段）、`internal/dnsagent/agent.go`（全文件无 `DefaultUnlockIP`）。
- 修法：要么让 agent 真的用它（无规则域名返回默认 IP），要么把这个输入框删掉，别让人白填。

### P1-08 改节点时不填“启用”就会把节点关掉
- 问题：改节点接口里没传 `enabled` 就当成 false，改个名字或备注就会顺手把节点禁用，引用它的规则跟着失效。
- 位置：`internal/panel/panel.go:handleNodeByID`（`d.Nodes[i].Enabled = upd.Enabled`）。
- 修法：改成只改传了的字段，没传 `enabled` 就别动它。

### P1-09 接管 resolv.conf 会丢配置，还原也不完整
- 问题：没做 `chattr +i` 锁定，dhclient、cloud-init、resolvconf 下次一跑就可能覆盖；备份是软链时拷的是链不是内容；接管两次后还原只认最新一次备份，还原的是 127.0.0.1 不是原配置；NetworkManager 只改第一个连接、不管 IPv6；netplan 只提示不处理。
- 位置：`scripts/install.sh`（接管段、内嵌还原脚本）、`scripts/restore-resolv.sh`。
- 修法：备份拷内容不拷软链、只备一次原文件、加 `chattr +i` 并在还原时去掉、处理 resolvconf/dhclient/cloud-init、NetworkManager 改全部连接加 IPv6、还原后恢复原来的软链关系。

### P1-10 安装脚本缺检查、校验可绕过、token 会露在进程列表里
- 问题：不检查 systemd 在不在、53 端口有没有被占、装没装 curl 之外要的东西；sha256 文件下不到就直接跳过校验（`|| true`），且二进制和校验文件走同一个没加密的通道，中间人能一起换；token 写在 systemd 启动命令里，`ps` 就能看到。
- 位置：`scripts/install.sh`（下载段、systemd 段）。
- 修法：先检查 systemd/端口/依赖再装；sha256 下不到就停下来别装；token 只放 600 权限的配置文件里，启动命令用配置文件。

### P1-11 没有装前测试和装后验证，装完不知道通没通
- 问题：AKDNS 有基线解锁测试、装完再验证，我们只有一句 `dig` 提示，脚本自己不测解锁 IP 通不通、不测规则生没生效。
- 位置：`scripts/install.sh`（结尾只有两行 dig 提示）。
- 修法：装完脚本自己跑一遍：测解锁 IP 443 通不通、dig 一条已设规则的域名看回的是不是解锁 IP，不通就报错别说“安装完成”。

### P1-12 有些平台的地区在面板里根本选不到
- 问题：平台库里有 AT（奥地利）、DK、ES、FI、NO、NZ、PL、SE 这些地区，但面板地区列表只有 26 个、没有这些，相关平台选不到对应地区；`abema` 在代码里叫 `abematv`，名字对不上。
- 位置：`internal/model/model.go:Regions`（26 个）、`data/platforms.json`（33 种地区值）。
- 修法：两边地区列表统一成一份，平台名和 ID 也统一。

### P1-13 面板数据文件谁都能读，坏了就起不来
- 问题：`data/panel.json` 是 644 权限，存着全部节点 IP 和服务器 token，本地任何用户都能读；文件一损坏面板就启动失败，没有备份也没有恢复办法。
- 位置：`internal/store/store.go:saveLocked`（0644）、`New`（解析失败直接返回错误）。
- 修法：数据文件改 600，每天自动备份一份，损坏时用备份恢复并提示。

### P1-14 Cloudflare Tunnel 脚本一步错就悄悄过
- 问题：登录、建 tunnel、建 DNS 记录、装服务全是 `|| true`，失败也不停；取 tunnel 凭据文件靠 `awk` 抠列表输出，格式一变就错；缓存规则只靠口头提醒，脚本自己不做。
- 位置：`scripts/cloudflare-tunnel.sh`。
- 修法：关键步骤失败就停下来报错，凭据文件用 tunnel 命令的确定输出取，缓存规则写进脚本或检查清单里。

### P1-15 卸载可能删掉还原用的备份
- 问题：卸载时还原失败只打印一句提醒就继续删 `/etc/dnsunlock`，备份删了就再也还原不了；防火墙放行的 53、Caddy、cloudflared 也没清。
- 位置：`scripts/uninstall.sh`。
- 修法：还原失败就停下来别删备份，卸载清单里把防火墙、Caddy、cloudflared 也列上。

---

## P2 — 建议修（10 条）

### P2-01 没有 DNS 缓存，上游只认 1.1.1.1
- 问题：每次查询都去问上游，又慢又容易被上游限速；上游只写死 1.1.1.1，挂了没备选，也不支持 DoH/DoT。
- 位置：`internal/dnsagent/agent.go:forward`。
- 修法：按 TTL 做个小缓存，上游配两个（1.1.1.1 + 8.8.8.8），一个挂了换另一个。

### P2-02 面板没有防暴力破解，token 存在浏览器里
- 问题：登录失败不限次数，token 放 URL 里会进日志、放 localStorage 里关不掉，没有退出登录。
- 位置：`internal/panel/panel.go:auth`、`internal/panel/assets/index.html`（localStorage）。
- 修法：登录失败限次数、token 别放 URL、加退出登录。

### P2-03 SNI 代理收不全大的 ClientHello，连接挂了也不断
- 问题：ClientHello 分片、大于 16K 就直接断开；转发时没设超时，连接挂住会一直占着。
- 位置：`internal/sniproxy/proxy.go:handleTLS/handleHTTP`。
- 修法：支持分片重组，转发全程设超时，定期清掉挂住的连接。

### P2-04 前端直接把节点名拼进页面，有注入风险
- 问题：节点名、备注等直接拼进 `innerHTML`，填个特殊字符就能插代码。
- 位置：`internal/panel/assets/index.html:renderNodes/renderRules` 等。
- 修法：显示用户填的内容时先转义，别直接拼 HTML。

### P2-05 解锁节点安装脚本传空地址会乱跑
- 问题：`install-unlock-node.sh` 用 `bash <(curl …)`，面板地址为空时拼出来的地址是错的，还会把参数传丢。
- 位置：`scripts/install-unlock-node.sh`。
- 修法：地址为空就停下来提示，别拼错地址去下载。

### P2-06 平台库有些域名没验证过
- 问题：`hbomaxcdn.com`、`daznservices.com` 这类域名在公开资料里对不上，可能是编的或过时的。
- 位置：`gen_platforms.py`、`data/platforms.json`。
- 修法：上线前对 Tier 1/2 的域名逐条 dig 验证，验证不过的删掉或标注。

### P2-07 探活只拨 TCP 443，不代表真能解锁
- 问题：443 通了不等于能解锁，TLS 不通、平台封了这个 IP 也测不出来。
- 位置：`internal/dnsagent/agent.go:checkHealth`。
- 修法：探活改成拨通后做一次 TLS 握手，或定期按自测清单抽查一两个平台。

### P2-08 改个节点也会让配置版本 +1，agent 白白重载
- 问题：加节点、改备注这些不影响规则的操作也会让配置版本涨，agent 每 5 秒都要重建一次域名表。
- 位置：`internal/store/store.go:Update`、`internal/panel/panel.go`（多数写操作都传 changed=true）。
- 修法：只有规则、域名、上游变了才涨版本，其他操作不涨。

### P2-09 面板挂了 agent 还能跑，但没人会知道
- 问题：面板挂了 agent 还能按最后一份规则继续工作（这是对的），但面板挂多久、规则是不是旧的，agent 不会告诉用户。
- 位置：`internal/dnsagent/agent.go:pollLoop`（失败只打一行日志）。
- 修法：面板连续拉不到配置超过 1 分钟，agent 在日志/状态里明确提示“正在用旧规则”。

### P2-10 README 和 DESIGN 写的不一样
- 问题：DESIGN 说所有 API 都不缓存，实际上只有 `/api/` 开头的才加了 `no-store`；README 说的构建 Go 版本和实际用的也不一致。
- 位置：`DESIGN.md`、`README.md`、`cmd/dnsunlock/main.go`。
- 修法：文档和代码对一遍，改完代码顺手改文档。

---

## P3 — 可改进（6 条）

### P3-01 地区优先级表漏了澳门和意大利
- 问题：`RegionPriority` 里没有 MO、IT，自动选地区时这两个地区永远排不到。
- 位置：`internal/model/model.go:RegionPriority`。
- 修法：补上 MO、IT。

### P3-02 前端有两份，改了一份容易忘另一份
- 问题：`web/index.html` 和 `internal/panel/assets/index.html` 内容一样但各存一份，目前没差，改的时候容易只改一份。
- 位置：`web/index.html`、`internal/panel/assets/index.html`。
- 修法：只留一份，另一份改成构建时自动复制。

### P3-03 构建说明里的 Go 版本对不上
- 问题：README 说用 Go 1.22，实际 `go.mod` 是 1.24，构建命令里还写着临时 Go 的路径。
- 位置：`README.md`（构建节）、`go.mod`。
- 修法：统一写 Go 1.24，构建命令写系统 Go 的正常写法。

### P3-04 有段死代码没删
- 问题：`proxyConn` 写了没人调，`DefaultUnlockIP` 也是写了没人用，留着容易让人误会。
- 位置：`internal/sniproxy/proxy.go:proxyConn`。
- 修法：删掉或接上真逻辑。

### P3-05 自测清单里的链接可能过期
- 问题：自测清单里 Netflix 那个片单链接是写死的片名 ID，平台一改就打不开。
- 位置：`internal/panel/panel.go:unlockChecks`。
- 修法：自测链接改成各平台首页加文字说明，别依赖单个片名。

### P3-06 测速用的 `date +%s%N` 在有些系统上不好使
- 问题：`pick_fastest_ip` 靠 `date +%s%N` 算毫秒，在 Alpine/busybox 上可能不支持，测速会算错。
- 位置：`scripts/install.sh:pick_fastest_ip`。
- 修法：测速改用 `bash` 内置计时或 `timeout` 的返回码，别依赖 `%N`。

---

## 搭建（面板部署）— 结论：不通过

- 源码构建：`go.mod` 是 go 1.24、`x/crypto v0.42.0` 是 indirect 依赖但代码里没用到（没搜到 bcrypt），`dist/` 里的二进制还是 go 1.22 时代旧版，构建和源码对不上；没有交叉编译脚本，arm64 包不存在。
- Release 资产与 sha256：没有 tag、没有 Release，`dist/dnsunlock-linux-amd64.sha256` 本地校验值和二进制对得上（`1a466b31…`），但这个包是旧版，且没经过公开下载验证。
- 公开仓库敏感信息：仓库是公开空仓；代码里没有 `gho_/ghp_` 这类真 token，没有真实 IP（示例全是 203.0.113.0/24 文档段），但默认 token `xhj028` 有 12 处、默认登录逻辑还没改，公开后任何人都能按默认 token 试。
- 面板首次启动：默认监听 `:8080`（所有网卡、没 TLS），数据文件 644，启动日志打 token，首次启动没有强制改密。
- 反代 Caddy/Nginx：`install-panel.sh` 不存在，Caddy 反代、自动 HTTPS、域名为空/已占用/证书失败的回退全都没实现；`cloudflare-tunnel.sh` 有但步骤失败也继续跑，凭据文件靠 `awk` 抠。
- Cloudflare Tunnel 缓存：代码里 `/api/` 返回了 `Cache-Control: no-store`，但 `/install.sh`、`/dl/*` 没加，Cache Rule 全靠用户手动去控制台加，脚本不检查。

## 安装（全部脚本）— 结论：不通过

| 脚本 | 结论 | 一句话 |
|---|---|---|
| `install-panel.sh` | 不存在 | 面板一键搭建和自动反代都没写 |
| `scripts/install.sh`（DNS 端） | 有阻塞项 | 备份/还原有架子但不完整，sha256 可绕过，token 露在启动命令里，缺 systemd/端口检查 |
| `scripts/install-unlock-node.sh` | 有阻塞项 | `bash <(curl …)`、空地址会拼错，且 SNI 模式没配 allowlist，默认公开代理 |
| `scripts/uninstall.sh` | 有阻塞项 | 还原失败还继续删备份，防火墙/Caddy 没清 |
| `scripts/restore-resolv.sh` | 有阻塞项 | 只认最新备份、还原不完整（见 P1-09） |
| `scripts/cloudflare-tunnel.sh` | 有阻塞项 | 关键步骤失败也继续，凭据靠 `awk` 抠，缓存规则不检查 |

- 下载源与校验：二进制和 sha256 走同一个面板地址（可能是 http），中间人能一起换；sha256 下不到就跳过校验。
- root 权限：都要 root，没做非 root 提示以外的事；`curl | bash` 本身没校验。
- 包管理器适配：脚本只检查 curl，没装依赖，没分 Debian/Ubuntu/CentOS/Alpine/Arch；没 systemd 的机器上 `systemctl` 会直接失败。
- 端口占用检测：没检查 53、443、80 有没有被占，agent 绑不上也照样说安装完成。
- 防火墙放行：ufw/firewall-cmd 有就放行 53，没就跳过，不检查云厂商安全组。
- 失败回滚/幂等：下载失败会停，但登记服务器、写 systemd、改 resolv.conf 做到一半失败会留半截，没回滚；重跑会重复登记服务器（每次生成新 server_id）。
- 交互默认值：allowlist 提示可空，空着就等于公开；是否接管 DNS 默认 N，这点是对的；DNS 服务器名、默认 IP 都靠人工填，填错没校验。
- 覆盖已有配置：systemd-resolved 的 drop-in 是新建的（不算覆盖），但 NetworkManager 会改第一个活动连接，resolv.conf 软链会被删掉重写，Caddy/Nginx 配置本身没被脚本动过（因为反代脚本不存在）。

## DNS 设置 — 结论：不通过

- `/etc/resolv.conf` 接管全过程：接管前会备份到 `/etc/dnsunlock/resolv.conf.bak.<时间>`，但备份拷的是软链、没 `chattr +i`、没处理 resolvconf/dhclient/cloud-init，接管两次后原备份就丢了；还原只认最新一次备份，恢复的是 127.0.0.1 不是原配置；NetworkManager 只改第一个连接、不管 IPv6；netplan 只提示。
- DNS agent 监听 53：UDP 和 TCP 都听，但没做速率限制；EDNS 不支持；TCP 兜底只在转发上游时有，客户端问 agent 时 UDP 不通不会自动提示切 TCP。
- allowlist：有，但默认空等于全放行，安装时可空着跳过。
- TTL/缓存：回答 TTL 固定 60、没缓存，每次都问上游；改规则后 5 秒轮询生效（旧测试文本说 6 秒内变了），但备用 IP 覆盖改规则清不掉，旧规则会残留。
- 改规则生效链路：面板改规则 → 配置版本 +1 → agent 5 秒轮询 → 版本变了重建域名表，链路本身是对的，但节点改名、改备注也会让版本 +1，白白重载。
- nameserver 与 address 两种模式：address 直接回 IP，nameserver 原样转发，分得清；但 nameserver 模式没填上游 IP 时规则会被静默跳过，面板上看不出来。
- 上游 DNS 选择与故障：上游只认 1.1.1.1，挂了没备选，转发失败直接没回应。
- 客户端 DNS 缓存刷新提示：README 只写了两行 dig，没提浏览器/系统缓存要清、要等几分钟。
- 卸载/还原后系统 DNS 是否恢复原样：不完全恢复，见 P1-09、P1-15。

## 与 AKDNS 安装脚本对照

对照来源：AKDNS 公开文档里写明的行为（交互式菜单、基线解锁测试、DNS 测速选最快节点、设为系统 DNS、按服务选解锁、装完再验证；接管前完整备份、一键还原、处理 systemd-resolved / NetworkManager / netplan / resolvconf、`chattr +i` 锁定防覆盖；UDP 53 全超时自动切 TCP、options use-vc、后端支持 DNS over TCP、Alpine/musl 可能不支持；只改选中服务的域名、其余流量直连）。**没有下载、没有运行 akdns.sh 本身，只用公开文档对照。**

| AKDNS 做法 | 我们做到了吗 | 差距 |
|---|---|---|
| 交互式菜单 | 没有 | 只有一串 `read` 提问，没菜单、没法回头改 |
| 基线解锁测试（装前先测） | 没有 | 见 P1-11，装前不测解锁 IP 通不通 |
| DNS 测速选最快节点 | 只有一半 | 安装脚本有 `--unlock-ips` 测速，但面板里没有测速入口，默认规则也不测速 |
| 设为系统 DNS | 有，但不完整 | 会备份、会处理 resolved/NM，但 netplan 只提示，见 P1-09 |
| 按服务选解锁 | 有 | 面板按平台选地区/IP 是有的 |
| 装完再验证 | 没有 | 只有两行 dig 提示，脚本不自己验证 |
| 接管前完整备份、一键还原 | 只有一半 | 备份有，还原不完整，见 P1-09 |
| 处理 systemd-resolved / NetworkManager / netplan / resolvconf | 只有一半 | resolved/NM 有，netplan 只提示，resolvconf 没处理 |
| `chattr +i` 锁定防覆盖 | 没有 | 全仓没搜到 `chattr` |
| UDP 53 全超时自动切 TCP（use-vc） | 只有一半 | agent 转发上游时 UDP 不通会走 TCP，但客户端到 agent、系统 resolv.conf 里都没写 `options use-vc`，Alpine/musl 不支持也没提示 |
| 只改选中服务的域名、其余直连 | 有 | 域名最小化、未命中走上游，这点做到了 |

## 家宽机（解锁机）— 一句话备注

- 如需隐藏真实 IP，可后续再加中继，不在本版做、不作为阻塞项。

## 平台库准确性（抽查 38 个）

- 总量：169 个平台、304 条域名、292 条不重复，没有重复 ID，没有格式错的域名，没有通用 CDN 域名（`akamaihd.net` / `cloudfront.net` / `amazonaws.com` / `1e100.net` / `googlevideo.com` / `fbcdn.net` 全都没收）。
- 抽查的 38 个（Netflix、Disney+、HBO Max、Hulu、Prime Video、Apple TV+、YouTube Premium、Spotify、ChatGPT、Claude、Gemini、TikTok、Instagram、Facebook、X、DAZN、Paramount+、Peacock、BBC iPlayer、Crunchyroll、Bilibili 国际、iQIYI 国际、Viu、WeTV、U-NEXT、TVer、Sora、Copilot、Meta AI、Grok、Midjourney、Perplexity、YouTube、WhatsApp、Telegram、Threads、Discord）核心域名基本真实，但有 3 个问题：`abema` 在库里叫 `abematv`、对不上名字；`hbomaxcdn.com`、`daznservices.com` 等域名在公开资料里对不上，没验证过；`youtube.com`、`facebook.com` 等 9 条域名被多个平台共用，会互相覆盖。
- Tier 排序：Tier 1 是 Netflix、YouTube Premium、Disney+、ChatGPT、TikTok、Spotify、HBO Max、Claude、Gemini、Instagram、Prime Video、Hulu，排得合理；但 `data/platforms.json` 里 tier 字段全是 0，Tier 是面板启动时现算的，文件本身没存 Tier。
- 地区列表：平台库用了 33 种地区值，面板只有 26 个，AT/DK/ES/FI/NO/NZ/PL/SE 选不到。
- 公共源模板：Alice（免费个人最多 5 个 IP）、AKDNS（Beta 免费、非 Akile 用户最多 10 个 IP）与公开文档一致，没硬编假 IP，这点做对了；SmartDNSProxy/Getflix/Unlocator 的免费额度说法没给来源，Beta 结束时间也没写。

## 安全与隐私核查（静态）

- 代码里没有真 token（`gho_/ghp_/github_pat_` 无命中），没有真实 IP（示例全是 203.0.113.0/24），但默认 token `xhj028` 有 12 处。
- DNS/SNI 路径没搜到记 qname/SNI/客户端 IP 的日志（只有计数和探活日志），无日志这点在代码层面做到了；但面板启动日志打 token、agent 心跳失败打错误（不含查询内容）。
- 面板列表打码只在前端做，API 全返回完整 IP，见 P0-05。
- agent 配置接口会返回全部全局规则（也就是全部解锁 IP），不是只返回本台机器的，见 P0-05、P0-06。

## 可靠性

- 面板挂了：agent 还能按最后一份规则继续工作，5 秒轮询失败只打一行日志，用户不知道自己在用旧规则。
- 节点挂了：默认只标红不切换，只有明确开了自动切换且填了备用 IP 才切，设计是对的，但切过去回不来，见 P1-06。
- 上游 DNS 挂了：转发失败直接没回应，没备选上游、没 SERVFAIL。
- 并发/内存：UDP 每个包起一个 goroutine，没限流，53 端口被刷会把机器打满；SNI 转发没超时，挂住的连接会一直占着。

## 发版前必须做的事（按顺序）

1. 修 7 条 P0（先做 P0-01、P0-02、P0-03、P0-04，这四条不修，装上去就是公开的）。
2. 修 15 条 P1（先做 P1-09、P1-10、P1-01、P1-02、P1-05，这五条关系到断不断网、解不解锁）。
3. 重构建 amd64+arm64、打 tag、发 Release，本地重跑一遍安装、反代、DNS、改规则、备份还原。
4. 动态验证重跑一遍（`go vet`、`go test`、DNS 测试、登录改密、备份还原），这次审计没重跑，不能拿旧测试结果当新版的证据。
5. 用户确认后再 push / 发版。

---

*审计结论：不建议发版。先修 P0，再重验证。*
