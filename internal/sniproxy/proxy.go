package sniproxy

// SNI proxy: listens on :443, reads the TLS ClientHello, extracts SNI,
// dials the real origin on :443 and proxies bytes both ways. Also handles
// plain HTTP on :80 by Host header.
//
// NO-LOG GUARANTEE: SNI/host values and client addresses are never logged;
// only aggregate counters (connections, bytes) are kept.

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"net"
	"strings"
	"sync/atomic"
	"time"
)

type Config struct {
	TLSListen  string // default ":443"
	HTTPListen string // default ":80", empty disables
	// Allowlist restricts which clients may use this proxy (IPs/CIDRs).
	// The SNI proxy must only be reachable from your own DNS servers /
	// unlock clients — anyone who can reach it can relay TLS through it.
	// Empty = allow all inside this library; the deployed binary
	// (cmd/dnsunlock) refuses to start with an empty allowlist on
	// non-loopback — fail-closed (P0-04). Never rely on empty.
	Allowlist []string
	// Dial overrides the origin dial (tests only; nil = net.DialTimeout).
	Dial func(network, address string, timeout time.Duration) (net.Conn, error)
}

func (p *Proxy) dial(address string) (net.Conn, error) {
	if p.cfg.Dial != nil {
		return p.cfg.Dial("tcp", address, 10*time.Second)
	}
	return net.DialTimeout("tcp", address, 10*time.Second)
}

type Proxy struct {
	cfg   Config
	conns atomic.Int64
	bytes atomic.Int64
	// parsed allowlist (nil = allow all inside this library; the
	// deployed entry point refuses to start empty on non-loopback)
	allowNets []*net.IPNet
	allowIPs  map[string]bool
	// allowlistErr is set when the configured allowlist contains an
	// invalid entry (N-04). Run() refuses to start; allowed() denies
	// everything until then — fail closed, never open.
	allowlistErr error
}

// ValidateAllowlist checks every entry is a valid IP or CIDR (N-04).
func ValidateAllowlist(entries []string) error {
	for _, e := range entries {
		e = strings.TrimSpace(e)
		if e == "" {
			continue
		}
		if _, _, err := net.ParseCIDR(e); err == nil {
			continue
		}
		if net.ParseIP(e) != nil {
			continue
		}
		return fmt.Errorf("allowlist entry %q is not a valid IP or CIDR", e)
	}
	return nil
}

// isLoopbackListen reports whether a listen address binds loopback only
// (empty host means all interfaces, i.e. NOT loopback-only).
func isLoopbackListen(listen string) bool {
	h, _, err := net.SplitHostPort(listen)
	if err != nil {
		return false
	}
	return h == "127.0.0.1" || h == "::1" || h == "localhost"
}

func New(cfg Config) *Proxy {
	if cfg.TLSListen == "" {
		cfg.TLSListen = ":443"
	}
	p := &Proxy{cfg: cfg, allowIPs: map[string]bool{}}
	for _, e := range cfg.Allowlist {
		e = strings.TrimSpace(e)
		if e == "" {
			continue
		}
		if _, n, err := net.ParseCIDR(e); err == nil {
			p.allowNets = append(p.allowNets, n)
		} else if ip := net.ParseIP(e); ip != nil {
			p.allowIPs[ip.String()] = true
		}
	}
	// N-04: an entry that parses as neither IP nor CIDR is an error, not
	// something to drop quietly — dropping it would silently turn the
	// proxy into an open one.
	p.allowlistErr = ValidateAllowlist(cfg.Allowlist)
	if len(p.allowNets) == 0 && len(p.allowIPs) == 0 {
		fmt.Println("[sni-proxy] WARNING: no allowlist set — anyone who can reach this port can relay TLS through it. Set the allowlist in the 0600 config file to your DNS servers / own IPs.")
	}
	return p
}

func (p *Proxy) allowed(ip net.IP) bool {
	// With an invalid allowlist nothing is allowed (N-04).
	if p.allowlistErr != nil {
		return false
	}
	if len(p.allowNets) == 0 && len(p.allowIPs) == 0 {
		return true
	}
	if p.allowIPs[ip.String()] {
		return true
	}
	for _, n := range p.allowNets {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}

func (p *Proxy) Counters() (int64, int64) { return p.conns.Load(), p.bytes.Load() }

// parseSNI extracts the server name from a TLS ClientHello record.
// Input must start with a TLS record (0x16 0x03 ...). Returns "" if absent.
func parseSNI(data []byte) string {
	if len(data) < 5 || data[0] != 0x16 {
		return ""
	}
	// Record length.
	recLen := int(data[3])<<8 | int(data[4])
	if len(data) < 5+recLen {
		return ""
	}
	hello := data[5 : 5+recLen]
	if len(hello) < 4 || hello[0] != 0x01 {
		return ""
	}
	// Handshake length (3 bytes), then: version(2) random(32) sessionID(1+len)
	pos := 4
	if len(hello) < pos+2+32+1 {
		return ""
	}
	pos += 2 + 32
	sessLen := int(hello[pos])
	pos++
	pos += sessLen
	if len(hello) < pos+2 {
		return ""
	}
	csLen := int(hello[pos])<<8 | int(hello[pos+1])
	pos += 2 + csLen
	if len(hello) < pos+1 {
		return ""
	}
	compLen := int(hello[pos])
	pos += 1 + compLen
	if len(hello) < pos+2 {
		return ""
	}
	extTotal := int(hello[pos])<<8 | int(hello[pos+1])
	pos += 2
	end := pos + extTotal
	if end > len(hello) {
		end = len(hello)
	}
	for pos+4 <= end {
		extType := int(hello[pos])<<8 | int(hello[pos+1])
		extLen := int(hello[pos+2])<<8 | int(hello[pos+3])
		pos += 4
		if pos+extLen > end {
			break
		}
		if extType == 0 { // server_name
			body := hello[pos : pos+extLen]
			if len(body) < 5 {
				return ""
			}
			// list len(2) | type(1)=host_name | name len(2) | name
			nameLen := int(body[3])<<8 | int(body[4])
			if 5+nameLen <= len(body) {
				return string(body[5 : 5+nameLen])
			}
			return ""
		}
		pos += extLen
	}
	return ""
}

func (p *Proxy) handleTLS(c net.Conn) {
	defer c.Close()
	_ = c.SetReadDeadline(time.Now().Add(10 * time.Second))
	// 32K reader: a fragmented / large ClientHello must not be dropped (P2-03).
	br := bufio.NewReaderSize(c, 32768)
	// Read the 5-byte TLS record header first, then exactly one record.
	hdr, err := br.Peek(5)
	if err != nil || len(hdr) < 5 || hdr[0] != 0x16 {
		return
	}
	recLen := int(hdr[3])<<8 | int(hdr[4])
	if recLen <= 0 || recLen > 32768 {
		return
	}
	peek, err := br.Peek(5 + recLen)
	if err != nil && len(peek) < 5+recLen {
		return
	}
	sni := parseSNI(peek)
	if sni == "" {
		return
	}
	initial := make([]byte, len(peek))
	copy(initial, peek)
	_, _ = io.CopyN(io.Discard, br, int64(len(peek)))
	// Whole-connection deadline: a stalled peer must not hold a
	// connection (and a goroutine pair) forever (P2-03).
	_ = c.SetDeadline(time.Now().Add(120 * time.Second))
	target := net.JoinHostPort(sni, "443")
	combined := io.MultiReader(bytes.NewReader(initial), br)
	p.conns.Add(1)
	origin, err := p.dial(target)
	if err != nil {
		return
	}
	_ = origin.SetDeadline(time.Now().Add(120 * time.Second))
	done := make(chan struct{}, 2)
	go func() {
		n, _ := io.Copy(origin, combined)
		p.bytes.Add(n)
		done <- struct{}{}
	}()
	go func() {
		n, _ := io.Copy(c, origin)
		p.bytes.Add(n)
		done <- struct{}{}
	}()
	<-done
	origin.Close()
}

func (p *Proxy) handleHTTP(c net.Conn) {
	defer c.Close()
	_ = c.SetReadDeadline(time.Now().Add(10 * time.Second))
	br := bufio.NewReader(c)
	var head bytes.Buffer
	host := ""
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			return
		}
		head.WriteString(line)
		if strings.HasPrefix(strings.ToLower(line), "host:") {
			host = strings.TrimSpace(line[5:])
		}
		if line == "\r\n" || line == "\n" {
			break
		}
		if head.Len() > 8192 {
			return
		}
	}
	if host == "" {
		return
	}
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	if host == "" || strings.Contains(host, "/") {
		return
	}
	_ = c.SetDeadline(time.Now().Add(120 * time.Second))
	combined := io.MultiReader(bytes.NewReader(head.Bytes()), br)
	p.conns.Add(1)
	origin, err := p.dial(net.JoinHostPort(host, "80"))
	if err != nil {
		return
	}
	_ = origin.SetDeadline(time.Now().Add(120 * time.Second))
	done := make(chan struct{}, 2)
	go func() {
		n, _ := io.Copy(origin, combined)
		p.bytes.Add(n)
		done <- struct{}{}
	}()
	go func() {
		n, _ := io.Copy(c, origin)
		p.bytes.Add(n)
		done <- struct{}{}
	}()
	<-done
	origin.Close()
}

func (p *Proxy) Run() error {
	// N-04: an invalid allowlist refuses startup.
	if p.allowlistErr != nil {
		return fmt.Errorf("sni-proxy: invalid allowlist: %w", p.allowlistErr)
	}
	// N-05: fail-closed applies to BOTH listeners. The plain-HTTP listener
	// used to skip the check entirely, so a loopback-only TLS setup still
	// left an open HTTP proxy on :80. Empty allowlist + non-loopback
	// listener on either side refuses to start.
	if len(p.allowNets) == 0 && len(p.allowIPs) == 0 {
		for _, l := range []string{p.cfg.TLSListen, p.cfg.HTTPListen} {
			if l != "" && !isLoopbackListen(l) {
				return fmt.Errorf("sni-proxy: refusing to start with an empty allowlist on %s — set the allowlist to your own client IPs, or listen on 127.0.0.1 for local testing", l)
			}
		}
	}
	errCh := make(chan error, 2)
	go func() {
		ln, err := net.Listen("tcp", p.cfg.TLSListen)
		if err != nil {
			errCh <- fmt.Errorf("tls listen %s: %w", p.cfg.TLSListen, err)
			return
		}
		defer ln.Close()
		for {
			c, err := ln.Accept()
			if err != nil {
				errCh <- err
				return
			}
			if tcpAddr, ok := c.RemoteAddr().(*net.TCPAddr); ok && !p.allowed(tcpAddr.IP) {
				c.Close()
				continue
			}
			go p.handleTLS(c)
		}
	}()
	if p.cfg.HTTPListen != "" {
		go func() {
			ln, err := net.Listen("tcp", p.cfg.HTTPListen)
			if err != nil {
				// HTTP is optional: log and keep the TLS proxy running.
				fmt.Printf("[sni-proxy] http listen %s failed (TLS proxy still running): %v\n", p.cfg.HTTPListen, err)
				return
			}
			defer ln.Close()
			for {
				c, err := ln.Accept()
				if err != nil {
					fmt.Printf("[sni-proxy] http accept: %v\n", err)
					return
				}
				if tcpAddr, ok := c.RemoteAddr().(*net.TCPAddr); ok && !p.allowed(tcpAddr.IP) {
					c.Close()
					continue
				}
				go p.handleHTTP(c)
			}
		}()
	}
	return <-errCh
}
