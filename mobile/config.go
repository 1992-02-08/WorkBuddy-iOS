package mobile

import (
 "bytes"
 "crypto/rand"
 "encoding/hex"
 "encoding/json"
 "fmt"
 "io"
 "os"
 "path/filepath"
 "strings"
 "sync"
 "time"

 "github.com/linguo2625469/workbuddy2api-panel/internal/livecfg"
 "github.com/linguo2625469/workbuddy2api-panel/internal/pool"
 "github.com/linguo2625469/workbuddy2api-panel/internal/upstream"
)

// Only fields that can safely be changed in an embedded gateway are accepted.
// Listening, filesystem paths, upstream URLs and task schedules are not configurable.
type gatewayConfig struct {
 APIKey string `json:"api_key"`
 Pool poolConfig `json:"pool"`
 Cooldown struct { SoftRate string `json:"soft_rate"` } `json:"cooldown"`
 Features struct { Sanitize bool `json:"sanitize_blacklist_fingerprints"` } `json:"features"`
 Models struct { Hidden []string `json:"hidden"` } `json:"models"`
 Logging struct { ClientInfo bool `json:"request_client_info"` } `json:"logging"`
}
type poolConfig struct {
 MaxInFlight int `json:"max_in_flight"`
 MaxInFlightGlobal int `json:"max_in_flight_global"`
 CreditFloor int64 `json:"credit_floor"`
 PreferExpiring bool `json:"prefer_expiring"`
 CrossDomainFallback bool `json:"cross_domain_fallback"`
 Strategy pool.RegionStrategies `json:"strategy"`
 AccountOrder pool.RegionAccountOrder `json:"account_order"`
}
type configStore struct {
 mu sync.Mutex
 path string
 cfg gatewayConfig
 live *livecfg.Holder
 pool *pool.Pool
 up *upstream.Client
}
func defaults() gatewayConfig {
 var c gatewayConfig
 c.Cooldown.SoftRate = "10m"
 c.Features.Sanitize = true
 c.Models.Hidden = []string{}
 c.Pool.MaxInFlight = 2
 c.Pool.MaxInFlightGlobal = 1
 c.Pool.PreferExpiring = true
 return c
}
func decodeConfig(raw []byte, c *gatewayConfig) error {
 if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) { return fmt.Errorf("config must be an object") }
 // Reject null at any depth: null must not silently preserve an old secret or setting.
 var tree any
 if err := json.Unmarshal(raw, &tree); err != nil { return err }
 var check func(any) error
 check = func(v any) error {
  if v == nil { return fmt.Errorf("null config values are not allowed") }
  switch x := v.(type) { case map[string]any: for _, child := range x { if err := check(child); err != nil { return err } }; case []any: for _, child := range x { if err := check(child); err != nil { return err } } }
  return nil
 }
 if err := check(tree); err != nil { return err }
 d := json.NewDecoder(bytes.NewReader(raw)); d.DisallowUnknownFields()
 if err := d.Decode(c); err != nil { return err }
 if err := d.Decode(new(any)); err != io.EOF { return fmt.Errorf("expected one config object") }
 if strings.TrimSpace(c.APIKey) == "" { return fmt.Errorf("api_key must not be empty") }
 if strings.TrimSpace(c.APIKey) != c.APIKey || len(c.APIKey) > 4096 || strings.ContainsAny(c.APIKey, "\r\n\t") { return fmt.Errorf("invalid api_key") }
 if c.Pool.MaxInFlight < 1 || c.Pool.MaxInFlight > 64 || c.Pool.MaxInFlightGlobal < 1 || c.Pool.MaxInFlightGlobal > 64 || c.Pool.CreditFloor < 0 { return fmt.Errorf("invalid pool limits") }
 s, err := c.Pool.Strategy.Normalize(); if err != nil { return err }; c.Pool.Strategy = s
 dur, err := time.ParseDuration(c.Cooldown.SoftRate)
 if err != nil || dur <= 0 || dur > 24*time.Hour { return fmt.Errorf("soft_rate must be between 0 and 24h") }
 return nil
}
func openConfig(dir string) (*configStore, error) {
 s := &configStore{path: filepath.Join(dir, "config.json"), cfg: defaults()}
 raw, err := os.ReadFile(s.path)
 if os.IsNotExist(err) {
  key := make([]byte, 32); if _, err := rand.Read(key); err != nil { return nil, err }
  s.cfg.APIKey = hex.EncodeToString(key)
  raw, err = json.Marshal(s.cfg)
  if err == nil { err = atomicWrite(s.path, raw) }
 }
 if err != nil { return nil, err }
 if err := decodeConfig(raw, &s.cfg); err != nil { return nil, fmt.Errorf("mobile config: %w", err) }
 return s, nil
}
func atomicWrite(path string, raw []byte) error {
 f, err := os.CreateTemp(filepath.Dir(path), ".mobile-*"); if err != nil { return err }
 name := f.Name(); defer os.Remove(name)
 if err = f.Chmod(0600); err == nil { _, err = f.Write(raw) }
 if err == nil { err = f.Sync() }
 closeErr := f.Close(); if err == nil { err = closeErr }
 if err == nil { err = os.Rename(name, path) }
 return err
}
func (s *configStore) load() (any, error) {
 s.mu.Lock(); defer s.mu.Unlock()
 // Round-trip for a detached snapshot (slice fields must not alias live state).
 raw, err := json.Marshal(s.cfg); if err != nil { return nil, err }
 var out map[string]any; err = json.Unmarshal(raw, &out); return out, err
}
func (s *configStore) save(raw []byte) ([]string, error) {
 s.mu.Lock(); defer s.mu.Unlock()
 // JSON decoding into a detached copy implements partial nested updates.
 old, _ := json.Marshal(s.cfg)
 var next gatewayConfig; _ = json.Unmarshal(old, &next)
 if err := decodeConfig(raw, &next); err != nil { return nil, err }
 out, err := json.MarshalIndent(next, "", "  "); if err != nil { return nil, err }
 if err := atomicWrite(s.path, out); err != nil { return nil, err }
 s.cfg = next; s.apply()
 return []string{}, nil
}
func (s *configStore) apply() {
 c := s.cfg; dur, _ := time.ParseDuration(c.Cooldown.SoftRate)
 s.live.Store(livecfg.Snapshot{APIKey:c.APIKey, SoftCooldown:dur, SanitizeFingerprints:c.Features.Sanitize, RecordClientInfo:c.Logging.ClientInfo, HiddenModels:livecfg.NormalizeHiddenModels(c.Models.Hidden)})
 s.up.SanitizeFingerprints.Store(c.Features.Sanitize)
 s.pool.SetMaxInFlight(c.Pool.MaxInFlight)
 s.pool.SetMaxInFlightGlobal(c.Pool.MaxInFlightGlobal)
 s.pool.SetCreditFloor(c.Pool.CreditFloor)
 s.pool.SetPreferExpiring(c.Pool.PreferExpiring)
 s.pool.SetCrossDomainFallback(c.Pool.CrossDomainFallback)
 _ = s.pool.SetScheduling(c.Pool.Strategy, c.Pool.AccountOrder)
}
