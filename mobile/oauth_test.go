package mobile

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/linguo2625469/workbuddy2api-panel/internal/panel"
	"github.com/linguo2625469/workbuddy2api-panel/internal/pool"
	"github.com/linguo2625469/workbuddy2api-panel/internal/upstream"
)

// All OAuth and billing calls are intercepted. Nothing can reach a provider.
func oauthPanel(t *testing.T, ttl time.Duration, transport roundTripFunc) (http.Handler, string) {
	t.Helper()
	dir := t.TempDir()
	p := pool.New("")
	up := upstream.New()
	up.HTTP.Transport = transport
	up.ChatHTTP.Transport = transport
	return panel.New(panel.Config{
		GatewayOnly: true, LoginTTL: ttl,
		LoginHTTP: &http.Client{Transport: transport},
		Pool: p, Upstream: up, AuthDir: dir, APIKey: "test-key",
	}), dir
}

func panelRequest(h http.Handler, method, path string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, nil)
	r.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func oauthResponse(t *testing.T, r *http.Request) (*http.Response, error) {
	t.Helper()
	switch r.URL.Path {
	case "/v2/plugin/auth/state":
		return response(`{"code":0,"data":{"state":"offline-state","authUrl":"https://example.invalid/oauth"}}`), nil
	case "/v2/plugin/auth/token":
		return response(`{"code":0,"data":{"accessToken":"fake-token","refreshToken":"fake-refresh","expiresIn":3600}}`), nil
	case "/v2/plugin/login/account":
		return response(`{"code":0,"data":{"uid":"offline-user"}}`), nil
	case "/v2/billing/meter/get-user-resource":
		return response(`{"code":0,"data":{}}`), nil
	default:
		t.Errorf("forbidden OAuth follow-up: %s", r.URL.Path)
		return response(`{"code":1}`), nil
	}
}

func TestOAuthExpiredBeforePoll(t *testing.T) {
	var calls atomic.Int32
	h, dir := oauthPanel(t, time.Nanosecond, func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		return oauthResponse(t, r)
	})
	if w := panelRequest(h, "POST", "/panel/api/login/start"); w.Code != 200 {
		t.Fatal(w.Code)
	}
	if w := panelRequest(h, "GET", "/panel/api/login/poll?state=offline-state"); w.Code != 404 {
		t.Fatalf("expired state accepted: %d", w.Code)
	}
	if calls.Load() != 1 { t.Fatal("expired poll reached upstream") }
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 0 { t.Fatal("expired login persisted credentials", err) }
}

func TestOAuthExpiresDuringUpstream(t *testing.T) {
	h, dir := oauthPanel(t, 100*time.Millisecond, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/v2/plugin/auth/token" {
			<-time.After(150*time.Millisecond)
		}
		return oauthResponse(t, r)
	})
	panelRequest(h, "POST", "/panel/api/login/start")
	if w := panelRequest(h, "GET", "/panel/api/login/poll?state=offline-state"); w.Code != 404 {
		t.Fatalf("late completion accepted: %d", w.Code)
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 0 { t.Fatal("late login persisted credentials", err) }
}

func TestOAuthConcurrentPollConsumesOnce(t *testing.T) {
	var accountCalls, balances atomic.Int32
	release := make(chan struct{})
	h, _ := oauthPanel(t, time.Minute, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/v2/plugin/login/account" {
			if accountCalls.Add(1) == 2 { close(release) }
			select {
			case <-release:
			case <-time.After(2*time.Second): t.Error("concurrent poll did not reach barrier")
			}
		}
		if r.URL.Path == "/v2/billing/meter/get-user-resource" { balances.Add(1) }
		return oauthResponse(t, r)
	})
	panelRequest(h, "POST", "/panel/api/login/start")
	var wg sync.WaitGroup
	results := make(chan *httptest.ResponseRecorder, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results <- panelRequest(h, "GET", "/panel/api/login/poll?state=offline-state")
		}()
	}
	wg.Wait()
	close(results)
	completed := 0
	for w := range results {
		if w.Code == 200 {
			var out struct { Done bool `json:"done"` }
			raw, _ := io.ReadAll(w.Result().Body)
			if json.Unmarshal(raw, &out) == nil && out.Done { completed++ }
		} else if w.Code != 404 { t.Errorf("unexpected response: %d", w.Code) }
	}
	if completed != 1 || balances.Load() != 1 {
		t.Fatalf("completed=%d balance calls=%d", completed, balances.Load())
	}
}
