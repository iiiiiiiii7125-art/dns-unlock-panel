package dnsagent

import (
	"net"
	"os"
	"testing"
	"time"
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
