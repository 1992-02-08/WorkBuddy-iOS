// Package mobile embeds the gateway in the UIKit host process. The host supplies
// an absolute Application Support directory and calls Stop before suspension.
// Exported signatures intentionally use only gomobile-bind supported types.
package mobile

import (
 "context"
 "fmt"
 "io"
 "net"
 "net/http"
 "os"
 "path/filepath"
 "sync"
 "time"

 "github.com/linguo2625469/workbuddy2api-panel/internal/auth"
 "github.com/linguo2625469/workbuddy2api-panel/internal/httpauth"
 "github.com/linguo2625469/workbuddy2api-panel/internal/livecfg"
 "github.com/linguo2625469/workbuddy2api-panel/internal/panel"
 "github.com/linguo2625469/workbuddy2api-panel/internal/pool"
 "github.com/linguo2625469/workbuddy2api-panel/internal/server"
 "github.com/linguo2625469/workbuddy2api-panel/internal/upstream"
 "github.com/linguo2625469/workbuddy2api-panel/internal/usage"
)

var singleton struct { sync.Mutex; current *runtime }

type runtime struct {
 dir, url string
 srv *http.Server
 cancel context.CancelFunc
 done chan struct{}
 pool *pool.Pool
 usage *usage.Recorder
 live *livecfg.Holder
 clients []*http.Client
 gate sync.Mutex
 closing bool
 stopOnce sync.Once
 requests sync.WaitGroup
}

// Start opens a dynamic TCP port on 127.0.0.1 and returns its base URL (no trailing
// slash). Repeated Start for the same directory is idempotent; a different one
// requires Stop first. No environment variables or current-directory files are used.
func Start(dataDir string) (string, error) {
 singleton.Lock(); defer singleton.Unlock()
 if dataDir == "" || !filepath.IsAbs(dataDir) { return "", fmt.Errorf("dataDir must be an absolute Application Support path") }
 dir := filepath.Clean(dataDir)
 if singleton.current != nil {
  if singleton.current.dir == dir { return singleton.current.url, nil }
  return "", fmt.Errorf("gateway already running with another directory")
 }
 r, err := startRuntime(dir, nil)
 if err != nil { return "", err }
 singleton.current = r
 return r.url, nil
}

// Stop cancels all incoming and outgoing requests (including SSE), closes the
// listener, waits for handlers, then flushes pool and usage. Safe to call repeatedly.
func Stop() {
 singleton.Lock(); defer singleton.Unlock()
 if r := singleton.current; r != nil { r.stop(); singleton.current = nil }
}

// APIKey returns the currently active nonempty key, or empty when stopped.
func APIKey() string {
 singleton.Lock(); defer singleton.Unlock()
 if r := singleton.current; r != nil { return r.live.Load().APIKey }; return ""
}

// BaseURL returns the running listener URL, or empty when stopped.
func BaseURL() string {
 singleton.Lock(); defer singleton.Unlock()
 if r := singleton.current; r != nil { return r.url }; return ""
}

// Running reports whether the embedded core has been started.
func Running() bool { return BaseURL() != "" }

// configure is test-only dependency injection; Start never overrides upstream URLs.
func startRuntime(dir string, configure func(*upstream.Client)) (*runtime, error) {
 if err := os.MkdirAll(dir, 0700); err != nil { return nil, err }
 authDir := filepath.Join(dir, "auths")
 if err := os.MkdirAll(authDir, 0700); err != nil { return nil, err }
 cfg, err := openConfig(dir); if err != nil { return nil, err }
 accounts, err := auth.LoadDir(authDir); if err != nil { return nil, err }
 ln, err := net.Listen("tcp4", "127.0.0.1:0"); if err != nil { return nil, err }
 ctx, cancel := context.WithCancel(context.Background())
 p := pool.New(filepath.Join(dir, "state.json")); p.SyncToDir(accounts)
 rec := usage.New(filepath.Join(dir, "usage.json")); rec.Start()
 live := livecfg.New(livecfg.Snapshot{})
 up := upstream.New()
 if configure != nil { configure(up) }
 up.HTTP.Transport = &lifecycleTransport{root:ctx, base:transportOf(up.HTTP)}
 up.ChatHTTP.Transport = &lifecycleTransport{root:ctx, base:transportOf(up.ChatHTTP)}
 // OAuth shares the managed RPC client, not the process-global login client.
 loginClient := &http.Client{Timeout:30*time.Second, Transport:up.HTTP.Transport}
 cfg.pool, cfg.up, cfg.live = p, up, live; cfg.apply()
 p.SetModelRateOf(up.ModelRate)
 pn := panel.New(panel.Config{GatewayOnly:true, LoginHTTP:loginClient, Pool:p,
  Upstream:up, AuthDir:authDir, Live:live, Usage:rec, Version:"ios-embedded",
  ConfigPath:cfg.path, LoadConfig:cfg.load, SaveConfig:cfg.save})
 h := server.NewHandler(server.Config{Pool:p, Upstream:up, Live:live, Panel:pn,
  Usage:rec, GlobalEnabled:true, PromptMode:"passthrough"})
 r := &runtime{dir:dir, url:"http://"+ln.Addr().String(), cancel:cancel,
  pool:p, usage:rec, live:live, done:make(chan struct{}), clients:[]*http.Client{up.HTTP,up.ChatHTTP,loginClient}}
 r.srv = &http.Server{Handler:r.track(h), ReadHeaderTimeout:15*time.Second,
  ReadTimeout:300*time.Second, IdleTimeout:60*time.Second,
  BaseContext:func(net.Listener) context.Context { return ctx }}
 go func() { defer close(r.done); _ = r.srv.Serve(ln) }()
 return r, nil
}
func (r *runtime) track(next http.Handler) http.Handler {
 return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
  r.gate.Lock()
  if r.closing { r.gate.Unlock(); http.Error(w,"stopping",http.StatusServiceUnavailable); return }
  r.requests.Add(1); r.gate.Unlock(); defer r.requests.Done()
  // WKWebView subresources cannot inherit the API Bearer header. Only the
  // exact public static files may bypass authentication; all APIs remain private.
  publicStatic := false
  if req.Method == http.MethodGet || req.Method == http.MethodHead {
   switch req.URL.Path {
   case "/panel/", "/panel/app.js", "/panel/mobile.css", "/panel/mobile.js":
    publicStatic = true
   }
  }
  if !publicStatic && !httpauth.VerifyBearer(req, r.live.Load().APIKey) { http.Error(w,"invalid_api_key",http.StatusUnauthorized); return }
  next.ServeHTTP(w, req)
 })
}
func (r *runtime) stop() {
 r.stopOnce.Do(func() {
 r.gate.Lock(); r.closing = true; r.gate.Unlock()
 r.cancel()
 _ = r.srv.Close()
 <-r.done
 r.requests.Wait()
 for _, c := range r.clients { c.CloseIdleConnections() }
 r.usage.Stop()
 r.pool.Close()
 })
}
func transportOf(c *http.Client) http.RoundTripper {
 if c.Transport != nil { return c.Transport }; return http.DefaultTransport
}

// Some existing upstream RPCs start with Background contexts. Bind every transport
// operation to this runtime too, and retain cancellation until the body is closed.
type lifecycleTransport struct { root context.Context; base http.RoundTripper }
func (t *lifecycleTransport) RoundTrip(req *http.Request) (*http.Response,error) {
 ctx, cancel := context.WithCancel(req.Context())
 stop := context.AfterFunc(t.root,cancel)
 if t.root.Err() != nil { cancel() }
 resp, err := t.base.RoundTrip(req.Clone(ctx))
 if err != nil { stop(); cancel(); return nil,err }
 resp.Body = &lifecycleBody{ReadCloser:resp.Body, cleanup:func(){stop();cancel()}}
 return resp,nil
}
func (t *lifecycleTransport) CloseIdleConnections() {
 if c, ok := t.base.(interface{CloseIdleConnections()}); ok { c.CloseIdleConnections() }
}
type lifecycleBody struct { io.ReadCloser; cleanup func() }
func (b *lifecycleBody) Close() error { defer b.cleanup(); return b.ReadCloser.Close() }
