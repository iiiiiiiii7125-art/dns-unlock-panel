// bindhold：台架用。占住 127.0.0.53:53（UDP + TCP），模拟 systemd-resolved
// 的 stub 监听；把 PID 写进 argv[1] 的文件，收到 kill 前一直占着。
// systemctl stub 在 restart/disable resolved 时按 PID 文件杀掉它，
// 模拟 resolved 停掉 stub 后端口被释放。
package main

import (
	"fmt"
	"net"
	"os"
	"time"
)

func main() {
	pc, err := net.ListenPacket("udp", "127.0.0.53:53")
	if err != nil {
		fmt.Println("hold udp fail:", err)
		os.Exit(1)
	}
	defer pc.Close()
	l, err := net.Listen("tcp", "127.0.0.53:53")
	if err != nil {
		fmt.Println("hold tcp fail:", err)
		os.Exit(1)
	}
	defer l.Close()
	if err := os.WriteFile(os.Args[1], []byte(fmt.Sprint(os.Getpid())), 0644); err != nil {
		fmt.Println("write pid fail:", err)
		os.Exit(1)
	}
	fmt.Println("holding 127.0.0.53:53 pid", os.Getpid())
	for {
		time.Sleep(time.Hour)
	}
}
