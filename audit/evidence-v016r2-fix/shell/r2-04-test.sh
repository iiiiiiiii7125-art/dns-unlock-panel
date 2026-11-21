#!/usr/bin/env bash
# R2-04 沙箱验证：agent 未在跑时 unit 路径的早返回跳过 stub_blockers 检查。
# 跑真实 scripts/restore-resolv.sh（--yes），unshare -rm 挂载命名空间
# （/etc 与 /var/lib/dnsunlock 换 tmpfs，不碰宿主）+ stub systemctl/ss/
# getent。结构化备份 + 当前 resolv.conf 为接管态 127.0.0.1：
#   A agent 未跑 + 外来通配符 :53 占位 → rc=1，中止在改 DNS 之前，
#     resolv.conf 未动、agent 未被 stop
#   B agent 未跑 + 无占位 → rc=0，还原成功（回归：无占位时不误拦）
#   C agent 在跑 + 外来通配符 :53 占位 → rc=1，agent 未被 stop（回归）
#   D agent 在跑 + 无占位 → rc=0，agent 被 stop、还原成功（回归）
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RESTORE="$ROOT/scripts/restore-resolv.sh"
TDIR="$(mktemp -d /tmp/r2-04-test.XXXXXX)"
STUBBIN="$TDIR/stubbin"; STUB_LOG="$TDIR/stublog"
mkdir -p "$STUBBIN" "$STUB_LOG"
LOG="$TDIR/run.log"
PASS=0; FAIL=0
ok()   { echo "PASS: $1" | tee -a "$LOG"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" | tee -a "$LOG"; FAIL=$((FAIL+1)); }
chk()  { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

echo "worktree: $ROOT" | tee "$LOG"
bash -n "$RESTORE" && ok "bash -n restore-resolv.sh" || bad "bash -n restore-resolv.sh"

cat > "$STUBBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG/systemctl.log"
cmd="$1"; shift || true
case "$cmd" in
  cat)
    case "${1:-}" in
      dnsunlock-agent.service) [ "${STUB_AGENT_UNIT:-0}" = 1 ] && exit 0 || exit 1;;
      systemd-resolved.service) exit 0;;
      *) exit 1;;
    esac;;
  is-active)
    unit="${@: -1}"
    case "$unit" in
      dnsunlock-agent) [ "${STUB_AGENT_ACTIVE:-0}" = 1 ] && exit 0 || exit 1;;
      systemd-resolved) [ "${STUB_RESOLVED_ACTIVE:-0}" = 1 ] && exit 0 || exit 1;;
      *) exit 1;;
    esac;;
  is-enabled)
    unit="${@: -1}"
    case "$unit" in
      dnsunlock-agent) [ "${STUB_AGENT_ENABLED:-0}" = 1 ] && exit 0 || exit 1;;
      systemd-resolved) exit 1;;
      *) exit 1;;
    esac;;
  daemon-reload|disable|enable|start|stop|restart) exit 0;;
  *) exit 0;;
esac
EOF
cat > "$STUBBIN/ss" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_SS_LINES:-}" ] && printf '%s\n' "$STUB_SS_LINES"
exit 0
EOF
cat > "$STUBBIN/getent" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "hosts" ] && [ "${2:-}" = "example.com" ]; then echo "93.184.216.34 example.com"; exit 0; fi
exec /usr/bin/getent "$@"
EOF
for s in resolvconf netplan chattr resolvectl nmcli; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/$s"
done
chmod +x "$STUBBIN"/*

cat > "$TDIR/inner.sh" <<'INNER'
#!/usr/bin/env bash
set -u
SC="$1"
export PATH="$STUBBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export STUB_LOG="$STUB_LOG"
cp -a /etc/alternatives "$TDIR/alt-copy" 2>/dev/null || true
mount -t tmpfs tmpfs /etc
[ -d "$TDIR/alt-copy" ] && cp -a "$TDIR/alt-copy" /etc/alternatives 2>/dev/null || true
mkdir -p /etc/dnsunlock /etc/systemd/system /etc/systemd/resolved.conf.d \
  /etc/NetworkManager/conf.d /etc/netplan /etc/cloud/cloud.cfg.d \
  /etc/resolvconf/resolv.conf.d /etc/dhcp
mount -t tmpfs tmpfs /var/lib/dnsunlock 2>/dev/null || mkdir -p /var/lib/dnsunlock
mkdir -p /var/lib/dnsunlock/backup
printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
printf '[Resolve]\n' > /etc/systemd/resolved.conf
printf 'hosts: files dns\n' > /etc/nsswitch.conf
D=/var/lib/dnsunlock/backup/20261121-120000_pre-takeover
mkdir -p "$D"
printf 'nameserver 1.1.1.1\n' > "$D/resolv.conf"
cat > "$D/metadata.txt" <<'EOF'
timestamp=2026-11-21T12:00:00+0000
label=pre-takeover
dns=1.1.1.1
backends=resolved
resolv_symlink=
resolved_active=no
resolved_enabled=no
nm_active=no
nm_enabled=no
resolvconf_active=no
resolvconf_enabled=no
nm_primary_uuid=
EOF
bash "$RESTORE" --yes > "$TDIR/out-$SC.log" 2>&1
echo "rc=$?" > "$TDIR/rc-$SC"
{
  echo "resolv.conf: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
  grep -q 'stop dnsunlock-agent' "$STUB_LOG/systemctl.log" 2>/dev/null && echo "agent-stop-called: YES" || echo "agent-stop-called: NO"
} > "$TDIR/state-$SC"
INNER
chmod +x "$TDIR/inner.sh"

FOREIGN='udp UNCONN 0 0 0.0.0.0:53 0.0.0.0:* users:(("other",pid=999,fd=3))'
run_scenario() { # <id> [env...]
  local sc="$1"; shift
  rm -f "$STUB_LOG"/*.log
  env STUBBIN="$STUBBIN" STUB_LOG="$STUB_LOG" RESTORE="$RESTORE" TDIR="$TDIR" "$@" \
    unshare -rm bash "$TDIR/inner.sh" "$sc" >>"$LOG" 2>&1
  echo "--- scenario $sc $(cat "$TDIR/rc-$sc" 2>/dev/null) ---" | tee -a "$LOG"
  cat "$TDIR/state-$sc" 2>/dev/null | tee -a "$LOG"
  grep -E '错误|已还原并验证|中止' "$TDIR/out-$sc.log" 2>/dev/null | head -3 | tee -a "$LOG"
}

run_scenario A STUB_AGENT_UNIT=1 STUB_AGENT_ACTIVE=0 STUB_AGENT_ENABLED=0 STUB_SS_LINES="$FOREIGN"
chk "A rc=1（中止）" grep -qx 'rc=1' "$TDIR/rc-A"
chk "A resolv.conf 未动（仍 127.0.0.1）" grep -q 'resolv.conf: nameserver 127.0.0.1' "$TDIR/state-A"
chk "A agent 未被 stop" grep -qx 'agent-stop-called: NO' "$TDIR/state-A"
chk "A 报错点名外来占位" grep -q '已有其他服务监听（0.0.0.0:53）' "$TDIR/out-A.log"

run_scenario B STUB_AGENT_UNIT=1 STUB_AGENT_ACTIVE=0 STUB_AGENT_ENABLED=0 STUB_SS_LINES=""
chk "B rc=0" grep -qx 'rc=0' "$TDIR/rc-B"
chk "B resolv.conf 已还原" grep -q 'resolv.conf: nameserver 1.1.1.1' "$TDIR/state-B"

run_scenario C STUB_AGENT_UNIT=1 STUB_AGENT_ACTIVE=1 STUB_AGENT_ENABLED=0 STUB_SS_LINES="$FOREIGN"
chk "C rc=1（中止）" grep -qx 'rc=1' "$TDIR/rc-C"
chk "C resolv.conf 未动" grep -q 'resolv.conf: nameserver 127.0.0.1' "$TDIR/state-C"
chk "C agent 未被 stop" grep -qx 'agent-stop-called: NO' "$TDIR/state-C"

run_scenario D STUB_AGENT_UNIT=1 STUB_AGENT_ACTIVE=1 STUB_AGENT_ENABLED=0 STUB_SS_LINES=""
chk "D rc=0" grep -qx 'rc=0' "$TDIR/rc-D"
chk "D resolv.conf 已还原" grep -q 'resolv.conf: nameserver 1.1.1.1' "$TDIR/state-D"
chk "D agent 被 stop" grep -qx 'agent-stop-called: YES' "$TDIR/state-D"

echo "=== R2-04: PASS=$PASS FAIL=$FAIL ===" | tee -a "$LOG"
[ "$FAIL" = 0 ]
