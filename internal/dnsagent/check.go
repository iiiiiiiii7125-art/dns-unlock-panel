package dnsagent

// `dnsunlock check` (v0.1.6, item 4 baseline): the installer's baseline
// comparison runs this before takeover (--via upstream: what the domain
// resolves to without the agent) and after (--via agent: what the agent
// answers). It reuses the agent's own DNS client + probeIP, never dig.
//
// CLI contract (Shell line depends on this exactly):
//   dnsunlock check --config /etc/dnsunlock/config.json [--via agent|upstream]
// Output, one line per rule's first platform domain:
//   <platform_id>\t<domain>\t<resolved_ip>\tOK|FAIL\t<ms|error>
//   (unresolved IP prints as "-"; latency is the :443/TLS probe RTT in ms)
// No rules: prints NO_RULES, exit 0.
// Exit codes: 0 = all OK, 1 = any FAIL, 2 = config/usage error.
// --via agent with the agent not running: every row FAILs with an error
// and exit is 1 — never a crash, never exit 2 (that is reserved for
// "we could not even load the config/rules").

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"net"
	"strconv"
	"strings"
)

// CheckResult is one output row of `dnsunlock check`.
type CheckResult struct {
	PlatformID string
	Domain     string
	ResolvedIP string
	OK         bool
	LatencyMs  int64  // probe RTT ms; -1 when nothing was measured
	Err        string // set when OK is false
}

// Line renders the contracted tab-separated row.
func (r CheckResult) Line() string {
	status := "OK"
	last := strconv.FormatInt(r.LatencyMs, 10)
	if !r.OK {
		status = "FAIL"
		last = r.Err
		if last == "" {
			last = "probe failed"
		}
	}
	ip := r.ResolvedIP
	if ip == "" {
		ip = "-"
	}
	return fmt.Sprintf("%s\t%s\t%s\t%s\t%s", r.PlatformID, r.Domain, ip, status, last)
}

// buildQuery builds a minimal DNS A query (RD set, one question).
// V016-31: the transaction ID is random per query (never the old fixed
// 0x1234), and over-long labels / domains are rejected instead of
// wrapping the length byte. Returns the packet, its ID, and an error.
func buildQuery(domain string) ([]byte, uint16, error) {
	var idb [2]byte
	if _, err := rand.Read(idb[:]); err != nil {
		return nil, 0, fmt.Errorf("random query ID: %w", err)
	}
	id := binary.BigEndian.Uint16(idb[:])
	domain = strings.TrimSuffix(domain, ".")
	if domain == "" {
		return nil, 0, fmt.Errorf("empty domain")
	}
	if len(domain) > 253 {
		return nil, 0, fmt.Errorf("domain too long: %d bytes (max 253)", len(domain))
	}
	var out []byte
	out = append(out, idb[0], idb[1]) // ID
	out = append(out, 0x01, 0x00)     // RD
	out = append(out, 0x00, 0x01)     // QDCOUNT=1
	out = append(out, 0x00, 0x00)     // ANCOUNT
	out = append(out, 0x00, 0x00)     // NSCOUNT
	out = append(out, 0x00, 0x00)     // ARCOUNT
	for _, l := range strings.Split(domain, ".") {
		if len(l) == 0 {
			return nil, 0, fmt.Errorf("empty label in domain %q", domain)
		}
		if len(l) > 63 {
			return nil, 0, fmt.Errorf("label %q too long: %d bytes (max 63)", l, len(l))
		}
		out = append(out, byte(len(l)))
		out = append(out, l...)
	}
	out = append(out, 0x00)       // root label
	out = append(out, 0x00, 0x01) // QTYPE A
	out = append(out, 0x00, 0x01) // QCLASS IN
	return out, id, nil
}

// skipName advances past a (possibly compressed) domain name in pkt.
func skipName(pkt []byte, off int) (int, error) {
	for {
		if off >= len(pkt) {
			return 0, fmt.Errorf("truncated name")
		}
		l := int(pkt[off])
		if l == 0 {
			return off + 1, nil
		}
		if l&0xC0 == 0xC0 {
			if off+1 >= len(pkt) {
				return 0, fmt.Errorf("truncated pointer")
			}
			return off + 2, nil // compression pointer: name ends here
		}
		off += 1 + l
	}
}

// parseAnswerA returns the first A record in a DNS response.
// V016-31: the response must carry the query's own ID and RCODE 0;
// anything else is rejected instead of being read as an answer.
func parseAnswerA(resp []byte, wantID uint16) (net.IP, error) {
	if len(resp) < 12 {
		return nil, fmt.Errorf("response too short")
	}
	if id := binary.BigEndian.Uint16(resp[0:2]); id != wantID {
		return nil, fmt.Errorf("response ID 0x%04x, want 0x%04x", id, wantID)
	}
	if rcode := resp[3] & 0x0F; rcode != 0 {
		return nil, fmt.Errorf("DNS error rcode=%d", rcode)
	}
	an := int(resp[6])<<8 | int(resp[7])
	if an == 0 {
		return nil, fmt.Errorf("no answer")
	}
	off := 12
	// Skip the question section.
	qd := int(resp[4])<<8 | int(resp[5])
	for i := 0; i < qd; i++ {
		var err error
		if off, err = skipName(resp, off); err != nil {
			return nil, err
		}
		off += 4
		if off > len(resp) {
			return nil, fmt.Errorf("truncated question")
		}
	}
	for i := 0; i < an; i++ {
		var err error
		if off, err = skipName(resp, off); err != nil {
			return nil, err
		}
		if off+10 > len(resp) {
			return nil, fmt.Errorf("truncated answer")
		}
		typ := int(resp[off])<<8 | int(resp[off+1])
		rdlen := int(resp[off+8])<<8 | int(resp[off+9])
		off += 10
		if off+rdlen > len(resp) {
			return nil, fmt.Errorf("truncated rdata")
		}
		if typ == 1 && rdlen == 4 {
			return net.IP(resp[off : off+4]), nil
		}
		off += rdlen
	}
	return nil, fmt.Errorf("no A record in answer")
}

// resolveVia asks one DNS server (host:port) for an A record, UDP first
// with TCP fallback, reusing the agent's forwarders.
func (a *Agent) resolveVia(addr, domain string) (string, error) {
	pkt, id, err := buildQuery(domain)
	if err != nil {
		return "", err
	}
	resp := a.forwardUDP(addr, pkt)
	if resp == nil {
		resp = a.forwardTCP(addr, pkt)
	}
	if resp == nil {
		return "", fmt.Errorf("no reply from DNS %s", addr)
	}
	ip, err := parseAnswerA(resp, id)
	if err != nil {
		return "", err
	}
	return ip.String(), nil
}

// agentListenAddr is where --via agent queries: the agent's configured
// listen address, with an empty host meaning loopback (":53" -> 127.0.0.1:53).
func (a *Agent) agentListenAddr() string {
	host, port, err := net.SplitHostPort(a.cfg.Listen)
	if err != nil {
		return "127.0.0.1:53"
	}
	if host == "" {
		host = "127.0.0.1"
	}
	if port == "" {
		port = "53"
	}
	return net.JoinHostPort(host, port)
}

// upstreamAddr normalises the panel's upstream: a bare IP/host gets :53,
// a host:port value (used by tests) is used as-is.
func upstreamAddr(u string) string {
	if u == "" {
		u = "1.1.1.1"
	}
	if _, _, err := net.SplitHostPort(u); err == nil {
		return u
	}
	return net.JoinHostPort(u, "53")
}

// RunCheck implements the `dnsunlock check` contract. It returns the
// per-rule rows and the process exit code (0 all OK, 1 any FAIL, 2
// config/usage error, in which case err is non-nil and rows is nil).
// A dead agent (or dead upstream) fails rows, never the whole run.
func (a *Agent) RunCheck(via string) ([]CheckResult, int, error) {
	if via != "agent" && via != "upstream" {
		return nil, 2, fmt.Errorf("--via must be agent or upstream, got %q", via)
	}
	cfg, err := a.fetchAgentConfig()
	if err != nil {
		return nil, 2, fmt.Errorf("load panel config: %w", err)
	}
	if len(cfg.Rules) == 0 {
		return nil, 0, nil // caller prints NO_RULES
	}
	var addr string
	if via == "agent" {
		addr = a.agentListenAddr()
	} else {
		addr = upstreamAddr(cfg.Upstream)
	}
	results := make([]CheckResult, 0, len(cfg.Rules))
	anyFail := false
	for _, r := range cfg.Rules {
		if len(r.Domains) == 0 {
			continue
		}
		row := CheckResult{PlatformID: r.PlatformID, Domain: r.Domains[0], LatencyMs: -1}
		ip, err := a.resolveVia(addr, row.Domain)
		if err != nil {
			row.Err = err.Error()
			results = append(results, row)
			anyFail = true
			continue
		}
		row.ResolvedIP = ip
		lat, ok := a.probeIP(ip, row.Domain)
		row.LatencyMs = lat
		row.OK = ok
		if !ok {
			row.Err = "TCP :" + probePort + " / TLS handshake failed"
			anyFail = true
		}
		results = append(results, row)
	}
	if anyFail {
		return results, 1, nil
	}
	return results, 0, nil
}
