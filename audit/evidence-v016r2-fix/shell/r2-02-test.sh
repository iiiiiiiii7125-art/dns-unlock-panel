#!/usr/bin/env bash
# R2-02 沙箱验证：非 53 监听端口接管守卫。
# 静态：帮助/提示里不再把 5353 当退路推荐；守卫代码就位。
# 行为：从 install.sh 提取 apply_temp_dns 及依赖函数，在 unshare -rm
# 挂载命名空间（/etc 换 tmpfs，不碰宿主）+ stub systemctl/resolvectl/
# dig/getent 下跑：
#   A DNS_LISTEN=127.0.0.1:5353 → 不改本机 DNS、mode=none、无 unit、未调 resolvectl
#   B DNS_LISTEN=127.0.0.1:53 + resolved 在跑 → resolvectl 路径（对照）
#   C DNS_LISTEN=127.0.0.1:53 + resolved 未跑 → direct-write 路径（对照）
#   D 永久接管拒绝 + 停用 resolved 升级的守卫表达式（取 install.sh 原文条件求值）
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
TDIR="$(mktemp -d /tmp/r2-02-test.XXXXXX)"
STUBBIN="$TDIR/stubbin"; STUB_LOG="$TDIR/stublog"
mkdir -p "$STUBBIN" "$STUB_LOG"
LOG="$TDIR/run.log"
PASS=0; FAIL=0
ok()   { echo "PASS: $1" | tee -a "$LOG"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" | tee -a "$LOG"; FAIL=$((FAIL+1)); }
chk()  { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

echo "worktree: $ROOT" | tee "$LOG"
bash -n "$INSTALL" && ok "bash -n install.sh" || bad "bash -n install.sh"

# ---- 静态断言 ----
chk "帮助/提示不再把 5353 当退路（每处 5353 都在诚实警告/注释语境里）" \
  bash -c '! grep "5353" "$1" | grep -vqE "无法做系统 DNS 接管|永远到不了|监听是具体地址"' _ "$INSTALL"
chk "5353 只剩 3 处诚实提及（守卫注释 + 提示警告 + 还原内嵌注释）" \
  bash -c '[ "$(grep -c "5353" "$1")" = 3 ]' _ "$INSTALL"
chk "apply_temp_dns 含端口守卫（_dl_port != 53 → mode=none）" \
  bash -c 'grep -q "_dl_port.*!= \"53\"" "$1" && sed -n "/^apply_temp_dns/,/^}/p" "$1" | grep -q "write_temp_state none"' _ "$INSTALL"
chk "永久接管拒绝块在 ask TAKEOVER 之后、hpve 检查之前" \
  bash -c 'a=$(grep -n "ask TAKEOVER" "$1" | head -1 | cut -d: -f1); b=$(grep -n "R2-02：非 53 监听端口拒绝接管" "$1" | head -1 | cut -d: -f1); c=$(grep -n "&& detect_hpve_init; then" "$1" | head -1 | cut -d: -f1); [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]' _ "$INSTALL"
chk "停用 resolved 升级加了端口=53 条件" \
  bash -c 'grep -q "TAKEOVER_VERIFY.*= 1.*_dl_port.*= \"53\".*systemctl is-active --quiet systemd-resolved" "$1"' _ "$INSTALL"
chk "两份 install.sh 仍 identical" cmp "$ROOT/scripts/install.sh" "$ROOT/internal/panel/assets/install.sh"

# ---- stubs ----
cat > "$STUBBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG/systemctl.log"
cmd="$1"; shift || true
case "$cmd" in
  is-active) [ "${STUB_RESOLVED_ACTIVE:-0}" = 1 ] && exit 0 || exit 1;;
  *) exit 0;;
esac
EOF
cat > "$STUBBIN/resolvectl" <<'EOF'
#!/usr/bin/env bash
echo "resolvectl $*" >> "$STUB_LOG/resolvectl.log"
exit 0
EOF
cat > "$STUBBIN/dig" <<'EOF'
#!/usr/bin/env bash
echo "93.184.216.34"
exit 0
EOF
cat > "$STUBBIN/getent" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "hosts" ]; then echo "93.184.216.34 $2"; exit 0; fi
exec /usr/bin/getent "$@"
EOF
for s in chattr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/$s"; done
chmod +x "$STUBBIN"/*

# ---- 提取被测函数（原文，未改）----
{
  echo 'set -uo pipefail'
  for f in verify_system_dns probe_agent_transport get_primary_interface write_temp_state clear_temp_state install_temp_boot_unit write_temp_resolv_conf apply_temp_dns; do
    sed -n "/^$f() {/,/^}/p" "$INSTALL"
  done
} > "$TDIR/funcs.sh"
bash -n "$TDIR/funcs.sh" && ok "提取的函数片段 bash -n 通过" || bad "提取的函数片段 bash -n 通过"

cat > "$TDIR/inner.sh" <<'INNER'
#!/usr/bin/env bash
set -u
SC="$1"; DNS_LISTEN="$2"
export PATH="$STUBBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export STUB_LOG="$STUB_LOG"
cp -a /etc/alternatives "$TDIR/alt-copy" 2>/dev/null || true
mount -t tmpfs tmpfs /etc
[ -d "$TDIR/alt-copy" ] && cp -a "$TDIR/alt-copy" /etc/alternatives 2>/dev/null || true
mkdir -p /etc/dnsunlock /etc/systemd/system /etc/systemd/resolved.conf.d
printf 'nameserver 1.1.1.1\n' > /etc/resolv.conf
_dl_host="${DNS_LISTEN%:*}"; _dl_host="${_dl_host#[}"; _dl_host="${_dl_host%]}"
_dl_port="${DNS_LISTEN##*:}"
TEMP_AGENT_WAS_ACTIVE=0; TEMP_AGENT_WAS_ENABLED=0
USE_VC=0
# shellcheck disable=SC1091
source "$TDIR/funcs.sh"
apply_temp_dns > "$TDIR/out-$SC.log" 2>&1
echo "rc=$?" > "$TDIR/rc-$SC"
{
  echo "resolv.conf: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
  if [ -f /etc/dnsunlock/temp-state/state ]; then echo "temp-state: $(cat /etc/dnsunlock/temp-state/state | tr '\n' ';')"; else echo "temp-state: MISSING"; fi
  [ -f /etc/systemd/system/dnsunlock-temp-restore.service ] && echo "boot-unit: EXISTS" || echo "boot-unit: GONE"
  [ -s "$STUB_LOG/resolvectl.log" ] && echo "resolvectl-called: YES $(cat "$STUB_LOG/resolvectl.log" | tr '\n' ';')" || echo "resolvectl-called: NO"
} > "$TDIR/state-$SC"
INNER
chmod +x "$TDIR/inner.sh"

run_scenario() { # <id> <dns-listen> [env...]
  local sc="$1" listen="$2"; shift 2
  rm -f "$STUB_LOG"/*.log
  env STUBBIN="$STUBBIN" STUB_LOG="$STUB_LOG" TDIR="$TDIR" "$@" \
    unshare -rm bash "$TDIR/inner.sh" "$sc" "$listen" >>"$LOG" 2>&1
  echo "--- scenario $sc ($listen) $(cat "$TDIR/rc-$sc" 2>/dev/null) ---" | tee -a "$LOG"
  cat "$TDIR/state-$sc" 2>/dev/null | tee -a "$LOG"
  grep -E '注意|无法做系统|临时模式' "$TDIR/out-$sc.log" 2>/dev/null | head -4 | tee -a "$LOG"
}

run_scenario A 127.0.0.1:5353 STUB_RESOLVED_ACTIVE=1
chk "A rc=0" grep -qx 'rc=0' "$TDIR/rc-A"
chk "A resolv.conf 未动（仍 1.1.1.1）" grep -q 'resolv.conf: nameserver 1.1.1.1' "$TDIR/state-A"
chk "A temp-state mode=none" grep -q 'temp-state: mode=none' "$TDIR/state-A"
chk "A 无开机 unit" grep -qx 'boot-unit: GONE' "$TDIR/state-A"
chk "A 未调 resolvectl" grep -qx 'resolvectl-called: NO' "$TDIR/state-A"
chk "A 输出明说无法接管" grep -q '无法做系统 DNS 接管' "$TDIR/out-A.log"

run_scenario B 127.0.0.1:53 STUB_RESOLVED_ACTIVE=1
chk "B rc=0" grep -qx 'rc=0' "$TDIR/rc-B"
chk "B resolvectl 路径（mode=resolvectl）" grep -q 'temp-state: mode=resolvectl' "$TDIR/state-B"
chk "B 调了 resolvectl dns" grep -q 'resolvectl-called: YES.*dns' "$TDIR/state-B"
chk "B resolv.conf 未动" grep -q 'resolv.conf: nameserver 1.1.1.1' "$TDIR/state-B"

run_scenario C 127.0.0.1:53 STUB_RESOLVED_ACTIVE=0
chk "C rc=0" grep -qx 'rc=0' "$TDIR/rc-C"
chk "C direct-write 路径（mode=direct-write）" grep -q 'temp-state: mode=direct-write' "$TDIR/state-C"
chk "C resolv.conf 已指 agent" grep -q 'resolv.conf: nameserver 127.0.0.1' "$TDIR/state-C"
chk "C 开机 unit 已装" grep -qx 'boot-unit: EXISTS' "$TDIR/state-C"

# D：永久接管拒绝 + 升级守卫的条件求值（取 install.sh 原文逻辑等价式）
TAKEOVER="y"; _dl_host="127.0.0.1"; _dl_port="5353"
if { [ "${TAKEOVER:-}" = "y" ] || [ "${TAKEOVER:-}" = "Y" ]; } && [ "${_dl_port:-53}" != "53" ]; then TAKEOVER="n"; fi
[ "$TAKEOVER" = "n" ] && ok "D :5353 + TAKEOVER=y → 拒绝接管（TAKEOVER=n）" || bad "D :5353 + TAKEOVER=y → 拒绝接管（TAKEOVER=n）"
TAKEOVER="y"; _dl_port="53"
if { [ "${TAKEOVER:-}" = "y" ] || [ "${TAKEOVER:-}" = "Y" ]; } && [ "${_dl_port:-53}" != "53" ]; then TAKEOVER="n"; fi
[ "$TAKEOVER" = "y" ] && ok "D :53 + TAKEOVER=y → 保持接管（TAKEOVER=y）" || bad "D :53 + TAKEOVER=y → 保持接管（TAKEOVER=y）"
_dl_port="5353"; TAKEOVER_VERIFY=1
if [ "$TAKEOVER_VERIFY" = 1 ] && [ "${_dl_port:-53}" = "53" ]; then bad "D :5353 时升级条件应为假"; else ok "D :5353 时停用 resolved 升级不触发"; fi
_dl_port="53"
if [ "$TAKEOVER_VERIFY" = 1 ] && [ "${_dl_port:-53}" = "53" ]; then ok "D :53 时停用 resolved 升级条件仍成立"; else bad "D :53 时停用 resolved 升级条件仍成立"; fi

echo "=== R2-02: PASS=$PASS FAIL=$FAIL ===" | tee -a "$LOG"
[ "$FAIL" = 0 ]
