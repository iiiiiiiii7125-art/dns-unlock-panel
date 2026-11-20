#!/usr/bin/env bash
# 一键还原 /etc/resolv.conf（与 install.sh 内嵌版本一致；install.sh 安装时也会生成一份到 /usr/local/bin/dnsunlock-restore-dns）。
# 只认单份原备份 /etc/dnsunlock/resolv.conf.orig，还原失败不删备份。
#!/usr/bin/env bash
# 还原 /etc/resolv.conf 到接管前的原备份，并恢复 systemd-resolved / NetworkManager / resolvconf / dhclient / cloud-init / netplan。
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
[ -e /etc/dnsunlock/resolv.conf.orig ] || { echo "没有找到原备份 /etc/dnsunlock/resolv.conf.orig，无需还原"; exit 0; }
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/systemd/resolved.conf.d/dnsunlock.conf
systemctl restart systemd-resolved 2>/dev/null || true
if [ -f /etc/dnsunlock/nm-backup.txt ]; then
  while IFS='|' read -r CON OLD4 OLD6; do
    [ -z "$CON" ] && continue
    if command -v nmcli >/dev/null 2>&1; then
      # P1-09：原值为空 = 当时没手动设 DNS，显式传空值清空；失败要报错，
      # 不能用 || true 静默吞掉（原值记在 nm-backup.txt 里，见报错信息）。
      if ! nmcli connection modify "$CON" ipv4.dns "${OLD4:-}" ipv4.ignore-auto-dns no ipv6.dns "${OLD6:-}" ipv6.ignore-auto-dns no 2>/dev/null; then
        echo "NetworkManager: 还原 $CON 的 DNS 失败，请手动检查（原值 IPv4='$OLD4' IPv6='$OLD6'）" >&2
      fi
      nmcli connection up "$CON" 2>/dev/null || echo "NetworkManager: 重新启用 $CON 失败" >&2
    fi
  done < /etc/dnsunlock/nm-backup.txt
fi
rm -f /etc/resolvconf/resolv.conf.d/head.dnsunlock
resolvconf -u 2>/dev/null || true
if [ -f /etc/dnsunlock/dhclient.conf.bak ]; then cp -a /etc/dnsunlock/dhclient.conf.bak /etc/dhcp/dhclient.conf; fi
rm -f /etc/cloud/cloud.cfg.d/99-dnsunlock.cfg
for f in /etc/dnsunlock/*.yaml.bak; do [ -e "$f" ] || continue; cp -a "$f" "/etc/netplan/$(basename "$f" .bak)"; done
netplan apply 2>/dev/null || true
rm -f /etc/resolv.conf
if [ -f /etc/dnsunlock/resolv.conf.orig.link ]; then
  LINK=$(cat /etc/dnsunlock/resolv.conf.orig.link)
  ln -s "$LINK" /etc/resolv.conf
  # P1-09：原 resolv.conf 是软链时，只恢复软链不够——若目标文件已被删，
  # 软链就指向空洞。目标不存在时，把备份的内容写回目标文件。
  case "$LINK" in /*) TARGET="$LINK" ;; *) TARGET="/etc/$LINK" ;; esac
  if [ ! -e "$TARGET" ]; then
    cp -L /etc/dnsunlock/resolv.conf.orig "$TARGET" 2>/dev/null || echo "注意: 软链目标 $TARGET 已不存在且写回失败，请手动恢复" >&2
    echo "已还原软链 /etc/resolv.conf -> $LINK，并把备份内容写回目标 $TARGET"
  else
    echo "已还原软链 /etc/resolv.conf -> $LINK（目标文件仍在，内容以目标为准）"
  fi
else
  cp -L /etc/dnsunlock/resolv.conf.orig /etc/resolv.conf
fi
echo "已还原 /etc/resolv.conf <- /etc/dnsunlock/resolv.conf.orig"
