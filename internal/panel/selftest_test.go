package panel

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"dnsunlock/internal/model"
	"dnsunlock/internal/store"
)

func testPanel(t *testing.T) (http.Handler, string) {
	t.Helper()
	dir := t.TempDir()
	st, err := store.New(filepath.Join(dir, "panel.json"))
	if err != nil {
		t.Fatal(err)
	}
	srv, err := New(st, "", dir)
	if err != nil {
		t.Fatal(err)
	}
	// Log in as admin/admin, change the default password (required before
	// any management API), log in again with the new password.
	h := srv.Handler()
	tok := doLogin(t, h, "admin", "admin")
	doReq(t, h, http.MethodPost, "/api/v1/change-password", tok,
		`{"old_password":"admin","new_password":"newpass123"}`, http.StatusOK)
	return h, doLogin(t, h, "admin", "newpass123")
}

func doLogin(t *testing.T, h http.Handler, user, pass string) string {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/login", bytes.NewBufferString(
		fmt.Sprintf(`{"username":%q,"password":%q}`, user, pass)))
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("login %s: %d %s", user, rec.Code, rec.Body.String())
	}
	var out struct {
		SessionToken string `json:"session_token"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&out); err != nil || out.SessionToken == "" {
		t.Fatalf("login %s: no session token (%v): %s", user, err, rec.Body.String())
	}
	return out.SessionToken
}

func doReq(t *testing.T, h http.Handler, method, path, tok, body string, wantCode int) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	var r *http.Request
	if body != "" {
		r = httptest.NewRequest(method, path, bytes.NewBufferString(body))
	} else {
		r = httptest.NewRequest(method, path, nil)
	}
	if tok != "" {
		r.Header.Set("X-Session-Token", tok)
	}
	h.ServeHTTP(rec, r)
	if rec.Code != wantCode {
		t.Fatalf("%s %s: got %d want %d: %s", method, path, rec.Code, wantCode, rec.Body.String())
	}
	return rec
}

func decode[T any](t *testing.T, rec *httptest.ResponseRecorder) T {
	t.Helper()
	var v T
	if err := json.NewDecoder(rec.Body).Decode(&v); err != nil {
		t.Fatalf("decode response: %v (body %s)", err, rec.Body.String())
	}
	return v
}

// POST selftest -> 201, duplicate -> 409 with the same id, unknown -> 404;
// config delivers the request once; heartbeat stores the result; GET
// /api/v1/servers shows last_selftest.
func TestSelftestEndpoints(t *testing.T) {
	h, sess := testPanel(t)

	// Register a server; the creation response carries its agent token.
	rec := doReq(t, h, http.MethodPost, "/api/v1/servers", sess,
		`{"name":"hk","ip":"203.0.113.5"}`, http.StatusCreated)
	sv := decode[model.DNSServer](t, rec)
	if sv.Token == "" {
		t.Fatalf("created server has no token: %+v", sv)
	}

	// PUT a rule with prefer_fastest: stored and returned.
	rec = doReq(t, h, http.MethodPut, "/api/v1/rules", sess,
		`{"platform_id":"netflix","region":"JP","prefer_fastest":true}`, http.StatusOK)
	rule := decode[model.Rule](t, rec)
	if !rule.PreferFastest || rule.Region != "JP" {
		t.Fatalf("PUT rule returned %+v want prefer_fastest=true region=JP", rule)
	}

	// Queue a self-test.
	rec = doReq(t, h, http.MethodPost, "/api/v1/servers/"+sv.ID+"/selftest", sess, "", http.StatusCreated)
	var queued struct {
		RequestID string `json:"request_id"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&queued); err != nil || queued.RequestID == "" {
		t.Fatalf("selftest queue: no request_id: %s", rec.Body.String())
	}
	// Duplicate while pending: 409 with the same id.
	rec = doReq(t, h, http.MethodPost, "/api/v1/servers/"+sv.ID+"/selftest", sess, "", http.StatusConflict)
	var dup struct {
		RequestID string `json:"request_id"`
	}
	_ = json.NewDecoder(rec.Body).Decode(&dup)
	if dup.RequestID != queued.RequestID {
		t.Fatalf("duplicate selftest request_id = %q want %q (409 must reuse the pending id)", dup.RequestID, queued.RequestID)
	}
	// Unknown server: 404.
	doReq(t, h, http.MethodPost, "/api/v1/servers/no-such/selftest", sess, "", http.StatusNotFound)

	// Agent config delivers the request once, then it is consumed.
	cfgRec := httptest.NewRecorder()
	cfgReq := httptest.NewRequest(http.MethodGet, "/api/v1/agent/config?server_id="+sv.ID, nil)
	cfgReq.Header.Set("X-Agent-Token", sv.Token)
	h.ServeHTTP(cfgRec, cfgReq)
	if cfgRec.Code != http.StatusOK {
		t.Fatalf("agent config: %d %s", cfgRec.Code, cfgRec.Body.String())
	}
	cfg := decode[model.AgentConfig](t, cfgRec)
	if cfg.SelftestRequest == nil || cfg.SelftestRequest.ID != queued.RequestID {
		t.Fatalf("agent config selftest_request = %+v want id %q", cfg.SelftestRequest, queued.RequestID)
	}
	cfgRec2 := httptest.NewRecorder()
	cfgReq2 := httptest.NewRequest(http.MethodGet, "/api/v1/agent/config?server_id="+sv.ID, nil)
	cfgReq2.Header.Set("X-Agent-Token", sv.Token)
	h.ServeHTTP(cfgRec2, cfgReq2)
	cfg2 := decode[model.AgentConfig](t, cfgRec2)
	if cfg2.SelftestRequest != nil {
		t.Fatalf("second agent config still carries selftest_request %+v (must be consumed on delivery)", cfg2.SelftestRequest)
	}

	// Heartbeat reports the result; GET /servers shows it.
	hb := fmt.Sprintf(`{"server_id":%q,"selftest_result":{"request_id":%q,"ran_at":"2026-11-21T00:00:00Z","results":[{"platform_id":"netflix","domain":"www.netflix.com","resolved_ip":"203.0.113.20","ok":true,"latency_ms":12}]}}`,
		sv.ID, queued.RequestID)
	hbRec := httptest.NewRecorder()
	hbReq := httptest.NewRequest(http.MethodPost, "/api/v1/agent/heartbeat?server_id="+sv.ID, bytes.NewBufferString(hb))
	hbReq.Header.Set("X-Agent-Token", sv.Token)
	h.ServeHTTP(hbRec, hbReq)
	if hbRec.Code != http.StatusOK {
		t.Fatalf("heartbeat: %d %s", hbRec.Code, hbRec.Body.String())
	}
	rec = doReq(t, h, http.MethodGet, "/api/v1/servers", sess, "", http.StatusOK)
	servers := decode[[]model.DNSServer](t, rec)
	if len(servers) != 1 {
		t.Fatalf("servers = %d want 1", len(servers))
	}
	ls := servers[0].LastSelftest
	if ls == nil || ls.RequestID != queued.RequestID || len(ls.Results) != 1 ||
		ls.Results[0].Domain != "www.netflix.com" || ls.Results[0].ResolvedIP != "203.0.113.20" || !ls.Results[0].OK {
		t.Fatalf("last_selftest = %+v want the reported result", ls)
	}
}
