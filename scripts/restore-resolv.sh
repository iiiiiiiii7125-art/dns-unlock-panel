#!/usr/bin/env bash
# 一键还原 /etc/resolv.conf（与 install.sh 内嵌版本一致；install.sh 安装时也会生成一份到 /usr/local/bin/dnsunlock-restore-dns）。
# 还原 /etc/resolv.conf 到接管前的原备份，并恢复 systemd-resolved / NetworkManager / resolvconf / dhclient / cloud-init / netplan。
# v0.1.6：结构化备份 /var/lib/dnsunlock/backup/<时间戳>_<标签>/ + metadata.txt；
# 还原默认选最早的一份（原始状态），还原前先自动备份当前状态，失败就中止；
# 还原后验证并报告“已还原并验证通过”或“已还原但验证未通过”。
# 老版本单份备份 /etc/dnsunlock/resolv.conf.orig 仍认（无备份目录时走老路）。
# 用法：dnsunlock-restore-dns [--yes] [--backup <备份目录>]
#   --yes     非交互：默认还原最早的一份，不再逐项确认（供 uninstall.sh 等脚本调用）
#   --backup  指定要还原的备份目录（须含 resolv.conf），与 --yes 合用可全程非交互
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }

BACKUP_ROOT="/var/lib/dnsunlock/backup"

ask_yes_no() {
  local ans=""
  if [ -r /dev/tty ]; then
    read -rp "$1 [y/N] " ans < /dev/tty || true
  fi
  case "$ans" in y|Y) return 0;; *) return 1;; esac
}

# 与 install.sh 的 do_backup 同款（独立脚本，自带一份）：备份当前 DNS 状态。
# stdout 只输出备份目录路径，说明打到 stderr。失败返回 1。
do_backup() {
  local label="$1" ts dir n=0 dns="" backends=""
  ts=$(date +%Y%m%d-%H%M%S)
  dir="$BACKUP_ROOT/${ts}_${label}"
  while [ -e "$dir" ]; do n=$((n+1)); dir="$BACKUP_ROOT/${ts}_${label}-$n"; done
  mkdir -p "$dir" || return 1
  cp -L /etc/resolv.conf "$dir/resolv.conf" 2>/dev/null || { rm -rf "$dir"; return 1; }
  if [ -L /etc/resolv.conf ]; then readlink /etc/resolv.conf > "$dir/resolv.conf.symlink" 2>/dev/null || true; fi
  [ -f /etc/systemd/resolved.conf ] && cp -a /etc/systemd/resolved.conf "$dir/resolved.conf" 2>/dev/null || true
  [ -d /etc/systemd/resolved.conf.d ] && cp -a /etc/systemd/resolved.conf.d "$dir/resolved.conf.d" 2>/dev/null || true
  [ -d /etc/NetworkManager/conf.d ] && cp -a /etc/NetworkManager/conf.d "$dir/NetworkManager-conf.d" 2>/dev/null || true
  if ls /etc/netplan/*.yaml >/dev/null 2>&1; then mkdir -p "$dir/netplan" && cp -a /etc/netplan/*.yaml "$dir/netplan/" 2>/dev/null || true; fi
  [ -f /etc/nsswitch.conf ] && cp -a /etc/nsswitch.conf "$dir/nsswitch.conf" 2>/dev/null || true
  [ -f /etc/dnsunlock/nm-backup.txt ] && cp -a /etc/dnsunlock/nm-backup.txt "$dir/nm-backup.txt" 2>/dev/null || true
  [ -f /etc/dhcp/dhclient.conf ] && cp -a /etc/dhcp/dhclient.conf "$dir/dhclient.conf" 2>/dev/null || true
  [ -d /etc/cloud/cloud.cfg.d ] && cp -a /etc/cloud/cloud.cfg.d "$dir/cloud.cfg.d" 2>/dev/null || true
  dns=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
  if systemctl cat systemd-resolved.service >/dev/null 2>&1; then backends="resolved"; fi
  if command -v nmcli >/dev/null 2>&1; then backends="${backends:+$backends,}nm"; fi
  if command -v resolvconf >/dev/null 2>&1; then backends="${backends:+$backends,}resolvconf"; fi
  if ls /etc/netplan/*.yaml >/dev/null 2>&1; then backends="${backends:+$backends,}netplan"; fi
  {
    echo "timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "label=$label"
    echo "dns=$dns"
    echo "backends=$backends"
    if [ -L /etc/resolv.conf ]; then echo "resolv_symlink=$(readlink /etc/resolv.conf)"; else echo "resolv_symlink="; fi
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then echo "resolved_active=yes"; else echo "resolved_active=no"; fi
    if systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then echo "resolved_enabled=yes"; else echo "resolved_enabled=no"; fi
    if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then echo "nm_active=yes"; else echo "nm_active=no"; fi
    if systemctl is-enabled --quiet NetworkManager 2>/dev/null; then echo "nm_enabled=yes"; else echo "nm_enabled=no"; fi
    if systemctl is-active --quiet resolvconf 2>/dev/null; then echo "resolvconf_active=yes"; else echo "resolvconf_active=no"; fi
    if systemctl is-enabled --quiet resolvconf 2>/dev/null; then echo "resolvconf_enabled=yes"; else echo "resolvconf_enabled=no"; fi
  } > "$dir/metadata.txt" || { rm -rf "$dir"; return 1; }
  echo "已备份当前 DNS 状态 -> $dir" >&2
  echo "$dir"
  return 0
}

meta_value() {
  sed -n "s/^$2=//p" "$1/metadata.txt" 2>/dev/null | head -1
}

# 还原后验证（getent 优先，走系统解析器；缺 getent 回退 dig；都没工具只报告）。
# 只报告结果，不决定退出码（文件已还原，验证失败只说明 DNS 可能仍有问题）。
verify_after_restore() {
  if command -v getent >/dev/null 2>&1; then
    if getent hosts example.com >/dev/null 2>&1; then echo "已还原并验证通过（getent hosts example.com 有结果）"; return 0; fi
    echo "已还原但验证未通过（getent hosts example.com 无结果，请检查 DNS 配置）" >&2
    return 0
  fi
  if command -v dig >/dev/null 2>&1; then
    if dig +short example.com A 2>/dev/null | grep -qE '^[0-9]+\.'; then echo "已还原并验证通过（dig example.com 有结果）"; return 0; fi
    echo "已还原但验证未通过（dig example.com 无结果，请检查 DNS 配置）" >&2
    return 0
  fi
  echo "已还原（无 getent/dig，验证未做，请手动验证：getent hosts example.com）"
  return 0
}

# 旧方式 NM 逐连接还原（备份里有 nm-backup.txt 时才做；v0.1.6 新方式接管不写它。
# 连接标识目前是连接名；item 7 会改成按 UUID，见 nm-backup.txt 的格式说明）。
restore_nm_legacy() {
  local file="$1"
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
  done < "$file"
}

# 按备份里记的后端重载（失败只警告，不致命；item 8 会收成 reload_dns_service 分发）。
# 只重载备份时在跑的后端：原来没跑的管理器不替用户启动。
# 注意：本函数在 resolv.conf 恢复之前跑，管理器重载时若改写 resolv.conf，
# 后面恢复 resolv.conf 的步骤会把它盖回去，所以最终内容以备份为准。
reload_backends() {
  local dir="$1" backends=""
  backends=$(meta_value "$dir" backends)
  if [ -z "$backends" ]; then
    # 无 metadata 的老备份：按老脚本的 blanket 做法全量重载（失败只警告）。
    systemctl restart systemd-resolved 2>/dev/null || true
    resolvconf -u 2>/dev/null || true
    netplan apply 2>/dev/null || true
    return 0
  fi
  case ",$backends," in
    *,resolved,*)
      if [ "$(meta_value "$dir" resolved_active)" = "yes" ]; then
        systemctl restart systemd-resolved 2>/dev/null || echo "警告: 重启 systemd-resolved 失败" >&2
      fi
      ;;
  esac
  case ",$backends," in
    *,nm,*)
      if [ "$(meta_value "$dir" nm_active)" = "yes" ] && command -v nmcli >/dev/null 2>&1; then
        nmcli general reload 2>/dev/null || echo "警告: nmcli general reload 失败" >&2
        # 重新激活活动连接（按 UUID；连接名含冒号会被截断，见 item 7）
        nmcli -t -f UUID connection show --active 2>/dev/null | while IFS= read -r uuid; do
          [ -n "$uuid" ] || continue
          nmcli connection up "$uuid" 2>/dev/null || echo "警告: 重新激活 NM 连接 $uuid 失败" >&2
        done
      fi
      ;;
  esac
  case ",$backends," in
    *,netplan,*) netplan apply 2>/dev/null || echo "警告: netplan apply 失败" >&2;;
  esac
  case ",$backends," in
    *,resolvconf,*)
      if [ "$(meta_value "$dir" resolvconf_active)" = "yes" ]; then
        resolvconf -u 2>/dev/null || echo "警告: resolvconf -u 失败" >&2
      fi
      ;;
  esac
}

# 从结构化备份目录还原。顺序：先恢复各后端文件 → 重新启用之前开着的管理器 →
# 按后端重载 → 最后恢复 resolv.conf（保证没有任何管理器在之后再改写它）。
restore_from_dir() {
  local dir="$1" link="" target=""
  echo "从备份还原: $dir（$(meta_value "$dir" label)，$(meta_value "$dir" timestamp)）"
  chattr -i /etc/resolv.conf 2>/dev/null || true
  # 1. 删本次接管写的 NM dns=none 配置（备份里若有同名文件，下面会按备份恢复）。
  rm -f /etc/NetworkManager/conf.d/dnsunlock.conf
  # 2. 恢复各后端文件（只恢复备份里有的）。
  if [ -f "$dir/resolved.conf" ]; then cp -a "$dir/resolved.conf" /etc/systemd/resolved.conf 2>/dev/null || echo "警告: 恢复 /etc/systemd/resolved.conf 失败" >&2; fi
  if [ -d "$dir/resolved.conf.d" ]; then
    rm -f /etc/systemd/resolved.conf.d/dnsunlock.conf
    cp -a "$dir/resolved.conf.d/." /etc/systemd/resolved.conf.d/ 2>/dev/null || echo "警告: 恢复 resolved.conf.d 失败" >&2
  else
    rm -f /etc/systemd/resolved.conf.d/dnsunlock.conf
  fi
  if [ -d "$dir/NetworkManager-conf.d" ]; then
    cp -a "$dir/NetworkManager-conf.d/." /etc/NetworkManager/conf.d/ 2>/dev/null || echo "警告: 恢复 NetworkManager conf.d 失败" >&2
  fi
  if [ -f "$dir/nsswitch.conf" ]; then cp -a "$dir/nsswitch.conf" /etc/nsswitch.conf 2>/dev/null || echo "警告: 恢复 nsswitch.conf 失败" >&2; fi
  if [ -d "$dir/netplan" ]; then
    for f in "$dir/netplan"/*.yaml; do [ -e "$f" ] || continue; cp -a "$f" "/etc/netplan/$(basename "$f")" 2>/dev/null || echo "警告: 恢复 netplan $(basename "$f") 失败" >&2; done
  fi
  if [ -f "$dir/dhclient.conf" ]; then cp -a "$dir/dhclient.conf" /etc/dhcp/dhclient.conf 2>/dev/null || echo "警告: 恢复 dhclient.conf 失败" >&2; fi
  if [ -d "$dir/cloud.cfg.d" ]; then
    rm -f /etc/cloud/cloud.cfg.d/99-dnsunlock.cfg
    cp -a "$dir/cloud.cfg.d/." /etc/cloud/cloud.cfg.d/ 2>/dev/null || echo "警告: 恢复 cloud.cfg.d 失败" >&2
  else
    rm -f /etc/cloud/cloud.cfg.d/99-dnsunlock.cfg
  fi
  rm -f /etc/resolvconf/resolv.conf.d/head.dnsunlock
  # 3. 旧方式 NM 逐连接还原（备份里有 nm-backup.txt 时才做）。
  if [ -f "$dir/nm-backup.txt" ]; then restore_nm_legacy "$dir/nm-backup.txt"; fi
  # 4. 重新启用之前开着的管理器（按备份 metadata）。
  if [ "$(meta_value "$dir" resolved_enabled)" = "yes" ]; then
    systemctl enable --now systemd-resolved 2>/dev/null || echo "警告: 重新启用 systemd-resolved 失败" >&2
  fi
  if [ "$(meta_value "$dir" resolvconf_enabled)" = "yes" ]; then
    systemctl enable --now resolvconf 2>/dev/null || echo "警告: 重新启用 resolvconf 失败" >&2
  fi
  # 5. 按后端重载。
  reload_backends "$dir"
  # 6. 最后恢复 resolv.conf（原先是符号链接就先恢复链接）。
  rm -f /etc/resolv.conf
  if [ -f "$dir/resolv.conf.symlink" ]; then
    link=$(cat "$dir/resolv.conf.symlink")
    ln -s "$link" /etc/resolv.conf
    # P1-09：原 resolv.conf 是软链时，只恢复软链不够——若目标文件已被删，
    # 软链就指向空洞。目标不存在时，把备份的内容写回目标文件。
    case "$link" in /*) target="$link" ;; *) target="/etc/$link" ;; esac
    if [ ! -e "$target" ]; then
      cp -L "$dir/resolv.conf" "$target" 2>/dev/null || echo "注意: 软链目标 $target 已不存在且写回失败，请手动恢复" >&2
      echo "已还原软链 /etc/resolv.conf -> $link，并把备份内容写回目标 $target"
    else
      echo "已还原软链 /etc/resolv.conf -> $link（目标文件仍在，内容以目标为准）"
    fi
  else
    cp -L "$dir/resolv.conf" /etc/resolv.conf
    echo "已还原 /etc/resolv.conf <- $dir/resolv.conf"
  fi
}

# 老路：无结构化备份目录，只有单份 /etc/dnsunlock/resolv.conf.orig（老版本接管）。
restore_legacy() {
  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/systemd/resolved.conf.d/dnsunlock.conf
  systemctl restart systemd-resolved 2>/dev/null || true
  if [ -f /etc/dnsunlock/nm-backup.txt ]; then
    restore_nm_legacy /etc/dnsunlock/nm-backup.txt
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
}

# ---- 参数 ----
YES=0
WANT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift;;
    --backup) WANT_DIR="$2"; shift 2;;
    --help|-h)
      echo "用法: dnsunlock-restore-dns [--yes] [--backup <备份目录>]"
      echo "  --yes     非交互：默认还原最早的一份（原始状态），不再逐项确认"
      echo "  --backup  指定要还原的备份目录（须含 resolv.conf）"
      exit 0;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

# ---- 选备份 ----
CHOSEN=""
if [ -n "$WANT_DIR" ]; then
  [ -d "$WANT_DIR" ] && [ -f "$WANT_DIR/resolv.conf" ] || { echo "备份目录不存在或不完整: $WANT_DIR"; exit 1; }
  CHOSEN="$WANT_DIR"
elif ls -d "$BACKUP_ROOT"/*/ >/dev/null 2>&1; then
  DIRS=()
  for d in "$BACKUP_ROOT"/*/; do [ -d "$d" ] || continue; DIRS+=("${d%/}"); done
  COUNT=${#DIRS[@]}
  echo "可用的备份（时间倒序）："
  i=$COUNT
  while [ "$i" -ge 1 ]; do
    d="${DIRS[$((i-1))]}"
    n=$((COUNT - i + 1))
    echo "  [$n] $(meta_value "$d" timestamp)  $(meta_value "$d" label)  DNS: $(meta_value "$d" dns)  $d"
    i=$((i-1))
  done
  if [ "$YES" = 1 ]; then
    CHOSEN="${DIRS[0]}"
    echo "非交互模式：默认还原最早的一份（原始状态）: $CHOSEN"
  else
    if [ ! -r /dev/tty ] && [ ! -t 0 ]; then
      echo "没有可交互的终端来选备份：请加 --yes（默认还原最早的一份）或 --backup <备份目录> --yes"
      exit 1
    fi
    SEL=""
    if [ -r /dev/tty ]; then read -rp "选编号 [默认 $COUNT=最早的一份，即原始状态]: " SEL < /dev/tty || true
    else read -rp "选编号 [默认 $COUNT=最早的一份，即原始状态]: " SEL || true; fi
    [ -z "$SEL" ] && SEL=$COUNT
    case "$SEL" in ''|*[!0-9]*) echo "编号不对: $SEL"; exit 1;; esac
    [ "$SEL" -ge 1 ] && [ "$SEL" -le "$COUNT" ] || { echo "编号超出范围: $SEL"; exit 1; }
    CHOSEN="${DIRS[$((COUNT - SEL))]}"
    echo "已选: $CHOSEN（$(meta_value "$CHOSEN" label)，$(meta_value "$CHOSEN" timestamp)）"
  fi
fi

if [ -n "$CHOSEN" ]; then
  # 确认（--yes 跳过）。
  if [ "$YES" != 1 ]; then
    ask_yes_no "确认还原到 $CHOSEN 吗？还原前会自动备份当前状态。" || { echo "已取消还原"; exit 0; }
  fi
  # 还原前先自动备份当前状态，备份失败就中止。
  PRE_DIR=$(do_backup "pre-restore") || { echo "还原前自动备份当前状态失败，已中止还原（未改任何文件）"; exit 1; }
  echo "还原前已自动备份当前状态 -> $PRE_DIR"
  restore_from_dir "$CHOSEN"
  verify_after_restore
  exit 0
fi

# 无结构化备份：走老路（单份 .orig）或提示无需还原。
if [ -e /etc/dnsunlock/resolv.conf.orig ]; then
  echo "未找到结构化备份，走老路还原单份备份 /etc/dnsunlock/resolv.conf.orig"
  if [ "$YES" != 1 ]; then
    ask_yes_no "确认还原到 /etc/dnsunlock/resolv.conf.orig 吗？还原前会自动备份当前状态。" || { echo "已取消还原"; exit 0; }
  fi
  PRE_DIR=$(do_backup "pre-restore") || { echo "还原前自动备份当前状态失败，已中止还原（未改任何文件）"; exit 1; }
  echo "还原前已自动备份当前状态 -> $PRE_DIR"
  restore_legacy
  verify_after_restore
  exit 0
fi
echo "没有找到原备份 /etc/dnsunlock/resolv.conf.orig，无需还原"
exit 0
