package app

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"kinlogue/internal/document"
	"kinlogue/internal/lan"
	"kinlogue/internal/library"
	"kinlogue/internal/macos"
	"net"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func inboxFixture(t *testing.T, s *library.Store) library.InboxItem {
	t.Helper()
	u, e := s.StageInbox(context.Background(), "synthetic.pdf", 3, strings.NewReader("abc"))
	if e != nil {
		t.Fatal(e)
	}
	r, e := u.Commit(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	return r
}
func TestInboxRecognitionAndArchive(t *testing.T) {
	a, s := newTestService(t, processor{func(context.Context, []byte) (document.Extraction, error) { return synthetic(), nil }})
	r := inboxFixture(t, s)
	got, e := a.RetryInbox(context.Background(), library.InboxSelection{ID: r.ID, Revision: r.Revision})
	if e != nil || got.Status != "reviewable" {
		t.Fatalf("recognize %v %s", e, got.Status)
	}
	m, e := a.AddMember(context.Background(), "Synthetic member")
	if e != nil {
		t.Fatal(e)
	}
	report, e := a.ArchiveInbox(context.Background(), []library.InboxSelection{{ID: got.ID, Revision: got.Revision}}, library.Edit{MemberID: m.ID, Title: "Synthetic", Date: "2026-10-09"})
	if e != nil || report.Status != "review" {
		t.Fatalf("archive %v %s", e, report.Status)
	}
	rows, e := a.Inbox(context.Background())
	if e != nil || len(rows) != 0 {
		t.Fatal("inbox retained", e)
	}
}
func TestCloseWaitsForInboxNativeRecognition(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	a, s := newTestService(t, processor{func(context.Context, []byte) (document.Extraction, error) {
		close(entered)
		<-release
		return synthetic(), nil
	}})
	r := inboxFixture(t, s)
	done := make(chan error, 1)
	go func() {
		_, e := a.RetryInbox(context.Background(), library.InboxSelection{ID: r.ID, Revision: r.Revision})
		done <- e
	}()
	<-entered
	closed := make(chan error, 1)
	go func() { closed <- a.Close() }()
	select {
	case <-closed:
		t.Fatal("closed before OCR drained")
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	if e := <-done; !errors.Is(e, context.Canceled) {
		t.Fatalf("late extraction accepted: %v", e)
	}
	if e := <-closed; e != nil {
		t.Fatal(e)
	}
}

// syntheticListener never opens a socket. HTTP requests below enter the same
// receiver handler directly while Serve waits for this listener to close.
type syntheticListener struct {
	done chan struct{}
	once sync.Once
}

func (l *syntheticListener) Accept() (net.Conn, error) { <-l.done; return nil, net.ErrClosed }
func (l *syntheticListener) Close() error              { l.once.Do(func() { close(l.done) }); return nil }
func (l *syntheticListener) Addr() net.Addr {
	return &net.TCPAddr{IP: net.IPv4(192, 168, 50, 2), Port: 8080}
}
func startSyntheticLAN(t *testing.T, a *Service) *lan.Receiver {
	t.Helper()
	iface := macos.LANInterface{Name: "synthetic", Index: 1, Address: netip.MustParseAddr("192.168.50.2"), PrefixBits: 24}
	e := a.ConfigureLAN(LANConfig{Interfaces: func() ([]macos.LANInterface, error) { return []macos.LANInterface{iface}, nil }, Listen: func(context.Context, macos.LANInterface) (net.Listener, error) {
		return &syntheticListener{done: make(chan struct{})}, nil
	}, Watch: func(context.Context, macos.LANInterface, func()) (func(), error) { return func() {}, nil }})
	if e != nil {
		t.Fatal(e)
	}
	if a.LANStatus().Active {
		t.Fatal("configuration started receiver")
	}
	if _, e = a.StartLAN(context.Background(), iface); e != nil {
		t.Fatal(e)
	}
	c := a.lanController()
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.session.receiver
}
func phoneRequest(r *lan.Receiver, method, path, body, cookie, csrf string) *httptest.ResponseRecorder {
	q := httptest.NewRequest(method, "http://192.168.50.2:8080"+path, strings.NewReader(body))
	q.RemoteAddr = "192.168.50.3:12345"
	q.Header.Set("Origin", "http://192.168.50.2:8080")
	q.Header.Set("Cookie", cookie)
	q.Header.Set("X-Kinlogue-CSRF", csrf)
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
func TestLANHTTPCommitStopDrainsOCRAndPreservesInbox(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	a, s := newTestService(t, processor{func(context.Context, []byte) (document.Extraction, error) {
		close(entered)
		<-release
		return synthetic(), nil
	}})
	r := startSyntheticLAN(t, a)
	paired := phoneRequest(r, "POST", "/api/pair", `{"code":"`+r.PairingCode()+`"}`, "", "")
	if paired.Code != 200 {
		t.Fatalf("pair: %d", paired.Code)
	}
	var response struct {
		CSRF string `json:"csrfToken"`
	}
	if e := json.Unmarshal(paired.Body.Bytes(), &response); e != nil {
		t.Fatal(e)
	}
	cookie := strings.Split(paired.Header().Get("Set-Cookie"), ";")[0]
	const id = "01234567-89ab-4cde-8fab-0123456789ab"
	reserve := phoneRequest(r, "POST", "/api/files/reserve", `{"remoteFileID":"`+id+`","displayName":"synthetic.pdf","declaredByteCount":3,"attemptRevision":1}`, cookie, response.CSRF)
	if reserve.Code != 201 {
		t.Fatalf("reserve: %d", reserve.Code)
	}
	upload := phoneRequest(r, "PUT", "/api/files/"+id, "abc", cookie, response.CSRF)
	if upload.Code != 200 {
		t.Fatalf("upload: %d", upload.Code)
	}
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("OCR not scheduled")
	}
	stopped := make(chan struct{})
	go func() { a.StopLAN(); close(stopped) }()
	select {
	case <-stopped:
		t.Fatal("stop returned before native OCR")
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("stop deadlock")
	}
	rows, e := s.Inbox(context.Background())
	if e != nil || len(rows) != 1 || rows[0].Status != "failed" || rows[0].Failure != "cancelled" {
		t.Fatalf("stopped queue: %#v %v", rows, e)
	}
	if a.LANStatus().Active {
		t.Fatal("receiver remains active")
	}
	if phoneRequest(r, "GET", "/api/session", "", cookie, "").Code < 400 {
		t.Fatal("old capability survives stop")
	}
}

func TestRestoreActivationRevokesLANBeforeLibraryReplacement(t *testing.T) {
	b, a, _, _, _ := backupFixture(t)
	ctx := context.Background()
	code := backupCode(t)
	if _, e := b.CreateBackup(ctx, "synthetic", code); e != nil {
		t.Fatal(e)
	}
	prepared, e := b.PrepareRestore(ctx, "synthetic", code)
	if e != nil {
		t.Fatal(e)
	}
	r := startSyntheticLAN(t, a)
	required, e := b.ActivateRestore(prepared.Handle)
	if e != nil || !required {
		t.Fatalf("restore: %v", e)
	}
	if a.LANStatus().Active || r.Active() {
		t.Fatal("receiver survived replacement")
	}
	if _, e = a.Inbox(ctx); !errors.Is(e, ErrClosed) {
		t.Fatal("old service accepted command")
	}
}

func TestLANWatcherFailureNeverOpensListener(t *testing.T) {
	a, _ := newTestService(t, processor{func(context.Context, []byte) (document.Extraction, error) { return synthetic(), nil }})
	iface := macos.LANInterface{Name: "synthetic", Index: 1, Address: netip.MustParseAddr("192.168.50.2"), PrefixBits: 24}
	e := a.ConfigureLAN(LANConfig{Interfaces: func() ([]macos.LANInterface, error) { return []macos.LANInterface{iface}, nil }, Listen: func(context.Context, macos.LANInterface) (net.Listener, error) {
		t.Error("listener opened without watcher")
		return nil, document.ErrUnavailable
	}, Watch: func(context.Context, macos.LANInterface, func()) (func(), error) { return nil, document.ErrUnavailable }})
	if e != nil {
		t.Fatal(e)
	}
	if _, e = a.StartLAN(context.Background(), iface); e == nil {
		t.Fatal("start without observer")
	}
	if a.LANStatus().Active {
		t.Fatal("failed start active")
	}
}
func TestInboxRecognitionFailureDoesNotBlockNextItem(t *testing.T) {
	a, s := newTestService(t, processor{func(_ context.Context, b []byte) (document.Extraction, error) {
		if string(b) == "abc" {
			return document.Extraction{}, document.ErrUnsupported
		}
		return synthetic(), nil
	}})
	first := inboxFixture(t, s)
	failed, e := a.RetryInbox(context.Background(), library.InboxSelection{ID: first.ID, Revision: first.Revision})
	if !errors.Is(e, document.ErrUnsupported) || failed.Status != "unsupported" {
		t.Fatalf("failure %v %#v", e, failed)
	}
	u, e := s.StageInbox(context.Background(), "next.pdf", 3, strings.NewReader("def"))
	if e != nil {
		t.Fatal(e)
	}
	second, e := u.Commit(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	ready, e := a.RetryInbox(context.Background(), library.InboxSelection{ID: second.ID, Revision: second.Revision})
	if e != nil || ready.Status != "reviewable" {
		t.Fatalf("next item blocked: %v", e)
	}
	if _, e = a.PreviewInbox(context.Background(), library.InboxSelection{ID: ready.ID, Revision: ready.Revision}, 1); e != nil {
		t.Fatal(e)
	}
	if _, e = a.PreviewInbox(context.Background(), library.InboxSelection{ID: ready.ID, Revision: second.Revision}, 1); !errors.Is(e, library.ErrState) {
		t.Fatal("stale selection rendered")
	}
}

func TestLANWatcherSynchronouslyRevokesWhileStopTransitionWaits(t *testing.T) {
	a, s := newTestService(t, processor{func(context.Context, []byte) (document.Extraction, error) { return synthetic(), nil }})
	iface := macos.LANInterface{Name: "synthetic", Index: 1, Address: netip.MustParseAddr("192.168.50.2"), PrefixBits: 24}
	var changed func()
	if e := a.ConfigureLAN(LANConfig{Interfaces: func() ([]macos.LANInterface, error) { return []macos.LANInterface{iface}, nil }, Listen: func(context.Context, macos.LANInterface) (net.Listener, error) {
		return &syntheticListener{done: make(chan struct{})}, nil
	}, Watch: func(_ context.Context, _ macos.LANInterface, f func()) (func(), error) {
		changed = f
		return func() {}, nil
	}}); e != nil {
		t.Fatal(e)
	}
	if _, e := a.StartLAN(context.Background(), iface); e != nil {
		t.Fatal(e)
	}
	c := a.lanController()
	c.mu.Lock()
	r := c.session.receiver
	c.mu.Unlock()
	c.transition.Lock()
	changed()
	if r.Active() {
		t.Error("network callback returned before receiver context was revoked")
	}
	c.transition.Unlock()
	a.StopLAN()
	rows, e := s.Inbox(context.Background())
	if e != nil || len(rows) != 0 {
		t.Fatal("unexpected publication", e)
	}
}

func TestLANRevocationPreservesSavedAndRetriesPartialInNewSession(t *testing.T) {
	ctx := context.Background()
	root := filepath.Join(t.TempDir(), "library")
	store, err := library.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	service := New(store, processor{func(context.Context, []byte) (document.Extraction, error) { return synthetic(), nil }}, nil, nil)
	t.Cleanup(func() { service.Close() })
	r := startSyntheticLAN(t, service)
	pairSession := func(r *lan.Receiver) (string, string) {
		t.Helper()
		w := phoneRequest(r, "POST", "/api/pair", `{"code":"`+r.PairingCode()+`"}`, "", "")
		var proof struct {
			CSRF string `json:"csrfToken"`
		}
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &proof) != nil {
			t.Fatal("pair failed")
		}
		return strings.Split(w.Header().Get("Set-Cookie"), ";")[0], proof.CSRF
	}
	cookie, csrf := pairSession(r)
	const savedID = "01234567-89ab-4cde-8fab-0123456789ab"
	const partialID = "11234567-89ab-4cde-8fab-0123456789ab"
	reserve := func(r *lan.Receiver, id, cookie, csrf string) {
		t.Helper()
		w := phoneRequest(r, "POST", "/api/files/reserve", `{"remoteFileID":"`+id+`","displayName":"synthetic.pdf","declaredByteCount":3,"attemptRevision":1}`, cookie, csrf)
		if w.Code != 201 {
			t.Fatal("reserve failed", w.Code)
		}
	}
	reserve(r, savedID, cookie, csrf)
	if w := phoneRequest(r, "PUT", "/api/files/"+savedID, "abc", cookie, csrf); w.Code != 200 {
		t.Fatal("saved upload failed", w.Code)
	}
	reserve(r, partialID, cookie, csrf)
	reader, writer := io.Pipe()
	defer writer.Close()
	q := httptest.NewRequest("PUT", "http://192.168.50.2:8080/api/files/"+partialID, reader)
	q.RemoteAddr = "192.168.50.3:12345"
	q.ContentLength = 3
	q.Header.Set("Origin", "http://192.168.50.2:8080")
	q.Header.Set("Cookie", cookie)
	q.Header.Set("X-Kinlogue-CSRF", csrf)
	q.Header.Set("Content-Type", "application/octet-stream")
	q.Header.Set("X-Kinlogue-Attempt-Revision", "1")
	done := make(chan int, 1)
	go func() { w := httptest.NewRecorder(); r.ServeHTTP(w, q); done <- w.Code }()
	if _, err = writer.Write([]byte("x")); err != nil {
		t.Fatal(err)
	}
	controller := service.lanController()
	controller.transition.Lock()
	service.RevokeLAN()
	revoked := !r.Active()
	controller.transition.Unlock()
	if !revoked {
		t.Fatal("revocation waited for teardown transition")
	}
	select {
	case code := <-done:
		if code < 400 {
			t.Fatal("partial reported saved")
		}
	case <-time.After(time.Second):
		t.Fatal("partial read not cancelled")
	}
	// Observe autonomous teardown; calling StopLAN here would hide a broken
	// RevokeLAN drain path. Acquire transition only after session removal.
	deadline := time.After(time.Second)
	for {
		controller.mu.Lock()
		removed := controller.session == nil
		controller.mu.Unlock()
		if removed {
			break
		}
		select {
		case <-deadline:
			t.Fatal("revocation did not remove session")
		case <-time.After(time.Millisecond):
		}
	}
	drained := make(chan struct{})
	go func() { controller.transition.Lock(); controller.transition.Unlock(); close(drained) }()
	select {
	case <-drained:
	case <-time.After(time.Second):
		t.Fatal("revocation did not drain")
	}
	if service.LANStatus().Active {
		t.Fatal("old reception restarted")
	}
	rows, err := store.Inbox(ctx)
	if err != nil || len(rows) != 1 {
		t.Fatal("partial entered inbox or saved item lost", err)
	}
	bytes, err := store.ReadInboxOriginal(ctx, rows[0].ID, rows[0].Revision)
	if err != nil || string(bytes) != "abc" {
		t.Fatal("saved bytes changed", err)
	}
	files, err := os.ReadDir(filepath.Join(root, "originals"))
	if err != nil || len(files) != 1 || !strings.HasSuffix(files[0].Name(), ".blob") {
		t.Fatal("partial not cleaned", err)
	}
	iface := macos.LANInterface{Name: "synthetic", Index: 1, Address: netip.MustParseAddr("192.168.50.2"), PrefixBits: 24}
	if _, err = service.StartLAN(ctx, iface); err != nil {
		t.Fatal(err)
	}
	controller.mu.Lock()
	next := controller.session.receiver
	controller.mu.Unlock()
	if phoneRequest(next, "GET", "/api/session", "", cookie, "").Code < 400 {
		t.Fatal("new session accepted old proof")
	}
	if phoneRequest(r, "GET", "/api/session", "", cookie, "").Code < 400 {
		t.Fatal("old session revived")
	}
	cookie, csrf = pairSession(next)
	reserve(next, partialID, cookie, csrf)
	if w := phoneRequest(next, "PUT", "/api/files/"+partialID, "xyz", cookie, csrf); w.Code != 200 {
		t.Fatal("explicit new-session retry failed", w.Code)
	}
	service.StopLAN()
	rows, err = store.Inbox(ctx)
	if err != nil || len(rows) != 2 {
		t.Fatal("retry failed to save exactly one complete item", err)
	}
}

func TestLANRevocationCancelsStartingSession(t *testing.T) {
	service, _ := newTestService(t, processor{func(context.Context, []byte) (document.Extraction, error) { return synthetic(), nil }})
	iface := macos.LANInterface{Name: "synthetic", Index: 1, Address: netip.MustParseAddr("192.168.50.2"), PrefixBits: 24}
	entered := make(chan struct{})
	err := service.ConfigureLAN(LANConfig{Interfaces: func() ([]macos.LANInterface, error) { return []macos.LANInterface{iface}, nil }, Watch: func(context.Context, macos.LANInterface, func()) (func(), error) { return func() {}, nil }, Listen: func(ctx context.Context, _ macos.LANInterface) (net.Listener, error) {
		close(entered)
		<-ctx.Done()
		return nil, ctx.Err()
	}})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { _, err := service.StartLAN(context.Background(), iface); done <- err }()
	<-entered
	service.RevokeLAN()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("revoked startup succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("startup not cancelled")
	}
	if service.LANStatus().Active {
		t.Fatal("revoked startup published a session")
	}
}

// admissionContext pauses an admitted command before it reaches the transition.
type admissionContext struct {
	context.Context
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (c *admissionContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.entered); <-c.release })
	return c.Context.Done()
}
func TestLANRevocationRejectsQueuedStart(t *testing.T) {
	service, _ := newTestService(t, processor{func(context.Context, []byte) (document.Extraction, error) { return synthetic(), nil }})
	startSyntheticLAN(t, service)
	service.StopLAN()
	c := service.lanController()
	listen := c.config.Listen
	listens := 0
	c.config.Listen = func(ctx context.Context, iface macos.LANInterface) (net.Listener, error) {
		listens++
		return listen(ctx, iface)
	}
	iface := macos.LANInterface{Name: "synthetic", Index: 1, Address: netip.MustParseAddr("192.168.50.2"), PrefixBits: 24}
	ctx := &admissionContext{Context: context.Background(), entered: make(chan struct{}), release: make(chan struct{})}
	c.transition.Lock()
	done := make(chan error, 1)
	go func() { _, err := service.StartLAN(ctx, iface); done <- err }()
	<-ctx.entered
	service.RevokeLAN()
	close(ctx.release)
	c.transition.Unlock()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("queued start survived revocation")
		}
	case <-time.After(time.Second):
		t.Fatal("queued start did not return")
	}
	if service.LANStatus().Active || listens != 0 {
		t.Fatal("revoked request reached listener or published session")
	}
	if _, err := service.StartLAN(context.Background(), iface); err != nil {
		t.Fatal("fresh explicit start rejected", err)
	}
	service.StopLAN()
}
