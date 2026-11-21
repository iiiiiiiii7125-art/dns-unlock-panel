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
set -euo pipefail

PANEL_URL="__PANEL_URL__"
TOKEN=""
MODE="dns"
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
pick_fastest_ip() {
  local best="" ip ok
  IFS=',' read -ra IPS <<< "$1"
  for ip in "${IPS[@]}"; do
    ip="$(echo "$ip" | tr -d ' ')"
    [ -z "$ip" ] && continue
    if timeout 3 bash -c "echo > /dev/tcp/$ip/443" 2>/dev/null; then
      echo "  测速 $ip :443 -> 通"
      [ -z "$best" ] && best="$ip"
    else
      echo "  测速 $ip :443 -> 不通"
    fi
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
    --unlock-ips) UNLOCK_IPS="$2"; shift 2;;
    --allowlist) ALLOWLIST="$2"; shift 2;;
    # P1-REAL-01：监听地址终于有了真实入口（命令行优先于 DNS_LISTEN 环境变量）。
    --dns-listen) DNS_LISTEN="$2"; shift 2;;
    --help|-h)
      echo "用法: bash install.sh [--panel URL] [--dns-listen ADDR] [--allowlist IPS] [--unlock-node]"
      echo "  --panel URL         面板地址（默认已 baked；443 不通时自动改走同主机 :8080，也可直接指定内网地址）"
      echo "  --dns-listen ADDR   DNS 监听地址，默认 :53；如 127.0.0.1:5353（也可设 DNS_LISTEN 环境变量）"
      echo "  --allowlist IPS     允许使用本 DNS 的客户端 IP/CIDR，逗号分隔（必填）"
      echo "  --unlock-node       只装 SNI 解锁节点，不装 DNS 分流服务"
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
# 注意：缺 dig 只在这里可降级；测速环节缺 dig 仍是致命的（两处不要混淆）。
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
  curl -fsSL -K "$AUTH_CFG" --max-time 8 "$PANEL_BASE/api/v1/agent/config" -o "$cfg" 2>/dev/null || { echo "  规则域名验证跳过: 拉不到 agent 配置（稍后手动验证规则域名）"; return 2; }
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

# v0.1.3 容错：面板 443 被挡时不要硬等 134 秒。候选顺序：
# (a) 配置的 PANEL_URL 本身，(b) 同一主机 http :8080（面板本身一直监听
# :8080，443 只是 Caddy 的反代），(c) 同一主机解析出的 IP :8080。
# 每个候选只探一次（--max-time 8）；任何 HTTP 响应都算通（没 token 的
# whoami 回 401 也算，说明到面板了）。成功时 stdout 只输出选中的地址，
# 诊断打到 stderr。都不通返回 1。
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
  for cand in "${uniq[@]}"; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "$cand/api/v1/agent/whoami" 2>/dev/null || true)
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      echo "$cand"
      return 0
    fi
    echo "  探测 $cand -> 不通（HTTP ${code:-000}）" >&2
  done
  echo "面板都连不上，试过：${uniq[*]}" >&2
  echo "请检查面板是否在运行；如果 443 被挡，可用 --panel 指定面板机的内网地址，如：bash install.sh --panel http://<面板机内网IP>:8080；面板和 agent 在同一台机器上时可用 --panel http://127.0.0.1:8080" >&2
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
# PANEL_URL 是登记的规范地址（写进配置文件，agent 运行时自己也会逐个试）；
# PANEL_BASE 是本次安装实际用的地址。
PANEL_BASE="$(probe_panel "$PANEL_URL")" || exit 1
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
  "panel_url": "$PANEL_URL",
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
  if dig +short "@$_dl_host" -p "$_dl_port" example.com A | grep -qE '^[0-9]+\.'; then echo "  验证通过: example.com 能走上游解析"; else echo "  验证失败: example.com 解析无结果，请看 journalctl -u dnsunlock-agent"; exit 1; fi
  echo "  提示: 再测一条已设规则的域名，如 dig @$_dl_host -p $_dl_port netflix.com A，应返回规则里配的解锁 IP（未设规则时走上游属正常）。"
else
  # v0.1.6 item 2：缺 dig 不再 exit 1——区分“测不了”和“测了不通”。
  # 测不了只警告 + 继续安装（接管步必须能跑到）；dig 在但解析无结果仍是硬失败（见上）。
  # 注意：测速环节缺 dig 仍是致命的（见 pick_fastest_ip / run_speed_test 的约定），只在应用后验证环节可降级。
  echo "  警告: 未装 dig，无法自动验证解析，继续安装（agent 本身不受影响）。"
  echo "  请手动验证：dig @$_dl_host -p $_dl_port example.com A（装 dig：Debian/Ubuntu 用 apt-get install -y dnsutils，RHEL/CentOS 用 yum install -y bind-utils）"
  echo "  也可不用 dig：getent hosts example.com（走系统解析器；接管后才有效）"
fi

# 6. 可选: 把本机系统 DNS 设为 127.0.0.1（默认不做，需确认）。
# P1-REAL-01 补充：resolv.conf 由 Tailscale 生成的机器绝对不接管——
# Tailscale 的 DNS（100.100.100.100）一旦被覆盖，内网机器就连不上了。
if grep -qi "tailscale" /etc/resolv.conf 2>/dev/null || grep -q "nameserver 100.100.100.100" /etc/resolv.conf 2>/dev/null; then
  echo
  echo "注意: 检测到 /etc/resolv.conf 由 Tailscale 生成，本机不做 DNS 接管（接管会断 Tailscale 内网 DNS）。"
  echo "如需本机流量也走分流，请手动把其他机器的 DNS 指到本机，或在 Tailscale 之外再处理。"
else
echo
ask TAKEOVER "是否把本机系统 DNS 设为 127.0.0.1 (本机流量也走分流)? [y/N] "
if [ "${TAKEOVER:-}" = "y" ] || [ "${TAKEOVER:-}" = "Y" ]; then
  # 只备一次原文件：已存在 .orig 就不再覆盖（P1-09：二次接管丢原备份）。
  if [ ! -e /etc/dnsunlock/resolv.conf.orig ]; then
    cp -L /etc/resolv.conf /etc/dnsunlock/resolv.conf.orig
    if [ -L /etc/resolv.conf ]; then readlink /etc/resolv.conf > /etc/dnsunlock/resolv.conf.orig.link; fi
    echo "已备份 /etc/resolv.conf 内容 -> /etc/dnsunlock/resolv.conf.orig（只备一次原文件）"
  else
    echo "已有原备份 /etc/dnsunlock/resolv.conf.orig，不再覆盖。"
  fi
  # systemd-resolved
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/dnsunlock.conf
    systemctl restart systemd-resolved
    echo "systemd-resolved: 已关 stub 监听 (drop-in 可删: /etc/systemd/resolved.conf.d/dnsunlock.conf)"
  fi
  # NetworkManager：改全部活动连接，含 IPv6，并记原值以便还原。
  if command -v nmcli >/dev/null 2>&1; then
    : > /etc/dnsunlock/nm-backup.txt
    while IFS= read -r CON; do
      [ -z "$CON" ] && continue
      OLD4=$(nmcli -g ipv4.dns connection show "$CON" 2>/dev/null || true)
      OLD6=$(nmcli -g ipv6.dns connection show "$CON" 2>/dev/null || true)
      echo "$CON|$OLD4|$OLD6" >> /etc/dnsunlock/nm-backup.txt
      nmcli connection modify "$CON" ipv4.dns "127.0.0.1" ipv4.ignore-auto-dns yes ipv6.dns "127.0.0.1" ipv6.ignore-auto-dns yes 2>/dev/null || echo "NetworkManager: 修改 $CON 失败, 请手动设 DNS 127.0.0.1"
      nmcli connection up "$CON" 2>/dev/null || true
      echo "NetworkManager: 已把 $CON 的 DNS 设为 127.0.0.1（含 IPv6）"
    done <<EOF_NM
$(nmcli -t -f NAME connection show --active 2>/dev/null)
EOF_NM
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
  printf 'nameserver 127.0.0.1\noptions use-vc\n' > /etc/resolv.conf
  chattr +i /etc/resolv.conf 2>/dev/null || echo "注意: chattr +i 失败（文件系统不支持），resolv.conf 可能被覆盖，请留意。"
  # v0.1.6 item 2：接管后立刻用系统解析器验证（getent 优先），不谎称成功。
  # rc=1 时大声警告 + 给还原命令；rc=2（没工具）只警告，不 abort。
  TAKEOVER_VERIFY=0
  verify_system_dns example.com || TAKEOVER_VERIFY=$?
  if [ "$TAKEOVER_VERIFY" = 0 ]; then verify_rule_domain || true; fi
  if [ "$TAKEOVER_VERIFY" = 1 ]; then
    echo "!!!! 警告：接管后系统解析验证未通过——本机解析现在可能不走 agent，流量可能不走分流 !!!!"
    echo "!!!! 请检查 journalctl -u dnsunlock-agent，并用 getent hosts example.com / dig example.com A 复查；要回滚请运行：dnsunlock-restore-dns !!!!"
    echo "本机 DNS 已写入 127.0.0.1，但验证未通过（见上），还原命令: dnsunlock-restore-dns"
  elif [ "$TAKEOVER_VERIFY" = 2 ]; then
    echo "本机 DNS 已设为 127.0.0.1，但系统解析验证因缺工具未做（见上），请手动验证：getent hosts example.com；还原命令: dnsunlock-restore-dns"
  else
    echo "本机 DNS 已设为 127.0.0.1（options use-vc：UDP 不通自动走 TCP），还原命令: dnsunlock-restore-dns"
  fi
fi
fi # 非 Tailscale resolv.conf 的机器才问是否接管；Tailscale 的机器直接跳过
# 一键还原脚本（无论是否接管都装上）
cat > /usr/local/bin/dnsunlock-restore-dns <<'RESTORE_EOF'
#!/usr/bin/env bash
# 还原 /etc/resolv.conf 到接管前的原备份，并恢复 systemd-resolved / NetworkManager / resolvconf / dhclient / cloud-init / netplan。
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
[ -e /etc/dnsunlock/resolv.conf.orig ] || { echo "没有找到原备份 /etc/dnsunlock/resolv.conf.orig，无需还原"; exit 0; }
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/systemd/resolved.conf.d/dnsunlock.conf
systemctl restart systemd-resolved 2>/dev/null || true
if [ -f /etc/dnsunlock/nm-backup.txt ]; then
  while IFS='|' read -r CON OLD4 OLD6; do
    [ -z "$CON" ] && continue
    if command -v nmcli >/dev/null 2>&1; then
      # P1-09：原值为空 = 当时没手动设 DNS，显式传空值清空；失败要报错，
      # 不能用 || true 静默吞掉（原值记在 nm-backup.txt 里，见报错信息）。
      if ! nmcli connection modify "$CON" ipv4.dns "${OLD4:-}" ipv4.ignore-auto-dns no ipv6.dns "${OLD6:-}" ipv6.ignore-auto-dns no 2>/dev/null; then
        echo "NetworkManager: 还原 $CON 的 DNS 失败，请手动检查（原值 IPv4='$OLD4' IPv6='$OLD6'）" >&2
      fi
      nmcli connection up "$CON" 2>/dev/null || echo "NetworkManager: 重新启用 $CON 失败" >&2
    fi
  done < /etc/dnsunlock/nm-backup.txt
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
RESTORE_EOF
chmod +x /usr/local/bin/dnsunlock-restore-dns

echo
echo "=== 安装完成 ==="
echo "面板: $PANEL_URL  (分流规则改动后约 5 秒生效)"
[ "$PANEL_BASE" != "$PANEL_URL" ] && echo "本次安装实际走的是 $PANEL_BASE（443 不通自动走 :8080）；agent 配置里仍记 $PANEL_URL，运行时会自动试两个地址。"
echo "DNS 监听: $DNS_LISTEN"
echo "测试: dig @$_dl_host -p $_dl_port netflix.com A    # 应返回规则里配的解锁 IP"
echo "      dig @$_dl_host -p $_dl_port example.com A    # 应返回真实上游 IP"
echo "日志: journalctl -u dnsunlock-agent -f     # 注意: 无查询日志, 只有计数与探活"
