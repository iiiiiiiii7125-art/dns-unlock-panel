#!/usr/bin/env bash
# V016-10 沙箱验证：还原验证失败 fail-closed exit 1，加 --force 逃生口。
# A/B/C/D/E：跑真实 scripts/restore-resolv.sh（--yes），unshare -rm 命名空间
# （/etc 与 /var/lib/dnsunlock 换 tmpfs）+ stub systemctl/ss/getent（验证失败）：
#   A CHOSEN + 验证失败 + 无 --force → rc=1
#   B CHOSEN + 验证失败 + --force → rc=0，大声警告含 pre-restore 备份与回滚命令
#   C legacy + 验证失败 + --force → rc=0
#   D legacy + 验证失败 + 无 --force → rc=1
#   E CHOSEN + 验证通过 + --force → rc=0，且不打印 --force 警告（只在失败时触发）
# F/G/H：跑真实 scripts/uninstall.sh（命名空间 + stub 还原二进制记参数）：
#   F uninstall --force → 还原被调 --yes --force，卸载 rc=0
#   G uninstall（无 --force）→ 还原被调 --yes（不带 --force）
#   H uninstall --purge --force → 还原被调 --yes --force，且 /var/lib/dnsunlock 被清
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RESTORE="$ROOT/scripts/restore-resolv.sh"
UNINSTALL="$ROOT/scripts/uninstall.sh"
TDIR="$(mktemp -d /tmp/v016-10-test.XXXXXX)"
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
bash -n "$UNINSTALL" && ok "bash -n uninstall.sh" || bad "bash -n uninstall.sh"

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
      systemd-resolved) exit 1;;
      *) exit 1;;
    esac;;
  is-enabled)
    unit="${@: -1}"
    case "$unit" in
      dnsunlock-agent) [ "${STUB_AGENT_ENABLED:-0}" = 1 ] && exit 0 || exit 1;;
      *) exit 1;;
    esac;;
  daemon-reload|disable|enable|start|stop|restart|reload) exit 0;;
  *) exit 0;;
esac
EOF
cat > "$STUBBIN/ss" <<'EOF'
#!/usr/bin/env bash
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
for s in resolvconf netplan chattr resolvectl nmcli cloudflared; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/$s"
done
chmod +x "$STUBBIN"/*

cat > "$TDIR/inner-restore.sh" <<'INNER'
#!/usr/bin/env bash
set -u
SC="$1"; MODE="$2"; shift 2
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
if [ "$MODE" = "chosen" ]; then
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
else
  printf 'nameserver 1.1.1.1\n' > /etc/dnsunlock/resolv.conf.orig
fi
bash "$RESTORE" "$@" > "$TDIR/out-$SC.log" 2>&1
echo "rc=$?" > "$TDIR/rc-$SC"
echo "resolv.conf: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')" > "$TDIR/state-$SC"
INNER
chmod +x "$TDIR/inner-restore.sh"

run_restore() { # <id> <mode> <stub-env...> -- <restore args...>
  local sc="$1" mode="$2"; shift 2
  local stubenv=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do stubenv+=("$1"); shift; done
  [ "$1" = "--" ] && shift
  env STUBBIN="$STUBBIN" STUB_LOG="$STUB_LOG" RESTORE="$RESTORE" TDIR="$TDIR" "${stubenv[@]}" \
    unshare -rm bash "$TDIR/inner-restore.sh" "$sc" "$mode" "$@" >>"$LOG" 2>&1
  echo "--- restore $sc ($mode) $(cat "$TDIR/rc-$sc" 2>/dev/null) ---" | tee -a "$LOG"
  cat "$TDIR/state-$sc" 2>/dev/null | tee -a "$LOG"
  grep -E '验证未通过|--force|回滚' "$TDIR/out-$sc.log" 2>/dev/null | head -4 | tee -a "$LOG"
}

run_restore A chosen STUB_GETENT_FAIL=1 STUB_AGENT_UNIT=0 -- --yes
chk "A rc=1（无 --force 仍 fail-closed）" grep -qx 'rc=1' "$TDIR/rc-A"
chk "A resolv.conf 已还原" grep -q 'resolv.conf: nameserver 1.1.1.1' "$TDIR/state-A"

run_restore B chosen STUB_GETENT_FAIL=1 STUB_AGENT_UNIT=0 -- --yes --force
chk "B rc=0（--force 逃生）" grep -qx 'rc=0' "$TDIR/rc-B"
chk "B resolv.conf 已还原" grep -q 'resolv.conf: nameserver 1.1.1.1' "$TDIR/state-B"
chk "B 大声警告 --force" grep -q '!!!! 警告：--force 已启用' "$TDIR/out-B.log"
chk "B 警告含 pre-restore 备份与回滚命令" grep -q 'pre-restore' "$TDIR/out-B.log" && grep -q '如需回滚' "$TDIR/out-B.log"

run_restore C legacy STUB_GETENT_FAIL=1 STUB_AGENT_UNIT=0 -- --yes --force
chk "C rc=0（legacy + --force）" grep -qx 'rc=0' "$TDIR/rc-C"
chk "C 大声警告 --force" grep -q '!!!! 警告：--force 已启用' "$TDIR/out-C.log"

run_restore D legacy STUB_GETENT_FAIL=1 STUB_AGENT_UNIT=0 -- --yes
chk "D rc=1（legacy 无 --force 仍 fail-closed）" grep -qx 'rc=1' "$TDIR/rc-D"

run_restore E chosen STUB_GETENT_FAIL=0 STUB_AGENT_UNIT=0 -- --yes --force
chk "E rc=0（验证通过 + --force）" grep -qx 'rc=0' "$TDIR/rc-E"
chk_absent "E 验证通过时不打印 --force 警告" "$TDIR/out-E.log" '!!!! 警告：--force'

# ---- uninstall 透传 ----
cat > "$TDIR/inner-uninstall.sh" <<'INNER'
#!/usr/bin/env bash
set -u
SC="$1"; shift
export PATH="$STUBBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export STUB_LOG="$STUB_LOG"
cp -a /etc/alternatives "$TDIR/alt-copy" 2>/dev/null || true
mount -t tmpfs tmpfs /etc
[ -d "$TDIR/alt-copy" ] && cp -a "$TDIR/alt-copy" /etc/alternatives 2>/dev/null || true
mkdir -p /etc/dnsunlock /etc/systemd/system /etc/caddy/Caddyfile.d /etc/cloudflared
# /var/lib 整个盖 tmpfs（不要只盖 /var/lib/dnsunlock——--purge 时 rm -rf
# 删不掉挂载点本身，会 EBUSY；盖 /var/lib 后里面的目录可正常删）。
mount -t tmpfs tmpfs /var/lib 2>/dev/null || mkdir -p /var/lib
mkdir -p /var/lib/dnsunlock/backup/20261121-120000_pre-takeover
mount -t tmpfs tmpfs /usr/local/bin 2>/dev/null || mkdir -p /usr/local/bin
cat > /usr/local/bin/dnsunlock-restore-dns <<'EOF'
#!/usr/bin/env bash
echo "restore-args: $*" >> "$STUB_LOG/restore-args.log"
exit 0
EOF
chmod +x /usr/local/bin/dnsunlock-restore-dns
touch /usr/local/bin/dnsunlock
bash "$UNINSTALL" "$@" > "$TDIR/out-$SC.log" 2>&1
echo "rc=$?" > "$TDIR/rc-$SC"
{
  [ -d /var/lib/dnsunlock ] && echo "var-lib-dnsunlock: EXISTS" || echo "var-lib-dnsunlock: GONE"
  cat "$STUB_LOG/restore-args.log" 2>/dev/null | tr '\n' ';'; echo
} > "$TDIR/state-$SC"
INNER
chmod +x "$TDIR/inner-uninstall.sh"

run_uninstall() { # <id> <uninstall args...>
  local sc="$1"; shift
  rm -f "$STUB_LOG"/*.log
  env STUBBIN="$STUBBIN" STUB_LOG="$STUB_LOG" UNINSTALL="$UNINSTALL" TDIR="$TDIR" \
    unshare -rm bash "$TDIR/inner-uninstall.sh" "$sc" "$@" >>"$LOG" 2>&1
  echo "--- uninstall $sc $(cat "$TDIR/rc-$sc" 2>/dev/null) ---" | tee -a "$LOG"
  cat "$TDIR/state-$sc" 2>/dev/null | tee -a "$LOG"
  grep -E '警告|还原系统' "$TDIR/out-$sc.log" 2>/dev/null | head -3 | tee -a "$LOG"
}

run_uninstall F --force
chk "F rc=0" grep -qx 'rc=0' "$TDIR/rc-F"
chk "F 还原被调 --yes --force" grep -q 'restore-args: --yes --force' "$TDIR/state-F"
chk "F 打印 --force 警告" grep -q '!!!! 警告：--force 已启用' "$TDIR/out-F.log"
chk "F 无 --purge 时 /var/lib/dnsunlock 保留" grep -qx 'var-lib-dnsunlock: EXISTS' "$TDIR/state-F"

run_uninstall G
chk "G rc=0" grep -qx 'rc=0' "$TDIR/rc-G"
chk "G 还原被调 --yes（不带 --force）" bash -c 'grep -qx "restore-args: --yes;" "$1"' _ "$TDIR/state-G"

run_uninstall H --purge --force
chk "H rc=0" grep -qx 'rc=0' "$TDIR/rc-H"
chk "H 还原被调 --yes --force" grep -q 'restore-args: --yes --force' "$TDIR/state-H"
chk "H --purge 清掉 /var/lib/dnsunlock" grep -qx 'var-lib-dnsunlock: GONE' "$TDIR/state-H"

echo "=== V016-10: PASS=$PASS FAIL=$FAIL ===" | tee -a "$LOG"
[ "$FAIL" = 0 ]
