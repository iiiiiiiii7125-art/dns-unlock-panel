package panel

import (
	"net/http"
	"testing"
)

// N-07: X-Forwarded-For is trusted only from a loopback reverse proxy,
// and the LAST entry wins (a proxy appends the real peer IP at the end).
func TestClientIP(t *testing.T) {
	cases := []struct {
		name       string
		remoteAddr string
		xff        string
		want       string
	}{
		{"direct client, forged XFF ignored", "203.0.113.5:1234", "1.2.3.4", "203.0.113.5"},
		{"direct client, no XFF", "203.0.113.5:1234", "", "203.0.113.5"},
		{"loopback proxy, last XFF wins", "127.0.0.1:1234", "1.1.1.1, 2.2.2.2", "2.2.2.2"},
		{"loopback proxy, single XFF", "127.0.0.1:1234", "198.51.100.77", "198.51.100.77"},
		{"loopback proxy, no XFF", "127.0.0.1:1234", "", "127.0.0.1"},
		{"ipv6 loopback proxy, last XFF wins", "[::1]:1234", "9.9.9.9, 8.8.8.8", "8.8.8.8"},
		{"other loopback address is NOT a trusted proxy", "127.0.0.2:1234", "1.2.3.4", "127.0.0.2"},
		// M-05: double reverse proxy (e.g. Cloudflare -> Caddy) is NOT
		// supported in this version — the lock keys on the last XFF
		// entry, which there is the outer proxy's egress IP, so users
		// behind the same egress share one lock. Pinned here so a
		// future change to the trust model cannot slip in silently.
		{"double proxy NOT supported: lock keys on egress IP", "127.0.0.1:1234", "203.0.113.9, 198.51.100.1", "198.51.100.1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := http.NewRequest(http.MethodGet, "/", nil)
			r.RemoteAddr = tc.remoteAddr
			if tc.xff != "" {
				r.Header.Set("X-Forwarded-For", tc.xff)
			}
			if got := clientIP(r); got != tc.want {
				t.Fatalf("clientIP(%q, XFF=%q) = %q, want %q", tc.remoteAddr, tc.xff, got, tc.want)
			}
		})
	}
}
