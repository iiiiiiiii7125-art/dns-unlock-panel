#!/usr/bin/env bash
# V016-24 沙箱验证：6 处 keep-stopped 分支由只警告改为直接 disable。
# 跑真实 scripts/restore-resolv.sh（--yes），unshare -rm 命名空间（/etc 与
# /var/lib/dnsunlock 换 tmpfs）+ stub systemctl/ss/getent。
# agent 还原前在运行（is-active=1）且 enabled=1，config.json 的 dns_listen
# 与 stub ss 输出按场景变；stub systemctl 的 stop 会落盘 agent-stopped
# 标记，ss stub 此后不再输出 agent 自己的监听行（模拟已停掉）。
#   A 通配符 :53 + stub 在监听 → disable 被调用 + 新文案
#   B 通配符 :53 + stub 在监听 + enabled=0 → 不调用 disable（对照）
#   C 具体地址 127.0.0.53:53（stub 自己的地址）→ disable 被调用
#   D 具体地址 127.0.0.1:5353 被外来占 → disable 被调用
#   E 通配符 :53 + :53 空闲 → disable 被调用
#   F 通配符 :53 + 外来具体地址占 :53（held）→ disable 被调用
#   G 通配符 :53 + stub + enabled=1 + disable 失败 → 警告写 stderr，还原 rc 仍 0
#   H 通配符 :53 + 无 ss 又无 python3（unknown）→ disable 被调用
#   I 通配符 :53 + stub + enabled=1 + agent 还原前未在运行 → 不调用 disable（对照）
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RESTORE="$ROOT/scripts/restore-resolv.sh"
TDIR="$(mktemp -d /tmp/v016-24-test.XXXXXX)"
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
      systemd-resolved) exit 1;;
      *) exit 1;;
    esac;;
  is-enabled)
    unit="${@: -1}"
    case "$unit" in
      dnsunlock-agent) [ "${STUB_AGENT_ENABLED:-0}" = 1 ] && exit 0 || exit 1;;
      *) exit 1;;
    esac;;
  disable)
    [ "${STUB_DISABLE_FAIL:-0}" = 1 ] && exit 1
    exit 0;;
  stop)
    touch "$STUB_LOG/agent-stopped"
    exit 0;;
  daemon-reload|enable|start|restart|reload) exit 0;;
  *) exit 0;;
esac
EOF
cat > "$STUBBIN/ss" <<'EOF'
#!/usr/bin/env bash
# 模拟 ss -tulnp 输出（第 5 列是监听地址，第 7 列起是 users 字段）。
agent_gone=0
[ -f "$STUB_LOG/agent-stopped" ] && agent_gone=1
agent_line() { # <addr> <proc>
  [ "$agent_gone" = 1 ] && return 0
  printf 'udp UNCONN 0 0 %s 0.0.0.0:* users:(("dnsunlock",pid=200,fd=5))\n' "$1"
}
case "${STUB_SS_MODE:-free}" in
  stub)    agent_line "0.0.0.0:53"
           printf 'udp UNCONN 0 0 127.0.0.53%%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=100,fd=10))\n';;
  free)    agent_line "0.0.0.0:53";;
  held)    agent_line "0.0.0.0:53"
           printf 'udp UNCONN 0 0 10.0.0.5:53 0.0.0.0:* users:(("foreign",pid=300,fd=7))\n';;
  stubaddr) agent_line "127.0.0.53:53";;
  blocked) agent_line "127.0.0.1:5353"
           printf 'udp UNCONN 0 0 127.0.0.1:5353 0.0.0.0:* users:(("foreign",pid=300,fd=7))\n';;
esac
exit 0
EOF
cat > "$STUBBIN/getent" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "hosts" ] && [ "${2:-}" = "example.com" ]; then
  echo "93.184.216.34 example.com"; exit 0
fi
exec /usr/bin/getent "$@"
EOF
for s in resolvconf netplan chattr resolvectl nmcli cloudflared; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/$s"
done
chmod +x "$STUBBIN"/*

cat > "$TDIR/inner.sh" <<'INNER'
#!/usr/bin/env bash
set -u
SC="$1"; LISTEN="$2"; shift 2
export PATH="$STUBBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export STUB_LOG="$STUB_LOG"
if [ "${NO_SS_PY:-0}" = 1 ]; then
  # unknown 分支：PATH 里既无 ss 也无 python3。建一个去掉了 ss/python3 的
  # 工具目录（其余命令全部软链自系统），放 PATH 最前；stubbin 也换成去掉了
  # ss 的副本，否则 stub ss 仍会被 command -v 找到。
  NOSS="$TDIR/noss-bin"
  mkdir -p "$NOSS" "$TDIR/stubbin-noss"
  cp -a "$STUBBIN"/. "$TDIR/stubbin-noss/" 2>/dev/null || true
  rm -f "$TDIR/stubbin-noss/ss"
  for d in /usr/bin /bin /usr/local/bin; do
    for f in "$d"/*; do
      [ -f "$f" ] && [ ! -e "$NOSS/$(basename "$f")" ] && ln -s "$f" "$NOSS/$(basename "$f")" 2>/dev/null || true
    done
  done
  rm -f "$NOSS/ss" "$NOSS/python3" "$NOSS/python3."*
  export PATH="$TDIR/stubbin-noss:$NOSS"
fi
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
printf '{"dns_listen": "%s"}\n' "$LISTEN" > /etc/dnsunlock/config.json
bash "$RESTORE" --yes > "$TDIR/out-$SC.log" 2>&1
echo "rc=$?" > "$TDIR/rc-$SC"
echo "resolv.conf: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')" > "$TDIR/state-$SC"
INNER
chmod +x "$TDIR/inner.sh"

run_case() { # <id> <listen> <stub-env...>
  local sc="$1" listen="$2"; shift 2
  rm -f "$STUB_LOG"/*.log
  env STUBBIN="$STUBBIN" STUB_LOG="$STUB_LOG" RESTORE="$RESTORE" TDIR="$TDIR" \
      STUB_AGENT_UNIT=1 STUB_AGENT_ACTIVE=1 STUB_AGENT_ENABLED=1 "$@" \
    unshare -rm bash "$TDIR/inner.sh" "$sc" "$listen" >>"$LOG" 2>&1
  echo "--- $sc listen=$listen $(cat "$TDIR/rc-$sc" 2>/dev/null) ---" | tee -a "$LOG"
  grep -E '已直接改为不开机自启|disable dnsunlock-agent 失败|保持停止' "$TDIR/out-$sc.log" 2>/dev/null | head -3 | tee -a "$LOG"
  grep -E 'disable' "$STUB_LOG/systemctl.log" 2>/dev/null | tee -a "$LOG"
}
disable_called() { grep -q '^systemctl disable dnsunlock-agent$' "$STUB_LOG/systemctl.log" 2>/dev/null; }

run_case A ":53" STUB_SS_MODE=stub
chk "A rc=0" grep -qx 'rc=0' "$TDIR/rc-A"
chk "A disable 被调用" disable_called
chk "A 新文案（已直接改为不开机自启）" grep -q '已直接改为不开机自启' "$TDIR/out-A.log"

run_case B ":53" STUB_SS_MODE=stub STUB_AGENT_ENABLED=0
chk "B rc=0" grep -qx 'rc=0' "$TDIR/rc-B"
chk "B enabled=0 时不调用 disable" bash -c '! grep -q "^systemctl disable dnsunlock-agent\$" "$1"' _ "$STUB_LOG/systemctl.log"

run_case C "127.0.0.53:53" STUB_SS_MODE=stubaddr
chk "C rc=0" grep -qx 'rc=0' "$TDIR/rc-C"
chk "C disable 被调用（stub-addr 分支）" disable_called

run_case D "127.0.0.1:5353" STUB_SS_MODE=blocked
chk "D rc=0" grep -qx 'rc=0' "$TDIR/rc-D"
chk "D disable 被调用（blocked 分支）" disable_called

run_case E ":53" STUB_SS_MODE=free
chk "E rc=0" grep -qx 'rc=0' "$TDIR/rc-E"
chk "E disable 被调用（free 分支）" disable_called

run_case F ":53" STUB_SS_MODE=held
chk "F rc=0" grep -qx 'rc=0' "$TDIR/rc-F"
chk "F disable 被调用（held 分支）" disable_called

run_case G ":53" STUB_SS_MODE=stub STUB_DISABLE_FAIL=1
chk "G rc=0（disable 失败不影响还原）" grep -qx 'rc=0' "$TDIR/rc-G"
chk "G disable 失败警告写出" grep -q 'disable dnsunlock-agent 失败' "$TDIR/out-G.log"

run_case H ":53" STUB_SS_MODE=stub NO_SS_PY=1
chk "H rc=0" grep -qx 'rc=0' "$TDIR/rc-H"
chk "H disable 被调用（unknown 分支）" disable_called
chk "H 确实走了 unknown 分支" grep -q '无法确认 :53 的占用情况' "$TDIR/out-H.log"

run_case I ":53" STUB_SS_MODE=stub STUB_AGENT_ACTIVE=0
chk "I rc=0" grep -qx 'rc=0' "$TDIR/rc-I"
chk "I agent 未在运行时不调用 disable" bash -c '! grep -q "^systemctl disable dnsunlock-agent\$" "$1"' _ "$STUB_LOG/systemctl.log"
chk "I 输出保持停止（未改动）" grep -q '保持停止（未改动）' "$TDIR/out-I.log"

echo "=== V016-24: PASS=$PASS FAIL=$FAIL ===" | tee -a "$LOG"
[ "$FAIL" = 0 ]
