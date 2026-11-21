#!/usr/bin/env bash
# R2-13 沙箱验证：probe_panel 校验 whoami 响应形态。
# 从 install.sh 提取 probe_panel 原文，对三个本地 fake 服务跑：
#   :8080  冒名者——即时回 404 + HTML（并行测速下最快）
#   :18081 真面板——0.3s 延迟回 401 + JSON {"error":"unauthorized: agent token required"}
#   :18082 真面板（200 变体）——0.5s 延迟回 200 + JSON {"server_id":"srv-test"}
#   A base :18081 → 必须选中 :18081，:8080 被判“不是面板”
#   B base :18082 → 必须选中 :18082
#   C base :18080（无服务）→ 只有冒名者响应 → rc=1“面板都连不上”
#   D 红证：7b86d49 旧版 probe_panel 跑 A 场景 → 选中冒名者 :8080
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
TDIR="$(mktemp -d /tmp/r2-13-test.XXXXXX)"
LOG="$TDIR/run.log"
PASS=0; FAIL=0
ok()   { echo "PASS: $1" | tee -a "$LOG"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" | tee -a "$LOG"; FAIL=$((FAIL+1)); }
chk()  { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

echo "worktree: $ROOT" | tee "$LOG"
bash -n "$INSTALL" && ok "bash -n install.sh" || bad "bash -n install.sh"

cat > "$TDIR/fake.py" <<'PYEOF'
import sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
port, mode = int(sys.argv[1]), sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if mode == "impostor":
            body = b"<html><body>404 Not Found</body></html>"
            self.send_response(404); self.send_header("Content-Type", "text/html")
        elif mode == "real401":
            time.sleep(0.3)
            body = b'{"error":"unauthorized: agent token required"}'
            self.send_response(401); self.send_header("Content-Type", "application/json")
        elif mode == "real200":
            time.sleep(0.5)
            body = b'{"server_id":"srv-test","name":"test"}'
            self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF

{ echo 'set -uo pipefail'; sed -n '/^probe_panel() {/,/^}/p' "$INSTALL"; } > "$TDIR/funcs.sh"
bash -n "$TDIR/funcs.sh" && ok "提取的新版 probe_panel bash -n 通过" || bad "提取的新版 probe_panel bash -n 通过"
git -C "$ROOT" show 7b86d49:scripts/install.sh > "$TDIR/install-old.sh"
{ echo 'set -uo pipefail'; sed -n '/^probe_panel() {/,/^}/p' "$TDIR/install-old.sh"; } > "$TDIR/funcs-old.sh"
bash -n "$TDIR/funcs-old.sh" && ok "提取的旧版 probe_panel bash -n 通过" || bad "提取的旧版 probe_panel bash -n 通过"

PIDS=""
cleanup() { [ -n "$PIDS" ] && kill $PIDS 2>/dev/null; }
trap cleanup EXIT
python3 "$TDIR/fake.py" 8080 impostor & PIDS="$PIDS $!"
python3 "$TDIR/fake.py" 18081 real401 & PIDS="$PIDS $!"
python3 "$TDIR/fake.py" 18082 real200 & PIDS="$PIDS $!"
for p in 8080 18081 18082; do
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -fsS -o /dev/null "http://127.0.0.1:$p/api/v1/agent/whoami" 2>/dev/null && break; sleep 0.2; done
done
curl -s -o /dev/null "http://127.0.0.1:8080/api/v1/agent/whoami"; echo "impostor up (404 expected, rc ignored)" | tee -a "$LOG"

run_case() { # <id> <funcs> <base-url>
  local id="$1" funcs="$2" base="$3"
  /usr/bin/bash -c "source \"$funcs\"; probe_panel \"$base\"" > "$TDIR/out-$id.log" 2> "$TDIR/err-$id.log"
  echo "rc=$?" > "$TDIR/rc-$id"
  echo "--- case $id base=$base $(cat "$TDIR/rc-$id") ---" | tee -a "$LOG"
  echo "stdout: $(cat "$TDIR/out-$id.log")" | tee -a "$LOG"
  grep -E '探测|面板都连不上' "$TDIR/err-$id.log" | tee -a "$LOG"
}

run_case A "$TDIR/funcs.sh" "http://127.0.0.1:18081"
chk "A rc=0" grep -qx 'rc=0' "$TDIR/rc-A"
chk "A 选中真面板 :18081" grep -qx 'http://127.0.0.1:18081' "$TDIR/out-A.log"
chk "A :8080 被判不是面板" grep -q 'http://127.0.0.1:8080 -> 不是面板' "$TDIR/err-A.log"

run_case B "$TDIR/funcs.sh" "http://127.0.0.1:18082"
chk "B rc=0" grep -qx 'rc=0' "$TDIR/rc-B"
chk "B 选中真面板 :18082（200 + server_id）" grep -qx 'http://127.0.0.1:18082' "$TDIR/out-B.log"
chk "B :8080 被判不是面板" grep -q 'http://127.0.0.1:8080 -> 不是面板' "$TDIR/err-B.log"

run_case C "$TDIR/funcs.sh" "http://127.0.0.1:18080"
chk "C rc=1（只有冒名者，不通）" grep -qx 'rc=1' "$TDIR/rc-C"
chk "C 输出为空（未选中任何入口）" bash -c '[ ! -s "$1" ]' _ "$TDIR/out-C.log"
chk "C 报面板都连不上" grep -q '面板都连不上' "$TDIR/err-C.log"

run_case D "$TDIR/funcs-old.sh" "http://127.0.0.1:18081"
chk "D（红证）旧版选中冒名者 :8080" grep -qx 'http://127.0.0.1:8080' "$TDIR/out-D.log"

echo "=== R2-13: PASS=$PASS FAIL=$FAIL ===" | tee -a "$LOG"
[ "$FAIL" = 0 ]
