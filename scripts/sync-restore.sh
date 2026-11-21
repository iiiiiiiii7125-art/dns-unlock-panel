#!/usr/bin/env python3
"""把 scripts/restore-resolv.sh 同步进两份 install.sh 的内嵌 heredoc。

用法: scripts/sync-restore.sh
改完还原脚本后跑它，再跑 scripts/check-restore-sync.sh 验证。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESTORE = ROOT / "scripts" / "restore-resolv.sh"
TARGETS = [
    ROOT / "scripts" / "install.sh",
    ROOT / "internal" / "panel" / "assets" / "install.sh",
]
PAT = re.compile(
    r"(cat > /usr/local/bin/dnsunlock-restore-dns <<'RESTORE_EOF'\n).*?(\nRESTORE_EOF)",
    re.S,
)


def main():
    restore = RESTORE.read_text().rstrip("\n")
    for target in TARGETS:
        s = target.read_text()
        m = PAT.search(s)
        if not m:
            print(f"找不到内嵌还原脚本标记: {target}", file=sys.stderr)
            return 1
        target.write_text(PAT.sub(lambda mm: mm.group(1) + restore + mm.group(2), s))
        print(f"已同步 {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
