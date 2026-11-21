#!/usr/bin/env bash
# dnsunlock 一键安装脚本 — 由面板 /install.sh 下发。
# 本脚本不含任何密钥：面板地址已 baked。
# 流程（先在面板登记服务器：DNS 服务器 -> 登记服务器，面板会直接给出
# 填好的一键安装命令，复制到目标 VPS 执行）：
#   curl -fsSL <面板地址>/install.sh | bash                  # 安装 DNS 分流服务（装时按提示输入 token 等）
#   curl -fsSL <面板地址>/install.sh | DNS_AGENT_TOKEN=<token> DNS_SERVER_NAME='名' DNS_DEFAULT_IP=<ip> DNS_ALLOWLIST='<allow>' bash
#                                                            # 面板自动生成的命令：值都带好了，不再逐项问
#   curl -fsSL <面板地址>/install.sh | bash -s -- --unlock-node  # 可选: 把本机变成 SNI 解锁节点
#   bash install.sh --dns-listen 127.0.0.1:5353   # 改 DNS 监听地址（默认 :53）
# 环境变量：DNS_LISTEN（同 --dns-listen，命令行优先）、DNS_DISABLE_STUB=y
#   （systemd-resolved 的 stub 占着 :53 时，自动问是否关掉 stub 监听；设
#   DNS_DISABLE_STUB=y 则不问直接关。只关 stub 监听，不改 /etc/resolv.conf。）
# 注意：用环境变量带 token 时，token 会进目标机器的 shell 历史；介意的话
# 就不带变量，装时按提示输入（不回显）。token 只写进 600 配置文件，不进
# 启动命令 / 日志；泄露了就去面板删了这台服务器重新登记，token 会换新的。
# v0.1.3：安装时先探面板：443 不通自动改走同主机 :8080（每步最多 8 秒，
# 不会像原来那样卡 134 秒）；agent 运行时也一样逐个试，规则照常同步。
# v0.1.6：结构化备份（/var/lib/dnsunlock/backup/<时间戳>_<标签>/ + metadata.txt）、
# NM 改 dns=none、use-vc 按 UDP/TCP 探测写、hpve-init 痕迹提示、验证不致命（见 [4/6] 与接管后验证）。
set -euo pipefail

PANEL_URL="__PANEL_URL__"
TOKEN=""
MODE="dns"
TEMP_MODE=0
SERVER_ID=""
SERVER_NAME=""
DEFAULT_IP=""
UNLOCK_IPS=""
ALLOWLIST=""
SNI_ALLOW=""

# 面板自动生成的安装命令用环境变量带值（值都填好了就不再逐项问）：
# DNS_AGENT_TOKEN / DNS_SERVER_NAME / DNS_DEFAULT_IP / DNS_ALLOWLIST /
# DNS_SNI_ALLOWLIST（--unlock-node 模式）。没带变量时照旧交互提问。
TOKEN="${TOKEN:-${DNS_AGENT_TOKEN:-}}"
SERVER_NAME="${SERVER_NAME:-${DNS_SERVER_NAME:-}}"
DEFAULT_IP="${DEFAULT_IP:-${DNS_DEFAULT_IP:-}}"
ALLOWLIST="${ALLOWLIST:-${DNS_ALLOWLIST:-}}"
SNI_ALLOW="${SNI_ALLOW:-${DNS_SNI_ALLOWLIST:-}}"

# 交互提问：curl | bash 时 stdin 是脚本本身，提问必须从 /dev/tty 读，
# 否则 read 会把脚本内容当成答案（token 问答失效、401 就是这么来的）。
# 用法：ask 变量名 "提示" [silent]；没终端时回落到 stdin（脚本已下载到
# 文件时 stdin 就是终端；curl | bash 且无终端时读不到，会在下面明确报错）。
# read 读到 EOF 返回非零；set -e 下会直接静默退出（连 [1/6] 之后发生了什么
# 都看不到）。这里明确报错退出：无终端 + stdin 关闭时，办法是下载脚本后运行，
# 或用环境变量/面板生成的命令带齐所需的值。
no_input() { echo "错误：无法读取输入（stdin 已关闭且无可用终端）。请用面板生成的安装命令（自带 DNS_AGENT_TOKEN），或先把脚本下载下来再执行。" >&2; exit 1; }
ask() {
  local _var="$1" _prompt="$2" _silent="${3:-}"
  if { : < /dev/tty; } 2>/dev/null; then
    printf '%s' "$_prompt" > /dev/tty
    if [ "$_silent" = silent ]; then read -rs "$_var" < /dev/tty || no_input; echo > /dev/tty
    else read -r "$_var" < /dev/tty || no_input; fi
  else
    if [ "$_silent" = silent ]; then read -rsp "$_prompt" "$_var" || no_input; echo
    else read -rp "$_prompt" "$_var" || no_input; fi
  fi
}
has_tty() { { : < /dev/tty; } 2>/dev/null; }
# 计时不用 date +%s%N（Alpine/busybox 上不可靠，见审计 P3-06）：有 python3 就用它计时，
# 没有就只按通/不通排序，不编造毫秒数。
# v0.1.6 V016-04：并行测全部候选 IP（每个 /dev/tcp :443 探测放后台跑，
# 各 3 秒超时），按延迟排序，选最快且可达的；只影响选默认解锁 IP，
# 不改变 agent 的规则/分流行为。stdout 末行仍是选中的 IP（调用方取 tail -1）。
pick_fastest_ip() {
  local best="" ip
  IFS=',' read -ra IPS <<< "$1"
  local tmpdir idx _st _ms _ip
  tmpdir="$(mktemp -d /tmp/dnsunlock-speed.XXXXXX)"
  for idx in "${!IPS[@]}"; do
    ip="$(echo "${IPS[$idx]}" | tr -d ' ')"
    [ -z "$ip" ] && continue
    (
      _start="$(python3 -c 'import time;print(time.time())' 2>/dev/null || echo "")"
      if timeout 3 bash -c "echo > /dev/tcp/$ip/443" 2>/dev/null; then _st="ok"; else _st="fail"; fi
      _end="$(python3 -c 'import time;print(time.time())' 2>/dev/null || echo "")"
      if [ -n "$_start" ] && [ -n "$_end" ]; then
        _ms="$(awk -v a="$_start" -v b="$_end" 'BEGIN{printf "%.0f", (b-a)*1000}')"
      else
        _ms="-1"
      fi
      printf '%s %s %s\n' "$_st" "$_ms" "$ip" > "$tmpdir/$idx"
    ) &
  done
  wait || true
  local timed=() untimed=() failed=()
  for idx in "${!IPS[@]}"; do
    [ -f "$tmpdir/$idx" ] || continue
    read -r _st _ms _ip < "$tmpdir/$idx"
    if [ "$_st" = "ok" ] && [ "$_ms" != "-1" ]; then timed+=("$_ms"$'\t'"$_ip");
    elif [ "$_st" = "ok" ]; then untimed+=("$_ip");
    else failed+=("$_ip"); fi
  done
  rm -rf "$tmpdir"
  if [ "${#timed[@]}" -gt 0 ]; then
    while IFS=$'\t' read -r _ms _ip; do
      echo "  测速 $_ip :443 -> 通（${_ms} ms）"
      [ -z "$best" ] && best="$_ip"
    done < <(printf '%s\n' "${timed[@]}" | sort -n)
  fi
  for _ip in "${untimed[@]}"; do
    echo "  测速 $_ip :443 -> 通"
    [ -z "$best" ] && best="$_ip"
  done
  for _ip in "${failed[@]}"; do
    echo "  测速 $_ip :443 -> 不通"
  done
  echo "$best"
}

valid_ip_cidr() {
  # 真校验（N-04）：IPv4 逐段 0-255、前缀 0-32；IPv6 用 python3 的 ipaddress
  # 真校验（没有 python3 时拒绝 IPv6，请装 python3 或填 IPv4）。
  # 旧实现只是 *.*.*.* 花纹匹配，999.999.1.1 都能过，IPv6 反被拒。
  local v="$1" ip pre a b c d rest o
  v="$(echo "$v" | tr -d ' ')"
  [ -n "$v" ] || return 1
  case "$v" in
    *:*)
      case "$v" in
        */*) pre="${v##*/}"; case "$pre" in ''|*[!0-9]*) return 1;; esac; [ "$pre" -le 128 ] 2>/dev/null || return 1;;
      esac
      if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import ipaddress,sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$v" 2>/dev/null
        return $?
      fi
      echo "提示: 校验 IPv6 需要 python3，未检测到，已拒绝 $v（请装 python3 或填 IPv4）" >&2
      return 1
      ;;
  esac
  case "$v" in
    */*) pre="${v##*/}"; case "$pre" in ''|*[!0-9]*) return 1;; esac; [ "$pre" -le 32 ] 2>/dev/null || return 1; ip="${v%/*}";;
    *) ip="$v";;
  esac
  case "$ip" in *[!0-9.]*) return 1;; esac
  IFS='.' read -r a b c d rest <<< "$ip"
  [ -n "${rest:-}" ] && return 1
  for o in "$a" "$b" "$c" "$d"; do
    case "$o" in ''|*[!0-9]*) return 1;; esac
    [ "$o" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --panel) PANEL_URL="$2"; shift 2;;
    # N-12: 没有 --token 参数（写进命令行会进 shell 历史和进程列表）。
    # token 只在安装时交互输入（不回显），或由面板生成的安装命令经
    # DNS_AGENT_TOKEN 环境变量带入；两种方式最后都只写进 600 配置文件。
    --server-id) SERVER_ID="$2"; shift 2;;
    --name) SERVER_NAME="$2"; shift 2;;
    --default-ip) DEFAULT_IP="$2"; shift 2;;
    --unlock-node) MODE="unlock"; shift;;
    --temp) TEMP_MODE=1; shift;;
    --unlock-ips) UNLOCK_IPS="$2"; shift 2;;
    --allowlist) ALLOWLIST="$2"; shift 2;;
    # P1-REAL-01：监听地址终于有了真实入口（命令行优先于 DNS_LISTEN 环境变量）。
    --dns-listen) DNS_LISTEN="$2"; shift 2;;
    --help|-h)
      echo "用法: bash install.sh [--panel URL] [--dns-listen ADDR] [--allowlist IPS] [--unlock-node] [--temp]"
      echo "  --panel URL         面板地址（默认已 baked；443 不通时自动改走同主机 :8080，也可直接指定内网地址）"
      echo "  --dns-listen ADDR   DNS 监听地址，默认 :53；如 127.0.0.1:5353（也可设 DNS_LISTEN 环境变量）"
      echo "  --allowlist IPS     允许使用本 DNS 的客户端 IP/CIDR，逗号分隔（必填）"
      echo "  --unlock-node       只装 SNI 解锁节点，不装 DNS 分流服务"
      echo "  --temp              临时模式：只把本次运行的 DNS 指到 agent，不做永久接管（重启后失效，不写永久备份、不加 chattr 锁、不停任何管理器）"
      echo "  环境变量（面板生成的安装命令自带，没带就交互提问）：DNS_AGENT_TOKEN DNS_SERVER_NAME DNS_DEFAULT_IP DNS_ALLOWLIST DNS_SNI_ALLOWLIST"
      exit 0;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

# P1-REAL-01：DNS 监听地址。默认 :53；systemd-resolved 的机器见下面的端口检查。
DNS_LISTEN="${DNS_LISTEN:-:53}"
case "$DNS_LISTEN" in
  *:*)
    _dl_port="${DNS_LISTEN##*:}"
    case "$_dl_port" in ''|*[!0-9]*) echo "DNS 监听地址格式不对: $DNS_LISTEN（端口要是 1-65535 的数字，如 :53 或 127.0.0.1:5353）"; exit 1;; esac
    [ "$_dl_port" -ge 1 ] && [ "$_dl_port" -le 65535 ] || { echo "DNS 监听端口超出范围: $DNS_LISTEN"; exit 1; }
    ;;
  *) echo "DNS 监听地址格式不对: $DNS_LISTEN（要含冒号，如 :53 或 127.0.0.1:5353）"; exit 1;;
esac

[ "$(id -u)" = "0" ] || { echo "请用 root 运行 (sudo bash)"; exit 1; }
command -v curl >/dev/null || { echo "需要 curl，请先安装"; exit 1; }
command -v sha256sum >/dev/null || { echo "需要 sha256sum，请先安装 coreutils"; exit 1; }
# P1-REAL-01：端口检查改为“真能绑上才算数”。
# 旧写法 ss 扫到 ':53 ' 就直接退出，但 systemd-resolved 的 stub 只占
# 127.0.0.53:53 这类 loopback 地址，本来就不一定跟 agent 的监听地址冲突；
# 反过来，只看 ss 也不能证明 agent 一定绑得上。所以直接按 Go 的方式
# （UDP+TCP，均设 SO_REUSEADDR）试绑一次监听地址，试得上就放行。
# 返回 0=可绑定，1=被占，2=测不出来（没 python3 且 ss 也看不到）。
can_bind_listen() {
  local listen="$1" host port
  host="${listen%:*}"; port="${listen##*:}"
  host="${host#[}"; host="${host%]}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$host" "$port" <<'PYEOF'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
fam = socket.AF_INET6 if ':' in host else socket.AF_INET
for typ in (socket.SOCK_DGRAM, socket.SOCK_STREAM):
    s = socket.socket(fam, typ)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind((host, port))
    except OSError:
        sys.exit(1)
    finally:
        s.close()
sys.exit(0)
PYEOF
    return $?
  fi
  # 没 python3：ss 启发式——只有非 stub 监听才算冲突；只剩 stub 时测不出来。
  if command -v ss >/dev/null 2>&1; then
    local listeners
    listeners=$(ss -tuln 2>/dev/null | grep -E ":$port " | awk '{print $5}' | sort -u)
    [ -z "$listeners" ] && return 0
    echo "$listeners" | grep -qvE '^(127\.0\.0\.53|127\.0\.0\.54)(%[^:]*)?:53$' && return 1
    return 2
  fi
  return 2
}

# stub_only_conflict：:53 上只有 systemd-resolved 的 stub（127.0.0.53/127.0.0.54）
# 时返回 0，其他 DNS 占着时返回 1。
stub_only_conflict() {
  command -v ss >/dev/null 2>&1 || return 1
  local listeners
  listeners=$(ss -tuln 2>/dev/null | grep -E ':53 ' | awk '{print $5}' | sort -u)
  [ -z "$listeners" ] && return 1
  echo "$listeners" | grep -qvE '^(127\.0\.0\.53|127\.0\.0\.54)(%[^:]*)?:53$' && return 1
  return 0
}

disable_stub_listener() {
  # 先把关 stub 之前的 drop-in 状态存起来：do_backup 在关 stub 之后才跑，
  # 不存的话备份里会带着接管刚写的 drop-in，还原时又把它恢复回来（stub
  # 永远关不回去）。存到 /etc/dnsunlock/，do_backup 会收进备份并消费掉。
  mkdir -p /etc/dnsunlock
  if [ -f /etc/systemd/resolved.conf.d/dnsunlock.conf ]; then
    cp -a /etc/systemd/resolved.conf.d/dnsunlock.conf /etc/dnsunlock/resolved-dropin.orig 2>/dev/null || true
    rm -f /etc/dnsunlock/resolved-dropin.absent
  else
    : > /etc/dnsunlock/resolved-dropin.absent
    rm -f /etc/dnsunlock/resolved-dropin.orig
  fi
  mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/dnsunlock.conf
  systemctl restart systemd-resolved
}

ask_yes_no() {
  # $1=提示。能读 /dev/tty 就问，否则默认否（管道安装时不要吞脚本内容）。
  local ans=""
  if [ -r /dev/tty ]; then
    read -rp "$1 [y/N] " ans < /dev/tty || true
  fi
  case "$ans" in y|Y) return 0;; *) return 1;; esac
}

# v0.1.6 item 2：接管后用系统解析器验证（不是只 @agent 查）。
# 优先 getent hosts（走 glibc，遵守 resolv.conf 的 options use-vc），
# 缺 getent 回退不带 @server 的 dig（use-vc 时加 +tcp）。
# 返回 0=解析成功，1=解析失败，2=没工具（只警告，不 abort）。
# 注意：测速环节（pick_fastest_ip 用 /dev/tcp，probe_panel 用 curl）
# 本来就不用 dig；缺 dig 只影响这里和 [4/6] 的验证，且只警告、不致命。
verify_system_dns() {
  local domain="$1" out=""
  if command -v getent >/dev/null 2>&1; then
    if out=$(getent hosts "$domain" 2>/dev/null) && [ -n "$out" ]; then
      echo "  系统解析验证通过: $domain -> $(echo "$out" | awk '{print $1}' | head -1)（getent，走系统解析器）"
      return 0
    fi
    echo "  系统解析验证失败: getent hosts $domain 无结果" >&2
    return 1
  fi
  if command -v dig >/dev/null 2>&1; then
    if [ "${USE_VC:-0}" = "1" ]; then
      out=$(dig +tcp +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    else
      out=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    fi
    if [ -n "$out" ]; then
      echo "  系统解析验证通过: $domain -> $out（dig，不带 @server）"
      return 0
    fi
    echo "  系统解析验证失败: dig $domain 无结果" >&2
    return 1
  fi
  echo "  系统解析验证跳过: 既无 getent 也无 dig，无法验证（请手动验证：getent hosts $domain）" >&2
  return 2
}

# v0.1.6 item 2：再查一条已设规则的域名，确认返回规则 IP。
# 规则取自面板 /api/v1/agent/config 的第一条 address 模式规则（domains[0] + node_ip）；
# 无规则、取不到、或规则是 nameserver 模式（答案不改写）时跳过，只提示手动核对。
# 失败只警告，不致命（规则 IP 也可能因故障切换而变化）。
verify_rule_domain() {
  local cfg="/tmp/dnsunlock-agent-config.json" domain="" node_ip="" out=""
  curl -fsSL -K "$AUTH_CFG" --max-time 8 "$PANEL_BASE/api/v1/agent/config?server_id=$SERVER_ID" -o "$cfg" 2>/dev/null || { echo "  规则域名验证跳过: 拉不到 agent 配置（稍后手动验证规则域名）"; return 2; }
  domain=$(sed -n 's/.*"domains":\["\([^"]*\)".*/\1/p' "$cfg" | head -1)
  node_ip=$(sed -n 's/.*"node_ip":"\([^"]*\)".*/\1/p' "$cfg" | head -1)
  rm -f "$cfg"
  if [ -z "$domain" ] || [ -z "$node_ip" ]; then
    echo "  规则域名验证跳过: 当前没有 address 模式的规则（未设规则时属正常）"
    return 2
  fi
  if command -v getent >/dev/null 2>&1; then
    out=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)
  elif command -v dig >/dev/null 2>&1; then
    if [ "${USE_VC:-0}" = "1" ]; then out=$(dig +tcp +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1);
    else out=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1); fi
  else
    echo "  规则域名验证跳过: 既无 getent 也无 dig（请手动验证：getent hosts $domain，应返回规则 IP $node_ip）"
    return 2
  fi
  if [ "$out" = "$node_ip" ]; then
    echo "  规则域名验证通过: $domain -> $out（规则 IP 一致）"
    return 0
  fi
  if [ -n "$out" ]; then
    echo "  警告: 规则域名 $domain 解析到 $out，不是规则 IP $node_ip（可能是 nameserver 模式规则、故障切换、或规则未生效，请人工核对）" >&2
  else
    echo "  警告: 规则域名 $domain 系统解析无结果（规则 IP 应为 $node_ip，请人工核对）" >&2
  fi
  return 1
}

# v0.1.6 V016-05：跑一次 `dnsunlock check` 并打印结果。
# $1 = 标签（如“基线（接管前）”），$2 = --via 值（upstream/agent），$3 = 输出文件。
# check 的 exit 契约（见 cmd/dnsunlock/main.go runCheck）：0 全部通过，
# 1 有 FAIL，2 配置/用法错误。任何失败都不致命（警告 + 继续，呼应计划
# 第 2 项“验证不致命”），但失败原因要写清楚；输出文件留给接管后的对比用。
run_dnsunlock_check() {
  local label="$1" via="$2" outfile="$3" rc=0
  if [ ! -x /usr/local/bin/dnsunlock ]; then
    echo "  警告: $label：/usr/local/bin/dnsunlock 不存在，跳过 dnsunlock check（不致命，继续安装）。" >&2
    return 2
  fi
  if [ ! -f /etc/dnsunlock/config.json ]; then
    echo "  警告: $label：/etc/dnsunlock/config.json 不存在，跳过 dnsunlock check（不致命，继续安装）。" >&2
    return 2
  fi
  echo "--- $label：dnsunlock check --via $via ---"
  if /usr/local/bin/dnsunlock check --config /etc/dnsunlock/config.json --via "$via" >"$outfile" 2>"$outfile.err"; then
    rc=0
  else
    rc=$?
  fi
  if [ -s "$outfile" ]; then
    sed 's/^/  /' "$outfile"
  else
    echo "  （check 无 stdout 输出）"
  fi
  if [ -s "$outfile.err" ]; then
    echo "  check 诊断（stderr）:"
    sed 's/^/  /' "$outfile.err"
  fi
  case "$rc" in
    0) echo "  $label：全部通过（exit 0）。" ;;
    1) echo "  警告: $label：有规则未通过（exit 1，见上表 FAIL 行），不致命，继续安装。" >&2 ;;
    *) echo "  警告: $label：dnsunlock check 无法完成（exit $rc，见上），不致命，继续安装。" >&2 ;;
  esac
  return "$rc"
}

# v0.1.6 V016-05：接管前后基线对比。$1 = 基线文件，$2 = 复测文件。
# check 输出每行：平台<TAB>域名<TAB>IP<TAB>OK|FAIL<TAB>延迟 ms 或错误。
# 只负责调用结果的对比展示，不改 check 本身的输出逻辑（V016-16/18 另修）。
print_check_comparison() {
  local base="$1" after="$2"
  echo "=== 接管前后基线对比（基线 --via upstream → 复测 --via agent）==="
  echo "  期望：规则域名从上游 IP 变为规则 IP（状态 OK）；无规则的域名两次都走上游。"
  if [ ! -s "$base" ] || [ ! -s "$after" ]; then
    echo "  对比跳过：基线或复测无输出（check 未完成，见上）。"
    return 2
  fi
  if grep -qx "NO_RULES" "$base" || grep -qx "NO_RULES" "$after"; then
    echo "  未设规则（基线或复测为 NO_RULES），无可对比。"
    return 0
  fi
  awk -F'\t' '
    FNR==NR { bip[$1]=$3; bst[$1]=$4; bdom[$1]=$2; next }
    {
      if ($1 in bip) {
        chg = (bip[$1] != $3 || bst[$1] != $4) ? "变化" : "一致"
        printf "  %s %s: 基线 %s(%s) -> 复测 %s(%s) [%s]\n", $1, $2, bip[$1], bst[$1], $3, $4, chg
        seen[$1]=1
      } else {
        printf "  %s %s: 仅复测有 %s(%s)（基线无此平台）\n", $1, $2, $3, $4
      }
    }
    END {
      for (p in bip) if (!(p in seen)) printf "  %s %s: 仅基线有 %s(%s)（复测无此平台）\n", p, bdom[p], bip[p], bst[p]
    }' "$base" "$after"
}

# v0.1.6 item 1：结构化备份。
BACKUP_ROOT="/var/lib/dnsunlock/backup"
USE_VC=0
# do_backup <标签>：把当前 DNS 状态备份到 $BACKUP_ROOT/<时间戳>_<标签>/，
# 附 metadata.txt（时间、标签、当时 DNS、后端、resolved/NM/resolvconf 的
# active/enabled 状态）+ 各后端文件。失败返回 1（调用方必须中止）。
# 第一次接管的备份就是原始状态、永不覆盖；同时保留
# /etc/dnsunlock/resolv.conf.orig 作为指向首份备份的兼容指针（只写一次）。
do_backup() {
  local label="$1" ts dir n=0 dns="" backends=""
  ts=$(date +%Y%m%d-%H%M%S)
  dir="$BACKUP_ROOT/${ts}_${label}"
  while [ -e "$dir" ]; do n=$((n+1)); dir="$BACKUP_ROOT/${ts}_${label}-$n"; done
  mkdir -p "$dir" || return 1
  cp -L /etc/resolv.conf "$dir/resolv.conf" 2>/dev/null || { rm -rf "$dir"; return 1; }
  if [ -L /etc/resolv.conf ]; then readlink /etc/resolv.conf > "$dir/resolv.conf.symlink" 2>/dev/null || true; fi
  [ -f /etc/systemd/resolved.conf ] && cp -a /etc/systemd/resolved.conf "$dir/resolved.conf" 2>/dev/null || true
  [ -d /etc/systemd/resolved.conf.d ] && cp -a /etc/systemd/resolved.conf.d "$dir/resolved.conf.d" 2>/dev/null || true
  # drop-in 的接管前状态（见 disable_stub_listener 的 stash）：只有 live
  # 内容确实是接管写的标准内容时才按 stash 走——用户若手动改过 drop-in，
  # live 内容就不是标准内容，此时现状即备份，不用 stash。stash 用完即删，
  # 不留给下次接管误用。注意：还原脚本那份 do_backup 不做这段（还原前备份
  # 拍的是现状，live drop-in 就是现状），两份故意不一致，见那边的注释。
  if [ -f /etc/dnsunlock/resolved-dropin.absent ] || [ -f /etc/dnsunlock/resolved-dropin.orig ]; then
    if [ -f /etc/systemd/resolved.conf.d/dnsunlock.conf ] && [ "$(cat /etc/systemd/resolved.conf.d/dnsunlock.conf 2>/dev/null)" = $'[Resolve]\nDNSStubListener=no' ]; then
      cp -a /etc/dnsunlock/resolved-dropin.orig "$dir/resolved-dropin.orig" 2>/dev/null || true
      cp -a /etc/dnsunlock/resolved-dropin.absent "$dir/resolved-dropin.absent" 2>/dev/null || true
      rm -f "$dir/resolved.conf.d/dnsunlock.conf"
    fi
    rm -f /etc/dnsunlock/resolved-dropin.orig /etc/dnsunlock/resolved-dropin.absent
  fi
  [ -d /etc/NetworkManager/conf.d ] && cp -a /etc/NetworkManager/conf.d "$dir/NetworkManager-conf.d" 2>/dev/null || true
  if ls /etc/netplan/*.yaml >/dev/null 2>&1; then mkdir -p "$dir/netplan" && cp -a /etc/netplan/*.yaml "$dir/netplan/" 2>/dev/null || true; fi
  [ -f /etc/nsswitch.conf ] && cp -a /etc/nsswitch.conf "$dir/nsswitch.conf" 2>/dev/null || true
  [ -f /etc/dnsunlock/nm-backup.txt ] && cp -a /etc/dnsunlock/nm-backup.txt "$dir/nm-backup.txt" 2>/dev/null || true
  [ -f /etc/dhcp/dhclient.conf ] && cp -a /etc/dhcp/dhclient.conf "$dir/dhclient.conf" 2>/dev/null || true
  [ -d /etc/cloud/cloud.cfg.d ] && cp -a /etc/cloud/cloud.cfg.d "$dir/cloud.cfg.d" 2>/dev/null || true
  dns=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
  if systemctl cat systemd-resolved.service >/dev/null 2>&1; then backends="resolved"; fi
  if command -v nmcli >/dev/null 2>&1; then backends="${backends:+$backends,}nm"; fi
  if command -v resolvconf >/dev/null 2>&1; then backends="${backends:+$backends,}resolvconf"; fi
  if ls /etc/netplan/*.yaml >/dev/null 2>&1; then backends="${backends:+$backends,}netplan"; fi
  {
    echo "timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "label=$label"
    echo "dns=$dns"
    echo "backends=$backends"
    if [ -L /etc/resolv.conf ]; then echo "resolv_symlink=$(readlink /etc/resolv.conf)"; else echo "resolv_symlink="; fi
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then echo "resolved_active=yes"; else echo "resolved_active=no"; fi
    if systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then echo "resolved_enabled=yes"; else echo "resolved_enabled=no"; fi
    if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then echo "nm_active=yes"; else echo "nm_active=no"; fi
    if systemctl is-enabled --quiet NetworkManager 2>/dev/null; then echo "nm_enabled=yes"; else echo "nm_enabled=no"; fi
    if systemctl is-active --quiet resolvconf 2>/dev/null; then echo "resolvconf_active=yes"; else echo "resolvconf_active=no"; fi
    if systemctl is-enabled --quiet resolvconf 2>/dev/null; then echo "resolvconf_enabled=yes"; else echo "resolvconf_enabled=no"; fi
    # v0.1.6 item 7：主连接记 UUID，不记连接名（连接名含冒号会被截断）。
    if command -v nmcli >/dev/null 2>&1; then echo "nm_primary_uuid=$(get_active_nm_connection_uuid 2>/dev/null || true)"; else echo "nm_primary_uuid="; fi
  } > "$dir/metadata.txt" || { rm -rf "$dir"; return 1; }
  # 兼容指针：只写一次（首份备份的原始状态）。
  if [ "$label" = "pre-takeover" ] && [ ! -e /etc/dnsunlock/resolv.conf.orig ]; then
    cp -L /etc/resolv.conf /etc/dnsunlock/resolv.conf.orig 2>/dev/null || true
    if [ -L /etc/resolv.conf ]; then readlink /etc/resolv.conf > /etc/dnsunlock/resolv.conf.orig.link 2>/dev/null || true; fi
  fi
  echo "已备份当前 DNS 状态 -> $dir" >&2
  echo "$dir"
  return 0
}

# v0.1.6 item 1：nsswitch 的 hosts: 行缺 dns 就补上（改前备份已由 do_backup
# 做进备份目录）。只有无行尾注释的常见写法才自动改；改不上就警告，不硬改。
ensure_nsswitch_dns() {
  [ -f /etc/nsswitch.conf ] || { echo "提示: 无 /etc/nsswitch.conf，跳过 nsswitch 处理"; return 0; }
  if grep -qE '^hosts:.*\bdns\b' /etc/nsswitch.conf 2>/dev/null; then
    echo "nsswitch: hosts: 行已有 dns，不动"
    return 0
  fi
  sed -i -E 's/^(hosts:[[:space:]]+[^#]*[^[:space:]#])([[:space:]]*)$/\1 dns\2/' /etc/nsswitch.conf 2>/dev/null || true
  if grep -qE '^hosts:.*\bdns\b' /etc/nsswitch.conf 2>/dev/null; then
    echo "nsswitch: hosts: 行已补 dns（停 resolved 后 glibc 仍查 resolv.conf）"
  else
    echo "警告: nsswitch hosts: 行补 dns 失败（可能是行尾有注释等特殊写法），请手动在 /etc/nsswitch.conf 的 hosts: 行加上 dns，否则停 resolved 后系统解析可能失效" >&2
  fi
}

# v0.1.6 item 1：use-vc 不再无条件写。接管前先探 UDP 到 agent（dig 不加 +tcp），
# 不通再试 +tcp，TCP 通才写 options use-vc。本机 agent 场景 UDP 几乎总通。
probe_agent_transport() {
  local host="$1" port="$2"
  USE_VC=0
  if ! command -v dig >/dev/null 2>&1; then
    echo "提示: 未装 dig，无法探测 UDP/TCP 传输方式，默认不写 options use-vc（UDP 优先）"
    return 0
  fi
  if dig +short "@$host" -p "$port" example.com A 2>/dev/null | grep -qE '^[0-9]+\.'; then
    echo "传输探测: UDP 到 agent 通，不写 options use-vc"
    return 0
  fi
  if dig +tcp +short "@$host" -p "$port" example.com A 2>/dev/null | grep -qE '^[0-9]+\.'; then
    USE_VC=1
    echo "传输探测: UDP 不通、TCP 通，将写 options use-vc"
    return 0
  fi
  echo "警告: UDP 和 TCP 到 agent 都不通（agent 可能未就绪），默认不写 options use-vc，接管后验证会复查" >&2
  return 0
}

# v0.1.6 item 1：hpve-init 痕迹检测。pride-bubble2 的 resolv.conf 由 hpve-init
# 管理，它会不会改回 resolv.conf 只能在那台机器上由用户在场时实测；
# 这里只做到：检测到痕迹就明确提示并询问，绝不静默接管。
detect_hpve_init() {
  grep -qi "hpve-init" /etc/resolv.conf 2>/dev/null && return 0
  grep -qi "hpve" /etc/resolv.conf 2>/dev/null && return 0
  [ -e /usr/local/bin/hpve-init ] && return 0
  [ -e /etc/hpve-init.conf ] && return 0
  systemctl list-unit-files 2>/dev/null | grep -qi "hpve" && return 0
  return 1
}

# v0.1.6 item 7：按默认路由接口取主网卡（无默认路由时取第一个 UP 的非 lo 网卡）。
get_primary_interface() {
  local dev
  dev=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
  if [ -n "$dev" ]; then echo "$dev"; return 0; fi
  ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | head -1
}

# v0.1.6 item 7：按默认路由接口取活动连接的 UUID（连接名含冒号会被截断），
# 无默认路由时回退取第一个活动连接（对应 AKDNS get_active_nm_connection_uuid）。
# 凡是碰 NetworkManager 的地方一律按 UUID 操作，不用连接名。
get_active_nm_connection_uuid() {
  local iface uuid
  command -v nmcli >/dev/null 2>&1 || return 1
  iface=$(get_primary_interface)
  if [ -n "$iface" ]; then
    uuid=$(nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null | awk -F: -v dev="$iface" '$2==dev {print $1; exit}')
    [ -n "$uuid" ] && { echo "$uuid"; return 0; }
  fi
  nmcli -t -f UUID connection show --active 2>/dev/null | head -1
}

# v0.1.6 item 5（临时模式）：把 agent 设为系统 DNS，但不做永久接管。
# systemd-resolved 在跑 → resolvectl dns <主网卡> 127.0.0.1（重启/服务重启后失效）；
# 否则直接写 resolv.conf，不加 chattr 锁、不停任何管理器、不动
# netplan/cloud-init/dhclient。全程不写永久备份。
write_temp_resolv_conf() {
  local link=""
  chattr -i /etc/resolv.conf 2>/dev/null || true
  if [ -L /etc/resolv.conf ]; then
    link=$(readlink /etc/resolv.conf)
    echo "提示: 原 /etc/resolv.conf 是软链 -> $link，临时模式先去掉软链写静态文件；还原时手动恢复软链（ln -s $link /etc/resolv.conf）或重启 systemd-resolved。"
    rm -f /etc/resolv.conf
  fi
  if [ "${USE_VC:-0}" = "1" ]; then
    printf 'nameserver 127.0.0.1\noptions use-vc\n' > /etc/resolv.conf
  else
    printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
  fi
  echo "临时模式：已直接写 /etc/resolv.conf（nameserver 127.0.0.1，不加 chattr 锁）。"
}

apply_temp_dns() {
  local iface=""
  # Tailscale 守卫：临时模式也不碰 Tailscale 管理的 resolv.conf。
  if grep -qi "tailscale" /etc/resolv.conf 2>/dev/null || grep -q "nameserver 100.100.100.100" /etc/resolv.conf 2>/dev/null; then
    echo "注意: 检测到 /etc/resolv.conf 由 Tailscale 生成，临时模式也不改本机 DNS（会断 Tailscale 内网 DNS）。"
    echo "如需本机流量也走分流，请手动把其他机器的 DNS 指到本机，或在 Tailscale 之外再处理。"
    return 0
  fi
  probe_agent_transport "$_dl_host" "$_dl_port"
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    iface=$(get_primary_interface)
    if [ -n "$iface" ] && resolvectl dns "$iface" 127.0.0.1 2>/dev/null; then
      echo "临时模式：已用 resolvectl 把 $iface 的 DNS 设为 127.0.0.1（agent）。"
    else
      echo "警告: resolvectl 设置失败，改直接写 resolv.conf（临时，不加锁）" >&2
      write_temp_resolv_conf
    fi
  else
    write_temp_resolv_conf
  fi
  echo "临时模式说明：本次只改了运行时 DNS，没有永久备份、没有 chattr 锁、没有停任何管理器。"
  echo "重启后失效（resolved 重启 / DHCP 续租 / 管理器运行时也可能失效）。"
  echo "要永久生效：重跑安装并选接管（本机系统 DNS 设为 127.0.0.1）。"
  echo "要立即还原：systemctl restart systemd-resolved（resolved 机器）或重新拉 DHCP（如 dhclient -r; dhclient，或重启 NetworkManager），或手动把 /etc/resolv.conf 改回原来的 DNS。"
  verify_system_dns example.com || echo "警告: 临时模式接管后系统解析验证未通过（见上），请检查 agent 是否在跑；还原办法见上。" >&2
}

# v0.1.3 容错：面板 443 被挡时不要硬等 134 秒。候选入口：
# (a) 配置的 PANEL_URL 本身，(b) 同一主机 http :8080（面板本身一直监听
# :8080，443 只是 Caddy 的反代），(c) 同一主机解析出的 IP :8080。
# v0.1.6 V016-04：全部候选并行探测（curl 计时，--max-time 8），按延迟
# 排序选最快且可达的，不再是“第一个通的就赢”。任何 HTTP 响应都算通
# （没 token 的 whoami 回 401 也算，说明到面板了）。成功时 stdout 只
# 输出选中的地址，诊断打到 stderr。都不通返回 1。
probe_panel() {
  local base="$1" scheme rest hostport host port ip
  local cands=() uniq=() cand code u seen
  scheme="${base%%://*}"; rest="${base#*://}"; hostport="${rest%%/*}"
  case "$hostport" in
    \[*\]* ) host="${hostport#[}"; host="${host%]*}" ;;
    * ) host="${hostport%%:*}" ;;
  esac
  port="${hostport##*:}"
  case "$port" in ''|*[!0-9]* ) port="" ;; esac
  cands+=("$base")
  # (b) 同主机 :8080（本身就是 http :8080 时跳过）
  if [ "$scheme" = "https" ] || [ "$port" != "8080" ]; then
    case "$host" in
      *:* ) cands+=("http://[$host]:8080") ;;
      * ) cands+=("http://$host:8080") ;;
    esac
  fi
  # (c) 解析出的 IP :8080（host 已是 IP 时 getent 原样返回，去重会去掉）
  if [ -n "$host" ]; then
    for ip in $(getent hosts "$host" 2>/dev/null | awk '{print $1}' | sort -u); do
      case "$ip" in
        *:* ) cands+=("http://[$ip]:8080") ;;
        * ) cands+=("http://$ip:8080") ;;
      esac
    done
  fi
  # (d) 本机 :8080（面板和 agent 在同一台机器上时：公网 IP 可能因无 hairpin
  # NAT 而不通，本机回环一定通；没有本机面板时连接被拒，瞬间失败，无代价）
  cands+=("http://127.0.0.1:8080")
  for cand in "${cands[@]}"; do
    seen=0
    for u in "${uniq[@]}"; do [ "$u" = "$cand" ] && seen=1; done
    [ "$seen" = 0 ] && uniq+=("$cand")
  done
  # v0.1.6 V016-04：并行测全部候选入口（curl 计时，8 秒超时），按延迟
  # 排序选最快且可达的做 PANEL_BASE，并打印排名；测速只影响选入口，
  # 不改变 agent 的规则/分流行为。成功时 stdout 只输出选中的地址，
  # 诊断打到 stderr。都不通返回 1。
  local tmpdir
  tmpdir="$(mktemp -d /tmp/dnsunlock-probe.XXXXXX)"
  local i=0
  for cand in "${uniq[@]}"; do
    ( out="$(curl -s -o /dev/null -w "%{http_code} %{time_total}" --max-time 8 "$cand/api/v1/agent/whoami" 2>/dev/null)" && printf '%s\n' "$out" > "$tmpdir/$i" || echo "000 0" > "$tmpdir/$i" ) &
    i=$((i+1))
  done
  wait || true
  local results=() ms code tsec
  i=0
  for cand in "${uniq[@]}"; do
    if read -r code tsec < "$tmpdir/$i" 2>/dev/null && [ -n "$code" ] && [ "$code" != "000" ]; then
      ms="$(awk -v t="$tsec" 'BEGIN{printf "%.0f", t*1000}')"
      results+=("$ms"$'\t'"$cand"$'\t'"$code")
    else
      echo "  探测 $cand -> 不通（HTTP ${code:-000}）" >&2
    fi
    i=$((i+1))
  done
  if [ "${#results[@]}" -eq 0 ]; then
    rm -rf "$tmpdir"
    echo "面板都连不上，试过：${uniq[*]}" >&2
    echo "请检查面板是否在运行；如果 443 被挡，可用 --panel 指定面板机的内网地址，如：bash install.sh --panel http://<面板机内网IP>:8080；面板和 agent 在同一台机器上时可用 --panel http://127.0.0.1:8080" >&2
    return 1
  fi
  local ranked best
  ranked="$(printf '%s\n' "${results[@]}" | sort -n)"
  echo "  面板入口测速排名（并行探测，8 秒超时，最快在前）：" >&2
  echo "$ranked" | while IFS=$'\t' read -r ms cand code; do
    echo "    $cand -> HTTP $code，${ms} ms" >&2
  done
  best="$(echo "$ranked" | head -1 | cut -f2)"
  rm -rf "$tmpdir"
  echo "$best"
  return 0
}

# v0.1.6 item 6：validate_ipv4（照抄 AKDNS：正则 + 每段 ≤255）。
validate_ipv4() {
  local v="$1" a b c d rest o
  v="$(echo "$v" | tr -d ' ')"
  [ -n "$v" ] || return 1
  case "$v" in *[!0-9.]*) return 1;; esac
  IFS='.' read -r a b c d rest <<< "$v"
  [ -n "${rest:-}" ] && return 1
  for o in "$a" "$b" "$c" "$d"; do
    case "$o" in ''|*[!0-9]*) return 1;; esac
    [ "$o" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

# v0.1.6 item 6：面板地址形状校验。http(s)://host[:port][/...]；
# host 是纯数字点分时必须是合法 IPv4（走 validate_ipv4），域名或 IPv6
# 形状上放过（连通性由 probe_panel 验证）。
valid_panel_url() {
  local u="$1" rest hostport host port
  case "$u" in http://*|https://*) ;; *) return 1;; esac
  rest="${u#*://}"
  [ -n "$rest" ] || return 1
  hostport="${rest%%/*}"
  [ -n "$hostport" ] || return 1
  case "$hostport" in
    \[*\]*)
      host="${hostport#[}"; host="${host%\]*}"
      case "$hostport" in
        *\]:*) port="${hostport##*:}"; case "$port" in ''|*[!0-9]*) return 1;; esac; [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1;;
      esac
      ;;
    *:*)
      host="${hostport%%:*}"; port="${hostport##*:}"
      case "$port" in ''|*[!0-9]*) return 1;; esac
      [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
      ;;
    *)
      host="$hostport"
      ;;
  esac
  [ -n "$host" ] || return 1
  case "$host" in
    *[!0-9.]*) : ;; # 域名或 IPv6：形状上放过，probe 验证连通性
    *) validate_ipv4 "$host" || return 1 ;;
  esac
  return 0
}

# v0.1.6 item 6：先探面板，探不到时给手动输入面板地址的入口（带校验），
# 而不是只报错退出。无终端时仍直接报错退出（curl|bash 且无终端无法提问）。
resolve_panel_base() {
  local base="$1" manual=""
  if PANEL_BASE="$(probe_panel "$base")"; then
    echo "$PANEL_BASE"
    return 0
  fi
  if ! has_tty; then
    echo "无可交互终端，无法手动输入面板地址，安装停止。" >&2
    return 1
  fi
  echo "面板都连不上（见上）。可以手动输入面板地址再试一次，或直接回车放弃。" >&2
  ask manual "手动输入面板地址（如 http://203.0.113.5:8080，面板和 agent 在同一台机器上时可用 http://127.0.0.1:8080；回车放弃）: "
  [ -n "${manual:-}" ] || return 1
  manual="${manual%/}"
  if ! valid_panel_url "$manual"; then
    echo "面板地址格式不对: $manual（要像 http://203.0.113.5:8080，host 是 IPv4 时每段 ≤255）" >&2
    return 1
  fi
  if PANEL_BASE="$(probe_panel "$manual")"; then
    echo "$PANEL_BASE"
    return 0
  fi
  echo "手动输入的面板地址也连不上，安装停止。" >&2
  return 1
}

# P1-10: 先检查 systemd / 端口，再动手；没有 systemd 的机器直接停下，不留半截服务。
if [ "$MODE" = "dns" ]; then
  command -v systemctl >/dev/null || { echo "需要 systemd（systemctl 不存在），本脚本不支持 OpenRC/SysVInit，请手动按 README 部署"; exit 1; }
  _bind_rc=0
  can_bind_listen "$DNS_LISTEN" || _bind_rc=$?
  if [ "$_bind_rc" = 1 ]; then
    if stub_only_conflict; then
      echo "检测到 systemd-resolved 的 stub 监听占着 127.0.0.53:53，agent 无法绑定 $DNS_LISTEN。"
      echo "可以只关掉 stub 监听（写 /etc/systemd/resolved.conf.d/dnsunlock.conf，DNSStubListener=no，并重启 systemd-resolved；不改 /etc/resolv.conf，不影响上游 DNS）。"
      if [ "${DNS_DISABLE_STUB:-}" = "y" ] || [ "${DNS_DISABLE_STUB:-}" = "Y" ] || ask_yes_no "是否关掉 systemd-resolved 的 stub 监听？"; then
        disable_stub_listener
        if can_bind_listen "$DNS_LISTEN"; then
          echo "stub 已关，$DNS_LISTEN 现在可绑定。"
        else
          echo "关掉 stub 后 $DNS_LISTEN 仍被占：请用 --dns-listen 换个端口（如 127.0.0.1:5353），或先停掉占用的服务再重跑。"
          exit 1
        fi
      else
        echo "未关 stub：请用 --dns-listen 换个端口（如 bash install.sh --dns-listen 127.0.0.1:5353），或先停掉占用的服务再重跑。"
        exit 1
      fi
    else
      echo "$DNS_LISTEN 已被占用（不是 systemd-resolved 的 stub）：请用 --dns-listen 换个端口，或先停掉占用的服务再重跑。"
      exit 1
    fi
  elif [ "$_bind_rc" = 2 ]; then
    echo "注意: 没装 python3，无法准确探测 $DNS_LISTEN 是否可绑定；继续安装，启动后第 [4/6] 步会验证解析，不通会报错。"
  else
    echo "监听地址 $DNS_LISTEN 可绑定。"
  fi
fi

echo "=== dnsunlock 安装 ==="
echo "面板: $PANEL_URL"
[ -z "${PANEL_URL:-}" ] && ask PANEL_URL "面板地址 (如 http://203.0.113.5:8080): "
PANEL_URL="${PANEL_URL%/}"
# agent token：没带 DNS_AGENT_TOKEN 环境变量时交互输入，不回显；
# 只放 600 配置文件里，绝不出现在启动命令 / 日志里。
if [ -z "${TOKEN:-}" ]; then
  ask TOKEN "agent token（面板 -> DNS 服务器 -> 登记后显示的那串，只显示一次）: " silent
fi
if [ -z "${TOKEN:-}" ]; then
  echo "agent token 不能为空。"
  if ! has_tty; then echo "当前没有可交互的终端（curl | bash 时无法提问）：请用面板生成的安装命令（自带 DNS_AGENT_TOKEN），或先把脚本下载下来再执行：curl -fsSL $PANEL_URL/install.sh -o /tmp/install.sh && bash /tmp/install.sh"; fi
  exit 1
fi

# v0.1.3: 先探面板，443 被挡时自动改走 :8080（每步最多等 8 秒，不会卡 134 秒）。
# v0.1.6 item 6：探不到时给手动输入面板地址的入口（resolve_panel_base）。
# PANEL_URL 是登记的规范地址；PANEL_BASE 是本次安装实际用的地址
# （443 被挡自动改走 :8080、或手动输入的地址）。
# agent 配置里记 PANEL_BASE——记 PANEL_URL 的话，改走/手动输入的地址下
# agent 永远连不上面板（只会试 PANEL_URL 及其 :8080 变体），规则拉不到。
PANEL_BASE="$(resolve_panel_base "$PANEL_URL")" || exit 1
if [ "$PANEL_BASE" != "$PANEL_URL" ]; then
  echo "面板 443 不通，已自动改走 $PANEL_BASE（面板直连 :8080）。"
fi

# M-02: token 不进命令行：写进 0600 的 curl 配置文件，curl -K 读它。
# 旧写法（curl -H 后直接跟 token）会把 token 写进进程列表（ps 可见）。
# 配置文件路径进 ps 不打紧，token 本身不出现；脚本退出时删掉（token 是
# hex 串，写进 curl 配置文件无需转义）。
AUTH_CFG="$(mktemp /tmp/dnsunlock-auth.XXXXXX)"
chmod 600 "$AUTH_CFG"
printf 'header = "X-Agent-Token: %s"\n' "$TOKEN" > "$AUTH_CFG"
trap 'rm -f "$AUTH_CFG" /tmp/dnsunlock-whoami.json' EXIT

# 0. 装前基线测试（P1-11，照 AKDNS 的做法）：面板通不通、token 对不对、解锁 IP 通不通。
echo "[0/6] 装前检查：面板连通性 + token..."
if ! curl -fsSL -K "$AUTH_CFG" "$PANEL_BASE/api/v1/agent/whoami" -o /tmp/dnsunlock-whoami.json; then
  echo "面板连不上或 agent token 不对：请检查面板地址和 token（token 是每台服务器单独的那串，不是 admin 密码）。"
  exit 1
fi
if [ -z "$SERVER_ID" ]; then
  SERVER_ID=$(sed -n 's/.*"server_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /tmp/dnsunlock-whoami.json | head -1)
fi
[ -n "${SERVER_ID:-}" ] || { echo "无法从 token 解析 server_id，请检查 token"; exit 1; }
echo "server_id: $SERVER_ID（token 验证通过）"

# 1. 下载二进制（必须带 agent token 头；sha256 下不到就停，不跳过校验）。
mkdir -p /usr/local/bin /etc/dnsunlock
ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) BIN="dnsunlock-linux-amd64";; aarch64|arm64) BIN="dnsunlock-linux-arm64";; *) echo "不支持的架构: $ARCH"; exit 1;; esac
echo "[1/6] 下载 $BIN ..."
# P0-REAL-01：二进制必须以 $BIN 的名字下载到临时目录再校验，校验文件里写的
# 名字就是 $BIN；旧写法直接存为 /usr/local/bin/dnsunlock 再 sha256sum -c，
# 目录里没有 $BIN，校验永远失败。校验通过后再装到最终位置。
DL_TMP="$(mktemp -d)"
trap 'rm -f "$AUTH_CFG" /tmp/dnsunlock-whoami.json; rm -rf "$DL_TMP"' EXIT
curl -fsSL -K "$AUTH_CFG" "$PANEL_BASE/dl/$BIN" -o "$DL_TMP/$BIN" || { echo "下载失败：检查面板地址 / token / Release 是否已发"; exit 1; }
curl -fsSL "$PANEL_BASE/dl/$BIN.sha256" -o "$DL_TMP/$BIN.sha256" || { echo "sha256 文件下载失败：为安全起见停止安装，不跳过校验"; exit 1; }
(cd "$DL_TMP" && sha256sum -c "$BIN.sha256") || { echo "sha256 校验失败：二进制可能被篡改，停止安装"; exit 1; }
echo "sha256 校验通过"
install -m 0755 "$DL_TMP/$BIN" /usr/local/bin/dnsunlock
rm -rf "$DL_TMP"
chmod +x /usr/local/bin/dnsunlock

if [ "$MODE" = "unlock" ]; then
  # ---- 可选: SNI 解锁节点模式 ----
  echo "[2/6] 配置 SNI 代理模式 (可选助手, 面板/DNS 分流不依赖它)..."
  if [ -z "${SNI_ALLOW:-}" ]; then
    ask SNI_ALLOW "允许使用本 SNI 代理的客户端 IP/CIDR，逗号分隔（必填，如 203.0.113.7；不填不启动）: "
  fi
  [ -n "${SNI_ALLOW:-}" ] || { echo "SNI 代理默认拒绝：不填 allowlist 就不启动，避免变成公开代理。"; exit 1; }
  for _e in $(echo "$SNI_ALLOW" | tr ',' ' '); do valid_ip_cidr "$_e" || { echo "SNI allowlist 里格式不对: $_e"; exit 1; }; done
  # N-12: SNI 也走 600 配置文件（http_listen 为空 = 明文 HTTP 默认禁用，
  # N-05），启动命令不再带 --allowlist（ps 可见）。
  cat > /etc/dnsunlock/config.json <<EOF
{"mode":"sni-proxy","sni_listen":":443","http_listen":"","allowlist":"$SNI_ALLOW"}
EOF
  chmod 600 /etc/dnsunlock/config.json
  cat > /etc/systemd/system/dnsunlock-proxy.service <<EOF
[Unit]
Description=dnsunlock SNI proxy (optional unlock node)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/dnsunlock sni-proxy --config /etc/dnsunlock/config.json
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now dnsunlock-proxy
  echo "完成: SNI 代理已在 :443 运行（明文 HTTP 默认禁用，只放行 allowlist 里的 IP）。"
  echo "接下来: 把这台机器的公网 IP 填进面板 -> 解锁 IP, 再给平台选它。"
  echo "注意: 443 端口可能被 nginx/Caddy 占用, 冲突时请先停掉它们或改 SNI_LISTEN。"
  exit 0
fi

# ---- DNS 分流服务模式 ----
if [ -z "$SERVER_NAME" ]; then
  ask SERVER_NAME "DNS 服务器名称 (如 香港-DNS-01，可空用面板登记的名字): "
fi
if [ -z "$DEFAULT_IP" ]; then
  ask DEFAULT_IP "默认解锁 IP (可空；只在某条规则的地区无可用节点时作备用，无规则的域名仍走上游): "
fi
if [ -n "$DEFAULT_IP" ] && ! valid_ip_cidr "$DEFAULT_IP"; then echo "默认解锁 IP 格式不对"; exit 1; fi
if [ -z "$DEFAULT_IP" ] && [ -n "$UNLOCK_IPS" ]; then
  echo "对解锁 IP 测速 (TCP :443)..."
  FASTEST=$(pick_fastest_ip "$UNLOCK_IPS" | tail -1)
  if [ -n "$FASTEST" ]; then echo "最快: $FASTEST, 将作为默认解锁 IP"; DEFAULT_IP="$FASTEST"; fi
elif [ -n "$UNLOCK_IPS" ]; then
  echo "对解锁 IP 测速 (TCP :443, 仅供参考)..."
  pick_fastest_ip "$UNLOCK_IPS" >/dev/null
fi
# allowlist 必填（P0-04）：空着就等于公开 DNS，直接停下。
while [ -z "${ALLOWLIST:-}" ]; do
  ask ALLOWLIST "允许使用本 DNS 的客户端 IP/CIDR，逗号分隔（必填，否则 53 会被滥用做 DNS 放大攻击，如 203.0.113.7,192.168.1.0/24；本机测试填 127.0.0.1）: "
  [ -n "${ALLOWLIST:-}" ] || echo "allowlist 不能为空。"
done
for _e in $(echo "$ALLOWLIST" | tr ',' ' '); do valid_ip_cidr "$_e" || { echo "allowlist 里格式不对: $_e"; exit 1; }; done

# 2. 写配置（token 只在 600 文件里）
echo "[2/6] 写配置..."
cat > /etc/dnsunlock/config.json <<EOF
{
  "mode": "dns-agent",
  "panel_url": "$PANEL_BASE",
  "agent_token": "$TOKEN",
  "server_id": "$SERVER_ID",
  "dns_listen": "$DNS_LISTEN",
  "allowlist": "$ALLOWLIST"
}
EOF
chmod 600 /etc/dnsunlock/config.json

# 3. systemd（启动命令不带 token，见 P1-10）
cat > /etc/systemd/system/dnsunlock-agent.service <<EOF
[Unit]
Description=dnsunlock DNS agent (split unlock)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/dnsunlock dns-agent --config /etc/dnsunlock/config.json
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

# 4. 防火墙：不主动全网放行 53。agent 的 allowlist 已挡住非授权客户端；
#    如需从外网访问，请在防火墙/安全组里只放行 allowlist 里的 IP。
echo "[3/6] 启动服务（不自动放行防火墙 53，请按 allowlist 自行放行）..."
systemctl daemon-reload
systemctl enable --now dnsunlock-agent
sleep 1
systemctl --no-pager status dnsunlock-agent --lines=5 || true

# 5. 装后验证（P1-11）：服务在跑、规则域名回解锁 IP、普通域名走上游；不通就报错，不说“安装完成”。
# dig 目标按实际监听地址来（默认 127.0.0.1:53，--dns-listen 改了就跟它走）。
echo "[4/6] 装后验证..."
_dl_host="${DNS_LISTEN%:*}"; _dl_host="${_dl_host#[}"; _dl_host="${_dl_host%]}"
_dl_port="${DNS_LISTEN##*:}"
[ -n "$_dl_host" ] || _dl_host="127.0.0.1"
if command -v dig >/dev/null 2>&1; then
  # UDP 先测（默认）；UDP 不通再试 TCP——有些环境会过滤 UDP/53（沙箱里回环
  # UDP 回包会被丢，实测 Go UDP echo：server 收到包、client 永远等不到回包），
  # agent 本身 TCP 能答就说明服务正常，不应硬失败。两路都不通仍是硬失败。
  if dig +short "@$_dl_host" -p "$_dl_port" example.com A | grep -qE '^[0-9]+\.'; then echo "  验证通过: example.com 能走上游解析";
  elif dig +tcp +short "@$_dl_host" -p "$_dl_port" example.com A | grep -qE '^[0-9]+\.'; then echo "  验证通过: example.com 能走上游解析（TCP；本机 UDP 解析不通，已自动走 TCP）";
  else echo "  验证失败: example.com 解析无结果（UDP 与 TCP 均不通），请看 journalctl -u dnsunlock-agent"; exit 1; fi
  echo "  提示: 再测一条已设规则的域名，如 dig @$_dl_host -p $_dl_port netflix.com A，应返回规则里配的解锁 IP（未设规则时走上游属正常）。"
else
  # v0.1.6 item 2：缺 dig 不再 exit 1——区分“测不了”和“测了不通”。
  # 测不了只警告 + 继续安装（接管步必须能跑到）；dig 在但解析无结果仍是硬失败（见上）。
  echo "  警告: 未装 dig，无法自动验证解析，继续安装（agent 本身不受影响）。"
  echo "  请手动验证：dig @$_dl_host -p $_dl_port example.com A（装 dig：Debian/Ubuntu 用 apt-get install -y dnsutils，RHEL/CentOS 用 yum install -y bind-utils）"
  echo "  也可不用 dig：getent hosts example.com（走系统解析器；接管后才有效）"
fi

# v0.1.6 V016-05：接管前基线（dnsunlock check --via upstream：规则域名
# 走上游直接解析的结果）。接管后在接管/临时分支内再跑一次 --via agent
# 做复测，两次结果并排对比打印。check 失败不致命（警告 + 继续），但
# 失败要写清楚（见 run_dnsunlock_check）。未接管时只有基线，无复测。
BASELINE_CHECK_FILE="$(mktemp /tmp/dnsunlock-check-baseline.XXXXXX)"
AFTER_CHECK_FILE="$(mktemp /tmp/dnsunlock-check-after.XXXXXX)"
CHECK_COMPARED=0
run_dnsunlock_check "基线（接管前）" "upstream" "$BASELINE_CHECK_FILE" || true

# 6. 可选: 把本机系统 DNS 设为 127.0.0.1（默认不做，需确认）。
# --temp 临时模式：只把本次运行的 DNS 指到 agent，不做永久接管（见 apply_temp_dns）。
if [ "${TEMP_MODE:-0}" = "1" ]; then
  echo
  echo "=== 临时模式（--temp）：只把本次运行的 DNS 指到 agent，不做永久接管 ==="
  apply_temp_dns
  # v0.1.6 V016-05：临时模式复测 + 基线对比（失败只警告，不致命）。
  run_dnsunlock_check "复测（临时模式）" "agent" "$AFTER_CHECK_FILE" || true
  print_check_comparison "$BASELINE_CHECK_FILE" "$AFTER_CHECK_FILE" || true
  CHECK_COMPARED=1
# P1-REAL-01 补充：resolv.conf 由 Tailscale 生成的机器绝对不接管——
# Tailscale 的 DNS（100.100.100.100）一旦被覆盖，内网机器就连不上了。
elif grep -qi "tailscale" /etc/resolv.conf 2>/dev/null || grep -q "nameserver 100.100.100.100" /etc/resolv.conf 2>/dev/null; then
  echo
  echo "注意: 检测到 /etc/resolv.conf 由 Tailscale 生成，本机不做 DNS 接管（接管会断 Tailscale 内网 DNS）。"
  echo "如需本机流量也走分流，请手动把其他机器的 DNS 指到本机，或在 Tailscale 之外再处理。"
else
echo
ask TAKEOVER "是否把本机系统 DNS 设为 127.0.0.1 (本机流量也走分流)? [y/N] "
# v0.1.6 item 1：hpve-init 痕迹检测——明确提示并询问，绝不静默接管。
if { [ "${TAKEOVER:-}" = "y" ] || [ "${TAKEOVER:-}" = "Y" ]; } && detect_hpve_init; then
  echo "!!!! 注意：检测到 hpve-init 管理本机 DNS 的痕迹（/etc/resolv.conf 或系统里有 hpve-init 相关文件/服务）!!!!"
  echo "hpve-init 可能会在之后把 resolv.conf 改回去，导致接管失效；是否继续接管请自行判断。"
  if ask_yes_no "检测到 hpve-init 痕迹，是否仍要继续接管？"; then
    echo "用户确认：继续接管（hpve-init 痕迹已知）"
  else
    echo "已取消接管（hpve-init 痕迹）：agent 本身已装好并在运行，只是不改本机系统 DNS。"
    TAKEOVER="n"
  fi
fi
# v0.1.6 item 6：接管前照抄 AKDNS menu_apply 的安全流程——打印操作摘要 +
# [y/N] 确认（默认 N）+ 自动备份（备份失败中止应用，见接管体内的 do_backup）。
# 传输探测是只读探测，提前到摘要前做，摘要里写明传输方式。
if { [ "${TAKEOVER:-}" = "y" ] || [ "${TAKEOVER:-}" = "Y" ]; }; then
  probe_agent_transport "$_dl_host" "$_dl_port"
  TAKEOVER_BACKENDS=""
  if systemctl cat systemd-resolved.service >/dev/null 2>&1; then TAKEOVER_BACKENDS="systemd-resolved（只关 stub 监听）"; fi
  if command -v nmcli >/dev/null 2>&1; then
    # v0.1.6 item 7：主连接按 UUID 标识（不用连接名），已记进备份 metadata。
    _puuid=$(get_active_nm_connection_uuid 2>/dev/null || true)
    if [ -n "$_puuid" ]; then TAKEOVER_BACKENDS="${TAKEOVER_BACKENDS:+$TAKEOVER_BACKENDS，}NetworkManager（dns=none，主连接 $_puuid）";
    else TAKEOVER_BACKENDS="${TAKEOVER_BACKENDS:+$TAKEOVER_BACKENDS，}NetworkManager（dns=none）"; fi
  fi
  if command -v resolvconf >/dev/null 2>&1; then TAKEOVER_BACKENDS="${TAKEOVER_BACKENDS:+$TAKEOVER_BACKENDS，}resolvconf（head 文件）"; fi
  if [ -f /etc/dhcp/dhclient.conf ]; then TAKEOVER_BACKENDS="${TAKEOVER_BACKENDS:+$TAKEOVER_BACKENDS，}dhclient（supersede）"; fi
  if [ -d /etc/cloud/cloud.cfg.d ]; then TAKEOVER_BACKENDS="${TAKEOVER_BACKENDS:+$TAKEOVER_BACKENDS，}cloud-init（manage-resolv-conf: false）"; fi
  if ls /etc/netplan/*.yaml >/dev/null 2>&1; then TAKEOVER_BACKENDS="${TAKEOVER_BACKENDS:+$TAKEOVER_BACKENDS，}netplan（改 nameservers，需再确认）"; fi
  if [ -f /etc/nsswitch.conf ]; then TAKEOVER_BACKENDS="${TAKEOVER_BACKENDS:+$TAKEOVER_BACKENDS，}nsswitch（hosts: 行缺 dns 就补）"; fi
  [ -z "$TAKEOVER_BACKENDS" ] && TAKEOVER_BACKENDS="无（只写静态 resolv.conf）"
  echo "=== 接管前确认（操作摘要）==="
  echo "  模式：永久接管（本机系统 DNS -> 127.0.0.1）"
  echo "  DNS：nameserver 127.0.0.1（agent 监听 $_dl_host:$_dl_port）"
  echo "  后端：$TAKEOVER_BACKENDS"
  if [ "${USE_VC:-0}" = "1" ]; then echo "  传输方式：TCP（UDP 不通，写 options use-vc）"; else echo "  传输方式：UDP 直连 agent"; fi
  echo "  接管方式：静态 resolv.conf + chattr +i 锁定（文件系统不支持时会警告）"
  echo "  备份：自动备份当前状态到 /var/lib/dnsunlock/backup/<时间戳>_pre-takeover/（含 metadata.txt），备份失败则中止接管"
  echo "  还原：dnsunlock-restore-dns（默认还原最早的一份，即原始状态）"
  if ask_yes_no "确认按上面摘要接管本机 DNS 吗？"; then
    echo "已确认，开始接管。"
  else
    echo "已取消接管：agent 本身已装好并在运行，只是不改本机系统 DNS。"
    TAKEOVER="n"
  fi
fi
if [ "${TAKEOVER:-}" = "y" ] || [ "${TAKEOVER:-}" = "Y" ]; then
  # v0.1.6 item 1：结构化备份——先备份当前状态，备份失败就中止，不动任何文件。
  # 第一次接管的备份就是原始状态、永不覆盖；/etc/dnsunlock/resolv.conf.orig
  # 只作为指向首份备份的兼容指针保留（do_backup 内只写一次）。
  do_backup "pre-takeover" || { echo "备份失败，已中止接管（未改任何文件），请检查磁盘 / 权限后重跑"; exit 1; }
  # nsswitch：hosts: 行缺 dns 就补上（改前备份已在备份目录里）。
  ensure_nsswitch_dns
  # systemd-resolved
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/dnsunlock.conf
    systemctl restart systemd-resolved
    echo "systemd-resolved: 已关 stub 监听 (drop-in 可删: /etc/systemd/resolved.conf.d/dnsunlock.conf)"
  fi
  # NetworkManager（v0.1.6 item 1）：不再逐连接改 ipv4.dns，改成写
  # /etc/NetworkManager/conf.d/dnsunlock.conf（dns=none）+ reload，不停用网络，
  # 新连接也不受影响。旧方式接管过的机器仍有 nm-backup.txt，还原脚本照旧认它
  #（新格式记 UUID，老文件记连接名，见 item 7）。
  if command -v nmcli >/dev/null 2>&1; then
    mkdir -p /etc/NetworkManager/conf.d
    printf '[main]\ndns=none\n' > /etc/NetworkManager/conf.d/dnsunlock.conf
    if systemctl reload NetworkManager 2>/dev/null || nmcli general reload 2>/dev/null; then
      echo "NetworkManager: 已写 dns=none（/etc/NetworkManager/conf.d/dnsunlock.conf）并重载，未断网"
    else
      echo "警告: NetworkManager 重载失败，dns=none 可能未生效；resolv.conf 已加 chattr 锁兜底" >&2
    fi
  fi
  # resolvconf：把 127.0.0.1 写进 head，让它下次生成时也带上。
  if command -v resolvconf >/dev/null 2>&1; then
    mkdir -p /etc/resolvconf/resolv.conf.d
    printf 'nameserver 127.0.0.1\n' > /etc/resolvconf/resolv.conf.d/head.dnsunlock
    resolvconf -u 2>/dev/null || true
    echo "resolvconf: 已写 head.dnsunlock"
  fi
  # dhclient：加 supersede，防止 DHCP 下发 DNS 覆盖。
  if [ -f /etc/dhcp/dhclient.conf ] && ! grep -q "dnsunlock" /etc/dhcp/dhclient.conf 2>/dev/null; then
    cp -a /etc/dhcp/dhclient.conf /etc/dnsunlock/dhclient.conf.bak
    printf '\n# dnsunlock: 固定本机 DNS 为 127.0.0.1\nsupersede domain-name-servers 127.0.0.1;\n' >> /etc/dhcp/dhclient.conf
    echo "dhclient: 已加 supersede domain-name-servers 127.0.0.1（原文件已备份）"
  fi
  # cloud-init：关掉它对 resolv.conf 的管理。
  if [ -d /etc/cloud/cloud.cfg.d ]; then
    printf 'manage-resolv-conf: false\n' > /etc/cloud/cloud.cfg.d/99-dnsunlock.cfg
    echo "cloud-init: 已写 99-dnsunlock.cfg（manage-resolv-conf: false）"
  fi
  # netplan：有 nameservers 配置时，备份 yaml 并把 addresses 改为 [127.0.0.1]，再 netplan apply（需确认）。
  if ls /etc/netplan/*.yaml >/dev/null 2>&1 && grep -lq "nameservers" /etc/netplan/*.yaml 2>/dev/null; then
    echo "检测到 netplan 配置了 nameservers："
    ask NP "是否自动改 netplan（备份 yaml，把 nameservers.addresses 改为 [127.0.0.1] 并 netplan apply）? [y/N] "
    if [ "${NP:-}" = "y" ] || [ "${NP:-}" = "Y" ]; then
      for f in /etc/netplan/*.yaml; do
        cp -a "$f" "/etc/dnsunlock/$(basename "$f").bak"
        python3 - "$f" <<'PYEOF' || sed -i 's/addresses: \[[^]]*\]/addresses: [127.0.0.1]/g' "$f"
import re, sys
p = sys.argv[1]
s = open(p).read()
# P1-09：不加 count=1——一个文件里多个网卡都可能配 nameservers，都要改。
s2 = re.sub(r'(nameservers:\s*\n(?:[ \t]+.*\n)*?[ \t]+addresses:\s*)\[[^\]]*\]', r'\g<1>[127.0.0.1]', s)
open(p, 'w').write(s2)
PYEOF
      done
      netplan apply 2>/dev/null || echo "netplan apply 失败，请手动检查 /etc/netplan/*.yaml"
      echo "netplan: 已改（原 yaml 已备份到 /etc/dnsunlock/）"
    else
      echo "netplan 未改：下次 netplan apply 可能覆盖 resolv.conf，请手动把 nameservers.addresses 改为 [127.0.0.1]。"
    fi
  fi
  # 静态 resolv.conf：先去 chattr 锁（如果之前锁过），去掉软链，写 127.0.0.1，再加锁。
  chattr -i /etc/resolv.conf 2>/dev/null || true
  [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
  # v0.1.6 item 1：options use-vc 只在传输探测确认 UDP 不通、TCP 通时才写。
  if [ "${USE_VC:-0}" = "1" ]; then
    printf 'nameserver 127.0.0.1\noptions use-vc\n' > /etc/resolv.conf
  else
    printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
  fi
  chattr +i /etc/resolv.conf 2>/dev/null || echo "注意: chattr +i 失败（文件系统不支持），resolv.conf 可能被覆盖，请留意。"
  # v0.1.6 item 2：接管后立刻用系统解析器验证（getent 优先），不谎称成功。
  # rc=1 时大声警告 + 给还原命令；rc=2（没工具）只警告，不 abort。
  TAKEOVER_VERIFY=0
  verify_system_dns example.com || TAKEOVER_VERIFY=$?
  # v0.1.6 item 1：默认只关 stub；验证仍不走 agent 时升级为彻底停用 resolved。
  if [ "$TAKEOVER_VERIFY" = 1 ] && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    echo "接管后系统解析仍不走 agent：升级处理，彻底停用 systemd-resolved（systemctl disable --now systemd-resolved）..."
    systemctl disable --now systemd-resolved 2>/dev/null || echo "警告: 停用 systemd-resolved 失败，靠文件锁兜底" >&2
    sleep 1
    TAKEOVER_VERIFY=0
    verify_system_dns example.com || TAKEOVER_VERIFY=$?
    if [ "$TAKEOVER_VERIFY" = 0 ]; then echo "升级后验证通过：停用 systemd-resolved 后系统解析已走 agent。"; fi
  fi
  if [ "$TAKEOVER_VERIFY" = 0 ]; then verify_rule_domain || true; fi
  if [ "$TAKEOVER_VERIFY" = 1 ]; then
    echo "!!!! 警告：接管后系统解析验证未通过——本机解析现在可能不走 agent，流量可能不走分流 !!!!"
    echo "!!!! 请检查 journalctl -u dnsunlock-agent，并用 getent hosts example.com / dig example.com A 复查；要回滚请运行：dnsunlock-restore-dns !!!!"
    echo "本机 DNS 已写入 127.0.0.1，但验证未通过（见上），还原命令: dnsunlock-restore-dns"
  elif [ "$TAKEOVER_VERIFY" = 2 ]; then
    echo "本机 DNS 已设为 127.0.0.1，但系统解析验证因缺工具未做（见上），请手动验证：getent hosts example.com；还原命令: dnsunlock-restore-dns"
  elif [ "${USE_VC:-0}" = "1" ]; then
    echo "本机 DNS 已设为 127.0.0.1（options use-vc：UDP 不通自动走 TCP），还原命令: dnsunlock-restore-dns"
  else
    echo "本机 DNS 已设为 127.0.0.1（UDP 直连 agent），还原命令: dnsunlock-restore-dns"
  fi
  # v0.1.6 V016-05：接管后复测 + 基线对比（失败只警告，不致命）。
  run_dnsunlock_check "复测（接管后）" "agent" "$AFTER_CHECK_FILE" || true
  print_check_comparison "$BASELINE_CHECK_FILE" "$AFTER_CHECK_FILE" || true
  CHECK_COMPARED=1
fi
fi # 非 Tailscale resolv.conf 的机器才问是否接管；Tailscale 的机器直接跳过
if [ "$CHECK_COMPARED" != "1" ]; then
  echo "（未接管：接管前基线见上，无复测对比；要复测可跑 /usr/local/bin/dnsunlock check --config /etc/dnsunlock/config.json --via agent）"
fi
# 一键还原脚本（无论是否接管都装上）
cat > /usr/local/bin/dnsunlock-restore-dns <<'RESTORE_EOF'
#!/usr/bin/env bash
# 一键还原 /etc/resolv.conf（与 install.sh 内嵌版本一致；install.sh 安装时也会生成一份到 /usr/local/bin/dnsunlock-restore-dns）。
# 同步办法：改完本文件跑 scripts/sync-restore.sh，再跑 scripts/check-restore-sync.sh 验证。
# 还原 /etc/resolv.conf 到接管前的原备份，并恢复 systemd-resolved / NetworkManager / resolvconf / dhclient / cloud-init / netplan。
# v0.1.6：结构化备份 /var/lib/dnsunlock/backup/<时间戳>_<标签>/ + metadata.txt；
# 还原默认选最早的一份（原始状态），还原前先自动备份当前状态，失败就中止；
# 还原后验证并报告“已还原并验证通过”或“已还原但验证未通过”。
# 老版本单份备份 /etc/dnsunlock/resolv.conf.orig 仍认（无备份目录时走老路）。
# 用法：dnsunlock-restore-dns [--yes] [--backup <备份目录>]
#   --yes     非交互：默认还原最早的一份，不再逐项确认（供 uninstall.sh 等脚本调用）
#   --backup  指定要还原的备份目录（须含 resolv.conf），与 --yes 合用可全程非交互
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }

BACKUP_ROOT="/var/lib/dnsunlock/backup"

ask_yes_no() {
  local ans=""
  if [ -r /dev/tty ]; then
    read -rp "$1 [y/N] " ans < /dev/tty || true
  fi
  case "$ans" in y|Y) return 0;; *) return 1;; esac
}

# v0.1.6 item 7：按默认路由接口取主网卡（无默认路由时取第一个 UP 的非 lo 网卡）。
get_primary_interface() {
  local dev
  dev=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
  if [ -n "$dev" ]; then echo "$dev"; return 0; fi
  ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | head -1
}

# v0.1.6 item 7：按默认路由接口取活动连接的 UUID（连接名含冒号会被截断），
# 无默认路由时回退取第一个活动连接（对应 AKDNS get_active_nm_connection_uuid）。
get_active_nm_connection_uuid() {
  local iface uuid
  command -v nmcli >/dev/null 2>&1 || return 1
  iface=$(get_primary_interface)
  if [ -n "$iface" ]; then
    uuid=$(nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null | awk -F: -v dev="$iface" '$2==dev {print $1; exit}')
    [ -n "$uuid" ] && { echo "$uuid"; return 0; }
  fi
  nmcli -t -f UUID connection show --active 2>/dev/null | head -1
}

# 与 install.sh 的 do_backup 同款（独立脚本，自带一份）：备份当前 DNS 状态。
# stdout 只输出备份目录路径，说明打到 stderr。失败返回 1。
# 注意：这份不做 install.sh 那边的 drop-in stash 逻辑——还原前备份拍的是
# 现状，live drop-in 就是现状，整目录照抄就是对的；stash 只在接管那次备份
# 里有意义（关 stub 在备份之前），由 install.sh 的 do_backup 处理。
do_backup() {
  local label="$1" ts dir n=0 dns="" backends=""
  ts=$(date +%Y%m%d-%H%M%S)
  dir="$BACKUP_ROOT/${ts}_${label}"
  while [ -e "$dir" ]; do n=$((n+1)); dir="$BACKUP_ROOT/${ts}_${label}-$n"; done
  mkdir -p "$dir" || return 1
  cp -L /etc/resolv.conf "$dir/resolv.conf" 2>/dev/null || { rm -rf "$dir"; return 1; }
  if [ -L /etc/resolv.conf ]; then readlink /etc/resolv.conf > "$dir/resolv.conf.symlink" 2>/dev/null || true; fi
  [ -f /etc/systemd/resolved.conf ] && cp -a /etc/systemd/resolved.conf "$dir/resolved.conf" 2>/dev/null || true
  [ -d /etc/systemd/resolved.conf.d ] && cp -a /etc/systemd/resolved.conf.d "$dir/resolved.conf.d" 2>/dev/null || true
  [ -d /etc/NetworkManager/conf.d ] && cp -a /etc/NetworkManager/conf.d "$dir/NetworkManager-conf.d" 2>/dev/null || true
  if ls /etc/netplan/*.yaml >/dev/null 2>&1; then mkdir -p "$dir/netplan" && cp -a /etc/netplan/*.yaml "$dir/netplan/" 2>/dev/null || true; fi
  [ -f /etc/nsswitch.conf ] && cp -a /etc/nsswitch.conf "$dir/nsswitch.conf" 2>/dev/null || true
  [ -f /etc/dnsunlock/nm-backup.txt ] && cp -a /etc/dnsunlock/nm-backup.txt "$dir/nm-backup.txt" 2>/dev/null || true
  [ -f /etc/dhcp/dhclient.conf ] && cp -a /etc/dhcp/dhclient.conf "$dir/dhclient.conf" 2>/dev/null || true
  [ -d /etc/cloud/cloud.cfg.d ] && cp -a /etc/cloud/cloud.cfg.d "$dir/cloud.cfg.d" 2>/dev/null || true
  dns=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
  if systemctl cat systemd-resolved.service >/dev/null 2>&1; then backends="resolved"; fi
  if command -v nmcli >/dev/null 2>&1; then backends="${backends:+$backends,}nm"; fi
  if command -v resolvconf >/dev/null 2>&1; then backends="${backends:+$backends,}resolvconf"; fi
  if ls /etc/netplan/*.yaml >/dev/null 2>&1; then backends="${backends:+$backends,}netplan"; fi
  {
    echo "timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "label=$label"
    echo "dns=$dns"
    echo "backends=$backends"
    if [ -L /etc/resolv.conf ]; then echo "resolv_symlink=$(readlink /etc/resolv.conf)"; else echo "resolv_symlink="; fi
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then echo "resolved_active=yes"; else echo "resolved_active=no"; fi
    if systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then echo "resolved_enabled=yes"; else echo "resolved_enabled=no"; fi
    if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then echo "nm_active=yes"; else echo "nm_active=no"; fi
    if systemctl is-enabled --quiet NetworkManager 2>/dev/null; then echo "nm_enabled=yes"; else echo "nm_enabled=no"; fi
    if systemctl is-active --quiet resolvconf 2>/dev/null; then echo "resolvconf_active=yes"; else echo "resolvconf_active=no"; fi
    if systemctl is-enabled --quiet resolvconf 2>/dev/null; then echo "resolvconf_enabled=yes"; else echo "resolvconf_enabled=no"; fi
    # v0.1.6 item 7：主连接记 UUID，不记连接名（连接名含冒号会被截断）。
    if command -v nmcli >/dev/null 2>&1; then echo "nm_primary_uuid=$(get_active_nm_connection_uuid 2>/dev/null || true)"; else echo "nm_primary_uuid="; fi
  } > "$dir/metadata.txt" || { rm -rf "$dir"; return 1; }
  echo "已备份当前 DNS 状态 -> $dir" >&2
  echo "$dir"
  return 0
}

meta_value() {
  sed -n "s/^$2=//p" "$1/metadata.txt" 2>/dev/null | head -1
}

# P1 (v0.1.6)：还原时 systemd-resolved 要重新绑 127.0.0.53:53 的 stub，
# 但 agent 还占着 :53（通配符绑定）——resolved 绑不上，日志里是
# "Turning off local DNS stub support"，系统 DNS 随之失效。
# 所以还原前必须先停 agent；还原后按需恢复，状态写死在输出里，不含糊。
AGENT_UNIT="dnsunlock-agent"
AGENT_WAS_ACTIVE=0
AGENT_WAS_ENABLED=0
AGENT_LISTEN=""

agent_unit_exists() {
  systemctl cat "$AGENT_UNIT.service" >/dev/null 2>&1 || \
    [ -f "/etc/systemd/system/$AGENT_UNIT.service" ] || \
    [ -f "/usr/lib/systemd/system/$AGENT_UNIT.service" ]
}

# 还原前记 agent 状态并停掉它。停不掉、或停完 :53 仍被占，就直接退出 1——
# 此时还没改任何文件（只做了还原前备份），比还原到一半才发现要强。
record_and_stop_agent() {
  AGENT_WAS_ACTIVE=0; AGENT_WAS_ENABLED=0; AGENT_LISTEN=""
  agent_unit_exists || return 0
  if systemctl is-enabled --quiet "$AGENT_UNIT" 2>/dev/null; then AGENT_WAS_ENABLED=1; fi
  if systemctl is-active --quiet "$AGENT_UNIT" 2>/dev/null; then AGENT_WAS_ACTIVE=1; fi
  [ "$AGENT_WAS_ACTIVE" = 1 ] || return 0
  if [ -f /etc/dnsunlock/config.json ]; then
    AGENT_LISTEN=$(sed -n 's/.*"dns_listen"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/dnsunlock/config.json | head -1)
  fi
  [ -n "$AGENT_LISTEN" ] || AGENT_LISTEN=":53"
  echo "还原前 agent 在运行（监听 $AGENT_LISTEN），先停掉它再重启 systemd-resolved（否则 resolved 抢不到 :53 的 stub）..."
  if ! systemctl stop "$AGENT_UNIT" 2>/dev/null; then
    echo "错误: 停 dnsunlock-agent 失败，还原已中止（未改任何文件）；请手动 systemctl stop dnsunlock-agent 后重跑" >&2
    exit 1
  fi
  # stop 是同步的，但多等一下确认 :53 真空出来了；ss 不存在就跳过这步。
  if command -v ss >/dev/null 2>&1; then
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      if ! ss -tuln 2>/dev/null | grep -qE ':53[[:space:]]'; then return 0; fi
      sleep 1
    done
    echo "错误: agent 已停，但 :53 仍被占（可能是别的服务），还原已中止（未改任何文件）；请先处理占 :53 的服务后重跑" >&2
    exit 1
  fi
  return 0
}

# 还原后按需恢复 agent（状态写死，不含糊）。
# agent 监听 :53（通配符）时起不回来：systemd-resolved 已重新占住
# 127.0.0.53:53，通配符 :53 绑不上（EADDRINUSE）。这时保持停止并明说，
# 要再用 agent 分流就重跑安装脚本（安装时会重新关掉 stub 并接管）。
# 监听是具体地址（127.0.0.1:53、127.0.0.1:5353 等）时不冲突，直接起回来。
restore_agent_after() {
  agent_unit_exists || return 0
  if [ "$AGENT_WAS_ACTIVE" != 1 ]; then
    echo "agent 还原前未在运行，保持停止（未改动）。"
    return 0
  fi
  case "$AGENT_LISTEN" in
    :53|0.0.0.0:53|[::]:53)
      echo "agent 还原前在运行（监听 $AGENT_LISTEN），现保持停止：systemd-resolved 已重新占用 :53（stub 127.0.0.53），agent 的通配符 :53 无法同时绑定。"
      echo "如需继续用 agent 分流，请重新执行安装脚本（它会重新关掉 stub 并接管）；只想恢复系统 DNS 的话，现在已经好了。"
      ;;
    *)
      echo "agent 还原前在运行（监听 $AGENT_LISTEN），正在恢复..."
      if systemctl start "$AGENT_UNIT" 2>/dev/null && systemctl is-active --quiet "$AGENT_UNIT" 2>/dev/null; then
        echo "agent 已恢复运行（监听 $AGENT_LISTEN）。"
      else
        echo "警告: agent 恢复启动失败（监听 $AGENT_LISTEN），系统 DNS 不受影响；请看 journalctl -u dnsunlock-agent" >&2
      fi
      ;;
  esac
}

# 还原后验证（getent 优先，走系统解析器；缺 getent 回退 dig；都没工具只报告）。
# 只报告结果，不决定退出码（文件已还原，验证失败只说明 DNS 可能仍有问题）。
verify_after_restore() {
  if command -v getent >/dev/null 2>&1; then
    if getent hosts example.com >/dev/null 2>&1; then echo "已还原并验证通过（getent hosts example.com 有结果）"; return 0; fi
    echo "已还原但验证未通过（getent hosts example.com 无结果，请检查 DNS 配置）" >&2
    return 0
  fi
  if command -v dig >/dev/null 2>&1; then
    if dig +short example.com A 2>/dev/null | grep -qE '^[0-9]+\.'; then echo "已还原并验证通过（dig example.com 有结果）"; return 0; fi
    echo "已还原但验证未通过（dig example.com 无结果，请检查 DNS 配置）" >&2
    return 0
  fi
  echo "已还原（无 getent/dig，验证未做，请手动验证：getent hosts example.com）"
  return 0
}

# 旧方式 NM 逐连接还原（备份里有 nm-backup.txt 时才做；v0.1.6 新方式接管不写它。
# v0.1.6 item 7：按 UUID 操作。nm-backup.txt 新格式记 UUID；老文件记的是连接名
#（可能含冒号），按名操作作兼容。UUID 形状的条目先核对该 UUID 是否还存在，
#不存在就跳过并报错，不静默按名去碰另一个连接）。
restore_nm_legacy() {
  local file="$1" id=""
  while IFS='|' read -r CON OLD4 OLD6; do
    [ -z "$CON" ] && continue
    if command -v nmcli >/dev/null 2>&1; then
      id="$CON"
      case "$CON" in
        ????????-????-????-????-????????????)
          if ! nmcli -g UUID connection show "$CON" 2>/dev/null | grep -qx "$CON"; then
            echo "NetworkManager: 备份里的连接 UUID $CON 已不存在，跳过（原值 IPv4='$OLD4' IPv6='$OLD6'）" >&2
            continue
          fi
          ;;
      esac
      # P1-09：原值为空 = 当时没手动设 DNS，显式传空值清空；失败要报错，
      # 不能用 || true 静默吞掉（原值记在 nm-backup.txt 里，见报错信息）。
      if ! nmcli connection modify "$id" ipv4.dns "${OLD4:-}" ipv4.ignore-auto-dns no ipv6.dns "${OLD6:-}" ipv6.ignore-auto-dns no 2>/dev/null; then
        echo "NetworkManager: 还原 $id 的 DNS 失败，请手动检查（原值 IPv4='$OLD4' IPv6='$OLD6'）" >&2
      fi
      nmcli connection up "$id" 2>/dev/null || echo "NetworkManager: 重新启用 $id 失败" >&2
    fi
  done < "$file"
}

# v0.1.6 item 8：按后端重载（对应 AKDNS reload_dns_service）。
# 单个后端一个分支：restart resolved / nmcli con reload + 重新激活连接 /
# netplan apply / resolv.conf 直接生效；失败只警告，不致命。
reload_dns_service() {
  local backend="$1" dir="$2"
  case "$backend" in
    resolved)
      if [ "$(meta_value "$dir" resolved_active)" = "yes" ]; then
        systemctl restart systemd-resolved 2>/dev/null || echo "警告: 重启 systemd-resolved 失败" >&2
      else
        echo "跳过 resolved 重载（备份时未在跑）"
      fi
      ;;
    nm)
      if [ "$(meta_value "$dir" nm_active)" = "yes" ] && command -v nmcli >/dev/null 2>&1; then
        nmcli general reload 2>/dev/null || echo "警告: nmcli general reload 失败" >&2
        # 重新激活活动连接（按 UUID；连接名含冒号会被截断，见 item 7）
        nmcli -t -f UUID connection show --active 2>/dev/null | while IFS= read -r uuid; do
          [ -n "$uuid" ] || continue
          nmcli connection up "$uuid" 2>/dev/null || echo "警告: 重新激活 NM 连接 $uuid 失败" >&2
        done
      else
        echo "跳过 NM 重载（备份时未在跑或无 nmcli）"
      fi
      ;;
    netplan)
      netplan apply 2>/dev/null || echo "警告: netplan apply 失败" >&2
      ;;
    resolvconf)
      if [ "$(meta_value "$dir" resolvconf_active)" = "yes" ]; then
        resolvconf -u 2>/dev/null || echo "警告: resolvconf -u 失败" >&2
      else
        echo "跳过 resolvconf 重载（备份时未在跑）"
      fi
      ;;
    *)
      # resolv.conf 直接生效，无需重载；未知后端只警告，不致命。
      echo "警告: 未知后端 $backend，跳过重载" >&2
      ;;
  esac
}

# 按备份里记的后端逐个分发重载。只重载备份时在跑的后端：
# 原来没跑的管理器不替用户启动。
# 注意：本函数在 resolv.conf 恢复之前跑，管理器重载时若改写 resolv.conf，
# 后面恢复 resolv.conf 的步骤会把它盖回去，所以最终内容以备份为准。
reload_backends() {
  local dir="$1" backends="" b="" _rl_backends=()
  backends=$(meta_value "$dir" backends)
  if [ -z "$backends" ]; then
    # 无 metadata 的老备份：按老脚本的 blanket 做法全量重载（失败只警告）。
    systemctl restart systemd-resolved 2>/dev/null || true
    resolvconf -u 2>/dev/null || true
    netplan apply 2>/dev/null || true
    return 0
  fi
  IFS=',' read -ra _rl_backends <<< "$backends"
  for b in "${_rl_backends[@]}"; do
    reload_dns_service "$b" "$dir"
  done
}

# 从结构化备份目录还原。顺序：先恢复各后端文件 → 重新启用之前开着的管理器 →
# 按后端重载 → 最后恢复 resolv.conf（保证没有任何管理器在之后再改写它）。
restore_from_dir() {
  local dir="$1" link="" target=""
  echo "从备份还原: $dir（$(meta_value "$dir" label)，$(meta_value "$dir" timestamp)）"
  # P1 (v0.1.6)：先停 agent 再动 resolved，否则 resolved 抢不到 :53 的 stub。
  record_and_stop_agent
  chattr -i /etc/resolv.conf 2>/dev/null || true
  # 1. 删本次接管写的 NM dns=none 配置（备份里若有同名文件，下面会按备份恢复）。
  rm -f /etc/NetworkManager/conf.d/dnsunlock.conf
  # 2. 恢复各后端文件（只恢复备份里有的）。
  if [ -f "$dir/resolved.conf" ]; then cp -a "$dir/resolved.conf" /etc/systemd/resolved.conf 2>/dev/null || echo "警告: 恢复 /etc/systemd/resolved.conf 失败" >&2; fi
  # resolved drop-in：备份里有 stash（接管时 disable_stub_listener 记的
  # 接管前状态）就按 stash 来——之前没有 → 删掉接管写的；之前有 → 恢复原
  # 内容。老备份无 stash 时按备份目录里的 resolved.conf.d 来（目录里有就
  # 是接管前已有，没有就是接管前没有）。注意：stash 只在 install.sh 的接
  # 管备份里产生；还原前备份拍的是现状，不带 stash，走目录分支。
  if [ -f "$dir/resolved-dropin.absent" ]; then
    rm -f /etc/systemd/resolved.conf.d/dnsunlock.conf
    if [ -d "$dir/resolved.conf.d" ]; then mkdir -p /etc/systemd/resolved.conf.d; cp -a "$dir/resolved.conf.d/." /etc/systemd/resolved.conf.d/ 2>/dev/null || echo "警告: 恢复 resolved.conf.d 失败" >&2; fi
  elif [ -f "$dir/resolved-dropin.orig" ]; then
    mkdir -p /etc/systemd/resolved.conf.d
    cp -a "$dir/resolved-dropin.orig" /etc/systemd/resolved.conf.d/dnsunlock.conf 2>/dev/null || echo "警告: 恢复 resolved drop-in 原内容失败" >&2
    if [ -d "$dir/resolved.conf.d" ]; then cp -a "$dir/resolved.conf.d/." /etc/systemd/resolved.conf.d/ 2>/dev/null || echo "警告: 恢复 resolved.conf.d 失败" >&2; fi
  elif [ -d "$dir/resolved.conf.d" ]; then
    rm -f /etc/systemd/resolved.conf.d/dnsunlock.conf
    cp -a "$dir/resolved.conf.d/." /etc/systemd/resolved.conf.d/ 2>/dev/null || echo "警告: 恢复 resolved.conf.d 失败" >&2
  else
    rm -f /etc/systemd/resolved.conf.d/dnsunlock.conf
  fi
  if [ -d "$dir/NetworkManager-conf.d" ]; then
    cp -a "$dir/NetworkManager-conf.d/." /etc/NetworkManager/conf.d/ 2>/dev/null || echo "警告: 恢复 NetworkManager conf.d 失败" >&2
  fi
  if [ -f "$dir/nsswitch.conf" ]; then cp -a "$dir/nsswitch.conf" /etc/nsswitch.conf 2>/dev/null || echo "警告: 恢复 nsswitch.conf 失败" >&2; fi
  if [ -d "$dir/netplan" ]; then
    for f in "$dir/netplan"/*.yaml; do [ -e "$f" ] || continue; cp -a "$f" "/etc/netplan/$(basename "$f")" 2>/dev/null || echo "警告: 恢复 netplan $(basename "$f") 失败" >&2; done
  fi
  if [ -f "$dir/dhclient.conf" ]; then cp -a "$dir/dhclient.conf" /etc/dhcp/dhclient.conf 2>/dev/null || echo "警告: 恢复 dhclient.conf 失败" >&2; fi
  if [ -d "$dir/cloud.cfg.d" ]; then
    rm -f /etc/cloud/cloud.cfg.d/99-dnsunlock.cfg
    cp -a "$dir/cloud.cfg.d/." /etc/cloud/cloud.cfg.d/ 2>/dev/null || echo "警告: 恢复 cloud.cfg.d 失败" >&2
  else
    rm -f /etc/cloud/cloud.cfg.d/99-dnsunlock.cfg
  fi
  rm -f /etc/resolvconf/resolv.conf.d/head.dnsunlock
  # 3. 旧方式 NM 逐连接还原（备份里有 nm-backup.txt 时才做）。
  if [ -f "$dir/nm-backup.txt" ]; then restore_nm_legacy "$dir/nm-backup.txt"; fi
  # 4. 重新启用之前开着的管理器（按备份 metadata）。
  if [ "$(meta_value "$dir" resolved_enabled)" = "yes" ]; then
    systemctl enable --now systemd-resolved 2>/dev/null || echo "警告: 重新启用 systemd-resolved 失败" >&2
  fi
  if [ "$(meta_value "$dir" resolvconf_enabled)" = "yes" ]; then
    systemctl enable --now resolvconf 2>/dev/null || echo "警告: 重新启用 resolvconf 失败" >&2
  fi
  # 5. 按后端重载。
  reload_backends "$dir"
  # 6. 最后恢复 resolv.conf（原先是符号链接就先恢复链接）。
  rm -f /etc/resolv.conf
  if [ -f "$dir/resolv.conf.symlink" ]; then
    link=$(cat "$dir/resolv.conf.symlink")
    ln -s "$link" /etc/resolv.conf
    # P1-09：原 resolv.conf 是软链时，只恢复软链不够——若目标文件已被删，
    # 软链就指向空洞。目标不存在时，把备份的内容写回目标文件。
    case "$link" in /*) target="$link" ;; *) target="/etc/$link" ;; esac
    if [ ! -e "$target" ]; then
      cp -L "$dir/resolv.conf" "$target" 2>/dev/null || echo "注意: 软链目标 $target 已不存在且写回失败，请手动恢复" >&2
      echo "已还原软链 /etc/resolv.conf -> $link，并把备份内容写回目标 $target"
    else
      echo "已还原软链 /etc/resolv.conf -> $link（目标文件仍在，内容以目标为准）"
    fi
  else
    cp -L "$dir/resolv.conf" /etc/resolv.conf
    echo "已还原 /etc/resolv.conf <- $dir/resolv.conf"
  fi
}

# 老路：无结构化备份目录，只有单份 /etc/dnsunlock/resolv.conf.orig（老版本接管）。
restore_legacy() {
  # P1 (v0.1.6)：先停 agent 再动 resolved，否则 resolved 抢不到 :53 的 stub。
  record_and_stop_agent
  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/systemd/resolved.conf.d/dnsunlock.conf
  systemctl restart systemd-resolved 2>/dev/null || true
  if [ -f /etc/dnsunlock/nm-backup.txt ]; then
    restore_nm_legacy /etc/dnsunlock/nm-backup.txt
  fi
  rm -f /etc/resolvconf/resolv.conf.d/head.dnsunlock
  resolvconf -u 2>/dev/null || true
  if [ -f /etc/dnsunlock/dhclient.conf.bak ]; then cp -a /etc/dnsunlock/dhclient.conf.bak /etc/dhcp/dhclient.conf; fi
  rm -f /etc/cloud/cloud.cfg.d/99-dnsunlock.cfg
  for f in /etc/dnsunlock/*.yaml.bak; do [ -e "$f" ] || continue; cp -a "$f" "/etc/netplan/$(basename "$f" .bak)"; done
  netplan apply 2>/dev/null || true
  rm -f /etc/resolv.conf
  if [ -f /etc/dnsunlock/resolv.conf.orig.link ]; then
    LINK=$(cat /etc/dnsunlock/resolv.conf.orig.link)
    ln -s "$LINK" /etc/resolv.conf
    # P1-09：原 resolv.conf 是软链时，只恢复软链不够——若目标文件已被删，
    # 软链就指向空洞。目标不存在时，把备份的内容写回目标文件。
    case "$LINK" in /*) TARGET="$LINK" ;; *) TARGET="/etc/$LINK" ;; esac
    if [ ! -e "$TARGET" ]; then
      cp -L /etc/dnsunlock/resolv.conf.orig "$TARGET" 2>/dev/null || echo "注意: 软链目标 $TARGET 已不存在且写回失败，请手动恢复" >&2
      echo "已还原软链 /etc/resolv.conf -> $LINK，并把备份内容写回目标 $TARGET"
    else
      echo "已还原软链 /etc/resolv.conf -> $LINK（目标文件仍在，内容以目标为准）"
    fi
  else
    cp -L /etc/dnsunlock/resolv.conf.orig /etc/resolv.conf
  fi
  echo "已还原 /etc/resolv.conf <- /etc/dnsunlock/resolv.conf.orig"
}

# ---- 参数 ----
YES=0
WANT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift;;
    --backup) WANT_DIR="$2"; shift 2;;
    --help|-h)
      echo "用法: dnsunlock-restore-dns [--yes] [--backup <备份目录>]"
      echo "  --yes     非交互：默认还原最早的一份（原始状态），不再逐项确认"
      echo "  --backup  指定要还原的备份目录（须含 resolv.conf）"
      exit 0;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

# ---- 选备份 ----
CHOSEN=""
if [ -n "$WANT_DIR" ]; then
  [ -d "$WANT_DIR" ] && [ -f "$WANT_DIR/resolv.conf" ] || { echo "备份目录不存在或不完整: $WANT_DIR"; exit 1; }
  CHOSEN="$WANT_DIR"
elif ls -d "$BACKUP_ROOT"/*/ >/dev/null 2>&1; then
  DIRS=()
  for d in "$BACKUP_ROOT"/*/; do [ -d "$d" ] || continue; DIRS+=("${d%/}"); done
  COUNT=${#DIRS[@]}
  echo "可用的备份（时间倒序）："
  i=$COUNT
  while [ "$i" -ge 1 ]; do
    d="${DIRS[$((i-1))]}"
    n=$((COUNT - i + 1))
    echo "  [$n] $(meta_value "$d" timestamp)  $(meta_value "$d" label)  DNS: $(meta_value "$d" dns)  $d"
    i=$((i-1))
  done
  if [ "$YES" = 1 ]; then
    CHOSEN="${DIRS[0]}"
    echo "非交互模式：默认还原最早的一份（原始状态）: $CHOSEN"
  else
    if [ ! -r /dev/tty ] && [ ! -t 0 ]; then
      echo "没有可交互的终端来选备份：请加 --yes（默认还原最早的一份）或 --backup <备份目录> --yes"
      exit 1
    fi
    SEL=""
    if [ -r /dev/tty ]; then read -rp "选编号 [默认 $COUNT=最早的一份，即原始状态]: " SEL < /dev/tty || true
    else read -rp "选编号 [默认 $COUNT=最早的一份，即原始状态]: " SEL || true; fi
    [ -z "$SEL" ] && SEL=$COUNT
    case "$SEL" in ''|*[!0-9]*) echo "编号不对: $SEL"; exit 1;; esac
    [ "$SEL" -ge 1 ] && [ "$SEL" -le "$COUNT" ] || { echo "编号超出范围: $SEL"; exit 1; }
    CHOSEN="${DIRS[$((COUNT - SEL))]}"
    echo "已选: $CHOSEN（$(meta_value "$CHOSEN" label)，$(meta_value "$CHOSEN" timestamp)）"
  fi
fi

if [ -n "$CHOSEN" ]; then
  # 确认（--yes 跳过）。
  if [ "$YES" != 1 ]; then
    ask_yes_no "确认还原到 $CHOSEN 吗？还原前会自动备份当前状态。" || { echo "已取消还原"; exit 0; }
  fi
  # 还原前先自动备份当前状态，备份失败就中止。
  PRE_DIR=$(do_backup "pre-restore") || { echo "还原前自动备份当前状态失败，已中止还原（未改任何文件）"; exit 1; }
  echo "还原前已自动备份当前状态 -> $PRE_DIR"
  restore_from_dir "$CHOSEN"
  verify_after_restore
  restore_agent_after
  exit 0
fi

# 无结构化备份：走老路（单份 .orig）或提示无需还原。
if [ -e /etc/dnsunlock/resolv.conf.orig ]; then
  echo "未找到结构化备份，走老路还原单份备份 /etc/dnsunlock/resolv.conf.orig"
  if [ "$YES" != 1 ]; then
    ask_yes_no "确认还原到 /etc/dnsunlock/resolv.conf.orig 吗？还原前会自动备份当前状态。" || { echo "已取消还原"; exit 0; }
  fi
  PRE_DIR=$(do_backup "pre-restore") || { echo "还原前自动备份当前状态失败，已中止还原（未改任何文件）"; exit 1; }
  echo "还原前已自动备份当前状态 -> $PRE_DIR"
  restore_legacy
  verify_after_restore
  restore_agent_after
  exit 0
fi
echo "没有找到永久备份（/var/lib/dnsunlock/backup/ 下无备份，也无 /etc/dnsunlock/resolv.conf.orig）。"
echo "如果你用的是 --temp 临时模式：临时 DNS 没有永久备份可还，清理办法："
echo "  - systemd-resolved 的机器：systemctl restart systemd-resolved（resolvectl 设的 DNS 即失效）"
echo "  - DHCP 的机器：重新拉 DHCP（如 dhclient -r; dhclient，或重启 NetworkManager）"
echo "  - 或手动把 /etc/resolv.conf 改回原来的 DNS（临时模式直接写文件时若原先是软链，需手动恢复软链）"
echo "临时模式重启后自动失效，不用专门清理也可以等重启。"
exit 0
RESTORE_EOF
chmod +x /usr/local/bin/dnsunlock-restore-dns

echo
echo "=== 安装完成 ==="
echo "面板: $PANEL_URL  (分流规则改动后约 5 秒生效)"
[ "$PANEL_BASE" != "$PANEL_URL" ] && echo "本次安装实际走的是 $PANEL_BASE（443 不通自动走 :8080）；agent 配置里记的也是 $PANEL_BASE（运行时会试它及其 :8080 变体）。"
echo "DNS 监听: $DNS_LISTEN"
echo "测试: dig @$_dl_host -p $_dl_port netflix.com A    # 应返回规则里配的解锁 IP"
echo "      dig @$_dl_host -p $_dl_port example.com A    # 应返回真实上游 IP"
echo "日志: journalctl -u dnsunlock-agent -f     # 注意: 无查询日志, 只有计数与探活"
