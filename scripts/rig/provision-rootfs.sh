#!/usr/bin/env bash
# 台架 rootfs 供应（v0.1.6 shell 线，唯一供应入口）。
#
# 保证 /var/lib/machines/v016-test 存在且含台架必需的工具。rootfs 曾在
# 2026-11-21 22:51–23:02 间无故消失，且重建参数仓库里无记录；本次把参数
# 定在这里，重建/补装都走本脚本，不要只手动装一次。
#
# 必需工具（debootstrap --include 清单）：
#   curl、bind9-dnsutils、bind9-host（dig/host）、iproute2（ss/ip）、
#   procps、util-linux、ca-certificates——minbase 不含这些，台架必需；
#   python3——R2-09 之后 S14 的 verify_rule_domain 只认 python3 或 jq
#   解析 agent 配置（grep 兜底已删），chroot 里没有真解析器时该断言
#   return 2 跳过。用完整 python3 不用 python3-minimal：json 属标准库，
#   随 libpython3-stdlib 来，不依赖 -minimal 的裁剪清单。
# 台架 python3 stub（scripts/rig/stubs/python3）只拦截 can_bind_listen
# 的 python3 - <host> <port> 调用，其余一律转给这里装的 /usr/bin/python3。
#
# 用法：RIG_ROOTFS=/var/lib/machines/v016-test bash scripts/rig/provision-rootfs.sh
#   - rootfs 不存在或为空 → debootstrap 重建（含 python3）。
#   - rootfs 存在但缺 python3 → chroot 内 apt-get 补装。
#   - 已有 python3 → 只自检，不动。
# 幂等；跑在 test-takeover-rig.sh 的单跑锁之内（防并行 lane 同时重建）。
set -euo pipefail

ROOT="${RIG_ROOTFS:-/var/lib/machines/v016-test}"
INCLUDE="curl,bind9-dnsutils,bind9-host,iproute2,procps,util-linux,ca-certificates,python3"

if [ ! -d "$ROOT" ] || [ -z "$(ls -A "$ROOT" 2>/dev/null)" ]; then
  echo "台架 rootfs 不存在或为空，重建：$ROOT"
  command -v debootstrap >/dev/null || { echo "缺 debootstrap"; exit 1; }
  rm -rf "$ROOT"
  debootstrap --variant=minbase --include="$INCLUDE" noble "$ROOT" http://archive.ubuntu.com/ubuntu
fi

if [ ! -x "$ROOT/usr/bin/python3" ]; then
  echo "台架 rootfs 缺 python3，chroot 内 apt 补装……"
  # 沙箱出口走环境里的 http_proxy（代理主机名，形如 hatch-egress-proxy）；
  # chroot 内 /etc/resolv.conf 只有 198.19.0.1，解析不了这个宿主内部名
  # （公网 DNS 还会把它解析到错误地址）。宿主 /etc/hosts 里有该名的正确
  # 映射，先把它抄进 chroot 的 /etc/hosts（只抄代理名那几行；环境里没有
  # 代理时跳过，apt 直接走公网）。注意：这里只解析主机名，绝不打印代理 URL。
  _proxy_host="${http_proxy:-}"
  _proxy_host="${_proxy_host#*://}"; _proxy_host="${_proxy_host#*@}"
  _proxy_host="${_proxy_host%%:*}"; _proxy_host="${_proxy_host%%/*}"
  if [ -n "$_proxy_host" ] && ! grep -qwF "$_proxy_host" "$ROOT/etc/hosts" 2>/dev/null; then
    # 只抄非注释行；写完必须 chmod 644——apt 的下载进程以 _apt 身份跑，
    # 读不到 660 的 /etc/hosts 时代理名解析失败（EAI_AGAIN），实测踩过。
    grep -wF "$_proxy_host" /etc/hosts 2>/dev/null | grep -v '^[[:space:]]*#' >> "$ROOT/etc/hosts" || true
    chmod 644 "$ROOT/etc/hosts"
  fi
  unset _proxy_host
  chroot "$ROOT" apt-get update -qq
  DEBIAN_FRONTEND=noninteractive chroot "$ROOT" apt-get install -y python3
fi

# 自检：真 python3 + json 可用（verify_rule_domain 就靠它）。
chroot "$ROOT" python3 -c 'import json, socket; print("rootfs python3 + json OK")'
echo "台架 rootfs 就绪：$ROOT（$(du -sh "$ROOT" 2>/dev/null | cut -f1)）"
