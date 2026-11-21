// dnsunlock — akcdn-style no-log DNS split-unlock panel.
//
// Modes:
//
//	dnsunlock panel      web panel + API (default :8080, login admin/admin)
//	dnsunlock dns-agent  DNS server on :53, rewrites platform domains
//	dnsunlock sni-proxy  optional SNI proxy on :443 (turn your own VPS
//	                     into an unlock node; NOT required by the panel)
//
// No-log: the DNS agent and SNI proxy never log queried names, SNI values,
// or client addresses — only aggregate counters.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"dnsunlock/internal/dnsagent"
	"dnsunlock/internal/panel"
	"dnsunlock/internal/sniproxy"
	"dnsunlock/internal/store"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "panel":
		runPanel(os.Args[2:])
	case "dns-agent":
		runAgent(os.Args[2:])
	case "sni-proxy":
		runProxy(os.Args[2:])
	case "check":
		runCheck(os.Args[2:])
	case "version", "-v", "--version":
		fmt.Println("dnsunlock v1.0.0 (MVP)")
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Println(`dnsunlock — 无日志 DNS 分流解锁面板

用法:
  dnsunlock panel      启动控制面板 (默认 :8080)
  dnsunlock dns-agent  启动 DNS 分流服务 (默认 :53)
  dnsunlock sni-proxy  启动 SNI 代理 (默认 :443, 可选)
  dnsunlock check      自测基线: 查每条规则域名并探活 (见下, 供 installer 调用)

环境变量:
  PANEL_ADDR   面板监听地址 (默认 :8080)
  PANEL_DATA   面板数据文件 (默认 ./data/panel.json, 0600)
  PANEL_DIST   二进制分发目录 (默认 ./dist)
  DNS_LISTEN   DNS 监听地址 (默认 :53)
  allowlist    只走 600 配置文件 (--config 里的 allowlist 项),
  命令行与环境变量都不传 (allowlist 进进程列表/环境会被同机其他用户看到)
  PANEL_URL    面板地址, 供 dns-agent 轮询 (默认 http://127.0.0.1:8080)
  DNS_SERVER_ID  本 DNS 服务器在面板中的 id
  DNS_AGENT_TOKEN 每台服务器的 agent token (面板登记时生成, 只放 600 配置文件里; 不要写进命令行, 会进 shell 历史)
  DNS_CONFIG   agent 配置文件 (默认 /etc/dnsunlock/config.json, 含 token 与 allowlist, 0600)
  SNI_LISTEN   SNI 代理监听地址 (默认 :443)

check 模式 (v0.1.6, 供 installer 做接管前后基线对比):
  dnsunlock check --config /etc/dnsunlock/config.json [--via agent|upstream]
  每条已设规则的平台一行:
    <platform_id>\t<domain>\t<resolved_ip>\tOK|FAIL\t<ms|error>
  无规则打印 NO_RULES (exit 0); 全部 OK exit 0; 任一 FAIL exit 1;
  配置/用法错误 exit 2。--via agent 默认走本机 agent (:53 或配置的
  dns_listen); agent 没在跑时每条记 FAIL、exit 1, 不崩溃。
  SNI_CONFIG   SNI 配置文件 (0600, 含 allowlist; 与 dns-agent 一致, 不走命令行)
  HTTP_LISTEN  明文 HTTP 代理监听地址 (默认空 = 禁用; 启用时同样受 allowlist 管)

登录: 面板默认 admin/admin, 首次登录后必须改密码。
凭证分开: 面板登录 / 每台 agent token / 二进制下载, 三套互不通用。`)
}

func runPanel(args []string) {
	fs := flag.NewFlagSet("panel", flag.ExitOnError)
	addr := fs.String("addr", env("PANEL_ADDR", ":8080"), "listen address")
	data := fs.String("data", env("PANEL_DATA", "./data/panel.json"), "data file")
	dist := fs.String("dist", env("PANEL_DIST", "./dist"), "dist dir for /dl")
	_ = fs.Parse(args)

	abs, err := filepath.Abs(*data)
	if err != nil {
		log.Fatal(err)
	}
	st, err := store.New(abs)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	srv, err := panel.New(st, "", *dist)
	if err != nil {
		log.Fatalf("panel: %v", err)
	}
	// Nothing cacheable: API, install script and downloads must never be
	// cached (critical behind Cloudflare) — P2-10 / P1-14.
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") || r.URL.Path == "/install.sh" || strings.HasPrefix(r.URL.Path, "/dl/") {
			w.Header().Set("Cache-Control", "no-store")
		}
		srv.Handler().ServeHTTP(w, r)
	})
	// Never log any credential (P0-03).
	log.Printf("panel listening on %s  data=%s", *addr, abs)
	log.Printf("open http://%s/ and log in as admin (default password admin — change it after first login)", *addr)
	log.Fatal(http.ListenAndServe(*addr, h))
}

type agentFileConfig struct {
	PanelURL   string `json:"panel_url"`
	AgentToken string `json:"agent_token"`
	Token      string `json:"token"` // legacy key, same as agent_token
	ServerID   string `json:"server_id"`
	DNSListen  string `json:"dns_listen"`
	Allowlist  string `json:"allowlist"`
}

// failClosedAllowlist enforces P0-04 at the deployed entry point: an empty
// allowlist refuses to start unless the listener is loopback-only.
func failClosedAllowlist(what, listen string, allowlist []string) {
	if len(allowlist) != 0 {
		return
	}
	host, _, err := splitHost(listen)
	if err == nil && (host == "127.0.0.1" || host == "::1" || host == "localhost") {
		log.Printf("%s: allowlist empty but listening on loopback only (%s) — ok for local testing", what, listen)
		return
	}
	log.Fatalf("%s: refusing to start with an empty allowlist on %s — set the allowlist in the 0600 config file (e.g. \"allowlist\": \"203.0.113.7,192.168.1.0/24\"), or listen on 127.0.0.1 for local testing. An open resolver/proxy will be abused.", what, listen)
}

func splitHost(listen string) (string, string, error) {
	return net.SplitHostPort(listen)
}

func jsonUnmarshal(b []byte, v any) error { return json.Unmarshal(b, v) }

func runAgent(args []string) {
	fs := flag.NewFlagSet("dns-agent", flag.ExitOnError)
	listen := fs.String("listen", env("DNS_LISTEN", ":53"), "DNS listen address")
	panelURL := fs.String("panel", env("PANEL_URL", "http://127.0.0.1:8080"), "panel URL")
	// N-12: no --token flag on purpose. A token on the command line ends
	// up in shell history and the process list; it belongs in the 0600
	// config file (or the DNS_AGENT_TOKEN env var) only.
	token := env("DNS_AGENT_TOKEN", "")
	serverID := fs.String("server-id", env("DNS_SERVER_ID", ""), "this DNS server id in panel")
	// M-03: no --allowlist flag on purpose (same reason as --token in
	// N-12): an allowlist on the command line ends up in the process
	// list, visible to other users on the box. It belongs in the 0600
	// config file only.
	allow := ""
	cfgFile := fs.String("config", env("DNS_CONFIG", ""), "agent config file (0600, contains the agent token and allowlist)")
	_ = fs.Parse(args)
	// Config file wins for secrets: the token never appears on the
	// process command line (P1-10) and the file is 0600.
	if *cfgFile != "" {
		b, err := os.ReadFile(*cfgFile)
		if err != nil {
			log.Fatalf("dns-agent: read config %s: %v", *cfgFile, err)
		}
		var fc agentFileConfig
		if err := jsonUnmarshal(b, &fc); err != nil {
			log.Fatalf("dns-agent: parse config %s: %v", *cfgFile, err)
		}
		if fc.PanelURL != "" {
			*panelURL = fc.PanelURL
		}
		if fc.AgentToken != "" {
			token = fc.AgentToken
		} else if fc.Token != "" {
			token = fc.Token
		}
		if fc.ServerID != "" {
			*serverID = fc.ServerID
		}
		if fc.DNSListen != "" {
			*listen = fc.DNSListen
		}
		if fc.Allowlist != "" {
			allow = fc.Allowlist
		}
	}
	if *serverID == "" {
		log.Fatal("dns-agent: -server-id is required (create the server in the panel first: DNS 服务器 -> 登记服务器, copy its agent token)")
	}
	if token == "" {
		log.Fatal("dns-agent: agent token is required (use --config /etc/dnsunlock/config.json or DNS_AGENT_TOKEN; this is the per-server token from the panel, not the admin password)")
	}
	var allowlist []string
	for _, e := range strings.Split(allow, ",") {
		if strings.TrimSpace(e) != "" {
			allowlist = append(allowlist, strings.TrimSpace(e))
		}
	}
	// N-04: an invalid allowlist entry refuses startup (never silently
	// drop to an open resolver).
	if err := dnsagent.ValidateAllowlist(allowlist); err != nil {
		log.Fatalf("dns-agent: invalid allowlist: %v", err)
	}
	failClosedAllowlist("dns-agent", *listen, allowlist)
	a := dnsagent.New(dnsagent.Config{
		Listen: *listen, PanelURL: *panelURL, Token: token, ServerID: *serverID,
		Allowlist: allowlist,
	})
	log.Printf("dns-agent listening on %s  panel=%s  server=%s", *listen, *panelURL, *serverID)
	log.Fatal(a.Run())
}

// runCheck implements `dnsunlock check` (v0.1.6, installer baseline).
// Exit codes are the contract: 0 all OK / NO_RULES, 1 any FAIL,
// 2 config/usage error. Nothing but the result rows (or NO_RULES)
// goes to stdout — diagnostics go to stderr.
func runCheck(args []string) {
	fs := flag.NewFlagSet("check", flag.ExitOnError)
	cfgFile := fs.String("config", env("DNS_CONFIG", ""), "agent config file (0600, contains the agent token; required)")
	via := fs.String("via", "agent", "how to resolve: agent (this machine's agent DNS) or upstream (panel's upstream directly)")
	_ = fs.Parse(args)
	if *via != "agent" && *via != "upstream" {
		fmt.Fprintf(os.Stderr, "check: --via must be agent or upstream, got %q\n", *via)
		os.Exit(2)
	}
	if *cfgFile == "" {
		fmt.Fprintln(os.Stderr, "check: --config is required (e.g. --config /etc/dnsunlock/config.json)")
		os.Exit(2)
	}
	b, err := os.ReadFile(*cfgFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "check: read config %s: %v\n", *cfgFile, err)
		os.Exit(2)
	}
	var fc agentFileConfig
	if err := jsonUnmarshal(b, &fc); err != nil {
		fmt.Fprintf(os.Stderr, "check: parse config %s: %v\n", *cfgFile, err)
		os.Exit(2)
	}
	token := fc.AgentToken
	if token == "" {
		token = fc.Token
	}
	if token == "" || fc.ServerID == "" {
		fmt.Fprintln(os.Stderr, "check: config must contain agent_token (or token) and server_id")
		os.Exit(2)
	}
	panelURL := fc.PanelURL
	if panelURL == "" {
		panelURL = env("PANEL_URL", "http://127.0.0.1:8080")
	}
	listen := fc.DNSListen
	if listen == "" {
		listen = env("DNS_LISTEN", ":53")
	}
	// V016-18: pass the config file's allowlist through (the old code
	// never read fc.Allowlist, so check warned "no DNS allowlist set"
	// even when one was configured), and suppress the warning outright
	// — check never listens on any port, so the warning is inapplicable
	// in this mode even with an empty allowlist.
	var allowlist []string
	for _, e := range strings.Split(fc.Allowlist, ",") {
		if strings.TrimSpace(e) != "" {
			allowlist = append(allowlist, strings.TrimSpace(e))
		}
	}
	a := dnsagent.New(dnsagent.Config{
		Listen: listen, PanelURL: panelURL, Token: token, ServerID: fc.ServerID,
		Allowlist: allowlist, QuietAllowlistWarning: true,
	})
	results, code, err := a.RunCheck(*via)
	if err != nil {
		fmt.Fprintf(os.Stderr, "check: %v\n", err)
		os.Exit(2)
	}
	if len(results) == 0 {
		fmt.Println("NO_RULES")
		os.Exit(0)
	}
	for _, r := range results {
		fmt.Println(r.Line())
	}
	os.Exit(code)
}

// sniFileConfig mirrors agentFileConfig: the SNI proxy reads its
// allowlist from the 0600 config file (N-12), never from the command line.
type sniFileConfig struct {
	SNIListen  string `json:"sni_listen"`
	HTTPListen string `json:"http_listen"`
	Allowlist  string `json:"allowlist"`
}

func runProxy(args []string) {
	fs := flag.NewFlagSet("sni-proxy", flag.ExitOnError)
	tls := fs.String("listen", env("SNI_LISTEN", ":443"), "TLS listen address")
	// N-05: plain HTTP is disabled by default. It used to default to :80
	// on all interfaces with no allowlist check — an open HTTP proxy.
	// Only enable it explicitly, and it is fail-closed like TLS.
	httpDef := ""
	if v, ok := os.LookupEnv("HTTP_LISTEN"); ok {
		httpDef = v
	}
	httpL := fs.String("http", httpDef, "plain HTTP listen address (empty = disabled)")
	// M-03: no --allowlist flag on purpose (same as dns-agent): the
	// allowlist belongs in the 0600 config file only, never on the
	// command line (process list) or in an env var.
	allow := ""
	cfgFile := fs.String("config", env("SNI_CONFIG", ""), "SNI config file (0600, contains the allowlist)")
	_ = fs.Parse(args)
	// Config file wins (N-12): allowlist never appears on the process
	// command line.
	if *cfgFile != "" {
		b, err := os.ReadFile(*cfgFile)
		if err != nil {
			log.Fatalf("sni-proxy: read config %s: %v", *cfgFile, err)
		}
		var fc sniFileConfig
		if err := jsonUnmarshal(b, &fc); err != nil {
			log.Fatalf("sni-proxy: parse config %s: %v", *cfgFile, err)
		}
		if fc.SNIListen != "" {
			*tls = fc.SNIListen
		}
		// http_listen may legitimately be "" (disabled): only override
		// when the key is present in the file.
		var raw map[string]json.RawMessage
		if err := jsonUnmarshal(b, &raw); err == nil {
			if _, ok := raw["http_listen"]; ok {
				*httpL = fc.HTTPListen
			}
		}
		if fc.Allowlist != "" {
			allow = fc.Allowlist
		}
	}
	var allowlist []string
	for _, e := range strings.Split(allow, ",") {
		if strings.TrimSpace(e) != "" {
			allowlist = append(allowlist, strings.TrimSpace(e))
		}
	}
	// N-04: an invalid allowlist entry refuses startup.
	if err := sniproxy.ValidateAllowlist(allowlist); err != nil {
		log.Fatalf("sni-proxy: invalid allowlist: %v", err)
	}
	failClosedAllowlist("sni-proxy", *tls, allowlist)
	// N-05: the HTTP listener gets the same fail-closed check as TLS.
	if *httpL != "" {
		failClosedAllowlist("sni-proxy (http)", *httpL, allowlist)
	}
	p := sniproxy.New(sniproxy.Config{TLSListen: *tls, HTTPListen: *httpL, Allowlist: allowlist})
	log.Printf("sni-proxy listening on %s (http %s)", *tls, *httpL)
	log.Fatal(p.Run())
}
