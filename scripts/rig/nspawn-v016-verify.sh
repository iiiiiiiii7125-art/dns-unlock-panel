#!/usr/bin/env bash
# V016-12 补验：nspawn 真容器验证（指定地址恢复分支）——只准备，不许擅自跑。
#
# 状态：已备好、未执行。B 线备好的镜像与 token 已确认仍在（2026-11-21 核查，
# 均在本沙箱内，不在测试机上）：
#   - 镜像 /var/lib/machines/v016-nspawn：Ubuntu 24.04 + systemd +
#     systemd-resolved + dig，375M；resolved 上游 DNS=198.19.0.1；
#     systemd-networkd 已 mask（-> /dev/null）；/root/v016/case.env 含
#     PANEL_URL=http://127.0.0.1:18280、agent token、server id；
#     /root/v016/install.sh 与基线 374e7b7 的 install.sh md5 一致。
#   - 宿主面板数据 /tmp/nspawn-panel/panel.json 仍在：服务器 nspawn-dns、
#     节点 nspawn-jp（203.0.113.99，JP）、tiktok 规则 -> 该节点；面板已停。
#   - 测试机（ip-172-26-15-152）上 /root/v016/ 与 /var/lib/machines/
#     均不存在——镜像与 token 从来不在测试机上，别去测试机上找。
#
# 续跑命令（需用户明确放行后，由具备执行权限的代理跑）：
#   NSPAWN_VERIFY_APPROVED=1 bash scripts/rig/nspawn-v016-verify.sh
# 手动起容器（仅供排障对照）：
#   systemd-nspawn --boot --machine=v016-nspawn --directory=/var/lib/machines/v016-nspawn
#
# 注意事项（审计报告第 4 节第 2 条 + B 线执行阻塞）：
#   - 沙箱禁 NET_ADMIN，--network-veth / NAT 不可用；容器与宿主共享网络
#     命名空间，镜像内 systemd-networkd 保持 mask（本脚本起容器前会校验，
#     若 mask 丢了就直接退出，绝不管理宿主网卡）。
#   - 容器内面板地址就是宿主面板 http://127.0.0.1:18280（共享 netns，
#     127.0.0.1 直通宿主）；宿主面板由本脚本用当前 worktree 现编译的
#     二进制 + /tmp/nspawn-panel/panel.json 重新起，install.sh 从面板
#     /dl/ 下载二进制（带 token + sha256 校验），所以验的是当前代码。
#   - 绝不碰宿主 /etc/resolv.conf（脚本首尾各记一次 sha256 对账）；
#     绝不碰生产面板 https://dns.0v0.baby；绝不碰测试机。
#   - 续跑后轮换/删除测试服务器：脚本末尾会调 DELETE /api/v1/servers/<id>
#     删掉 nspawn-dns（token 随之作废）；若删除失败，脚本会大声报错，
#     续跑人必须手动在面板里删掉该服务器，不得声称已轮换。
#   - 本脚本上次被系统安全检查拦住未执行：必须等用户明确放行。脚本自带
#     审批门：不设 NSPAWN_VERIFY_APPROVED=1 就直接退出。
#   - 本脚本本身未经实跑（写好即停，未执行 nspawn）：续跑人先通读，
#     按容器内实际提示调整答案流/等待时间，以容器内断言结果为准。
#
# 补验 5 步（审计报告 B 线事项 3 + 第 4 节第 2 条）：
#   1. 安装 agent --dns-listen 127.0.0.1:53，走永久接管（含关 stub），
#      getent hosts tiktok.com 返回规则 IP；
#   2. 跑 dnsunlock-restore-dns --yes，退出码 0，resolv.conf 恢复原内容；
#   3. 三点同时成立：systemctl is-active dnsunlock-agent 为 active；
#      dig @127.0.0.1 tiktok.com A（UDP）返回规则 IP；
#      dig @127.0.0.53 example.com A 有结果（stub 与 agent 共存）；
#   4. 再测一个非 53 端口（127.0.0.1:5353）同流程，确认端口无关性；
#   5. （负向，可选）--dns-listen 127.0.0.53:53 的还原应报警告且系统 DNS
#      仍可用；若安装直接拒绝该冲突地址，记下事实即停，不强行绕过。
#   6. （R2-15）容器阶段跑一次 rig-inner（RIG_CONTAINER_STAGE=1）：V016-15
#      的 rig 容器断言（dig @127.0.0.53 UDP 真查回包源）之前零执行——沙箱
#      里是 SKIP，nspawn 脚本根本不调 rig-inner。步骤 6 在容器内真跑
#      rig-inner，输出落盘 /root/v016/rig-inner-container.log，宿主侧归档
#      进 audit/evidence-v016-fix/。跑之前先停真 resolved 与 1~5 步留下的
#      agent（rig-inner 用 stub 的 systemctl，停不掉真 stub；真 stub 占着
#      127.0.0.53:53 时 agent 绑不上 :53，S0 会直接失败；关 stub 的真实路
#      径由上面 5 步覆盖，这里只取 UDP 断言的执行价值）。
set -euo pipefail

[ "${NSPAWN_VERIFY_APPROVED:-0}" = "1" ] || {
  echo "未放行：nspawn 真容器验证需用户明确放行后才能跑。"
  echo "续跑：NSPAWN_VERIFY_APPROVED=1 bash scripts/rig/nspawn-v016-verify.sh"
  exit 1
}
[ "$(id -u)" = "0" ] || { echo "需 root 跑（systemd-nspawn --boot）"; exit 1; }
command -v systemd-nspawn >/dev/null || { echo "缺 systemd-nspawn"; exit 1; }
command -v machinectl >/dev/null || { echo "缺 machinectl"; exit 1; }

WORKTREE="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE=/var/lib/machines/v016-nspawn
MACHINE=v016-nspawn
PANEL_PORT=18280
PANEL_URL="http://127.0.0.1:$PANEL_PORT"
PANEL_DATA=/tmp/nspawn-panel/panel.json
EVIDENCE="$WORKTREE/audit/evidence-v016-fix"
GO=${GO:-$HOME/go/bin/go}
STAMP=$(date +%Y%m%d-%H%M%S)
HOST_LOG="$EVIDENCE/nspawn-host-$STAMP.log"
mkdir -p "$EVIDENCE"
exec > >(tee -a "$HOST_LOG") 2>&1

echo "== V016-12 nspawn 补验 $STAMP（基线 $(cd "$WORKTREE" && git rev-parse --short HEAD)）=="
echo "== 前置检查 =="
[ -d "$IMAGE" ] || { echo "镜像不存在: $IMAGE"; exit 1; }
[ "$(readlink "$IMAGE/etc/systemd/system/systemd-networkd.service")" = "/dev/null" ] \
  || { echo "镜像内 systemd-networkd 未 mask，退出（绝不管理宿主网卡）"; exit 1; }
[ -f "$IMAGE/root/v016/case.env" ] || { echo "镜像内 /root/v016/case.env 不存在"; exit 1; }
[ -f "$PANEL_DATA" ] || { echo "宿主面板数据不存在: $PANEL_DATA"; exit 1; }
[ -x "$GO" ] || { echo "找不到 go：设 GO=/path/to/go"; exit 1; }
HOST_RESOLV_BEFORE=$(sha256sum /etc/resolv.conf | cut -d' ' -f1)
echo "宿主 /etc/resolv.conf sha256（跑前）: $HOST_RESOLV_BEFORE"

echo "== 刷新镜像内代码为当前 worktree =="
cp "$WORKTREE/scripts/install.sh" "$IMAGE/root/v016/install.sh"
cp "$WORKTREE/scripts/restore-resolv.sh" "$IMAGE/root/v016/restore-resolv.sh"
echo "install.sh md5: $(md5sum "$IMAGE/root/v016/install.sh" | cut -d' ' -f1)"
echo "restore-resolv.sh md5: $(md5sum "$IMAGE/root/v016/restore-resolv.sh" | cut -d' ' -f1)"

echo "== 编译 dnsunlock 并起宿主面板（$PANEL_URL，数据 $PANEL_DATA）=="
(cd "$WORKTREE" && "$GO" build -trimpath -o dist/dnsunlock-linux-amd64 ./cmd/dnsunlock)
(cd "$WORKTREE/dist" && sha256sum dnsunlock-linux-amd64 > dnsunlock-linux-amd64.sha256)
"$WORKTREE/dist/dnsunlock-linux-amd64" panel -addr "127.0.0.1:$PANEL_PORT" \
  -data "$PANEL_DATA" -dist "$WORKTREE/dist" > "$EVIDENCE/nspawn-panel-$STAMP.log" 2>&1 &
PANEL_PID=$!
cleanup_panel() { kill "$PANEL_PID" 2>/dev/null || true; }
trap cleanup_panel EXIT
i=0
while [ "$i" -lt 15 ]; do
  curl -fsS "$PANEL_URL/install.sh" -o /dev/null 2>/dev/null && break
  sleep 1; i=$((i+1))
done
curl -fsS "$PANEL_URL/install.sh" -o /dev/null || { echo "面板起不来，见 $EVIDENCE/nspawn-panel-$STAMP.log"; exit 1; }

echo "== 校验 case.env 的 token 在面板上仍有效（token 本身绝不打印）=="
# 只取字段值进变量，不回显。
CASE_PANEL_URL=$(sed -n 's/^PANEL_URL=//p' "$IMAGE/root/v016/case.env" | head -1)
CASE_TOKEN=$(sed -n 's/^DNS_AGENT_TOKEN=//p' "$IMAGE/root/v016/case.env" | head -1)
CASE_SERVER=$(sed -n 's/^RIG_SERVER_ID=//p' "$IMAGE/root/v016/case.env" | head -1)
[ "$CASE_PANEL_URL" = "$PANEL_URL" ] || { echo "case.env 的 PANEL_URL 与本脚本面板地址不一致，请先核对"; exit 1; }
[ -n "$CASE_TOKEN" ] && [ -n "$CASE_SERVER" ] || { echo "case.env 缺 token 或 server id"; exit 1; }
AUTH_CFG=$(mktemp); chmod 600 "$AUTH_CFG"
printf 'header = "X-Agent-Token: %s"\n' "$CASE_TOKEN" > "$AUTH_CFG"
CFG_JSON=$(curl -fsSL -K "$AUTH_CFG" "$PANEL_URL/api/v1/agent/config?server_id=$CASE_SERVER" || true)
rm -f "$AUTH_CFG"
echo "$CFG_JSON" | grep -q "tiktok" || {
  echo "case.env 的 token 拉不到 tiktok 规则（可能已轮换/面板数据已变）。"
  echo "先在面板里重登记服务器/节点/规则并更新镜像内 /root/v016/case.env 再跑。"
  exit 1
}
echo "token 有效：agent 配置含 tiktok 规则"

echo "== 同步台架树进镜像（R2-15：步骤 6 容器内跑 rig-inner 用）=="
mkdir -p "$IMAGE/root/rig"/{stubs,state,logs,bin,fixtures}
cp "$WORKTREE/scripts/rig/rig-inner.sh" "$IMAGE/root/rig/rig-inner.sh"
cp "$WORKTREE/scripts/rig/stubs/"* "$IMAGE/root/rig/stubs/"
cp "$WORKTREE/scripts/rig/fixtures/"* "$IMAGE/root/rig/fixtures/"
cp "$WORKTREE/dist/dnsunlock-linux-amd64" "$IMAGE/root/rig/bin/dnsunlock"
(cd "$WORKTREE" && "$GO" build -trimpath -o "$IMAGE/root/rig/bin/bindprobe" ./scripts/rig/bindprobe)
(cd "$WORKTREE" && "$GO" build -trimpath -o "$IMAGE/root/rig/bin/bindhold" ./scripts/rig/bindhold)
chmod +x "$IMAGE/root/rig/stubs/"* "$IMAGE/root/rig/bin/"* "$IMAGE/root/rig/rig-inner.sh"
cp "$IMAGE/etc/nsswitch.conf" "$IMAGE/root/rig/fixtures/nsswitch.base"  # rig-inner 的 reset_state 要它
printf '%s\n' "$(cd "$WORKTREE" && git rev-parse HEAD)" > "$IMAGE/root/rig/baseline-commit.txt"  # G-1：基线戳
echo "台架树已同步进镜像 /root/rig：$(find "$IMAGE/root/rig" -type f | wc -l) 个文件，基线 $(cat "$IMAGE/root/rig/baseline-commit.txt")"

echo "== 写容器内 5 步补验脚本（进镜像 /root/v016/nspawn-guest-check.sh）=="
cat > "$IMAGE/root/v016/nspawn-guest-check.sh" <<'GUEST_EOF'
#!/bin/bash
# 容器内补验（V016-12：步骤 1~5；R2-15：步骤 6 跑 rig-inner 容器阶段）。
# 由宿主脚本写入镜像，machinectl shell 执行。
# 日志：/root/v016/nspawn-verify.log；步骤 6 另有 /root/v016/rig-inner-container.log。
# token 只从 /root/v016/case.env 读，绝不打印。
set -u
LOG=/root/v016/nspawn-verify.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
PASS=0; FAIL=0; FAILED=()
pass() { PASS=$((PASS+1)); echo "[PASS] $1"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "[FAIL] $1"; }
assert() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi; }

# shellcheck disable=SC1091
source /root/v016/case.env
export DNS_AGENT_TOKEN
RULE_DOMAIN=tiktok.com
AUTH_CFG=$(mktemp); chmod 600 "$AUTH_CFG"
printf 'header = "X-Agent-Token: %s"\n' "$DNS_AGENT_TOKEN" > "$AUTH_CFG"
CFG_JSON=$(curl -fsSL -K "$AUTH_CFG" "$PANEL_URL/api/v1/agent/config?server_id=$RIG_SERVER_ID")
rm -f "$AUTH_CFG"
RULE_IP=$(echo "$CFG_JSON" | sed -n 's/.*"node_ip":"\([^"]*\)".*/\1/p' | head -1)
[ -n "$RULE_IP" ] || { echo "拉不到规则 IP，容器内补验无法开始"; exit 2; }
echo "规则：$RULE_DOMAIN -> $RULE_IP（面板 $PANEL_URL，server $RIG_SERVER_ID）"

dig_rule_ok() { # $1=地址 $2=端口（默认 53）；UDP 真查（容器阶段，不断言 TCP 替代）
  local addr="$1" port="${2:-53}"
  dig -p "$port" +short "@$addr" "$RULE_DOMAIN" A 2>/dev/null | grep -qx "$RULE_IP"
}
dig_stub_ok() { dig +short @127.0.0.53 example.com A 2>/dev/null | grep -qE '^[0-9]+\.'; }
getent_rule_ok() { getent hosts "$RULE_DOMAIN" 2>/dev/null | grep -q "$RULE_IP"; }
getent_example_ok() { getent hosts example.com 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; }

do_install() { # $1=监听地址 $2=日志；rc 记进 LAST_RC，函数本身总返回 0（让断言而非 set -e 裁决）
  local listen="$1" log="$2"
  printf 'y\ny\ny\ny\ny\ny\n' > /tmp/nspawn-answers.txt
  DNS_AGENT_TOKEN="$DNS_AGENT_TOKEN" DNS_SERVER_NAME="nspawn-dns" \
    DNS_DEFAULT_IP="$RULE_IP" DNS_ALLOWLIST="127.0.0.1" \
    script -qec "bash /root/v016/install.sh --panel $PANEL_URL --dns-listen $listen" \
    /dev/null < /tmp/nspawn-answers.txt > "$log" 2>&1
  LAST_RC=$?
  echo "install $listen rc=$LAST_RC（日志 $log）"
  return 0
}
do_restore() { # $1=日志；rc 记进 LAST_RC，函数本身总返回 0
  dnsunlock-restore-dns --yes > "$1" 2>&1
  LAST_RC=$?
  echo "restore rc=$LAST_RC（日志 $1）"
  return 0
}
last_rc0() { [ "${LAST_RC:-99}" = 0 ]; }

echo "=== 步骤 0：容器内基线 ==="
systemctl stop dnsunlock-agent 2>/dev/null || true
systemctl disable dnsunlock-agent 2>/dev/null || true
rm -rf /var/lib/dnsunlock /etc/dnsunlock
mkdir -p /var/lib/dnsunlock/backup /etc/dnsunlock
assert "步骤 0：systemd-resolved 在跑" systemctl is-active --quiet systemd-resolved
assert "步骤 0：stub 在 127.0.0.53:53 监听" bash -c "ss -tuln | grep -q '127.0.0.53:53'"
cp /etc/resolv.conf /root/v016/resolv.conf.baseline
echo "步骤 0：基线 resolv.conf 已存 /root/v016/resolv.conf.baseline"

echo "=== 步骤 1：安装 --dns-listen 127.0.0.1:53 ==="
do_install 127.0.0.1:53 /root/v016/step1-install.log
assert "步骤 1：install rc=0" last_rc0
assert "步骤 1：getent tiktok.com 返回规则 IP" getent_rule_ok
assert "步骤 1：getent example.com 仍走上游" getent_example_ok

echo "=== 步骤 2：还原 --yes ==="
do_restore /root/v016/step2-restore.log
assert "步骤 2：restore rc=0" last_rc0
assert "步骤 2：resolv.conf 恢复原内容" cmp -s /etc/resolv.conf /root/v016/resolv.conf.baseline
assert "步骤 2：还原后系统 DNS 可用" getent_example_ok

echo "=== 步骤 3：三点共存断言（UDP 真查） ==="
assert "步骤 3：agent 已恢复运行" systemctl is-active --quiet dnsunlock-agent
assert "步骤 3：dig @127.0.0.1 tiktok.com（UDP）返回规则 IP" dig_rule_ok 127.0.0.1 53
assert "步骤 3：dig @127.0.0.53 example.com 有结果（stub 回来了）" dig_stub_ok

echo "=== 步骤 4：非 53 端口 127.0.0.1:5353 同流程 ==="
do_install 127.0.0.1:5353 /root/v016/step4-install.log
assert "步骤 4：install rc=0" last_rc0
assert "步骤 4：getent tiktok.com 返回规则 IP" getent_rule_ok
do_restore /root/v016/step4-restore.log
assert "步骤 4：restore rc=0" last_rc0
assert "步骤 4：resolv.conf 恢复原内容" cmp -s /etc/resolv.conf /root/v016/resolv.conf.baseline
assert "步骤 4：agent 已恢复运行" systemctl is-active --quiet dnsunlock-agent
assert "步骤 4：dig @127.0.0.1 -p 5353 tiktok.com（UDP）返回规则 IP" dig_rule_ok 127.0.0.1 5353
assert "步骤 4：dig @127.0.0.53 example.com 有结果" dig_stub_ok
assert "步骤 4：还原后系统 DNS 可用" getent_example_ok

echo "=== 步骤 5（负向，可选）：--dns-listen 127.0.0.53:53 ==="
# 若安装直接拒绝该冲突地址，记下事实即停，不强行绕过；本步失败不计入 FAIL。
do_install 127.0.0.53:53 /root/v016/step5-install.log
if [ "${LAST_RC:-99}" != "0" ]; then
  echo "[STEP5-OPTIONAL] 安装拒绝 127.0.0.53:53（rc=$LAST_RC），符合预期冲突，记下即停，不强行绕过"
else
  do_restore /root/v016/step5-restore.log
  if grep -q "警告" /root/v016/step5-restore.log; then
    echo "[STEP5-OPTIONAL] 还原报警告，符合预期"
  else
    echo "[STEP5-OPTIONAL] 还原未报警告（见 step5-restore.log），记录在案"
  fi
  if getent_example_ok; then echo "[STEP5-OPTIONAL] 系统 DNS 仍可用"; else echo "[STEP5-OPTIONAL] 系统 DNS 不可用，记录在案"; fi
fi

echo "=== 步骤 6：rig-inner 容器阶段（R2-15，RIG_CONTAINER_STAGE=1）==="
# R2-15：V016-15 的 rig 容器断言（dig @127.0.0.53 UDP 真查回包源）之前零执行——
# 沙箱里是 SKIP，nspawn 脚本根本不调 rig-inner。这里在容器内真跑一次 rig-inner，
# 输出落盘 /root/v016/rig-inner-container.log（另有 pty 逐字稿
# /root/v016/rig-inner-container-typescript），宿主侧归档进 $EVIDENCE。
# 前置清理（不属于 rig-inner 本身）：先停真 resolved 与 1~5 步留下的 agent。
# rig-inner 用 stub 的 systemctl（PATH 前置），它停不掉容器里真的 resolved；
# 真 stub 占着 127.0.0.53:53 时 agent 绑不上 :53，S0 会直接失败；关 stub 的
# 真实路径由上面 5 步（真 systemd）覆盖，这里只取 UDP 断言的执行价值。
# 答案流与 scripts/test-takeover-rig.sh 的答案表同步（24 行），多一个提问就错一位。
if [ ! -x /root/rig/rig-inner.sh ]; then
  echo "步骤 6：镜像内 /root/rig/rig-inner.sh 不存在，宿主同步漏了"
  fail "步骤 6：rig-inner 已同步进镜像"
else
  pass "步骤 6：rig-inner 已同步进镜像"
  systemctl stop dnsunlock-agent 2>/dev/null || true
  systemctl stop systemd-resolved 2>/dev/null || true
  sleep 1
  {
    printf 'y\ny\ny\n'      # S1b: 关 stub / 接管 / 摘要
    printf 'y\ny\n'         # S2: 接管 / 摘要
    printf 'y\ny\n'         # S6: 接管 / 摘要
    printf 'not-a-url\n'    # S7a: 手动输入（非法）
    printf '%s\ny\ny\n' "$PANEL_URL"  # S7b: 手动输入 / 接管 / 摘要
    printf 'y\n\n'          # S8: 接管 / 摘要默认 N
    printf 'y\n\n'          # S9a: 接管 / hpve 默认 N
    printf 'y\ny\ny\n'      # S9b: 接管 / hpve / 摘要
    printf 'y\ny\n'         # S10: 接管 / 摘要
    printf 'y\ny\n'         # S11: 接管 / 摘要
    printf 'y\ny\n'         # S13: 接管 / 摘要
  } > /tmp/nspawn-rig-answers.txt
  if [ "$(wc -l < /tmp/nspawn-rig-answers.txt)" = 24 ]; then
    pass "步骤 6：答案流 24 行"
  else
    fail "步骤 6：答案流 24 行"
  fi
  RIG_INNER_RC=99
  RIG_CONTAINER_STAGE=1 DNS_AGENT_TOKEN="$DNS_AGENT_TOKEN" RIG_SERVER_ID="$RIG_SERVER_ID" PANEL_URL="$PANEL_URL" \
    script -qec "/bin/bash /root/rig/rig-inner.sh" /root/v016/rig-inner-container-typescript \
    < /tmp/nspawn-rig-answers.txt > /root/v016/rig-inner-container.log 2>&1
  RIG_INNER_RC=$?
  echo "rig-inner 容器阶段退出码：$RIG_INNER_RC（日志 /root/v016/rig-inner-container.log）"
  rig_inner_rc0() { [ "${RIG_INNER_RC:-99}" = 0 ]; }
  assert "步骤 6：rig-inner 容器阶段通过（RIG_CONTAINER_STAGE=1）" rig_inner_rc0
  assert "步骤 6：容器阶段断言已执行（日志里无 SKIP-容器阶段）" bash -c "! grep -q 'SKIP-容器阶段' /root/v016/rig-inner-container.log"
  assert "步骤 6：容器阶段 UDP 断言已跑（日志含 dig @127.0.0.53 断言行）" bash -c "grep -q '容器阶段.*dig @127.0.0.53' /root/v016/rig-inner-container.log"
fi

echo "=== NSPAWN 补验汇总：PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  printf '失败项：\n'
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
exit 0
GUEST_EOF
chmod +x "$IMAGE/root/v016/nspawn-guest-check.sh"
bash -n "$IMAGE/root/v016/nspawn-guest-check.sh" || { echo "容器内脚本 bash -n 未过"; exit 1; }

echo "== 起容器 =="
systemd-nspawn --boot --machine="$MACHINE" --directory="$IMAGE" \
  > "$EVIDENCE/nspawn-boot-$STAMP.log" 2>&1 &
NSPAWN_PID=$!
i=0
while [ "$i" -lt 60 ]; do
  if machinectl show "$MACHINE" >/dev/null 2>&1; then break; fi
  sleep 1; i=$((i+1))
done
machinectl show "$MACHINE" >/dev/null 2>&1 || { echo "容器 60 秒未起来，见 $EVIDENCE/nspawn-boot-$STAMP.log"; kill "$NSPAWN_PID" 2>/dev/null || true; exit 1; }
echo "容器已起：$MACHINE"

echo "== 容器内跑 5 步补验 =="
set +e
machinectl shell --uid=root "$MACHINE" /bin/bash /root/v016/nspawn-guest-check.sh
GUEST_RC=$?
set -e
echo "容器内补验退出码：$GUEST_RC"

echo "== 关容器 =="
machinectl poweroff "$MACHINE" 2>/dev/null || true
i=0
while [ "$i" -lt 60 ]; do
  machinectl show "$MACHINE" >/dev/null 2>&1 || break
  sleep 1; i=$((i+1))
done
if machinectl show "$MACHINE" >/dev/null 2>&1; then
  machinectl terminate "$MACHINE" 2>/dev/null || true
  sleep 5
fi
kill "$NSPAWN_PID" 2>/dev/null || true

echo "== 归档日志 =="
cp "$IMAGE/root/v016/nspawn-verify.log" "$EVIDENCE/nspawn-verify-$STAMP.log"
cp "$IMAGE/root/v016/resolv.conf.baseline" "$EVIDENCE/nspawn-resolv-baseline-$STAMP.txt" 2>/dev/null || true
# R2-15：步骤 6 的 rig-inner 容器阶段日志是本次补验的证据本体，必须落盘归档。
cp "$IMAGE/root/v016/rig-inner-container.log" "$EVIDENCE/rig-inner-container-$STAMP.log" 2>/dev/null \
  || echo "警告：容器内 rig-inner 日志未生成（步骤 6 未跑或未落盘），R2-15 未闭合"
cp "$IMAGE/root/v016/rig-inner-container-typescript" "$EVIDENCE/rig-inner-container-typescript-$STAMP.log" 2>/dev/null || true
echo "容器内日志：$EVIDENCE/nspawn-verify-$STAMP.log"
echo "容器内 rig-inner 日志：$EVIDENCE/rig-inner-container-$STAMP.log"
echo "宿主日志：$HOST_LOG"

echo "== 轮换/删除测试服务器（token 作废） =="
# 管理登录：先试 admin/admin；若已改密（must-change 或 401），退出并让人手动处理，
# 绝不猜密码、绝不把 token 写进日志。
jget() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
SESSION=$(curl -fsSL -X POST "$PANEL_URL/api/v1/login" -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin"}' 2>/dev/null | jget "['session_token']" 2>/dev/null || true)
if [ -z "$SESSION" ]; then
  echo "警告：面板 admin/admin 登录失败，无法自动删测试服务器。"
  echo "续跑人必须手动在面板里删除服务器 $CASE_SERVER（或轮换其 token），否则不得声称已轮换。"
else
  if curl -fsSL -H "X-Session-Token: $SESSION" -X DELETE "$PANEL_URL/api/v1/servers/$CASE_SERVER" > /dev/null; then
    echo "测试服务器 $CASE_SERVER 已删除（token 作废）"
  else
    echo "警告：DELETE 服务器失败，续跑人必须手动在面板里删除 $CASE_SERVER。"
  fi
fi

HOST_RESOLV_AFTER=$(sha256sum /etc/resolv.conf | cut -d' ' -f1)
echo "宿主 /etc/resolv.conf sha256（跑后）: $HOST_RESOLV_AFTER"
[ "$HOST_RESOLV_BEFORE" = "$HOST_RESOLV_AFTER" ] \
  || echo "警告：宿主 /etc/resolv.conf 在补验前后变了，请核查（本脚本绝不改它）"
echo "== nspawn 补验结束，容器内退出码 $GUEST_RC；日志见 $EVIDENCE =="
exit "$GUEST_RC"
