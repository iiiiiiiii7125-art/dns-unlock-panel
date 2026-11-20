package sniproxy

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"testing"
	"time"
)

// TestProxyEndToEnd: real TLS origin on 127.0.0.1 (random port), the proxy
// on a random port, client handshakes through the proxy with SNI=localhost
// and GETs /. The proxy's dial is redirected to the origin port, so the
// client reaches the origin ONLY via the proxy — proving SNI routing plus
// full byte proxying (handshake AND application data).
func TestProxyEndToEnd(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "localhost"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		DNSNames:     []string{"localhost"},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert := tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}

	originLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	originPort := originLn.Addr().(*net.TCPAddr).Port
	tlsLn := tls.NewListener(originLn, &tls.Config{Certificates: []tls.Certificate{cert}})
	go http.Serve(tlsLn, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "ORIGIN-OK")
	}))

	proxyLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	proxyPort := proxyLn.Addr().(*net.TCPAddr).Port
	proxyLn.Close()
	p := New(Config{
		TLSListen:  fmt.Sprintf("127.0.0.1:%d", proxyPort),
		HTTPListen: "",
		Dial: func(network, address string, timeout time.Duration) (net.Conn, error) {
			// Redirect whatever SNI host the proxy dials to our origin.
			return net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", originPort), timeout)
		},
	})
	go func() { _ = p.Run() }()
	time.Sleep(200 * time.Millisecond)

	client := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true, ServerName: "localhost"},
		},
	}
	resp, err := client.Get(fmt.Sprintf("https://127.0.0.1:%d/", proxyPort))
	if err != nil {
		t.Fatalf("GET through proxy failed: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if string(body) != "ORIGIN-OK" {
		t.Fatalf("unexpected body %q", body)
	}
}
