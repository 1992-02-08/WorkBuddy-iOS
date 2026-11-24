package mobile

import (
 "context"
 "encoding/json"
 "fmt"
 "io"
 "net/http"
 "net/http/httptest"
 "os"
 "path/filepath"
 "strings"
 "sync"
 "testing"
 "time"

 "github.com/linguo2625469/workbuddy2api-panel/internal/auth"
 "github.com/linguo2625469/workbuddy2api-panel/internal/upstream"
 "github.com/linguo2625469/workbuddy2api-panel/internal/usage"
)

type roundTripFunc func(*http.Request) (*http.Response, error)
func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func response(body string) *http.Response {
 return &http.Response{StatusCode:200, Header:make(http.Header), Body:io.NopCloser(strings.NewReader(body))}
}
func offline(t *testing.T, configure func(*upstream.Client)) *runtime {
 t.Helper()
 r, err := startRuntime(t.TempDir(), func(up *upstream.Client) {
  deny := roundTripFunc(func(req *http.Request)(*http.Response,error){ t.Errorf("unexpected upstream request: %s",req.URL.Path); return nil,fmt.Errorf("unexpected upstream request") })
  up.HTTP.Transport = deny; up.ChatHTTP.Transport = deny
  if configure != nil { configure(up) }
 })
 if err != nil { t.Fatal(err) }
 t.Cleanup(r.stop)
 return r
}
func request(t *testing.T, base, key, method, path, body string) (int, []byte) {
 t.Helper()
 req, err := http.NewRequest(method,base+path,strings.NewReader(body)); if err != nil { t.Fatal(err) }
 if key != "" { req.Header.Set("Authorization","Bearer "+key) }
 client := &http.Client{Timeout:3*time.Second}
 resp, err := client.Do(req); if err != nil { t.Fatal(err) }
 defer resp.Body.Close()
 raw, err := io.ReadAll(resp.Body); if err != nil { t.Fatal(err) }
 return resp.StatusCode,raw
}
func TestStartStopRestart(t *testing.T) {
 Stop(); t.Cleanup(Stop)
 dir := t.TempDir()
 base, err := Start(dir); if err != nil { t.Fatal(err) }
 key := APIKey()
 if len(key) != 64 || !strings.HasPrefix(base,"http://127.0.0.1:") || !Running() { t.Fatal("invalid startup state") }
 again, err := Start(dir); if err != nil || again != base { t.Fatal("Start not idempotent",err) }
 if _, err := Start(t.TempDir()); err == nil { t.Fatal("accepted directory switch") }
 status,_ := request(t,base,key,"GET","/status",""); if status != 200 { t.Fatal(status) }
 Stop(); Stop()
 if Running() || APIKey() != "" || BaseURL() != "" { t.Fatal("state not cleared") }
 if resp, err := (&http.Client{Timeout:time.Second}).Get(base+"/status"); err == nil { resp.Body.Close(); t.Fatal("listener survived Stop") }
 base, err = Start(dir); if err != nil { t.Fatal(err) }
 if APIKey() != key { t.Fatal("key changed on restart") }
 status,_ = request(t,base,key,"GET","/panel/api/overview",""); if status != 200 { t.Fatal(status) }
}
func TestAuthenticationAndForbiddenRoutes(t *testing.T) {
 r := offline(t,nil); key := r.live.Load().APIKey
 for _, path := range []string{"/status","/healthz","/v1/models","/panel/api/overview","/panel/api/config","/panel/app.js/extra","/panel/unknown"} {
  for _, bad := range []string{"","incorrect"} {
   status,_ := request(t,r.url,bad,"GET",path,""); if status != 401 { t.Errorf("%s: %d",path,status) }
  }
 }
 for _, path := range []string{"/panel/","/panel/app.js","/panel/mobile.css","/panel/mobile.js"} {
  for _, method := range []string{"GET","HEAD"} {
   status,raw := request(t,r.url,"",method,path,"")
   if status != 200 { t.Errorf("public static %s %s: %d",method,path,status) }
   if strings.Contains(string(raw),key) { t.Errorf("static asset exposed API key: %s",path) }
  }
  status,_ := request(t,r.url,"","POST",path,"")
  if status != 401 { t.Errorf("static exception allowed POST %s: %d",path,status) }
 }
 for _, route := range []string{
  "POST /panel/api/import/cockpit", "POST /panel/api/accounts/u/checkin", "GET /panel/api/accounts/u/tasks",
  "POST /panel/api/accounts/u/tasks/accept", "POST /panel/api/accounts/u/tasks/accept_all",
  "POST /panel/api/accounts/u/tasks/claim", "POST /panel/api/accounts/u/tasks/auto",
  "POST /panel/api/accounts/u/tasks/auto_all", "POST /panel/api/tasks/scan_all",
  "POST /panel/api/tasks/run_queue", "GET /panel/api/tasks/queue", "GET /panel/api/school/vouchers",
  "POST /panel/api/checkin_all", "POST /panel/api/travel_all", "POST /panel/api/activity_all",
  "POST /panel/api/keepalive_all", "POST /panel/api/balance_all", "GET /panel/api/compensation",
  "POST /panel/api/compensation_all", "POST /panel/api/accounts/u/compensation",
 } {
  method,path,_ := strings.Cut(route," ")
  status,_ := request(t,r.url,key,method,path,""); if status != 404 { t.Errorf("%s: %d",route,status) }
 }
 for _, path := range []string{"/panel/api/overview","/panel/api/usage","/panel/api/config","/panel/api/packages"} {
  status,_ := request(t,r.url,key,"GET",path,""); if status != 200 { t.Errorf("%s: %d",path,status) }
 }
}
func TestSandboxConfigAndPersistence(t *testing.T) {
 r := offline(t,nil); key := r.live.Load().APIKey
 path := filepath.Join(r.dir,"config.json")
 before,_ := os.ReadFile(path)
 for _, body := range []string{
  `{"listen":"0.0.0.0:80"}`, `{"auth_dir":"../escape"}`, `{"state_file":"/tmp/state"}`,
  `{"api_key":""}`, `{"api_key":"   "}`, `{"api_key":null}`, `{"schedule":{"checkin_enabled":true}}`,
  `{"schedule":{"growth_enabled":true}}`, `{"upstream":{"device_token_file":"../secret"}}`,
  `{"pool":{"max_in_flight":0}}`, `{"cooldown":{"soft_rate":"bad"}}`, `null`, `{} {}`,
  `{"pool":{"strategy":{"domestic":"invalid"}}}`,
 } {
  status,_ := request(t,r.url,key,"POST","/panel/api/config",body)
  if status != 400 { t.Errorf("accepted %s: %d",body,status) }
  after,_ := os.ReadFile(path); if string(before) != string(after) { t.Fatal("rejected write modified config") }
 }
 status,raw := request(t,r.url,key,"POST","/panel/api/config",`{"api_key":"replacement-key","pool":{"credit_floor":42,"strategy":{"domestic":"round_robin"}},"models":{"hidden":["cn:hidden"]}}`)
 if status != 200 { t.Fatalf("%d: %s",status,raw) }
 status,_ = request(t,r.url,key,"GET","/status",""); if status != 401 { t.Fatal("old key still valid") }
 status,_ = request(t,r.url,"replacement-key","GET","/status",""); if status != 200 { t.Fatal(status) }
 saved,err := openConfig(r.dir); if err != nil { t.Fatal(err) }
 if saved.cfg.APIKey != "replacement-key" || saved.cfg.Pool.CreditFloor != 42 || saved.cfg.Pool.Strategy.Domestic != "round_robin" { t.Fatal("settings not persisted") }
 info,err := os.Stat(path); if err != nil || info.Mode().Perm() != 0600 { t.Fatal("config permissions",err) }
}
func TestOAuthGatewayOnly(t *testing.T) {
 for _, realm := range []string{"cn","global"} { t.Run(realm,func(t *testing.T){
  var mu sync.Mutex; var paths []string
  r := offline(t,func(up *upstream.Client){
   fake := roundTripFunc(func(req *http.Request)(*http.Response,error){
    mu.Lock(); paths = append(paths,req.URL.Path); mu.Unlock()
    switch req.URL.Path {
    case "/v2/plugin/auth/state": return response(`{"code":0,"data":{"state":"state-with&symbols","authUrl":"https://example.invalid/oauth"}}`),nil
    case "/v2/plugin/auth/token":
     if req.URL.Query().Get("state") != "state-with&symbols" { return nil,fmt.Errorf("bad state encoding") }
     return response(`{"code":0,"data":{"accessToken":"token","refreshToken":"refresh","expiresIn":3600}}`),nil
    case "/v2/plugin/login/account": return response(`{"code":0,"data":{"uid":"test-user","nickname":"offline"}}`),nil
    default:
     // Balance is the only permitted post-login upstream operation.
     if req.URL.Path != "/v2/billing/meter/get-user-resource" && req.URL.Path != "/billing/meter/get-user-resource" {
      t.Errorf("unexpected OAuth follow-up: %s",req.URL.Path)
      return nil,fmt.Errorf("forbidden OAuth follow-up")
     }
     return response(`{"code":0,"data":{}}`),nil
    }
   }); up.HTTP.Transport = fake; up.ChatHTTP.Transport = fake
  })
  key := r.live.Load().APIKey
  status,_ := request(t,r.url,key,"POST","/panel/api/login/start",`{"realm":"`+realm+`"}`); if status != 200 { t.Fatal(status) }
  status,raw := request(t,r.url,key,"GET","/panel/api/login/poll?state=state-with%26symbols","")
  if status != 200 { t.Fatalf("%d %s",status,raw) }
  var out struct { Done bool `json:"done"` }; if json.Unmarshal(raw,&out) != nil || !out.Done { t.Fatalf("login failed %s",raw) }
  if r.pool.AuthByUID("test-user") == nil { t.Fatal("account not loaded") }
  if _,err := os.Stat(filepath.Join(r.dir,"auths","workbuddy-test-user.json")); err != nil { t.Fatal(err) }
  status,_ = request(t,r.url,key,"GET","/panel/api/login/poll?state=state-with%26symbols",""); if status != 404 { t.Fatal("state replay accepted") }
  mu.Lock(); defer mu.Unlock()
  for _, p := range paths { if strings.Contains(p,"checkin") || strings.Contains(p,"check-in") || strings.Contains(p,"trial") || strings.Contains(p,"registration") || strings.Contains(p,"report") { t.Errorf("reward call: %s",p) } }
 }) }
}
func TestLifecycleCancelsSSEBody(t *testing.T) {
 canceled := make(chan struct{})
 upstreamServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
  w.Header().Set("Content-Type","text/event-stream"); _,_ = io.WriteString(w,"data: first\n\n"); w.(http.Flusher).Flush()
  <-r.Context().Done(); close(canceled)
 }))
 defer upstreamServer.Close()
 ctx,cancel := context.WithCancel(context.Background()); defer cancel()
 tr := &lifecycleTransport{root:ctx,base:http.DefaultTransport.(*http.Transport).Clone()}
 client := &http.Client{Transport:tr}; defer client.CloseIdleConnections()
 resp,err := client.Get(upstreamServer.URL); if err != nil { t.Fatal(err) }; defer resp.Body.Close()
 cancel()
 select { case <-canceled: case <-time.After(2*time.Second): t.Fatal("SSE upstream not canceled") }
 if _,err := io.ReadAll(resp.Body); err == nil { t.Fatal("SSE body survived cancellation") }
}
func TestStopWaitsForHandlersAndFlushes(t *testing.T) {
 entered := make(chan struct{}); finished := make(chan struct{})
 r := offline(t,nil)
 // Exercise the exact tracking wrapper used by the listener with an active SSE handler.
 handler := r.track(http.HandlerFunc(func(w http.ResponseWriter,req *http.Request){
  close(entered); <-req.Context().Done()
  r.usage.Add(time.Now(),"cn","u","m",usage.Delta{TotalTokens:7,HasTotal:true},true)
  close(finished)
 }))
 ctx,cancel := context.WithCancel(context.Background()); defer cancel()
 req := httptest.NewRequest("GET","/stream",nil).WithContext(ctx)
 req.Header.Set("Authorization","Bearer "+r.live.Load().APIKey)
 go handler.ServeHTTP(httptest.NewRecorder(),req)
 <-entered
 stopped := make(chan struct{}); go func(){ r.stop(); close(stopped) }()
 select { case <-stopped: t.Fatal("Stop did not wait for active handler"); case <-time.After(20*time.Millisecond): }
 cancel()
 select { case <-stopped: case <-time.After(2*time.Second): t.Fatal("Stop hung") }
 <-finished
 raw,err := os.ReadFile(filepath.Join(r.dir,"usage.json"))
 var saved struct { Buckets []struct { Tokens int64 `json:"t"` } `json:"buckets"` }
 if err != nil || json.Unmarshal(raw,&saved) != nil { t.Fatalf("invalid usage snapshot: %v",err) }
 var tokens int64
 for _, b := range saved.Buckets { tokens += b.Tokens }
 if tokens != 7 { t.Fatalf("usage not flushed: got %d tokens",tokens) }
}
func TestPoolStateSurvivesStop(t *testing.T) {
 r := offline(t,nil)
 a := &auth.Auth{UID:"persisted-user", AccessToken:"fake-token", RefreshToken:"fake-refresh", ExpiresAt:time.Now().Add(time.Hour).Unix(), FilePath:filepath.Join(r.dir,"auths","workbuddy-persisted-user.json")}
 if err := a.SaveAtomic(); err != nil { t.Fatal(err) }
 r.pool.Add(a)
 r.pool.Disable(a.UID,"offline-test")
 r.stop()
 next,err := startRuntime(r.dir,func(up *upstream.Client){
  deny := roundTripFunc(func(req *http.Request)(*http.Response,error){ t.Errorf("restart reached upstream: %s",req.URL.Path); return nil,fmt.Errorf("offline") })
  up.HTTP.Transport = deny; up.ChatHTTP.Transport = deny
 })
 if err != nil { t.Fatal(err) }
 defer next.stop()
 statuses := next.pool.List()
 if len(statuses) != 1 || !statuses[0].Disabled { t.Fatal("disabled account state not restored") }
}

func TestInvalidStartup(t *testing.T) {
 Stop(); t.Cleanup(Stop)
 for _,dir := range []string{"","relative"} { if _,err := Start(dir); err == nil { t.Fatal("accepted relative directory") } }
 dir := t.TempDir(); if err := os.WriteFile(filepath.Join(dir,"config.json"),[]byte(`{"api_key":""}`),0600); err != nil { t.Fatal(err) }
 if _,err := Start(dir); err == nil { t.Fatal("started with empty persisted key") }
}
