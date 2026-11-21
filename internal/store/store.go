package store

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"dnsunlock/internal/model"
)

// Data is the whole panel state, persisted as one JSON file (atomic write).
type Data struct {
	AdminUsername   string                           `json:"admin_username,omitempty"`
	AdminPassHash   string                           `json:"admin_pass_hash,omitempty"`
	AdminMustChange bool                             `json:"admin_must_change,omitempty"`
	Nodes           []model.Node                     `json:"nodes"`
	Rules           map[string]model.Rule            `json:"rules"`        // global: platform_id -> rule
	ServerRules     map[string]map[string]model.Rule `json:"server_rules"` // server_id -> platform_id -> rule
	Servers         []model.DNSServer                `json:"servers"`
	Events          []model.FailoverEvent            `json:"events"`
	ConfigVersion   int64                            `json:"config_version"`
	Upstream        string                           `json:"upstream"`
	// CustomDomains lets users add their own domains per platform
	// (platform_id -> extra suffixes), merged into the agent config.
	CustomDomains map[string][]string `json:"custom_domains,omitempty"`
	// PublicSourceIPs stores the DNS IP the user pasted in for each
	// public unlock source after registering (source id -> DNS IP).
	PublicSourceIPs map[string]string `json:"public_source_ips,omitempty"`
	// SelftestPending holds one queued self-test request per server
	// (server_id -> request), consumed when the agent next fetches its
	// config. A request older than 10 minutes may be replaced by a new
	// POST (the agent is presumed dead); see handleServerByID.
	SelftestPending map[string]model.SelftestRequest `json:"selftest_pending,omitempty"`
}

type Store struct {
	mu   sync.RWMutex
	path string
	d    Data
}

func New(path string) (*Store, error) {
	s := &Store{path: path}
	s.d = Data{
		Rules:       map[string]model.Rule{},
		ServerRules: map[string]map[string]model.Rule{},
		Upstream:    "1.1.1.1",
	}
	if b, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(b, &s.d); err != nil {
			// Corrupt primary: try the backup before giving up (P1-13).
			if bb, err2 := os.ReadFile(path + ".bak"); err2 == nil {
				var bak Data
				if err3 := json.Unmarshal(bb, &bak); err3 == nil {
					s.d = bak
					if s.d.Rules == nil {
						s.d.Rules = map[string]model.Rule{}
					}
					if s.d.ServerRules == nil {
						s.d.ServerRules = map[string]map[string]model.Rule{}
					}
					if s.d.Upstream == "" {
						s.d.Upstream = "1.1.1.1"
					}
					_ = s.saveLocked()
					return s, nil
				}
			}
			return nil, fmt.Errorf("parse store %s: %w", path, err)
		}
		if s.d.Rules == nil {
			s.d.Rules = map[string]model.Rule{}
		}
		if s.d.ServerRules == nil {
			s.d.ServerRules = map[string]map[string]model.Rule{}
		}
		if s.d.Upstream == "" {
			s.d.Upstream = "1.1.1.1"
		}
		return s, nil
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	if err := s.saveLocked(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) saveLocked() error {
	b, err := json.MarshalIndent(s.d, "", "  ")
	if err != nil {
		return err
	}
	// Keep one backup of the previous good file (P1-13), then atomic rename.
	if old, err := os.ReadFile(s.path); err == nil {
		_ = os.WriteFile(s.path+".bak", old, 0o600)
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, s.path); err != nil {
		return err
	}
	return os.Chmod(s.path, 0o600)
}

// Update runs fn under the write lock, bumps ConfigVersion when fn reports a change, and persists.
func (s *Store) Update(fn func(d *Data) (changed bool, err error)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	changed, err := fn(&s.d)
	if err != nil {
		return err
	}
	if changed {
		s.d.ConfigVersion++
	}
	return s.saveLocked()
}

func (s *Store) View(fn func(d *Data)) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	fn(&s.d)
}

// Snapshot returns a deep copy for read-only use.
func (s *Store) Snapshot() Data {
	s.mu.RLock()
	defer s.mu.RUnlock()
	b, _ := json.Marshal(s.d)
	var out Data
	_ = json.Unmarshal(b, &out)
	return out
}

func Now() string { return time.Now().UTC().Format(time.RFC3339) }

func NewID(prefix string) string {
	return fmt.Sprintf("%s-%d", prefix, time.Now().UnixNano())
}
