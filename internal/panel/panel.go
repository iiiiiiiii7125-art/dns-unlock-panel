package panel

import (
	"context"
	"crypto/rand"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"

	"dnsunlock/internal/model"
	"dnsunlock/internal/store"
)

//go:embed assets/index.html
var indexHTML []byte

//go:embed assets/install.sh
var installSH []byte

//go:embed assets/platforms.json
var platformsJSON []byte

type Server struct {
	store     *store.Store
	distDir   string
	platforms []model.Platform
	// sessions: admin login sessions (in-memory, restart clears them).
	sessMu   sync.Mutex
	sessions map[string]session
	// login attempts per client IP, for brute-force limiting (P2-02).
	attMu    sync.Mutex
	attempts map[string]*loginAttempt
}

type session struct {
	username string
	expires  time.Time
}

type loginAttempt struct {
	count       int
	firstFailed time.Time
	lockedUntil time.Time
}

type ctxKey string

const agentServerKey ctxKey = "agent_server_id"

func randomToken(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// maskIP hides the last two octets of an IPv4 address (1.2.*.*).
// The full IP is only ever returned by the reveal endpoint (admin, on demand)
// or by the agent config endpoint (that server's own token, its own rules).
func maskIP(ip string) string {
	if ip == "" {
		return ""
	}
	if parsed := net.ParseIP(ip); parsed != nil {
		if v4 := parsed.To4(); v4 != nil {
			return fmt.Sprintf("%d.%d.*.*", v4[0], v4[1])
		}
		parts := strings.Split(parsed.String(), ":")
		if len(parts) >= 2 {
			return parts[0] + ":" + parts[1] + ":*:*:*:*:*:*"
		}
	}
	return "****"
}

func maskNode(n model.Node) model.Node {
	n.IP = maskIP(n.IP)
	return n
}

func maskServer(sv model.DNSServer) model.DNSServer {
	sv.IP = maskIP(sv.IP)
	sv.DefaultUnlockIP = maskIP(sv.DefaultUnlockIP)
	sv.Token = ""
	return sv
}

func validIP(ip string) bool { return ip != "" && net.ParseIP(strings.TrimSpace(ip)) != nil }

func validDomain(d string) bool {
	d = strings.ToLower(strings.TrimSpace(strings.TrimSuffix(d, ".")))
	if d == "" || strings.Contains(d, " ") || strings.Contains(d, "_") {
		return false
	}
	labels := strings.Split(d, ".")
	if len(labels) < 2 {
		return false
	}
	for _, l := range labels {
		if l == "" || len(l) > 63 {
			return false
		}
		for _, c := range l {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return false
			}
		}
		if strings.HasPrefix(l, "-") || strings.HasSuffix(l, "-") {
			return false
		}
	}
	return true
}

// validCustomDomain: P1-04 — reject bare TLDs / single labels / over-broad
// well-known 2-label domains that would hijack a whole service family.
var broadCustomDomains = map[string]bool{
	"google.com": true, "apple.com": true, "amazon.com": true,
	"microsoft.com": true, "facebook.com": true, "bbc.com": true, "bing.com": true,
}

func validCustomDomain(d string) (bool, string) {
	if !validDomain(d) {
		return false, "域名格式不对：请填至少两段的域名，如 video.netflix.com"
	}
	if broadCustomDomains[strings.ToLower(d)] {
		return false, "这个域名太宽（会拐走整个服务家族），请填更具体的子域名，如 tv.apple.com"
	}
	return true, ""
}

// New creates the panel server. The old shared PANEL_TOKEN is gone:
// admin login is username+password (default admin/admin, bcrypt-hashed,
// must-change on first login), and each DNS server gets its own random
// agent token. The token argument is kept only for signature compat and
// is ignored.
func New(st *store.Store, _token, distDir string) (*Server, error) {
	var plats []model.Platform
	if err := json.Unmarshal(platformsJSON, &plats); err != nil {
		return nil, fmt.Errorf("parse platforms: %w", err)
	}
	for i := range plats {
		plats[i].Tier = model.TierOf(plats[i].ID)
	}
	s := &Server{store: st, distDir: distDir, platforms: plats,
		sessions: map[string]session{}, attempts: map[string]*loginAttempt{}}
	snap := st.Snapshot()
	if snap.AdminPassHash == "" {
		hash, err := bcrypt.GenerateFromPassword([]byte("admin"), bcrypt.DefaultCost)
		if err != nil {
			return nil, err
		}
		_ = st.Update(func(d *store.Data) (bool, error) {
			d.AdminUsername = "admin"
			d.AdminPassHash = string(hash)
			d.AdminMustChange = true
			return false, nil // admin seed must not bump config version
		})
	}
	s.seedDefaults()
	return s, nil
}

func (s *Server) checkPassword(username, password string) bool {
	snap := s.store.Snapshot()
	if username != snap.AdminUsername || snap.AdminPassHash == "" {
		return false
	}
	return bcrypt.CompareHashAndPassword([]byte(snap.AdminPassHash), []byte(password)) == nil
}

func (s *Server) newSession(username string) string {
	tok := randomToken(32)
	s.sessMu.Lock()
	s.sessions[tok] = session{username: username, expires: time.Now().Add(24 * time.Hour)}
	s.sessMu.Unlock()
	return tok
}

func (s *Server) validSession(r *http.Request) bool {
	tok := r.Header.Get("X-Session-Token")
	if tok == "" {
		if ah := r.Header.Get("Authorization"); strings.HasPrefix(ah, "Bearer ") {
			tok = strings.TrimPrefix(ah, "Bearer ")
		}
	}
	if tok == "" {
		return false
	}
	s.sessMu.Lock()
	defer s.sessMu.Unlock()
	sess, ok := s.sessions[tok]
	if !ok || time.Now().After(sess.expires) {
		delete(s.sessions, tok)
		return false
	}
	return true
}

// handleAgentWhoami maps an agent token to its server id, so the install
// script only needs the token the admin copied from the panel (it never
// needs the admin password, and the token alone cannot list other servers).
func (s *Server) handleAgentWhoami(w http.ResponseWriter, r *http.Request) {
	// N-08: agent token only via the X-Agent-Token header, never via the
	// URL query string (tokens in URLs land in access logs).
	tok := r.Header.Get("X-Agent-Token")
	if tok == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized: agent token required"})
		return
	}
	snap := s.store.Snapshot()
	for _, sv := range snap.Servers {
		if sv.Token != "" && sv.Token == tok {
			writeJSON(w, http.StatusOK, map[string]any{"server_id": sv.ID, "name": sv.Name})
			return
		}
	}
	writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized: bad agent token"})
}

// agentAuth verifies a per-server agent token and pins the request to that
// server only. A token for server A can never fetch server B's config or
// report heartbeats as server B (P0-06).
func (s *Server) agentAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// N-08: agent token only via the X-Agent-Token header.
		tok := r.Header.Get("X-Agent-Token")
		serverID := r.URL.Query().Get("server_id")
		if tok == "" || serverID == "" {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized: agent token and server_id required"})
			return
		}
		snap := s.store.Snapshot()
		ok := false
		for _, sv := range snap.Servers {
			if sv.ID == serverID && sv.Token != "" && sv.Token == tok {
				ok = true
				break
			}
		}
		if !ok {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized: bad agent token for this server"})
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), agentServerKey, serverID)))
	}
}

func agentServerID(r *http.Request) string {
	v, _ := r.Context().Value(agentServerKey).(string)
	return v
}

func (s *Server) seedDefaults() {
	snap := s.store.Snapshot()
	if len(snap.Rules) > 0 || snap.ConfigVersion > 0 {
		return
	}
	// Default rules follow the three main uses:
	// 流媒体 Netflix/Disney+ -> HK, AI ChatGPT -> US, 社交 TikTok -> US.
	// M-01: youtube 与 youtube-premium 共用 youtube.com，种子规则必须指
	// 同一地区（都 HK），否则两条规则解析到不同 IP，面板口径里自带冲突，
	// 用户点保存任一条都会拿 409。agent 侧按 Tier 先赢者定，本来就是
	// youtube-premium（Tier 1）胜出，所以 youtube 指 HK 与实际行为一致。
	defaults := map[string]string{
		"netflix": "HK", "disneyplus": "HK", "hbomax": "US", "hulu": "US",
		"primevideo": "US", "chatgpt": "US", "claude": "US", "gemini": "US",
		"youtube-premium": "HK", "spotify": "US", "tiktok": "US",
		"dazn": "JP", "crunchyroll": "US", "bbciplayer": "GB",
		"instagram": "US", "youtube": "HK",
	}
	_ = s.store.Update(func(d *store.Data) (bool, error) {
		for pid, region := range defaults {
			d.Rules[pid] = model.Rule{PlatformID: pid, Region: region}
		}
		return true, nil
	})
}

func (s *Server) platformByID(id string) (model.Platform, bool) {
	for _, p := range s.platforms {
		if p.ID == id {
			return p, true
		}
	}
	return model.Platform{}, false
}

// resolveIP turns a rule into a concrete IP.
// Order: explicit NodeID -> CustomIP -> first enabled node in Region.
// Returns (ip, nodeID, ok). A rule with only a CustomIP has nodeID "".
func resolveIP(nodes []model.Node, r model.Rule) (string, string, bool) {
	if r.NodeID != "" {
		for _, n := range nodes {
			if n.ID == r.NodeID && n.Enabled {
				return n.IP, n.ID, true
			}
		}
	}
	if r.CustomIP != "" {
		return r.CustomIP, "", true
	}
	if r.Region != "" {
		// PreferFastest: lowest-latency ONLINE node in the region wins
		// the initial pick (LatencyMs comes from the agent's 30s probes,
		// stored on the node by heartbeat). No online node with a
		// measured latency -> fall through to the normal first-online
		// pick below, never to a node already known dead.
		if r.PreferFastest {
			best := -1
			for i, n := range nodes {
				if n.Region == r.Region && n.Enabled && n.Status == "online" && n.LatencyMs >= 0 {
					if best < 0 || n.LatencyMs < nodes[best].LatencyMs {
						best = i
					}
				}
			}
			if best >= 0 {
				return nodes[best].IP, nodes[best].ID, true
			}
		}
		var fallback *model.Node
		for i, n := range nodes {
			if n.Region == r.Region && n.Enabled {
				if n.Status == "online" {
					return n.IP, n.ID, true
				}
				if fallback == nil {
					fallback = &nodes[i]
				}
			}
		}
		if fallback != nil {
			return fallback.IP, fallback.ID, true
		}
	}
	return "", "", false
}

// regionCandidates lists the enabled nodes in a region rule's region so
// the agent can re-pick the fastest healthy one from its own probe data.
// Only for region-only rules (explicit NodeID/CustomIP already pin one IP,
// nameserver rules have no node IP at all). Empty = no choice to make.
func regionCandidates(nodes []model.Node, r model.Rule) []model.NodeCandidate {
	if r.Region == "" || r.NodeID != "" || r.CustomIP != "" || r.Mode == "nameserver" {
		return nil
	}
	var out []model.NodeCandidate
	for _, n := range nodes {
		if n.Region == r.Region && n.Enabled {
			out = append(out, model.NodeCandidate{NodeID: n.ID, NodeIP: n.IP, LatencyMs: n.LatencyMs, Status: n.Status})
		}
	}
	return out
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/install.sh", s.handleInstallScript)
	mux.HandleFunc("/dl/", s.handleDownload)
	mux.HandleFunc("/api/v1/login", s.handleLogin)
	mux.HandleFunc("/api/v1/logout", s.auth(s.handleLogout))
	mux.HandleFunc("/api/v1/change-password", s.auth(s.handleChangePassword))
	mux.HandleFunc("/api/v1/status", s.auth(s.handleStatus))
	mux.HandleFunc("/api/v1/regions", s.auth(s.handleRegions))
	mux.HandleFunc("/api/v1/platforms", s.auth(s.handlePlatforms))
	mux.HandleFunc("/api/v1/nodes", s.auth(s.handleNodes))
	mux.HandleFunc("/api/v1/nodes/", s.auth(s.handleNodeByID))
	mux.HandleFunc("/api/v1/rules", s.auth(s.handleRules))
	mux.HandleFunc("/api/v1/servers", s.auth(s.handleServers))
	mux.HandleFunc("/api/v1/servers/", s.auth(s.handleServerByID))
	mux.HandleFunc("/api/v1/events", s.auth(s.handleEvents))
	mux.HandleFunc("/api/v1/agent/config", s.agentAuth(s.handleAgentConfig))
	mux.HandleFunc("/api/v1/agent/heartbeat", s.agentAuth(s.handleHeartbeat))
	mux.HandleFunc("/api/v1/agent/whoami", s.handleAgentWhoami)
	mux.HandleFunc("/api/v1/custom-domains", s.auth(s.handleCustomDomains))
	mux.HandleFunc("/api/v1/checks", s.auth(s.handleChecks))
	mux.HandleFunc("/api/v1/public-sources", s.auth(s.handlePublicSources))
	return mux
}

func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.validSession(r) {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized: please log in"})
			return
		}
		// N-06: a must-change session (default admin password, first
		// login) may only change the password or log out. The default
		// password must not be usable for any management API.
		if s.store.Snapshot().AdminMustChange && r.URL.Path != "/api/v1/change-password" && r.URL.Path != "/api/v1/logout" {
			writeJSON(w, http.StatusForbidden, map[string]any{"error": "must_change_password: 请先修改默认密码", "must_change": true})
			return
		}
		next(w, r)
	}
}

// clientIP returns the client address used for login rate limiting.
// N-07: X-Forwarded-For is trusted ONLY when the connection comes from a
// loopback reverse proxy (our Caddy setup runs on the same box). A direct
// client can forge the header and dodge the lockout otherwise. And when
// trusted, the LAST entry is used: a reverse proxy appends the real peer
// IP at the end, so the first entry is still attacker-controlled.
//
// M-05 (scope fixed 2026-11-20: server install only, no Cloudflare):
// only two deployments are supported, and the lock key in each is:
//   - direct (browser -> panel :8080): the TCP peer IP. XFF is ignored.
//   - single loopback reverse proxy (Caddy on the same box -> panel):
//     the LAST XFF entry (Caddy appends the real peer IP at the end).
// A double reverse proxy (e.g. Cloudflare -> Caddy -> panel) is NOT
// supported in this version: the last XFF entry there is the outer
// proxy's egress IP, so all users behind the same egress would share
// one lock and one person's 5 bad passwords would lock the others out
// for 60s. That case is deliberately not fixed here — the user does not
// use Cloudflare — and no CF-Connecting-IP trust is added, because that
// header is forgeable by anyone who reaches Caddy directly.
func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	if host == "127.0.0.1" || host == "::1" {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			return strings.TrimSpace(parts[len(parts)-1])
		}
	}
	return host
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	ip := clientIP(r)
	s.attMu.Lock()
	att, ok := s.attempts[ip]
	if !ok {
		att = &loginAttempt{}
		s.attempts[ip] = att
	}
	if time.Now().Before(att.lockedUntil) {
		s.attMu.Unlock()
		writeJSON(w, http.StatusTooManyRequests, map[string]any{"error": "登录失败次数过多，请 60 秒后再试"})
		return
	}
	s.attMu.Unlock()
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := readJSON(r, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	if !s.checkPassword(body.Username, body.Password) {
		s.attMu.Lock()
		att.count++
		if att.count == 1 {
			att.firstFailed = time.Now()
		}
		if att.count >= 5 {
			att.lockedUntil = time.Now().Add(60 * time.Second)
			att.count = 0
		}
		s.attMu.Unlock()
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "用户名或密码错误"})
		return
	}
	s.attMu.Lock()
	delete(s.attempts, ip)
	s.attMu.Unlock()
	snap := s.store.Snapshot()
	writeJSON(w, http.StatusOK, map[string]any{
		"session_token": s.newSession(body.Username),
		"must_change":   snap.AdminMustChange,
		"username":      snap.AdminUsername,
	})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	tok := r.Header.Get("X-Session-Token")
	if tok == "" {
		if ah := r.Header.Get("Authorization"); strings.HasPrefix(ah, "Bearer ") {
			tok = strings.TrimPrefix(ah, "Bearer ")
		}
	}
	s.sessMu.Lock()
	delete(s.sessions, tok)
	s.sessMu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleChangePassword(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		OldPassword string `json:"old_password"`
		NewPassword string `json:"new_password"`
	}
	if err := readJSON(r, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	if len(body.NewPassword) < 6 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "新密码至少 6 位"})
		return
	}
	// The session already proves identity; still verify the old password
	// so a borrowed session alone cannot lock the owner out.
	snap := s.store.Snapshot()
	if bcrypt.CompareHashAndPassword([]byte(snap.AdminPassHash), []byte(body.OldPassword)) != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "旧密码不对"})
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(body.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	_ = s.store.Update(func(d *store.Data) (bool, error) {
		d.AdminPassHash = string(hash)
		d.AdminMustChange = false
		return false, nil
	})
	// Invalidate all sessions: the old password (and any borrowed session)
	// must stop working immediately (P0-02).
	s.sessMu.Lock()
	s.sessions = map[string]session{}
	s.sessMu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func readJSON(r *http.Request, v any) error {
	defer r.Body.Close()
	return json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(v)
}

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(indexHTML)
}

func (s *Server) handleInstallScript(w http.ResponseWriter, r *http.Request) {
	// Public, but contains NO secret: only the panel URL is baked in.
	// The per-server agent token is entered by the installer at run time
	// (prompted, never printed in logs) — never baked into this script (P0-03).
	scheme := "http"
	if r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https" {
		scheme = "https"
	}
	panelURL := fmt.Sprintf("%s://%s", scheme, r.Host)
	script := strings.ReplaceAll(string(installSH), "__PANEL_URL__", panelURL)
	w.Header().Set("Content-Type", "text/x-shellscript; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(script))
}

func (s *Server) handleDownload(w http.ResponseWriter, r *http.Request) {
	// /dl/dnsunlock-linux-amd64 and /dl/dnsunlock-linux-amd64.sha256
	name := strings.TrimPrefix(r.URL.Path, "/dl/")
	if strings.Contains(name, "/") || strings.Contains(name, "..") {
		http.NotFound(w, r)
		return
	}
	// Download endpoint: the binary needs an admin session OR a valid
	// per-server agent token; sha256 stays open (it is only a checksum).
	// Three credential kinds are separate: panel session, agent token,
	// and (for the binary) either of those — never one shared token (P0-06).
	if !strings.HasSuffix(name, ".sha256") {
		allowed := s.validSession(r)
		if !allowed {
			// N-08: agent token only via header, never via query string.
			tok := r.Header.Get("X-Agent-Token")
			if tok != "" {
				snap := s.store.Snapshot()
				for _, sv := range snap.Servers {
					if sv.Token != "" && sv.Token == tok {
						allowed = true
						break
					}
				}
			}
		}
		if !allowed {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized: log in, or use a per-server agent token"})
			return
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	p := filepath.Join(s.distDir, name)
	f, err := os.Open(p)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "not found: " + name + " (build dist/ first)"})
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	_, _ = io.Copy(w, f)
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	snap := s.store.Snapshot()
	online := 0
	for _, n := range snap.Nodes {
		if n.Status == "online" {
			online++
		}
	}
	serversOnline := 0
	for _, sv := range snap.Servers {
		if sv.Status == "online" {
			serversOnline++
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"nodes_total": len(snap.Nodes), "nodes_online": online,
		"platforms_total": len(s.platforms), "rules_total": len(snap.Rules),
		"servers_total": len(snap.Servers), "servers_online": serversOnline,
		"config_version": snap.ConfigVersion, "upstream": snap.Upstream,
	})
}

func (s *Server) handleRegions(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, model.Regions)
}

func (s *Server) handlePlatforms(w http.ResponseWriter, r *http.Request) {
	q := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
	cat := r.URL.Query().Get("category")
	out := []model.Platform{}
	for _, p := range s.platforms {
		if cat != "" && p.Category != cat {
			continue
		}
		if q != "" && !strings.Contains(strings.ToLower(p.Name+" "+p.NameZh+" "+p.ID), q) {
			continue
		}
		out = append(out, p)
	}
	writeJSON(w, http.StatusOK, out)
}

// ---- nodes ----

func (s *Server) handleNodes(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		snap := s.store.Snapshot()
		out := []model.Node{}
		for _, n := range snap.Nodes {
			out = append(out, maskNode(n))
		}
		writeJSON(w, http.StatusOK, out)
	case http.MethodPost:
		var n model.Node
		if err := readJSON(r, &n); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
			return
		}
		if !validIP(n.IP) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "ip 格式不对：请填有效的 IPv4/IPv6 地址"})
			return
		}
		if n.Region == "" || !model.RegionValid(n.Region) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "region 无效：请从地区列表里选"})
			return
		}
		if n.Port < 0 || n.Port > 65535 {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "port 必须在 0-65535 之间"})
			return
		}
		if n.Port == 0 {
			n.Port = 443
		}
		if n.ID == "" {
			n.ID = store.NewID("node")
		}
		n.Enabled = true
		if n.Status == "" {
			n.Status = "unknown"
		}
		n.LatencyMs = -1
		err := s.store.Update(func(d *store.Data) (bool, error) {
			d.Nodes = append(d.Nodes, n)
			return true, nil
		})
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusCreated, maskNode(n))
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleNodeByID(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/api/v1/nodes/")
	// GET /api/v1/nodes/{id}/reveal — admin only, on demand, returns the full IP.
	if r.Method == http.MethodGet && strings.HasSuffix(id, "/reveal") {
		nid := strings.TrimSuffix(id, "/reveal")
		snap := s.store.Snapshot()
		for _, n := range snap.Nodes {
			if n.ID == nid {
				writeJSON(w, http.StatusOK, map[string]any{"id": n.ID, "ip": n.IP})
				return
			}
		}
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "node not found"})
		return
	}
	switch r.Method {
	case http.MethodPut:
		var upd struct {
			Name    string `json:"name"`
			IP      string `json:"ip"`
			Region  string `json:"region"`
			Port    int    `json:"port"`
			Enabled *bool  `json:"enabled"`
			Note    string `json:"note"`
		}
		if err := readJSON(r, &upd); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
			return
		}
		if upd.IP != "" && !validIP(upd.IP) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "ip 格式不对"})
			return
		}
		if upd.Region != "" && !model.RegionValid(upd.Region) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "region 无效"})
			return
		}
		var out model.Node
		found := false
		_ = s.store.Update(func(d *store.Data) (bool, error) {
			for i, n := range d.Nodes {
				if n.ID == id {
					// P2-08: only bump config version when something that
					// changes resolution changed (IP / region / enabled).
					// Renaming or editing a note must not push a new
					// config to every agent.
					changed := false
					if upd.Name != "" {
						d.Nodes[i].Name = upd.Name
					}
					if upd.IP != "" && upd.IP != d.Nodes[i].IP {
						d.Nodes[i].IP = upd.IP
						changed = true
					}
					if upd.Region != "" && upd.Region != d.Nodes[i].Region {
						d.Nodes[i].Region = upd.Region
						changed = true
					}
					if upd.Port != 0 {
						d.Nodes[i].Port = upd.Port
					}
					// P1-08: only change Enabled when the client actually sent it.
					if upd.Enabled != nil && *upd.Enabled != d.Nodes[i].Enabled {
						d.Nodes[i].Enabled = *upd.Enabled
						changed = true
					}
					if upd.Note != "" {
						d.Nodes[i].Note = upd.Note
					}
					out = maskNode(d.Nodes[i])
					found = true
					return changed, nil
				}
			}
			return false, nil
		})
		if !found {
			writeJSON(w, http.StatusNotFound, map[string]any{"error": "node not found"})
			return
		}
		writeJSON(w, http.StatusOK, out)
	case http.MethodDelete:
		_ = s.store.Update(func(d *store.Data) (bool, error) {
			for i, n := range d.Nodes {
				if n.ID == id {
					d.Nodes = append(d.Nodes[:i], d.Nodes[i+1:]...)
					return true, nil
				}
			}
			return false, nil
		})
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

// lastOctetLabel identifies an IP in a conflict message without leaking
// it: only the last octet (IPv4) / last group (IPv6) is shown.
func lastOctetLabel(ip string) string {
	if p := net.ParseIP(strings.TrimSpace(ip)); p != nil {
		if v4 := p.To4(); v4 != nil {
			return fmt.Sprintf("*.*.*.%d", v4[3])
		}
		parts := strings.Split(p.String(), ":")
		return "*:" + parts[len(parts)-1]
	}
	return "?"
}

// describeRuleTarget names a rule's unlock target for conflict messages
// (N-10): node name + region, or a partially-masked custom IP — never two
// identical masked IPs the user cannot tell apart.
func describeRuleTarget(snap store.Data, r model.Rule) string {
	if r.Mode == "nameserver" {
		return "nameserver 上游 " + lastOctetLabel(r.Nameserver)
	}
	if r.NodeID != "" {
		for _, n := range snap.Nodes {
			if n.ID == r.NodeID {
				return "节点 " + n.Name + "（" + n.Region + "）"
			}
		}
		return "节点 " + r.NodeID
	}
	if r.CustomIP != "" {
		return "自定义 IP " + lastOctetLabel(r.CustomIP)
	}
	if r.Region != "" {
		// Region-only rule: describe the node it actually resolves to,
		// not just the region — otherwise two same-region rules read the same.
		if ip, nid, ok := resolveIP(snap.Nodes, r); ok {
			for _, n := range snap.Nodes {
				if n.ID == nid {
					return "节点 " + n.Name + "（" + n.Region + "）"
				}
			}
			return r.Region + " 地区节点 " + lastOctetLabel(ip)
		}
		return r.Region + " 地区节点"
	}
	return "（未解析）"
}
// Two platforms sharing a domain (e.g. youtube.com) can only resolve to
// one IP in the agent; if the new rule would resolve differently, say so.
func (s *Server) domainConflict(snap store.Data, plat model.Platform, body struct {
	PlatformID   string `json:"platform_id"`
	NodeID       string `json:"node_id"`
	Region       string `json:"region"`
	CustomIP     string `json:"custom_ip"`
	BackupIP     string `json:"backup_ip"`
	AutoFailover bool   `json:"auto_failover"`
	PreferFastest bool  `json:"prefer_fastest"`
	Mode         string `json:"mode"`
	Nameserver   string `json:"nameserver"`
	ServerID     string `json:"server_id"`
	Force        bool   `json:"force"`
}) string {
	newRule := model.Rule{PlatformID: body.PlatformID, NodeID: body.NodeID, Region: body.Region, CustomIP: body.CustomIP, PreferFastest: body.PreferFastest, Mode: body.Mode, Nameserver: body.Nameserver}
	newIP, _, newOK := resolveIP(snap.Nodes, newRule)
	if body.Mode == "nameserver" {
		newIP = "nameserver:" + body.Nameserver
		newOK = true
	}
	if !newOK {
		return ""
	}
	merged := map[string]model.Rule{}
	for k, v := range snap.Rules {
		merged[k] = v
	}
	for _, p := range s.platforms {
		if p.ID == plat.ID {
			continue
		}
		shared := false
		for _, d := range p.Domains {
			for _, d2 := range plat.Domains {
				if strings.EqualFold(d, d2) {
					shared = true
				}
			}
		}
		if !shared {
			continue
		}
		other, has := merged[p.ID]
		if !has {
			continue
		}
		otherIP, _, otherOK := resolveIP(snap.Nodes, other)
		if other.Mode == "nameserver" {
			otherIP, otherOK = "nameserver:"+other.Nameserver, true
		}
		if otherOK && otherIP != newIP {
			return "域名冲突：本平台与 " + p.Name + " 共用域名，现有规则指向 " + describeRuleTarget(snap, other) + "，新规则指向 " + describeRuleTarget(snap, newRule) + "；确认要覆盖请重新保存并勾选强制"
		}
	}
	return ""
}

// ---- rules ----

func (s *Server) handleRules(w http.ResponseWriter, r *http.Request) {
	serverID := r.URL.Query().Get("server_id")
	switch r.Method {
	case http.MethodGet:
		snap := s.store.Snapshot()
		merged := map[string]model.Rule{}
		for k, v := range snap.Rules {
			merged[k] = v
		}
		if serverID != "" {
			for k, v := range snap.ServerRules[serverID] {
				merged[k] = v
			}
		}
		// Return as a list enriched with resolved node.
		out := []map[string]any{}
		for _, p := range s.platforms {
			rule, ok := merged[p.ID]
			entry := map[string]any{"platform": p, "has_rule": ok}
			if ok {
				entry["rule"] = rule
				if ip, nid, ok2 := resolveIP(snap.Nodes, rule); ok2 {
					entry["resolved_ip"] = maskIP(ip)
					for _, n := range snap.Nodes {
						if n.ID == nid {
							entry["node"] = maskNode(n)
							break
						}
					}
				} else if rule.CustomIP != "" {
					entry["resolved_ip"] = maskIP(rule.CustomIP)
				}
			}
			out = append(out, entry)
		}
		sort.Slice(out, func(i, j int) bool {
			pi := out[i]["platform"].(model.Platform)
			pj := out[j]["platform"].(model.Platform)
			if pi.Tier != pj.Tier {
				return pi.Tier < pj.Tier // popularity first, not alphabetical
			}
			if ri, rj := model.CategoryRank(pi.Category), model.CategoryRank(pj.Category); ri != rj {
				return ri < rj // main uses first: 流媒体 / AI 服务 / 社交与娱乐
			}
			return pi.Name < pj.Name
		})
		writeJSON(w, http.StatusOK, out)
	case http.MethodPut:
		var body struct {
			PlatformID   string `json:"platform_id"`
			NodeID       string `json:"node_id"`
			Region       string `json:"region"`
			CustomIP     string `json:"custom_ip"`
			BackupIP     string `json:"backup_ip"`
			AutoFailover bool   `json:"auto_failover"`
			PreferFastest bool  `json:"prefer_fastest"`
			Mode         string `json:"mode"`
			Nameserver   string `json:"nameserver"`
			ServerID     string `json:"server_id"`
			Force        bool   `json:"force"`
		}
		if err := readJSON(r, &body); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
			return
		}
		plat, ok := s.platformByID(body.PlatformID)
		if !ok {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "unknown platform: " + body.PlatformID})
			return
		}
		if body.CustomIP != "" && !validIP(body.CustomIP) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "custom_ip 格式不对：请填有效的 IP 地址"})
			return
		}
		if body.BackupIP != "" && !validIP(body.BackupIP) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "backup_ip 格式不对：请填有效的 IP 地址"})
			return
		}
		if body.Region != "" && !model.RegionValid(body.Region) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "region 无效：请从地区列表里选"})
			return
		}
		if body.Mode == "nameserver" {
			if !validIP(body.Nameserver) {
				writeJSON(w, http.StatusBadRequest, map[string]any{"error": "nameserver 模式需要填有效的上游 DNS IP"})
				return
			}
		} else if body.Mode != "" && body.Mode != "address" {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "mode 只能是 address 或 nameserver"})
			return
		}
		if body.Mode == "nameserver" && body.Nameserver == "" {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "nameserver 模式需要填上游 DNS IP"})
			return
		}
		// P1-02: domain conflict — if this platform shares a domain with
		// another platform whose rule resolves to a different IP, refuse
		// unless the caller confirms (force=true). The agent resolves
		// conflicts deterministically (lowest tier wins), but the panel
		// must not let the user set one silently.
		if !body.Force {
			snap := s.store.Snapshot()
			if conflict := s.domainConflict(snap, plat, body); conflict != "" {
				writeJSON(w, http.StatusConflict, map[string]any{"error": conflict, "conflict": true})
				return
			}
		}
		if body.NodeID == "" && body.Region == "" && body.CustomIP == "" && body.Mode != "nameserver" {
			// Clear rule.
			sid := body.ServerID
			if sid == "" {
				sid = serverID
			}
			_ = s.store.Update(func(d *store.Data) (bool, error) {
				if sid != "" {
					delete(d.ServerRules[sid], body.PlatformID)
				} else {
					delete(d.Rules, body.PlatformID)
				}
				return true, nil
			})
			writeJSON(w, http.StatusOK, map[string]any{"ok": true, "cleared": true})
			return
		}
		rule := model.Rule{PlatformID: body.PlatformID, NodeID: body.NodeID, Region: body.Region, CustomIP: body.CustomIP, BackupIP: body.BackupIP, AutoFailover: body.AutoFailover, PreferFastest: body.PreferFastest, Mode: body.Mode, Nameserver: body.Nameserver}
		sid := body.ServerID
		if sid == "" {
			sid = serverID
		}
		_ = s.store.Update(func(d *store.Data) (bool, error) {
			if sid != "" {
				if d.ServerRules[sid] == nil {
					d.ServerRules[sid] = map[string]model.Rule{}
				}
				d.ServerRules[sid][body.PlatformID] = rule
			} else {
				d.Rules[body.PlatformID] = rule
			}
			return true, nil
		})
		writeJSON(w, http.StatusOK, rule)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

// ---- dns servers ----

func (s *Server) handleServers(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		snap := s.store.Snapshot()
		out := []model.DNSServer{}
		for _, sv := range snap.Servers {
			out = append(out, maskServer(sv))
		}
		writeJSON(w, http.StatusOK, out)
	case http.MethodPost:
		var sv model.DNSServer
		if err := readJSON(r, &sv); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
			return
		}
		if sv.IP != "" && !validIP(sv.IP) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "服务器 ip 格式不对"})
			return
		}
		if sv.DefaultUnlockIP != "" && !validIP(sv.DefaultUnlockIP) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "默认解锁 IP 格式不对：请填有效的 IP 地址"})
			return
		}
		if sv.Allowlist != "" {
			for _, e := range strings.Split(sv.Allowlist, ",") {
				e = strings.TrimSpace(e)
				if e == "" {
					continue
				}
				if _, _, err := net.ParseCIDR(e); err != nil && net.ParseIP(e) == nil {
					writeJSON(w, http.StatusBadRequest, map[string]any{"error": "allowlist 格式不对：请填 IP 或 CIDR，用逗号分隔"})
					return
				}
			}
		}
		if sv.ID == "" {
			sv.ID = store.NewID("srv")
		}
		// Per-server random agent token (P0-02/P0-06). Returned once, in
		// full, in this creation response only; lists mask it.
		sv.Token = randomToken(16)
		if sv.Status == "" {
			sv.Status = "unknown"
		}
		_ = s.store.Update(func(d *store.Data) (bool, error) {
			d.Servers = append(d.Servers, sv)
			return false, nil // registration must not bump config version
		})
		writeJSON(w, http.StatusCreated, sv)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleServerByID(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/api/v1/servers/")
	// GET /api/v1/servers/{id}/reveal — admin only, on demand.
	if r.Method == http.MethodGet && strings.HasSuffix(id, "/reveal") {
		nid := strings.TrimSuffix(id, "/reveal")
		snap := s.store.Snapshot()
		for _, sv := range snap.Servers {
			if sv.ID == nid {
				writeJSON(w, http.StatusOK, map[string]any{"id": sv.ID, "ip": sv.IP, "token": sv.Token, "default_unlock_ip": sv.DefaultUnlockIP})
				return
			}
		}
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "server not found"})
		return
	}
	if r.Method != http.MethodDelete {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	_ = s.store.Update(func(d *store.Data) (bool, error) {
		for i, sv := range d.Servers {
			if sv.ID == id {
				d.Servers = append(d.Servers[:i], d.Servers[i+1:]...)
				delete(d.ServerRules, id)
				return false, nil
			}
		}
		return false, nil
	})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// ---- custom domains ----

// handleCustomDomains: GET returns all; POST {platform_id, domain} adds one;
// DELETE ?platform_id=&domain= removes one. Custom domains are merged into
// the agent config for that platform (minimal-domain principle: users add
// only what they actually need, instead of the panel shipping giant lists).
func (s *Server) handleCustomDomains(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		snap := s.store.Snapshot()
		if snap.CustomDomains == nil {
			snap.CustomDomains = map[string][]string{}
		}
		writeJSON(w, http.StatusOK, snap.CustomDomains)
	case http.MethodPost:
		var body struct {
			PlatformID string `json:"platform_id"`
			Domain     string `json:"domain"`
		}
		if err := readJSON(r, &body); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
			return
		}
		body.Domain = strings.ToLower(strings.TrimSpace(strings.TrimSuffix(body.Domain, ".")))
		if _, ok := s.platformByID(body.PlatformID); !ok {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad platform_id"})
			return
		}
		if ok, msg := validCustomDomain(body.Domain); !ok {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": msg})
			return
		}
		_ = s.store.Update(func(d *store.Data) (bool, error) {
			if d.CustomDomains == nil {
				d.CustomDomains = map[string][]string{}
			}
			for _, x := range d.CustomDomains[body.PlatformID] {
				if x == body.Domain {
					return false, nil
				}
			}
			d.CustomDomains[body.PlatformID] = append(d.CustomDomains[body.PlatformID], body.Domain)
			return true, nil
		})
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case http.MethodDelete:
		pid := r.URL.Query().Get("platform_id")
		dom := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("domain")))
		_ = s.store.Update(func(d *store.Data) (bool, error) {
			out := []string{}
			for _, x := range d.CustomDomains[pid] {
				if x != dom {
					out = append(out, x)
				}
			}
			d.CustomDomains[pid] = out
			return true, nil
		})
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

// ---- unlock self-checks ----

// UnlockCheck is a manual verification recipe, not an automated verdict:
// the panel does not fake a detection result. Each entry tells the user
// exactly how to confirm that platform really unlocks through the DNS.
// (Idea borrowed from yt1988/unlock-check and RegionRestrictionCheck:
// one checklist per service, run against the real service.)
type UnlockCheck struct {
	PlatformID string `json:"platform_id"`
	Name       string `json:"name"`
	Method     string `json:"method"` // what to do
	URL        string `json:"url"`
	Expect     string `json:"expect"` // what "unlocked" looks like
}

var unlockChecks = []UnlockCheck{
	{"netflix", "Netflix", "打开首页并登录，查看是否显示该地区片单而非“不可用”", "https://www.netflix.com/", "能播放且显示对应地区字幕/片单"},
	{"disneyplus", "Disney+", "打开首页并登录，查看地区专属内容是否出现", "https://www.disneyplus.com/", "首页正常加载且无区域错误"},
	{"hbomax", "HBO Max", "打开首页，查看是否进入该地区库", "https://www.max.com/", "能浏览片库而非跳转报错页"},
	{"chatgpt", "ChatGPT", "打开并登录，能正常对话即解锁", "https://chatgpt.com/", "可登录、可对话，无“not available in your country”"},
	{"claude", "Claude", "打开并登录，能正常对话即解锁", "https://claude.ai/", "可登录、可对话"},
	{"gemini", "Google Gemini", "打开并登录，能正常对话即解锁", "https://gemini.google.com/", "可登录、可对话"},
	{"tiktok", "TikTok", "打开首页，视频流是否按目标地区推荐", "https://www.tiktok.com/", "视频正常播放，内容偏向目标地区"},
	{"bbciplayer", "BBC iPlayer", "打开并播放任意节目（需英国 IP）", "https://www.bbc.co.uk/iplayer", "能播放，无“only available in the UK”"},
	{"dazn", "DAZN", "打开首页，查看当地赛事是否列出", "https://www.dazn.com/", "显示目标地区赛事表"},
	{"hulu", "Hulu", "打开首页并登录", "https://www.hulu.com/", "能登录浏览，无区域拦截"},
	{"primevideo", "Prime Video", "打开首页，查看地区片单", "https://www.primevideo.com/", "显示目标地区片单"},
	{"spotify", "Spotify", "打开 Web 播放器并播放", "https://open.spotify.com/", "可播放，无区域限制提示"},
	{"youtube-premium", "YouTube Premium", "打开后查看是否显示 Premium 会员价/标识", "https://www.youtube.com/premium", "显示对应地区 Premium 价格"},
	{"crunchyroll", "Crunchyroll", "打开并播放任意番剧", "https://www.crunchyroll.com/", "能播放，无区域限制"},
	{"bilibili-intl", "Bilibili 国际版", "打开并播放港澳台限定番剧", "https://www.bilibili.tv/", "限定内容可播放"},
}

func (s *Server) handleChecks(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, unlockChecks)
}

// ---- public unlock sources ----

// handlePublicSources: GET returns the built-in templates merged with the
// DNS IP the user pasted in after registering; PUT {id, dns_ip} saves one.
// No template ships a usable IP — every public source assigns one only
// after the user registers and binds their own IP.
func (s *Server) handlePublicSources(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		snap := s.store.Snapshot()
		out := []model.PublicSource{}
		for _, ps := range model.PublicSources {
			ps.DNSIP = snap.PublicSourceIPs[ps.ID]
			out = append(out, ps)
		}
		writeJSON(w, http.StatusOK, out)
	case http.MethodPut:
		var body struct {
			ID    string `json:"id"`
			DNSIP string `json:"dns_ip"`
		}
		if err := readJSON(r, &body); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
			return
		}
		known := false
		for _, ps := range model.PublicSources {
			if ps.ID == body.ID {
				known = true
			}
		}
		if !known {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "unknown source: " + body.ID})
			return
		}
		if body.DNSIP != "" && !validIP(body.DNSIP) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "dns_ip 格式不对：请填有效的 IP 地址"})
			return
		}
		_ = s.store.Update(func(d *store.Data) (bool, error) {
			if d.PublicSourceIPs == nil {
				d.PublicSourceIPs = map[string]string{}
			}
			d.PublicSourceIPs[body.ID] = strings.TrimSpace(body.DNSIP)
			return false, nil // saving a template IP must not bump config version
		})
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	snap := s.store.Snapshot()
	ev := snap.Events
	if ev == nil {
		ev = []model.FailoverEvent{}
	}
	// Newest first.
	for i, j := 0, len(ev)-1; i < j; i, j = i+1, j-1 {
		ev[i], ev[j] = ev[j], ev[i]
	}
	if len(ev) > 100 {
		ev = ev[:100]
	}
	writeJSON(w, http.StatusOK, ev)
}

// ---- agent ----

func (s *Server) handleAgentConfig(w http.ResponseWriter, r *http.Request) {
	// agentAuth already pinned this request to exactly one server (P0-05/P0-06):
	// the caller only ever sees its own rules and its own IPs.
	serverID := agentServerID(r)
	snap := s.store.Snapshot()
	merged := map[string]model.Rule{}
	for k, v := range snap.Rules {
		merged[k] = v
	}
	for k, v := range snap.ServerRules[serverID] {
		merged[k] = v
	}
	cfg := model.AgentConfig{Version: snap.ConfigVersion, Upstream: snap.Upstream}
	var defaultIP string
	for _, sv := range snap.Servers {
		if sv.ID == serverID {
			defaultIP = sv.DefaultUnlockIP
			cfg.DefaultUnlockIP = defaultIP
			break
		}
	}
	// Platforms sorted by popularity tier, then ID: the first platform
	// wins a shared domain, deterministically (P1-02). Later platforms
	// sharing that domain are skipped for that domain only.
	plats := append([]model.Platform{}, s.platforms...)
	sort.Slice(plats, func(i, j int) bool {
		if plats[i].Tier != plats[j].Tier {
			return plats[i].Tier < plats[j].Tier
		}
		return plats[i].ID < plats[j].ID
	})
	seenDomain := map[string]bool{}
	for _, p := range plats {
		rule, ok := merged[p.ID]
		if !ok {
			continue
		}
		domains := append([]string{}, p.Domains...)
		domains = append(domains, snap.CustomDomains[p.ID]...)
		// Deduplicate domains across platforms (first tier wins).
		kept := domains[:0]
		for _, d := range domains {
			dl := strings.ToLower(strings.TrimSuffix(d, "."))
			if seenDomain[dl] {
				continue
			}
			seenDomain[dl] = true
			kept = append(kept, d)
		}
		if len(kept) == 0 {
			continue
		}
		if rule.Mode == "nameserver" {
			if rule.Nameserver == "" {
				continue
			}
			cfg.Rules = append(cfg.Rules, model.AgentRule{
				PlatformID: p.ID, Domains: kept, Mode: "nameserver",
				Nameserver: rule.Nameserver, Region: rule.Region, Tier: p.Tier,
			})
			continue
		}
		ip, nid, ok := resolveIP(snap.Nodes, rule)
		if !ok {
			// P1-07: the server's default unlock IP is the fallback when
			// a rule names a region with no enabled node in it. It is NOT
			// used for platforms with no rule at all (those stay upstream).
			if defaultIP != "" && validIP(defaultIP) {
				ip, nid, ok = defaultIP, "", true
			}
		}
		if !ok || !validIP(ip) {
			continue // no usable IP for that rule: leave platform on upstream
		}
		cfg.Rules = append(cfg.Rules, model.AgentRule{
			PlatformID: p.ID, Domains: kept,
			NodeID: nid, NodeIP: ip, Region: rule.Region, Tier: p.Tier,
			BackupIP: rule.BackupIP, AutoFailover: rule.AutoFailover,
			PreferFastest: rule.PreferFastest, Candidates: regionCandidates(snap.Nodes, rule),
		})
	}
	// Mark server seen.
	if serverID != "" {
		now := time.Now().UTC().Format(time.RFC3339)
		_ = s.store.Update(func(d *store.Data) (bool, error) {
			for i, sv := range d.Servers {
				if sv.ID == serverID {
					d.Servers[i].LastSeen = now
					d.Servers[i].Status = "online"
					d.Servers[i].ConfigVersion = snap.ConfigVersion
					return false, nil
				}
			}
			return false, nil
		})
	}
	writeJSON(w, http.StatusOK, cfg)
}

func (s *Server) handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var hb model.AgentHeartbeat
	if err := readJSON(r, &hb); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	if hb.ServerID != agentServerID(r) {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": "forbidden: heartbeat server_id does not match this agent token"})
		return
	}
	now := time.Now().UTC().Format(time.RFC3339)
	_ = s.store.Update(func(d *store.Data) (bool, error) {
		for _, nh := range hb.Nodes {
			for i, n := range d.Nodes {
				// Agent reports health keyed by unlock IP; match by node
				// id (legacy) or by IP (covers free-form custom IPs).
				if n.ID == nh.NodeID || n.IP == nh.NodeID {
					d.Nodes[i].Status = nh.Status
					d.Nodes[i].LatencyMs = nh.LatencyMs
					d.Nodes[i].LastSeen = now
				}
			}
		}
		for i, sv := range d.Servers {
			if sv.ID == hb.ServerID {
				d.Servers[i].LastSeen = now
				d.Servers[i].Status = "online"
			}
		}
		for _, e := range hb.Events {
			if e.Time == "" {
				e.Time = now
			}
			e.ServerID = hb.ServerID
			d.Events = append(d.Events, e)
		}
		if len(d.Events) > 200 {
			d.Events = d.Events[len(d.Events)-200:]
		}
		return false, nil
	})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
