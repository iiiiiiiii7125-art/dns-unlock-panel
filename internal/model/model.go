package model

// Region is one unlock country/region.
type Region struct {
	Code string `json:"code"`
	Name string `json:"name"` // Chinese name
}

// Regions: 34 supported unlock regions (code -> Chinese name).
// Covers the AKDNS-style set (HK/MO/TW/JP/KR/SG/US/DE/GB/IT/NL) plus
// CA/AU/FR/IN/BR/ID/TH/MY/PH/VN/TR/AR/MX/ZA/AE.
var Regions = []Region{
	{"HK", "香港"}, {"MO", "澳门"}, {"TW", "台湾"}, {"JP", "日本"}, {"KR", "韩国"},
	{"US", "美国"}, {"GB", "英国"}, {"SG", "新加坡"}, {"DE", "德国"},
	{"FR", "法国"}, {"NL", "荷兰"}, {"IT", "意大利"}, {"CA", "加拿大"}, {"AU", "澳大利亚"},
	{"IN", "印度"}, {"BR", "巴西"}, {"ID", "印尼"}, {"TH", "泰国"},
	{"MY", "马来西亚"}, {"PH", "菲律宾"}, {"VN", "越南"}, {"TR", "土耳其"},
	{"AR", "阿根廷"}, {"MX", "墨西哥"}, {"ZA", "南非"}, {"AE", "阿联酋"},
	{"AT", "奥地利"}, {"DK", "丹麦"}, {"ES", "西班牙"}, {"FI", "芬兰"},
	{"NO", "挪威"}, {"NZ", "新西兰"}, {"PL", "波兰"}, {"SE", "瑞典"},
}

// RegionPriority is the failover order when a region has no healthy node.
var RegionPriority = []string{"HK", "JP", "SG", "TW", "US", "KR", "GB", "DE", "NL", "CA", "AU", "FR", "IN", "BR", "TH", "ID", "MY", "PH", "VN", "TR", "MX", "AR", "ZA", "AE", "MO", "IT", "AT", "DK", "ES", "FI", "NO", "NZ", "PL", "SE"}

// CategoryOrder pins the three main uses first in the UI
// (流媒体 / AI 服务 / 社交与娱乐), then the regional zones, then 其他.
var CategoryOrder = []string{"流媒体", "AI 服务", "社交与娱乐", "日本专区", "台湾专区", "香港专区", "其他"}

func CategoryRank(c string) int {
	for i, x := range CategoryOrder {
		if x == c {
			return i
		}
	}
	return len(CategoryOrder)
}

// Popularity tiers: rules are sorted by tier, NOT alphabetically.
// Tier 1 = most-used (Netflix/YouTube/Disney+/ChatGPT/TikTok/...),
// Tier 2 = next tier, Tier 3 = regional zones + long tail.
var Tier1 = []string{
	"netflix", "youtube-premium", "disneyplus", "chatgpt", "tiktok",
	"spotify", "hbomax", "claude", "gemini", "instagram",
	"primevideo", "hulu",
}

var Tier2 = []string{
	"facebook", "x", "dazn", "paramountplus", "appletv", "peacock",
	"bbciplayer", "crunchyroll", "sora", "copilot", "reddit",
	"whatsapp", "telegram", "threads", "youtube", "discord",
	"linkedin", "grok", "midjourney", "perplexity", "meta-ai",
	"notion-ai", "cursor", "runway", "leonardo", "character-ai", "poe",
}

func TierOf(id string) int {
	for _, x := range Tier1 {
		if x == id {
			return 1
		}
	}
	for _, x := range Tier2 {
		if x == id {
			return 2
		}
	}
	return 3
}

// PublicSource is a third-party SmartDNS / unlock service template.
// There is NO universal public unlock IP: every one of these requires
// registering, binding your own IP, and then they assign you a DNS IP.
// The panel stores ONLY the DNS IP the user pastes in after registering.
// Never hard-code a supposed "public unlock IP" — it does not exist.
type PublicSource struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Website   string `json:"website"`
	FreeQuota string `json:"free_quota"`
	Regions   string `json:"regions"`
	Note      string `json:"note"`
	DNSIP     string `json:"dns_ip,omitempty"` // filled by the user after registering
}

var PublicSources = []PublicSource{
	{ID: "alice", Name: "Alice", Website: "https://app.alice.ws", FreeQuota: "免费个人最多 5 个 IP", Regions: "多地区", Note: "注册后绑定自己的 IP, 再把分配的 DNS IP 填进来, 规则里用 nameserver 模式走它。"},
	{ID: "akdns", Name: "AKDNS", Website: "https://dns.akile.ai", FreeQuota: "Beta 免费, 非 Akile 用户最多 10 个 IP", Regions: "香港/台湾/日本/韩国/新加坡/美国/德国/英国/意大利/荷兰等约 18 个地区", Note: "注册后绑定自己的 IP, 再把分配的 DNS IP 填进来, 规则里用 nameserver 模式走它。"},
	{ID: "smartdnsproxy", Name: "SmartDNSProxy", Website: "https://www.smartdnsproxy.com", FreeQuota: "14 天试用", Regions: "多地区", Note: "商业服务, 需自行注册付费; 试用/订阅后把分配的 DNS IP 填进来。"},
	{ID: "getflix", Name: "Getflix", Website: "https://www.getflix.com.au", FreeQuota: "付费, 无免费档", Regions: "多地区", Note: "商业 SmartDNS, 需自行注册付费; 把分配的 DNS IP 填进来。"},
	{ID: "unlocator", Name: "Unlocator", Website: "https://unlocator.com", FreeQuota: "付费, 有试用", Regions: "多地区", Note: "商业 SmartDNS, 需自行注册付费; 把分配的 DNS IP 填进来。"},
}

func RegionValid(code string) bool {
	for _, r := range Regions {
		if r.Code == code {
			return true
		}
	}
	return false
}

func RegionName(code string) string {
	for _, r := range Regions {
		if r.Code == code {
			return r.Name
		}
	}
	return code
}

// Platform is one entry of the built-in catalogue (data/platforms.json).
type Platform struct {
	ID               string   `json:"id"`
	Name             string   `json:"name"`
	NameZh           string   `json:"name_zh"`
	Category         string   `json:"category"`
	RegionsAvailable []string `json:"regions_available"`
	Domains          []string `json:"domains"`
	Tier             int      `json:"tier,omitempty"` // popularity tier 1-3, set by the panel
}

// Node is an unlock IP record: {name, ip, region (label only), note}.
// NOTHING needs to be installed on this machine. It is just an IP the
// panel may return in DNS answers. Traffic for a platform is answered
// with this IP; what happens next depends on the service behind the IP.
// (Optional: run `dnsunlock sni-proxy` on a VPS you own to turn it into
// a real unlock node — see scripts/install-unlock-node.sh.)
type Node struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	IP        string `json:"ip"`
	Region    string `json:"region"`
	Port      int    `json:"port"` // probe port, default 443 (TCP dial only)
	Enabled   bool   `json:"enabled"`
	Status    string `json:"status"`     // unknown | online | offline (TCP :443 probe only)
	LatencyMs int64  `json:"latency_ms"` // last probe RTT, -1 = failed
	Note      string `json:"note"`
	LastSeen  string `json:"last_seen,omitempty"`
}

// Rule maps one platform to one unlock IP.
// Resolution order (first non-empty wins):
//  1. NodeID  — pick an IP record already saved in the panel
//  2. CustomIP — a free-form IP typed directly on this rule
//  3. Region  — auto-pick the first enabled IP record in that region
//
// A node is ONLY an IP record {name, ip, region, note}: nothing has to be
// installed on that machine. The panel only rewrites DNS to return this IP;
// whether the IP can actually unlock the platform depends on whatever
// service already runs behind it (SNI proxy / unlock service). The panel
// cannot magically give an arbitrary IP unlocking ability.
type Rule struct {
	PlatformID string `json:"platform_id"`
	NodeID     string `json:"node_id,omitempty"`
	Region     string `json:"region,omitempty"`
	CustomIP   string `json:"custom_ip,omitempty"`
	// BackupIP + AutoFailover: only when the user explicitly enables
	// failover on THIS rule does the agent switch to BackupIP after
	// 2 consecutive TCP :443 probe failures. Otherwise a failed probe
	// only marks the node red in the panel; the rule is untouched.
	BackupIP     string `json:"backup_ip,omitempty"`
	AutoFailover bool   `json:"auto_failover,omitempty"`
	// PreferFastest: when the rule names a region with several enabled
	// nodes, pick the healthy node with the lowest probe latency
	// instead of the first online one. Default off, on purpose:
	// explicit choice wins — probe latency measures the agent-to-node
	// probe path, not the real streaming path, and auto-switching
	// regions would silently void the region the user picked by hand.
	// It only changes the INITIAL pick; AutoFailover (fault switching)
	// is untouched and still governs what happens when the pick dies.
	PreferFastest bool `json:"prefer_fastest,omitempty"`
	// Mode: "address" (默认) = DNS 直接返回解锁 IP;
	// "nameserver" = 把该平台的查询转发到 Nameserver 指定的上游 DNS
	// (如某解锁服务提供的专用 DNS IP)，不改写答案。
	Mode       string `json:"mode,omitempty"`
	Nameserver string `json:"nameserver,omitempty"`
}

// DNSServer is a client VPS running `dnsunlock dns-agent` (DNS on :53).
type DNSServer struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	IP              string `json:"ip"`
	Token           string `json:"token,omitempty"` // per-server agent token (random, never the admin password)
	Allowlist       string `json:"allowlist,omitempty"`
	DefaultUnlockIP string `json:"default_unlock_ip,omitempty"`
	Status          string `json:"status"` // unknown | online | offline
	LastSeen        string `json:"last_seen,omitempty"`
	ConfigVersion   int64  `json:"config_version"`
	// LastSelftest is the newest self-test result this server reported
	// (null when never tested). It holds resolved unlock IPs in full:
	// it is only ever returned on the admin-authenticated servers API.
	LastSelftest *SelftestResult `json:"last_selftest,omitempty"`
}

// FailoverEvent records an automatic node switch. It contains no query data.
type FailoverEvent struct {
	Time     string `json:"time"`
	Region   string `json:"region"`
	Platform string `json:"platform,omitempty"`
	FromNode string `json:"from_node"`
	ToNode   string `json:"to_node"`
	Reason   string `json:"reason"`
	ServerID string `json:"server_id,omitempty"`
}

// AgentConfig is what the panel hands to a dns-agent (polled every 5s).
type AgentConfig struct {
	Version  int64  `json:"version"`
	Upstream string `json:"upstream"`
	// Rules resolved to concrete IPs: each entry is one platform.
	Rules []AgentRule `json:"rules"`
	// SelftestRequest, when set, asks the agent to run one connectivity
	// self-test on its next poll and report back via heartbeat. The
	// panel sends it once (consumed on delivery); the agent dedupes by
	// ID so a repeated delivery never re-runs the same request.
	SelftestRequest *SelftestRequest `json:"selftest_request,omitempty"`
	// DefaultUnlockIP is the fallback when a rule names a region with no
	// enabled node in it (P1-07). It is NOT used for platforms with no
	// rule at all — those stay on upstream. Empty = no fallback.
	DefaultUnlockIP string `json:"default_unlock_ip,omitempty"`
}

type AgentRule struct {
	PlatformID string   `json:"platform_id"`
	Tier       int      `json:"tier,omitempty"`
	Domains    []string `json:"domains"`
	NodeID     string   `json:"node_id"`
	NodeIP     string   `json:"node_ip"`
	Region     string   `json:"region"`
	// BackupIP/AutoFailover are honoured only when AutoFailover is true.
	BackupIP     string `json:"backup_ip,omitempty"`
	AutoFailover bool   `json:"auto_failover,omitempty"`
	// PreferFastest: see Rule.PreferFastest. Only an initial pick; the
	// agent re-picks from Candidates on every 30s health cycle, and
	// AutoFailover still owns fault switching. Default false.
	PreferFastest bool `json:"prefer_fastest,omitempty"`
	// Candidates: enabled nodes in the rule's region (region rules
	// only), so the agent can re-pick the fastest healthy one from its
	// own probe data instead of trusting the panel's stored latency.
	Candidates []NodeCandidate `json:"candidates,omitempty"`
	// Mode "address" (default) or "nameserver"; Nameserver is the upstream
	// DNS IP used in nameserver mode (answer is relayed, not rewritten).
	Mode       string `json:"mode,omitempty"`
	Nameserver string `json:"nameserver,omitempty"`
}

// NodeCandidate is one region node the agent may pick from when a rule
// has PreferFastest on. LatencyMs is the panel's last stored probe
// latency (-1 = failed/unknown); Status is online/offline/unknown.
type NodeCandidate struct {
	NodeID    string `json:"node_id"`
	NodeIP    string `json:"node_ip"`
	LatencyMs int64  `json:"latency_ms"`
	Status    string `json:"status"`
}

// AgentHeartbeat is posted by dns-agent; carries health only, never queries.
type AgentHeartbeat struct {
	ServerID string          `json:"server_id"`
	Nodes    []NodeHealth    `json:"nodes,omitempty"`
	Events   []FailoverEvent `json:"events,omitempty"`
	Counters AgentCounters   `json:"counters,omitempty"`
	// SelftestResult carries the result of a SelftestRequest the panel
	// sent earlier (sent once, with the next heartbeat after the run).
	SelftestResult *SelftestResult `json:"selftest_result,omitempty"`
}

// SelftestRequest asks one agent to run a connectivity self-test.
// Delivered inside AgentConfig; reported back in AgentHeartbeat.
type SelftestRequest struct {
	ID          string `json:"id"`
	RequestedAt string `json:"requested_at"` // RFC3339 UTC
}

// SelftestResultItem is one platform's row: domain -> resolved IP -> ok?
// The UI lists these verbatim, one row per platform with a rule.
type SelftestResultItem struct {
	PlatformID string `json:"platform_id"`
	Domain     string `json:"domain"`
	ResolvedIP string `json:"resolved_ip"`
	OK         bool   `json:"ok"`
	LatencyMs  int64  `json:"latency_ms"` // probe RTT ms; -1 = not measured
	Error      string `json:"error,omitempty"`
}

// SelftestResult is the agent's answer to one SelftestRequest.
// NOTE: this is a connectivity check only (DNS resolves + TCP :443/TLS
// answers). It does NOT prove the streaming service accepts the traffic.
type SelftestResult struct {
	RequestID string               `json:"request_id"`
	RanAt     string               `json:"ran_at"` // RFC3339 UTC
	Results   []SelftestResultItem `json:"results"`
}

type NodeHealth struct {
	NodeID    string `json:"node_id"`
	Status    string `json:"status"`
	LatencyMs int64  `json:"latency_ms"`
}

type AgentCounters struct {
	Total       int64            `json:"total"`
	Rewritten   int64            `json:"rewritten"`
	Forwarded   int64            `json:"forwarded"`
	PerPlatform map[string]int64 `json:"per_platform,omitempty"` // platform id -> hits, no client identity
}
