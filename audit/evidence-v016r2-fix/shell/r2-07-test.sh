#!/usr/bin/env bash
# R2-07 沙箱验证：cleanup_temp_state revert 失败时 fail-open。
# 跑真实 scripts/restore-resolv.sh，在 unshare -rm 挂载命名空间
# （/etc 换 tmpfs，不碰宿主）+ stub systemctl/resolvectl：
#   A resolvectl revert 失败（交互 --temp-cleanup）→ rc=1，状态与 unit 保留，
#     不打印“清理完成”，打印“清理未完成”
#   B resolvectl revert 成功 → rc=0，状态与 unit 清掉，打印“清理完成”
#   C direct-write 但 orig 缺失 → rc=1，状态保留，不打印“清理完成”
#   D --boot --temp-cleanup + revert 失败 → rc=0（开机 unit 不失败），
#     但状态保留、警告在输出里（下次启动可再试）
#   E direct-write 成功 → rc=0，resolv.conf 恢复原值，状态与 unit 清掉
#   F 无永久备份分支 + revert 失败 → rc=1（不谎报成功）
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RESTORE="$ROOT/scripts/restore-resolv.sh"
TDIR="$(mktemp -d /tmp/r2-07-test.XXXXXX)"
STUBBIN="$TDIR/stubbin"; STUB_LOG="$TDIR/stublog"
mkdir -p "$STUBBIN" "$STUB_LOG"
LOG="$TDIR/run.log"
PASS=0; FAIL=0
ok()   { echo "PASS: $1" | tee -a "$LOG"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" | tee -a "$LOG"; FAIL=$((FAIL+1)); }
chk()  { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
chk_absent() { local desc="$1" file="$2" pat="$3"; if grep -q "$pat" "$file" 2>/dev/null; then bad "$desc"; else ok "$desc"; fi; }

echo "worktree: $ROOT" | tee "$LOG"
bash -n "$RESTORE" && ok "bash -n restore-resolv.sh" || bad "bash -n restore-resolv.sh"

cat > "$STUBBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG/systemctl.log"
exit 0
EOF
cat > "$STUBBIN/resolvectl" <<'EOF'
#!/usr/bin/env bash
echo "resolvectl $*" >> "$STUB_LOG/resolvectl.log"
[ "${STUB_RESOLVECTL_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
for s in chattr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/$s"; done
chmod +x "$STUBBIN"/*

cat > "$TDIR/inner.sh" <<'INNER'
#!/usr/bin/env bash
set -u
SC="$1"; MODE="$2"; shift 2
export PATH="$STUBBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export STUB_LOG="$STUB_LOG"
cp -a /etc/alternatives "$TDIR/alt-copy" 2>/dev/null || true
mount -t tmpfs tmpfs /etc
[ -d "$TDIR/alt-copy" ] && cp -a "$TDIR/alt-copy" /etc/alternatives 2>/dev/null || true
mkdir -p /etc/dnsunlock/temp-state /etc/systemd/system
printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
printf 'mode=%s\niface=eth0\nlisten=127.0.0.1:53\nagent_was_active=0\nagent_was_enabled=0\ntimestamp=20261122T000000+0000\n' "$MODE" > /etc/dnsunlock/temp-state/state
if [ "$MODE" = "direct-write" ] && [ "$SC" != "C" ]; then
  printf 'nameserver 1.1.1.1\n' > /etc/dnsunlock/temp-state/resolv.conf.orig
fi
cat > /etc/systemd/system/dnsunlock-temp-restore.service <<'EOF'
[Unit]
Description=dnsunlock temp DNS restore (one-shot, removes itself)
[Service]
Type=oneshot
ExecStart=/usr/local/bin/dnsunlock-restore-dns --boot --temp-cleanup
EOF
bash "$RESTORE" "$@" > "$TDIR/out-$SC.log" 2>&1
echo "rc=$?" > "$TDIR/rc-$SC"
{
  echo "resolv.conf: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
  [ -f /etc/dnsunlock/temp-state/state ] && echo "temp-state/state: EXISTS" || echo "temp-state/state: GONE"
  [ -f /etc/systemd/system/dnsunlock-temp-restore.service ] && echo "boot-unit: EXISTS" || echo "boot-unit: GONE"
} > "$TDIR/state-$SC"
INNER
chmod +x "$TDIR/inner.sh"

# 注意：STUB_RESOLVECTL_FAIL 经 env 传进 unshare；run_case 的 "$@" 同时
# 承载 restore 参数与 stub 环境变量——用 env VAR=val 形式放在 unshare 之前。
run_case() { # <id> <mode> <stub-env...> -- <restore args...>
  local sc="$1" mode="$2"; shift 2
  local stubenv=() args=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do stubenv+=("$1"); shift; done
  [ "$1" = "--" ] && shift
  args=("$@")
  rm -f "$STUB_LOG"/*.log
  env STUBBIN="$STUBBIN" STUB_LOG="$STUB_LOG" RESTORE="$RESTORE" TDIR="$TDIR" "${stubenv[@]}" \
    unshare -rm bash "$TDIR/inner.sh" "$sc" "$mode" "${args[@]}" >>"$LOG" 2>&1
  echo "--- scenario $sc ($mode) $(cat "$TDIR/rc-$sc" 2>/dev/null) ---" | tee -a "$LOG"
  cat "$TDIR/state-$sc" 2>/dev/null | tee -a "$LOG"
  grep -E '清理完成|清理未完成|revert' "$TDIR/out-$sc.log" 2>/dev/null | head -4 | tee -a "$LOG"
}

run_case A resolvectl STUB_RESOLVECTL_FAIL=1 -- --temp-cleanup
chk "A rc=1" grep -qx 'rc=1' "$TDIR/rc-A"
chk "A 状态保留" grep -qx 'temp-state/state: EXISTS' "$TDIR/state-A"
chk "A unit 保留" grep -qx 'boot-unit: EXISTS' "$TDIR/state-A"
chk_absent "A 不打印“清理完成”" "$TDIR/out-A.log" '临时模式清理完成'
chk "A 打印“清理未完成”" grep -q '临时模式清理未完成' "$TDIR/out-A.log"

run_case B resolvectl STUB_RESOLVECTL_FAIL=0 -- --temp-cleanup
chk "B rc=0" grep -qx 'rc=0' "$TDIR/rc-B"
chk "B 状态清掉" grep -qx 'temp-state/state: GONE' "$TDIR/state-B"
chk "B unit 清掉" grep -qx 'boot-unit: GONE' "$TDIR/state-B"
chk "B 打印“清理完成”" grep -q '临时模式清理完成' "$TDIR/out-B.log"

run_case C direct-write -- --temp-cleanup
chk "C rc=1（orig 缺失）" grep -qx 'rc=1' "$TDIR/rc-C"
chk "C 状态保留" grep -qx 'temp-state/state: EXISTS' "$TDIR/state-C"
chk "C resolv.conf 未动" grep -q 'resolv.conf: nameserver 127.0.0.1' "$TDIR/state-C"
chk_absent "C 不打印“清理完成”" "$TDIR/out-C.log" '临时模式清理完成'

run_case D resolvectl STUB_RESOLVECTL_FAIL=1 -- --boot --temp-cleanup
chk "D rc=0（--boot 恒返回 0）" grep -qx 'rc=0' "$TDIR/rc-D"
chk "D 状态保留（下次启动再试）" grep -qx 'temp-state/state: EXISTS' "$TDIR/state-D"
chk "D 警告仍写进输出" grep -q '临时模式清理未完成' "$TDIR/out-D.log"

run_case E direct-write -- --temp-cleanup
chk "E rc=0" grep -qx 'rc=0' "$TDIR/rc-E"
chk "E resolv.conf 恢复原值" grep -q 'resolv.conf: nameserver 1.1.1.1' "$TDIR/state-E"
chk "E 状态清掉" grep -qx 'temp-state/state: GONE' "$TDIR/state-E"
chk "E unit 清掉" grep -qx 'boot-unit: GONE' "$TDIR/state-E"
chk "E 打印“清理完成”" grep -q '临时模式清理完成' "$TDIR/out-E.log"

run_case F resolvectl STUB_RESOLVECTL_FAIL=1 -- --yes
chk "F rc=1（无永久备份分支也传播失败）" grep -qx 'rc=1' "$TDIR/rc-F"
chk "F 状态保留" grep -qx 'temp-state/state: EXISTS' "$TDIR/state-F"

echo "=== R2-07: PASS=$PASS FAIL=$FAIL ===" | tee -a "$LOG"
[ "$FAIL" = 0 ]
