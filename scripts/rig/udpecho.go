// UDP 回环收发自测：server 绑 127.0.0.1:PORT 收一个包回 PONG，client 发 HELLO 等回包。
package main

import (
	"fmt"
	"net"
	"os"
	"time"
)

func main() {
	mode := os.Args[1]
	port := os.Args[2]
	if mode == "server" {
		pc, err := net.ListenPacket("udp", "127.0.0.1:"+port)
		if err != nil {
			fmt.Println("server listen fail:", err)
			os.Exit(1)
		}
		defer pc.Close()
		fmt.Println("server listening 127.0.0.1:" + port)
		buf := make([]byte, 4096)
		_ = pc.SetReadDeadline(time.Now().Add(8 * time.Second))
		n, addr, err := pc.ReadFrom(buf)
		if err != nil {
			fmt.Println("server TIMEOUT/ERR: no UDP packet arrived:", err)
			os.Exit(2)
		}
		fmt.Printf("server got %d bytes from %s, replying\n", n, addr)
		_, _ = pc.WriteTo([]byte("PONG"), addr)
		time.Sleep(500 * time.Millisecond)
	} else {
		c, err := net.Dial("udp", "127.0.0.1:"+port)
		if err != nil {
			fmt.Println("client dial fail:", err)
			os.Exit(1)
		}
		defer c.Close()
		_, _ = c.Write([]byte("HELLO"))
		_ = c.SetReadDeadline(time.Now().Add(8 * time.Second))
		buf := make([]byte, 4096)
		n, err := c.Read(buf)
		if err != nil {
			fmt.Println("client TIMEOUT/ERR: no reply:", err)
			os.Exit(2)
		}
		fmt.Printf("client got reply: %q\n", buf[:n])
	}
}
