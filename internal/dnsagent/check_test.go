package dnsagent

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"dnsunlock/internal/model"
)

// TestBuildQueryRandomIDAndLabelChecks (V016-31): the hand-written DNS
// client must use a random query ID (never the fixed 0x1234), and must
// refuse labels over 63 bytes instead of wrapping their length byte.
func TestBuildQueryRandomIDAndLabelChecks(t *testing.T) {
	q1, id1, err := buildQuery("www.netflix.com")
	if err != nil {
		t.Fatalf("buildQuery: %v", err)
	}
	if len(q1) < 12 || q1[0] != byte(id1>>8) || q1[1] != byte(id1) {
		t.Fatalf("query ID bytes %v do not match returned id 0x%04x", q1[:2], id1)
	}
	if id1 == 0x1234 {
		t.Fatalf("query ID is the fixed 0x1234")
	}
	seen := map[uint16]bool{id1: true}
	for i := 0; i < 16; i++ {
		_, id, err := buildQuery("www.netflix.com")
		if err != nil {
			t.Fatalf("buildQuery: %v", err)
		}
		if seen[id] {
			t.Fatalf("duplicate query ID 0x%04x in 17 builds (IDs must be random)", id)
		}
		seen[id] = true
	}
	long := strings.Repeat("a", 64) + ".example.com"
	if _, _, err := buildQuery(long); err == nil {
		t.Fatalf("buildQuery(64-byte label) = no error, want label-too-long error")
	}
	huge := strings.Repeat("a", 63) + "." + strings.Repeat("b", 63) + "." + strings.Repeat("c", 63) + "." + strings.Repeat("d", 63) + ".com"
	if _, _, err := buildQuery(huge); err == nil {
		t.Fatalf("buildQuery(%d-byte domain) = no error, want domain-too-long error", len(huge))
	}
}

// TestParseAnswerAValidatesIDAndRcode (V016-31): a response with the
// wrong transaction ID or a non-zero RCODE must be rejected, not
// silently accepted as an answer.
func TestParseAnswerAValidatesIDAndRcode(t *testing.T) {
	q, id, err := buildQuery("www.netflix.com")
	if err != nil {
		t.Fatalf("buildQuery: %v", err)
	}
	qq, ok := parseQuestion(q)
	if !ok {
		t.Fatalf("parseQuestion of own query failed")
	}
	resp := buildResponse(q, qq, net.ParseIP("203.0.113.20"))
	if ip, err := parseAnswerA(resp, id); err != nil || !ip.Equal(net.ParseIP("203.0.113.20")) {
		t.Fatalf("parseAnswerA(matching ID) = %v, %v want 203.0.113.20, nil", ip, err)
	}
	wrongID := append([]byte(nil), resp...)
	wrongID[0] ^= 0xff
	if _, err := parseAnswerA(wrongID, id); err == nil {
		t.Fatalf("parseAnswerA(wrong ID) = no error, want ID mismatch error")
	}
	servfail := append([]byte(nil), resp...)
	servfail[3] |= 0x02 // RCODE=SERVFAIL
	if _, err := parseAnswerA(servfail, id); err == nil {
		t.Fatalf("parseAnswerA(RCODE=SERVFAIL) = no error, want RCODE error")
	}
	nxdomain := append([]byte(nil), resp...)
	nxdomain[3] |= 0x03 // RCODE=NXDOMAIN
	if _, err := parseAnswerA(nxdomain, id); err == nil {
		t.Fatalf("parseAnswerA(RCODE=NXDOMAIN) = no error, want RCODE error")
	}
}

func TestCheckLineFormat(t *testing.T) {
	ok := CheckResult{PlatformID: "netflix", Domain: "www.netflix.com", ResolvedIP: "203.0.113.20", OK: true, LatencyMs: 12}
	if got := ok.Line(); got != "netflix\twww.netflix.com\t203.0.113.20\tOK\t12" {
		t.Fatalf("OK line = %q", got)
	}
	fail := CheckResult{PlatformID: "tiktok", Domain: "www.tiktok.com", ResolvedIP: "203.0.113.30", OK: false, LatencyMs: -1, Err: "TCP :443 / TLS handshake failed"}
	if got := fail.Line(); got != "tiktok\twww.tiktok.com\t203.0.113.30\tFAIL\tTCP :443 / TLS handshake failed" {
		t.Fatalf("FAIL line = %q", got)
	}
	unresolved := CheckResult{PlatformID: "x", Domain: "x.example.com", OK: false, LatencyMs: -1, Err: "no reply from DNS 127.0.0.1:53"}
	if got := unresolved.Line(); !strings.HasPrefix(got, "x\tx.example.com\t-\tFAIL\tno reply") {
		t.Fatalf("unresolved line = %q want IP field '-'", got)
	}
}

// dnsStub is a TCP DNS server answering A queries for one domain with
// one IP, SERVFAIL otherwise. TCP, not UDP: this sandbox blocks
// sendto(2) on unconnected UDP sockets ("operation not permitted"), so a
// UDP stub can never reply here; RunCheck's UDP->TCP fallback is what
// these tests exercise. Real UDP behaviour is verified on the test
// machine, not in this sandbox.
func dnsStub(t *testing.T, domain, ip string) net.Addr {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_ = c.SetDeadline(time.Now().Add(5 * time.Second))
				var lb [2]byte
				if _, err := io.ReadFull(c, lb[:]); err != nil {
					return
				}
				n := int(lb[0])<<8 | int(lb[1])
				if n <= 0 || n > 65535 {
					return
				}
				pkt := make([]byte, n)
				if _, err := io.ReadFull(c, pkt); err != nil {
					return
				}
				q, ok := parseQuestion(pkt)
				if !ok {
					return
				}
				var resp []byte
				if strings.EqualFold(q.name, domain) {
					resp = buildResponse(pkt, q, net.ParseIP(ip))
				} else {
					resp = buildErrorResponse(pkt, 2)
				}
				var out [2]byte
				out[0], out[1] = byte(len(resp)>>8), byte(len(resp))
				_, _ = c.Write(out[:])
				_, _ = c.Write(resp)
			}(c)
		}
	}()
	return ln.Addr()
}

func panelStub(t *testing.T, cfg model.AgentConfig) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(cfg)
	}))
}

// TestRunCheckUnresolvableRuleFails (V016-16): a rule the panel kept
// with an empty NodeIP (no node in its region, no default unlock IP)
// must come out as a FAIL row — "no usable unlock IP" — never as an
// OK row for the domain's real upstream IP, and never silently
// skipped. Without this, check would report the unlock as working
// when there is no unlock IP at all.
func TestRunCheckUnresolvableRuleFails(t *testing.T) {
	port := localTLSServer(t)
	oldPort := probePort
	probePort = strconv.Itoa(port)
	t.Cleanup(func() { probePort = oldPort })

	stub := dnsStub(t, "bbci.co.uk", "127.0.0.1")
	upstream := stub.String() // answers the domain with 127.0.0.1 (real-IP path)
	cfg := model.AgentConfig{Version: 1, Upstream: upstream, Rules: []model.AgentRule{
		{PlatformID: "bbciplayer", Domains: []string{"bbci.co.uk"}, Region: "GB", NodeIP: ""},
	}}
	srv := panelStub(t, cfg)
	defer srv.Close()

	a := New(Config{Listen: "127.0.0.1:15353", PanelURL: srv.URL, Token: "t", ServerID: "srv-1"})
	results, code, err := a.RunCheck("upstream")
	if err != nil {
		t.Fatalf("RunCheck err = %v want nil", err)
	}
	if code != 1 || len(results) != 1 {
		t.Fatalf("RunCheck = %v,%d want 1 row, code 1", results, code)
	}
	row := results[0]
	if row.OK || row.ResolvedIP != "" {
		t.Fatalf("row = %+v want FAIL with no resolved IP", row)
	}
	if !strings.Contains(row.Err, "no usable unlock IP") {
		t.Fatalf("row.Err = %q want it to name the missing unlock IP", row.Err)
	}
	if got := row.Line(); !strings.HasPrefix(got, "bbciplayer\tbbci.co.uk\t-\tFAIL\t") {
		t.Fatalf("line = %q want bbciplayer FAIL row with '-' IP", got)
	}
}

// TestNewQuietAllowlistWarning (V016-18): `dnsunlock check` never
// listens, so its agent must not print the empty-allowlist warning;
// the dns-agent path (flag off) still warns as before.
func TestNewQuietAllowlistWarning(t *testing.T) {
	captureStderr := func(f func()) string {
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		old := os.Stderr
		os.Stderr = w
		f()
		_ = w.Close()
		os.Stderr = old
		out, _ := io.ReadAll(r)
		return string(out)
	}
	if got := captureStderr(func() {
		_ = New(Config{Listen: "127.0.0.1:15353", QuietAllowlistWarning: true})
	}); strings.Contains(got, "no DNS allowlist") {
		t.Fatalf("quiet agent printed allowlist warning: %q", got)
	}
	if got := captureStderr(func() {
		_ = New(Config{Listen: "127.0.0.1:15353"})
	}); !strings.Contains(got, "no DNS allowlist") {
		t.Fatalf("non-quiet agent did not print allowlist warning: %q", got)
	}
	// A configured allowlist never warns either way.
	if got := captureStderr(func() {
		_ = New(Config{Listen: "127.0.0.1:15353", Allowlist: []string{"127.0.0.1"}})
	}); strings.Contains(got, "no DNS allowlist") {
		t.Fatalf("agent with allowlist printed allowlist warning: %q", got)
	}
}

func TestRunCheckViaAgent(t *testing.T) {
	port := localTLSServer(t)
	oldPort := probePort
	probePort = strconv.Itoa(port)
	t.Cleanup(func() { probePort = oldPort })

	stub := dnsStub(t, "www.netflix.com", "127.0.0.1")
	agentAddr := stub.String()
	cfg := model.AgentConfig{Version: 1, Upstream: "1.1.1.1", Rules: []model.AgentRule{
		{PlatformID: "netflix", Domains: []string{"www.netflix.com"}, NodeIP: "127.0.0.1"},
	}}
	srv := panelStub(t, cfg)
	defer srv.Close()

	a := New(Config{Listen: agentAddr, PanelURL: srv.URL, Token: "t", ServerID: "srv-1"})
	results, code, err := a.RunCheck("agent")
	if err != nil || code != 0 || len(results) != 1 {
		t.Fatalf("RunCheck(agent) = %v,%d,%v want 1 row, code 0", results, code, err)
	}
	row := results[0]
	if row.PlatformID != "netflix" || row.Domain != "www.netflix.com" ||
		row.ResolvedIP != "127.0.0.1" || !row.OK || row.LatencyMs < 0 {
		t.Fatalf("row = %+v want netflix/www.netflix.com/127.0.0.1 OK latency>=0", row)
	}
	if got := row.Line(); !strings.HasPrefix(got, "netflix\twww.netflix.com\t127.0.0.1\tOK\t") {
		t.Fatalf("line = %q", got)
	}
}

func TestRunCheckViaUpstream(t *testing.T) {
	port := localTLSServer(t)
	oldPort := probePort
	probePort = strconv.Itoa(port)
	t.Cleanup(func() { probePort = oldPort })

	stub := dnsStub(t, "www.netflix.com", "127.0.0.1")
	upstream := stub.String() // host:port, used as-is
	cfg := model.AgentConfig{Version: 1, Upstream: upstream, Rules: []model.AgentRule{
		{PlatformID: "netflix", Domains: []string{"www.netflix.com"}, NodeIP: "127.0.0.1"},
	}}
	srv := panelStub(t, cfg)
	defer srv.Close()

	a := New(Config{Listen: "127.0.0.1:15353", PanelURL: srv.URL, Token: "t", ServerID: "srv-1"})
	results, code, err := a.RunCheck("upstream")
	if err != nil || code != 0 || len(results) != 1 || !results[0].OK {
		t.Fatalf("RunCheck(upstream) = %+v,%d,%v want 1 OK row, code 0", results, code, err)
	}
}

// No rules: empty results, code 0 (caller prints NO_RULES).
func TestRunCheckNoRules(t *testing.T) {
	srv := panelStub(t, model.AgentConfig{Version: 1, Upstream: "1.1.1.1"})
	defer srv.Close()
	a := New(Config{Listen: "127.0.0.1:15353", PanelURL: srv.URL, Token: "t", ServerID: "srv-1"})
	results, code, err := a.RunCheck("agent")
	if err != nil || code != 0 || len(results) != 0 {
		t.Fatalf("RunCheck no rules = %v,%d,%v want empty, code 0", results, code, err)
	}
}

// Agent not running: every row FAILs, exit 1, no crash.
func TestRunCheckAgentDown(t *testing.T) {
	cfg := model.AgentConfig{Version: 1, Upstream: "1.1.1.1", Rules: []model.AgentRule{
		{PlatformID: "netflix", Domains: []string{"www.netflix.com"}, NodeIP: "127.0.0.1"},
		{PlatformID: "tiktok", Domains: []string{"www.tiktok.com"}, NodeIP: "127.0.0.1"},
	}}
	srv := panelStub(t, cfg)
	defer srv.Close()
	a := New(Config{Listen: "127.0.0.1:9", PanelURL: srv.URL, Token: "t", ServerID: "srv-1"})
	start := time.Now()
	results, code, err := a.RunCheck("agent")
	if err != nil {
		t.Fatalf("RunCheck(agent down) err = %v want nil (dead agent is FAIL rows, not exit 2)", err)
	}
	if code != 1 || len(results) != 2 {
		t.Fatalf("RunCheck(agent down) = %v,%d want 2 FAIL rows, code 1", results, code)
	}
	for _, r := range results {
		if r.OK || r.Err == "" || r.ResolvedIP != "" {
			t.Fatalf("row = %+v want FAIL with error and no resolved IP", r)
		}
	}
	t.Logf("agent-down check took %s", time.Since(start).Round(time.Millisecond))
}

func TestRunCheckErrors(t *testing.T) {
	// Bad --via: exit 2.
	a := New(Config{Listen: "127.0.0.1:15353", PanelURL: "http://127.0.0.1:9", Token: "t", ServerID: "srv-1"})
	if _, code, err := a.RunCheck("bogus"); err == nil || code != 2 {
		t.Fatalf("RunCheck(bogus) code=%d err=%v want code 2 + error", code, err)
	}
	// Panel unreachable: config error, exit 2.
	srv := panelStub(t, model.AgentConfig{Version: 1})
	url := srv.URL
	srv.Close() // panel gone
	a2 := New(Config{Listen: "127.0.0.1:15353", PanelURL: url, Token: "t", ServerID: "srv-1"})
	if _, code, err := a2.RunCheck("agent"); err == nil || code != 2 {
		t.Fatalf("RunCheck(panel down) code=%d err=%v want code 2 + error", code, err)
	}
}
