#!/usr/bin/env bash
# R2-09 沙箱验证：verify_rule_domain 的 grep 兜底已删，无 python3/jq 则跳过。
# 从 install.sh 提取 verify_rule_domain 原文，stub curl 下发一份含多候选
# 节点的 region 规则配置（旧 grep 兜底的错位场景），stub getent 作最终核对：
#   A python3 在 → 严格解析，取第一条 address 规则，验证通过 rc=0（回归）
#   B 只有 jq（无 python3）→ jq 路径取到同一条规则，rc=0（回归）
#   C 既无 python3 也无 jq → 跳过 rc=2，报“既无 python3 也无 jq”，
#     不猜、不取任何规则（旧代码会在此走 grep 配对）
#   D 静态：源码里已无 grep paste 兜底
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
TDIR="$(mktemp -d /tmp/r2-09-test.XXXXXX)"
LOG="$TDIR/run.log"
PASS=0; FAIL=0
ok()   { echo "PASS: $1" | tee -a "$LOG"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" | tee -a "$LOG"; FAIL=$((FAIL+1)); }
chk()  { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

echo "worktree: $ROOT" | tee "$LOG"
bash -n "$INSTALL" && ok "bash -n install.sh" || bad "bash -n install.sh"
chk "D 源码里已无 grep paste 兜底" bash -c '! grep -q "paste <(grep -oE" "$1"' _ "$INSTALL"
chk "D 源码里仍有 python3/jq 两路严格解析" bash -c 'grep -q "command -v python3" "$1" && grep -q "command -v jq" "$1"' _ "$INSTALL"

# 含多候选节点的 region 规则配置：第一条是 nameserver 规则，第二条是带
# 2 个候选节点的 address 规则（node_ip 203.0.113.99 + 2 个 candidate node_ip）。
cat > "$TDIR/config.json" <<'EOF'
{"rules": [
  {"mode": "nameserver", "domains": ["example.com"], "node_ip": "", "nameserver": "1.1.1.1"},
  {"mode": "address", "domains": ["tiktok.com", "tiktokv.com"], "node_ip": "203.0.113.99",
   "regionCandidates": [{"node_ip": "203.0.113.50"}, {"node_ip": "203.0.113.60"}]}
]}
EOF

# stub curl：把配置写进 -o 指定的文件；stub getent：tiktok.com 返回规则 IP。
mkdir -p "$TDIR/stubbin"
cat > "$TDIR/stubbin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
cat "$STUB_CONFIG_JSON" > "$out"
exit 0
EOF
cat > "$TDIR/stubbin/getent" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "hosts" ]; then echo "203.0.113.99 $2"; exit 0; fi
exec /usr/bin/getent "$@"
EOF
chmod +x "$TDIR/stubbin"/*

{ echo 'set -uo pipefail'; sed -n '/^verify_rule_domain() {/,/^}/p' "$INSTALL"; } > "$TDIR/funcs.sh"
bash -n "$TDIR/funcs.sh" && ok "提取的函数片段 bash -n 通过" || bad "提取的函数片段 bash -n 通过"

run_case() { # <id> <path-dir> ; 余下 env 经全局变量传
  local id="$1" bindir="$2"
  PANEL_BASE="http://127.0.0.1:8080" SERVER_ID="srv-test" AUTH_CFG="/dev/null" USE_VC=0 \
    STUB_CONFIG_JSON="$TDIR/config.json" \
    PATH="$bindir" /usr/bin/bash -c "source \"$TDIR/funcs.sh\"; verify_rule_domain" > "$TDIR/out-$id.log" 2>&1
  echo "rc=$?" > "$TDIR/rc-$id"
  echo "--- case $id $(cat "$TDIR/rc-$id") ---" | tee -a "$LOG"
  cat "$TDIR/out-$id.log" | tee -a "$LOG"
}

# A：python3 + jq 都在（真实 /usr/bin）
mkdir -p "$TDIR/binA"
ln -sf /usr/bin/mktemp "$TDIR/binA/mktemp"; ln -sf /bin/rm "$TDIR/binA/rm"; ln -sf /usr/bin/head "$TDIR/binA/head"; ln -sf /usr/bin/cat "$TDIR/binA/cat"; ln -sf /usr/bin/bash "$TDIR/binA/bash"; ln -sf /usr/bin/awk "$TDIR/binA/awk"
ln -sf "$TDIR/stubbin/curl" "$TDIR/binA/curl"; ln -sf "$TDIR/stubbin/getent" "$TDIR/binA/getent"
ln -sf /usr/bin/python3 "$TDIR/binA/python3"; ln -sf /usr/bin/jq "$TDIR/binA/jq"
run_case A "$TDIR/binA"
chk "A rc=0（python3 路径验证通过）" grep -qx 'rc=0' "$TDIR/rc-A"
chk "A 取到 tiktok.com → 203.0.113.99" grep -q '规则域名验证通过: tiktok.com -> 203.0.113.99' "$TDIR/out-A.log"

# B：只有 jq（无 python3）
mkdir -p "$TDIR/binB"
ln -sf /usr/bin/mktemp "$TDIR/binB/mktemp"; ln -sf /bin/rm "$TDIR/binB/rm"; ln -sf /usr/bin/head "$TDIR/binB/head"; ln -sf /usr/bin/cat "$TDIR/binB/cat"; ln -sf /usr/bin/bash "$TDIR/binB/bash"; ln -sf /usr/bin/awk "$TDIR/binB/awk"
ln -sf "$TDIR/stubbin/curl" "$TDIR/binB/curl"; ln -sf "$TDIR/stubbin/getent" "$TDIR/binB/getent"
ln -sf /usr/bin/jq "$TDIR/binB/jq"
run_case B "$TDIR/binB"
chk "B rc=0（jq 路径验证通过）" grep -qx 'rc=0' "$TDIR/rc-B"
chk "B 取到同一条规则" grep -q '规则域名验证通过: tiktok.com -> 203.0.113.99' "$TDIR/out-B.log"

# C：既无 python3 也无 jq
mkdir -p "$TDIR/binC"
ln -sf /usr/bin/mktemp "$TDIR/binC/mktemp"; ln -sf /bin/rm "$TDIR/binC/rm"; ln -sf /usr/bin/head "$TDIR/binC/head"; ln -sf /usr/bin/cat "$TDIR/binC/cat"; ln -sf /usr/bin/bash "$TDIR/binC/bash"; ln -sf /usr/bin/awk "$TDIR/binC/awk"
ln -sf "$TDIR/stubbin/curl" "$TDIR/binC/curl"; ln -sf "$TDIR/stubbin/getent" "$TDIR/binC/getent"
run_case C "$TDIR/binC"
chk "C rc=2（跳过）" grep -qx 'rc=2' "$TDIR/rc-C"
chk "C 报既无 python3 也无 jq" grep -q '既无 python3 也无 jq' "$TDIR/out-C.log"
chk "C 未取任何规则（无验证通过/警告行）" bash -c '! grep -q "规则域名验证通过\|规则域名 .* 解析到" "$1"' _ "$TDIR/out-C.log"

echo "=== R2-09: PASS=$PASS FAIL=$FAIL ===" | tee -a "$LOG"
[ "$FAIL" = 0 ]
