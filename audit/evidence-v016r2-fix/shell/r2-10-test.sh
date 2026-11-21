#!/usr/bin/env bash
# R2-10 沙箱验证：run_dnsunlock_check 的 mktemp 文件泄漏。
# 取 install.sh 里第二道 EXIT trap 的原文，在 set -u 的子 shell 里求值：
#   A 变量都已赋值（模拟安装跑到 check 之后 abort）→ 退出后基线/复测
#     文件及其 .err、AUTH_CFG、whoami、DL_TMP 全被清掉
#   B 变量为空（模拟 check 文件还没建就退出）→ trap 不报错、rc=0
#   C 静态：trap 里含两处 check 文件及 .err；变量在 trap 之前已初始化
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
TDIR="$(mktemp -d /tmp/r2-10-test.XXXXXX)"
LOG="$TDIR/run.log"
PASS=0; FAIL=0
ok()   { echo "PASS: $1" | tee -a "$LOG"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" | tee -a "$LOG"; FAIL=$((FAIL+1)); }
chk()  { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

echo "worktree: $ROOT" | tee "$LOG"
bash -n "$INSTALL" && ok "bash -n install.sh" || bad "bash -n install.sh"

TRAP_LINE="$(grep "trap 'rm -f \"\$AUTH_CFG\" /tmp/dnsunlock-whoami.json; rm -rf \"\$DL_TMP\"" "$INSTALL" | head -1)"
[ -n "$TRAP_LINE" ] && ok "取到第二道 EXIT trap 原文" || bad "取到第二道 EXIT trap 原文"
echo "trap: $TRAP_LINE" | tee -a "$LOG"
chk "C trap 里含 BASELINE/AFTER_CHECK_FILE 及 .err" bash -c 'case "$1" in *BASELINE_CHECK_FILE*.err*AFTER_CHECK_FILE*.err*) true;; *) false;; esac' _ "$TRAP_LINE"
chk "C 变量在第一道 trap 之前已初始化为空" bash -c '
  init=$(grep -n "BASELINE_CHECK_FILE=\"\"" "$1" | head -1 | cut -d: -f1)
  trap1=$(grep -n "trap .rm -f \"\$AUTH_CFG\" /tmp/dnsunlock-whoami.json. EXIT" "$1" | head -1 | cut -d: -f1)
  [ -n "$init" ] && [ -n "$trap1" ] && [ "$init" -lt "$trap1" ]' _ "$INSTALL"
chk "C 两份 install.sh 仍 identical" cmp "$ROOT/scripts/install.sh" "$ROOT/internal/panel/assets/install.sh"

# A：变量都赋值，触发 EXIT
D="$TDIR/caseA"; mkdir -p "$D"
AUTH_CFG="$D/auth"; DL_TMP="$D/dl"; BASELINE_CHECK_FILE="$D/baseline"; AFTER_CHECK_FILE="$D/after"
touch "$AUTH_CFG" "$D/dnsunlock-whoami.json" "$BASELINE_CHECK_FILE" "$BASELINE_CHECK_FILE.err" "$AFTER_CHECK_FILE" "$AFTER_CHECK_FILE.err"
mkdir -p "$DL_TMP"
# 注意 /tmp/dnsunlock-whoami.json 是 trap 里的绝对路径，用同名文件占位验证：
touch /tmp/dnsunlock-whoami.json
/usr/bin/bash -c "
set -uo pipefail
AUTH_CFG='$AUTH_CFG'; DL_TMP='$DL_TMP'
BASELINE_CHECK_FILE='$BASELINE_CHECK_FILE'; AFTER_CHECK_FILE='$AFTER_CHECK_FILE'
$TRAP_LINE
exit 3
" 2>"$TDIR/caseA.err"
echo "caseA subshell rc=$?" | tee -a "$LOG"
chk "A 基线文件被清" bash -c '[ ! -e "$1" ]' _ "$BASELINE_CHECK_FILE"
chk "A 基线 .err 被清" bash -c '[ ! -e "$1.err" ]' _ "$BASELINE_CHECK_FILE"
chk "A 复测文件被清" bash -c '[ ! -e "$1" ]' _ "$AFTER_CHECK_FILE"
chk "A 复测 .err 被清" bash -c '[ ! -e "$1.err" ]' _ "$AFTER_CHECK_FILE"
chk "A AUTH_CFG 被清" bash -c '[ ! -e "$1" ]' _ "$AUTH_CFG"
chk "A DL_TMP 被清" bash -c '[ ! -e "$1" ]' _ "$DL_TMP"
chk "A /tmp/dnsunlock-whoami.json 被清" bash -c '[ ! -e /tmp/dnsunlock-whoami.json ]'

# B：变量为空，trap 不报错
/usr/bin/bash -c "
set -uo pipefail
AUTH_CFG='$TDIR/caseB-auth'; DL_TMP='$TDIR/caseB-dl'
touch \"\$AUTH_CFG\"; mkdir -p \"\$DL_TMP\"
BASELINE_CHECK_FILE=''; AFTER_CHECK_FILE=''
$TRAP_LINE
exit 0
" 2>"$TDIR/caseB.err"
BRC=$?
echo "caseB subshell rc=$BRC stderr: $(cat "$TDIR/caseB.err")" | tee -a "$LOG"
[ "$BRC" = 0 ] && ok "B 变量为空时 trap 不报错、rc=0" || bad "B 变量为空时 trap 不报错、rc=0"
chk "B 空变量时 AUTH_CFG 照常清掉" bash -c '[ ! -e "$1" ]' _ "$TDIR/caseB-auth"

echo "=== R2-10: PASS=$PASS FAIL=$FAIL ===" | tee -a "$LOG"
[ "$FAIL" = 0 ]
