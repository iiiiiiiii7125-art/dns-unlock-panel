package panel

import (
	"testing"

	"dnsunlock/internal/model"
)

func TestResolveIPPreferFastest(t *testing.T) {
	nodes := []model.Node{
		{ID: "n1", IP: "203.0.113.10", Region: "JP", Enabled: true, Status: "online", LatencyMs: 120},
		{ID: "n2", IP: "203.0.113.20", Region: "JP", Enabled: true, Status: "online", LatencyMs: 35},
		{ID: "n3", IP: "203.0.113.30", Region: "JP", Enabled: true, Status: "offline", LatencyMs: 5},
		{ID: "n4", IP: "203.0.113.40", Region: "US", Enabled: true, Status: "online", LatencyMs: 1},
	}
	rule := model.Rule{PlatformID: "netflix", Region: "JP", PreferFastest: true}
	ip, nid, ok := resolveIP(nodes, rule)
	if !ok || ip != "203.0.113.20" || nid != "n2" {
		t.Fatalf("prefer_fastest resolve = %q,%q,%v want 203.0.113.20,n2,true (offline n3 at 5ms must not win)", ip, nid, ok)
	}

	// PreferFastest off: first online node in the region (old behaviour).
	rule.PreferFastest = false
	ip, _, ok = resolveIP(nodes, rule)
	if !ok || ip != "203.0.113.10" {
		t.Fatalf("plain resolve = %q,%v want 203.0.113.10,true", ip, ok)
	}

	// PreferFastest on but no online node with a measured latency:
	// fall back to the normal first-online pick, never to a dead node.
	stale := []model.Node{
		{ID: "n1", IP: "203.0.113.10", Region: "JP", Enabled: true, Status: "online", LatencyMs: -1},
		{ID: "n3", IP: "203.0.113.30", Region: "JP", Enabled: true, Status: "offline", LatencyMs: 5},
	}
	ip, _, ok = resolveIP(stale, model.Rule{PlatformID: "netflix", Region: "JP", PreferFastest: true})
	if !ok || ip != "203.0.113.10" {
		t.Fatalf("no-latency fallback = %q,%v want 203.0.113.10,true", ip, ok)
	}
}

func TestRegionCandidates(t *testing.T) {
	nodes := []model.Node{
		{ID: "n1", IP: "203.0.113.10", Region: "JP", Enabled: true, Status: "online", LatencyMs: 120},
		{ID: "n2", IP: "203.0.113.20", Region: "JP", Enabled: false, Status: "online", LatencyMs: 1},
		{ID: "n3", IP: "203.0.113.30", Region: "US", Enabled: true, Status: "online", LatencyMs: 1},
	}
	got := regionCandidates(nodes, model.Rule{Region: "JP"})
	if len(got) != 1 || got[0].NodeIP != "203.0.113.10" {
		t.Fatalf("regionCandidates = %+v want only enabled JP n1", got)
	}
	// Explicit NodeID / CustomIP / nameserver rules pin one target: no candidates.
	if got := regionCandidates(nodes, model.Rule{Region: "JP", NodeID: "n1"}); got != nil {
		t.Fatalf("node-pinned rule candidates = %v want nil", got)
	}
	if got := regionCandidates(nodes, model.Rule{Region: "JP", CustomIP: "203.0.113.99"}); got != nil {
		t.Fatalf("custom-ip rule candidates = %v want nil", got)
	}
	if got := regionCandidates(nodes, model.Rule{Region: "JP", Mode: "nameserver", Nameserver: "1.1.1.1"}); got != nil {
		t.Fatalf("nameserver rule candidates = %v want nil", got)
	}
}
