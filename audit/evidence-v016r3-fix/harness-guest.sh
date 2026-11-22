#!/bin/bash
# v0.1.6 修复轮 2 容器验证 guest 脚本（测试机 nspawn v016-test，Debian 12，真 systemd）
# 用法：guest.sh <scenario> [phase]
#   r201 p1|p2  R2-01 红：永久接管 → --temp direct-write → 还原 → 重启 → 复活断言
#   g201 p1|p2  R2-01 绿：同上，断言还原清掉 temp-state+unit、重启后干净
#   r202        R2-02 红：--dns-listen 127.0.0.1:5353，接管写死 nameserver，系统 DNS 死 + resolved 被停
#   g202        R2-02 绿：同上，断言守卫拒绝接管、resolved 不动、系统 DNS 活
#   r204        R2-04 红：agent 已停 + 外来通配符 :53 占位，还原先改后失败
#   g204        R2-04 绿：同上，断言停前中止、resolv.conf 未动；清占位后重跑恢复
#   r215        R2-15 绿：容器内真跑 rig-inner（RIG_CONTAINER_STAGE=1）
#   v12         V016-12 五步（绿；步 4 按 R2-02 新行为断言拒绝接管）
# 日志 /root/v016/<scenario>[.<phase>].log；结束写 === SUMMARY === PASS=x FAIL=y。
# token 只从 /root/v016/case.env 读，绝不打印。全部 dig 走 UDP（不用 +tcp）。
set -u
SCENARIO="${1:-}"; PHASE="${2:-}"
LOG="/root/v016/${SCENARIO}${PHASE:+.$PHASE}.log"
mkdir -p /root/v016
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
PASS=0; FAIL=0; FAILED=()
pass() { PASS=$((PASS+1)); echo "[PASS] $1"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "[FAIL] $1"; }
assert() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi; }
summary() {
  echo "=== SUMMARY === scenario=$SCENARIO${PHASE:+ phase=$PHASE} PASS=$PASS FAIL=$FAIL"
  if [ "$FAIL" -gt 0 ]; then printf '失败项：\n'; printf '  - %s\n' "${FAILED[@]}"; fi
  echo "=== END $SCENARIO ==="
  sleep 2  # tee 缓冲 + scope 拆除会丢 SUMMARY 尾行，先睡 2 秒再退
  exit "$([ "$FAIL" = 0 ] && echo 0 || echo 1)"
}

# shellcheck disable=SC1091
source /root/v016/case.env  # PANEL_URL, DNS_AGENT_TOKEN, RIG_SERVER_ID
RULE_DOMAIN=tiktok.com
RULE_IP=203.0.113.99
LAST_RC=99
last_rc0() { [ "${LAST_RC:-99}" = 0 ]; }
last_rc1() { [ "${LAST_RC:-99}" = 1 ]; }

dig_rule_ok() { # $1=地址 $2=端口（默认 53）；UDP 真查
  local addr="$1" port="${2:-53}"
  dig -p "$port" +short "@$addr" "$RULE_DOMAIN" A 2>/dev/null | grep -qx "$RULE_IP"
}
dig_stub_ok() { dig +short @127.0.0.53 example.com A 2>/dev/null | grep -qE '^[0-9]+\.'; }
getent_rule_ok() { getent hosts "$RULE_DOMAIN" 2>/dev/null | grep -q "$RULE_IP"; }
getent_example_ok() { getent ahosts example.com 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; }  # 本容器 getent hosts 对双栈域名只回 AAAA，ahosts 才列双栈
getent_tiktok_upstream() { # tiktok 走上游（返回 IP 但不是规则 IP）
  local ip
  ip=$(getent hosts "$RULE_DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
  [ -n "$ip" ] && [ "$ip" != "$RULE_IP" ]
}
resolv_is_stub_link() { [ -L /etc/resolv.conf ] && [ "$(readlink /etc/resolv.conf)" = "/run/systemd/resolve/stub-resolv.conf" ]; }
resolv_is_127001() { [ ! -L /etc/resolv.conf ] && grep -qx "nameserver 127.0.0.1" /etc/resolv.conf; }
agent_active() { systemctl is-active --quiet dnsunlock-agent 2>/dev/null; }
agent_inactive() { ! systemctl is-active --quiet dnsunlock-agent 2>/dev/null; }
resolved_active() { systemctl is-active --quiet systemd-resolved 2>/dev/null; }
resolved_enabled() { systemctl is-enabled --quiet systemd-resolved 2>/dev/null; }
stub_listening() { ss -tuln 2>/dev/null | grep -q '127.0.0.53'; }  # ss 印 127.0.0.53%lo:53，字面 127.0.0.53:53 匹配不到（R2-03 同类）
dropin_exists() { [ -f /etc/systemd/resolved.conf.d/dnsunlock.conf ]; }
dropin_absent() { [ ! -f /etc/systemd/resolved.conf.d/dnsunlock.conf ]; }
tempstate_exists() { [ -f /etc/dnsunlock/temp-state/state ]; }
tempstate_absent() { [ ! -e /etc/dnsunlock/temp-state ]; }
tempunit_exists() { [ -f /etc/systemd/system/dnsunlock-temp-restore.service ]; }
tempunit_absent() { [ ! -f /etc/systemd/system/dnsunlock-temp-restore.service ]; }
tempunit_enabled() { systemctl is-enabled --quiet dnsunlock-temp-restore.service 2>/dev/null; }
pending_absent() { [ ! -f /etc/dnsunlock/agent-restore-pending ]; }
log_has() { grep -qF "$2" "$1"; }  # log_has <file> <needle>

snapshot() { # snapshot <tag>：状态快照（不打印 token、不打印 config.json）
  local tag="$1"
  echo "--- snapshot: $tag ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ---"
  echo "resolved: active=$(systemctl is-active systemd-resolved 2>/dev/null) enabled=$(systemctl is-enabled systemd-resolved 2>/dev/null)"
  echo "agent: active=$(systemctl is-active dnsunlock-agent 2>/dev/null) enabled=$(systemctl is-enabled dnsunlock-agent 2>/dev/null) pid=$(systemctl show -p MainPID --value dnsunlock-agent 2>/dev/null)"
  echo "ss :53 lines:"
  ss -tuln 2>/dev/null | grep ':53' || echo "  (none)"
  echo "resolv.conf: $(ls -l /etc/resolv.conf | awk '{print $NF}')"
  cat /etc/resolv.conf 2>/dev/null | grep -v '^#' | grep -v '^$' || true
  echo "drop-in: $(dropin_exists && echo yes || echo no); temp-state: $(tempstate_exists && { grep '^mode=' /etc/dnsunlock/temp-state/state 2>/dev/null || echo yes; } || echo no); temp-unit: $(tempunit_exists && echo yes || echo no); pending-marker: $([ -f /etc/dnsunlock/agent-restore-pending ] && echo yes || echo no)"
  echo "getent tiktok: $(getent hosts "$RULE_DOMAIN" 2>/dev/null | head -1 || echo '(none)')"
  echo "getent example: $(getent hosts example.com 2>/dev/null | head -1 || echo '(none)')"
}

reset_state() {
  echo "--- reset_state ---"
  systemctl stop dnsunlock-agent 2>/dev/null || true
  systemctl disable dnsunlock-agent 2>/dev/null || true
  rm -f /etc/systemd/system/dnsunlock-agent.service
  rm -f /etc/systemd/system/dnsunlock-temp-restore.service
  systemctl daemon-reload 2>/dev/null || true
  rm -rf /var/lib/dnsunlock /etc/dnsunlock
  mkdir -p /var/lib/dnsunlock/backup /etc/dnsunlock
  rm -f /etc/systemd/resolved.conf.d/dnsunlock.conf
  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/resolv.conf
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  systemctl enable systemd-resolved 2>/dev/null || true
  systemctl restart systemd-resolved 2>/dev/null || systemctl start systemd-resolved 2>/dev/null || true
  sleep 2
  echo "--- reset done ---"
}

baseline_asserts() {
  assert "基线：resolved 在跑" resolved_active
  assert "基线：stub 在 127.0.0.53:53 监听" stub_listening
  assert "基线：无 drop-in" dropin_absent
  assert "基线：agent 不在跑" agent_inactive
  assert "基线：无临时状态" tempstate_absent
  assert "基线：无临时 unit" tempunit_absent
  assert "基线：resolv.conf 是 stub 软链" resolv_is_stub_link
  assert "基线：系统 DNS 可用" getent_example_ok
  assert "基线：getent tiktok 不走规则" getent_tiktok_upstream
}

do_install() { # do_install <listen> <temp:0|1> <log>；rc 记 LAST_RC，函数总返回 0
  local listen="$1" temp="$2" log="$3"
  curl -fsSL "$PANEL_URL/install.sh" -o /tmp/install.sh || { echo "下载 install.sh 失败"; LAST_RC=99; return 0; }
  printf 'y\ny\ny\ny\ny\ny\n' > /tmp/install-answers.txt
  local args=(--panel "$PANEL_URL" --dns-listen "$listen")
  [ "$temp" = 1 ] && args+=(--temp)
  DNS_AGENT_TOKEN="$DNS_AGENT_TOKEN" DNS_SERVER_NAME="nspawn-dns" \
    DNS_DEFAULT_IP="$RULE_IP" DNS_ALLOWLIST="127.0.0.1" \
    script -qec "bash /tmp/install.sh ${args[*]}" /dev/null < /tmp/install-answers.txt > "$log" 2>&1
  LAST_RC=$?
  echo "install $listen temp=$temp rc=$LAST_RC（日志 $log）"
  return 0
}

do_restore() { # do_restore <log> [extra args...]；rc 记 LAST_RC，函数总返回 0
  local log="$1"; shift
  dnsunlock-restore-dns --yes "$@" > "$log" 2>&1
  LAST_RC=$?
  echo "restore rc=$LAST_RC（日志 $log）"
  return 0
}

# ---------------- 场景 ----------------
scen_r201_p1() {  # R2-01 红：永久接管 → temp direct-write → 还原 →（重启在宿主机做）
  reset_state; baseline_asserts
  do_install 127.0.0.1:53 0 /root/v016/r201-perm-install.log
  assert "永久安装 rc=0" last_rc0
  assert "永久安装后 getent tiktok 走规则" getent_rule_ok
  assert "永久安装后 resolv.conf=127.0.0.1" resolv_is_127001
  assert "永久安装后 drop-in 存在" dropin_exists
  assert "永久安装后 agent 在跑" agent_active
  systemctl stop dnsunlock-agent; systemctl stop systemd-resolved
  sleep 1
  assert "temp 前 agent 已停" agent_inactive
  do_install 127.0.0.1:53 1 /root/v016/r201-temp-install.log
  assert "temp 安装 rc=0" last_rc0
  assert "temp 后 temp-state 存在" tempstate_exists
  assert "temp 后 temp-state mode=direct-write" sh -c 'grep -q "^mode=direct-write" /etc/dnsunlock/temp-state/state'
  assert "temp 后开机 unit 已装且 enabled" tempunit_enabled
  assert "temp 后 resolv.conf=127.0.0.1" resolv_is_127001
  assert "temp 后 getent tiktok 走规则" getent_rule_ok
  assert "temp 后 agent 在跑（temp 起的）" agent_active
  do_restore /root/v016/r201-restore.log
  assert "还原 rc=0" last_rc0
  assert "还原后 resolv.conf 回 stub 软链" resolv_is_stub_link
  assert "还原后 drop-in 已删" dropin_absent
  assert "还原后 resolved 在跑" resolved_active
  assert "还原后系统 DNS 可用" getent_example_ok
  assert "还原后 getent tiktok 走上游（分流已断）" getent_tiktok_upstream
  # 红 bug：还原没清临时状态
  assert "【红】还原后 temp-state 还在（bug 复现）" tempstate_exists
  assert "【红】还原后开机 unit 还在（bug 复现）" tempunit_exists
  snapshot "r201-p1 末态"
  touch /root/v016/r201-p1-done
  summary
}

scen_g201_p1() {  # R2-01 绿：同上，断言还原清掉 temp-state+unit
  reset_state; baseline_asserts
  do_install 127.0.0.1:53 0 /root/v016/g201-perm-install.log
  assert "永久安装 rc=0" last_rc0
  assert "永久安装后 getent tiktok 走规则" getent_rule_ok
  assert "永久安装后 resolv.conf=127.0.0.1" resolv_is_127001
  assert "永久安装后 drop-in 存在" dropin_exists
  assert "永久安装后 agent 在跑" agent_active
  systemctl stop dnsunlock-agent; systemctl stop systemd-resolved
  sleep 1
  assert "temp 前 agent 已停" agent_inactive
  do_install 127.0.0.1:53 1 /root/v016/g201-temp-install.log
  assert "temp 安装 rc=0" last_rc0
  assert "temp 后 temp-state 存在" tempstate_exists
  assert "temp 后 temp-state mode=direct-write" sh -c 'grep -q "^mode=direct-write" /etc/dnsunlock/temp-state/state'
  assert "temp 后开机 unit 已装且 enabled" tempunit_enabled
  assert "temp 后 resolv.conf=127.0.0.1" resolv_is_127001
  assert "temp 后 getent tiktok 走规则" getent_rule_ok
  assert "temp 后 agent 在跑（temp 起的）" agent_active
  do_restore /root/v016/g201-restore.log
  assert "还原 rc=0" last_rc0
  assert "还原后 resolv.conf 回 stub 软链" resolv_is_stub_link
  assert "还原后 drop-in 已删" dropin_absent
  assert "还原后 resolved 在跑" resolved_active
  assert "还原后系统 DNS 可用" getent_example_ok
  assert "还原后 getent tiktok 走上游（分流已断）" getent_tiktok_upstream
  # 绿修法：还原清掉临时状态
  assert "【绿】还原后 temp-state 已清" tempstate_absent
  assert "【绿】还原后开机 unit 已删" tempunit_absent
  snapshot "g201-p1 末态"
  touch /root/v016/g201-p1-done
  summary
}

scen_r201_p2() {  # R2-01 红，重启后断言（按分支断言，F3 复审 §8-4 修正）
  echo "--- r201-p2：重启后断言 ---"
  echo "boots: $(journalctl --list-boots 2>/dev/null | wc -l)"
  journalctl -u dnsunlock-temp-restore.service --no-pager -b 2>/dev/null | tail -20
  # 台架修正：先判走“分流静默复活”还是“系统 DNS 死”分支，再断言该支末态。
  # 复活分支：resolv.conf 为普通文件 127.0.0.1、agent 在跑、tiktok 走规则。
  # DNS 死分支：resolv.conf 仍是 stub 软链（但目标文件被写穿为 127.0.0.1）、
  # agent 已停、getent 全空。两支都是红复现成立，只断言走到的那支。
  if resolv_is_127001 && agent_active; then
    echo "--- 走“分流静默复活”分支 ---"
    assert "【红】重启后 resolv.conf 被改回 127.0.0.1（分流复活）" resolv_is_127001
    assert "【红】重启后 getent tiktok 走规则（分流静默复活）" getent_rule_ok
    assert "【红】重启后 agent 在跑（开机自启）" agent_active
  elif resolv_is_stub_link && agent_inactive; then
    echo "--- 走“系统 DNS 死”分支（最坏情况） ---"
    assert "【红】重启后 resolv.conf 仍是 stub 软链" resolv_is_stub_link
    assert "【红】重启后 stub 目标文件被写穿为 127.0.0.1" sh -c 'grep -qx "nameserver 127.0.0.1" /run/systemd/resolve/stub-resolv.conf'
    assert "【红】重启后 agent 已停（开机清理停掉了它）" agent_inactive
    assert "【红】重启后系统 DNS 已死（getent example 不通）" sh -c '! getent ahosts example.com 2>/dev/null | grep -qE "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"'
    assert "【红】重启后 getent tiktok 不通（分流与上游双死）" sh -c '! getent hosts tiktok.com 2>/dev/null | grep -q .'
  else
    fail "【红】重启后未走任一已知分支（既非复活也非 DNS 死）"
  fi
  assert "【红】开机 unit 跑过（journal 有临时模式清理）" sh -c 'journalctl -u dnsunlock-temp-restore.service --no-pager -b 2>/dev/null | grep -qi "临时模式清理\|temp-cleanup\|临时状态"'
  snapshot "r201-p2 末态"
  summary
}

scen_g201_p2() {  # R2-01 绿，重启后断言
  echo "--- g201-p2：重启后断言 ---"
  echo "boots: $(journalctl --list-boots 2>/dev/null | wc -l)"
  assert "【绿】重启后 resolv.conf 仍是 stub 软链" resolv_is_stub_link
  assert "【绿】重启后 getent tiktok 走上游（分流已死）" getent_tiktok_upstream
  assert "【绿】重启后系统 DNS 可用" getent_example_ok
  assert "【绿】重启后无 temp-state" tempstate_absent
  assert "【绿】重启后无开机 unit" tempunit_absent
  snapshot "g201-p2 末态"
  summary
}

scen_r202() {  # R2-02 红：--dns-listen 127.0.0.1:5353
  reset_state; baseline_asserts
  do_install 127.0.0.1:5353 0 /root/v016/r202-install.log
  assert "安装 rc=0（装完但写死 nameserver）" last_rc0
  assert "【红】resolv.conf 被写死 nameserver 127.0.0.1" resolv_is_127001
  assert "【红】系统 DNS 已死（getent example 不通）" sh -c '! getent ahosts example.com 2>/dev/null | grep -qE "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"'
  assert "【红】resolved 被自动停用（enabled=disabled）" sh -c '! systemctl is-enabled --quiet systemd-resolved 2>/dev/null'
  assert "【红】resolved 不在跑" sh -c '! systemctl is-active --quiet systemd-resolved 2>/dev/null'
  assert "【红】agent 在 127.0.0.1:5353 上跑" agent_active
  assert "【红】agent 本身能答（dig -p 5353 tiktok → 规则 IP，UDP）" sh -c 'dig -p 5353 +short @127.0.0.1 tiktok.com A 2>/dev/null | grep -qx "203.0.113.99"'
  assert "【红】安装日志含自动停用 resolved（升级处理）" sh -c 'grep -qF "升级处理" /root/v016/r202-install.log || grep -qF "disable --now systemd-resolved" /root/v016/r202-install.log'
  snapshot "r202 安装后"
  do_restore /root/v016/r202-restore.log
  assert "还原 rc=0（可恢复）" last_rc0
  assert "还原后 resolv.conf 回 stub 软链" resolv_is_stub_link
  assert "还原后 resolved 在跑" resolved_active
  assert "还原后系统 DNS 恢复" getent_example_ok
  reset_state
  summary
}

scen_g202() {  # R2-02 绿：--dns-listen 127.0.0.1:5353，守卫拒绝接管
  reset_state; baseline_asserts
  do_install 127.0.0.1:5353 0 /root/v016/g202-install.log
  assert "安装 rc=0" last_rc0
  assert "【绿】安装日志明说本次不接管（守卫拒绝）" sh -c 'grep -qF "本次不接管" /root/v016/g202-install.log'
  assert "【绿】resolv.conf 未动（仍是 stub 软链）" resolv_is_stub_link
  assert "【绿】resolved 仍在跑" resolved_active
  assert "【绿】resolved 仍 enabled" resolved_enabled
  assert "【绿】系统 DNS 可用" getent_example_ok
  assert "【绿】getent tiktok 走上游（没接管就没分流）" getent_tiktok_upstream
  assert "【绿】agent 在 127.0.0.1:5353 上跑" agent_active
  assert "【绿】agent 本身能答（dig -p 5353 tiktok → 规则 IP，UDP）" sh -c 'dig -p 5353 +short @127.0.0.1 tiktok.com A 2>/dev/null | grep -qx "203.0.113.99"'
  snapshot "g202 安装后"
  reset_state
  summary
}

start_wildhold() { # 通配符 :53 占位（0.0.0.0:53 UDP+TCP），pid 写文件
  setsid nohup python3 /root/v016/wildhold.py /root/v016/wildhold.pid > /root/v016/wildhold.log 2>&1 < /dev/null &
  sleep 1
  [ -f /root/v016/wildhold.pid ] && kill -0 "$(cat /root/v016/wildhold.pid)" 2>/dev/null
}
wildhold_listening() { ss -tuln 2>/dev/null | grep -q '0.0.0.0:53'; }
stop_wildhold() {
  [ -f /root/v016/wildhold.pid ] && kill "$(cat /root/v016/wildhold.pid)" 2>/dev/null || true
  # 台架修正（F3 复审 §8-4）：轮询等进程退出再返回，不要 sleep 1 秒就断言。
  # 等进程死 + :53 上无 0.0.0.0 监听，最多 10 秒；超时仍返回，由调用方断言裁决。
  local i=0 _pid=""
  while [ "$i" -lt 20 ]; do
    _pid="$(cat /root/v016/wildhold.pid 2>/dev/null || echo "")"
    if { [ -z "$_pid" ] || ! kill -0 "$_pid" 2>/dev/null; } && ! ss -tuln 2>/dev/null | grep -q "0.0.0.0:53"; then
      return 0
    fi
    sleep 0.5; i=$((i+1))
  done
  return 0
}

scen_r204() {  # R2-04 红：agent 已停 + 外来通配符 :53 占位，还原先改后失败
  reset_state; baseline_asserts
  do_install 127.0.0.1:53 0 /root/v016/r204-install.log
  assert "永久安装 rc=0" last_rc0
  assert "永久安装后 getent tiktok 走规则" getent_rule_ok
  systemctl stop dnsunlock-agent
  assert "agent 已停（还原前状态）" agent_inactive
  start_wildhold
  assert "通配符占位已起（0.0.0.0:53）" wildhold_listening
  do_restore /root/v016/r204-restore.log
  assert "【红】还原 rc=1（验证失败才退出）" last_rc1
  assert "【红】还原已改 resolv.conf（不再是 127.0.0.1）" sh -c '! grep -qx "nameserver 127.0.0.1" /etc/resolv.conf'
  assert "【红】还原已删 drop-in" dropin_absent
  assert "【红】还原日志含验证未通过" sh -c 'grep -qF "验证未通过" /root/v016/r204-restore.log'
  assert "【红】系统 DNS 已死（getent example 不通）" sh -c '! getent ahosts example.com 2>/dev/null | grep -qE "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"'
  assert "【红】agent 仍停着" agent_inactive
  assert "【红】无待办标记" pending_absent
  snapshot "r204 还原后（占位仍在）"
  stop_wildhold
  assert "占位已清" sh -c '! ss -tuln 2>/dev/null | grep -q "0.0.0.0:53"'
  do_restore /root/v016/r204-restore2.log
  assert "清占位后重跑还原 rc=0" last_rc0
  assert "重跑后系统 DNS 恢复" getent_example_ok
  reset_state
  summary
}

scen_g204() {  # R2-04 绿：同上，断言停前中止、resolv.conf 未动；清占位后重跑恢复
  reset_state; baseline_asserts
  do_install 127.0.0.1:53 0 /root/v016/g204-install.log
  assert "永久安装 rc=0" last_rc0
  assert "永久安装后 getent tiktok 走规则" getent_rule_ok
  systemctl stop dnsunlock-agent
  assert "agent 已停（还原前状态）" agent_inactive
  start_wildhold
  assert "通配符占位已起（0.0.0.0:53）" wildhold_listening
  do_restore /root/v016/g204-restore.log
  assert "【绿】还原 rc=1（停前中止）" last_rc1
  assert "【绿】还原日志明说已有其他服务监听" sh -c 'grep -qF "已有其他服务监听" /root/v016/g204-restore.log'
  assert "【绿】resolv.conf 未动（仍是 127.0.0.1）" resolv_is_127001
  assert "【绿】drop-in 还在" dropin_exists
  assert "【绿】agent 未动（仍停着）" agent_inactive
  snapshot "g204 还原后（占位仍在）"
  stop_wildhold
  assert "占位已清" sh -c '! ss -tuln 2>/dev/null | grep -q "0.0.0.0:53"'
  do_restore /root/v016/g204-restore2.log
  assert "清占位后重跑还原 rc=0" last_rc0
  assert "重跑后 resolv.conf 回 stub 软链" resolv_is_stub_link
  assert "重跑后系统 DNS 恢复" getent_example_ok
  assert "重跑后 agent 仍停着（还原前就没跑，不谎报）" agent_inactive
  reset_state
  summary
}

scen_r215() {  # R2-15 绿：容器内真跑 rig-inner（RIG_CONTAINER_STAGE=1）
  reset_state; baseline_asserts
  [ -x /root/rig/rig-inner.sh ] || { echo "rig-inner.sh 不在 /root/rig/"; exit 2; }
  cp /etc/nsswitch.conf /root/rig/fixtures/nsswitch.base 2>/dev/null || true
  systemctl stop dnsunlock-agent 2>/dev/null || true
  systemctl stop systemd-resolved 2>/dev/null || true
  sleep 1
  # 答案流必须与 scripts/test-takeover-rig.sh 的 24 行布局逐行一致
  # （S7b 要填真面板地址、S8/S9a 摘要确认要留空行取默认 N）；
  # 全 y 会使 S7b 手动输入拿到 y、S8/S9a 拿到 y 而非默认 N。
  {
    printf 'y\ny\ny\n'      # S1b: 关 stub / 接管 / 摘要
    printf 'y\ny\n'         # S2: 接管 / 摘要
    printf 'y\ny\n'         # S6: 接管 / 摘要
    printf 'not-a-url\n'    # S7a: 手动输入（非法）
    printf '%s\ny\ny\n' "$PANEL_URL"  # S7b: 手动输入 / 接管 / 摘要
    printf 'y\n\n'          # S8: 接管 / 摘要默认 N
    printf 'y\n\n'          # S9a: 接管 / hpve 默认 N
    printf 'y\ny\ny\n'      # S9b: 接管 / hpve / 摘要
    printf 'y\ny\n'         # S10: 接管 / 摘要
    printf 'y\ny\n'         # S11: 接管 / 摘要
    printf 'y\ny\n'         # S13: 接管 / 摘要
  } > /root/v016/rig-answers.txt
  RIG_CONTAINER_STAGE=1 DNS_AGENT_TOKEN="$DNS_AGENT_TOKEN" RIG_SERVER_ID="$RIG_SERVER_ID" PANEL_URL="$PANEL_URL" \
    script -qec "/bin/bash /root/rig/rig-inner.sh" /root/v016/rig-inner-typescript < /root/v016/rig-answers.txt > /root/v016/rig-inner-container.log 2>&1
  local rc=$?
  echo "rig-inner rc=$rc（日志 /root/v016/rig-inner-container.log）"
  [ "$rc" = 0 ] && pass "rig-inner exit 0" || fail "rig-inner exit 0（实际 rc=$rc）"
  ! grep -qF "SKIP-容器阶段" /root/v016/rig-inner-container.log && pass "无 SKIP-容器阶段" || fail "无 SKIP-容器阶段"
  grep -qF "dig @127.0.0.53" /root/v016/rig-inner-container.log && pass "日志含 dig @127.0.0.53 断言行" || fail "日志含 dig @127.0.0.53 断言行"
  reset_state
  summary
}

scen_v12() {  # V016-12 五步（绿；步 4 按 R2-02 新行为断言拒绝接管）
  reset_state; baseline_asserts
  echo "--- v12 步 1：永久安装 :53 ---"
  do_install 127.0.0.1:53 0 /root/v016/v12-s1-install.log
  assert "步 1 安装 rc=0" last_rc0
  assert "步 1 getent tiktok 走规则" getent_rule_ok
  assert "步 1 example 走上游" getent_example_ok
  echo "--- v12 步 2：还原 ---"
  do_restore /root/v016/v12-s2-restore.log
  assert "步 2 还原 rc=0" last_rc0
  assert "步 2 resolv.conf 回 stub 软链" resolv_is_stub_link
  assert "步 2 系统 DNS 恢复" getent_example_ok
  echo "--- v12 步 3：agent 重启后仍能答 ---"
  assert "步 3 agent 在跑" agent_active
  assert "步 3 dig @127.0.0.1 tiktok → 规则 IP（UDP）" sh -c 'dig +short @127.0.0.1 tiktok.com A 2>/dev/null | grep -qx "203.0.113.99"'
  assert "步 3 dig @127.0.0.53 example.com 通（UDP）" dig_stub_ok
  echo "--- v12 步 4：5353 安装（R2-02 新行为：拒绝接管）---"
  do_install 127.0.0.1:5353 0 /root/v016/v12-s4-install.log
  assert "步 4 安装 rc=0" last_rc0
  # 台架修正（F3 复审 §8-4）：“本次不接管”断言只在安装走到接管提问时才断言。
  # 接管提问在 [4/6] 验证之后，安装在 [4/6] 退出时根本没走到提问，断言不可达。
  if grep -qF "是否把本机系统 DNS" /root/v016/v12-s4-install.log; then
    assert "步 4 安装日志明说本次不接管" sh -c 'grep -qF "本次不接管" /root/v016/v12-s4-install.log'
  else
    echo "[SKIP] 步 4 未走到接管提问（安装在 [4/6] 退出），守卫文案断言不可达，不计入"
  fi
  assert "步 4 resolv.conf 未动（stub 软链）" resolv_is_stub_link
  assert "步 4 resolved 仍在跑" resolved_active
  assert "步 4 系统 DNS 可用" getent_example_ok
  assert "步 4 dig -p 5353 tiktok → 规则 IP（UDP）" sh -c 'dig -p 5353 +short @127.0.0.1 tiktok.com A 2>/dev/null | grep -qx "203.0.113.99"'
  systemctl stop dnsunlock-agent 2>/dev/null || true
  echo "--- v12 步 5：127.0.0.53:53 反向安装（记录行为）---"
  do_install 127.0.0.53:53 0 /root/v016/v12-s5-install.log
  echo "步 5 安装 rc=$LAST_RC（记录：应拒绝或警告，不应静默装上）"
  do_restore /root/v016/v12-s5-restore.log
  echo "步 5 还原 rc=$LAST_RC（记录）"
  assert "步 5 agent 仍停着" agent_inactive
  assert "步 5 stub 在 127.0.0.53:53 监听" stub_listening
  assert "步 5 系统 DNS 可用" getent_example_ok
  reset_state
  summary
}

# ---------------- F3 场景（修复轮 3，见 AUDIT-REPORT-V016-FOCUSED.md §8） ----------------
# F3-01：还原后立即 dig @127.0.0.53 tiktok ×5 全走上游 + Global 为空 + getent 走上游。
# F3-02 agent：agent 在跑时重装 --dns-listen 127.0.0.1:5353 → rc=0 + PID 变 + dig -p 5353 回规则 IP。
# F3-02 SNI：装 SNI（allowlist A=127.0.0.1）→ 重装改 allowlist B=203.0.113.7 → rc=0 + 日志有验证 + 新 allowlist 生效。
# F3-03：agent enabled 但已停时还原 → 还原后 agent 为 disabled + 日志有 disable 说明。

agent_pid() { systemctl show -p MainPID --value dnsunlock-agent 2>/dev/null; }
proxy_pid() { systemctl show -p MainPID --value dnsunlock-proxy 2>/dev/null; }
proxy_active() { systemctl is-active --quiet dnsunlock-proxy 2>/dev/null; }
agent_enabled() { systemctl is-enabled --quiet dnsunlock-agent 2>/dev/null; }
agent_disabled() { ! systemctl is-enabled --quiet dnsunlock-agent 2>/dev/null; }

# 断言函数的 stdout 会被 assert 吞掉（>/dev/null），所以 F3-01 的逐次 dig
# 与 resolvectl 原文必须同时写进场景证据文件（$EVID_FILE），否则无日志可查。
evid() { echo "$*" | tee -a "${EVID_FILE:-/root/v016/evidence.txt}"; }

dig_tiktok_upstream_x5() { # dig @127.0.0.53 tiktok.com A ×5，全部回上游（非空、非规则 IP）；逐次打印原文
  local i=0 ip=""
  while [ "$i" -lt 5 ]; do
    i=$((i+1))
    ip=$(dig +short @127.0.0.53 tiktok.com A 2>/dev/null | head -1)
    evid "  dig #$i @127.0.0.53 tiktok.com A -> ${ip:-(none)}"
    [ -n "$ip" ] && [ "$ip" != "$RULE_IP" ] || return 1
  done
  return 0
}
global_dns_clean() { # resolvectl dns 的 Global: 行不含 127.0.0.1（还原后应为空）
  evid "  resolvectl dns:"
  resolvectl dns 2>/dev/null | sed 's/^/    /' | tee -a "${EVID_FILE:-/root/v016/evidence.txt}"
  ! resolvectl dns 2>/dev/null | grep "^Global:" | grep -q "127.0.0.1"
}

do_install_sni() { # do_install_sni <allowlist> <log>：--unlock-node 只装 SNI 代理
  local allow="$1" log="$2"
  curl -fsSL "$PANEL_URL/install.sh" -o /tmp/install-sni.sh || { echo "下载 install.sh 失败"; LAST_RC=99; return 0; }
  DNS_AGENT_TOKEN="$DNS_AGENT_TOKEN" DNS_SNI_ALLOWLIST="$allow" \
    script -qec "bash /tmp/install-sni.sh --panel $PANEL_URL --unlock-node" \
    /dev/null < /dev/null > "$log" 2>&1
  LAST_RC=$?
  echo "install sni allowlist=$allow rc=$LAST_RC（日志 $log）"
  return 0
}

sni_probe() { # sni_probe：经 127.0.0.1:443 做一次 TLS 握手（SNI=example.com）。
  # 放行 → 代理把 ClientHello 转给 example.com:443，握手成功；拒绝 → accept 后立即关，握手 EOF。
  # 打印 ALLOWED/DENIED，exit 0=放行，exit 1=拒绝。python3 在镜像内（provision-rootfs 清单）。
  python3 - "$@" <<'PYEOF'
import socket, ssl, sys
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    raw = socket.create_connection(("127.0.0.1", 443), timeout=8)
    try:
        s = ctx.wrap_socket(raw, server_hostname="example.com")
        print("SNI-PROBE: ALLOWED (TLS handshake ok, peer=%s)" % s.version())
        s.close()
        sys.exit(0)
    except Exception as e:
        print("SNI-PROBE: DENIED (handshake failed: %s)" % e)
        sys.exit(1)
except Exception as e:
    print("SNI-PROBE: DENIED (connect failed: %s)" % e)
    sys.exit(1)
PYEOF
}
sni_allowed() { sni_probe | tee /root/v016/sni-probe-last.txt | grep -q "ALLOWED"; }
sni_denied() { ! sni_allowed; }

f301_asserts_immediate() { # 还原后立即的三项 F3-01 断言（$1=日志前缀，用于命名）
  assert "F3-01 还原后立即 dig @127.0.0.53 tiktok ×5 全走上游" dig_tiktok_upstream_x5
  assert "F3-01 还原后 resolvectl dns Global: 为空（无 127.0.0.1）" global_dns_clean
  assert "F3-01 还原后 getent tiktok 走上游（分流已断）" getent_tiktok_upstream
  # 补充诊断：agent 重启后需 ~1s 从面板拉规则才开始回规则 IP，立即 dig 时它还
  # 没规则、全走上游；延迟 3 秒再测 ×5，红版的闪烁才现形（R2 的 getent 失败
  # 就是在稍晚时刻命中的）。绿版 Global 已空，延迟测也应全走上游。
  sleep 3
  evid "--- 延迟 3 秒后复测 dig ×5 ---"
  assert "F3-01 延迟 3 秒后 dig @127.0.0.53 tiktok ×5 仍全走上游" dig_tiktok_upstream_x5
}

scen_f301c() {  # F3-01 CHOSEN 路：永久接管 → 还原（结构化备份）
  EVID_FILE=/root/v016/f301c-dig5.txt; : > "$EVID_FILE"
  reset_state; baseline_asserts
  do_install 127.0.0.1:53 0 /root/v016/f301c-install.log
  assert "永久安装 rc=0" last_rc0
  assert "永久安装后 getent tiktok 走规则" getent_rule_ok
  assert "永久安装后 resolv.conf=127.0.0.1" resolv_is_127001
  assert "永久安装后 agent 在跑" agent_active
  echo "--- F3-01 CHOSEN：还原 ---"
  do_restore /root/v016/f301c-restore.log
  assert "还原 rc=0" last_rc0
  f301_asserts_immediate
  assert "还原后 resolv.conf 回 stub 软链" resolv_is_stub_link
  assert "还原后 resolved 在跑" resolved_active
  assert "还原后系统 DNS 可用" getent_example_ok
  assert "还原后 agent 已恢复运行（特定地址分支）" agent_active
  snapshot "f301c 末态"
  reset_state
  summary
}

scen_f301l() {  # F3-01 legacy 路：永久接管 → 删结构化备份、留 .orig → 还原走老路
  EVID_FILE=/root/v016/f301l-dig5.txt; : > "$EVID_FILE"
  reset_state; baseline_asserts
  do_install 127.0.0.1:53 0 /root/v016/f301l-install.log
  assert "永久安装 rc=0" last_rc0
  assert "永久安装后 getent tiktok 走规则" getent_rule_ok
  assert "永久安装后 agent 在跑" agent_active
  # 搭 legacy 状态：install 的 do_backup 已写好 /etc/dnsunlock/resolv.conf.orig
  # + .orig.link（指向首份备份的兼容指针）；删掉全部结构化备份目录，迫使还原走老路。
  assert "legacy 前 .orig 存在" sh -c '[ -f /etc/dnsunlock/resolv.conf.orig ]'
  assert "legacy 前 .orig.link 存在" sh -c '[ -f /etc/dnsunlock/resolv.conf.orig.link ]'
  echo "legacy 前 .orig.link 内容：$(cat /etc/dnsunlock/resolv.conf.orig.link 2>/dev/null)"
  rm -rf /var/lib/dnsunlock/backup/*
  assert "legacy 前无结构化备份目录" sh -c '[ -z "$(ls -A /var/lib/dnsunlock/backup 2>/dev/null)" ]'
  echo "--- F3-01 legacy：还原 ---"
  do_restore /root/v016/f301l-restore.log
  assert "还原走了老路（日志含 走老路还原）" sh -c 'grep -qF "走老路还原" /root/v016/f301l-restore.log'
  assert "还原 rc=0" last_rc0
  f301_asserts_immediate
  assert "还原后 resolv.conf 回 stub 软链" resolv_is_stub_link
  assert "还原后 resolved 在跑" resolved_active
  assert "还原后系统 DNS 可用" getent_example_ok
  assert "还原后 agent 已恢复运行（特定地址分支）" agent_active
  snapshot "f301l 末态"
  reset_state
  summary
}

scen_f302a() {  # F3-02 agent：agent 在 :53 跑时重装 --dns-listen 127.0.0.1:5353
  reset_state; baseline_asserts
  do_install 127.0.0.1:53 0 /root/v016/f302a-install.log
  assert "首次安装 rc=0" last_rc0
  assert "首次安装后 agent 在跑" agent_active
  local pid_before=""
  pid_before=$(agent_pid)
  echo "重装前 agent MainPID=$pid_before"
  [ -n "$pid_before" ] && [ "$pid_before" != "0" ] || { echo "重装前取不到 agent PID"; exit 2; }
  echo "--- F3-02 agent：重装 --dns-listen 127.0.0.1:5353 ---"
  do_install 127.0.0.1:5353 0 /root/v016/f302a-reinstall.log
  assert "重装 rc=0" last_rc0
  local pid_after=""
  pid_after=$(agent_pid)
  echo "重装后 agent MainPID=$pid_after（之前 $pid_before）"
  assert "重装后 Main PID 变化（新配置已加载）" sh -c "[ -n \"$pid_after\" ] && [ \"$pid_after\" != \"0\" ] && [ \"$pid_after\" != \"$pid_before\" ]"
  assert "重装后 dig -p 5353 tiktok → 规则 IP（UDP）" sh -c 'dig -p 5353 +short @127.0.0.1 tiktok.com A 2>/dev/null | grep -qx "203.0.113.99"'
  # v12 断言修正同款：守卫文案只在安装走到接管提问时才断言。
  if grep -qF "是否把本机系统 DNS" /root/v016/f302a-reinstall.log; then
    assert "重装日志明说本次不接管（5353 不接管）" sh -c 'grep -qF "本次不接管" /root/v016/f302a-reinstall.log'
  else
    echo "[SKIP] 重装未走到接管提问，守卫文案断言不可达，不计入"
  fi
  assert "重装后 resolv.conf 仍是接管态（未新接管）" resolv_is_127001
  echo "--- F3-02 agent：还原收尾 ---"
  do_restore /root/v016/f302a-restore.log
  assert "还原 rc=0" last_rc0
  assert "还原后 resolv.conf 回 stub 软链" resolv_is_stub_link
  assert "还原后系统 DNS 恢复" getent_example_ok
  snapshot "f302a 末态"
  reset_state
  summary
}

scen_f302s() {  # F3-02 SNI：装 SNI（allowlist A=127.0.0.1）→ 重装改 allowlist B=203.0.113.7
  reset_state; baseline_asserts
  # SNI 探针依赖容器直连 egress（代理把 ClientHello 转给 example.com:443）；先证 egress 可用。
  assert "容器直连 egress 可用（curl example.com）" sh -c 'curl -fsSI --max-time 10 https://example.com -o /dev/null'
  assert "容器 :443 空闲" sh -c '! ss -tln 2>/dev/null | grep -q ":443 "'
  echo "--- F3-02 SNI：首次安装 allowlist A=127.0.0.1 ---"
  do_install_sni 127.0.0.1 /root/v016/f302s-install-a.log
  assert "SNI 首次安装 rc=0" last_rc0
  assert "SNI 代理在跑" proxy_active
  assert "SNI 代理在 :443 监听" sh -c 'ss -tln 2>/dev/null | grep -q ":443 "'
  local pid_before=""
  pid_before=$(proxy_pid)
  echo "重装前 proxy MainPID=$pid_before"
  assert "allowlist A 下 127.0.0.1 被放行（探针 ALLOWED）" sni_allowed
  echo "--- F3-02 SNI：重装改 allowlist B=203.0.113.7 ---"
  do_install_sni 203.0.113.7 /root/v016/f302s-install-b.log
  assert "SNI 重装 rc=0" last_rc0
  assert "SNI 重装日志有“新配置已加载”验证通过" sh -c 'grep -qF "新 allowlist 已加载" /root/v016/f302s-install-b.log'
  local pid_after=""
  pid_after=$(proxy_pid)
  echo "重装后 proxy MainPID=$pid_after（之前 $pid_before）"
  assert "SNI 重装后 Main PID 变化" sh -c "[ -n \"$pid_after\" ] && [ \"$pid_after\" != \"0\" ] && [ \"$pid_after\" != \"$pid_before\" ]"
  assert "SNI 配置文件已写新 allowlist B" sh -c 'grep -q "203.0.113.7" /etc/dnsunlock/config.json'
  assert "新 allowlist 生效：127.0.0.1 被拒绝（探针 DENIED）" sni_denied
  assert "SNI 代理仍在跑" proxy_active
  systemctl stop dnsunlock-proxy 2>/dev/null || true
  systemctl disable dnsunlock-proxy 2>/dev/null || true
  rm -f /etc/systemd/system/dnsunlock-proxy.service
  systemctl daemon-reload 2>/dev/null || true
  snapshot "f302s 末态"
  reset_state
  summary
}

scen_f303() {  # F3-03：agent enabled 但已停时还原 → 还原后 agent 为 disabled
  reset_state; baseline_asserts
  do_install 127.0.0.1:53 0 /root/v016/f303-install.log
  assert "永久安装 rc=0" last_rc0
  assert "永久安装后 agent 在跑" agent_active
  assert "永久安装后 agent enabled" agent_enabled
  systemctl stop dnsunlock-agent
  assert "还原前 agent 已停" agent_inactive
  assert "还原前 agent 仍 enabled（待还原 disable）" agent_enabled
  echo "--- F3-03：还原 ---"
  do_restore /root/v016/f303-restore.log
  assert "还原 rc=0" last_rc0
  assert "还原后 agent 为 disabled" agent_disabled
  assert "还原日志有 disable 说明（已直接改为不开机自启）" sh -c 'grep -qF "已直接改为不开机自启" /root/v016/f303-restore.log'
  assert "还原后 agent 仍停着" agent_inactive
  assert "还原后 resolv.conf 回 stub 软链" resolv_is_stub_link
  assert "还原后系统 DNS 可用" getent_example_ok
  snapshot "f303 末态"
  reset_state
  summary
}

# ---------------- 分派 ----------------
case "$SCENARIO" in
  r201) [ "$PHASE" = p1 ] && scen_r201_p1 || scen_r201_p2 ;;
  g201) [ "$PHASE" = p1 ] && scen_g201_p1 || scen_g201_p2 ;;
  r202) scen_r202 ;;
  g202) scen_g202 ;;
  r204) scen_r204 ;;
  g204) scen_g204 ;;
  r215) scen_r215 ;;
  v12)  scen_v12 ;;
  f301c) scen_f301c ;;
  f301l) scen_f301l ;;
  f302a) scen_f302a ;;
  f302s) scen_f302s ;;
  f303) scen_f303 ;;
  *) echo "未知场景：$SCENARIO"; echo "用法：guest.sh r201|g201 p1|p2 | r202|g202|r204|g204|r215|v12 | f301c|f301l|f302a|f302s|f303"; exit 2 ;;
esac
