package lan

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"kinlogue/internal/library"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const authority = "192.168.50.2:8080"
const fid = "01234567-89ab-4cde-8fab-0123456789ab"

func receiver(t *testing.T, stage func(context.Context, string, int64, io.Reader) (Staged, error)) *Receiver {
	t.Helper()
	r, e := New(Config{Authority: authority, Prefix: netip.MustParsePrefix("192.168.50.0/24"), ValidateNetwork: func() bool { return true }, Stage: stage})
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(r.Stop)
	return r
}
func request(r *Receiver, method, path, body, cookie, csrf string) *httptest.ResponseRecorder {
	q := httptest.NewRequest(method, "http://"+authority+path, strings.NewReader(body))
	q.RemoteAddr = "192.168.50.3:12345"
	q.Header.Set("Origin", "http://"+authority)
	if cookie != "" {
		q.Header.Set("Cookie", cookie)
	}
	if csrf != "" {
		q.Header.Set("X-Kinlogue-CSRF", csrf)
	}
	if method == "PUT" {
		q.Header.Set("Content-Type", "application/octet-stream")
		q.Header.Set("X-Kinlogue-Attempt-Revision", "1")
	} else if body != "" {
		q.Header.Set("Content-Type", "application/json")
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, q)
	return w
}
func pair(t *testing.T, r *Receiver) (string, string) {
	t.Helper()
	w := request(r, "POST", "/api/pair", `{"code":"`+r.PairingCode()+`"}`, "", "")
	if w.Code != 200 {
		t.Fatalf("pair %d %s", w.Code, w.Body)
	}
	var v struct {
		CSRF string `json:"csrfToken"`
	}
	json.Unmarshal(w.Body.Bytes(), &v)
	return strings.Split(w.Header().Get("Set-Cookie"), ";")[0], v.CSRF
}

type staged struct{ commits *atomic.Int32 }

func (s staged) Commit(context.Context) error { s.commits.Add(1); return nil }
func (s staged) Abort() error                 { return nil }
func TestSavedReplayAndCancelledTombstone(t *testing.T) {
	var commits atomic.Int32
	r := receiver(t, func(ctx context.Context, n string, z int64, b io.Reader) (Staged, error) {
		_, e := io.Copy(io.Discard, b)
		return staged{&commits}, e
	})
	cookie, csrf := pair(t, r)
	reserve := `{"remoteFileID":"` + fid + `","displayName":"page.pdf","declaredByteCount":3,"attemptRevision":1}`
	if w := request(r, "POST", "/api/files/reserve", reserve, cookie, csrf); w.Code != 201 {
		t.Fatal(w.Code, w.Body)
	}
	for i := 0; i < 2; i++ {
		if w := request(r, "PUT", "/api/files/"+fid, "abc", cookie, csrf); w.Code != 200 {
			t.Fatal(w.Code, w.Body)
		}
	}
	if commits.Load() != 1 {
		t.Fatal("replay republished", commits.Load())
	}
}
func TestAuthenticationAndStrictJSONBeforeStage(t *testing.T) {
	var called atomic.Int32
	r := receiver(t, func(context.Context, string, int64, io.Reader) (Staged, error) { called.Add(1); return nil, nil })
	cookie, csrf := pair(t, r)
	for _, body := range []string{`{"remoteFileID":"` + fid + `","displayName":null,"declaredByteCount":3,"attemptRevision":1}`, `{"remoteFileID":"` + fid + `","displayName":"a","displayName":"b","declaredByteCount":3,"attemptRevision":1}`, `{"remoteFileID":"` + fid + `","displayName":"a","declaredByteCount":3,"attemptRevision":1,"unknown":true}`} {
		if w := request(r, "POST", "/api/files/reserve", body, cookie, csrf); w.Code < 400 {
			t.Fatal("accepted malformed", body)
		}
	}
	if w := request(r, "PUT", "/api/files/"+fid, "abc", cookie, ""); w.Code < 400 {
		t.Fatal("cookie-only mutation")
	}
	if called.Load() != 0 {
		t.Fatal("stage before validation")
	}
	r.Stop()
	if w := request(r, "GET", "/api/session", "", cookie, ""); w.Code < 400 {
		t.Fatal("old session survives")
	}
}

var _ http.Handler = (*Receiver)(nil)

func reserveFile(t *testing.T, r *Receiver, cookie, csrf, id string) {
	t.Helper()
	body := `{"remoteFileID":"` + id + `","displayName":"page.pdf","declaredByteCount":3,"attemptRevision":1}`
	w := request(r, "POST", "/api/files/reserve", body, cookie, csrf)
	if w.Code != 201 {
		t.Fatalf("reserve: %d %s", w.Code, w.Body)
	}
}
func TestStopWaitsForStagingAbortAndPreventsCommit(t *testing.T) {
	var commits atomic.Int32
	started := make(chan struct{})
	abortStarted := make(chan struct{})
	releaseAbort := make(chan struct{})
	r := receiver(t, func(ctx context.Context, _ string, _ int64, b io.Reader) (Staged, error) {
		close(started)
		<-ctx.Done()
		return blockingStaged{&commits, abortStarted, releaseAbort}, ctx.Err()
	})
	cookie, csrf := pair(t, r)
	reserveFile(t, r, cookie, csrf, fid)
	finished := make(chan struct{})
	go func() { request(r, "PUT", "/api/files/"+fid, "abc", cookie, csrf); close(finished) }()
	<-started
	stopped := make(chan struct{})
	go func() { r.Stop(); close(stopped) }()
	<-abortStarted
	select {
	case <-stopped:
		t.Fatal("Stop returned before staging cleanup")
	default:
	}
	close(releaseAbort)
	select {
	case <-stopped:
	case <-time.After(3 * time.Second):
		t.Fatal("Stop deadlocked")
	}
	<-finished
	if commits.Load() != 0 {
		t.Fatal("published after stop")
	}
}

type blockingStaged struct {
	commits          *atomic.Int32
	entered, release chan struct{}
}

func (s blockingStaged) Commit(context.Context) error { s.commits.Add(1); return nil }
func (s blockingStaged) Abort() error                 { close(s.entered); <-s.release; return nil }
func TestCancelCannotBeResurrectedByLateBodyOrReservation(t *testing.T) {
	var commits atomic.Int32
	started := make(chan struct{})
	release := make(chan struct{})
	r := receiver(t, func(ctx context.Context, _ string, _ int64, b io.Reader) (Staged, error) {
		io.Copy(io.Discard, b)
		close(started)
		<-release
		return staged{&commits}, nil
	})
	cookie, csrf := pair(t, r)
	reserveFile(t, r, cookie, csrf, fid)
	done := make(chan struct{})
	go func() { request(r, "PUT", "/api/files/"+fid, "abc", cookie, csrf); close(done) }()
	<-started
	q := httptest.NewRequest("POST", "http://"+authority+"/api/files/"+fid+"/cancel", nil)
	q.RemoteAddr = "192.168.50.3:12345"
	q.Header.Set("Origin", "http://"+authority)
	q.Header.Set("Cookie", cookie)
	q.Header.Set("X-Kinlogue-CSRF", csrf)
	q.Header.Set("X-Kinlogue-Attempt-Revision", "1")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, q)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	close(release)
	<-done
	reserveFile(t, r, cookie, csrf, fid)
	if commits.Load() != 0 {
		t.Fatal("late publish")
	}
	r.mu.Lock()
	state := r.files[fid].State
	r.mu.Unlock()
	if state != "cancelled" {
		t.Fatal("resurrected", state)
	}
}
func TestAdmissionDoesNotReadRejectedBody(t *testing.T) {
	r := receiver(t, func(context.Context, string, int64, io.Reader) (Staged, error) {
		t.Error("stage called")
		return nil, nil
	})
	cookie, csrf := pair(t, r)
	cases := []func(*http.Request){func(q *http.Request) { q.Host = "attacker.invalid" }, func(q *http.Request) { q.Header.Set("Origin", "http://attacker.invalid") }, func(q *http.Request) { q.RemoteAddr = "192.168.51.3:1234" }, func(q *http.Request) { q.Header.Del("X-Kinlogue-CSRF") }, func(q *http.Request) { q.Header.Add("Cookie", cookie) }, func(q *http.Request) { q.Header.Set("Expect", "100-continue") }, func(q *http.Request) { q.Header.Set("Content-Type", "text/plain") }}
	for _, mutate := range cases {
		b := &neverRead{t: t}
		q := httptest.NewRequest("PUT", "http://"+authority+"/api/files/"+fid, nil)
		q.Body = b
		q.ContentLength = 3
		q.RemoteAddr = "192.168.50.3:1234"
		q.Header.Set("Cookie", cookie)
		q.Header.Set("Origin", "http://"+authority)
		q.Header.Set("X-Kinlogue-CSRF", csrf)
		q.Header.Set("Content-Type", "application/octet-stream")
		mutate(q)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, q)
		if w.Code < 400 {
			t.Fatal("bad admission", w.Code)
		}
	}
}

type neverRead struct{ t *testing.T }

func (b *neverRead) Read([]byte) (int, error) { b.t.Error("unadmitted body read"); return 0, io.EOF }
func (*neverRead) Close() error               { return nil }

// HTML and CSS remain identical; client_test.go covers the Go retry fix.
func TestShellAssetsMatchReviewedSwiftClient(t *testing.T) {
	for _, n := range []string{"index.html", "styles.css"} {
		want, e := os.ReadFile("../../Sources/KinloguePlatform/Resources/LANUpload/" + n)
		if e != nil {
			t.Fatal(e)
		}
		got, e := assets.ReadFile("assets/" + n)
		if e != nil || !bytes.Equal(got, want) {
			t.Fatal("asset drift", n)
		}
	}
}
func TestPairCodeOneUseAndIdlePollDoesNotExtendLifetime(t *testing.T) {
	r := receiver(t, func(context.Context, string, int64, io.Reader) (Staged, error) { return nil, nil })
	code := r.PairingCode()
	cookie, _ := pair(t, r)
	if w := request(r, "POST", "/api/pair", `{"code":"`+code+`"}`, "", ""); w.Code < 400 {
		t.Fatal("reused code")
	}
	r.mu.Lock()
	before := r.activity
	r.mu.Unlock()
	if w := request(r, "GET", "/api/session", "", cookie, ""); w.Code != 200 {
		t.Fatal(w.Code)
	}
	r.mu.Lock()
	if !r.activity.Equal(before) {
		t.Error("poll refreshed idle")
	}
	r.activity = time.Now().Add(-16 * time.Minute)
	r.mu.Unlock()
	if w := request(r, "GET", "/api/session", "", cookie, ""); w.Code != 410 {
		t.Fatal(w.Code)
	}
}
func TestUploadLimitAndConcurrentStop(t *testing.T) {
	started := make(chan struct{}, 2)
	r := receiver(t, func(ctx context.Context, _ string, _ int64, _ io.Reader) (Staged, error) {
		started <- struct{}{}
		<-ctx.Done()
		return nil, ctx.Err()
	})
	cookie, csrf := pair(t, r)
	ids := []string{fid, "11234567-89ab-4cde-8fab-0123456789ab", "21234567-89ab-4cde-8fab-0123456789ab"}
	for _, id := range ids {
		reserveFile(t, r, cookie, csrf, id)
	}
	var wg sync.WaitGroup
	for _, id := range ids[:2] {
		wg.Add(1)
		go func() { defer wg.Done(); request(r, "PUT", "/api/files/"+id, "abc", cookie, csrf) }()
	}
	<-started
	<-started
	if w := request(r, "PUT", "/api/files/"+ids[2], "abc", cookie, csrf); w.Code != 429 {
		t.Fatal(w.Code)
	}
	for range 4 {
		wg.Add(1)
		go func() { defer wg.Done(); r.Stop() }()
	}
	wg.Wait()
}

func TestOptionalNullMediaTypeMatchesBrowserClient(t *testing.T) {
	r := receiver(t, func(context.Context, string, int64, io.Reader) (Staged, error) { return nil, nil })
	cookie, csrf := pair(t, r)
	w := request(r, "POST", "/api/files/reserve", `{"remoteFileID":"`+fid+`","displayName":"untyped","declaredByteCount":3,"attemptRevision":1,"mediaType":null}`, cookie, csrf)
	if w.Code != 201 {
		t.Fatal(w.Code, w.Body)
	}
}
func TestRawFramingRejectedBeforeHTTPNormalization(t *testing.T) {
	for _, head := range []string{"PUT / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\nabc", "PUT / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", "GET / HTTP/1.1\r\nHost: x\r\nHost: x\r\n\r\n"} {
		a, b := net.Pipe()
		go func() { defer b.Close(); io.WriteString(b, head) }()
		c := &headerConn{Conn: a, release: func() {}}
		buf := make([]byte, 8192)
		n, e := c.Read(buf)
		c.Close()
		if e == nil || n != 0 {
			t.Fatal("ambiguous head reached HTTP parser")
		}
	}
}
func TestRawHeaderPreservesStreamingBody(t *testing.T) {
	a, b := net.Pipe()
	head := "PUT / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc"
	go func() { defer b.Close(); io.WriteString(b, head) }()
	c := &headerConn{Conn: a, release: func() {}}
	got, e := io.ReadAll(c)
	c.Close()
	if e != nil || string(got) != head {
		t.Fatal("stream corrupted", e)
	}
}

func TestPartialAndOversizedBodiesNeverPublish(t *testing.T) {
	for _, body := range []string{"ab", "abcd"} {
		t.Run(body, func(t *testing.T) {
			var commits atomic.Int32
			r := receiver(t, func(ctx context.Context, _ string, _ int64, b io.Reader) (Staged, error) {
				_, e := io.Copy(io.Discard, b)
				return staged{&commits}, e
			})
			cookie, csrf := pair(t, r)
			reserveFile(t, r, cookie, csrf, fid)
			q := httptest.NewRequest("PUT", "http://"+authority+"/api/files/"+fid, strings.NewReader(body))
			q.ContentLength = -1
			q.TransferEncoding = []string{"chunked"}
			q.RemoteAddr = "192.168.50.3:1234"
			q.Header.Set("Origin", "http://"+authority)
			q.Header.Set("Content-Type", "application/octet-stream")
			q.Header.Set("Cookie", cookie)
			q.Header.Set("X-Kinlogue-CSRF", csrf)
			q.Header.Set("X-Kinlogue-Attempt-Revision", "1")
			w := httptest.NewRecorder()
			r.ServeHTTP(w, q)
			if w.Code < 400 || commits.Load() != 0 {
				t.Fatal("invalid bytes published")
			}
		})
	}
}
func TestInterruptedAttemptRequiresNewRevision(t *testing.T) {
	var calls atomic.Int32
	r := receiver(t, func(context.Context, string, int64, io.Reader) (Staged, error) {
		calls.Add(1)
		return nil, io.ErrUnexpectedEOF
	})
	cookie, csrf := pair(t, r)
	reserveFile(t, r, cookie, csrf, fid)
	request(r, "PUT", "/api/files/"+fid, "abc", cookie, csrf)
	request(r, "PUT", "/api/files/"+fid, "abc", cookie, csrf)
	if calls.Load() != 1 {
		t.Fatal("reused interrupted attempt")
	}
	body := `{"remoteFileID":"` + fid + `","displayName":"page.pdf","declaredByteCount":3,"attemptRevision":2}`
	if w := request(r, "POST", "/api/files/reserve", body, cookie, csrf); w.Code != 201 {
		t.Fatal(w.Code, w.Body)
	}
}
func TestChangedNetworkPreventsPublication(t *testing.T) {
	var commits atomic.Int32
	var valid atomic.Bool
	valid.Store(true)
	r, e := New(Config{Authority: authority, Prefix: netip.MustParsePrefix("192.168.50.0/24"), ValidateNetwork: valid.Load, Stage: func(ctx context.Context, _ string, _ int64, b io.Reader) (Staged, error) {
		io.Copy(io.Discard, b)
		valid.Store(false)
		return staged{&commits}, nil
	}})
	if e != nil {
		t.Fatal(e)
	}
	defer r.Stop()
	cookie, csrf := pair(t, r)
	reserveFile(t, r, cookie, csrf, fid)
	if w := request(r, "PUT", "/api/files/"+fid, "abc", cookie, csrf); w.Code < 400 || commits.Load() != 0 {
		t.Fatal("changed network published")
	}
}

type endpointConn struct {
	net.Conn
	remote string
}

func (c endpointConn) RemoteAddr() net.Addr { return stringAddr(c.remote) }

type stringAddr string

func (a stringAddr) Network() string { return "tcp" }
func (a stringAddr) String() string  { return string(a) }

type pipeListener struct{ conns chan net.Conn }

func (l *pipeListener) Accept() (net.Conn, error) {
	c, ok := <-l.conns
	if !ok {
		return nil, net.ErrClosed
	}
	return c, nil
}
func (l *pipeListener) Close() error   { close(l.conns); return nil }
func (l *pipeListener) Addr() net.Addr { return stringAddr(authority) }
func TestPeerAdmissionPrecedesHTTPReads(t *testing.T) {
	r := receiver(t, func(context.Context, string, int64, io.Reader) (Staged, error) { return nil, nil })
	bad, badPeer := net.Pipe()
	good, goodPeer := net.Pipe()
	defer badPeer.Close()
	defer goodPeer.Close()
	base := &pipeListener{make(chan net.Conn, 2)}
	base.conns <- endpointConn{bad, "192.168.51.3:1234"}
	base.conns <- endpointConn{good, "192.168.50.3:1234"}
	l := &peerListener{Listener: base, receiver: r, slots: make(chan struct{}, 64)}
	accepted, e := l.Accept()
	if e != nil {
		t.Fatal(e)
	}
	defer accepted.Close()
	_ = badPeer.SetReadDeadline(time.Now().Add(time.Second))
	var b [1]byte
	if _, e = badPeer.Read(b[:]); e != io.EOF {
		t.Fatal("cross-prefix connection was not closed before HTTP", e)
	}
}

// A snapshot can hold the store lock while Commit waits for it. Revocation and
// transport closure must not wait behind that publication lock.
type waitingCommit struct {
	entered chan context.Context
	release chan struct{}
}

func (s waitingCommit) Commit(ctx context.Context) error {
	s.entered <- ctx
	<-s.release
	return ctx.Err()
}
func (s waitingCommit) Abort() error { return nil }

type closingListener struct {
	entered, closed chan struct{}
	once            sync.Once
}

func (l *closingListener) Accept() (net.Conn, error) {
	l.once.Do(func() { close(l.entered) })
	<-l.closed
	return nil, net.ErrClosed
}
func (l *closingListener) Close() error {
	select {
	case <-l.closed:
	default:
		close(l.closed)
	}
	return nil
}
func (l *closingListener) Addr() net.Addr { return stringAddr(authority) }
func TestStopRevokesAndClosesBeforeBlockedCommitDrains(t *testing.T) {
	entered, release := make(chan context.Context, 1), make(chan struct{})
	r := receiver(t, func(_ context.Context, _ string, _ int64, b io.Reader) (Staged, error) {
		_, e := io.Copy(io.Discard, b)
		return waitingCommit{entered, release}, e
	})
	l := &closingListener{entered: make(chan struct{}), closed: make(chan struct{})}
	served := make(chan struct{})
	go func() { _ = r.Serve(l); close(served) }()
	<-l.entered
	cookie, csrf := pair(t, r)
	reserveFile(t, r, cookie, csrf, fid)
	uploaded := make(chan *httptest.ResponseRecorder, 1)
	go func() { uploaded <- request(r, "PUT", "/api/files/"+fid, "abc", cookie, csrf) }()
	ctx := <-entered
	stopped := make(chan struct{})
	go func() { r.Stop(); close(stopped) }()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Error("blocked commit prevented context revocation")
	}
	select {
	case <-l.closed:
	case <-time.After(time.Second):
		t.Error("blocked commit prevented listener closure")
	}
	select {
	case <-stopped:
		t.Error("stop returned before commit drained")
	default:
	}
	close(release)
	<-stopped
	<-served
	if w := <-uploaded; w.Code < 400 {
		t.Error("cancelled commit reported saved")
	}
}
func TestServerDiscardsTransportDiagnostics(t *testing.T) {
	r := receiver(t, func(context.Context, string, int64, io.Reader) (Staged, error) { return nil, nil })
	l := &closingListener{entered: make(chan struct{}), closed: make(chan struct{})}
	served := make(chan struct{})
	go func() { _ = r.Serve(l); close(served) }()
	<-l.entered
	if r.server.ErrorLog == nil || r.server.ErrorLog.Writer() != io.Discard {
		t.Error("HTTP diagnostics can expose remote address or panic contents")
	}
	r.Stop()
	<-served
}

type heldSnapshotWriter struct {
	entered, release chan struct{}
	once             sync.Once
}

func (w *heldSnapshotWriter) Write(b []byte) (int, error) {
	w.once.Do(func() { close(w.entered); <-w.release })
	return len(b), nil
}

type storeCommit struct {
	upload  *library.InboxUpload
	entered chan context.Context
}

func (s storeCommit) Commit(ctx context.Context) error {
	s.entered <- ctx
	_, e := s.upload.Commit(ctx)
	return e
}
func (s storeCommit) Abort() error { return s.upload.Abort() }
func TestSessionRevocationPreventsStoreCommitWaitingForSnapshot(t *testing.T) {
	for _, mode := range []string{"stop", "parent"} {
		t.Run(mode, func(t *testing.T) {
			store, e := library.Open(filepath.Join(t.TempDir(), "library"))
			if e != nil {
				t.Fatal(e)
			}
			defer store.Close()
			life, cancel := context.WithCancel(context.Background())
			defer cancel()
			writer := &heldSnapshotWriter{entered: make(chan struct{}), release: make(chan struct{})}
			snapshotDone := make(chan error, 1)
			entered := make(chan context.Context, 1)
			r, e := New(Config{Context: life, Authority: authority, Prefix: netip.MustParsePrefix("192.168.50.0/24"), ValidateNetwork: func() bool { return true }, Stage: func(ctx context.Context, n string, z int64, b io.Reader) (Staged, error) {
				u, e := store.StageInbox(ctx, n, z, b)
				if e != nil {
					return nil, e
				}
				go func() { _, e := store.WriteSnapshot(context.Background(), writer); snapshotDone <- e }()
				<-writer.entered
				return storeCommit{u, entered}, nil
			}})
			if e != nil {
				t.Fatal(e)
			}
			defer r.Stop()
			cookie, csrf := pair(t, r)
			reserveFile(t, r, cookie, csrf, fid)
			uploaded := make(chan *httptest.ResponseRecorder, 1)
			go func() { uploaded <- request(r, "PUT", "/api/files/"+fid, "abc", cookie, csrf) }()
			ctx := <-entered
			if mode == "parent" {
				cancel()
				if ctx.Err() == nil {
					t.Error("parent cancellation did not synchronously reach publication context")
				}
			} else {
				go r.Stop()
				select {
				case <-ctx.Done():
				case <-time.After(time.Second):
					t.Error("stop did not revoke waiting publication")
				}
			}
			close(writer.release)
			if e := <-snapshotDone; e != nil {
				t.Fatal(e)
			}
			if w := <-uploaded; w.Code < 400 {
				t.Error("revoked upload reported saved")
			}
			r.Stop()
			items, e := store.Inbox(context.Background())
			if e != nil || len(items) != 0 {
				t.Fatalf("revoked upload reached durable inbox: %d, %v", len(items), e)
			}
		})
	}
}

func TestSessionHasNonRenewableDeadline(t *testing.T) {
	r := receiver(t, func(context.Context, string, int64, io.Reader) (Staged, error) { return nil, nil })
	deadline, ok := r.ctx.Deadline()
	if !ok || deadline.Sub(r.created) > 15*time.Minute || deadline.Sub(r.created) < 14*time.Minute {
		t.Fatal("session needs an absolute bound independent of phone activity")
	}
	cookie, csrf := pair(t, r)
	reserveFile(t, r, cookie, csrf, fid)
	r.mu.Lock()
	r.activity = time.Now().Add(time.Hour)
	r.mu.Unlock()
	next, ok := r.ctx.Deadline()
	if !ok || !next.Equal(deadline) {
		t.Fatal("accepted activity extended absolute session bound")
	}
}

func TestAbsoluteDeadlineRevokesDespiteFreshActivity(t *testing.T) {
	r, err := newReceiver(Config{Authority: authority, Prefix: netip.MustParsePrefix("192.168.50.0/24"), ValidateNetwork: func() bool { return true }, Stage: func(context.Context, string, int64, io.Reader) (Staged, error) { return nil, nil }}, 100*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.Stop)
	r.mu.Lock()
	r.paired = true
	r.activity = time.Now().Add(time.Hour)
	r.mu.Unlock()
	select {
	case <-r.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("traffic can keep session alive beyond absolute deadline")
	}
	if r.Active() || r.PairingCode() != "" {
		t.Fatal("expired session proof retained")
	}
}
