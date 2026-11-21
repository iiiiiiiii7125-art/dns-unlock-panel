package dnsagent

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
	"time"

	"dnsunlock/internal/model"
)

// localTLSServer starts a TLS listener on 127.0.0.1:0 that completes
// handshakes (probeIP only proves TLS answers) and returns its port.
// probePort is pointed at it for the test, then restored.
func localTLSServer(t *testing.T) int {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "127.0.0.1"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage: x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert := tls.Certificate{
		Certificate: [][]byte{der},
		PrivateKey:  key,
		Leaf:        tpl,
	}
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}})
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				_ = c.(*tls.Conn).Handshake()
				c.Close()
			}()
		}
	}()
	t.Cleanup(func() { ln.Close() })
	return ln.Addr().(*net.TCPAddr).Port
}

// Full round trip: config carries selftest_request -> agent runs it in
// the background -> next heartbeat carries selftest_result (once only),
// and a repeated delivery of the same request id never re-runs it.
func TestSelftestRoundTrip(t *testing.T) {
	port := localTLSServer(t)
	oldPort := probePort
	probePort = strconv.Itoa(port)
	t.Cleanup(func() { probePort = oldPort })

	rule := model.AgentRule{
		PlatformID: "netflix", Tier: 1, Domains: []string{"www.netflix.com"},
		NodeIP: "127.0.0.1", Region: "JP",
	}
	req := model.SelftestRequest{ID: "st-test-1", RequestedAt: time.Now().UTC().Format(time.RFC3339)}
	cfg := model.AgentConfig{
		Version: 1, Upstream: "1.1.1.1", Rules: []model.AgentRule{rule},
		SelftestRequest: &req,
	}
	var hbMu sync.Mutex
	var lastHB *model.AgentHeartbeat
	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/agent/config":
			_ = json.NewEncoder(w).Encode(cfg)
		case "/api/v1/agent/heartbeat":
			var hb model.AgentHeartbeat
			_ = json.NewDecoder(r.Body).Decode(&hb)
			hbMu.Lock()
			lastHB = &hb
			hbMu.Unlock()
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer stub.Close()

	a := New(Config{PanelURL: stub.URL, Token: "t", ServerID: "srv-1"})
	if err := a.fetchConfig(); err != nil {
		t.Fatalf("fetchConfig: %v", err)
	}
	// Wait for the background run to produce a result.
	deadline := time.Now().Add(5 * time.Second)
	for {
		a.selftestMu.Lock()
		done := a.selftestResult != nil
		a.selftestMu.Unlock()
		if done || time.Now().After(deadline) {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	a.selftestMu.Lock()
	res := a.selftestResult
	runs := a.selftestRuns
	a.selftestMu.Unlock()
	if res == nil {
		t.Fatalf("no selftest result after fetchConfig (runs=%d)", runs)
	}
	if res.RequestID != "st-test-1" || len(res.Results) != 1 {
		t.Fatalf("result = %+v want request st-test-1 with 1 row", res)
	}
	row := res.Results[0]
	if row.PlatformID != "netflix" || row.Domain != "www.netflix.com" ||
		row.ResolvedIP != "127.0.0.1" || !row.OK || row.LatencyMs < 0 {
		t.Fatalf("row = %+v want netflix/www.netflix.com/127.0.0.1 ok latency>=0", row)
	}

	// Heartbeat carries the result once, then clears it.
	a.sendHeartbeat()
	hbMu.Lock()
	got := lastHB
	hbMu.Unlock()
	if got == nil || got.SelftestResult == nil || got.SelftestResult.RequestID != "st-test-1" {
		t.Fatalf("heartbeat carried %+v want selftest_result st-test-1", got)
	}
	a.sendHeartbeat()
	hbMu.Lock()
	got2 := lastHB
	hbMu.Unlock()
	if got2 == nil || got2.SelftestResult != nil {
		t.Fatalf("second heartbeat carried %+v want no selftest_result (sent once)", got2)
	}

	// Same request delivered again: never re-runs.
	if err := a.fetchConfig(); err != nil {
		t.Fatalf("second fetchConfig: %v", err)
	}
	time.Sleep(300 * time.Millisecond)
	a.selftestMu.Lock()
	runs2 := a.selftestRuns
	a.selftestMu.Unlock()
	if runs2 != 1 {
		t.Fatalf("selftest runs = %d want 1 (duplicate delivery must not re-run)", runs2)
	}
}

// A rule whose unlock IP has no TLS listener fails the row (not a crash)
// and the run still reports the other platforms.
func TestSelftestProbeFailure(t *testing.T) {
	port := localTLSServer(t)
	oldPort := probePort
	probePort = strconv.Itoa(port)
	t.Cleanup(func() { probePort = oldPort })

	a := New(Config{PanelURL: "http://127.0.0.1:8080", Token: "t", ServerID: "srv-1"})
	a.rulesMu.Lock()
	a.rules = map[string]model.AgentRule{
		"ok-plat":   {PlatformID: "ok-plat", Domains: []string{"ok.example.com"}, NodeIP: "127.0.0.1"},
		"dead-plat": {PlatformID: "dead-plat", Domains: []string{"dead.example.com"}, NodeIP: "203.0.113.99"},
	}
	a.rulesMu.Unlock()
	a.mu.Lock()
	a.rebuildDomainsLocked(a.rules)
	a.mu.Unlock()
	a.runSelftest(model.SelftestRequest{ID: "st-fail", RequestedAt: time.Now().UTC().Format(time.RFC3339)})
	a.selftestMu.Lock()
	res := a.selftestResult
	a.selftestMu.Unlock()
	if res == nil || len(res.Results) != 2 {
		t.Fatalf("result = %+v want 2 rows", res)
	}
	byID := map[string]model.SelftestResultItem{}
	for _, r := range res.Results {
		byID[r.PlatformID] = r
	}
	if !byID["ok-plat"].OK || byID["ok-plat"].ResolvedIP != "127.0.0.1" {
		t.Fatalf("ok-plat row = %+v want ok", byID["ok-plat"])
	}
	if byID["dead-plat"].OK || byID["dead-plat"].Error == "" || byID["dead-plat"].LatencyMs != -1 {
		t.Fatalf("dead-plat row = %+v want FAIL with error and latency -1", byID["dead-plat"])
	}
}
