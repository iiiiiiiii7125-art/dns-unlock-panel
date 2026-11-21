# DNS 分流解锁面板（akcdn 式）

无日志 DNS 复写系统：高效、轻量。**主用途就是三类：社交媒体、流媒体、AI 服务**——一次接入 DNS，后续分流规则全在面板里管，改完约 5 秒生效。

- **169 个平台**（比 AKDNS 的 60+ 更全），**34 个国家/地区**，按热度分级排序：Tier 1（Netflix、YouTube Premium、Disney+、ChatGPT、TikTok、Spotify、HBO Max、Claude、Gemini、Instagram、Prime Video、Hulu）在最前，Tier 2 其次，再往后是日本 / 台湾 / 香港专区和长尾。
- **解锁节点只是一条 IP 记录**：面板里随便填任意 IP 就能加一条解锁规则，不需要在那台机器上装任何东西。规则 = 平台 → IP，可从已有 IP 下拉选，也可每条规则直接手填自定义 IP。
- **面板只做 DNS 复写**：把流媒体域名解析到你填的解锁 IP。流量能不能解锁，取决于这个 IP 背后的服务器本身会不会转发该平台（SNI 代理 / 解锁服务）。**面板不会让任意 IP 凭空具备解锁能力。**
- **无日志**：DNS 与 SNI 代理路径不记录查询域名、SNI、客户端 IP，只保留聚合计数（总量 / 复写数 / 转发数 / 每平台命中数，不含客户端身份）。

---

## 任意服务器 1 分钟部署面板

面板就是**单 Go 二进制 + 本地数据文件**，任意一台 VPS 都能跑，不强制 Docker、不强制 Cloudflare。

```bash
# 一键安装（在任意 VPS 上，root）。跑起来后会问你域名：
#   域名（填了就配 Caddy 自动反代 + HTTPS；留空只跑 :8080，不配反代）:
# 填域名自动配 Caddy 反代 + HTTPS，留空只跑 8080；80/443 被占时脚本会停下，不覆盖别人的服务。
curl -fsSL https://raw.githubusercontent.com/iiiiiiiii7125-art/dns-unlock-panel/main/scripts/install-panel.sh | bash
# 不想等询问，也可以直接传参：bash install-panel.sh --domain dns.example.com
```

打开面板，用默认账号 **admin / admin** 登录，**首次登录后请立即改密码**（改完后旧密码立即失效、所有登录失效）。
数据存在 `/var/lib/dnsunlock/panel.json`（0600，带 `.bak` 自动备份；损坏时自动从 `.bak` 恢复）。
登录防暴力破解：连续输错 5 次锁 60 秒；锁按连接 IP 计（直连）或按 XFF 最后一个值计（单层 Caddy 反代），双层反代（如 Cloudflare → Caddy）本版不支持，见 DESIGN.md 安全设计（M-05）。

> 三套凭证是分开的，不要混用：① 面板登录（admin/admin，可改）；② 每台 DNS 机器的 agent token（面板登记服务器时生成，只显示一次，装机时输入）；③ 二进制下载（用 ① 的登录 session 或 ② 的 agent token）。**公开仓库里没有任何 token**。

> Cloudflare Tunnel 只作**可选入口**（域名 + HTTPS），不是必需品：见第 6 节。

---

## 快速上手（AKDNS 式六步）

```
1. 加 IP       面板 → 🔒 私有解锁 IP：填任意 IP（如香港服务器 IP），地区只是个标签
2. 基线解锁测试  先确认这个 IP 本身能解锁目标平台（见“解锁自测”页）
3. DNS 测速     安装 DNS 时可传 --unlock-ips "IP1,IP2"，脚本对 :443 测速取最快者
4. 设为系统 DNS  在 VPS 上执行一键安装命令（见下），可选把本机 DNS 设为 127.0.0.1
5. 选服务解锁   面板 → 分流规则：Netflix → HK、ChatGPT → US、TikTok → US……
6. 再验证       dig @127.0.0.1 -p 53 netflix.com A 应返回解锁 IP；再按“解锁自测”核对
```

### 一键装 DNS 分流服务（在目标 VPS 上执行）

```bash
curl -fsSL http://面板IP:8080/install.sh | bash
# 先在面板登记服务器（DNS 服务器 → 登记服务器），复制 agent token；
# 再按提示输入：面板地址 / agent token（不回显）/ DNS 服务器名称 / 默认解锁 IP（可空）/ allowlist（必填）
# 可选参数：--unlock-ips "203.0.113.10,203.0.113.20" 测速选最快；--allowlist "你的IP,192.168.1.0/24"
```

脚本会：装前基线测试（面板连通 + token 校验）→ 下载二进制并校验 sha256（下不到就停）→ 写 600 配置文件（token 只在文件里，不进启动命令）→ 写 systemd `dnsunlock-agent` → 装后验证（example.com 走上游、规则域名回解锁 IP）→ 可选把本机 DNS 设为 127.0.0.1。
**脚本不自动放行防火墙 53**：agent 的 allowlist 已挡住非授权客户端；如需外网访问，请在防火墙/安全组里只放行 allowlist 里的 IP。
可选：按提示把本机系统 DNS 设为 127.0.0.1（接管前完整备份 `/etc/resolv.conf`，处理 systemd-resolved / NetworkManager / netplan 冲突，还原命令 `dnsunlock-restore-dns`）。

测试：

```bash
dig @127.0.0.1 -p 53 netflix.com A    # 应返回规则里配的解锁 IP
dig @127.0.0.1 -p 53 example.com A    # 应返回真实上游 IP
```

### 可选：把自己的 VPS 变成解锁节点（SNI 代理）

面板和 DNS 分流本身**不需要**这一步。只有当你想让某台自己的 VPS 亲自做解锁出口时：

```bash
curl -fsSL http://面板IP:8080/install.sh | bash -s -- --unlock-node
```

在该机上跑 `dnsunlock sni-proxy`（:443 解析 SNI、:80 按 Host 转发），再把它的公网 IP 填进面板。

### 公共解锁源（可选）

面板 → 🌐 公共解锁源：Alice（app.alice.ws，免费个人最多 5 个 IP）、AKDNS（dns.akile.ai，Beta 免费，非 Akile 用户最多 10 个 IP）、SmartDNSProxy（14 天试用）、Getflix / Unlocator（商业，需注册付费）。

⚠️ **没有放之四海的通用公共解锁 IP**：这些服务都是“先注册、绑定自己 IP、再拿到分配的 DNS IP”。模板里只放名称、官网、免费额度、覆盖地区，**代码里不硬编任何所谓公共解锁 IP**；注册拿到 DNS IP 后填进来，规则里用 `nameserver` 模式走它。

---

## 两种解锁模式（按平台选）

| 模式 | 行为 | 适用 |
|---|---|---|
| `address`（默认） | DNS 直接返回解锁 IP，流量走 SNI 代理出口 | 自己的解锁节点 IP |
| `nameserver` | 该平台的查询转发到指定的上游 DNS IP，原样返回答案 | 公共解锁源（Alice/AKDNS 等）分配的 DNS IP |

规则里还能填**备用 IP**并勾选“探活失败自动切备用”——只有明确开了这一项，agent 才会在该 IP 连续 2 次 TCP :443 探活失败后切到备用 IP；否则失败只在面板标红，规则不动。

## 分流模型

一台解锁机可同时解多地区、一个 DNS 可按平台分不同地区，例如：Netflix → US、港台 B 站 → HK、ChatGPT → US、TikTok → SG。这正是按平台分规则的模型：每条规则独立选 IP/地区/模式。

域名库按最小化原则：每个平台只收真正做地域判定的核心域名 1–5 个，**不收** `akamaihd.net` / `cloudfront.net` / `amazonaws.com` / `1e100.net` / `googlevideo.com` / `fbcdn.net` 这类通用 CDN（否则浪费解锁机带宽还容易断）。缺的域名在面板 → 自定义域名 里自己加。

## 安全（必读）

**原理：任何能用你 DNS 的人，用 `dig` 就能看到返回的解锁 IP。** 所以：

1. **DNS 53 绝不能对全网开放递归**，否则成 DNS 放大攻击源。agent 与 SNI 代理默认拒绝：allowlist 为空且监听非 loopback 时**拒绝启动**，只听 127.0.0.1 时才放行本机测试。安装时必须填 allowlist（只放行授权的客户端 IP/CIDR）；安装脚本不主动放行防火墙 53。
2. **SNI 代理只放行授权的被解锁机 IP**：allowlist 只写进 600 配置文件（`/etc/dnsunlock/config.json` 里的 `allowlist` 项），不走命令行与环境变量（会进进程列表/环境），同理。
3. **私有节点 IP 是敏感信息**：面板列表默认打码（如 `1.2.*.*`），点“显示”才单独调接口取完整 IP；未登录的 `/install.sh` 里不含任何 token 或私有 IP；`/dl/*` 需登录 session 或 agent token；DNS agent 拉配置必须带每台机器自己的 token，配置接口只返回该台机器的规则，伪造别人的 server_id 上报心跳会被拒绝。
4. 公共源和私有节点在 UI 上分两个区显示，互不混淆。

## Cloudflare 入口（可选）

面板仍跑在 VPS 上，Cloudflare 只做入口：

```bash
PANEL_DOMAIN=panel.example.com ./scripts/cloudflare-tunnel.sh
```

创建 tunnel → ingress 到 `localhost:8080` → 域名解析到 tunnel。**必须**在 Cloudflare 加 Cache Rule：`/api/*`、`/install.sh`、`/dl/*` 全部 Bypass cache（API 本身已返回 `Cache-Control: no-store`，这是第二层保险），否则 DNS agent 的 5 秒轮询会被缓存。

纯 Workers 方案不作为 v1：Workers 跑不了 Go 常驻进程 + 本地文件存储，要重写后端为 Workers + D1/KV。见 DESIGN.md 对比。

## 和经典栈的对比

| | 经典栈（ab77/netflix-proxy 等） | 本项目 |
|---|---|---|
| DNS | dnsmasq / SmartDNS | Go 自研（UDP/TCP，TCP 兜底） |
| 解锁 | sniproxy + Docker | Go 自研 SNI 代理（可选） |
| 管理 | 静态配置 / proxy-domains.txt | Web 面板，规则 5 秒生效 |
| 部署 | Docker + 多组件 | 单二进制 + 一个数据文件 |

Go 单二进制就是替代 dnsmasq + sniproxy + Docker 的轻量版，逻辑与之一致，来源见 REFERENCES.md。

## 局限（写明）

- 无 SNI 的老设备（旧 Chromecast / PS3 / 部分电视）走不了 SNI 解锁。
- sniproxy 需占用 80/443 端口，冲突时先停 nginx/Caddy 或改监听端口。
- 面板只做 DNS 复写，不凭空让任意 IP 具备解锁能力；解锁效果取决于 IP 背后的服务。
- 本地实测未覆盖：真实流媒体解锁（需真实解锁节点 + 真实 Netflix 等账号测试，见“未验证”）。

## 故障排查

| 现象 | 排查 |
|---|---|
| `dig` 超时 | agent 是否在跑；53 是否被防火墙/其他 DNS 占用；allowlist 是否把你拦了 |
| 规则改了不生效 | 等 6 秒（5 秒轮询）；看面板配置版本是否 +1；agent 日志有无 poll 失败 |
| 域名返回真实 IP | 该平台无规则，或规则指向的节点被删/禁用；nameserver 模式看上游是否通 |
| UDP 53 不通 | agent 会自动走 TCP 53 兜底（上游与客户端两侧）；检查云厂商安全组 |
| 面板打不开 | 面板地址、admin 账号密码、云厂商 8080 端口放行；Tunnel 部署看第 6 节 |
| 系统 DNS 接管后上不了网 | `dnsunlock-restore-dns` 一键还原 `/etc/resolv.conf` |

## 构建

```bash
# 需要 Go 1.24+（go.mod: go 1.24.0，含 golang.org/x/crypto，见 go.sum）
go vet ./... && go test ./...
bash scripts/build.sh   # 双架构构建 + 生成分架构 sha256 并校验
```

构建产物（`dist/`，也是 Release 资产清单）：`dnsunlock-linux-amd64`、`dnsunlock-linux-arm64`、每架构单独的 `dnsunlock-linux-amd64.sha256` / `dnsunlock-linux-arm64.sha256`（各只含本架构一行，安装脚本只装一个架构时校验才不会报错）、合集 `dnsunlock.sha256`（仅供人工核对）。

## 默认解锁 IP 的语义

DNS 服务器登记时可填一个“默认解锁 IP”（可空）。它**只在某条规则存在、但该规则的地区里没有可用节点时**作备用；**没有规则的平台不用它**，仍走上游解析。不要把它理解成“没规则也走这个 IP”。


默认登录 admin / admin（首次登录必须改密码）。面板默认 `:8080`，DNS 默认 `:53`。
