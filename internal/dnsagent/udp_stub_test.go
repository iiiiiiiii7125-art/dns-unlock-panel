package dnsagent

import (
	"bytes"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"

	"dnsunlock/internal/model"
)

// TestPktinfoOOBRoundTrip (P1, v0.1.6): the ancillary data built by
// replyOOB must parse back to the same destination address through
// dstFromOOB, for both socket families. Pure encode/decode, no network:
// the live reply-source check (query 127.0.0.53, read the reply's source)
// cannot run in the sandbox (loopback UDP replies are dropped there);
// it is covered by the test-machine nspawn container instead.
func TestPktinfoOOBRoundTrip(t *testing.T) {
	// IPv6 / dual-stack socket: destination ::ffff:127.0.0.53.
	p6 := &udpPktinfo{v6: true, active: true}
	dst6 := net.ParseIP("::ffff:127.0.0.53")
	got6 := p6.dstFromOOB(p6.replyOOB(dst6))
	if got6 == nil || !got6.Equal(dst6) {
		t.Fatalf("v6 round-trip: got %v, want %v", got6, dst6)
	}
	// Plain IPv6 destination.
	dst6b := net.ParseIP("2001:db8::1")
	got6b := p6.dstFromOOB(p6.replyOOB(dst6b))
	if got6b == nil || !got6b.Equal(dst6b) {
		t.Fatalf("v6 round-trip: got %v, want %v", got6b, dst6b)
	}
	// IPv4 socket.
	p4 := &udpPktinfo{v6: false, active: true}
	dst4 := net.ParseIP("127.0.0.53")
	got4 := p4.dstFromOOB(p4.replyOOB(dst4))
	if got4 == nil || !got4.Equal(dst4) {
		t.Fatalf("v4 round-trip: got %v, want %v", got4, dst4)
	}
	// Inactive pktinfo never yields a destination.
	pOff := &udpPktinfo{v6: true, active: false}
	if got := pOff.dstFromOOB(p6.replyOOB(dst6)); got != nil {
		t.Fatalf("inactive pktinfo dstFromOOB: got %v, want nil", got)
	}
	if got := pOff.replyOOB(dst6); got != nil {
		t.Fatalf("inactive pktinfo replyOOB: got %v, want nil", got)
	}
}

// TestServeUDPStarts (P1, v0.1.6): serveUDP with pktinfo enabled must
// start and hold :53. Needs root (privileged port); skip if :53 is busy.
// The socket stays bound until the test process exits; no other test in
// this package binds :53.
// TestPktinfoFamilyFromSocket (V016-11): the pktinfo family must come
// from the socket itself, not the listen-address string. On a host with
// IPv6 disabled, ListenUDP(":53") builds an AF_INET socket while the
// resolved listen address still has a nil IP; judging by the address
// tries IPV6_RECVPKTINFO on it, gets ENOPROTOOPT and silently falls
// back to plain (wrong-source) replies. The (AF_INET socket, ":53"
// address) pair below is exactly what serveUDP passes on such a host.
func TestPktinfoFamilyFromSocket(t *testing.T) {
	// Case 1: AF_INET socket + wildcard address -> IPv4 pktinfo, active.
	c4, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatalf("listen 127.0.0.1: %v", err)
	}
	defer c4.Close()
	wildcard, err := net.ResolveUDPAddr("udp", ":53")
	if err != nil {
		t.Fatalf("resolve :53: %v", err)
	}
	p4 := newUDPPktinfo(c4, wildcard)
	if !p4.active {
		t.Fatalf("AF_INET socket + wildcard addr: pktinfo inactive (V016-11: fell back to plain replies)")
	}
	if p4.v6 {
		t.Fatalf("AF_INET socket + wildcard addr: v6=true, want false")
	}
	// Case 2: wildcard socket -> IPv6 (dual-stack) pktinfo, active.
	c6, err := net.ListenUDP("udp", &net.UDPAddr{})
	if err != nil {
		t.Fatalf("listen :0: %v", err)
	}
	defer c6.Close()
	p6 := newUDPPktinfo(c6, wildcard)
	if !p6.active {
		t.Fatalf("wildcard socket: pktinfo inactive")
	}
	if !p6.v6 {
		t.Fatalf("wildcard socket: v6=false, want true")
	}
	// Case 3: explicit IPv6 socket -> IPv6 pktinfo, active.
	c6b, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("::1")})
	if err != nil {
		t.Skipf("no IPv6 loopback: %v", err)
	}
	defer c6b.Close()
	v6addr, err := net.ResolveUDPAddr("udp", "[::1]:53")
	if err != nil {
		t.Fatalf("resolve [::1]:53: %v", err)
	}
	p6b := newUDPPktinfo(c6b, v6addr)
	if !p6b.active || !p6b.v6 {
		t.Fatalf("IPv6 socket: active=%v v6=%v, want active=true v6=true", p6b.active, p6b.v6)
	}
}

// TestPktinfoSyscallConnFailureLogs (V016-25): when SyscallConn()
// fails, newUDPPktinfo must log it like the setsockopt branch does,
// instead of silently returning an inactive pktinfo. A zero-value
// UDPConn makes SyscallConn fail deterministically (EINVAL).
func TestPktinfoSyscallConnFailureLogs(t *testing.T) {
	var buf bytes.Buffer
	old := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(old)
	p := newUDPPktinfo(&net.UDPConn{}, nil)
	if p.active {
		t.Fatalf("zero-value conn: pktinfo active=true, want false")
	}
	if !bytes.Contains(buf.Bytes(), []byte("SyscallConn")) {
		t.Fatalf("no SyscallConn log line; log output = %q", buf.String())
	}
}

// TestPktinfoClosedConnInactive (V016-26): a socket whose raw control
// fails (here: already closed) must yield an INACTIVE pktinfo, never a
// false active=true with no setsockopt applied. The old code discarded
// the raw.Control error, so setErr stayed nil and the conn looked
// pktinfo-enabled while the kernel never got the option.
func TestPktinfoClosedConnInactive(t *testing.T) {
	c, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	c.Close()
	var buf bytes.Buffer
	old := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(old)
	addr, _ := net.ResolveUDPAddr("udp", "127.0.0.1:53")
	p := newUDPPktinfo(c, addr)
	if p.active {
		t.Fatalf("closed conn: pktinfo active=true, want false (Control error must not be ignored)")
	}
	if buf.Len() == 0 {
		t.Fatalf("closed conn: no log line for the failed pktinfo setup")
	}
}

// TestPktinfoSetsockoptFailureLogged (V016-26): the first setsockopt
// attempt failing (IPv6 option on an IPv4 socket) must be visible in
// the log — the fallback to IP_PKTINFO is a real branch, not a silent
// one — and the socket must still end up active on IPv4 pktinfo.
func TestPktinfoSetsockoptFailureLogged(t *testing.T) {
	c, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer c.Close()
	var buf bytes.Buffer
	old := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(old)
	addr, _ := net.ResolveUDPAddr("udp", "127.0.0.1:53")
	p := newUDPPktinfo(c, addr)
	if !p.active || p.v6 {
		t.Fatalf("IPv4 socket: active=%v v6=%v, want active=true v6=false", p.active, p.v6)
	}
	if !strings.Contains(buf.String(), "IPV6_RECVPKTINFO") || !strings.Contains(buf.String(), "IP_PKTINFO") {
		t.Fatalf("fallback not logged; log output = %q", buf.String())
	}
}

// udpSendBlocked reports whether this environment blocks UDP sends
// (the sandbox returns EPERM on sendto). The live reply-source test
// below can only assert the reply's source where sends work; where
// they are blocked it still asserts everything up to the send.
func udpSendBlocked() bool {
	c, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		return true
	}
	defer c.Close()
	_, err = c.WriteToUDP([]byte("x"), &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 9})
	return err != nil
}

// TestPktinfoLiveKernelOOB (V016-26): NOT a self-consistent round trip.
// The ancillary data here comes from the kernel (a real packet sent to
// 127.0.0.2 on a wildcard socket), not from replyOOB — dstFromOOB must
// read the kernel's destination back. The reply's ancillary data is
// then handed to the kernel: a malformed cmsg would fail EINVAL, while
// the sandbox's send policy fails EPERM, so any error other than EPERM
// (or success) is a failure.
func TestPktinfoLiveKernelOOB(t *testing.T) {
	srv, err := net.ListenUDP("udp", &net.UDPAddr{})
	if err != nil {
		t.Fatalf("listen wildcard: %v", err)
	}
	defer srv.Close()
	wildcard, _ := net.ResolveUDPAddr("udp", ":53")
	pkt := newUDPPktinfo(srv, wildcard)
	if !pkt.active || !pkt.v6 {
		t.Fatalf("wildcard socket: active=%v v6=%v, want active=true v6=true", pkt.active, pkt.v6)
	}
	port := srv.LocalAddr().(*net.UDPAddr).Port
	cli, err := net.DialUDP("udp", nil, &net.UDPAddr{IP: net.ParseIP("127.0.0.2"), Port: port})
	if err != nil {
		t.Fatalf("dial 127.0.0.2: %v", err)
	}
	defer cli.Close()
	q0, _, err := buildQuery("example.com")
	if err != nil {
		t.Fatalf("buildQuery: %v", err)
	}
	if _, err := cli.Write(q0); err != nil {
		t.Fatalf("client write: %v", err)
	}
	_ = srv.SetReadDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 8192)
	oob := make([]byte, 64)
	n, oobn, _, remote, err := srv.ReadMsgUDP(buf, oob)
	if err != nil {
		t.Fatalf("server read: %v", err)
	}
	if n == 0 {
		t.Fatalf("server read 0 bytes")
	}
	dst := pkt.dstFromOOB(oob[:oobn])
	if dst == nil || dst.To4() == nil || !dst.To4().Equal(net.ParseIP("127.0.0.2")) {
		t.Fatalf("dstFromOOB(kernel oob) = %v, want 127.0.0.2", dst)
	}
	_, _, werr := srv.WriteMsgUDP([]byte("pong"), pkt.replyOOB(dst), remote)
	if werr != nil && !errors.Is(werr, syscall.EPERM) {
		t.Fatalf("WriteMsgUDP with pktinfo oob: %v (want nil, or EPERM where the sandbox blocks UDP sends)", werr)
	}
	if werr == nil {
		// The reply got out: the client must see it from 127.0.0.2.
		_ = cli.SetReadDeadline(time.Now().Add(5 * time.Second))
		rbuf := make([]byte, 100)
		_, _, _, src, rerr := cli.ReadMsgUDP(rbuf, nil)
		if rerr != nil {
			t.Fatalf("client read: %v", rerr)
		}
		if src == nil || src.IP == nil || !src.IP.Equal(net.ParseIP("127.0.0.2")) {
			t.Fatalf("reply source = %v, want 127.0.0.2", src)
		}
	}
}

// TestServeUDPLiveReplySource (V016-26): a real agent answering a real
// query. The query must be handled (total counter moves) and, where the
// environment allows UDP replies, the reply must come from the address
// queried (127.0.0.2, not the socket's default 127.0.0.1) with the
// rewritten answer — the exact P1(b) behaviour, live.
func TestServeUDPLiveReplySource(t *testing.T) {
	// Ephemeral port (retried): a fixed port flakes when a previous
	// test binary's socket is still draining.
	var a *Agent
	var port int
	for attempt := 0; attempt < 5; attempt++ {
		p, err := freeUDPPort()
		if err != nil {
			t.Fatalf("free port: %v", err)
		}
		a = New(Config{Listen: fmt.Sprintf(":%d", p), Allowlist: []string{"127.0.0.1"}})
		a.rulesMu.Lock()
		a.rules = map[string]model.AgentRule{
			"tiktok": {PlatformID: "tiktok", Domains: []string{"tiktok.com"}, NodeIP: "203.0.113.99"},
		}
		a.rulesMu.Unlock()
		a.mu.Lock()
		a.rebuildDomainsLocked(a.rules)
		a.mu.Unlock()
		go func() { _ = a.serveUDP() }()
		deadline := time.Now().Add(2 * time.Second)
		bound := false
		for {
			if udpBound(fmt.Sprintf("127.0.0.1:%d", p)) {
				bound = true
				break
			}
			if time.Now().After(deadline) {
				break
			}
			time.Sleep(50 * time.Millisecond)
		}
		if bound {
			port = p
			break
		}
	}
	if port == 0 {
		t.Fatal("agent did not bind any ephemeral port")
	}
	cli, err := net.DialUDP("udp", nil, &net.UDPAddr{IP: net.ParseIP("127.0.0.2"), Port: port})
	if err != nil {
		t.Fatalf("dial 127.0.0.2:%d: %v", port, err)
	}
	defer cli.Close()
	q, qid, err := buildQuery("tiktok.com")
	if err != nil {
		t.Fatalf("buildQuery: %v", err)
	}
	if _, err := cli.Write(q); err != nil {
		t.Fatalf("client write: %v", err)
	}
	// The agent must have handled the query (total counter moves).
	handled := time.Now().Add(5 * time.Second)
	for a.total.Load() == 0 {
		if time.Now().After(handled) {
			t.Fatal("agent never handled the query (total stayed 0)")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if udpSendBlocked() {
		t.Skip("environment blocks UDP sends (EPERM); query handling proven via total counter, reply source needs a real machine")
	}
	_ = cli.SetReadDeadline(time.Now().Add(5 * time.Second))
	rbuf := make([]byte, 8192)
	n, _, _, src, err := cli.ReadMsgUDP(rbuf, nil)
	if err != nil {
		t.Fatalf("client read: %v", err)
	}
	if src == nil || src.IP == nil || !src.IP.Equal(net.ParseIP("127.0.0.2")) {
		t.Fatalf("reply source = %v, want 127.0.0.2 (pktinfo must force the queried address)", src)
	}
	ip, err := parseAnswerA(rbuf[:n], qid)
	if err != nil {
		t.Fatalf("parse reply: %v", err)
	}
	if !ip.Equal(net.ParseIP("203.0.113.99")) {
		t.Fatalf("reply answer = %v, want 203.0.113.99", ip)
	}
}

func TestServeUDPStarts(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("needs root to bind :53")
	}
	if udpBound(":53") {
		t.Skip(":53 already held")
	}
	a := New(Config{Listen: ":53", Allowlist: []string{"127.0.0.1"}})
	go func() { _ = a.serveUDP() }()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if udpBound("127.0.0.1:53") {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("agent did not bind :53")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// freeUDPPort returns an unused ephemeral UDP port (best effort: the
// caller re-binds it immediately; on collision the caller retries).
func freeUDPPort() (int, error) {
	c, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		return 0, err
	}
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).Port, nil
}

// udpBound reports whether addr is already held (a fresh bind fails).
func udpBound(addr string) bool {
	ua, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return false
	}
	c, err := net.ListenUDP("udp", ua)
	if err != nil {
		return true
	}
	c.Close()
	return false
}
