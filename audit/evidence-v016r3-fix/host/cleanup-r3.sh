#!/bin/bash
# v0.1.6 R3 收尾：停容器、删镜像、停 scratch 面板、删凭据与工作目录、恢复 iptables、删桥、核对宿主机。
set -u
echo "== 1. 停容器 =="
machinectl poweroff v016-test 2>/dev/null || true
for i in $(seq 1 30); do machinectl show v016-test >/dev/null 2>&1 || break; sleep 1; done
if machinectl show v016-test >/dev/null 2>&1; then machinectl terminate v016-test 2>/dev/null || true; sleep 5; fi
machinectl list 2>/dev/null; echo "容器已停（上行应无机器）"
echo "== 2. 删镜像 =="
rm -rf /var/lib/machines/v016-test
ls /var/lib/machines/ 2>/dev/null; echo "镜像目录已删（上行应为空）"
echo "== 3. 停 scratch 面板 =="
pkill -f "dnsunlock-linux-amd64 panel -addr 10.0.5.1:18280" 2>/dev/null || true
sleep 2
ss -tln 2>/dev/null | grep 18280 || echo ":18280 已关"
echo "== 4. 删凭据与 R3 工作目录 =="
ls -la /root/v016-r3/ 2>/dev/null | head -20
rm -rf /root/v016-r3
ls /root/v016-r3 2>&1 | head -1
for f in /root/v016/case.env /root/v016-r2/case.env /root/v016-r2/panel.json; do [ -e "$f" ] && echo "残留凭据文件: $f" || echo "无残留: $f"; done
echo "== 5. 恢复 iptables =="
iptables-restore < /tmp/iptables-before-r3.save 2>/dev/null || echo "注意：iptables-before 恢复失败（文件随 /root/v016-r3 已删？）"
iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -c "10.0.5" || true
iptables -L INPUT -n 2>/dev/null | grep -c 18280 || true
echo "== 6. 删桥 =="
ip link set br-v016 down 2>/dev/null || true
ip link delete br-v016 type bridge 2>/dev/null || true
ip link show br-v016 2>&1 | head -1
echo "== 7. 宿主机核对 =="
sha256sum /etc/resolv.conf
echo "panel pid: $(systemctl show -p MainPID --value dnsunlock-panel 2>/dev/null) agent pid: $(systemctl show -p MainPID --value dnsunlock-agent 2>/dev/null)"
sha256sum /proc/$(systemctl show -p MainPID --value dnsunlock-panel)/exe /proc/$(systemctl show -p MainPID --value dnsunlock-agent)/exe 2>/dev/null
systemctl is-active dnsunlock-panel dnsunlock-agent 2>/dev/null
ss -tuln 2>/dev/null | grep -E ":53 |:8080" | head -5
curl -fsS --max-time 5 http://127.0.0.1:8080/install.sh -o /dev/null && echo "宿主面板 :8080 HTTP 200"
machinectl list 2>/dev/null
sysctl -n net.ipv4.ip_forward
echo "== 清理完成 =="
