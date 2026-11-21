package panel

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"dnsunlock/internal/model"
	"dnsunlock/internal/store"
)

// TestAgentConfigKeepsUnresolvableRules (V016-16): a rule the panel
// cannot resolve to any IP (bbciplayer -> GB, zero nodes, no default
// unlock IP) must still reach the agent config — with an empty NodeIP
// — instead of being silently dropped. Dropping it makes `dnsunlock
// check` print NO_RULES, indistinguishable from "no rules set at all".
func TestAgentConfigKeepsUnresolvableRules(t *testing.T) {
	st, err := store.New(filepath.Join(t.TempDir(), "panel.json"))
	if err != nil {
		t.Fatalf("store.New: %v", err)
	}
	srv, err := New(st, "", t.TempDir())
	if err != nil {
		t.Fatalf("panel.New: %v", err)
	}
	_ = st.Update(func(d *store.Data) (bool, error) {
		d.Servers = []model.DNSServer{{ID: "srv-1", Name: "hk", Token: "tok-1"}}
		if d.Rules == nil {
			d.Rules = map[string]model.Rule{}
		}
		d.Rules["bbciplayer"] = model.Rule{PlatformID: "bbciplayer", Region: "GB"}
		return false, nil
	})
	req := httptest.NewRequest(http.MethodGet, "/api/v1/agent/config?server_id=srv-1", nil)
	req.Header.Set("X-Agent-Token", "tok-1")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("agent config status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var cfg model.AgentConfig
	if err := json.NewDecoder(rec.Body).Decode(&cfg); err != nil {
		t.Fatalf("decode agent config: %v", err)
	}
	for _, r := range cfg.Rules {
		if r.PlatformID == "bbciplayer" {
			if r.NodeIP != "" {
				t.Fatalf("bbciplayer NodeIP = %q, want empty (no GB node exists)", r.NodeIP)
			}
			if len(r.Domains) == 0 {
				t.Fatalf("bbciplayer rule kept but has no domains")
			}
			return
		}
	}
	t.Fatalf("bbciplayer rule missing from agent config (rules=%v); check would print NO_RULES", cfg.Rules)
}
