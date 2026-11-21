#!/bin/bash
# 台架内驱动（chroot 内跑）。/dev/tty 由外层 script(1) 的 pty 提供，
# 全部交互答案由宿主脚本按场景顺序一次性喂进 pty（见 test-takeover-rig.sh 的答案表）。
# 注意：不要在这里加新的交互提问——每多一个提问，答案流就错一位。
#
# 沙箱 UDP 回环限制（2026-11-21 实测，Go UDP echo：server 收到包、client
# 永远等不到回包，chroot 内外都一样；UDP 到 198.19.0.1 等外部地址正常）：
#   - dig 一律 +tcp（dig 不读 resolv.conf 的 options use-vc）；
#   - probe_agent_transport 在沙箱里永远判 UDP 死、TCP 活 → USE_VC=1，
#     所以接管写出的 resolv.conf 带 options use-vc，getent 靠它走 TCP；
#     “UDP 通 → 不写 use-vc”那条路沙箱里测不了，只在 S14 用假 dig 单测。
#   - ss 在 chroot 里依赖 /proc：宿主脚本挂了 proc 之后才看得见真监听。
export PATH=/root/rig/stubs:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
set -u
RIG=/root/rig
LOG=$RIG/logs
STATE=$RIG/state
TOKEN="${DNS_AGENT_TOKEN:-}"
SERVER_ID="${RIG_SERVER_ID:-}"
PANEL_URL="${PANEL_URL:-http://127.0.0.1:18080}"
export PANEL_BASE="$PANEL_URL"  # S14 提取的 verify_rule_domain 引用它
RULE_DOMAIN=tiktok.com
RULE_IP=203.0.113.99
INSTALL=$RIG/install.sh
PASS=0; FAIL=0; FAILED_NAMES=()
RUN_RC=99

[ -n "$TOKEN" ] || { echo "缺少 DNS_AGENT_TOKEN"; exit 2; }
[ -n "$SERVER_ID" ] || { echo "缺少 RIG_SERVER_ID"; exit 2; }
[ -r /dev/tty ] || { echo "台架错误: /dev/tty 不可读（chroot 缺设备节点，宿主脚本应 bind 挂 /dev/tty）；否则全部交互提问默认否"; exit 2; }

pass() { PASS=$((PASS+1)); echo "[PASS] $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); echo "[FAIL] $1"; }
assert() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
expect_fail() { if "$@" >/dev/null 2>&1; then return 1; else return 0; fi; }
assert_rc0() { [ "${RUN_RC:-99}" = 0 ]; }
assert_rc1() { [ "${RUN_RC:-99}" = 1 ]; }
file_has() { grep -qF "$2" "$1" 2>/dev/null; }
file_lacks() { ! grep -qF "$2" "$1" 2>/dev/null; }
files_eq() { cmp -s "$1" "$2"; }
file_absent() { [ ! -f "$1" ]; }
backup_count() { ls -d /var/lib/dnsunlock/backup/*/ 2>/dev/null | wc -l; }
count_is_n() { [ "$(backup_count)" = "$1" ]; }
newest_backup() { ls -dt /var/lib/dnsunlock/backup/*/ 2>/dev/null | head -1; }
newest_meta_has() { grep -q "$1" "$(newest_backup)/metadata.txt" 2>/dev/null; }
markers_has() { grep -qF "$1" "$LOG/markers.log" 2>/dev/null; }
calls_has() { grep -qF "$1" "$LOG/calls.log" 2>/dev/null; }
resolv_is_127() { [ "$(head -1 /etc/resolv.conf 2>/dev/null)" = "nameserver 127.0.0.1" ]; }
resolv_no_usevc() { ! grep -q "options use-vc" /etc/resolv.conf 2>/dev/null; }
resolv_has_usevc() { grep -q "options use-vc" /etc/resolv.conf 2>/dev/null; }
is_locked() { lsattr /etc/resolv.conf 2>/dev/null | grep -q -- '----i'; }
is_unlocked() { ! lsattr /etc/resolv.conf 2>/dev/null | grep -q -- '----i'; }
nm_confd_dnsnone() { [ -f /etc/NetworkManager/conf.d/dnsunlock.conf ] && grep -q "dns=none" /etc/NetworkManager/conf.d/dnsunlock.conf; }
nsswitch_has_dns() { grep -qE '^hosts:.*\bdns\b' /etc/nsswitch.conf 2>/dev/null; }
dig_rule_ok() { dig +tcp +short "@127.0.0.1" "$RULE_DOMAIN" A 2>/dev/null | grep -qx "$RULE_IP"; }
dig_example_upstream() { local out; out=$(dig +tcp +short @127.0.0.1 example.com A 2>/dev/null | grep -E '^[0-9]+\.' | head -1); [ -n "$out" ] && [ "$out" != "$RULE_IP" ]; }
getent_rule_ok() { getent hosts "$RULE_DOMAIN" 2>/dev/null | grep -q "$RULE_IP"; }
getent_rule_not() { ! getent hosts "$RULE_DOMAIN" 2>/dev/null | grep -q "$RULE_IP"; }
getent_example_ok() { getent hosts example.com 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; }

port53_free() { /root/rig/bin/bindprobe "" 53; }
port53_busy() { ! port53_free; }  # V016-13：S14 前置断言用（:53 被 agent 占住）

stop_agent() {
  if [ -f "$STATE/agent.pid" ]; then
    kill "$(cat "$STATE/agent.pid")" 2>/dev/null || true
    sleep 1
    rm -f "$STATE/agent.pid"
  fi
}

write_agent_config() {
  # $1=dns_listen（如 :53）
  mkdir -p /etc/dnsunlock
  cat > /etc/dnsunlock/config.json <<EOF
{"mode":"dns-agent","panel_url":"$PANEL_URL","agent_token":"$TOKEN","server_id":"$SERVER_ID","dns_listen":"$1","allowlist":"127.0.0.1"}
EOF
  chmod 600 /etc/dnsunlock/config.json
}

wait_for_rule() {
  local i=0
  while [ "$i" -lt 15 ]; do
    dig_rule_ok && return 0
    sleep 1; i=$((i+1))
  done
  echo "wait_for_rule: 15 秒后 agent 仍未返回规则 IP" >&2
  return 1
}

wait_for_rule_getent() {
  local i=0
  while [ "$i" -lt 10 ]; do
    getent_rule_ok && return 0
    sleep 1; i=$((i+1))
  done
  echo "wait_for_rule_getent: 10 秒后系统解析仍未返回规则 IP" >&2
  return 1
}

reset_state() {
  # 复位 /etc 与 stub 状态；不动 /var/lib/dnsunlock 与 /etc/dnsunlock（备份留给场景管）
  chattr -i /etc/resolv.conf 2>/dev/null || true
  cp -f "$RIG/fixtures/resolv.conf.base" /etc/resolv.conf
  cp -f "$RIG/fixtures/nsswitch.base" /etc/nsswitch.conf
  rm -rf /etc/systemd/resolved.conf.d /etc/NetworkManager/conf.d
  rm -f /etc/resolvconf/resolv.conf.d/head.dnsunlock
  : > "$LOG/calls.log"; : > "$LOG/markers.log"
  echo yes > "$STATE/systemd-resolved.active"; echo yes > "$STATE/systemd-resolved.enabled"
  echo no > "$STATE/NetworkManager.active"; echo no > "$STATE/NetworkManager.enabled"
  echo no > "$STATE/resolvconf.active"; echo no > "$STATE/resolvconf.enabled"
  : > "$STATE/chattr.locked"
  rm -f "$STATE/stub-holder.pid"
}

reset_backups() {
  stop_agent
  rm -rf /var/lib/dnsunlock /etc/dnsunlock
  mkdir -p /var/lib/dnsunlock/backup /etc/dnsunlock
}

run_install() {
  # $1=输出日志；其余参数透传给 install.sh。先停掉上个场景的 agent，
  # 否则 :53 被占、install.sh 的端口检查直接退出。答案来自 pty 流。
  local log="$1"; shift
  stop_agent
  port53_free || echo "警告: 停掉上个 agent 后 :53 仍被占（本次安装的端口检查可能失败）" >&2
  DNS_AGENT_TOKEN="$TOKEN" DNS_SERVER_NAME="rig-dns" DNS_DEFAULT_IP="203.0.113.99" DNS_ALLOWLIST="127.0.0.1" \
    bash "$INSTALL" --panel "$PANEL_URL" "$@" > "$log" 2>&1
  RUN_RC=$?
}

run_restore() {
  # $1=输出日志；其余参数透传给 dnsunlock-restore-dns
  local log="$1"; shift
  /usr/local/bin/dnsunlock-restore-dns "$@" > "$log" 2>&1
  RUN_RC=$?
}

cleanup() {
  stop_agent
  if [ -f "$STATE/stub-holder.pid" ]; then kill "$(cat "$STATE/stub-holder.pid")" 2>/dev/null || true; rm -f "$STATE/stub-holder.pid"; fi
  [ -f /usr/bin/dig.bak ] && mv -f /usr/bin/dig.bak /usr/bin/dig
}
trap cleanup EXIT

mkdir -p "$LOG" "$STATE" /etc/dnsunlock /var/lib/dnsunlock/backup
reset_backups; reset_state

echo "=== S0 基线：agent 直连 DNS ==="
write_agent_config ":53"
nohup /root/rig/bin/dnsunlock dns-agent --config /etc/dnsunlock/config.json >> "$LOG/agent.log" 2>&1 &
echo $! > "$STATE/agent.pid"
wait_for_rule
assert "S0 dig @agent tiktok.com 返回规则 IP" dig_rule_ok
assert "S0 dig @agent example.com 走上游（非规则 IP）" dig_example_upstream
assert "S0 基线 getent tiktok.com 不走 agent（走上游）" getent_rule_not
assert "S0 基线 getent example.com 有结果" getent_example_ok
stop_agent
assert "S0 停 agent 后 :53 已释放（防级联占用）" port53_free

echo "=== S1b stub-only 接管（127.0.0.53:53 被占）==="
reset_state
/root/rig/bin/bindhold "$STATE/stub-holder.pid" >> "$LOG/bindhold.log" 2>&1 &
i=0; while [ "$i" -lt 5 ]; do ss -tuln 2>/dev/null | grep -q '127.0.0.53:53' && break; sleep 1; i=$((i+1)); done
assert "S1b bindhold 已占住 127.0.0.53:53" bash -c "ss -tuln | grep -q '127.0.0.53:53'"
run_install "$LOG/s1b.log"
assert "S1b install rc=0" assert_rc0
assert "S1b 提示关 stub 并确认已关" file_has "$LOG/s1b.log" "stub 已关"
assert "S1b drop-in 已写 DNSStubListener=no" file_has /etc/systemd/resolved.conf.d/dnsunlock.conf "DNSStubListener=no"
assert "S1b bindhold 已被 restart 干掉" file_absent "$STATE/stub-holder.pid"
assert "S1b 127.0.0.53:53 已释放" bash -c "! ss -tuln | grep -q '127.0.0.53:53'"
assert "S1b 备份目录恰好 1 个" count_is_n 1
assert "S1b metadata 标签 pre-takeover" newest_meta_has "^label=pre-takeover"
assert "S1b metadata 当时 DNS 含 198.19.0.1" newest_meta_has "198.19.0.1"
assert "S1b metadata 含 resolved 后端" newest_meta_has "backends=.*resolved"
assert "S1b 备份的 resolv.conf 就是原文件" files_eq "$(newest_backup)/resolv.conf" "$RIG/fixtures/resolv.conf.base"
assert "S1b resolv.conf 已是 127.0.0.1" resolv_is_127
assert "S1b 有 use-vc（沙箱 UDP 回环不通，探测判 TCP，见文件头）" resolv_has_usevc
assert "S1b NM conf.d 已写 dns=none" nm_confd_dnsnone
assert "S1b chattr +i 已锁" is_locked
assert "S1b systemctl 调过 restart resolved" markers_has "restart systemd-resolved"
assert "S1b systemctl 调过 reload NetworkManager" markers_has "reload NetworkManager"
assert "S1b nmcli 被调过（取 UUID）" calls_has "nmcli"
wait_for_rule
assert "S1b 接管后 getent tiktok.com 返回规则 IP" getent_rule_ok
assert "S1b 接管后 getent example.com 仍走上游" getent_example_ok
assert "S1b .orig 兼容指针内容是原文件" files_eq /etc/dnsunlock/resolv.conf.orig "$RIG/fixtures/resolv.conf.base"

echo "=== S2 二次接管：首份备份永不覆盖 ==="
reset_state
run_install "$LOG/s2.log"
assert "S2 install rc=0" assert_rc0
assert "S2 备份目录变成 2 个" count_is_n 2
assert "S2 .orig 仍是原始内容" files_eq /etc/dnsunlock/resolv.conf.orig "$RIG/fixtures/resolv.conf.base"
assert "S2 最早一份备份仍是原始内容" files_eq "$(ls -dt /var/lib/dnsunlock/backup/*/ | tail -1)/resolv.conf" "$RIG/fixtures/resolv.conf.base"
assert "S2 最新一份备份是本次接管前状态（reset 后 base）" files_eq "$(newest_backup)/resolv.conf" "$RIG/fixtures/resolv.conf.base"

echo "=== S3 还原回滚（--yes，默认最早一份）==="
run_restore "$LOG/s3.log" --yes
assert "S3 restore rc=0" assert_rc0
assert "S3 resolv.conf 已还原为原文件" files_eq /etc/resolv.conf "$RIG/fixtures/resolv.conf.base"
assert "S3 NM dns=none 配置已删" file_absent /etc/NetworkManager/conf.d/dnsunlock.conf
assert "S3 resolved drop-in 已删" file_absent /etc/systemd/resolved.conf.d/dnsunlock.conf
assert "S3 chattr 锁已解" is_unlocked
assert "S3 还原后验证通过" file_has "$LOG/s3.log" "已还原并验证通过"
assert "S3 还原后 getent tiktok.com 不再是规则 IP" getent_rule_not
assert "S3 还原后 getent example.com 有结果" getent_example_ok
assert "S3 还原前自动备份了当前状态（备份数 3）" count_is_n 3

echo "=== S4 --temp：resolvectl 路径 ==="
reset_state
BEFORE=$(backup_count)
run_install "$LOG/s4.log" --temp
assert "S4 install rc=0" assert_rc0
assert "S4 resolvectl 被调 dns <网卡> 127.0.0.1" markers_has "resolvectl dns"
assert "S4 markers 含 127.0.0.1" markers_has "127.0.0.1"
assert "S4 未写永久备份" count_is_n "$BEFORE"
assert "S4 resolv.conf 未动（resolvectl 路径不写文件）" files_eq /etc/resolv.conf "$RIG/fixtures/resolv.conf.base"
assert "S4 输出说明临时模式" file_has "$LOG/s4.log" "临时模式"
assert "S4 输出说明重启后失效" file_has "$LOG/s4.log" "重启后失效"

echo "=== S5 --temp：resolved 未跑，直接写文件 ==="
reset_state
echo no > "$STATE/systemd-resolved.active"
BEFORE=$(backup_count)
run_install "$LOG/s5.log" --temp
assert "S5 install rc=0" assert_rc0
assert "S5 resolv.conf 已写 127.0.0.1" resolv_is_127
assert "S5 未加 chattr 锁" is_unlocked
assert "S5 未写永久备份" count_is_n "$BEFORE"
assert "S5 输出说明临时模式" file_has "$LOG/s5.log" "临时模式"
cp -f "$RIG/fixtures/resolv.conf.base" /etc/resolv.conf

echo "=== S6 缺 dig：警告 + 继续安装 ==="
reset_state
mv /usr/bin/dig /usr/bin/dig.bak
BEFORE=$(backup_count)
run_install "$LOG/s6.log"
assert "S6 install rc=0" assert_rc0
assert "S6 输出缺 dig 警告" file_has "$LOG/s6.log" "未装 dig"
assert "S6 输出继续安装" file_has "$LOG/s6.log" "继续安装"
assert "S6 输出给手动验证命令" file_has "$LOG/s6.log" "请手动验证"
assert "S6 接管仍完成" resolv_is_127
# 沙箱里缺 dig → 探不到传输方式 → 默认不写 use-vc → getent 走 UDP 死路，
# 所以这里按设计走升级 + 大声警告，不可能返回规则 IP（真机上 UDP 通则能过）。
# 断言失败路径本身，而不是规则 IP。
assert "S6 输出升级处理（验证失败后 disable resolved）" file_has "$LOG/s6.log" "升级处理"
assert "S6 输出验证未通过大声警告" file_has "$LOG/s6.log" "验证未通过"
mv /usr/bin/dig.bak /usr/bin/dig
run_restore "$LOG/s6-restore.log" --yes
assert "S6 清理：还原回原文件" files_eq /etc/resolv.conf "$RIG/fixtures/resolv.conf.base"

echo "=== S7a 手动输入：非法地址拒绝 ==="
reset_state
run_install "$LOG/s7a.log" --panel http://127.0.0.1:9
assert "S7a install rc=1" assert_rc1
assert "S7a 报错面板地址格式不对" file_has "$LOG/s7a.log" "面板地址格式不对"

echo "=== S7b 手动输入：合法地址继续安装 ==="
reset_state
run_install "$LOG/s7b.log" --panel http://127.0.0.1:9
assert "S7b install rc=0" assert_rc0
assert "S7b 输出已自动改走手动地址" file_has "$LOG/s7b.log" "已自动改走 $PANEL_URL"
assert "S7b 接管完成" resolv_is_127
wait_for_rule
assert "S7b 接管后 getent 规则 IP" getent_rule_ok
run_restore "$LOG/s7b-restore.log" --yes
assert "S7b 清理：还原回原文件" files_eq /etc/resolv.conf "$RIG/fixtures/resolv.conf.base"

echo "=== S8 摘要确认默认 N：取消接管 ==="
reset_state
BEFORE=$(backup_count)
run_install "$LOG/s8.log"
assert "S8 install rc=0（取消接管仍算安装完成）" assert_rc0
assert "S8 输出已取消接管" file_has "$LOG/s8.log" "已取消接管"
assert "S8 未写备份" count_is_n "$BEFORE"
assert "S8 resolv.conf 未动" files_eq /etc/resolv.conf "$RIG/fixtures/resolv.conf.base"

echo "=== S9a hpve-init：默认 N，取消接管 ==="
reset_state
cp -f "$RIG/fixtures/resolv.conf.hpve" /etc/resolv.conf
BEFORE=$(backup_count)
run_install "$LOG/s9a.log"
assert "S9a install rc=0" assert_rc0
assert "S9a 输出 hpve-init 提示" file_has "$LOG/s9a.log" "hpve-init"
assert "S9a 未写备份" count_is_n "$BEFORE"
assert "S9a resolv.conf 未动" files_eq /etc/resolv.conf "$RIG/fixtures/resolv.conf.hpve"

echo "=== S9b hpve-init：确认后继续接管 ==="
reset_state
cp -f "$RIG/fixtures/resolv.conf.hpve" /etc/resolv.conf
run_install "$LOG/s9b.log"
assert "S9b install rc=0" assert_rc0
assert "S9b 接管完成" resolv_is_127
assert "S9b 备份 metadata 含原 DNS 1.1.1.1" newest_meta_has "1.1.1.1"
run_restore "$LOG/s9b-restore.log" --yes
assert "S9b 清理：还原回 hpve 文件" files_eq /etc/resolv.conf "$RIG/fixtures/resolv.conf.hpve"

echo "=== S10 nsswitch：hosts 行补 dns ==="
reset_state
cp -f "$RIG/fixtures/nsswitch.nodns" /etc/nsswitch.conf
assert "S10 前置：hosts 行无 dns" file_lacks /etc/nsswitch.conf "dns"
run_install "$LOG/s10.log"
assert "S10 install rc=0" assert_rc0
assert "S10 hosts 行已补 dns" nsswitch_has_dns
B_S10=$(newest_backup)  # 本次接管前备份（nsswitch 还是无 dns 的那份；最早一份是带 dns 的 base，不能用）
run_restore "$LOG/s10-restore.log" --backup "$B_S10" --yes
assert "S10 还原后 nsswitch 回到无 dns" file_lacks /etc/nsswitch.conf "dns"
assert "S10 还原后 drop-in 已删（stash 记 absent）" file_absent /etc/systemd/resolved.conf.d/dnsunlock.conf

echo "=== S11 升级路径：验证不走 agent → disable --now resolved ==="
reset_state
run_install "$LOG/s11.log" --dns-listen 127.0.0.1:15353
assert "S11 install rc=0" assert_rc0
assert "S11 输出升级处理" file_has "$LOG/s11.log" "升级处理"
assert "S11 输出验证未通过警告" file_has "$LOG/s11.log" "验证未通过"
assert "S11 systemctl 记了 disable --now resolved" markers_has "disable systemd-resolved"
assert "S11 resolv.conf 仍是 127.0.0.1" resolv_is_127
run_restore "$LOG/s11-restore.log" --yes
assert "S11 还原后验证通过" file_has "$LOG/s11-restore.log" "已还原并验证通过"
assert "S11 还原回原文件" files_eq /etc/resolv.conf "$RIG/fixtures/resolv.conf.base"

echo "=== S12 Tailscale 守卫 ==="
reset_state
cp -f "$RIG/fixtures/resolv.conf.tailscale" /etc/resolv.conf
BEFORE=$(backup_count)
run_install "$LOG/s12.log"
assert "S12 install rc=0" assert_rc0
assert "S12 输出 Tailscale 提示" file_has "$LOG/s12.log" "Tailscale"
assert "S12 未写备份" count_is_n "$BEFORE"
assert "S12 resolv.conf 未动" files_eq /etc/resolv.conf "$RIG/fixtures/resolv.conf.tailscale"

echo "=== S13 还原 --backup 指定备份 ==="
reset_state
run_install "$LOG/s13.log"
assert "S13 install rc=0" assert_rc0
B_NEW=$(newest_backup)
run_restore "$LOG/s13-restore.log" --backup "$B_NEW" --yes
assert "S13 restore rc=0" assert_rc0
assert "S13 resolv.conf 等于指定备份的内容" files_eq /etc/resolv.conf "$B_NEW/resolv.conf"
run_restore "$LOG/s13-restore2.log" --yes
assert "S13 默认还原回原文件" files_eq /etc/resolv.conf "$RIG/fixtures/resolv.conf.base"

echo "=== S14 函数级：validate_ipv4 / valid_panel_url / probe / UUID / verify ==="
# V016-13：S14 自给自足——不再假设 S13 残留的 agent 还在跑。
# P1(a) 之后 S13 的还原会停掉 agent（通配符分支保持停止），S14 若不自己起
# agent，getent 走 127.0.0.1:53 必然失败。开头显式起 agent，结尾停掉。
write_agent_config ":53"
nohup /root/rig/bin/dnsunlock dns-agent --config /etc/dnsunlock/config.json >> "$LOG/agent.log" 2>&1 &
echo $! > "$STATE/agent.pid"
assert "S14 前置：agent 已起并返回规则 IP" wait_for_rule
assert "S14 前置：agent 正在 :53 监听" port53_busy
awk '/^(validate_ipv4|valid_panel_url|probe_agent_transport|get_active_nm_connection_uuid|get_primary_interface|verify_system_dns|verify_rule_domain)\(\) [{]$/,/^[}]$/' "$INSTALL" > /tmp/rig-funcs.sh
assert "S14 函数提取成功" bash -c "[ -s /tmp/rig-funcs.sh ]"
bash -n /tmp/rig-funcs.sh && pass "S14 提取的函数 bash -n 通过" || fail "S14 提取的函数 bash -n 通过"
USE_VC=0
# shellcheck disable=SC1091
source /tmp/rig-funcs.sh
assert "S14 validate_ipv4 1.2.3.4 通过" validate_ipv4 1.2.3.4
assert "S14 validate_ipv4 999.1.1.1 拒绝" expect_fail validate_ipv4 999.1.1.1
assert "S14 validate_ipv4 1.2.3 拒绝" expect_fail validate_ipv4 1.2.3
assert "S14 validate_ipv4 1.2.3.4.5 拒绝" expect_fail validate_ipv4 1.2.3.4.5
assert "S14 validate_ipv4 空拒绝" expect_fail validate_ipv4 ""
assert "S14 validate_ipv4 0.0.0.0 通过" validate_ipv4 0.0.0.0
assert "S14 valid_panel_url http://203.0.113.5:8080 通过" valid_panel_url "http://203.0.113.5:8080"
assert "S14 valid_panel_url 999.1.1.1 拒绝" expect_fail valid_panel_url "http://999.1.1.1:8080"
assert "S14 valid_panel_url https 域名通过" valid_panel_url "https://dns.example.com"
assert "S14 valid_panel_url IPv6 通过" valid_panel_url "http://[::1]:8080"
assert "S14 valid_panel_url ftp 拒绝" expect_fail valid_panel_url "ftp://x"
assert "S14 valid_panel_url 端口超范围拒绝" expect_fail valid_panel_url "http://host:99999"
assert "S14 valid_panel_url 端口非数字拒绝" expect_fail valid_panel_url "http://host:abc"
# probe_agent_transport：假 dig 三种模式
mkdir -p /tmp/rig-fakedig-a /tmp/rig-fakedig-b /tmp/rig-nodig
printf '#!/bin/bash\ncase "$*" in *"+tcp"*) echo "93.184.216.34";; *) exit 1;; esac\n' > /tmp/rig-fakedig-a/dig
printf '#!/bin/bash\necho "93.184.216.34"\n' > /tmp/rig-fakedig-b/dig
chmod +x /tmp/rig-fakedig-a/dig /tmp/rig-fakedig-b/dig
ln -sf /usr/bin/grep /tmp/rig-nodig/grep
probe_tcp_only() { PATH=/tmp/rig-fakedig-a:$PATH probe_agent_transport 127.0.0.1 53; [ "${USE_VC:-0}" = 1 ]; }
probe_udp_ok() { PATH=/tmp/rig-fakedig-b:$PATH probe_agent_transport 127.0.0.1 53; [ "${USE_VC:-0}" = 0 ]; }
probe_no_dig() { PATH=/tmp/rig-nodig probe_agent_transport 127.0.0.1 53; [ "${USE_VC:-0}" = 0 ]; }
assert "S14 probe UDP 不通 TCP 通 → USE_VC=1" probe_tcp_only
assert "S14 probe UDP 通 → USE_VC=0" probe_udp_ok
assert "S14 probe 无 dig → USE_VC=0" probe_no_dig
# get_active_nm_connection_uuid：假 ip + stub nmcli
mkdir -p /tmp/rig-fakene /tmp/rig-fakene-noroute
printf '#!/bin/bash\nif [ "$1" = "route" ]; then echo "default via 10.0.0.1 dev eth0 proto dhcp metric 100"; fi\nif [ "$1" = "-o" ]; then printf "2: eth0: <BROADCAST> mtu 1500\\n3: eth1: <BROADCAST> mtu 1500\\n"; fi\n' > /tmp/rig-fakene/ip
printf '#!/bin/bash\nexit 0\n' > /tmp/rig-fakene-noroute/ip
chmod +x /tmp/rig-fakene/ip /tmp/rig-fakene-noroute/ip
uuid_is() { [ "$(PATH="$1:$PATH" get_active_nm_connection_uuid)" = "$2" ]; }
assert "S14 UUID 按默认路由接口取 eth0 的" uuid_is /tmp/rig-fakene aaaaaaaa-1111-2222-3333-444444444444
assert "S14 UUID 无默认路由回退第一个活动连接" uuid_is /tmp/rig-fakene-noroute aaaaaaaa-1111-2222-3333-444444444444
# verify_system_dns：假 getent 三种模式
mkdir -p /tmp/rig-fakegetent-ok /tmp/rig-fakegetent-fail /tmp/rig-notools
printf '#!/bin/bash\necho "93.184.216.34 example.com"\n' > /tmp/rig-fakegetent-ok/getent
printf '#!/bin/bash\nexit 1\n' > /tmp/rig-fakegetent-fail/getent
chmod +x /tmp/rig-fakegetent-ok/getent /tmp/rig-fakegetent-fail/getent
ln -sf /usr/bin/awk /tmp/rig-fakegetent-ok/awk; ln -sf /usr/bin/grep /tmp/rig-fakegetent-ok/grep; ln -sf /usr/bin/head /tmp/rig-fakegetent-ok/head
ln -sf /usr/bin/awk /tmp/rig-fakegetent-fail/awk; ln -sf /usr/bin/grep /tmp/rig-fakegetent-fail/grep; ln -sf /usr/bin/head /tmp/rig-fakegetent-fail/head
vsd_with_getent() { PATH="$1:$PATH" verify_system_dns example.com; }
vsd_rc2() { PATH=/tmp/rig-notools verify_system_dns example.com; [ $? = 2 ]; }
assert "S14 verify getent 成功 → rc 0" vsd_with_getent /tmp/rig-fakegetent-ok
assert "S14 verify getent 失败 → rc 1" expect_fail vsd_with_getent /tmp/rig-fakegetent-fail
assert "S14 verify 无工具 → rc 2" vsd_rc2
# verify_rule_domain：真 agent + 真 panel，resolv.conf 指 agent 时通过，指上游时失败
AUTH_CFG=$(mktemp /tmp/rig-auth.XXXXXX)
chmod 600 "$AUTH_CFG"
printf 'header = "X-Agent-Token: %s"\n' "$TOKEN" > "$AUTH_CFG"
cp /etc/resolv.conf /tmp/rig-resolv-saved
printf 'nameserver 127.0.0.1\noptions use-vc\n' > /etc/resolv.conf  # getent 在沙箱里必须走 TCP
assert "S14 verify_rule_domain 规则 IP 一致 → rc 0" verify_rule_domain
cp "$RIG/fixtures/resolv.conf.base" /etc/resolv.conf
assert "S14 verify_rule_domain 非规则 IP → rc 1" expect_fail verify_rule_domain
cp /tmp/rig-resolv-saved /etc/resolv.conf
rm -f "$AUTH_CFG"
# V016-13：S14 自己起的 agent 自己停掉，不把运行状态留给后续场景。
stop_agent
assert "S14 结尾：agent 已停" port53_free

echo "=== S15 无永久备份：提示临时清理办法 ==="
mv /etc/dnsunlock/resolv.conf.orig /tmp/rig-orig-saved
mv /var/lib/dnsunlock/backup /tmp/rig-backup-saved
run_restore "$LOG/s15.log" --yes
assert "S15 restore rc=0" assert_rc0
assert "S15 提示临时模式清理办法" file_has "$LOG/s15.log" "临时模式"
assert "S15 提示 restart resolved" file_has "$LOG/s15.log" "systemctl restart systemd-resolved"
mv /tmp/rig-orig-saved /etc/dnsunlock/resolv.conf.orig
mv /tmp/rig-backup-saved /var/lib/dnsunlock/backup

echo "=== RIG SUMMARY: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  printf '失败项：\n'
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
exit 0
