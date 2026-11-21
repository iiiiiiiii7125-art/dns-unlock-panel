#!/usr/bin/env bash
# R2-01 (+R2-05) 沙箱验证：跑真实 scripts/restore-resolv.sh（--yes），
# 在 unshare -rm 挂载命名空间里（/etc 换成 tmpfs，绝不碰宿主 /etc 与
# 测试机），stub systemctl/ss/getent/resolvconf/netplan/chattr。
# 场景：
#   A CHOSEN：结构化备份 + direct-write 临时状态 + 开机 unit 残留
#     → 还原 exit 0，resolv.conf 回原值，temp-state 与 unit 消失
#   B legacy：只有 .orig + resolvectl 临时状态（仅 state 文件，无 unit）
#     → 还原 exit 0，resolv.conf 回原值，temp-state 消失（R2-05）
#   C 中止：agent 在跑 + 外来通配符 :53 占位 → 还原 exit 1，
#     temp-state 与 unit 原样保留、resolv.conf 未动（中止路径不调 clear）
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RESTORE="$ROOT/scripts/restore-resolv.sh"
TDIR="$(mktemp -d /tmp/r2-01-test.XXXXXX)"
STUBBIN="$TDIR/stubbin"; STUB_LOG="$TDIR/stublog"
mkdir -p "$STUBBIN" "$STUB_LOG"
LOG="$TDIR/run.log"
PASS=0; FAIL=0
ok()   { echo "PASS: $1" | tee -a "$LOG"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" | tee -a "$LOG"; FAIL=$((FAIL+1)); }
chk()  { # chk <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

# ---- stubs ----
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
      systemd-resolved) [ "${STUB_RESOLVED_ENABLED:-0}" = 1 ] && exit 0 || exit 1;;
      *) exit 1;;
    esac;;
  daemon-reload|disable|enable|start|stop|restart) exit 0;;
  *) exit 0;;
esac
EOF
cat > "$STUBBIN/ss" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_SS53_LINES:-}" ] && printf '%s\n' "$STUB_SS53_LINES"
exit 0
EOF
cat > "$STUBBIN/getent" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "hosts" ] && [ "${2:-}" = "example.com" ]; then
  [ "${STUB_GETENT_FAIL:-0}" = 1 ] && exit 1
  echo "93.184.216.34 example.com"; exit 0
fi
exec /usr/bin/getent "$@"
EOF
for s in resolvconf netplan chattr resolvectl nmcli; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG/%s.log"\nexit 0\n' "$s" "$s" > "$STUBBIN/$s"
done
chmod +x "$STUBBIN"/*

# ---- namespace 内场景脚本 ----
cat > "$TDIR/inner.sh" <<'INNER'
#!/usr/bin/env bash
set -u
SC="$1"
export PATH="$STUBBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export STUB_LOG="$STUB_LOG"
# /etc/alternatives 挂 tmpfs 前先抄一份（/usr/bin/awk -> /etc/alternatives/awk，
# 盖掉 /etc 后 awk 会变断链，ss_listen_53_p 等用到 awk 的地方全空）。
cp -a /etc/alternatives "$TDIR/alt-copy" 2>/dev/null || true
mount -t tmpfs tmpfs /etc
[ -d "$TDIR/alt-copy" ] && cp -a "$TDIR/alt-copy" /etc/alternatives 2>/dev/null || true
mkdir -p /etc/dnsunlock /etc/systemd/system /etc/systemd/resolved.conf.d \
  /etc/NetworkManager/conf.d /etc/netplan /etc/cloud/cloud.cfg.d \
  /etc/resolvconf/resolv.conf.d /etc/dhcp /var/lib/dnsunlock
# /var/lib/dnsunlock 也盖 tmpfs（否则各场景的备份目录会漏到宿主、互相串味）。
mount -t tmpfs tmpfs /var/lib/dnsunlock
mkdir -p /var/lib/dnsunlock/backup
printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
printf '[Resolve]\n' > /etc/systemd/resolved.conf
printf 'hosts: files dns\n' > /etc/nsswitch.conf
# 临时状态：A=direct-write（orig=接管态）+开机 unit；B=resolvectl（仅 state）
mkdir -p /etc/dnsunlock/temp-state
case "$SC" in
  A|C)
    printf 'mode=direct-write\niface=\nlisten=127.0.0.1:53\nagent_was_active=0\nagent_was_enabled=0\ntimestamp=20261122T000000+0000\n' > /etc/dnsunlock/temp-state/state
    printf 'nameserver 127.0.0.1\n' > /etc/dnsunlock/temp-state/resolv.conf.orig
    cat > /etc/systemd/system/dnsunlock-temp-restore.service <<'EOF'
[Unit]
Description=dnsunlock temp DNS restore (one-shot, removes itself)
[Service]
Type=oneshot
ExecStart=/usr/local/bin/dnsunlock-restore-dns --temp-cleanup
EOF
    ;;
  B)
    printf 'mode=resolvectl\niface=eth0\nlisten=127.0.0.1:53\nagent_was_active=0\nagent_was_enabled=0\ntimestamp=20261122T000000+0000\n' > /etc/dnsunlock/temp-state/state
    ;;
esac
case "$SC" in
  A|C)
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
    ;;
  B)
    printf 'nameserver 1.1.1.1\n' > /etc/dnsunlock/resolv.conf.orig
    ;;
esac
bash "$RESTORE" --yes > "$TDIR/out-$SC.log" 2>&1
echo "rc=$?" > "$TDIR/rc-$SC"
{
  echo "resolv.conf: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
  [ -e /etc/dnsunlock/temp-state ] && echo "temp-state: EXISTS" || echo "temp-state: GONE"
  [ -f /etc/dnsunlock/temp-state/state ] && echo "temp-state/state: EXISTS" || echo "temp-state/state: GONE"
  [ -f /etc/systemd/system/dnsunlock-temp-restore.service ] && echo "boot-unit: EXISTS" || echo "boot-unit: GONE"
  grep -q 'disable dnsunlock-temp-restore' "$STUB_LOG/systemctl.log" 2>/dev/null && echo "systemctl-disable-unit: YES" || echo "systemctl-disable-unit: NO"
} > "$TDIR/state-$SC"
INNER
chmod +x "$TDIR/inner.sh"

run_scenario() { # <id> [env assignments...]
  local sc="$1"; shift
  rm -f "$STUB_LOG"/*.log
  env STUBBIN="$STUBBIN" STUB_LOG="$STUB_LOG" RESTORE="$RESTORE" TDIR="$TDIR" "$@" \
    unshare -rm bash "$TDIR/inner.sh" "$sc" >>"$LOG" 2>&1
  echo "--- scenario $sc $(cat "$TDIR/rc-$sc" 2>/dev/null) ---" | tee -a "$LOG"
  cat "$TDIR/state-$sc" 2>/dev/null | tee -a "$LOG"
  tail -5 "$TDIR/out-$sc.log" 2>/dev/null | tee -a "$LOG"
}

echo "worktree: $ROOT" | tee "$LOG"
echo "restore: $RESTORE" | tee -a "$LOG"
bash -n "$RESTORE" && ok "bash -n restore-resolv.sh" || bad "bash -n restore-resolv.sh"

# A：CHOSEN，agent 未跑、无占位
run_scenario A STUB_AGENT_UNIT=0 STUB_AGENT_ACTIVE=0 STUB_AGENT_ENABLED=0
chk "A rc=0" grep -qx 'rc=0' "$TDIR/rc-A"
chk "A resolv.conf 回到 1.1.1.1" grep -q 'resolv.conf: nameserver 1.1.1.1' "$TDIR/state-A"
chk "A temp-state 已清" grep -qx 'temp-state: GONE' "$TDIR/state-A"
chk "A 开机 unit 已删" grep -qx 'boot-unit: GONE' "$TDIR/state-A"
chk "A systemctl disable 调过 unit" grep -qx 'systemctl-disable-unit: YES' "$TDIR/state-A"

# B：legacy + resolvectl 惰性残留
run_scenario B STUB_AGENT_UNIT=0 STUB_AGENT_ACTIVE=0 STUB_AGENT_ENABLED=0
chk "B rc=0" grep -qx 'rc=0' "$TDIR/rc-B"
chk "B resolv.conf 回到 1.1.1.1" grep -q 'resolv.conf: nameserver 1.1.1.1' "$TDIR/state-B"
chk "B temp-state 已清（R2-05）" grep -qx 'temp-state: GONE' "$TDIR/state-B"

# C：中止路径不调 clear——agent 在跑 + 外来通配符 :53
run_scenario C STUB_AGENT_UNIT=1 STUB_AGENT_ACTIVE=1 STUB_AGENT_ENABLED=0 \
  STUB_SS53_LINES='udp UNCONN 0 0 0.0.0.0:53 0.0.0.0:* users:(("other",pid=999,fd=3))'
chk "C rc=1（中止）" grep -qx 'rc=1' "$TDIR/rc-C"
chk "C resolv.conf 未动（仍 127.0.0.1）" grep -q 'resolv.conf: nameserver 127.0.0.1' "$TDIR/state-C"
chk "C temp-state 保留" grep -qx 'temp-state: EXISTS' "$TDIR/state-C"
chk "C 开机 unit 保留" grep -qx 'boot-unit: EXISTS' "$TDIR/state-C"
chk "C 未调 disable 清 unit" grep -qx 'systemctl-disable-unit: NO' "$TDIR/state-C"

echo "=== R2-01: PASS=$PASS FAIL=$FAIL ===" | tee -a "$LOG"
[ "$FAIL" = 0 ]
