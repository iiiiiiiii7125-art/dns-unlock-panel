package dnsagent

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"dnsunlock/internal/model"
)

func fastestRule() model.AgentRule {
	return model.AgentRule{
		PlatformID: "netflix", Tier: 1, Domains: []string{"www.netflix.com"},
		NodeIP: "203.0.113.10", Region: "JP", PreferFastest: true,
		Candidates: []model.NodeCandidate{
			{NodeID: "n-slow", NodeIP: "203.0.113.10", LatencyMs: 120, Status: "online"},
			{NodeID: "n-fast", NodeIP: "203.0.113.20", LatencyMs: 35, Status: "online"},
			{NodeID: "n-dead", NodeIP: "203.0.113.30", LatencyMs: 5, Status: "offline"},
		},
	}
}

// pickFastest uses the agent's own probe data (health map) when any
// candidate has been probed; else the panel's stored LatencyMs.
func TestPickFastest(t *testing.T) {
	a := New(Config{PanelURL: "http://127.0.0.1:8080", Token: "t", ServerID: "srv-1"})

	// (a) probed: lowest-latency ONLINE node wins; offline node with a
	// lower stored latency must not win.
	a.healthMu.Lock()
	a.health["203.0.113.10"] = &nodeHealth{status: "online", latency: 120}
	a.health["203.0.113.20"] = &nodeHealth{status: "online", latency: 35}
	a.health["203.0.113.30"] = &nodeHealth{status: "offline", latency: -1}
	a.healthMu.Unlock()
	if got, ok := a.pickFastest(fastestRule()); !ok || got != "203.0.113.20" {
		t.Fatalf("probed pick = %q,%v want 203.0.113.20,true", got, ok)
	}

	// (b) probed but nothing online: no pick, caller keeps panel NodeIP.
	a.healthMu.Lock()
	a.health["203.0.113.10"] = &nodeHealth{status: "offline", latency: -1}
	a.health["203.0.113.20"] = &nodeHealth{status: "offline", latency: -1}
	a.healthMu.Unlock()
	if got, ok := a.pickFastest(fastestRule()); ok || got != "" {
		t.Fatalf("all-dead pick = %q,%v want \"\",false", got, ok)
	}

	// (c) nothing probed yet: fall back to the panel's stored latency.
	a2 := New(Config{PanelURL: "http://127.0.0.1:8080", Token: "t", ServerID: "srv-1"})
	if got, ok := a2.pickFastest(fastestRule()); !ok || got != "203.0.113.20" {
		t.Fatalf("unprobed pick = %q,%v want 203.0.113.20,true", got, ok)
	}

	// (d) nothing probed, no latency known: no pick.
	r := fastestRule()
	for i := range r.Candidates {
		r.Candidates[i].LatencyMs = -1
	}
	if got, ok := a2.pickFastest(r); ok || got != "" {
		t.Fatalf("no-latency pick = %q,%v want \"\",false", got, ok)
	}
}

// fetchConfig applies the fastest pick, and a failover override still
// wins over it (AutoFailover untouched by PreferFastest).
func TestPreferFastestFetchConfig(t *testing.T) {
	rule := fastestRule()
	cfg := model.AgentConfig{Version: 1, Upstream: "1.1.1.1", Rules: []model.AgentRule{rule}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(cfg)
	}))
	defer srv.Close()

	a := New(Config{PanelURL: srv.URL, Token: "t", ServerID: "srv-1"})
	a.healthMu.Lock()
	a.health["203.0.113.10"] = &nodeHealth{status: "online", latency: 120}
	a.health["203.0.113.20"] = &nodeHealth{status: "online", latency: 35}
	a.health["203.0.113.30"] = &nodeHealth{status: "offline", latency: -1}
	a.healthMu.Unlock()
	if err := a.fetchConfig(); err != nil {
		t.Fatalf("fetchConfig: %v", err)
	}
	tgt, ok := a.lookup("www.netflix.com")
	if !ok || tgt.ip != "203.0.113.20" {
		t.Fatalf("lookup after fetch = %+v,%v want ip 203.0.113.20", tgt, ok)
	}

	// Failover override still wins over the fastest pick.
	a.overrideMu.Lock()
	a.override["netflix"] = "203.0.113.99"
	a.overrideMu.Unlock()
	tgt, _ = a.lookup("www.netflix.com")
	if tgt.ip != "203.0.113.99" {
		t.Fatalf("lookup with override = %q want 203.0.113.99 (failover must still win)", tgt.ip)
	}
	a.overrideMu.Lock()
	delete(a.override, "netflix")
	a.overrideMu.Unlock()

	// refreshFastest re-picks when probe data changes (fast node dies).
	a.healthMu.Lock()
	a.health["203.0.113.20"] = &nodeHealth{status: "offline", latency: -1}
	a.healthMu.Unlock()
	a.refreshFastest()
	tgt, _ = a.lookup("www.netflix.com")
	if tgt.ip != "203.0.113.10" {
		t.Fatalf("lookup after refresh = %q want 203.0.113.10 (only healthy left)", tgt.ip)
	}

	// ... but not while a failover override owns the platform.
	a.overrideMu.Lock()
	a.override["netflix"] = "203.0.113.99"
	a.overrideMu.Unlock()
	a.healthMu.Lock()
	a.health["203.0.113.20"] = &nodeHealth{status: "online", latency: 10}
	a.healthMu.Unlock()
	a.refreshFastest()
	tgt, _ = a.lookup("www.netflix.com")
	if tgt.ip != "203.0.113.99" {
		t.Fatalf("lookup during override = %q want 203.0.113.99 (refresh must not steal a failover)", tgt.ip)
	}
}
