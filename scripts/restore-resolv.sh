#!/usr/bin/env bash
# 一键还原 /etc/resolv.conf（与 install.sh 内嵌版本一致；install.sh 安装时也会生成一份到 /usr/local/bin/dnsunlock-restore-dns）。
# 同步办法：改完本文件跑 scripts/sync-restore.sh，再跑 scripts/check-restore-sync.sh 验证。
# 还原 /etc/resolv.conf 到接管前的原备份，并恢复 systemd-resolved / NetworkManager / resolvconf / dhclient / cloud-init / netplan。
# v0.1.6：结构化备份 /var/lib/dnsunlock/backup/<时间戳>_<标签>/ + metadata.txt；
# 还原默认选最早的一份（原始状态），还原前先自动备份当前状态，失败就中止；
# 还原后验证并报告“已还原并验证通过”或“已还原但验证未通过”。
# 老版本单份备份 /etc/dnsunlock/resolv.conf.orig 仍认（无备份目录时走老路）。
# 用法：dnsunlock-restore-dns [--yes] [--backup <备份目录>] [--temp-cleanup] [--boot]
#   --yes     非交互：默认还原最早的一份，不再逐项确认（供 uninstall.sh 等脚本调用）
#   --backup  指定要还原的备份目录（须含 resolv.conf），与 --yes 合用可全程非交互
#   --temp-cleanup  只清理 --temp 临时模式留下的运行时 DNS；清理失败返回 1（状态已保留）
#   --boot    与 --temp-cleanup 合用（开机 oneshot unit 用）：清理失败也返回 0
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
AGENT_NO_UNIT=0
PENDING_MARKER="/etc/dnsunlock/agent-restore-pending"
PRE_RESTORE_BACKUP=""

agent_unit_exists() {
  systemctl cat "$AGENT_UNIT.service" >/dev/null 2>&1 || \
    [ -f "/etc/systemd/system/$AGENT_UNIT.service" ] || \
    [ -f "/usr/lib/systemd/system/$AGENT_UNIT.service" ]
}

# --- :53 监听地址解析（V016-02）---
# ss_listen_53_p：输出当前所有 :53 监听行，格式“地址<TAB>users 字段（可能为空）”，
# 去重。users 字段来自 ss -tulnp，用于分辨监听归属（dnsunlock 自己 vs 别的进程）。
ss_listen_53_p() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -tulnp 2>/dev/null | awk '$1 ~ /^(udp|tcp)/ && $5 ~ /:53$/ {u=""; for (i=7;i<=NF;i++) u=u $i " "; sub(/ $/,"",u); print $5 "\t" u}' | sort -u
}

# R2-03：ss 输出的监听地址可能带接口后缀（如 127.0.0.53%lo:53），先剥掉
# %… 后缀再比对，否则 stub 会被误判为外来占位。
_addr_host() { local a="$1"; a="${a%:*}"; a="${a#[}"; a="${a%]}"; a="${a%%\%*}"; printf '%s' "$a"; }
_addr_port() { printf '%s' "${1##*:}"; }
_is_wildcard_host() {
  case "$1" in ""|\*|0.0.0.0|::) return 0;; *) return 1;; esac
}
_is_stub_host() {
  case "$1" in 127.0.0.53|127.0.0.54) return 0;; *) return 1;; esac
}

# stub_blockers [own_listen] [ignore_pid]：输出会挡住 resolved stub
# （127.0.0.53:53）绑定的 :53 监听（空格分隔），有则返回 0，无则返回 1。
# 挡住 ⟺ 通配符 :53 监听；resolved 自己的 stub（127.0.0.53/54:53）永远不算
# 挡路。own_listen 给出时（停 agent 之前）：agent 自己的通配符监听不算
# （停掉后就没了）——归属 dnsunlock 的监听都算自己的（配置里的 listen 过
# 期、实际监听地址对不上时也一样）；看不出归属（ss 没给 users）且 own 是
# 通配符时按共存推断跳过——agent 正在跑且占通配符 :53 时，通配符 :53 只能
# 是它自己（两个进程绑不上同一个通配符 :53）。停后复查（无 own 参数）时
# 任何通配符 :53 监听都算挡路，但 ignore_pid 给出时跳过该 pid 的残留行
# （刚杀掉的 agent 的僵尸/未回收监听行，端口实际已释放）。127.0.0.1:53
# 这类具体地址不挡 stub。
stub_blockers() {
  local own="${1:-}" _ignore_pid="${2:-}" a host port own_host="" own_port="" found="" users=""
  if [ -n "$own" ]; then own_host=$(_addr_host "$own"); own_port=$(_addr_port "$own"); fi
  while IFS="$(printf '\t')" read -r a users; do
    [ -n "$a" ] || continue
    if [ -n "$_ignore_pid" ]; then
      case "$users" in *"pid=$_ignore_pid,"*|*"pid=$_ignore_pid)"*) continue;; esac
    fi
    host=$(_addr_host "$a"); port=$(_addr_port "$a")
    [ "$port" = "53" ] || continue
    _is_stub_host "$host" && continue
    _is_wildcard_host "$host" || continue
    if [ -n "$own" ]; then
      case "$users" in *dnsunlock*) continue;; esac
      if _is_wildcard_host "$own_host" && [ "$own_port" = "53" ]; then
        case "$users" in "") continue;; esac
      fi
    fi
    case " $found " in *" $a "*) ;; *) found="${found:+$found }$a";; esac
  done <<EOF
$(ss_listen_53_p 2>/dev/null || true)
EOF
  if [ -n "$found" ]; then echo "$found"; return 0; fi
  return 1
}

# agent_listen_from_config：读 /etc/dnsunlock/config.json 的 dns_listen，无则默认 :53。
agent_listen_from_config() {
  local listen=""
  if [ -f /etc/dnsunlock/config.json ]; then
    listen=$(sed -n 's/.*"dns_listen"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/dnsunlock/config.json | head -1)
  fi
  [ -n "$listen" ] || listen=":53"
  printf '%s' "$listen"
}

# 中止时 agent 未能恢复的待办标记：下次还原重跑时 AGENT_WAS_ACTIVE 仍为 1，
# 不再谎报“还原前未在运行”。agent 恢复运行、或还原明确决定让它保持停止后清掉。
write_pending_marker() {
  mkdir -p /etc/dnsunlock 2>/dev/null || return 1
  { echo "listen=$1"; echo "timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')"; } > "$PENDING_MARKER" 2>/dev/null || return 1
  return 0
}
read_pending_marker() {
  [ -f "$PENDING_MARKER" ] || return 1
  sed -n 's/^listen=//p' "$PENDING_MARKER" 2>/dev/null | head -1
}
clear_pending_marker() {
  rm -f "$PENDING_MARKER" 2>/dev/null || true
}

# --- 无 unit agent 的端口兜底（V016-09）---
# _addr_matches_listen <实际监听地址> <配置 listen>：通配符 listen 匹配任何
# 通配符地址（:53 ⟷ 0.0.0.0:53 / [::]:53）；否则精确匹配。
_addr_matches_listen() {
  local a_host a_port l_host l_port
  a_host=$(_addr_host "$1"); a_port=$(_addr_port "$1")
  l_host=$(_addr_host "$2"); l_port=$(_addr_port "$2")
  [ "$a_port" = "$l_port" ] || return 1
  if _is_wildcard_host "$l_host"; then
    _is_wildcard_host "$a_host"
  else
    [ "$a_host" = "$l_host" ]
  fi
}

# _pid_gone <pid>：进程不存在、或已成僵尸（等父进程回收，端口已释放）都算没了。
_pid_gone() {
  local pid="$1" st=""
  kill -0 "$pid" 2>/dev/null || return 0
  if [ -r "/proc/$pid/stat" ]; then
    st=$(sed -n 's/^.*) \([A-Za-z]\).*/\1/p' "/proc/$pid/stat" 2>/dev/null || true)
    [ "$st" = "Z" ] && return 0
  fi
  return 1
}

# agent_pid_on_listen <listen>：输出占着该监听地址的 dnsunlock 进程 pid。
# 先读 ss -tulnp 的 users 字段（归属 dnsunlock 且地址匹配）；ss 没给 users
# 时回退 pgrep -f dns-agent，再确认该监听地址确实有人占着。
agent_pid_on_listen() {
  local listen="$1" a users pid=""
  while IFS="$(printf '\t')" read -r a users; do
    case "$users" in *dnsunlock*) ;; *) continue;; esac
    _addr_matches_listen "$a" "$listen" || continue
    pid=$(printf '%s' "$users" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$pid" ] && { printf '%s' "$pid"; return 0; }
  done <<EOF
$(ss_listen_53_p 2>/dev/null || true)
EOF
  if command -v pgrep >/dev/null 2>&1; then
    pid=$(pgrep -f "dns-agent" 2>/dev/null | grep -v "^$$$" | head -1)
    if [ -n "$pid" ] && ! _pid_gone "$pid"; then
      while IFS="$(printf '\t')" read -r a users; do
        _addr_matches_listen "$a" "$listen" && { printf '%s' "$pid"; return 0; }
      done <<EOF
$(ss_listen_53_p 2>/dev/null || true)
EOF
    fi
  fi
  return 1
}

# agent_pid_any_53：输出“pid 监听地址”，找任何一个 dnsunlock 占的 :53 监听
# （配置里的 listen 过期、与实际监听对不上时用）。
agent_pid_any_53() {
  local a users pid=""
  while IFS="$(printf '\t')" read -r a users; do
    case "$users" in *dnsunlock*) ;; *) continue;; esac
    pid=$(printf '%s' "$users" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$pid" ] && { printf '%s %s' "$pid" "$a"; return 0; }
  done <<EOF
$(ss_listen_53_p 2>/dev/null || true)
EOF
  return 1
}

# stop_agent_no_unit <pid>：TERM，等监听消失或进程没了（最多 5 秒）；还不走
# 就 KILL，再等 2 秒。成功返回 0。
stop_agent_no_unit() {
  local pid="$1" _i
  kill -TERM "$pid" 2>/dev/null || return 0
  for _i in 1 2 3 4 5; do
    _pid_gone "$pid" && return 0
    if command -v ss >/dev/null 2>&1; then
      agent_pid_on_listen "$AGENT_LISTEN" >/dev/null 2>&1 || return 0
    fi
    sleep 1
  done
  kill -KILL "$pid" 2>/dev/null || true
  for _i in 1 2; do
    _pid_gone "$pid" && return 0
    if command -v ss >/dev/null 2>&1; then
      agent_pid_on_listen "$AGENT_LISTEN" >/dev/null 2>&1 || return 0
    fi
    sleep 1
  done
  return 1
}

# restart_agent：把 agent 起回来。成功返回 0（并清待办标记），失败返回 1。
# 有 unit 时 systemctl start；无 unit 时直接起二进制（与 unit 的 ExecStart
# 同一条命令），再确认端口上确实是 dnsunlock 在监听。
restart_agent() {
  local _listen="${AGENT_LISTEN:-$(agent_listen_from_config)}" _i
  if agent_unit_exists; then
    if systemctl start "$AGENT_UNIT" 2>/dev/null && systemctl is-active --quiet "$AGENT_UNIT" 2>/dev/null; then
      clear_pending_marker
      return 0
    fi
    return 1
  fi
  if [ -x /usr/local/bin/dnsunlock ] && [ -f /etc/dnsunlock/config.json ]; then
    nohup /usr/local/bin/dnsunlock dns-agent --config /etc/dnsunlock/config.json >/dev/null 2>&1 &
    for _i in 1 2 3 4 5; do
      sleep 1
      if agent_pid_on_listen "$_listen" >/dev/null 2>&1; then
        clear_pending_marker
        return 0
      fi
    done
  fi
  return 1
}

# abort_restore_agent：中止路径把刚停掉的 agent 起回来（能起就起，起不回来
# 也要明说 + 留待办标记）。返回 0=已恢复，1=未能恢复。
abort_restore_agent() {
  echo "还原已中止，正在把刚停掉的 agent 恢复运行..."
  if restart_agent; then
    echo "agent 已恢复运行（监听 $AGENT_LISTEN），系统 DNS 未改动。"
    return 0
  fi
  if [ "$AGENT_NO_UNIT" = 1 ]; then
    echo "警告: agent 未能恢复运行（监听 $AGENT_LISTEN，无 systemd unit），分流已停止；系统 DNS 未改动（resolv.conf 仍指向 agent）。请手动运行 /usr/local/bin/dnsunlock dns-agent --config /etc/dnsunlock/config.json，或重跑安装脚本。" >&2
  else
    echo "警告: agent 未能恢复运行（监听 $AGENT_LISTEN），分流已停止；系统 DNS 未改动（resolv.conf 仍指向 agent）。请手动 systemctl start dnsunlock-agent，或重跑安装脚本。" >&2
  fi
  write_pending_marker "$AGENT_LISTEN"
  return 1
}

# record_and_stop_agent_no_unit <pending_listen>：无 systemd unit 时的端口兜底。
# 按配置 listen 找端口上的 dnsunlock 进程并杀掉；配置过期时按实际监听处理。
# 外来通配符 :53 占位在动手之前就中止（agent 不动）；停完仍有占位时中止，
# 但先把 agent 起回来（起不回来也要明说 + 留待办标记）。
record_and_stop_agent_no_unit() {
  local _pending="$1" _pid="" _any="" _blockers="" _i
  AGENT_NO_UNIT=1
  if [ -n "$_pending" ]; then AGENT_WAS_ACTIVE=1; AGENT_LISTEN="$_pending"; fi
  AGENT_LISTEN=$(agent_listen_from_config)
  if [ ! -f /etc/dnsunlock/config.json ] && [ -n "$_pending" ]; then AGENT_LISTEN="$_pending"; fi
  # 停之前先检查：有没有停完也不会消失的、会挡 stub 的监听。
  if _blockers=$(stub_blockers "$AGENT_LISTEN"); then
    echo "错误: :53 上已有其他服务监听（$_blockers），重启 systemd-resolved 会抢不到 stub，还原已中止（agent 未动，系统 DNS 未改；只写了一份还原前备份 ${PRE_RESTORE_BACKUP:-（见 /var/lib/dnsunlock/backup/ 下最新一份）}）；请先处理占 :53 的服务后重跑" >&2
    exit 1
  fi
  _pid=$(agent_pid_on_listen "$AGENT_LISTEN" 2>/dev/null || true)
  if [ -z "$_pid" ]; then
    _any=$(agent_pid_any_53 2>/dev/null || true)
    if [ -n "$_any" ]; then
      _pid="${_any%% *}"; AGENT_LISTEN="${_any#* }"
    fi
  fi
  if [ -n "$_pid" ]; then
    AGENT_WAS_ACTIVE=1
    clear_pending_marker
    echo "还原前 agent 在运行（监听 $AGENT_LISTEN，无 systemd unit，按端口找到进程 $_pid），先停掉它再重启 systemd-resolved（否则 resolved 抢不到 :53 的 stub）..."
    if ! stop_agent_no_unit "$_pid"; then
      echo "错误: 停 agent 进程 $_pid 失败（kill 后仍在监听 $AGENT_LISTEN），还原已中止（只写了一份还原前备份 ${PRE_RESTORE_BACKUP:-（见 /var/lib/dnsunlock/backup/ 下最新一份）}，未改系统 DNS 配置）；请手动 kill $_pid 后重跑" >&2
      exit 1
    fi
  elif [ "$AGENT_WAS_ACTIVE" = 1 ]; then
    echo "上次还原中止后 agent 未能恢复（监听 $AGENT_LISTEN，原本在运行）；本次还原继续，还原后将尝试恢复它..."
  else
    # 没 unit、端口上也没有 agent：没什么要停的，直接还原。
    return 0
  fi
  # 停完确认挡 stub 的监听真没了（忽略刚杀掉的 agent 的残留行）；没有 ss 就跳过。
  if command -v ss >/dev/null 2>&1; then
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      stub_blockers "" "$_pid" >/dev/null 2>&1 || return 0
      sleep 1
    done
    _blockers=$(stub_blockers "" "$_pid" 2>/dev/null || true)
    echo "错误: agent 已停，但 :53 仍被占（${_blockers:-别的服务}），还原已中止（只写了一份还原前备份 ${PRE_RESTORE_BACKUP:-（见 /var/lib/dnsunlock/backup/ 下最新一份）}，未改系统 DNS 配置）" >&2
    abort_restore_agent || true
    exit 1
  fi
  return 0
}

# 还原前记 agent 状态并停掉它。
# 顺序（V016-02）：先读上次中止留下的待办标记，再按“冲突”检查 :53——
# 只有会挡住 resolved stub 绑定的监听才算障碍（通配符 :53；resolved 自己
# 的 stub 127.0.0.53:53 不算，agent 自己的通配符监听也不算，停后就没了）。
# R2-04：冲突检查在 AGENT_WAS_ACTIVE 早返回之前——无论 agent 是否在跑都
# 先查（与无 unit 路径对齐）；原先 agent 未在跑时直接 return，外来 :53
# 占位发现不了，还原先改 resolv.conf、后验证失败才 exit 1，系统 DNS 死。
# 检查到障碍时在停 agent 之前就中止（agent 不动）；停完仍有障碍时中止，
# 但先把 agent 起回来（起不回来也要明说 + 留待办标记，下次重跑不再谎报
# “还原前未在运行”）。停 agent 失败时 agent 还在跑，不用恢复。
# 此时还没改系统 DNS 配置（只写了一份还原前备份），比还原到一半才发现要强。
record_and_stop_agent() {
  AGENT_WAS_ACTIVE=0; AGENT_WAS_ENABLED=0; AGENT_LISTEN=""; AGENT_NO_UNIT=0
  local _blockers="" _pending="" _running_now=0
  # 上次中止留下的待办：agent 曾在运行、却没能恢复——重跑时仍算“曾在运行”。
  _pending=$(read_pending_marker 2>/dev/null || true)
  if ! agent_unit_exists; then
    record_and_stop_agent_no_unit "$_pending"
    return 0
  fi
  if [ -n "$_pending" ]; then AGENT_WAS_ACTIVE=1; AGENT_LISTEN="$_pending"; fi
  if systemctl is-enabled --quiet "$AGENT_UNIT" 2>/dev/null; then AGENT_WAS_ENABLED=1; fi
  if systemctl is-active --quiet "$AGENT_UNIT" 2>/dev/null; then
    AGENT_WAS_ACTIVE=1
    _running_now=1
    clear_pending_marker
  fi
  AGENT_LISTEN=$(agent_listen_from_config)
  if [ ! -f /etc/dnsunlock/config.json ] && [ -n "$_pending" ]; then AGENT_LISTEN="$_pending"; fi
  # 停之前先检查：有没有停完也不会消失的、会挡 stub 的监听。
  if _blockers=$(stub_blockers "$AGENT_LISTEN"); then
    echo "错误: :53 上已有其他服务监听（$_blockers），重启 systemd-resolved 会抢不到 stub，还原已中止（agent 未动，系统 DNS 未改；只写了一份还原前备份 ${PRE_RESTORE_BACKUP:-（见 /var/lib/dnsunlock/backup/ 下最新一份）}）；请先处理占 :53 的服务后重跑" >&2
    exit 1
  fi
  [ "$AGENT_WAS_ACTIVE" = 1 ] || return 0
  if [ "$_running_now" = 1 ]; then
    echo "还原前 agent 在运行（监听 $AGENT_LISTEN），先停掉它再重启 systemd-resolved（否则 resolved 抢不到 :53 的 stub）..."
    if ! systemctl stop "$AGENT_UNIT" 2>/dev/null; then
      echo "错误: 停 dnsunlock-agent 失败，还原已中止（只写了一份还原前备份 ${PRE_RESTORE_BACKUP:-（见 /var/lib/dnsunlock/backup/ 下最新一份）}，未改系统 DNS 配置）；请手动 systemctl stop dnsunlock-agent 后重跑" >&2
      exit 1
    fi
  else
    echo "上次还原中止后 agent 未能恢复（监听 $AGENT_LISTEN，原本在运行）；本次还原继续，还原后将尝试恢复它..."
  fi
  # stop 是同步的，但多等一下确认挡 stub 的监听真没了；没有 ss 就跳过这步。
  if command -v ss >/dev/null 2>&1; then
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      stub_blockers >/dev/null 2>&1 || return 0
      sleep 1
    done
    _blockers=$(stub_blockers 2>/dev/null || true)
    echo "错误: agent 已停，但 :53 仍被占（${_blockers:-别的服务}），还原已中止（只写了一份还原前备份 ${PRE_RESTORE_BACKUP:-（见 /var/lib/dnsunlock/backup/ 下最新一份）}，未改系统 DNS 配置）" >&2
    abort_restore_agent || true
    exit 1
  fi
  return 0
}

# ss_listen_all_p：输出当前所有监听行，格式“地址<TAB>users 字段（可能为空）”，
# 去重（不限 :53，供 listen_blocked 判断非 53 端口的占用）。
ss_listen_all_p() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -tulnp 2>/dev/null | awk '$1 ~ /^(udp|tcp)/ {u=""; for (i=7;i<=NF;i++) u=u $i " "; sub(/ $/,"",u); print $5 "\t" u}' | sort -u
}

# listen_blocked <listen>：该监听地址现在是否会被别的进程挡住（V016-23）。
# 输出挡住它的监听地址（空格分隔），有则返回 0，无则返回 1。
# 挡住 ⟺ 有监听占了完全相同的地址，或有通配符监听占了同端口；
# 归属 dnsunlock 的监听不算（那是 agent 自己刚停掉的残留行，端口实际已释放）。
listen_blocked() {
  local listen="$1" l_host l_port a host port found="" users=""
  l_host=$(_addr_host "$listen"); l_port=$(_addr_port "$listen")
  [ -n "$l_port" ] || return 1
  while IFS="$(printf '\t')" read -r a users; do
    [ -n "$a" ] || continue
    host=$(_addr_host "$a"); port=$(_addr_port "$a")
    [ "$port" = "$l_port" ] || continue
    case "$users" in *dnsunlock*) continue;; esac
    if [ "$host" = "$l_host" ] || _is_wildcard_host "$host"; then
      case " $found " in *" $a "*) ;; *) found="${found:+$found }$a";; esac
    fi
  done <<EOF
$(ss_listen_all_p 2>/dev/null || true)
EOF
  if [ -n "$found" ]; then echo "$found"; return 0; fi
  return 1
}
# measure_53：实测 :53 的占用情况，供 restore_agent_after 决策（V016-08）。
# 输出以下之一（第一行）：
#   stub <地址>   — resolved 的 stub（127.0.0.53:53 或 127.0.0.54:53）在监听
#   held <地址…> — :53 被占，但不是 stub（列出监听地址；无 ss 时只给 held）
#   free          — :53 上没有任何监听
#   unknown       — 无 ss 且无 python3，无法测量
measure_53() {
  if command -v ss >/dev/null 2>&1; then
    local addrs=""
    # R2-03：ss 输出的地址可能带接口后缀（127.0.0.53%lo:53），归一化掉
    # %… 后缀再比对，否则 stub 分支是死代码、误报 held。
    addrs=$(ss_listen_53_p 2>/dev/null | cut -f1 | sed 's/%[^ :]*//g' | sort -u | tr '\n' ' ' | sed 's/ $//')
    if [ -z "$addrs" ]; then echo "free"; return 0; fi
    case " $addrs " in
      *" 127.0.0.53:53 "*) echo "stub 127.0.0.53:53"; return 0;;
      *" 127.0.0.54:53 "*) echo "stub 127.0.0.54:53"; return 0;;
    esac
    echo "held $addrs"; return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PYEOF' 2>/dev/null
import socket, errno
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.bind(("0.0.0.0", 53))
    print("free")
except OSError as e:
    print("held" if e.errno == errno.EADDRINUSE else "unknown")
finally:
    s.close()
PYEOF
    return 0
  fi
  echo "unknown"
}

# _enabled_boot_warn：agent 保持停止、且还原前是开机自启时提醒下次启动会抢 :53（V016-24）。
# AGENT_WAS_ENABLED 只写不读的死变量问题就此解决。
_enabled_boot_warn() {
  if [ "$AGENT_WAS_ENABLED" = 1 ]; then
    echo "注意: agent 仍是开机自启（enabled），下次启动时还会尝试绑定 :53、与 systemd-resolved 抢端口；如不再用 agent 分流，请执行 systemctl disable dnsunlock-agent，或重跑安装脚本重新接管。"
  fi
}

# 还原后按需恢复 agent（实测为准，不瞎猜，V016-08）。
# agent 监听通配符 :53 时：先实测 :53 的占用——resolved 的 stub 真在
# 127.0.0.53:53 上监听才说“已重新占用”并保持停止；:53 空闲就把 agent
# 起回来（不然分流无声无息丢了）；被别的服务占着就如实说是谁占着。
# 监听是具体地址（127.0.0.1:53、127.0.0.1:5353 等）时：先按实际冲突分类
# （V016-23）——地址就是 stub 的、或当前被别的进程挡住的，保持停止并明说；
# 不冲突才起回来，起失败要明说分流已丢及恢复办法，并留待办标记。
# 无 unit 的 agent 也走 restart_agent 的端口兜底分支（V016-09）。
restore_agent_after() {
  if [ "$AGENT_WAS_ACTIVE" != 1 ]; then
    echo "agent 还原前未在运行，保持停止（未改动）。"
    return 0
  fi
  case "$AGENT_LISTEN" in
    :53|0.0.0.0:53|[::]:53)
      local _m="" _kind="" _rest=""
      _m=$(measure_53 2>/dev/null || echo unknown)
      _kind="${_m%% *}"
      case "$_m" in *" "*) _rest="${_m#* }";; *) _rest="";; esac
      case "$_kind" in
        stub)
          echo "agent 还原前在运行（监听 $AGENT_LISTEN），现保持停止：实测 systemd-resolved 的 stub 已在 $_rest 监听，agent 的通配符 :53 无法同时绑定。"
          echo "如需继续用 agent 分流，请重新执行安装脚本（它会重新关掉 stub 并接管）；只想恢复系统 DNS 的话，现在已经好了。"
          clear_pending_marker
          _enabled_boot_warn
          ;;
        free)
          # V016-08 修的是“谎报”，不是“自动恢复”：实测 :53 空闲只说明
          # resolved 的 stub 没起来，不等于可以把 agent 起回来。起回来会让
          # 验证经 agent 通过、还原报成功，而分流实际还残留着（还原的本意
          # 是去掉分流），与 V016-10 的 fail-closed 相抵触，也违背 P1(a)
          # “通配符 agent 还原后保持停止”的定稿设计。所以保持停止，并明说
          # stub 没起来、验证会如实报告；想继续用 agent 请重跑安装脚本。
          echo "agent 还原前在运行（监听 $AGENT_LISTEN），现保持停止：实测 :53 当前空闲（systemd-resolved 的 stub 并未在监听），按还原设计不自动恢复 agent，避免分流静默残留。"
          echo "注意：resolved 的 stub 没起来，系统 DNS 可能不可用；还原后的验证会如实报告（验证失败则还原退出码为 1）。如需继续用 agent 分流，请重跑安装脚本；只想恢复系统 DNS 的话，请先检查 systemd-resolved 是否正常启动。"
          clear_pending_marker
          _enabled_boot_warn
          ;;
        held)
          echo "agent 还原前在运行（监听 $AGENT_LISTEN），现保持停止：systemd-resolved 的 stub 未在 :53 上监听，但 :53 仍被占（${_rest:-别的服务}），agent 的通配符 :53 无法绑定。"
          echo "如需继续用 agent 分流，请先处理占 :53 的服务后重跑安装脚本；只想恢复系统 DNS 的话，现在已经好了。"
          clear_pending_marker
          _enabled_boot_warn
          ;;
        *)
          echo "agent 还原前在运行（监听 $AGENT_LISTEN），现保持停止：无法确认 :53 的占用情况（本机无 ss/python3 可测），为避免抢端口失败，agent 未恢复。"
          echo "如需继续用 agent 分流，请重跑安装脚本；只想恢复系统 DNS 的话，现在已经好了。"
          clear_pending_marker
          _enabled_boot_warn
          ;;
      esac
      ;;
    *)
      local _blockers=""
      # 按实际冲突分类，不按监听字符串语法（V016-23）：
      # 监听地址就是 stub 自己的地址（127.0.0.53/54:53）→ 起 agent 会直接抢
      # 掉 stub，保持停止；监听地址当前被别的进程挡住 → 也保持停止并点名。
      if _is_stub_host "$(_addr_host "$AGENT_LISTEN")" && [ "$(_addr_port "$AGENT_LISTEN")" = "53" ]; then
        echo "agent 还原前在运行（监听 $AGENT_LISTEN），现保持停止：该地址就是 systemd-resolved 的 stub 地址，agent 占了它会直接抢掉 stub。"
        echo "如需继续用 agent 分流，请重跑安装脚本并改监听地址（例如 bash install.sh --dns-listen 127.0.0.1:53）；只想恢复系统 DNS 的话，现在已经好了。"
        clear_pending_marker
        _enabled_boot_warn
      elif _blockers=$(listen_blocked "$AGENT_LISTEN"); then
        echo "agent 还原前在运行（监听 $AGENT_LISTEN），现保持停止：该监听地址已被占（$_blockers），agent 绑不上。"
        echo "如需继续用 agent 分流，请先处理占用的服务后重跑安装脚本；只想恢复系统 DNS 的话，现在已经好了。"
        clear_pending_marker
        _enabled_boot_warn
      else
        echo "agent 还原前在运行（监听 $AGENT_LISTEN），正在恢复..."
        if restart_agent; then
          echo "agent 已恢复运行（监听 $AGENT_LISTEN）。"
        elif [ "$AGENT_NO_UNIT" = 1 ]; then
          echo "警告: agent 恢复启动失败（监听 $AGENT_LISTEN），分流已停止；系统 DNS 不受影响。请手动运行 /usr/local/bin/dnsunlock dns-agent --config /etc/dnsunlock/config.json，或重跑安装脚本。" >&2
          write_pending_marker "$AGENT_LISTEN"
        else
          echo "警告: agent 恢复启动失败（监听 $AGENT_LISTEN），分流已停止；系统 DNS 不受影响。请手动 systemctl start dnsunlock-agent，或重跑安装脚本；详情见 journalctl -u dnsunlock-agent。" >&2
          write_pending_marker "$AGENT_LISTEN"
        fi
      fi
      ;;
  esac
}

# 还原后验证（getent 优先，走系统解析器；缺 getent 回退 dig；都没工具只报告）。
# 验证失败返回 1（V016-10：以前恒返回 0，stub 已死仍 exit 0，uninstall 会继续删 agent）。
# 无工具时无法证明失败，返回 0（只报告未做验证）。
verify_after_restore() {
  if command -v getent >/dev/null 2>&1; then
    if getent hosts example.com >/dev/null 2>&1; then echo "已还原并验证通过（getent hosts example.com 有结果）"; return 0; fi
    echo "已还原但验证未通过（getent hosts example.com 无结果，请检查 DNS 配置）" >&2
    return 1
  fi
  if command -v dig >/dev/null 2>&1; then
    if dig +short example.com A 2>/dev/null | grep -qE '^[0-9]+\.'; then echo "已还原并验证通过（dig example.com 有结果）"; return 0; fi
    echo "已还原但验证未通过（dig example.com 无结果，请检查 DNS 配置）" >&2
    return 1
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

# clear_temp_state：只清临时状态记录与开机清理 unit，不动 resolv.conf（R2-01）。
# 还原成功后调用：永久还原取代了临时 DNS，旧记录再留着，下次重启时开机
# unit 会按记录把 resolv.conf 恢复成临时原状（即接管态 127.0.0.1），等于
# 撤销还原。绝不能用 cleanup_temp_state 代替——后者会按记录恢复 DNS。
# 也覆盖 resolvectl 路径的惰性残留（R2-05：只有 state 文件、无开机 unit、
# 无 DNS 效应，同样清掉）。尽力而为，失败只警告，不致命。
clear_temp_state() {
  rm -rf /etc/dnsunlock/temp-state 2>/dev/null || true
  if [ -f /etc/systemd/system/dnsunlock-temp-restore.service ]; then
    systemctl disable dnsunlock-temp-restore.service 2>/dev/null || true
    rm -f /etc/systemd/system/dnsunlock-temp-restore.service
    systemctl daemon-reload 2>/dev/null || true
  fi
}

# cleanup_temp_state：清理 --temp 临时模式留下的运行时 DNS（V016-01）。
# 按 /etc/dnsunlock/temp-state/state 的记录来：
#   resolvectl 模式：resolvectl revert <iface>（运行时设置，重启即失效，不动文件）；
#   direct-write 模式：把 resolv.conf 从 temp-state/resolv.conf.orig 恢复
#     （原先是软链时恢复软链 + 把内容写回目标），再清掉 temp-state 与开机 unit；
#   none 模式：DNS 没动过，只清记录。
# 若临时模式启动了 agent（agent_was_active=0），停掉它；之前已在跑的 agent 不动。
# R2-07：revert 失败不再 fail-open——失败时返回 1 并保留状态文件与开机 unit
# （失败态可再现、可重试；开机 unit 下次启动会再跑一次清理），绝不打印
# “清理完成”。注意：这里绝不能直接 systemctl restart systemd-resolved——agent 还占着 :53
# 时 resolved 会抢不到 stub（正是 V016-01 的 P1）；要先停 agent，或用 resolvectl revert。
cleanup_temp_state() {
  local _state="/etc/dnsunlock/temp-state/state" _mode="" _iface="" _was_active="0" _link="" _tgt="" _pid="" _revert_failed=0
  echo "临时模式清理：按 /etc/dnsunlock/temp-state 的记录恢复 DNS..."
  if [ ! -f "$_state" ]; then
    echo "临时模式清理：没有临时状态记录（/etc/dnsunlock/temp-state/state 不存在），无需清理。"
    return 0
  fi
  _mode=$(sed -n 's/^mode=//p' "$_state" 2>/dev/null | head -1)
  _iface=$(sed -n 's/^iface=//p' "$_state" 2>/dev/null | head -1)
  _was_active=$(sed -n 's/^agent_was_active=//p' "$_state" 2>/dev/null | head -1)
  case "$_mode" in
    resolvectl)
      if [ -n "$_iface" ] && command -v resolvectl >/dev/null 2>&1; then
        if resolvectl revert "$_iface" 2>/dev/null; then
          echo "临时模式清理：已 resolvectl revert $_iface（运行时 DNS 已恢复）。"
        else
          echo "警告: resolvectl revert $_iface 失败；可先停 dnsunlock-agent，再执行 systemctl restart systemd-resolved 恢复。" >&2
          _revert_failed=1
        fi
      else
        echo "警告: 无法 resolvectl revert（无网卡记录或无 resolvectl）；可先停 dnsunlock-agent，再执行 systemctl restart systemd-resolved 恢复。" >&2
        _revert_failed=1
      fi
      ;;
    direct-write)
      if [ -f /etc/dnsunlock/temp-state/resolv.conf.orig ]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
        if [ -f /etc/dnsunlock/temp-state/resolv.conf.link ]; then
          _link=$(cat /etc/dnsunlock/temp-state/resolv.conf.link 2>/dev/null || true)
          rm -f /etc/resolv.conf
          if [ -n "$_link" ]; then
            ln -s "$_link" /etc/resolv.conf 2>/dev/null || { echo "警告: 恢复 /etc/resolv.conf 软链 -> $_link 失败，请手动检查" >&2; _revert_failed=1; }
            case "$_link" in /*) _tgt="$_link" ;; *) _tgt="/etc/$_link" ;; esac
            if [ ! -e "$_tgt" ]; then
              mkdir -p "$(dirname "$_tgt")" 2>/dev/null || true
              cp -L /etc/dnsunlock/temp-state/resolv.conf.orig "$_tgt" 2>/dev/null || { echo "警告: 软链目标 $_tgt 不存在且写回失败，请手动恢复" >&2; _revert_failed=1; }
            fi
            echo "临时模式清理：已恢复 /etc/resolv.conf 软链 -> $_link。"
          else
            echo "警告: 临时状态里软链目标为空，无法恢复 /etc/resolv.conf 软链；请手动检查。" >&2
            _revert_failed=1
          fi
        else
          cp -L /etc/dnsunlock/temp-state/resolv.conf.orig /etc/resolv.conf 2>/dev/null || { echo "警告: 恢复 /etc/resolv.conf 失败，请手动检查" >&2; _revert_failed=1; }
          echo "临时模式清理：已把 /etc/resolv.conf 从临时状态恢复。"
        fi
      else
        echo "警告: 临时状态里没有原 resolv.conf 备份，无法恢复文件；请手动检查 /etc/resolv.conf。" >&2
        _revert_failed=1
      fi
      ;;
    none)
      echo "临时模式清理：临时安装时未改本机 DNS，无需恢复文件。"
      ;;
    *)
      echo "警告: 临时状态记录的 mode 未知（${_mode:-空}），只清记录，不动 DNS。" >&2
      ;;
  esac
  # 临时模式启动的 agent（之前没在跑）要停掉；之前已在跑的 agent 不动。
  if [ "$_was_active" != "1" ]; then
    if agent_unit_exists; then
      systemctl stop "$AGENT_UNIT" 2>/dev/null || true
      echo "临时模式清理：已停掉临时模式启动的 agent。"
    elif [ -x /usr/local/bin/dnsunlock ]; then
      _pid=$(agent_pid_on_listen "$(agent_listen_from_config)" 2>/dev/null || true)
      if [ -n "$_pid" ]; then kill "$_pid" 2>/dev/null || true; echo "临时模式清理：已停掉临时模式启动的 agent（进程 $_pid）。"; fi
    fi
  else
    echo "临时模式清理：agent 在临时安装前已在运行，本次不动它。"
  fi
  # R2-07：revert 失败时不删状态、不删 unit、不报“清理完成”，返回 1。
  if [ "$_revert_failed" = 1 ]; then
    echo "临时模式清理未完成：DNS 未恢复原状（见上），状态记录已保留（/etc/dnsunlock/temp-state/state），请手动处理后重跑 dnsunlock-restore-dns --temp-cleanup；开机清理 unit 已保留，下次启动会再试一次。" >&2
    return 1
  fi
  # 清掉临时状态与开机 unit（unit 自己删自己，下次开机不再跑）。
  rm -rf /etc/dnsunlock/temp-state 2>/dev/null || true
  if [ -f /etc/systemd/system/dnsunlock-temp-restore.service ]; then
    systemctl disable dnsunlock-temp-restore.service 2>/dev/null || true
    rm -f /etc/systemd/system/dnsunlock-temp-restore.service
    systemctl daemon-reload 2>/dev/null || true
  fi
  echo "临时模式清理完成。如仍有问题，先停 dnsunlock-agent，再执行 systemctl restart systemd-resolved。"
  return 0
}
# ---- 参数 ----
YES=0
WANT_DIR=""
BOOT_CLEANUP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift;;
    --backup) WANT_DIR="$2"; shift 2;;
    --boot)
      # 只与 --temp-cleanup 合用（开机 oneshot unit 调它时放前面）：
      # 表示本次调用来自开机 unit，清理失败也返回 0（警告写进日志），
      # 不让 oneshot 失败；交互路径不用它，失败时返回 1。
      BOOT_CLEANUP=1; shift;;
    --temp-cleanup)
      # --temp 临时模式的退出清理：按临时状态记录恢复 DNS、停掉临时启动的
      # agent、清记录与 unit。R2-07：交互路径上 revert 失败时返回 1（状态
      # 已保留，可重跑）；开机 unit 调用（--boot --temp-cleanup）时恒返回 0。
      if [ "$BOOT_CLEANUP" = 1 ]; then
        cleanup_temp_state || true
        exit 0
      fi
      cleanup_temp_state || exit 1
      exit 0;;
    --help|-h)
      echo "用法: dnsunlock-restore-dns [--yes] [--backup <备份目录>] [--temp-cleanup] [--boot]"
      echo "  --yes     非交互：默认还原最早的一份（原始状态），不再逐项确认"
      echo "  --backup  指定要还原的备份目录（须含 resolv.conf）"
      echo "  --temp-cleanup  只清理 --temp 临时模式留下的运行时 DNS（按临时状态记录）；清理失败返回 1（状态已保留，可重跑）"
      echo "  --boot    与 --temp-cleanup 合用（开机 oneshot unit 用）：清理失败也返回 0，警告写进日志"
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
  PRE_RESTORE_BACKUP="$PRE_DIR"
  restore_from_dir "$CHOSEN"
  VERIFY_RC=0
  verify_after_restore || VERIFY_RC=$?
  restore_agent_after
  # R2-01：还原已完成（无论验证过不过），清临时状态：残留的开机 unit 会在
  # 下次重启把 resolv.conf 改回接管态。只在还原成功路径调，中止路径不调
  # （中止时 DNS 未改，临时状态仍有效）。
  clear_temp_state
  if [ "$VERIFY_RC" != 0 ]; then
    echo "还原已完成，但还原后验证未通过（见上），退出码 1；请检查 DNS 配置，确认无误后可重跑还原。" >&2
    exit 1
  fi
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
  PRE_RESTORE_BACKUP="$PRE_DIR"
  restore_legacy
  VERIFY_RC=0
  verify_after_restore || VERIFY_RC=$?
  restore_agent_after
  # R2-01：同上，还原已完成即清临时状态（中止路径不调）。
  clear_temp_state
  if [ "$VERIFY_RC" != 0 ]; then
    echo "还原已完成，但还原后验证未通过（见上），退出码 1；请检查 DNS 配置，确认无误后可重跑还原。" >&2
    exit 1
  fi
  exit 0
fi
echo "没有找到永久备份（/var/lib/dnsunlock/backup/ 下无备份，也无 /etc/dnsunlock/resolv.conf.orig）。"
if [ -f /etc/dnsunlock/temp-state/state ]; then
  echo "但找到 --temp 临时模式的状态记录，按记录清理临时 DNS："
  # R2-07：清理失败时返回 1（状态已保留），不谎报成功。
  if cleanup_temp_state; then
    exit 0
  else
    exit 1
  fi
fi
echo "如果你用的是 --temp 临时模式：临时 DNS 没有永久备份可还，清理办法："
echo "  - systemd-resolved 的机器：先停 dnsunlock-agent，再执行 systemctl restart systemd-resolved（resolvectl 设的 DNS 即失效；直接 restart 时 agent 还占着 :53，resolved 会抢不到 stub）"
echo "  - DHCP 的机器：重新拉 DHCP（如 dhclient -r; dhclient，或重启 NetworkManager）"
echo "  - 或手动把 /etc/resolv.conf 改回原来的 DNS（临时模式直接写文件时若原先是软链，需手动恢复软链）"
echo "临时模式重启后自动失效，不用专门清理也可以等重启。"
exit 0
