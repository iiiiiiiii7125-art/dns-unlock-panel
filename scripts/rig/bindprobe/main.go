// bindprobe：台架用。按 install.sh 里 can_bind_listen 的 python3 探测逻辑，
// 对 <host> <port> 各做一次真 bind（UDP + TCP，SO_REUSEADDR），都通返回 0，
// 否则返回 1。chroot 里没有 python3，python3 stub 调这个。
package main

import (
	"fmt"
	"net"
	"os"
)

func main() {
	addr := net.JoinHostPort(os.Args[1], os.Args[2])
	pc, err := net.ListenPacket("udp", addr)
	if err != nil {
		fmt.Println("bind fail:", err)
		os.Exit(1)
	}
	pc.Close()
	l, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Println("bind fail:", err)
		os.Exit(1)
	}
	l.Close()
}
