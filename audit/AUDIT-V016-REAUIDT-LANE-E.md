# v0.1.6 复审 E 线报告（对抗评审线）

- **复审对象**：`~/workspace/dns-unlock-panel-v016`，分支 `feature/v0.1.6-takeover`，修复区间 `374e7b7..7b86d49`（tip `7b86d49`），基底 v0.1.5（`817c606`）
- **复审方式**：只读复审，只审修复 diff，不重审未动的代码。不改代码，未 push/tag/发版，未碰生产面板，未碰测试机宿主机状态（测试机未登录；本线证据全部来自 worktree 内代码、已归档日志与沙箱只读检查）。
- **本线结论：FAIL（不可发版）**——修复本身引入 1 个 P2（E-R1，V016-01 修复的残留口子，须在本轮修掉重验）+ S6 立项 P2（不单独挡发版，但建议本轮顺手修）+ 6 个 P3。原审计的 P1/P2 修复经对抗复核大体成立，见第 5 节“复核通过项”。

## 1. 新问题清单（只审 diff 挖出的）

### E-R1（P2）：永久还原不清理临时状态，残留的开机 unit 会在下次重启时把已还原的 DNS 改回去

- **位置**：`scripts/restore-resolv.sh` 的 CHOSEN 分支与 legacy 分支（另见内嵌于两份 `install.sh` 的同一份还原脚本，三份已由 `check-restore-sync.sh` 验证一致，口子三份同在）。
- **证据**：
  - 全文件 grep：`restore-resolv.sh` 内 `temp-state` 只出现在两处——`cleanup_temp_state()`（约 813–880 行）与无永久备份分支（约 984 行）。CHOSEN 分支（`restore_from_dir` → `verify` → `restore_agent_after` → `exit 0`）与 legacy 分支全程不碰临时状态、不删开机 unit。
  - 对照：`install.sh` 永久接管分支在 `do_backup "pre-takeover"` 之后立即调 `clear_temp_state`（约 1183 行），注释明确写了理由：“避免开机 unit 把刚接管的 DNS 还原回去”。还原路径存在**完全相同的 hazard**（“避免开机 unit 把刚还原的 DNS 还原回去”），却没有等价调用——同一轮修复里一处修了、一处漏了。
  - `restore-resolv.sh` 里根本不存在 `clear_temp_state` 这个函数（只有 `cleanup_temp_state`，见下条“修法注意”）。
- **复现序列（代码级可推导，未在真机跑——需修复方容器重验）**：
  1. 永久接管（resolv.conf → `nameserver 127.0.0.1`，agent 已 `enable`）。
  2. 跑一次 `--temp` 且走到 direct-write 模式（resolved 未跑、或 `resolvectl` 失败）：`write_temp_resolv_conf` 把当时的 resolv.conf（即接管态 `nameserver 127.0.0.1`）存入 `temp-state/resolv.conf.orig`，并装开机 unit `dnsunlock-temp-restore.service`。
  3. 跑 `dnsunlock-restore-dns`：resolv.conf 恢复原状，agent 按规则停掉；但 `temp-state/` 与开机 unit 原样残留。
  4. 重启：开机 unit 跑 `--temp-cleanup` → direct-write 分支把 resolv.conf 从 `temp-state/resolv.conf.orig` 恢复为 `nameserver 127.0.0.1`。
  - 后果分两支：永久 agent 若监听通配符 `:53` 且还原已把 resolved stub 请回 127.0.0.53，则 agent 开机自启绑不上 `:53`（`Restart=always` 空转），系统 DNS 指向无人监听的 127.0.0.1:53——**系统 DNS 死**；若永久 agent 监听 127.0.0.1:53，则绑得上，**分流在还原后静默复活**。uninstall 路径同理：uninstall 调 `restore --yes` 后删 agent，残留 unit 在下次重启把 resolv.conf 改回 127.0.0.1，而 agent 已删——系统 DNS 死。
- **定级理由（P2 不是 P1）**：后果最坏一支是 P1 级的（系统 DNS 死），但触发要走“永久接管 → direct-write 临时 → 还原 → 重启”四步，且 direct-write 只在 resolved 缺席/失败时才走，不是常规 resolved 机器的默认路径。V016-01 本体是默认路径 P1；这是它修复的残留口子，评 P2、本轮必修。
- **修法注意**：还原成功路径上要调的是 `clear_temp_state` 的等价物（删 `temp-state/` + `disable` 并删开机 unit + `daemon-reload`），**绝不能调 `cleanup_temp_state`**——后者会按记录把 resolv.conf 恢复成临时原状（即接管态 127.0.0.1），等于亲手撤销还原。`restore-resolv.sh` 需新增该函数（或内联三行），位置在 `restore_from_dir`/`restore_legacy` 成功之后、中止路径不调（中止时 DNS 未改，临时状态仍有效）。
- **同根 benign 变体**：resolvectl 模式的临时状态在重启后同样残留（无开机 unit、无 DNS 效应）——即容器轮登记的“01a lazy residue”，已由 `green-01a-part2.log:59` 原文佐证（“temp-state after reboot: state (resolvectl path writes a record but no boot unit; DNS effect is gone)”）。无害，但与本项同根；修 E-R1 时顺手让 `clear_temp_state` 也覆盖它（永久接管/还原成功时都清）。
- **重验要求**：容器里跑完整序列（永久接管 → `--temp` direct-write → 还原 → 重启），断言重启后 `temp-state/` 不存在、开机 unit 不存在、resolv.conf 保持还原态、系统 DNS 正常。现有 green-01a 台架只验了“临时→重启”，未覆盖“临时→还原→重启”，须补这一段。

### E-R2（P3）：`copyServerInstall` 未做 V016-21 同款 reveal 失败处理（漏网的兄弟路径）

- **位置**：`web/index.html:772-777`（与 `internal/panel/assets/index.html` 同步一致）。本轮 diff 对该函数 **0 行改动**（`git diff` 里无 `^[+-].*copyServerInstall`）。
- **证据**：函数体是 `await api('/api/v1/servers/'+id+'/reveal')` 后直接写剪贴板、无 `try/catch`；而 `api()` 在 401 时抛错并清会话、弹登录框（`web/index.html:227` 起）。reveal 一旦失败（会话过期、强制改密后 401——浏览器复核轮已记录同类 401），该 promise 静默 reject：什么都没复制、没有任何提示，用户只看到登录框突然出现。V016-21 给节点复制路径（`copyNodeInstall`）补的正是这一课（失败如实报错、全失败不复制），服务器复制路径是同一失效模式的漏网兄弟。
- **与 C7br/C7cr 的关系**：**不是一回事**。C7br/C7cr 已由同目录 `AUDIT-V016-REAUIDT-C7-ADJUDICATION.md` 裁决为脚本误判（detail 三子条件全过但 pass=false、剪贴板实物各含恰好一个正确 token），本线同意该裁决、不重复立项。**本线已直接复核原始文件**（`audit/evidence-v016-fix/browser/results-retest.json`）：`C7br | pass = False | detail = 'clip has rev1 token=true name=true has rev2 token=false'`；`C7cr | pass = False | detail = 'clip has rev2 token=true name=true has rev1 token=false'`——三子条件全部满足而 pass 仍为 false，确系脚本 pass 计算 bug，产品行为正确。E-R2 是代码追踪发现的另一条失效路径（reveal 失败时），与 C7 的“复制成功但脚本判错”无关。
- **修法**：与 `copyNodeInstall` 对齐：`try/catch` 包住 reveal，失败时 alert 如实报错、不复制；`j.token` 为空时同样不复制。

### E-R3（P3）：`cleanup_temp_state` 恒返回 0 且照常打印“清理完成”，revert 失败时 fail-open 呈报

- **位置**：`scripts/restore-resolv.sh` 约 813–890 行（`cleanup_temp_state`）。
- **证据**：resolvectl 分支 `revert` 失败只打一条警告，随后照常走“停 agent → `rm -rf temp-state` → 删 unit → 打印‘临时模式清理完成’→ `return 0`”。失败后状态记录已被删，下次重跑只会说“没有临时状态记录，无需清理”——失败态不可再现、不可重试，而用户得到的是“清理完成”。另：停 agent 发生在 revert **之后**且失败后无重试；若 revert 失败只是时序问题，本函数不会再试一次。
- **定级理由**：revert 失败的常见原因（网卡记录已不存在、resolved 未跑）本就窄，且警告文本给了手动补救办法（先停 agent 再 restart resolved），所以只评 P3。修法：交互路径上 revert 失败时返回非零并**保留**状态文件（开机 unit 调用时可继续返回 0 但须把警告写进日志）；或至少失败时不打印“清理完成”。

### E-R4（P3）：`write_temp_state` 与开机 unit 的写顺序存在 kill 窗口

- **位置**：`scripts/install.sh` 的 `apply_temp_dns` direct-write 路径。
- **证据**：顺序是 `write_temp_resolv_conf`（写 `resolv.conf.orig`/`.link`）→ `install_temp_boot_unit` → `write_temp_state`（写 `state` 文件）。三步之间无用户交互，但进程若在此时被杀（信号、OOM、断电演练外的强杀），开机 unit 已存在（或 orig 已写）而 `state` 文件不存在；开机 `--temp-cleanup` 只认 `state` 文件，缺失即打印“没有临时状态记录，无需清理”返回 0，direct-write 的临时 DNS 失去自动恢复。`install_temp_boot_unit` 的注释只承认了“安装中途被杀时 unit 可能指向旧版/缺失的 restore 脚本”这半个窗口，未提 `state` 文件本身的窗口。
- **修法**：先写 `state` 文件再装开机 unit（或把写 `state` 合进 `write_temp_resolv_conf` 内、orig 写完即写 state）。

### E-R5（P3，稳健性）：`verify_rule_domain` 的 grep 兜底注释的不变量是假的（已尝试证伪 live bug，未成立）

- **位置**：`scripts/install.sh` 的 `verify_rule_domain` grep 兜底分支；注释称“每条规则恰好一个 domains 数组与一个 node_ip 字段，文档顺序一一对应”。
- **证据**：该不变量不成立——`model.NodeCandidate` 同样有 `json:"node_ip"`（`internal/model/model.go:253`），一个带 N 个候选节点的 region 规则在文件里贡献 N+1 个 `node_ip`。本线用样本配置实测了 `paste` 配对：首条规则配对正确，错位只会在首条规则 `node_ip` 为空时向后传导。
- **但 live bug 不成立（对抗自查）**：`awk` 取第一个非空配对，而第一个配对恒为首条规则自己的 `node_ip`；首条规则 `node_ip` 为空 ⟺ `resolveIP` 失败 ⟺ 该 region 无启用节点 ⟺ `regionCandidates` 同样为空（两者都按 `Enabled` 过滤），所以错位配对永远走不到；nameserver 规则无 candidates，同样安全。python3/jq 两条主路径是严格 JSON 解析，不受影响。
- **结论**：真实面板输出上无 live 错配，评 P3 稳健性项：删掉 grep 兜底、改走“无 python3/jq 则跳过（return 2）”，或把兜底改成按规则切分的解析，别留一个靠面板内部不变量才成立的配对。

### E-R6（P3，卫生）：`run_dnsunlock_check` 的 mktemp 文件泄漏

- **位置**：`scripts/install.sh`，`BASELINE_CHECK_FILE`/`AFTER_CHECK_FILE` 及 `run_dnsunlock_check` 写出的 `"$outfile.err"`。
- **证据**：三个文件由 `mktemp` 创建后全程无人 `rm`；每次安装留 2–3 个小文件在 `/tmp`。另：基线文件在 `[4/6]` 之后即创建，安装中途 abort 同样残留。修法：安装末尾 `trap` 清理（已有 `trap 'rm -f ...' EXIT` 的先例，约 945 行处）。

### E-R7（P3）：节点安装命令注释头显示的是掩码 IP，行绑定标识打了折扣

- **位置**：`web/index.html` 的 `copyNodeInstall`（V016-21 改动内）。
- **证据**：注释头 `tag` 用 `node.name + '（' + node.ip + '，' + node.region + '）'` 拼成，但 `NODES` 列表接口只给掩码 IP（代码原注释：“列表接口只给打码 IP”）。所以头显示如 `203.0.*.*`，V016-21 想达到的“每行按钮生成自己那台节点的命令”在标识层只落实了一半（名 + 地区仍有效，IP 无效）。与浏览器复核轮的同名 P3 候选一致。修法：点按钮时对该节点调一次 reveal 取完整 IP 拼头，或头里去掉 IP 只留名 + 地区。

### E-R8（P3，观察）：`stop_agent_no_unit` 有两处“失败当成功”的角落

- **位置**：`scripts/restore-resolv.sh` 的 `stop_agent_no_unit`。
- **证据**：
  - 首行 `kill -TERM "$pid" 2>/dev/null || return 0`：`kill` 因 ESRCH 失败（进程已死）时返回 0 是对的；但因 EPERM 失败（pid 属主不是当前用户）时同样返回 0，agent 明明还在跑。
  - 轮询里 `agent_pid_on_listen … || return 0`：若本机有 `ss` 但无 `pgrep`，且 ss 的 users 字段为空（看不出归属），`agent_pid_on_listen` 返回 1，函数即判定“已停”，而 pid 实际可能还活着（仅当 agent 忽略 TERM 时才走到这一步，随后 KILL 循环同理）。
- **定级理由**：还原正常以 root 跑，EPERM 与“有 ss 无 pgrep”都窄；且 KILL 后 `_pid_gone` 仍会兜底。只记为观察，不要求本轮修（顺手修可把首行改成只在 ESRCH 时返回 0）。

## 2. S6 :8080 观察裁决

### 事实

- `probe_panel`（v0.1.3 语义，plan3 继承，本轮未改判定条件）把**任何非 000 的 HTTP 响应都算“面板可达”**。`whoami` 不带 token 时真面板回 401 + JSON `{"error":"unauthorized: agent token required"}`（`internal/panel/panel.go:216-232`）；别家 lane 遗留的 python3 HTTP 服务回 404 + HTML，同样算可达。
- R1 的 S6：当时 :8080 上有别的 lane 遗留的 python 服务，`probe_panel` 选中了它。
- **本轮的新变化（V016-04）让旧语义更危险**：以前是顺序 fallback——只有 443 不通才试 :8080；现在是并行测速取最快——本机冒名者（~1ms）几乎每次都会赢过经 Caddy 的真面板。判定条件没变，但触发概率从“443 故障时”放大到“每次安装”。
- 选错的后果不止“连不上”：选中之后安装脚本用 `-K` 带 agent token 调 `whoami`（约 949 行）并拉取 agent 配置——token 会发给冒名者。威胁模型上限很明确：冒名者必须已监听在**面板机自己的 :8080** 上，即面板机本身已被误配/入侵或台架残留服务；在真实部署里 :8080 本来就是面板，冒名者不存在。

### 裁决

- **立项加固：是，定 P2（E-R9）**。理由：判定条件可以且应当校验形态——`whoami` 的合法响应只有两种：401 + JSON 含 `agent token`，或 200 + JSON 含 `server_id`。改动约 10 行（`curl` 取 body 后校验），无行为回归面。
- **挡不挡发版：不单独挡**。理由：利用前提是面板机 :8080 上已有 rogue 监听，这在真实部署里不是攻击面而是机器已被占的前提；且 S6 本就不在 R1 审计清单内、无计划承诺。
- **但建议本轮顺手修，不留到下版本**：V016-04 是本轮引入的放大器，修判定条件与修测速是同一处代码；若本轮关闭时仍未修，须把“:8080 冒名者可赢得测速、token 会发给它”写进发版说明的已知限制，并把“台架不得残留 :8080 服务”记为台架纪律。

## 3. 审计预测修正的措辞（“系统 DNS 死”分支）

### 核对结论（与 A 线实测一致，本线复核了已归档证据）

- 软链变体（`audit/evidence-v016-fix/test-machine-container/red/red-01-part2.log:45-47,52-53`）：“重启后 resolv.conf 内容已无 127.0.0.53（stub 文件改列上游）”“重启后系统 DNS 靠上游仍可用（DNS 死分支未复现）”；原文：“审计的‘系统 DNS 死’分支在本容器（Debian 12 + 软链 resolv.conf）未复现——stub 关掉后 stub 文件改列上游，系统 DNS 靠上游活着；分流以 agent 常驻 :53 的形式变永久。”
- 静态变体（`red-01-static-part2.log:19-25`）：重启后 drop-in 还在、agent 自启、stub 仍关、resolv.conf 仍是静态 127.0.0.53、分流变永久、系统 DNS 经 agent 仍可用。
- 修复对照（`green/green-01a-part2.log:51-58`）：重启后无 drop-in、agent 未自启/未在跑、stub 在监听、resolv.conf 仍指 stub、系统 DNS 正常、分流已失效。
- 本线复核无分歧：两变体里“系统 DNS 死”均未按字面复现；真正后果在两变体里一致。

### 复审报告应采用的准确措辞

> 临时模式的重启后后果，在 Debian 12 + 软链 resolv.conf 的实测容器中**未按“系统 DNS 失效”的字面含义复现**：stub 关闭后，`stub-resolv.conf` 改列上游 DNS，系统 DNS 经上游仍可用；静态 resolv.conf 变体中，系统 DNS 经 agent 仍可用。实测的真正后果是两项：(1) **分流静默变永久**（agent 常驻 :53，重启后仍劫持规则域名）；(2) **stub 永久关闭**（drop-in 残留，resolved 的 stub 不再监听）。“重启后系统 DNS 失效”仅在静态 resolv.conf 且 agent 未能提供解析时才成立，不是本轮实测的默认分支。**严重性不变（仍为 P1）**：静默永久分流 + stub 永久关闭仍违背“重启后失效”的明确承诺，且用户无法从表面察觉；修正的只是失效机理的描述，不是定级。

## 4. 范围外改动检查

- **产品代码：无清单外顺手改动。** 逐文件核对：`.gitignore`（V016-07）、`cmd/dnsunlock/main.go`（V016-18）、`internal/dnsagent/agent.go`（V016-11/16/17/25/26/28/34）、`internal/dnsagent/check.go`（V016-16/31）、`check_test.go`/`selftest_test.go`/`udp_stub_test.go`/`agent_config_test.go`（对应项测试）、`web/index.html` 与 `internal/panel/assets/index.html`（V016-03/17/19/20/21）、`scripts/install.sh` 与 `internal/panel/assets/install.sh`（V016-01/02/04/05/06/08/09/10/22/23/24/32/34）、`internal/panel/panel.go`（V016-16）、`scripts/restore-resolv.sh`（V016-01/02/08/09/10/22/23/24）、`scripts/rig/nspawn-v016-verify.sh`（V016-12 准备）、`scripts/rig/rig-inner.sh` 与 `scripts/test-takeover-rig.sh`（V016-13/14/15）、`scripts/uninstall.sh`（V016-10/33）——全部映射到 ledger 项，无未列出的功能改动。
- **区间内非修复内容（说明，非问题）**：`374e7b7..7b86d49` 同时含审计报告提交（`audit/AUDIT-REPORT-V016.md`、`AUDIT-V016-LANE-*.md`、`findings-ledger-v016.csv` 的新增）与修复证据归档（`audit/evidence-v016-fix/`），属审计流程产物，不计为修复改动。
- **未修复的已登记项（仍 open，本轮未动，须继续登记）**：V016-27（`--dns-listen` 非 53 端口时接管仍写 `nameserver 127.0.0.1`）——容器轮重提的同项（127.0.0.1:5353 仍可接管、自测失败）在本轮 diff 里无任何改动，仍为 registered-only；V016-29/35/36/37 同样未动（其中 V016-36 install/restore 无锁与 E-R1 同属“还原窗口”家族，但本轮未修，仍登记）。
- **工作区卫生（非 diff 内容，仅记录）**：worktree 根下有未入库目录 `dist-green/`、`dist-red/`（构建产物，未提交，不在 diff 内）；建议修复方清理或入 `.gitignore`。
- **两个待用户裁决的产品决定（修复方已单边选了实现，须用户确认）**：V016-10 未给 `--force` 逃生口（修复选了 fail-closed 无 `--force`）；V016-24 选了“警告”（`_enabled_boot_warn`）而非“直接 disable”。本线不替用户裁决，只记录：若用户要 `--force` 或要 disable，两处都要返工。

## 5. 对抗复核通过项（抽查证据，证明不是只挑刺）

- **V016-16 面板/agent 协同**：`panel.go` 里 `ip, nid, ok := resolveIP(...)` 在循环内用 `:=` 新声明，`resolveIP` 失败返回 `("", "", false)`——无跨平台 stale IP；agent `rebuildDomainsLocked` 与 `check.go` 对空 `NodeIP`/空 `Nameserver` 的跳过/FAIL 分支一致。
- **V016-11 pktinfo**：新 `newUDPPktinfo` 按套接字能力先试 IPv6 再试 IPv4；`trySet` 每次重置 `setErr` 并先查 `Control` 错误（V016-26 的闭合 socket 误判已堵）；双失败记日志，无静默回退。
- **V016-02 还原检查**：停前按冲突检查、停后复查、中止恢复 agent、待办标记防谎报，均与 V016-02 修复方向一致；`ss` 无 users 字段时的误判只发生在非 root 运行，而还原本就需要 root——可接受。
- **V016-34/28 Go 改动**：`maybeStartSelftest` 加锁/解锁路径全覆盖（nil 请求也解锁）；`sendHeartbeat` 失败恢复时在锁内判 `selftestResult == nil`，新结果优先，旧结果不丢。并行自测：`resolveForSelftest`/`probeIP` 只用 per-call 状态 + `lookup`（`mu.RLock → overrideMu`）；全仓无反向加锁顺序（`refreshFastest` 先放 `overrideMu` 再取 `mu`；健康循环取 `overrideMu` 时不持 `mu`）；`go test -race ./internal/dnsagent/` 沙箱实测 `ok 19.8s`——但该次执行审批超时未答复，按 R1 惯例只记“已观察到通过”，不作正式采信。
- **V016-05 接线**：基线在 agent 启动后、接管前跑 `--via upstream`，复测在接管/临时分支内跑 `--via agent`，失败 `|| true` 不致命；对比 awk 的字段取法与 `CheckResult.Line()` 的 5 字段布局一致，`NO_RULES` 有守卫。
- **V016-04 测速**：`pick_fastest_ip` 并行后 stdout 末行仍是选中 IP（调用方 `tail -1` 契约未变）；`probe_panel` 全不通返回 1、`mktemp` 失败时 fail-closed（无结果文件即判全不通）。S6 除外，见第 2 节。
- **V016-10/24**：两还原出口（CHOSEN/legacy）均在 `restore_agent_after` 之后按 `VERIFY_RC` 退出 1；`_enabled_boot_warn` 消费了 `AGENT_WAS_ENABLED`。
- **V016-03 UI**：`prefer_fastest` 接线于 `rowHTML`、`renderEditor`、`backendDone`、`ruleForm`、`stageEditor`、导出/导入全链路；未发现会把它重置的另一条规则构造路径。
- **同步与语法**：`scripts/check-restore-sync.sh` 通过（两份 install.sh 内嵌还原 == `scripts/restore-resolv.sh`，两份 install.sh 相同；两份 index.html 相同）；6 个脚本 `bash -n` 全过；两份 index.html 内联 JS `node --check` 全过；`go vet ./...` EXIT 0；`.pyc` 已从 git 索引删除、`.gitignore` 已加 `__pycache__/` 与 `*.pyc`。
- **S9b 台架断言**：`run_restore` 会写 `RUN_RC`，`s9b_restore_rc_ok`（rc=0，或 rc=1 且日志含“验证未通过”）语义成立。
- **nspawn 脚本**：纯准备脚本，自带 `NSPAWN_VERIFY_APPROVED=1` 审批门，未执行，与头注释及 `65314d8` 的说明一致。
- **Restart=always**：agent unit 模板两处（`install.sh:998,1056`）本轮未动；显式 `systemctl stop` 不触发 restart，故不撤销还原/临时停止路径；残留风险仍是已登记的 V016-36 窗口，无新动作。
- **allowlist 默认拒绝与 token**：`QuietAllowlistWarning` 只在 `runCheck` 置位，agent/sni 入口永不置位，fail-closed 启动检查未动；token/密码处理无 diff（`probe_panel` 本身不发 token，token 只在选中入口后发往该入口——见 S6 节）。

## 6. 本线 verdict

**FAIL。** 修复轮把 R1 清单基本修完了，但 E-R1 是 V016-01 修复自身的残留口子：永久还原不清理临时状态，残留开机 unit 可在还原后的首次重启把 DNS 改回接管态，最坏一支复现“系统 DNS 死”。修法是一行级（还原成功路径上清临时状态 + 删 unit，须新增 `clear_temp_state` 等价物、不可复用 `cleanup_temp_state`），重验是已有容器台架可覆盖的序列（永久接管 → `--temp` direct-write → 还原 → 重启）。E-R1 修完重验通过、S6（P2，不单独挡发版，建议同轮修）落定、P3 项或同轮顺手修或登记下版本后，方可发版。
