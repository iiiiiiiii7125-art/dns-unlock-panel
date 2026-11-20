#!/usr/bin/env bash
# 可选助手: 把本机变成 SNI 解锁节点 (面板/DNS 分流不依赖它)。
# 用法: ./scripts/install-unlock-node.sh https://面板地址
# 等价于执行 install.sh 的 --unlock-node 分支; 本文件只是方便单独分发。
# 注意: 本机需要空出 443 端口（明文 HTTP 默认禁用）, 且必须在提示里填 allowlist (不填不启动)。
set -euo pipefail
PANEL_URL="${1:-}"
[ -n "$PANEL_URL" ] || { echo "用法: $0 <面板地址>，如 $0 http://203.0.113.5:8080"; exit 1; }
[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL "${PANEL_URL%/}/install.sh" -o "$TMP" || { echo "下载 install.sh 失败: 检查面板地址"; exit 1; }
bash "$TMP" --panel "${PANEL_URL%/}" --unlock-node
