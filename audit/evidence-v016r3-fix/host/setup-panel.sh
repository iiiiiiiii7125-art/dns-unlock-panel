#!/bin/bash
# v0.1.6 R3: 起 scratch 面板（$1=red|green），建 server/node/tiktok 规则，写容器内 case.env。
# token 只进变量与 0600 文件，绝不打印、不写日志。
set -euo pipefail
COLOR="${1:?red|green}"
BASE=/root/v016-r3
PANEL_URL="http://10.0.5.1:18280"
DIST="$BASE/dist-$COLOR"
[ -x "$DIST/dnsunlock-linux-amd64" ] || { echo "缺二进制: $DIST"; exit 1; }

# 停掉旧 scratch 面板（换色时用）
pkill -f "dnsunlock-linux-amd64 panel -addr 10.0.5.1:18280" 2>/dev/null || true
sleep 1
nohup "$DIST/dnsunlock-linux-amd64" panel -addr 10.0.5.1:18280 -data "$BASE/panel.json" -dist "$DIST" > "$BASE/panel-$COLOR.log" 2>&1 &
echo "panel $COLOR started pid $!"
i=0
until curl -fsS "$PANEL_URL/install.sh" -o /dev/null 2>/dev/null; do
  sleep 1; i=$((i+1)); [ "$i" -lt 15 ] || { echo "面板 15s 未起，见 $BASE/panel-$COLOR.log"; exit 1; }
done
echo "panel $COLOR up: $PANEL_URL"

python3 - "$PANEL_URL" "$BASE" <<'PYEOF'
import json, os, sys, urllib.request
base, d = sys.argv[1], sys.argv[2]
def call(method, path, body=None, headers=None):
    req = urllib.request.Request(base + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except Exception:
            return e.code, {}

def login(pw):
    return call("POST", "/api/v1/login", {"username": "admin", "password": pw})
st, out = login("admin")
if st != 200:
    # 换色重起：panel.json 已改过密码，用测试机本地存的密码登
    with open(d + "/admin-pass") as f:
        pw = f.read().strip()
    st, out = login(pw)
    assert st == 200, "admin 登录失败"
sess = out["session_token"]
if out.get("must_change"):
    # 首登须改密（面板默认流程）：改成测试机本地随机密码，只存 0600 文件，不打印
    import secrets
    newpass = secrets.token_hex(16)
    st2, out2 = call("POST", "/api/v1/change-password",
                      {"old_password": "admin", "new_password": newpass},
                      headers={"X-Session-Token": sess})
    assert st2 == 200, (st2, out2)
    with open(d + "/admin-pass", "w") as f:
        f.write(newpass)
    os.chmod(d + "/admin-pass", 0o600)
    st, out = login(newpass)
    assert st == 200, out
    sess = out["session_token"]
    print("admin 首登改密完成（新密码只存测试机 0600 文件）")
H = {"X-Session-Token": sess}
# 服务器：已存在就复用（换色重起面板时 panel.json 不变），否则新建
st, servers = call("GET", "/api/v1/servers", headers=H)
sv = next((s for s in servers if s.get("name") == "nspawn-dns"), None)
if sv is None:
    st, sv = call("POST", "/api/v1/servers", {"name": "nspawn-dns", "ip": "10.0.5.2"}, headers=H)
    assert st == 201, (st, sv)
    print("server created id=%s" % sv["id"])
else:
    print("server reused id=%s" % sv["id"])
    # 复用时 token 不在列表响应里：用 reveal 端点取
    st, sv2 = call("GET", "/api/v1/servers/%s/reveal" % sv["id"], headers=H)
    assert st == 200, (st, sv2)
    sv = sv2
server_id, token = sv["id"], sv["token"]
assert token, "no token"
# 节点
st, nodes = call("GET", "/api/v1/nodes", headers=H)
nd = next((n for n in nodes if n.get("name") == "nspawn-jp"), None)
if nd is None:
    st, nd = call("POST", "/api/v1/nodes", {"name": "nspawn-jp", "ip": "203.0.113.99", "region": "JP"}, headers=H)
    assert st == 201, (st, nd)
    print("node created id=%s" % nd["id"])
else:
    print("node reused id=%s" % nd["id"])
# tiktok 规则 -> 该节点
st, rule = call("PUT", "/api/v1/rules", {"platform_id": "tiktok", "node_id": nd["id"]}, headers=H)
assert st == 200, (st, rule)
print("rule tiktok -> node %s ok" % nd["id"])
# 校验 agent 配置含 tiktok 规则 IP（只校验，不打印 token/config 全文）
st, cfg = call("GET", "/api/v1/agent/config?server_id=%s" % server_id, headers={"X-Agent-Token": token})
cfg_s = json.dumps(cfg)
assert "tiktok" in cfg_s and "203.0.113.99" in cfg_s, "agent config 缺 tiktok/203.0.113.99"
print("agent config 校验通过：含 tiktok -> 203.0.113.99")
# 写容器内 case.env（0600），token 只写文件
with open("/var/lib/machines/v016-test/root/v016/case.env", "w") as f:
    f.write("PANEL_URL=%s\nDNS_AGENT_TOKEN=%s\nRIG_SERVER_ID=%s\n" % ("http://10.0.5.1:18280", token, server_id))
import os
os.chmod("/var/lib/machines/v016-test/root/v016/case.env", 0o600)
print("case.env 已写进镜像 /root/v016/case.env (0600)")
PYEOF
echo "setup-panel $COLOR done"
