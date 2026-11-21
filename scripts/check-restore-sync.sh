#!/usr/bin/env bash
# 检查双份来源一致：两份 install.sh 内嵌的还原脚本必须与
# scripts/restore-resolv.sh 字节一致，且两份 install.sh 本身字节一致。
# 漂移就失败（exit 1）。还原脚本改了就必须同步：跑 scripts/sync-restore.sh，
# 再跑本脚本验证。
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
extract_embedded() {
  # $1=install.sh 路径，输出内嵌还原脚本到 stdout
  sed -n "/^cat > \/usr\/local\/bin\/dnsunlock-restore-dns <<'RESTORE_EOF'$/,/^RESTORE_EOF$/p" "$1" | sed '1d;$d'
}
for f in scripts/install.sh internal/panel/assets/install.sh; do
  if ! extract_embedded "$f" | diff -q - scripts/restore-resolv.sh >/dev/null; then
    echo "漂移: $f 内嵌的还原脚本与 scripts/restore-resolv.sh 不一致，请跑 scripts/sync-restore.sh 同步" >&2
    fail=1
  fi
done
if ! cmp -s scripts/install.sh internal/panel/assets/install.sh; then
  echo "漂移: scripts/install.sh 与 internal/panel/assets/install.sh 不一致（两份必须 identical）" >&2
  fail=1
fi
if [ "$fail" = 1 ]; then exit 1; fi
echo "还原脚本双份来源一致（两份 install.sh 内嵌 == scripts/restore-resolv.sh，且两份 install.sh identical）"
