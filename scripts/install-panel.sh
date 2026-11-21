#!/usr/bin/env bash
# dnsunlock 面板一键安装（P0-01）。
# 用法（在任意一台 VPS 上，root）：
#   curl -fsSL https://raw.githubusercontent.com/iiiiiiiii7125-art/dns-unlock-panel/main/scripts/install-panel.sh | bash
#   # 跑起来后会问你要不要填域名：填了就配 Caddy 自动反代 + HTTPS，
#   # 留空只跑 8080，不配反代；也可以直接传参跳过询问：
#   #   bash install-panel.sh --domain dns.example.com   （填域名 -> Caddy 自动 HTTPS 反代）
#   #   bash install-panel.sh                          （不填域名 -> 只跑 8080）
# 注意：本脚本只装面板本身（8080）+ 可选 Caddy 反代；不装 DNS agent，不碰 resolv.conf。
set -euo pipefail
DOMAIN=""
PORT="8080"
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done
# 没传 --domain 时交互式问域名：管道安装（curl | bash）时 stdin 是脚本
# 本身，所以从 /dev/tty 读；没有终端（如自动化）就跳过询问，默认只跑 8080。
# 注意：/dev/tty 即使存在也可能打不开（无控制终端），先在重定向了
# stderr 的复合命令里试开，失败时静默跳过，不要把报错打出来。
# 提示语要单独打到 /dev/tty 上：read -p 的提示走 stderr，不能跟
# 2>/dev/null 一起用，否则用户看不到问题。
if [ -z "$DOMAIN" ]; then
  if { : < /dev/tty; } 2>/dev/null; then
    printf '%s' "域名（填了就配 Caddy 自动反代 + HTTPS；留空只跑 :8080，不配反代）: " > /dev/tty
    read -r DOMAIN < /dev/tty || true
    DOMAIN="$(printf '%s' "$DOMAIN" | tr -d '[:space:]')"
  fi
fi
# P0-01 残留：域名/端口格式先校验，不合规直接停，不装一半再报错。
if [ -n "$DOMAIN" ]; then
  case "$DOMAIN" in
    *..*|.*|*.|-*|*-) echo "域名格式不对: $DOMAIN"; exit 1;;
  esac
  echo "$DOMAIN" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' || { echo "域名格式不对: $DOMAIN（请填如 dns.example.com 的完整域名）"; exit 1; }
fi
case "$PORT" in
  ''|*[!0-9]*) echo "端口格式不对: $PORT（请填 1-65535 的数字）"; exit 1;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { echo "端口超出范围: $PORT（请填 1-65535）"; exit 1; }
[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
command -v curl >/dev/null || { echo "需要 curl"; exit 1; }
command -v sha256sum >/dev/null || { echo "需要 sha256sum"; exit 1; }
command -v systemctl >/dev/null || { echo "需要 systemd"; exit 1; }
# port_in_use: 端口占用检查。优先用 ss；没有 ss 时用 bash 内置 /dev/tcp
# 探 127.0.0.1（P0-01 残留：ss 缺失时不再静默跳过检查）。
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tuln 2>/dev/null | grep -q ":$p "
    return $?
  fi
  if (echo > "/dev/tcp/127.0.0.1/$p") 2>/dev/null; then return 0; fi
  return 1
}
ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) BIN="dnsunlock-linux-amd64";; aarch64|arm64) BIN="dnsunlock-linux-arm64";; *) echo "不支持的架构: $ARCH"; exit 1;; esac
REPO="https://github.com/iiiiiiiii7125-art/dns-unlock-panel"

echo "=== dnsunlock 面板安装 ==="
# 端口预检：80/443 被占时提示，不覆盖、不杀别人的服务。
if [ -n "$DOMAIN" ]; then
  if port_in_use 80; then echo "80 端口已被占用，Caddy 无法监听；请停掉占用的服务或去掉 --domain 只跑 8080"; exit 1; fi
  if port_in_use 443; then echo "443 端口已被占用，Caddy 无法监听；请停掉占用的服务或去掉 --domain 只跑 8080"; exit 1; fi
fi
if port_in_use "$PORT"; then
  echo "端口 $PORT 已被占用，请换 --port 或停掉占用的服务"
  exit 1
fi
# 下载二进制（Release 资产，sha256 必须校验，下不到就停）
mkdir -p /usr/local/bin /etc/dnsunlock
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "[1/4] 下载面板二进制 $BIN ..."
# P0-REAL-01：二进制必须以 $BIN 的名字下载，校验文件里写的名字就是 $BIN；
# 旧写法下载为 $TMP/dnsunlock 再 sha256sum -c，目录里没有 $BIN，校验永远失败。
curl -fsSL "$REPO/releases/latest/download/$BIN" -o "$TMP/$BIN" || { echo "下载失败：Release 还没发或网络不通"; exit 1; }
curl -fsSL "$REPO/releases/latest/download/$BIN.sha256" -o "$TMP/$BIN.sha256" || { echo "sha256 文件下载失败，停止安装"; exit 1; }
(cd "$TMP" && sha256sum -c "$BIN.sha256") || { echo "sha256 校验失败，停止安装"; exit 1; }
install -m 0755 "$TMP/$BIN" /usr/local/bin/dnsunlock
mkdir -p /var/lib/dnsunlock
echo "sha256 校验通过"
# P0-REAL-02：面板的 /dl/ 从 dist 目录发二进制，agent 一键安装靠它下载。
# 旧脚本只装 /usr/local/bin/dnsunlock，从不建 dist 目录，/dl/ 永远 404，
# agent 一键安装在 [1/6] 下载那步必失败。把 5 个 Release 资产都放进 dist。
DIST_DIR="/var/lib/dnsunlock/dist"
mkdir -p "$DIST_DIR"
case "$BIN" in
  *amd64) OTHER_BIN="dnsunlock-linux-arm64" ;;
  *) OTHER_BIN="dnsunlock-linux-amd64" ;;
esac
curl -fsSL "$REPO/releases/latest/download/$OTHER_BIN" -o "$TMP/$OTHER_BIN" || { echo "另一架构二进制下载失败，停止安装"; exit 1; }
curl -fsSL "$REPO/releases/latest/download/$OTHER_BIN.sha256" -o "$TMP/$OTHER_BIN.sha256" || { echo "另一架构 sha256 下载失败，停止安装"; exit 1; }
(cd "$TMP" && sha256sum -c "$OTHER_BIN.sha256") || { echo "另一架构 sha256 校验失败，停止安装"; exit 1; }
curl -fsSL "$REPO/releases/latest/download/dnsunlock.sha256" -o "$TMP/dnsunlock.sha256" || { echo "合集 sha256 下载失败，停止安装"; exit 1; }
install -m 0644 "$TMP/$BIN" "$DIST_DIR/$BIN"
install -m 0644 "$TMP/$BIN.sha256" "$DIST_DIR/$BIN.sha256"
install -m 0644 "$TMP/$OTHER_BIN" "$DIST_DIR/$OTHER_BIN"
install -m 0644 "$TMP/$OTHER_BIN.sha256" "$DIST_DIR/$OTHER_BIN.sha256"
install -m 0644 "$TMP/dnsunlock.sha256" "$DIST_DIR/dnsunlock.sha256"
(cd "$DIST_DIR" && sha256sum -c dnsunlock.sha256) || { echo "dist 合集校验失败，停止安装"; exit 1; }
echo "dist 已就绪: $DIST_DIR（5 个资产，/dl/ 可下载）"

echo "[2/4] 写 systemd 服务..."
cat > /etc/systemd/system/dnsunlock-panel.service <<EOF
[Unit]
Description=dnsunlock panel (DNS split unlock management)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/dnsunlock panel -addr :$PORT -data /var/lib/dnsunlock/panel.json -dist /var/lib/dnsunlock/dist
Restart=always
RestartSec=3
StateDirectory=dnsunlock
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now dnsunlock-panel
sleep 1
systemctl --no-pager status dnsunlock-panel --lines=5 || true

if [ -n "$DOMAIN" ]; then
  echo "[3/4] 配置 Caddy 反代 $DOMAIN -> 127.0.0.1:$PORT（自动 HTTPS）..."
  command -v caddy >/dev/null || {
    echo "未检测到 caddy，正在安装（apt/yum/dnf 任一）..."
    if command -v apt-get >/dev/null 2>&1; then apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null && apt-get update >/dev/null && apt-get install -y caddy
    elif command -v dnf >/dev/null 2>&1; then dnf install -y 'dnf-command(copr)' >/dev/null && dnf copr enable -y @caddy/caddy >/dev/null && dnf install -y caddy
    elif command -v yum >/dev/null 2>&1; then yum install -y yum-plugin-copr >/dev/null && yum copr enable -y @caddy/caddy >/dev/null && yum install -y caddy
    else echo "装不上 caddy（没有 apt/dnf/yum），请手动装 caddy 后重跑本脚本"; exit 1; fi
  }
  mkdir -p /etc/caddy/Caddyfile.d
  cat > /etc/caddy/Caddyfile.d/dnsunlock <<EOF
# dnsunlock panel reverse proxy (generated by install-panel.sh)
$DOMAIN {
    reverse_proxy 127.0.0.1:$PORT
}
EOF
  # 幂等：只在主 Caddyfile 没引用 import 时才加一行。
  if [ -f /etc/caddy/Caddyfile ] && ! grep -q "Caddyfile.d" /etc/caddy/Caddyfile 2>/dev/null; then
    echo "import Caddyfile.d/*" >> /etc/caddy/Caddyfile
  fi
  if command -v caddy >/dev/null 2>&1; then
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || { echo "Caddyfile 校验失败，请检查 /etc/caddy/Caddyfile"; exit 1; }
  fi
  systemctl enable --now caddy
  systemctl reload caddy
  echo "反代已生效：https://$DOMAIN"
else
  echo "[3/4] 未填域名，跳过 Caddy 反代，面板只跑 :$PORT"
fi

echo "[4/4] 检查..."
# N-01: 收尾探活不用要登录的 /api/v1/status（未登录必 401，curl -f 下
# 脚本直接退出，永远打不出“安装完成”）。改用 systemd 状态 + 不鉴权的首页。
systemctl is-active --quiet dnsunlock-panel || { echo "面板服务未在运行：请看 systemctl status dnsunlock-panel / journalctl -u dnsunlock-panel"; exit 1; }
curl -fsS "http://127.0.0.1:$PORT/" | grep -q "登录面板" || { echo "面板首页无响应：请检查面板是否在 :$PORT 监听"; exit 1; }
echo "面板服务运行中，首页可访问。"
echo
echo "=== 面板安装完成 ==="
if [ -n "$DOMAIN" ]; then echo "面板地址: https://$DOMAIN"; else echo "面板地址: http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT"; fi
echo "默认登录: admin / admin（首次登录后请立即改密码）"
echo "下一步: 登录面板 -> 解锁 IP -> 添加任意 IP；DNS 服务器 -> 登记服务器，拿 agent token 去 DNS 机器上装。"
echo "卸载: bash scripts/uninstall.sh（或面板仓库里的 uninstall.sh）"
