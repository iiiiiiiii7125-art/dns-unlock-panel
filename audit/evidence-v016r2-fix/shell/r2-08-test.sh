#!/usr/bin/env bash
# R2-08 沙箱验证：write_temp_state 与开机 unit 的写顺序 kill 窗口。
# 从 install.sh 提取 apply_temp_dns 及依赖函数，在 unshare -rm 命名空间
# （/etc 换 tmpfs）+ stub systemctl 下跑 direct-write 两条路径；stub
# systemctl 在 daemon-reload / enable 时当场检查 state 文件是否已存在——
# 这正是 kill 窗口的判定点（unit 已装而 state 不在 = 窗口仍在）。
#   A resolved 未跑 → direct-write（site 2）：装 unit 时 state 已在
#   B resolved 在跑 + resolvectl 失败 → direct-write（site 1）：同上
#   C 红证：用 7b86d49 旧版函数跑 A 场景：装 unit 时 state 不在（窗口复现）
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
TDIR="$(mktemp -d /tmp/r2-08-test.XXXXXX)"
STUBBIN="$TDIR/stubbin"; STUB_LOG="$TDIR/stublog"
mkdir -p "$STUBBIN" "$STUB_LOG"
LOG="$TDIR/run.log"
PASS=0; FAIL=0
ok()   { echo "PASS: $1" | tee -a "$LOG"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" | tee -a "$LOG"; FAIL=$((FAIL+1)); }
chk()  { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

echo "worktree: $ROOT" | tee "$LOG"
bash -n "$INSTALL" && ok "bash -n install.sh" || bad "bash -n install.sh"

# ---- 静态：两处 direct-write 都是先写 state 再装 unit ----
chk "静态：apply_temp_dns 内两处 direct-write 都是 state 在前、unit 在后" bash -c '
  awk "/^apply_temp_dns\(\) {/,/^}/" "$1" | grep -o "write_temp_state direct-write \"\"\|install_temp_boot_unit" | tr "\n" " " | grep -q "write_temp_state direct-write \"\" install_temp_boot_unit write_temp_state direct-write \"\" install_temp_boot_unit "
' _ "$INSTALL"

# ---- stubs ----
cat > "$STUBBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG/systemctl.log"
cmd="$1"; shift || true
case "$cmd" in
  is-active) [ "${STUB_RESOLVED_ACTIVE:-0}" = 1 ] && exit 0 || exit 1;;
  daemon-reload|enable)
    if [ -f /etc/dnsunlock/temp-state/state ]; then echo "$cmd: state EXISTS" >> "$STUB_LOG/order.log";
    else echo "$cmd: state MISSING" >> "$STUB_LOG/order.log"; fi
    exit 0;;
  *) exit 0;;
esac
EOF
cat > "$STUBBIN/resolvectl" <<'EOF'
#!/usr/bin/env bash
echo "resolvectl $*" >> "$STUB_LOG/resolvectl.log"
[ "${STUB_RESOLVECTL_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
cat > "$STUBBIN/dig" <<'EOF'
#!/usr/bin/env bash
echo "93.184.216.34"; exit 0
EOF
cat > "$STUBBIN/getent" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "hosts" ]; then echo "93.184.216.34 $2"; exit 0; fi
exec /usr/bin/getent "$@"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/chattr"
chmod +x "$STUBBIN"/*

extract_funcs() { # <install.sh path> <out>
  {
    echo 'set -uo pipefail'
    for f in verify_system_dns probe_agent_transport get_primary_interface write_temp_state clear_temp_state install_temp_boot_unit write_temp_resolv_conf apply_temp_dns; do
      sed -n "/^$f() {/,/^}/p" "$1"
    done
  } > "$2"
  bash -n "$2"
}
extract_funcs "$INSTALL" "$TDIR/funcs.sh" && ok "提取的新版函数片段 bash -n 通过" || bad "提取的新版函数片段 bash -n 通过"
git -C "$ROOT" show 7b86d49:scripts/install.sh > "$TDIR/install-old.sh"
extract_funcs "$TDIR/install-old.sh" "$TDIR/funcs-old.sh" && ok "提取的旧版函数片段 bash -n 通过" || bad "提取的旧版函数片段 bash -n 通过"

cat > "$TDIR/inner.sh" <<'INNER'
#!/usr/bin/env bash
set -u
SC="$1"; DNS_LISTEN="$2"; FUNCS="$3"
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
source "$FUNCS"
apply_temp_dns > "$TDIR/out-$SC.log" 2>&1
echo "rc=$?" > "$TDIR/rc-$SC"
cp "$STUB_LOG/order.log" "$TDIR/order-$SC.log" 2>/dev/null || : > "$TDIR/order-$SC.log"
{
  echo "resolv.conf: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
  [ -f /etc/dnsunlock/temp-state/state ] && echo "temp-state: $(head -1 /etc/dnsunlock/temp-state/state)" || echo "temp-state: MISSING"
  [ -f /etc/systemd/system/dnsunlock-temp-restore.service ] && echo "boot-unit: EXISTS" || echo "boot-unit: GONE"
} > "$TDIR/state-$SC"
INNER
chmod +x "$TDIR/inner.sh"

run_case() { # <id> <funcs> <stub-env...> -- <dns-listen>
  local sc="$1" funcs="$2"; shift 2
  local stubenv=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do stubenv+=("$1"); shift; done
  [ "$1" = "--" ] && shift
  rm -f "$STUB_LOG"/*.log
  env STUBBIN="$STUBBIN" STUB_LOG="$STUB_LOG" TDIR="$TDIR" "${stubenv[@]}" \
    unshare -rm bash "$TDIR/inner.sh" "$sc" "$1" "$funcs" >>"$LOG" 2>&1
  echo "--- scenario $sc $(cat "$TDIR/rc-$sc" 2>/dev/null) ---" | tee -a "$LOG"
  cat "$TDIR/state-$sc" 2>/dev/null | tee -a "$LOG"
  cat "$TDIR/order-$sc.log" 2>/dev/null | tee -a "$LOG"
}

run_case A "$TDIR/funcs.sh" STUB_RESOLVED_ACTIVE=0 -- 127.0.0.1:53
chk "A rc=0" grep -qx 'rc=0' "$TDIR/rc-A"
chk "A direct-write 完成" grep -q 'temp-state: mode=direct-write' "$TDIR/state-A"
chk "A daemon-reload 时 state 已在" grep -qx 'daemon-reload: state EXISTS' "$TDIR/order-A.log"
chk "A enable 时 state 已在" grep -qx 'enable: state EXISTS' "$TDIR/order-A.log"

run_case B "$TDIR/funcs.sh" STUB_RESOLVED_ACTIVE=1 STUB_RESOLVECTL_FAIL=1 -- 127.0.0.1:53
chk "B rc=0" grep -qx 'rc=0' "$TDIR/rc-B"
chk "B direct-write 完成（resolvectl 失败回退）" grep -q 'temp-state: mode=direct-write' "$TDIR/state-B"
chk "B daemon-reload 时 state 已在" grep -qx 'daemon-reload: state EXISTS' "$TDIR/order-B.log"
chk "B enable 时 state 已在" grep -qx 'enable: state EXISTS' "$TDIR/order-B.log"

run_case C "$TDIR/funcs-old.sh" STUB_RESOLVED_ACTIVE=0 -- 127.0.0.1:53
chk "C（红证）旧版 daemon-reload 时 state 不在" grep -qx 'daemon-reload: state MISSING' "$TDIR/order-C.log"
chk "C（红证）旧版 enable 时 state 不在" grep -qx 'enable: state MISSING' "$TDIR/order-C.log"

echo "=== R2-08: PASS=$PASS FAIL=$FAIL ===" | tee -a "$LOG"
[ "$FAIL" = 0 ]
