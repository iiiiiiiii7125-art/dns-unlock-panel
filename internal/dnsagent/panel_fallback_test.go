package dnsagent

import (
	"net"
	"reflect"
	"strings"
	"testing"
)

// v0.1.3: panel endpoint fallback candidates.
// (a) configured URL, (b) same host plain http :8080,
// (c) each resolved IP :8080 (dropped when the host does not resolve),
// (d) http://127.0.0.1:8080 last (v0.1.4: panel+agent on one machine).
func TestPanelCandidates(t *testing.T) {
	// Literal-IP inputs never resolve: exact match.
	exact := []struct {
		in   string
		want []string
	}{
		{"http://127.0.0.1:8080", []string{"http://127.0.0.1:8080"}},
		{"https://127.0.0.1:8443", []string{"https://127.0.0.1:8443", "http://127.0.0.1:8080"}},
		// Blackholed public IP: (b) same host :8080, then (d) loopback.
		{"https://203.0.113.99:443", []string{"https://203.0.113.99:443", "http://203.0.113.99:8080", "http://127.0.0.1:8080"}},
	}
	for _, tc := range exact {
		if got := panelCandidates(tc.in); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("panelCandidates(%q) = %v, want %v", tc.in, got, tc.want)
		}
	}

	// Hostname input: (a) and (b) must lead; (c) is resolver-dependent
	// (some resolvers wildcard unknown names), so only its shape is
	// asserted — every extra candidate must be http://<IP>:8080.
	got := panelCandidates("https://panel.invalid/")
	if len(got) < 2 || got[0] != "https://panel.invalid" || got[1] != "http://panel.invalid:8080" {
		t.Fatalf("panelCandidates(hostname) = %v, want it to start with [https://panel.invalid http://panel.invalid:8080]", got)
	}
	for _, c := range got[2:] {
		if !strings.HasPrefix(c, "http://") || !strings.HasSuffix(c, ":8080") {
			t.Errorf("fallback candidate %q is not http://<ip>:8080", c)
		}
		ip := strings.TrimSuffix(strings.TrimPrefix(c, "http://"), ":8080")
		if net.ParseIP(ip) == nil {
			t.Errorf("fallback candidate %q does not hold a literal IP", c)
		}
	}
	// (d) loopback must be the last candidate.
	if got[len(got)-1] != "http://127.0.0.1:8080" {
		t.Errorf("last candidate = %q, want http://127.0.0.1:8080 (full list %v)", got[len(got)-1], got)
	}
}
