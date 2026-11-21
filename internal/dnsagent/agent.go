package dnsagent

// DNS agent: serves DNS on :53, rewrites platform domains to the unlock
// node's IP, forwards everything else to upstream. Polls the panel for
// config every 5s; a rule change takes effect within ~5s.
//
// NO-LOG GUARANTEE: this file never logs a queried name, a client address,
// or any per-query detail. Only aggregate counters are kept (total,
// rewritten, forwarded, per-platform hits without client identity).

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"dnsunlock/internal/model"
)

type Config struct {
	Listen     string // e.g. ":53" or ":15353" for tests
	PanelURL   string
	Token      string
	ServerID   string
	Upstream   string // filled from panel config; default 1.1.1.1
	ServerName string
	// Allowlist restricts which clients may use this DNS server
	// (IPs or CIDRs, e.g. 127.0.0.1, 192.168.1.0/24).
	// SECURITY: an open recursive resolver on :53 becomes a DNS
	// amplification source. On a public VPS you MUST set an allowlist
	// (or firewall 53 to your own IPs). Empty = allow all inside this
	// library; the deployed binary (cmd/dnsunlock) refuses to start
	// with an empty allowlist on non-loopback — fail-closed (P0-04).
	// Never rely on empty in production.
	Allowlist []string
}

// target is what one domain suffix resolves to.
type target struct {
	ip       string // address mode: unlock IP to return
	platform string
	mode     string // "address" (default) or "nameserver"
	ns       string // nameserver mode: upstream DNS IP to forward to
}

type Agent struct {
	cfg Config
	mu  sync.RWMutex
	// domain suffix -> target (lowercase, no trailing dot)
	domains   map[string]target
	version   int64
	upstream  string
	upstreams []string // primary + 8.8.8.8 fallback (P2-01)
	// Small cache for forwarded (non-rewritten) answers, 60s, max 512 (P2-01).
	cacheMu     sync.Mutex
	cache       map[string]cacheEntry
	lastFetchMu sync.Mutex
	lastFetch   time.Time
	lastFetchOK bool
	// Bound concurrent UDP handlers (reliability: unbounded goroutines).
	sem chan struct{}
	// parsed allowlist (nil = allow all inside this library; the
	// deployed entry point refuses to start empty on non-loopback)
	allowNets []*net.IPNet
	allowIPs  map[string]bool
	// allowlistErr is set when the configured allowlist contains an
	// invalid entry (N-04). Run() refuses to start in that case, and
	// allowed() denies everything until then — fail closed, never open.
	allowlistErr error

	total     atomic.Int64
	rewritten atomic.Int64
	forwarded atomic.Int64
	perPlatMu sync.Mutex
	perPlat   map[string]int64

	// health state: unlock IP -> consecutive probe failures, last status.
	// A failed probe ONLY marks the IP red in the panel. It never changes
	// a rule by itself — see failoverToBackup, which runs only when the
	// user explicitly enabled AutoFailover + BackupIP on that rule.
	healthMu sync.Mutex
	health   map[string]*nodeHealth
	// rules currently in effect (platform id -> rule), for failover lookup
	rulesMu sync.Mutex
	rules   map[string]model.AgentRule
	// failover override: platform id -> node ip currently in use
	override      map[string]string
	overrideMu    sync.Mutex
	eventsMu      sync.Mutex
	pendingEvents []model.FailoverEvent
	// self-test (v0.1.6): one queued request at a time, run in the
	// background so a slow probe never stalls the 5s config poll.
	// The result rides the next heartbeat, then is cleared (sent once).
	selftestMu     sync.Mutex
	selftestRun    map[string]bool // request id -> currently running
	selftestDone   map[string]bool // request id -> already ran (dedupe)
	selftestResult *model.SelftestResult
	selftestRuns   int // runs started (test hook)
	// panel fallback (v0.1.3): candidate panel endpoints, built once
	// from the configured panel URL; last-known-good is tried first.
	// In-memory only — nothing new is persisted to disk.
	panelMu         sync.Mutex
	panelCandidates []string
	panelLastGood   string
}

type cacheEntry struct {
	resp   []byte
	expire time.Time
}

type nodeHealth struct {
	failures int
	status   string
	latency  int64
}

// ValidateAllowlist checks every entry is a valid IP or CIDR (N-04).
// An invalid entry must refuse startup, never silently drop to "allow all".
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

func New(cfg Config) *Agent {
	if cfg.Upstream == "" {
		cfg.Upstream = "1.1.1.1"
	}
	a := &Agent{
		cfg: cfg, domains: map[string]target{},
		upstream: cfg.Upstream, upstreams: []string{cfg.Upstream, "8.8.8.8"}, perPlat: map[string]int64{},
		health: map[string]*nodeHealth{}, rules: map[string]model.AgentRule{},
		override: map[string]string{}, allowIPs: map[string]bool{},
		selftestRun: map[string]bool{}, selftestDone: map[string]bool{},
		panelCandidates: panelCandidates(cfg.PanelURL),
		cache:           map[string]cacheEntry{}, lastFetch: time.Now(), lastFetchOK: true,
		sem: make(chan struct{}, 256),
	}
	// Deduplicate upstreams.
	seen := map[string]bool{}
	uniq := []string{}
	for _, u := range a.upstreams {
		if u != "" && !seen[u] {
			seen[u] = true
			uniq = append(uniq, u)
		}
	}
	a.upstreams = uniq
	for _, e := range cfg.Allowlist {
		e = strings.TrimSpace(e)
		if e == "" {
			continue
		}
		if _, n, err := net.ParseCIDR(e); err == nil {
			a.allowNets = append(a.allowNets, n)
		} else if ip := net.ParseIP(e); ip != nil {
			a.allowIPs[ip.String()] = true
		}
	}
	// N-04: an entry that parses as neither IP nor CIDR is an error, not
	// something to drop quietly — dropping it would silently turn the
	// resolver into an open one.
	a.allowlistErr = ValidateAllowlist(cfg.Allowlist)
	if len(a.allowNets) == 0 && len(a.allowIPs) == 0 {
		// Stderr, not stdout: stdout is machine-readable output for
		// `dnsunlock check` (and nothing here is a query answer).
		fmt.Fprintln(os.Stderr, "[agent] WARNING: no DNS allowlist set — this resolver answers anyone. On a public VPS set the allowlist in the 0600 config file (e.g. your client IPs / 192.168.1.0/24) or firewall port 53, or it will be abused for DNS amplification.")
	}
	return a
}

// allowed reports whether a client IP may use this resolver.
// With an invalid allowlist (allowlistErr set) nothing is allowed.
func (a *Agent) allowed(ip net.IP) bool {
	if a.allowlistErr != nil {
		return false
	}
	if len(a.allowNets) == 0 && len(a.allowIPs) == 0 {
		return true
	}
	if a.allowIPs[ip.String()] {
		return true
	}
	for _, n := range a.allowNets {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}

// lookup returns the target for a name (exact, then suffix walk).
func (a *Agent) lookup(name string) (target, bool) {
	name = strings.ToLower(strings.TrimSuffix(name, "."))
	a.mu.RLock()
	defer a.mu.RUnlock()
	for {
		if t, ok := a.domains[name]; ok {
			// Failover override wins over the panel config (address mode only).
			if t.mode != "nameserver" {
				a.overrideMu.Lock()
				if ov, ok2 := a.override[t.platform]; ok2 {
					t.ip = ov
				}
				a.overrideMu.Unlock()
			}
			return t, true
		}
		if i := strings.Index(name, "."); i >= 0 {
			name = name[i+1:]
		} else {
			return target{}, false
		}
	}
}

// panelCandidates builds the ordered fallback list from the configured
// panel URL: (a) the configured URL itself, (b) plain http on the same
// host :8080 (the panel always listens on :8080 directly; 443 is only
// Caddy's reverse proxy), (c) http on each resolved IP of the host
// :8080, (d) http://127.0.0.1:8080 last (panel and agent on the same
// machine: the public IP may be unreachable from the machine itself
// when there is no hairpin NAT, while loopback always works; refused
// instantly when no local panel listens). Nothing here weakens the
// allowlist or adds a port/relay.
// Resolution happens once at startup; a failure just drops (c).
func panelCandidates(rawurl string) []string {
	seen := map[string]bool{}
	out := []string{}
	add := func(u string) {
		u = strings.TrimSuffix(u, "/")
		if u != "" && !seen[u] {
			seen[u] = true
			out = append(out, u)
		}
	}
	add(rawurl)
	u, err := url.Parse(rawurl)
	if err != nil || u.Host == "" {
		return out
	}
	host := u.Hostname()
	if host == "" {
		return out
	}
	// (b) same host, plain http :8080.
	if !(u.Scheme == "http" && u.Port() == "8080") {
		add("http://" + net.JoinHostPort(host, "8080"))
	}
	// (c) resolved IPs :8080.
	if net.ParseIP(host) == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if ips, err := net.DefaultResolver.LookupHost(ctx, host); err == nil {
			for _, ip := range ips {
				add("http://" + net.JoinHostPort(ip, "8080"))
			}
		}
	}
	// (d) loopback :8080 last — panel and agent on the same machine.
	add("http://127.0.0.1:8080")
	return out
}

// panelDo sends one panel request, trying the last-known-good endpoint
// first, then the rest in order. Each attempt is bounded (~5s) so a
// blackholed 443 fails fast instead of hanging a poll cycle. Any HTTP
// response counts as reachable; the caller checks the status code.
func (a *Agent) panelDo(newReq func(base string) (*http.Request, error)) (*http.Response, error) {
	a.panelMu.Lock()
	order := append([]string{}, a.panelCandidates...)
	if a.panelLastGood != "" {
		front := []string{a.panelLastGood}
		for _, c := range order {
			if c != a.panelLastGood {
				front = append(front, c)
			}
		}
		order = front
	}
	a.panelMu.Unlock()
	short := &http.Client{Timeout: 5 * time.Second}
	var lastErr error
	for _, base := range order {
		req, err := newReq(base)
		if err != nil {
			return nil, err
		}
		resp, err := short.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		a.panelMu.Lock()
		a.panelLastGood = base
		a.panelMu.Unlock()
		return resp, nil
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("no panel endpoints configured")
	}
	return nil, lastErr
}

func (a *Agent) fetchAgentConfig() (model.AgentConfig, error) {
	var cfg model.AgentConfig
	// Token goes in the header, never in the URL (URLs land in access
	// logs). The panel's agentAuth accepts X-Agent-Token (P0-06).
	resp, err := a.panelDo(func(base string) (*http.Request, error) {
		u := fmt.Sprintf("%s/api/v1/agent/config?server_id=%s",
			strings.TrimSuffix(base, "/"), a.cfg.ServerID)
		req, err := http.NewRequest(http.MethodGet, u, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("X-Agent-Token", a.cfg.Token)
		return req, nil
	})
	if err != nil {
		return cfg, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return cfg, fmt.Errorf("panel config: %s: %s", resp.Status, strings.TrimSpace(string(b)))
	}
	if err := json.NewDecoder(resp.Body).Decode(&cfg); err != nil {
		return cfg, err
	}
	return cfg, nil
}

func (a *Agent) fetchConfig() error {
	cfg, err := a.fetchAgentConfig()
	if err != nil {
		return err
	}
	a.lastFetchMu.Lock()
	a.lastFetch = time.Now()
	a.lastFetchOK = true
	a.lastFetchMu.Unlock()
	a.mu.Lock()
	if cfg.Version != a.version {
		// Deterministic conflict resolution (P1-02): lowest tier wins a
		// shared domain; the panel already dedups, the agent re-checks.
		sorted := append([]model.AgentRule{}, cfg.Rules...)
		sort.Slice(sorted, func(i, j int) bool {
			if sorted[i].Tier != sorted[j].Tier {
				return sorted[i].Tier < sorted[j].Tier
			}
			return sorted[i].PlatformID < sorted[j].PlatformID
		})
		rules := map[string]model.AgentRule{}
		for _, r := range sorted {
			// PreferFastest: initial pick only. The panel already
			// resolved NodeIP to its fastest stored node; the agent
			// re-picks here from its own live probe data, and again
			// after every 30s health cycle (refreshFastest). This
			// never touches AutoFailover: a failover override still
			// wins in lookup(), and failback still returns to this
			// (effective) primary when it recovers.
			if r.PreferFastest && len(r.Candidates) > 0 {
				if fast, ok := a.pickFastest(r); ok && fast != r.NodeIP {
					fmt.Printf("[agent] prefer-fastest: %s %s -> %s (lowest probe latency in %s)\n", r.PlatformID, r.NodeIP, fast, r.Region)
					r.NodeIP = fast
				}
			}
			rules[r.PlatformID] = r
		}
		a.rebuildDomainsLocked(rules)
		a.rulesMu.Lock()
		oldRules := a.rules
		a.rules = rules
		a.rulesMu.Unlock()
		a.version = cfg.Version
		// Clear stale failover overrides: platform removed, OR its
		// primary IP changed (P1-06 — editing the primary must take
		// effect; the old override used to survive forever).
		a.overrideMu.Lock()
		for pid := range a.override {
			newR, still := rules[pid]
			if !still {
				delete(a.override, pid)
				continue
			}
			if oldR, had := oldRules[pid]; had && oldR.NodeIP != newR.NodeIP {
				delete(a.override, pid)
			}
		}
		a.overrideMu.Unlock()
	}
	if cfg.Upstream != "" {
		a.upstream = cfg.Upstream
		a.upstreams = []string{cfg.Upstream, "8.8.8.8"}
		if cfg.Upstream == "8.8.8.8" {
			a.upstreams = []string{"8.8.8.8", "1.1.1.1"}
		}
	}
	a.mu.Unlock()
	// v0.1.6 self-test: a queued request runs in the background so a
	// slow probe never stalls the 5s poll loop.
	a.maybeStartSelftest(cfg.SelftestRequest)
	return nil
}

// maybeStartSelftest starts one run for a queued request, unless this
// request already ran or is running (the panel may deliver it twice).
func (a *Agent) maybeStartSelftest(req *model.SelftestRequest) {
	if req == nil || req.ID == "" {
		return
	}
	a.selftestMu.Lock()
	if a.selftestDone[req.ID] || a.selftestRun[req.ID] {
		a.selftestMu.Unlock()
		return
	}
	a.selftestRun[req.ID] = true
	a.selftestRuns++
	a.selftestMu.Unlock()
	go a.runSelftest(*req)
}

// runSelftest tests every rule's first platform domain: resolve it with
// the agent's own lookup (nameserver rules: ask that nameserver), then
// TCP :443 + TLS handshake the resolved IP (probeIP). One row per
// platform, so the UI can list "domain -> resolved IP -> ok?" verbatim.
// Connectivity only — it does NOT prove the service accepts the traffic.
func (a *Agent) runSelftest(req model.SelftestRequest) {
	defer func() {
		a.selftestMu.Lock()
		delete(a.selftestRun, req.ID)
		a.selftestDone[req.ID] = true
		a.selftestMu.Unlock()
	}()
	a.rulesMu.Lock()
	rules := make([]model.AgentRule, 0, len(a.rules))
	for _, r := range a.rules {
		rules = append(rules, r)
	}
	a.rulesMu.Unlock()
	sort.Slice(rules, func(i, j int) bool { return rules[i].PlatformID < rules[j].PlatformID })
	res := &model.SelftestResult{
		RequestID: req.ID, RanAt: time.Now().UTC().Format(time.RFC3339),
		Results: []model.SelftestResultItem{},
	}
	for _, r := range rules {
		if len(r.Domains) == 0 {
			continue
		}
		domain := r.Domains[0]
		item := model.SelftestResultItem{PlatformID: r.PlatformID, Domain: domain, LatencyMs: -1}
		ip, err := a.resolveForSelftest(r, domain)
		if err != nil {
			item.Error = err.Error()
			res.Results = append(res.Results, item)
			continue
		}
		item.ResolvedIP = ip
		lat, ok := a.probeIP(ip, domain)
		item.LatencyMs = lat
		item.OK = ok
		if !ok {
			item.Error = "TCP :" + probePort + " 连接或 TLS 握手失败"
		}
		res.Results = append(res.Results, item)
	}
	a.selftestMu.Lock()
	a.selftestResult = res
	a.selftestMu.Unlock()
	fmt.Printf("[agent] selftest %s done: %d platforms\n", req.ID, len(res.Results))
}

// resolveForSelftest resolves one domain the way the agent itself would
// answer it: address rules via lookup (failover override included),
// nameserver rules by asking that nameserver directly.
func (a *Agent) resolveForSelftest(r model.AgentRule, domain string) (string, error) {
	if r.Mode == "nameserver" {
		if r.Nameserver == "" {
			return "", fmt.Errorf("nameserver 模式未填上游 DNS IP")
		}
		ns := r.Nameserver
		resolver := &net.Resolver{
			PreferGo: true,
			Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
				d := &net.Dialer{Timeout: 3 * time.Second}
				return d.DialContext(ctx, "udp", net.JoinHostPort(ns, "53"))
			},
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		ips, err := resolver.LookupHost(ctx, domain)
		if err != nil {
			return "", fmt.Errorf("向上游 %s 查询失败: %v", ns, err)
		}
		if len(ips) == 0 {
			return "", fmt.Errorf("上游 %s 未返回 IP", ns)
		}
		return ips[0], nil
	}
	t, ok := a.lookup(domain)
	if !ok {
		return "", fmt.Errorf("agent 未匹配到该域名的规则")
	}
	if net.ParseIP(t.ip) == nil {
		return "", fmt.Errorf("解锁 IP 无效: %q", t.ip)
	}
	return t.ip, nil
}

// rebuildDomainsLocked rebuilds the domain->target map from rules.
// Caller must hold a.mu (write). Tier order decides shared domains
// (P1-02): lowest tier wins, first platform wins a shared domain.
func (a *Agent) rebuildDomainsLocked(rules map[string]model.AgentRule) {
	sorted := make([]model.AgentRule, 0, len(rules))
	for _, r := range rules {
		sorted = append(sorted, r)
	}
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].Tier != sorted[j].Tier {
			return sorted[i].Tier < sorted[j].Tier
		}
		return sorted[i].PlatformID < sorted[j].PlatformID
	})
	domains := map[string]target{}
	for _, r := range sorted {
		// V016-16: skip rules the panel kept as unresolvable (empty
		// NodeIP / empty Nameserver) when SERVING dns. They exist in
		// the config so check/selftest can report them, but for
		// resolution the domain must stay unmatched and forward
		// upstream exactly as before the panel kept them — matching
		// it with an empty IP would NODATA non-A queries instead.
		if r.Mode == "nameserver" {
			if r.Nameserver == "" {
				continue
			}
		} else if net.ParseIP(r.NodeIP) == nil {
			continue
		}
		for _, d := range r.Domains {
			d = strings.ToLower(strings.TrimSuffix(d, "."))
			if _, exists := domains[d]; exists {
				continue
			}
			domains[d] = target{ip: r.NodeIP, platform: r.PlatformID, mode: r.Mode, ns: r.Nameserver}
		}
	}
	a.domains = domains
}

// pickFastest returns the lowest-latency healthy candidate IP for a
// PreferFastest rule, using the agent's own probe data (health map) when
// any candidate has been probed, else the panel's stored LatencyMs.
// It returns ok=false when no candidate is usable: no probed candidate
// is online, or no latency is known at all — the caller then keeps the
// panel-resolved NodeIP instead of picking a node known to be dead.
func (a *Agent) pickFastest(r model.AgentRule) (string, bool) {
	a.healthMu.Lock()
	defer a.healthMu.Unlock()
	probed := false
	bestIP := ""
	var bestLat int64
	for _, c := range r.Candidates {
		if h, ok := a.health[c.NodeIP]; ok {
			probed = true
			if h.status == "online" && h.latency >= 0 && (bestIP == "" || h.latency < bestLat) {
				bestIP, bestLat = c.NodeIP, h.latency
			}
		}
	}
	if probed {
		return bestIP, bestIP != ""
	}
	for _, c := range r.Candidates {
		// Panel-side fallback: a node the panel already knows is
		// offline must not win on a stale low latency either.
		if c.Status == "offline" {
			continue
		}
		if c.LatencyMs >= 0 && (bestIP == "" || c.LatencyMs < bestLat) {
			bestIP, bestLat = c.NodeIP, c.LatencyMs
		}
	}
	return bestIP, bestIP != ""
}

// refreshFastest re-picks the fastest healthy node for PreferFastest
// rules after each 30s health cycle, from fresh probe data. It is an
// INITIAL-choice refresh only: a platform with an active failover
// override is skipped, so AutoFailover keeps owning the switch until
// the primary recovers (failback), and this never overrides it.
func (a *Agent) refreshFastest() {
	a.overrideMu.Lock()
	overridden := map[string]bool{}
	for pid := range a.override {
		overridden[pid] = true
	}
	a.overrideMu.Unlock()
	a.mu.Lock()
	defer a.mu.Unlock()
	a.rulesMu.Lock()
	defer a.rulesMu.Unlock()
	changed := false
	for pid, r := range a.rules {
		if !r.PreferFastest || len(r.Candidates) == 0 || overridden[pid] {
			continue
		}
		if fast, ok := a.pickFastest(r); ok && fast != r.NodeIP {
			fmt.Printf("[agent] prefer-fastest: %s %s -> %s (probe latency changed)\n", pid, r.NodeIP, fast)
			r.NodeIP = fast
			a.rules[pid] = r
			changed = true
		}
	}
	if changed {
		a.rebuildDomainsLocked(a.rules)
	}
}

func (a *Agent) pollLoop(stop <-chan struct{}) {
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	_ = a.fetchConfig() // immediate first fetch; errors logged once per tick below
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			if err := a.fetchConfig(); err != nil {
				a.lastFetchMu.Lock()
				a.lastFetchOK = false
				stale := time.Since(a.lastFetch)
				a.lastFetchMu.Unlock()
				fmt.Printf("[agent] config poll failed: %v\n", err)
				if stale > time.Minute {
					// P2-09: say so plainly instead of silently serving stale rules.
					fmt.Printf("[agent] WARNING: panel unreachable for %s — still serving last-known rules (version %d)\n", stale.Round(time.Second), a.version)
				}
			}
		}
	}
}

// healthLoop probes each distinct unlock IP on TCP :443 every 30s.
// A failed probe only updates status (reported to the panel, shown red).
// Automatic rule changes happen ONLY via failoverToBackup, and only for
// rules where the user explicitly enabled AutoFailover with a BackupIP —
// except PreferFastest, which only re-picks the INITIAL node choice from
// fresh probe data and never overrides an active failover (see
// refreshFastest).
func (a *Agent) healthLoop(stop <-chan struct{}) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			a.checkHealth()
			a.sendHeartbeat()
		}
	}
}

// probePort is the TCP port probeIP / the self-test dials. Production
// value is 443; tests override it to a local TLS listener's port.
var probePort = "443"

func (a *Agent) probeIP(ip, sni string) (int64, bool) {
	// P2-07: TCP :443 open does not prove unlocking works. Dial, then do
	// a TLS handshake (no verification — the IP is the unlock node, not
	// a CA-trusted name; we only prove TLS answers). A failed handshake
	// counts as a failed probe.
	start := time.Now()
	d := &net.Dialer{Timeout: 3 * time.Second}
	c, err := d.Dial("tcp", net.JoinHostPort(ip, probePort))
	if err != nil {
		return -1, false
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	tc := tls.Client(c, &tls.Config{InsecureSkipVerify: true, ServerName: sni})
	if err := tc.Handshake(); err != nil {
		return -1, false
	}
	_ = tc.Close()
	return time.Since(start).Milliseconds(), true
}

func (a *Agent) checkHealth() {
	a.rulesMu.Lock()
	ips := map[string]string{} // ip -> one SNI name to handshake with
	rules := make([]model.AgentRule, 0, len(a.rules))
	for _, r := range a.rules {
		rules = append(rules, r)
		if r.NodeIP != "" {
			if _, ok := ips[r.NodeIP]; !ok && len(r.Domains) > 0 {
				ips[r.NodeIP] = r.Domains[0]
			}
		}
		// P1-06: probe backup IPs too, so a dead backup is known.
		if r.BackupIP != "" {
			if _, ok := ips[r.BackupIP]; !ok && len(r.Domains) > 0 {
				ips[r.BackupIP] = r.Domains[0]
			}
		}
		// v0.1.6 PreferFastest: probe the candidates too — without
		// this, a candidate that is nobody's current NodeIP would
		// never get a measured latency, and neither the agent's
		// re-pick nor the panel's initial pick could compare it.
		// Candidates never trigger failover (only a rule's own
		// NodeIP does, in the loop below).
		for _, c := range r.Candidates {
			if _, ok := ips[c.NodeIP]; !ok && len(r.Domains) > 0 {
				ips[c.NodeIP] = r.Domains[0]
			}
		}
	}
	a.rulesMu.Unlock()
	for ip, sni := range ips {
		lat, ok := a.probeIP(ip, sni)
		a.healthMu.Lock()
		h, exists := a.health[ip]
		if !exists {
			h = &nodeHealth{}
			a.health[ip] = h
		}
		wasOverride := false
		if ok {
			h.failures = 0
			h.status = "online"
			h.latency = lat
		} else {
			h.failures++
			h.status = "offline"
			h.latency = -1
		}
		failures := h.failures
		a.healthMu.Unlock()
		_ = wasOverride
		if !ok && failures == 2 {
			for _, r := range rules {
				if r.NodeIP == ip && r.AutoFailover && r.BackupIP != "" {
					a.failoverToBackup(r)
				}
			}
		}
		if ok {
			// P1-06: primary recovered — clear the failover override and
			// switch back, with an event so the panel shows it.
			a.overrideMu.Lock()
			for pid, ov := range a.override {
				if r, has := a.rules[pid]; has && r.NodeIP == ip && ov != ip {
					delete(a.override, pid)
					a.eventsMu.Lock()
					a.pendingEvents = append(a.pendingEvents, model.FailoverEvent{
						Time: time.Now().UTC().Format(time.RFC3339), Region: r.Region,
						Platform: pid, FromNode: ov, ToNode: ip,
						Reason: "primary unlock IP recovered; switched back from backup IP",
					})
					a.eventsMu.Unlock()
					fmt.Printf("[agent] failback: %s %s -> primary %s\n", pid, ov, ip)
				}
			}
			a.overrideMu.Unlock()
		}
	}
	// PreferFastest re-pick from the fresh probe data (initial choice
	// only — platforms under a failover override are skipped inside).
	a.refreshFastest()
}

// failoverToBackup switches ONE opted-in rule to its backup IP.
func (a *Agent) failoverToBackup(r model.AgentRule) {
	a.overrideMu.Lock()
	if a.override[r.PlatformID] == r.BackupIP {
		a.overrideMu.Unlock()
		return
	}
	a.override[r.PlatformID] = r.BackupIP
	a.overrideMu.Unlock()
	a.eventsMu.Lock()
	a.pendingEvents = append(a.pendingEvents, model.FailoverEvent{
		Time: time.Now().UTC().Format(time.RFC3339), Region: r.Region,
		Platform: r.PlatformID, FromNode: r.NodeID, ToNode: r.BackupIP,
		Reason: "unlock IP probe failed 2x; rule had auto-failover enabled, switched to backup IP",
	})
	a.eventsMu.Unlock()
	fmt.Printf("[agent] failover: %s %s -> backup %s (rule opted in)\n", r.PlatformID, r.NodeIP, r.BackupIP)
}

func (a *Agent) sendHeartbeat() {
	a.healthMu.Lock()
	nodes := []model.NodeHealth{}
	// NodeID here is the unlock IP itself: rules may use a free-form
	// custom IP with no node record, so the panel matches by IP too.
	for ip, h := range a.health {
		nodes = append(nodes, model.NodeHealth{NodeID: ip, Status: h.status, LatencyMs: h.latency})
	}
	a.healthMu.Unlock()
	a.eventsMu.Lock()
	events := a.pendingEvents
	a.pendingEvents = nil
	a.eventsMu.Unlock()
	a.perPlatMu.Lock()
	perPlat := map[string]int64{}
	for k, v := range a.perPlat {
		perPlat[k] = v
	}
	a.perPlatMu.Unlock()
	// v0.1.6 self-test: attach a finished result once, then clear it.
	a.selftestMu.Lock()
	stResult := a.selftestResult
	a.selftestResult = nil
	a.selftestMu.Unlock()
	hb := model.AgentHeartbeat{
		ServerID: a.cfg.ServerID, Nodes: nodes, Events: events,
		Counters:       model.AgentCounters{Total: a.total.Load(), Rewritten: a.rewritten.Load(), Forwarded: a.forwarded.Load(), PerPlatform: perPlat},
		SelftestResult: stResult,
	}
	b, _ := json.Marshal(hb)
	resp, err := a.panelDo(func(base string) (*http.Request, error) {
		u := fmt.Sprintf("%s/api/v1/agent/heartbeat?server_id=%s", strings.TrimSuffix(base, "/"), a.cfg.ServerID)
		hbReq, err := http.NewRequest(http.MethodPost, u, bytes.NewReader(b))
		if err != nil {
			return nil, err
		}
		hbReq.Header.Set("Content-Type", "application/json")
		hbReq.Header.Set("X-Agent-Token", a.cfg.Token)
		return hbReq, nil
	})
	if err != nil {
		fmt.Printf("[agent] heartbeat failed: %v\n", err)
		return
	}
	resp.Body.Close()
}

// ---- DNS wire format (minimal, stdlib only) ----

type dnsQuestion struct {
	name  string
	qtype uint16
	end   int // offset just after the question section
}

// parseQuestion extracts the first question. Returns ok=false on malformed input.
func parseQuestion(pkt []byte) (dnsQuestion, bool) {
	if len(pkt) < 12 {
		return dnsQuestion{}, false
	}
	qd := binary.BigEndian.Uint16(pkt[4:6])
	if qd != 1 {
		return dnsQuestion{}, false
	}
	off := 12
	var labels []string
	for {
		if off >= len(pkt) {
			return dnsQuestion{}, false
		}
		l := int(pkt[off])
		if l == 0 {
			off++
			break
		}
		if l&0xC0 != 0 {
			return dnsQuestion{}, false // no compression in queries we handle
		}
		off++
		if off+l > len(pkt) {
			return dnsQuestion{}, false
		}
		labels = append(labels, string(pkt[off:off+l]))
		off += l
	}
	if off+4 > len(pkt) {
		return dnsQuestion{}, false
	}
	qtype := binary.BigEndian.Uint16(pkt[off : off+2])
	return dnsQuestion{name: strings.Join(labels, "."), qtype: qtype, end: off + 4}, true
}

func buildErrorResponse(req []byte, rcode byte) []byte {
	// SERVFAIL (or other rcode): copy ID, preserve RD, set QR|RA|rcode.
	// Base 0x8080 (QR + RA); RD comes from the request only — the old
	// 0x8180 base forced RD=1 even when the client asked RD=0 (P1-01).
	out := make([]byte, 0, 16)
	out = append(out, req[0], req[1])
	flags := uint16(0x8080) | (uint16(req[2])&0x01)<<8 // preserve RD from request
	flags = (flags & 0xFFF0) | uint16(rcode)
	out = append(out, byte(flags>>8), byte(flags))
	out = append(out, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
	return out
}

// buildFormErr answers a malformed query (bad QDCOUNT, truncated question,
// compression in the question) with FORMERR instead of silence (P1-01).
// Header only — no question section is echoed back.
func buildFormErr(req []byte) []byte {
	out := make([]byte, 0, 12)
	out = append(out, req[0], req[1])
	flags := uint16(0x8080) | (uint16(req[2])&0x01)<<8
	flags = (flags & 0xFFF0) | 1 // FORMERR
	out = append(out, byte(flags>>8), byte(flags))
	out = append(out, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
	return out
}

func buildResponse(req []byte, q dnsQuestion, ip net.IP) []byte {
	// Header: copy ID, preserve the request's RD bit, set QR|RA, NOERROR.
	// QD=1, AN=1 (or 0 for NODATA). P1-01: the old code hardcoded 0x8180.
	out := make([]byte, 0, len(req)+32)
	out = append(out, req[0], req[1])
	flags := uint16(0x8080) | (uint16(req[2])&0x01)<<8
	out = append(out, byte(flags>>8), byte(flags))
	out = append(out, 0x00, 0x01) // QDCOUNT
	if ip != nil {
		out = append(out, 0x00, 0x01) // ANCOUNT
	} else {
		out = append(out, 0x00, 0x00)
	}
	out = append(out, 0x00, 0x00, 0x00, 0x00) // NS, AR
	out = append(out, req[12:q.end]...)       // question section verbatim
	if ip != nil {
		out = append(out, 0xC0, 0x0C) // name pointer to question
		out = append(out, 0x00, 0x01) // TYPE A
		out = append(out, 0x00, 0x01) // CLASS IN
		ttl := make([]byte, 4)
		binary.BigEndian.PutUint32(ttl, 60)
		out = append(out, ttl...)
		out = append(out, 0x00, 0x04)
		out = append(out, ip.To4()...)
	}
	return out
}

func (a *Agent) handlePacket(pkt []byte) []byte {
	q, ok := parseQuestion(pkt)
	if !ok {
		// Malformed query: answer FORMERR, don't go silent (P1-01).
		// Too short to even hold an ID: nothing sane to answer with.
		if len(pkt) >= 12 {
			return buildFormErr(pkt)
		}
		return nil
	}
	a.total.Add(1)
	if t, matched := a.lookup(q.name); matched {
		// Nameserver mode: relay the query to the rule's DNS, don't rewrite.
		if t.mode == "nameserver" && t.ns != "" {
			a.forwarded.Add(1)
			a.perPlatMu.Lock()
			a.perPlat[t.platform]++
			a.perPlatMu.Unlock()
			if resp := a.forwardTo(net.JoinHostPort(t.ns, "53"), pkt); resp != nil {
				return resp
			}
			return buildErrorResponse(pkt, 2) // SERVFAIL, not silence (P1-01)
		}
		a.rewritten.Add(1)
		a.perPlatMu.Lock()
		a.perPlat[t.platform]++
		a.perPlatMu.Unlock()
		if q.qtype != 1 && q.qtype != 28 {
			// P1-01: matched domain, other type (CNAME/HTTPS/TXT...):
			// answer NODATA instead of forwarding upstream, so the
			// follow-up resolution cannot silently bypass the unlock.
			return buildResponse(pkt, q, nil)
		}
		if q.qtype == 28 {
			// Matched platform: answer AAAA with NODATA so clients use IPv4 via the unlock node.
			return buildResponse(pkt, q, nil)
		}
		ip := net.ParseIP(t.ip)
		if ip == nil {
			// P1-05: an invalid unlock IP must not produce a silent empty
			// answer — fall through to upstream instead.
			a.forwarded.Add(1)
			return a.forwardWithCache(pkt, q)
		}
		return buildResponse(pkt, q, ip)
	}
	// Not a rewrite: forward the raw packet to upstream and relay the reply.
	a.forwarded.Add(1)
	return a.forwardWithCache(pkt, q)
}

// forwardWithCache forwards to upstream (primary, then 8.8.8.8) with a
// 60s cache for non-rewritten answers; upstream failure -> SERVFAIL.
func (a *Agent) forwardWithCache(pkt []byte, q dnsQuestion) []byte {
	key := strings.ToLower(q.name) + "/" + fmt.Sprint(q.qtype)
	a.cacheMu.Lock()
	if e, ok := a.cache[key]; ok && time.Now().Before(e.expire) {
		// N-03: rewrite the transaction ID to THIS query's ID. The
		// cached reply still carries the first query's ID; returning it
		// verbatim makes the client drop the reply. Copy first so the
		// cached bytes are never mutated.
		resp := append([]byte(nil), e.resp...)
		if len(resp) >= 2 {
			resp[0], resp[1] = pkt[0], pkt[1]
		}
		a.cacheMu.Unlock()
		return resp
	}
	a.cacheMu.Unlock()
	resp := a.forward(pkt)
	if resp == nil {
		return buildErrorResponse(pkt, 2) // SERVFAIL (P1-01)
	}
	a.cacheMu.Lock()
	if len(a.cache) > 512 {
		for k := range a.cache {
			delete(a.cache, k)
			break
		}
	}
	a.cache[key] = cacheEntry{resp: append([]byte(nil), resp...), expire: time.Now().Add(60 * time.Second)}
	a.cacheMu.Unlock()
	return resp
}

func (a *Agent) forward(pkt []byte) []byte {
	for _, u := range a.upstreams {
		if resp := a.forwardTo(net.JoinHostPort(u, "53"), pkt); resp != nil {
			return resp
		}
	}
	return nil
}

func (a *Agent) forwardTo(addr string, pkt []byte) []byte {
	if resp := a.forwardUDP(addr, pkt); resp != nil {
		return resp
	}
	return a.forwardTCP(addr, pkt)
}

func (a *Agent) forwardUDP(addr string, pkt []byte) []byte {
	c, err := net.DialTimeout("udp", addr, 3*time.Second)
	if err != nil {
		return nil
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := c.Write(pkt); err != nil {
		return nil
	}
	buf := make([]byte, 8192)
	n, err := c.Read(buf)
	if err != nil {
		return nil
	}
	return buf[:n]
}

// forwardTCP is the fallback when UDP to upstream is blocked/unreachable.
func (a *Agent) forwardTCP(addr string, pkt []byte) []byte {
	c, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		return nil
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(3 * time.Second))
	var lb [2]byte
	binary.BigEndian.PutUint16(lb[:], uint16(len(pkt)))
	if _, err := c.Write(lb[:]); err != nil {
		return nil
	}
	if _, err := c.Write(pkt); err != nil {
		return nil
	}
	if _, err := io.ReadFull(c, lb[:]); err != nil {
		return nil
	}
	n := int(binary.BigEndian.Uint16(lb[:]))
	if n <= 0 || n > 65535 {
		return nil
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(c, buf); err != nil {
		return nil
	}
	return buf
}

func (a *Agent) serveUDP() error {
	addr, err := net.ResolveUDPAddr("udp", a.cfg.Listen)
	if err != nil {
		return err
	}
	c, err := net.ListenUDP("udp", addr)
	if err != nil {
		return err
	}
	defer c.Close()
	// P1 (v0.1.6): reply from the address the query was sent to.
	// A wildcard :53 socket also receives queries sent to 127.0.0.53
	// (the systemd-resolved stub address), but the kernel answers them
	// from 127.0.0.1, which dig/getent discard on source check
	// (bare-UDP capture: reply from ('127.0.0.1', 53), ID and content
	// correct, still dropped). TCP is unaffected (the reply source of
	// an accepted connection is the address it was made to).
	// IP_PKTINFO / IPV6_PKTINFO makes each reply carry the query's
	// destination address as its source. Best effort: if the socket
	// does not support it, fall back to plain replies (old behavior).
	pkt := newUDPPktinfo(c, addr)
	buf := make([]byte, 8192)
	oob := make([]byte, 64)
	for {
		n, oobn, _, remote, err := c.ReadMsgUDP(buf, oob)
		if err != nil {
			return err
		}
		if !a.allowed(remote.IP) {
			continue // not on the allowlist: drop silently, no reply
		}
		pktBytes := append([]byte(nil), buf[:n]...)
		dst := pkt.dstFromOOB(oob[:oobn])
		select {
		case a.sem <- struct{}{}:
		default:
			continue // overloaded: drop instead of spawning unbounded goroutines
		}
		go func() {
			defer func() { <-a.sem }()
			resp := a.handlePacket(pktBytes)
			if resp == nil {
				return
			}
			if dst != nil {
				if _, _, err := c.WriteMsgUDP(resp, pkt.replyOOB(dst), remote); err != nil {
					// A wrong-source reply is better than silence if
					// the kernel rejects the ancillary data.
					_, _ = c.WriteToUDP(resp, remote)
				}
				return
			}
			_, _ = c.WriteToUDP(resp, remote)
		}()
	}
}

// udpPktinfo makes UDP replies carry the query's destination address as
// their source (IP_PKTINFO for IPv4 sockets, IPV6_PKTINFO for IPv6 /
// dual-stack sockets). Without it, a wildcard :53 socket answers queries
// sent to 127.0.0.53 from 127.0.0.1, and dig/getent discard the reply.
// Ancillary data is built with encoding/binary (no unsafe); the layout
// is the kernel's struct cmsghdr + struct in_pktinfo / in6_pktinfo on
// little-endian amd64/arm64 (the only release targets).
type udpPktinfo struct {
	v6     bool // socket is IPv6 (incl. the dual-stack wildcard ":53")
	active bool // recv-pktinfo was enabled on the socket
}

func newUDPPktinfo(c *net.UDPConn, addr *net.UDPAddr) *udpPktinfo {
	// V016-11: the family comes from the socket, never from the
	// listen-address string (addr is kept only for the caller's
	// convenience; it says nothing about the socket Go built). On a
	// host with IPv6 disabled, ":53" still resolves to a nil-IP
	// address, but ListenUDP builds an AF_INET socket; judging by the
	// address would try IPV6_RECVPKTINFO on it, get ENOPROTOOPT and
	// silently fall back to plain (wrong-source) replies. So try the
	// IPv6 option first and, only if the socket rejects it, the IPv4
	// option; only when both fail do we fall back to plain replies,
	// and that fallback is logged, never silent.
	p := &udpPktinfo{}
	raw, err := c.SyscallConn()
	if err != nil {
		// V016-25: log this like the setsockopt failure below — the
		// same "pktinfo not enabled" state must not be silent here
		// and noisy there, or troubleshooting cannot tell them apart.
		log.Printf("dns-agent: cannot enable pktinfo: SyscallConn failed (%v); replies to 127.0.0.53 may be dropped on source check", err)
		return p
	}
	var setErr error
	// trySet applies one pktinfo option; a Control error means the
	// callback never ran, so setErr staying nil must NOT read as
	// success (V016-26: a closed socket used to come out active=true).
	trySet := func(level, typ int) (ctrlErr error) {
		setErr = nil
		return raw.Control(func(fd uintptr) {
			setErr = syscall.SetsockoptInt(int(fd), level, typ, 1)
		})
	}
	if ctrlErr := trySet(syscall.IPPROTO_IPV6, syscall.IPV6_RECVPKTINFO); ctrlErr != nil {
		log.Printf("dns-agent: cannot enable pktinfo: cannot access socket (%v); replies to 127.0.0.53 may be dropped on source check", ctrlErr)
		return p
	}
	if setErr == nil {
		p.v6 = true
		p.active = true
		return p
	}
	v6Err := setErr
	if ctrlErr := trySet(syscall.IPPROTO_IP, syscall.IP_PKTINFO); ctrlErr != nil {
		log.Printf("dns-agent: cannot enable pktinfo: cannot access socket (%v); replies to 127.0.0.53 may be dropped on source check", ctrlErr)
		return p
	}
	if setErr == nil {
		log.Printf("dns-agent: IPV6_RECVPKTINFO not supported on this socket (%v); using IP_PKTINFO instead", v6Err)
		p.v6 = false
		p.active = true
		return p
	}
	log.Printf("dns-agent: cannot enable pktinfo (IPv6: %v; IPv4: %v); replies to 127.0.0.53 may be dropped on source check", v6Err, setErr)
	return p
}

// dstFromOOB extracts the packet's destination address from ancillary data.
func (p *udpPktinfo) dstFromOOB(oob []byte) net.IP {
	if !p.active || len(oob) == 0 {
		return nil
	}
	cmsgs, err := syscall.ParseSocketControlMessage(oob)
	if err != nil {
		return nil
	}
	for _, m := range cmsgs {
		if p.v6 {
			if m.Header.Level == syscall.IPPROTO_IPV6 && m.Header.Type == syscall.IPV6_PKTINFO && len(m.Data) >= 16 {
				return net.IP(append([]byte(nil), m.Data[:16]...))
			}
		} else if m.Header.Level == syscall.IPPROTO_IP && m.Header.Type == syscall.IP_PKTINFO && len(m.Data) >= 12 {
			return net.IP(append([]byte(nil), m.Data[8:12]...))
		}
	}
	return nil
}

// replyOOB builds the ancillary data that forces the reply source to dst.
func (p *udpPktinfo) replyOOB(dst net.IP) []byte {
	if !p.active || dst == nil {
		return nil
	}
	if p.v6 {
		ip16 := dst.To16()
		if ip16 == nil {
			return nil
		}
		oob := make([]byte, syscall.CmsgSpace(20))
		binary.LittleEndian.PutUint64(oob[0:8], uint64(syscall.CmsgLen(20)))
		binary.LittleEndian.PutUint32(oob[8:12], uint32(syscall.IPPROTO_IPV6))
		binary.LittleEndian.PutUint32(oob[12:16], uint32(syscall.IPV6_PKTINFO))
		copy(oob[16:32], ip16)                       // ipi6_addr
		binary.LittleEndian.PutUint32(oob[32:36], 0) // ipi6_ifindex
		return oob[:syscall.CmsgLen(20)]
	}
	ip4 := dst.To4()
	if ip4 == nil {
		return nil
	}
	oob := make([]byte, syscall.CmsgSpace(12))
	binary.LittleEndian.PutUint64(oob[0:8], uint64(syscall.CmsgLen(12)))
	binary.LittleEndian.PutUint32(oob[8:12], uint32(syscall.IPPROTO_IP))
	binary.LittleEndian.PutUint32(oob[12:16], uint32(syscall.IP_PKTINFO))
	binary.LittleEndian.PutUint32(oob[16:20], 0) // ipi_ifindex
	copy(oob[20:24], ip4)                        // ipi_spec_dst
	copy(oob[24:28], ip4)                        // ipi_addr
	return oob[:syscall.CmsgLen(12)]
}

func (a *Agent) serveTCP() error {
	ln, err := net.Listen("tcp", a.cfg.Listen)
	if err != nil {
		return err
	}
	defer ln.Close()
	for {
		c, err := ln.Accept()
		if err != nil {
			return err
		}
		if tcpAddr, ok := c.RemoteAddr().(*net.TCPAddr); ok && !a.allowed(tcpAddr.IP) {
			c.Close()
			continue
		}
		go a.handleTCP(c)
	}
}

func (a *Agent) handleTCP(c net.Conn) {
	defer c.Close()
	// 15s: upstream may need a 3s UDP attempt + a 3s TCP attempt per
	// server (two upstreams worst case). A 5s deadline closed the
	// connection before the TCP fallback could answer (found live:
	// "communications error: end of file" when UDP to upstream is blocked).
	_ = c.SetDeadline(time.Now().Add(15 * time.Second))
	var lb [2]byte
	if _, err := io.ReadFull(c, lb[:]); err != nil {
		return
	}
	n := int(binary.BigEndian.Uint16(lb[:]))
	if n <= 0 || n > 65535 {
		return
	}
	pkt := make([]byte, n)
	if _, err := io.ReadFull(c, pkt); err != nil {
		return
	}
	resp := a.handlePacket(pkt)
	if resp == nil {
		return
	}
	var out [2]byte
	binary.BigEndian.PutUint16(out[:], uint16(len(resp)))
	_, _ = c.Write(out[:])
	_, _ = c.Write(resp)
}

func (a *Agent) Counters() model.AgentCounters {
	a.perPlatMu.Lock()
	defer a.perPlatMu.Unlock()
	perPlat := map[string]int64{}
	for k, v := range a.perPlat {
		perPlat[k] = v
	}
	return model.AgentCounters{Total: a.total.Load(), Rewritten: a.rewritten.Load(), Forwarded: a.forwarded.Load(), PerPlatform: perPlat}
}

// Run starts polling, healthchecks and both DNS listeners. It blocks.
func (a *Agent) Run() error {
	// N-04: an invalid allowlist refuses startup (checked again here so
	// the agent itself never runs open by mistake, not just the CLI).
	if a.allowlistErr != nil {
		return fmt.Errorf("dns-agent: invalid allowlist: %w", a.allowlistErr)
	}
	stop := make(chan struct{})
	go a.pollLoop(stop)
	go a.healthLoop(stop)
	errCh := make(chan error, 2)
	go func() { errCh <- a.serveUDP() }()
	go func() { errCh <- a.serveTCP() }()
	return <-errCh
}
