#!/usr/bin/env bash
# 沙箱接管验证台架（v0.1.6 shell 线）——入口脚本。
#
# 用法：bash scripts/test-takeover-rig.sh [--keep]
#   --keep  跑完不杀 panel（调试用；panel 日志在 /tmp/rig-panel/panel.log）
#
# 隔离方式（nspawn 在沙箱里不可行，见下）：
#   unshare --mount（不加 --user——嵌套 userns 里 :53 绑不上，实测 permission
#   denied；不加 --user 时 :53 绑定正常）+ chroot /var/lib/machines/v016-test
#   + mount -t proc proc <rootfs>/proc（plain --mount 下实测可行，ss 才能看见
#   真监听；--pid 下挂 proc 才被禁）+ mount -t devpts（给 script(1) 的 pty 用）
#   + script -qec（给 install.sh 的 /dev/tty 提问提供控制终端）。chroot 内 /etc
#   就是 rootfs 的 /etc，宿主 /etc/resolv.conf（spawnd 只读挂载）绝不被碰。
#   沙箱 UDP 回环限制（Go UDP echo 实测：server 收到包、client 等不到回包，
#   chroot 内外都一样；UDP 到外部 198.19.0.1 正常）：dig 一律 +tcp；
#   probe 永远判 UDP 死、TCP 活 → 接管总写 options use-vc；“UDP 通不写
#   use-vc”只在 S14 用假 dig 单测，不在沙箱端到端里测。
#   全部交互答案由本脚本按场景顺序一次性喂进 pty（答案表在下面）。
#
# 真跑的部分：真 panel（宿主 127.0.0.1:18180 起动态挑空闲端口，上游 198.19.0.1）+ 真 agent
#   （chroot 内 :53 / :15353）+ 真 dig/getent/curl/ss/ip + 真 chroot 绑定探测。
# stub 的部分（PATH 前置 /root/rig/stubs，只在 chroot 内生效）：
#   systemctl / resolvectl / nmcli / netplan / resolvconf / chattr / lsattr /
#   python3（只实现 can_bind_listen 的 bind 探测，调 Go 写的 bindprobe）。
#   每个 stub 记录每次调用（命令+参数）到 /root/rig/logs/calls.log；
#   systemctl 模拟最小状态（is-active/is-enabled 的 canned 值、
#   disable/restart 写 marker 并真的启停台架里的 agent / 干掉 stub 占位进程）。
#   NM 守护进程不跑，只验“写对 conf.d + 调对 nmcli”这一层。
#   chattr +i 在沙箱 overlayfs 上实测 Operation not permitted，
#   所以锁本身只能 stub 模拟（marker 文件）；真文件系统上的行为待验。
#
# 覆盖清单：S0 基线 / S1b stub-only 接管 / S2 首份备份永不覆盖 /
#   S3 还原回滚 / S4 --temp resolvectl 路径 / S5 --temp 直接写文件 /
#   S6 缺 dig 警告继续 / S7a 手动输入非法拒绝 / S7b 手动输入合法继续 /
#   S8 摘要确认默认 N / S9a hpve-init 默认 N / S9b hpve-init 确认继续 /
#   S10 nsswitch 补 dns / S11 升级路径（disable --now resolved）/
#   S12 Tailscale 守卫 / S13 还原 --backup 指定备份 /
#   S14 函数级（validate_ipv4 / valid_panel_url / probe / UUID / verify）/
#   S15 无永久备份提示临时清理办法。
#
# 沙箱里验不了（改到 rebase 后测试机 nspawn 容器里验）：
#   真 systemd-resolved 的行为（drop-in 关 stub 后 127.0.0.53 停掉、
#   resolved 不覆写静态 resolv.conf）、真 chattr +i 锁、真 NM 守护进程行为、
#   真 netplan apply、真 resolvconf -u。汇报里分两栏写，不要把台架结果
#   说成 systemd 容器结果。
#   另：dig @127.0.0.53（UDP）回包源断言是容器阶段的（见 rig-inner.sh 头），
#   沙箱 rig 只跑 stop marker、agent 状态、+tcp @127.0.0.53 对照等价断言；
#   容器阶段由 scripts/rig/nspawn-v016-verify.sh 覆盖（V016-12 补验）。
#
# 答案表（按场景顺序，一行一个提问，空行 = 默认 N）：
#   S1b: 关 stub y / 接管 y / 摘要 y
#   S2:  接管 y / 摘要 y
#   S6:  接管 y / 摘要 y
#   S7a: 手动输入 not-a-url（非法）
#   S7b: 手动输入 http://127.0.0.1:18080 / 接管 y / 摘要 y
#   S8:  接管 y / 摘要空（默认 N）
#   S9a: 接管 y / hpve 空（默认 N）
#   S9b: 接管 y / hpve y / 摘要 y
#   S10: 接管 y / 摘要 y
#   S11: 接管 y / 摘要 y
#   S13: 接管 y / 摘要 y
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT=/var/lib/machines/v016-test
RIG=$ROOT/root/rig
# 面板端口：沙箱是多 lane 共用的，18080 已被 v0.1.5 验证的 panel 占着，
# 这里从 18180 起挑第一个空闲端口（不要杀别人的进程）。
PANEL_PORT=""
for _p in 18180 18181 18182 18183 18184 18185; do
  if ! ss -tln 2>/dev/null | grep -q ":$_p "; then PANEL_PORT=$_p; break; fi
done
[ -n "$PANEL_PORT" ] || { echo "18180-18185 都被占了，换一段端口"; exit 1; }
PANEL_URL="http://127.0.0.1:$PANEL_PORT"
PANEL_DIR=/tmp/rig-panel
PANEL_DATA=$PANEL_DIR/panel.json
GO=${GO:-$HOME/go/bin/go}
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

PANEL_PID=""
cleanup_panel() {
  if [ "$KEEP" != 1 ] && [ -n "$PANEL_PID" ]; then kill "$PANEL_PID" 2>/dev/null || true; fi
}
trap cleanup_panel EXIT

[ -d "$ROOT" ] || { echo "台架 rootfs 不存在: $ROOT"; exit 1; }
command -v unshare >/dev/null || { echo "需要 unshare"; exit 1; }
command -v chroot >/dev/null || { echo "需要 chroot"; exit 1; }
[ -x "$GO" ] || { echo "找不到 go：设 GO=/path/to/go（默认 ~/go/bin/go）"; exit 1; }

echo "== 构建 dnsunlock（amd64）=="
"$GO" build -trimpath -o dist/dnsunlock-linux-amd64 ./cmd/dnsunlock
(cd dist && sha256sum dnsunlock-linux-amd64 > dnsunlock-linux-amd64.sha256)

echo "== 起 panel（宿主 $PANEL_URL，上游 198.19.0.1）=="
mkdir -p "$PANEL_DIR"
printf '{"upstream":"198.19.0.1","rules":{},"server_rules":{}}' > "$PANEL_DATA"
chmod 600 "$PANEL_DATA"
./dist/dnsunlock-linux-amd64 panel -addr "127.0.0.1:$PANEL_PORT" -data "$PANEL_DATA" -dist "$PWD/dist" > "$PANEL_DIR/panel.log" 2>&1 &
PANEL_PID=$!
i=0
while [ "$i" -lt 15 ]; do
  if curl -fsS "$PANEL_URL/install.sh" -o /dev/null 2>/dev/null; then break; fi
  sleep 1; i=$((i+1))
done
curl -fsS "$PANEL_URL/install.sh" -o /dev/null || { echo "panel 起不来，见 $PANEL_DIR/panel.log"; exit 1; }

echo "== 面板里登记服务器/节点/规则 =="
jget() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
SESSION=$(curl -fsSL -X POST "$PANEL_URL/api/v1/login" -H 'Content-Type: application/json' -d '{"username":"admin","password":"admin"}' | jget "['session_token']")
[ -n "$SESSION" ] || { echo "panel 登录失败"; exit 1; }
# 默认 admin/admin 是 must-change 状态，管理 API 一律 403：先改密码再重新登录。
curl -fsSL -H "X-Session-Token: $SESSION" -X POST "$PANEL_URL/api/v1/change-password" -H 'Content-Type: application/json' -d '{"old_password":"admin","new_password":"rig-admin-pass-1"}' > /dev/null || { echo "改密码失败"; exit 1; }
SESSION=$(curl -fsSL -X POST "$PANEL_URL/api/v1/login" -H 'Content-Type: application/json' -d '{"username":"admin","password":"rig-admin-pass-1"}' | jget "['session_token']")
[ -n "$SESSION" ] || { echo "用新密码登录失败"; exit 1; }
SRV_JSON=$(curl -fsSL -H "X-Session-Token: $SESSION" -X POST "$PANEL_URL/api/v1/servers" -H 'Content-Type: application/json' -d '{"name":"rig-dns","ip":"127.0.0.1","allowlist":"127.0.0.1"}')
TOKEN=$(echo "$SRV_JSON" | jget "['token']")
SERVER_ID=$(echo "$SRV_JSON" | jget "['id']")
[ -n "$TOKEN" ] && [ -n "$SERVER_ID" ] || { echo "登记服务器失败: $SRV_JSON"; exit 1; }
NODE_JSON=$(curl -fsSL -H "X-Session-Token: $SESSION" -X POST "$PANEL_URL/api/v1/nodes" -H 'Content-Type: application/json' -d '{"name":"rig-jp","ip":"203.0.113.99","region":"JP"}')
NODE_ID=$(echo "$NODE_JSON" | jget "['id']")
[ -n "$NODE_ID" ] || { echo "建节点失败: $NODE_JSON"; exit 1; }
curl -fsSL -H "X-Session-Token: $SESSION" -X PUT "$PANEL_URL/api/v1/rules" -H 'Content-Type: application/json' -d "{\"platform_id\":\"tiktok\",\"node_id\":\"$NODE_ID\"}" > /dev/null
CFG_JSON=$(curl -fsSL -H "X-Agent-Token: $TOKEN" "$PANEL_URL/api/v1/agent/config?server_id=$SERVER_ID")
echo "$CFG_JSON" | grep -q "tiktok" || { echo "规则未进 agent 配置: $CFG_JSON"; exit 1; }
echo "$CFG_JSON" | grep -q "203.0.113.99" || { echo "规则 IP 未进 agent 配置: $CFG_JSON"; exit 1; }
echo "panel 就绪：server=$SERVER_ID node=$NODE_ID 规则 tiktok -> 203.0.113.99"

echo "== 准备台架文件（$RIG）=="
rm -rf "$RIG"
mkdir -p "$RIG"/{stubs,state,logs,bin,fixtures}
cp scripts/install.sh "$RIG/install.sh"
cp scripts/rig/rig-inner.sh "$RIG/rig-inner.sh"
cp scripts/rig/stubs/* "$RIG/stubs/"
cp scripts/rig/fixtures/* "$RIG/fixtures/"
cp dist/dnsunlock-linux-amd64 "$RIG/bin/dnsunlock"
"$GO" build -trimpath -o "$RIG/bin/bindprobe" ./scripts/rig/bindprobe
"$GO" build -trimpath -o "$RIG/bin/bindhold" ./scripts/rig/bindhold
chmod +x "$RIG"/stubs/* "$RIG/bin/"* "$RIG/rig-inner.sh"
cp "$ROOT/etc/nsswitch.conf" "$RIG/fixtures/nsswitch.base"
# chroot 内验证 panel 可达（共用宿主网络，127.0.0.1:18080 应通）
unshare --mount chroot "$ROOT" /usr/bin/curl -fsS "$PANEL_URL/install.sh" -o /dev/null || { echo "chroot 内连不上 panel $PANEL_URL"; exit 1; }

echo "== 生成答案流（24 行，见本脚本头答案表）=="
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
} > /tmp/rig-answers.txt
[ "$(wc -l < /tmp/rig-answers.txt)" = 24 ] || { echo "答案流不是 24 行"; exit 1; }

# 挂载点准备：chroot 的 /dev 缺 tty/null/zero/urandom 节点（mknod 在沙箱里
# EPERM，连 userns 里也不行），改成每次进 chroot 前 bind 挂宿主的同名设备
# （/dev/tty 是魔数设备 5,0，打开时永远解析成调用进程自己的控制终端，
# 也就是 script 的 pty，不会串到宿主的 tty）。占位文件常驻 rootfs 无害。
D=$ROOT/dev
touch "$D/tty" "$D/null" "$D/zero" "$D/urandom" 2>/dev/null || true
: > "$D/null" 2>/dev/null || true  # 之前 /dev/null 是个普通文件，先截断
echo "== 进 chroot 跑台架（script 分配 pty 供 /dev/tty 提问）=="
export DNS_AGENT_TOKEN="$TOKEN" RIG_SERVER_ID="$SERVER_ID" PANEL_URL="$PANEL_URL"
export RIG_CONTAINER_STAGE="${RIG_CONTAINER_STAGE:-0}"  # V016-15：容器里跑才置 1，见 rig-inner.sh 头
set +e
# proc 挂进 chroot：ss 才能看见真监听（install.sh 的 stub_only_conflict
# 和台架的 ss 断言都靠它；plain --mount 下挂 proc 实测可行，--pid 下才禁）。
unshare --mount bash -c 'mount --make-rprivate /; mount -t proc proc /var/lib/machines/v016-test/proc; mount -t devpts devpts /var/lib/machines/v016-test/dev/pts; mount --bind /dev/tty /var/lib/machines/v016-test/dev/tty; mount --bind /dev/null /var/lib/machines/v016-test/dev/null; mount --bind /dev/zero /var/lib/machines/v016-test/dev/zero; mount --bind /dev/urandom /var/lib/machines/v016-test/dev/urandom; exec chroot /var/lib/machines/v016-test /usr/bin/script -qec "/bin/bash /root/rig/rig-inner.sh" /root/rig/logs/typescript' < /tmp/rig-answers.txt
RC=$?
set -e
echo "== 台架退出码: $RC（日志：chroot 内 /root/rig/logs/，宿主路径 $RIG/logs/；panel 日志 $PANEL_DIR/panel.log）=="
exit "$RC"
