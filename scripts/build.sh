#!/usr/bin/env bash
# 构建 dnsunlock 双架构二进制 + 校验文件（N-02）。
# 产物（dist/）：
#   dnsunlock-linux-amd64 / dnsunlock-linux-arm64
#   dnsunlock-linux-amd64.sha256 / dnsunlock-linux-arm64.sha256
#     —— 每个文件只含本架构那一行的哈希，安装脚本按 $BIN.sha256 下载，
#        只装一个架构时 sha256sum -c 不会再报另一架构缺失。
#   dnsunlock.sha256 —— 合集（两个架构都在），仅供人工核对。
# Release 资产清单 = 上面 5 个文件（两个二进制 + 两个分架构 sha256 + 合集）。
set -euo pipefail
cd "$(dirname "$0")/.."
GO="${GO:-$(command -v go || echo "$HOME/go/bin/go")}"
[ -x "$GO" ] || { echo "找不到 go：请装 Go 1.24+ 或设 GO=/path/to/go"; exit 1; }
mkdir -p dist
echo "go: $($GO version)"
CGO_ENABLED=0 "$GO" build -trimpath -o dist/dnsunlock-linux-amd64 ./cmd/dnsunlock
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 "$GO" build -trimpath -o dist/dnsunlock-linux-arm64 ./cmd/dnsunlock
(cd dist && sha256sum dnsunlock-linux-amd64 > dnsunlock-linux-amd64.sha256)
(cd dist && sha256sum dnsunlock-linux-arm64 > dnsunlock-linux-arm64.sha256)
(cd dist && sha256sum dnsunlock-linux-amd64 dnsunlock-linux-arm64 > dnsunlock.sha256)
(cd dist && sha256sum -c dnsunlock-linux-amd64.sha256 && sha256sum -c dnsunlock-linux-arm64.sha256 && sha256sum -c dnsunlock.sha256)
ls -l dist/
file dist/dnsunlock-linux-amd64 dist/dnsunlock-linux-arm64 2>/dev/null || true
