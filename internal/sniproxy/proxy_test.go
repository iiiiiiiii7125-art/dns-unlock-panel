package sniproxy

import (
	"os"
	"testing"
)

func TestParseSNIRealClientHello(t *testing.T) {
	b, err := os.ReadFile("/tmp/dns-test/clienthello.bin")
	if err != nil {
		t.Skip("no captured ClientHello: " + err.Error())
	}
	got := parseSNI(b)
	t.Logf("captured %d bytes, SNI=%q", len(b), got)
	// NOTE: this capture was taken with curl to an IP literal, and curl
	// sends no SNI for IP literals — empty is CORRECT here. The test
	// only guards against a parser crash on real input.
	if got != "" {
		t.Fatalf("expected empty SNI for IP-literal ClientHello, got %q", got)
	}
}

func TestParseSNISynthetic(t *testing.T) {
	// Minimal ClientHello: record + handshake with server_name "example.com".
	name := "example.com"
	// server_name extension: type(2)=0, len(2), list_len(2), name_type(1)=0,
	// name_len(2), name.
	sniExt := []byte{0x00, 0x00, 0x00, byte(len(name) + 5),
		0x00, byte(len(name) + 3), 0x00, 0x00, byte(len(name))}
	sniExt = append(sniExt, name...)
	// Build handshake body: version(2) random(32) sess(1+0) cs(2+2) comp(1+1) extlen(2) exts
	body := []byte{0x03, 0x03}
	body = append(body, make([]byte, 32)...)
	body = append(body, 0x00)             // session id len
	body = append(body, 0x00, 0x02, 0x13, 0x01) // cipher suites len 2 + one suite
	body = append(body, 0x01, 0x00)       // compression len 1 + null
	extPayload := sniExt
	body = append(body, byte(len(extPayload)>>8), byte(len(extPayload)))
	body = append(body, extPayload...)
	hs := []byte{0x01, byte(len(body) >> 16), byte(len(body) >> 8), byte(len(body))}
	hs = append(hs, body...)
	rec := []byte{0x16, 0x03, 0x01, byte(len(hs) >> 8), byte(len(hs))}
	rec = append(rec, hs...)
	if got := parseSNI(rec); got != name {
		t.Fatalf("synthetic: got %q want %q", got, name)
	}
}
