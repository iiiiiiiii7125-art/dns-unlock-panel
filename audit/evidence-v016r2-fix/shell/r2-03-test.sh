#!/usr/bin/env bash
# R2-03 沙箱验证：measure_53 / _addr_host 认不出真实 ss 输出 127.0.0.53%lo:53。
# 从 restore-resolv.sh 提取原文函数，stub ss 输出测试机快照同款真实格式：
#   udp UNCONN ... 127.0.0.53%lo:53 ... users:(("systemd-resolve",...))
# 断言：_addr_host 剥 %lo；measure_53 在 stub 在监听时报 stub 而非 held；
# 通配符 agent + stub 共存时仍报 stub；纯外来占位报 held；空闲报 free。
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RESTORE="$ROOT/scripts/restore-resolv.sh"
TDIR="$(mktemp -d /tmp/r2-03-test.XXXXXX)"
STUBBIN="$TDIR/stubbin"
mkdir -p "$STUBBIN"
LOG="$TDIR/run.log"
PASS=0; FAIL=0
ok()   { echo "PASS: $1" | tee -a "$LOG"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" | tee -a "$LOG"; FAIL=$((FAIL+1)); }
chk()  { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

echo "worktree: $ROOT" | tee "$LOG"
bash -n "$RESTORE" && ok "bash -n restore-resolv.sh" || bad "bash -n restore-resolv.sh"

cat > "$STUBBIN/ss" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_SS_LINES:-}" ] && printf '%s\n' "$STUB_SS_LINES"
exit 0
EOF
chmod +x "$STUBBIN/ss"

{
  echo 'set -uo pipefail'
  for f in ss_listen_53_p _addr_host _addr_port _is_wildcard_host _is_stub_host measure_53; do
    sed -n "/^$f() {/,/^}/p" "$RESTORE"
  done
} > "$TDIR/funcs.sh"
bash -n "$TDIR/funcs.sh" && ok "提取的函数片段 bash -n 通过" || bad "提取的函数片段 bash -n 通过"

run_case() { # <id> <ss-lines> <expected-measure> ; 用 env 传 ss 输出
  local id="$1" lines="$2" want="$3" got=""
  got=$(env STUB_SS_LINES="$lines" PATH="$STUBBIN:/usr/bin:/bin" bash -c "source \"$TDIR/funcs.sh\"; measure_53" 2>/dev/null)
  if [ "$got" = "$want" ]; then ok "measure_53 $id → [$got]"; else bad "measure_53 $id → [$got]，期望 [$want]"; fi
  echo "  $id: ss=[$lines] measure=[$got]" | tee -a "$LOG"
}

# _addr_host 单元断言（直接求值）
h=$(PATH="$STUBBIN:/usr/bin:/bin" bash -c "source \"$TDIR/funcs.sh\"; _addr_host '127.0.0.53%lo:53'")
[ "$h" = "127.0.0.53" ] && ok "_addr_host '127.0.0.53%lo:53' → 127.0.0.53" || bad "_addr_host '127.0.0.53%lo:53' → [$h]"
h=$(PATH="$STUBBIN:/usr/bin:/bin" bash -c "source \"$TDIR/funcs.sh\"; _addr_host '[fe80::1%eth0]:53'")
[ "$h" = "fe80::1" ] && ok "_addr_host '[fe80::1%eth0]:53' → fe80::1" || bad "_addr_host '[fe80::1%eth0]:53' → [$h]"
h=$(PATH="$STUBBIN:/usr/bin:/bin" bash -c "source \"$TDIR/funcs.sh\"; _addr_host '127.0.0.1:5353'")
[ "$h" = "127.0.0.1" ] && ok "_addr_host '127.0.0.1:5353' → 127.0.0.1（无 % 时不变）" || bad "_addr_host '127.0.0.1:5353' → [$h]"
h=$(PATH="$STUBBIN:/usr/bin:/bin" bash -c "source \"$TDIR/funcs.sh\"; _addr_host '0.0.0.0:53'")
[ "$h" = "0.0.0.0" ] && ok "_addr_host '0.0.0.0:53' → 0.0.0.0" || bad "_addr_host '0.0.0.0:53' → [$h]"

# 真实 ss 输出格式（测试机快照同款）：stub 的 udp+tcp 两行都带 %lo
STUB_ONLY='udp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=1,fd=1))
tcp LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=1,fd=2))'
run_case "stub-only-%lo" "$STUB_ONLY" "stub 127.0.0.53:53"

# 通配符 agent + stub 共存（B 线说的漏网组合）：仍应报 stub，不误导用户处理占位
WILD_PLUS_STUB='udp UNCONN 0 0 0.0.0.0:53 0.0.0.0:* users:(("dnsunlock",pid=123,fd=3))
udp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=1,fd=1))'
run_case "wildcard-agent+stub-%lo" "$WILD_PLUS_STUB" "stub 127.0.0.53:53"

# 纯外来占位：held，且地址已归一化（无 %lo 残留）
FOREIGN='udp UNCONN 0 0 0.0.0.0:53 0.0.0.0:* users:(("other",pid=999,fd=3))'
run_case "foreign-only" "$FOREIGN" "held 0.0.0.0:53"

# 空闲
run_case "free" "" "free"

# 旧格式（无 %lo）回归：仍报 stub
STUB_PLAIN='udp UNCONN 0 0 127.0.0.53:53 0.0.0.0:* users:(("systemd-resolve",pid=1,fd=1))'
run_case "stub-plain-no-suffix" "$STUB_PLAIN" "stub 127.0.0.53:53"

# 本机真实 ss 的 :53 行（若有）只作信息记录：格式是否带 % 后缀
echo "--- 本机真实 ss :53 行（信息）---" | tee -a "$LOG"
ss -tulnp 2>/dev/null | grep -E ':53 ' | tee -a "$LOG" || echo "（本机无 :53 监听）" | tee -a "$LOG"

echo "=== R2-03: PASS=$PASS FAIL=$FAIL ===" | tee -a "$LOG"
[ "$FAIL" = 0 ]
