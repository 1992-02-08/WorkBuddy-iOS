package mobile

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/linguo2625469/workbuddy2api-panel/internal/upstream"
)

func TestStopCancelsBackgroundRPC(t *testing.T) {
	entered := make(chan struct{})
	canceled := make(chan struct{})
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		close(entered)
		<-req.Context().Done()
		close(canceled)
	}))
	defer fake.Close()
	r := offline(t, func(up *upstream.Client) {
		up.HTTP.Transport = http.DefaultTransport.(*http.Transport).Clone()
	})
	// Client.Get uses Background internally, like existing billing RPC helpers.
	requestDone := make(chan error, 1)
	go func() {
		resp, err := r.clients[0].Get(fake.URL)
		if resp != nil { resp.Body.Close() }
		requestDone <- err
	}()
	select {
	case <-entered:
	case <-time.After(2*time.Second): t.Fatal("RPC did not reach local fake upstream")
	}
	r.stop()
	select {
	case <-canceled:
	case <-time.After(2*time.Second): t.Fatal("Stop did not cancel upstream RPC")
	}
	select {
	case err := <-requestDone:
		if err == nil { t.Fatal("canceled RPC returned success") }
	case <-time.After(2*time.Second): t.Fatal("RPC remained blocked after Stop")
	}
}
