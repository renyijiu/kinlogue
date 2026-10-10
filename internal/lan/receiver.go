package lan

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

// Staged is unpublished, complete storage. Commit must perform only the bounded
// durable publication, never recognition or a callback into Receiver. Abort
// releases staging resources and is also called after Commit.
type Staged interface {
	Commit(context.Context) error
	Abort() error
}
type Config struct {
	// Context owns the session lifetime. Cancellation propagates synchronously
	// through request and publication contexts; nil means Background.
	Context   context.Context
	Authority string
	Prefix    netip.Prefix
	Stage     func(context.Context, string, int64, io.Reader) (Staged, error)
	// ValidateNetwork verifies the selected interface, address and netmask are
	// still identical. It must be fast and must not call back into Receiver.
	ValidateNetwork func() bool
}

const MaxFileBytes int64 = 100 * 1024 * 1024

// Session timing follows the Swift receiver contract: an unpaired code expires
// after PairingLifetime; a paired session ends after SessionIdleTimeout without
// accepted activity (pairing, reservation, cancellation, upload bytes or a saved
// upload). Session polling alone never extends it. Manual stop, lifecycle and
// network revocation end the session immediately regardless of activity.
const (
	PairingLifetime    = 10 * time.Minute
	SessionIdleTimeout = 15 * time.Minute
)

// Per-request transport deadlines match the Swift handler: request heads must
// arrive promptly, JSON bodies are small, and an upload body may stream for at
// most uploadBodyDeadline as long as bytes keep arriving within
// uploadProgressDeadline. They are variables only so tests can shorten them.
var (
	requestHeadDeadline    = 15 * time.Second
	requestDeadline        = 30 * time.Second
	uploadProgressDeadline = 30 * time.Second
	uploadBodyDeadline     = 15 * time.Minute
)

const cookieName = "KinlogueLANSession"

var errEnded = errors.New("LAN session ended")

//go:embed assets/*
var assets embed.FS

type fileStatus struct {
	ID       string `json:"remoteFileID"`
	Name     string `json:"displayName"`
	Size     int64  `json:"declaredByteCount"`
	Received int64  `json:"receivedByteCount"`
	Revision uint64 `json:"attemptRevision"`
	State    string `json:"state"`
}
type file struct {
	fileStatus
	cancel context.CancelFunc
}
type rate struct {
	start              time.Time
	requests, failures int
	poll               time.Time
}

// Receiver owns exactly one ephemeral session. Construct a new Receiver after
// every stop; it never restarts or imports previous credentials or receipts.
type Receiver struct {
	config             Config
	mu                 sync.Mutex // publication, reservations and receipts share this gate
	serverMu           sync.Mutex // socket shutdown must never wait behind publication
	code, cookie, csrf string
	paired, stopped    bool
	created, activity  time.Time
	pairing, idle      time.Duration
	files              map[string]*file
	peers              map[netip.Addr]*rate
	global             rate
	uploads            int
	ctx                context.Context
	cancel             context.CancelFunc
	handlers           sync.WaitGroup
	stopOnce           sync.Once
	done               chan struct{}
	server             *http.Server
}

func New(c Config) (*Receiver, error) { return newReceiver(c, PairingLifetime, SessionIdleTimeout) }

func newReceiver(c Config, pairing, idle time.Duration) (*Receiver, error) {
	ap, e := netip.ParseAddrPort(c.Authority)
	if e != nil || ap.Port() == 0 || ap.Addr().IsUnspecified() || ap.Addr().IsMulticast() || ap.Addr().Is4In6() || ap.Addr().Zone() != "" || !c.Prefix.IsValid() || c.Prefix.Bits() == 0 || !c.Prefix.Contains(ap.Addr()) || c.Prefix.Addr().Is4In6() || c.Stage == nil || c.ValidateNetwork == nil {
		return nil, errors.New("invalid LAN configuration")
	}
	n, e := rand.Int(rand.Reader, big.NewInt(1000000))
	if e != nil {
		return nil, e
	}
	token := func() (string, error) {
		b := make([]byte, 32)
		_, e := rand.Read(b)
		return base64.RawURLEncoding.EncodeToString(b), e
	}
	cookie, e := token()
	if e != nil {
		return nil, e
	}
	csrf, e := token()
	if e != nil {
		return nil, e
	}
	parent := c.Context
	if parent == nil {
		parent = context.Background()
	}
	if pairing <= 0 || idle <= 0 {
		return nil, errors.New("invalid LAN session timing")
	}
	ctx, cancel := context.WithCancel(parent)
	now := time.Now()
	r := &Receiver{config: c, code: fmt.Sprintf("%06d", n.Int64()), cookie: cookie, csrf: csrf, created: now, activity: now, pairing: pairing, idle: idle, files: map[string]*file{}, peers: map[netip.Addr]*rate{}, ctx: ctx, cancel: cancel, done: make(chan struct{})}
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				r.Stop()
				return
			case <-ticker.C:
				r.mu.Lock()
				expired := r.expiredLocked()
				r.mu.Unlock()
				if expired || !c.ValidateNetwork() {
					r.Stop()
					return
				}
			}
		}
	}()
	return r, nil
}
func (r *Receiver) PairingCode() string {
	if r.ctx.Err() != nil {
		return ""
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.ctx.Err() != nil {
		return ""
	}
	return r.code
}
func (r *Receiver) Active() bool {
	if r.ctx.Err() != nil {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.ctx.Err() == nil && !r.stopped && !r.expiredLocked()
}
func (r *Receiver) Done() <-chan struct{} { return r.done }
func (r *Receiver) expiredLocked() bool {
	if r.paired {
		return time.Since(r.activity) >= r.idle
	}
	return time.Since(r.created) >= r.pairing
}
func (r *Receiver) revokeLocked() {
	r.stopped = true
	r.code = ""
	r.cookie = ""
	r.csrf = ""
	r.cancel()
	for _, f := range r.files {
		if f.cancel != nil {
			f.cancel()
		}
	}
}

// Stop cancels publication and closes sockets before waiting for the publication
// gate and staging cleanup. It
// must not be called synchronously by Stage/Commit or from ServeHTTP itself.
func (r *Receiver) Stop() {
	r.stopOnce.Do(func() {
		r.cancel()
		r.serverMu.Lock()
		s := r.server
		r.serverMu.Unlock()
		if s != nil {
			_ = s.Close()
		}
		r.mu.Lock()
		r.revokeLocked()
		r.mu.Unlock()
		r.handlers.Wait()
		r.mu.Lock()
		r.files = nil
		r.peers = nil
		r.global = rate{}
		r.mu.Unlock()
		close(r.done)
	})
	<-r.done
}

// Serve accepts an already-bound exact-address listener. Peer prefix admission
// happens in Accept before net/http can read a single byte. Stop owns teardown.
func (r *Receiver) Serve(l net.Listener) error {
	if l == nil {
		return errors.New("missing LAN listener")
	}
	if l.Addr().String() != r.config.Authority {
		_ = l.Close()
		return errors.New("listener address mismatch")
	}
	r.serverMu.Lock()
	if r.ctx.Err() != nil || r.server != nil {
		r.serverMu.Unlock()
		_ = l.Close()
		return errEnded
	}
	s := &http.Server{ErrorLog: log.New(io.Discard, "", 0), Handler: r, ReadHeaderTimeout: requestHeadDeadline, ReadTimeout: requestDeadline, WriteTimeout: requestDeadline, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 16 * 1024, BaseContext: func(net.Listener) context.Context { return r.ctx }}
	r.server = s
	r.serverMu.Unlock()
	e := s.Serve(&peerListener{Listener: l, receiver: r, slots: make(chan struct{}, 64)})
	r.Stop()
	if errors.Is(e, http.ErrServerClosed) {
		return nil
	}
	return e
}

type peerListener struct {
	net.Listener
	receiver *Receiver
	slots    chan struct{}
}

func (l *peerListener) Accept() (net.Conn, error) {
	for {
		c, e := l.Listener.Accept()
		if e != nil {
			return nil, e
		}
		ap, e := netip.ParseAddrPort(c.RemoteAddr().String())
		if e != nil || !l.receiver.peerOK(ap.Addr()) || !l.receiver.config.ValidateNetwork() {
			_ = c.Close()
			continue
		}
		select {
		case l.slots <- struct{}{}:
			return &headerConn{Conn: c, release: func() { <-l.slots }}, nil
		default:
			_ = c.Close()
		}
	}
}
func (r *Receiver) peerOK(a netip.Addr) bool {
	return a.IsValid() && !a.Is4In6() && a.Zone() == "" && r.config.Prefix.Contains(a)
}
func equal(a, b string) bool { return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1 }
func reject(w http.ResponseWriter, status int) {
	code := "requestRejected"
	if status == 429 {
		code = "retryLater"
	}
	if status == 410 {
		code = "sessionEnded"
	}
	respond(w, status, map[string]any{"error": code, "retryable": status == 429})
}
func respond(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if v != nil {
		_ = json.NewEncoder(w).Encode(v)
	}
}
func security(w http.ResponseWriter) {
	for k, v := range map[string]string{"Cache-Control": "no-store", "Pragma": "no-cache", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY", "Cross-Origin-Resource-Policy": "same-origin", "Content-Security-Policy": "default-src 'none'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; connect-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'"} {
		w.Header().Set(k, v)
	}
}
func canonicalID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range []byte(s) {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
		} else if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
func route(q *http.Request) (kind, id string) {
	p := q.URL.EscapedPath()
	if q.URL.RawQuery != "" || q.URL.ForceQuery || q.URL.IsAbs() && q.URL.Host != q.Host {
		return "", ""
	}
	if q.Method == "GET" && (p == "/" || p == "/styles.css" || p == "/app.js") {
		return "asset", p
	}
	if q.Method == "POST" && p == "/api/pair" {
		return "pair", ""
	}
	if q.Method == "GET" && p == "/api/session" {
		return "session", ""
	}
	if q.Method == "POST" && p == "/api/session/logout" {
		return "logout", ""
	}
	if q.Method == "POST" && p == "/api/files/reserve" {
		return "reserve", ""
	}
	parts := strings.Split(p, "/")
	if len(parts) >= 4 && parts[0] == "" && parts[1] == "api" && parts[2] == "files" && canonicalID(parts[3]) {
		if len(parts) == 4 {
			if q.Method == "PUT" {
				return "upload", parts[3]
			}
			if q.Method == "GET" {
				return "status", parts[3]
			}
		}
		if len(parts) == 5 && parts[4] == "cancel" && q.Method == "POST" {
			return "cancel", parts[3]
		}
	}
	return "", ""
}
func framing(q *http.Request, kind string) bool {
	for _, h := range []string{"Content-Length", "Content-Type", "Origin", "Cookie", "X-Kinlogue-CSRF", "X-Kinlogue-Attempt-Revision"} {
		if len(q.Header.Values(h)) > 1 {
			return false
		}
	}
	if q.Header.Get("Expect") != "" || len(q.Trailer) != 0 || len(q.TransferEncoding) > 1 || len(q.TransferEncoding) == 1 && q.TransferEncoding[0] != "chunked" || len(q.TransferEncoding) > 0 && q.Header.Get("Content-Length") != "" {
		return false
	}
	switch kind {
	case "pair", "reserve":
		return strings.ToLower(q.Header.Get("Content-Type")) == "application/json" && q.ContentLength <= 65536
	case "upload":
		return strings.ToLower(q.Header.Get("Content-Type")) == "application/octet-stream" && q.ContentLength <= MaxFileBytes
	default:
		return q.ContentLength == 0 && len(q.TransferEncoding) == 0
	}
}
func (r *Receiver) ServeHTTP(w http.ResponseWriter, q *http.Request) {
	security(w)
	// Close rejected requests instead of allowing net/http to drain unadmitted
	// bodies, including unauthorized uploads and Expect: 100-continue probes.
	w.Header().Set("Connection", "close")
	peer, e := netip.ParseAddrPort(q.RemoteAddr)
	if e != nil || !r.peerOK(peer.Addr()) {
		reject(w, 403)
		return
	}
	kind, id := route(q)
	if kind == "" {
		reject(w, 404)
		return
	}
	origin := q.Header.Get("Origin")
	if q.Host != r.config.Authority || !framing(q, kind) || (origin != "" && origin != "http://"+r.config.Authority) || (origin == "" && kind != "asset" && kind != "session") {
		reject(w, 403)
		return
	}
	if !r.config.ValidateNetwork() {
		go r.Stop()
		reject(w, 410)
		return
	}
	r.mu.Lock()
	if r.ctx.Err() != nil || r.stopped || r.expiredLocked() {
		r.mu.Unlock()
		go r.Stop()
		reject(w, 410)
		return
	}
	r.handlers.Add(1)
	r.mu.Unlock()
	defer r.handlers.Done()
	ctx, cancel := context.WithCancel(r.ctx)
	defer cancel()
	detach := context.AfterFunc(q.Context(), cancel)
	defer detach()
	closeBody := context.AfterFunc(ctx, func() { _ = q.Body.Close() })
	defer closeBody()
	if kind == "asset" {
		name := id
		if name == "/" {
			name = "/index.html"
		}
		b, _ := assets.ReadFile("assets" + name)
		ct := "text/html; charset=utf-8"
		if id == "/app.js" {
			ct = "text/javascript; charset=utf-8"
		}
		if id == "/styles.css" {
			ct = "text/css; charset=utf-8"
		}
		w.Header().Set("Content-Type", ct)
		w.WriteHeader(200)
		_, _ = w.Write(b)
		return
	}
	r.mu.Lock()
	if r.ctx.Err() != nil || r.stopped {
		r.mu.Unlock()
		reject(w, 410)
		return
	}
	now := time.Now()
	r.pruneLocked(now)
	pr := r.peers[peer.Addr()]
	if pr == nil {
		if len(r.peers) >= 1024 {
			r.mu.Unlock()
			reject(w, 429)
			return
		}
		pr = &rate{start: now}
		r.peers[peer.Addr()] = pr
	}
	if kind == "pair" {
		if pr.failures >= 5 || r.global.failures >= 30 {
			r.mu.Unlock()
			reject(w, 429)
			return
		}
		pr.failures++
		r.global.failures++
		r.mu.Unlock()
		var v struct {
			Code string `json:"code"`
		}
		if decode(q.Body, &v) != nil {
			reject(w, 400)
			return
		}
		r.mu.Lock()
		defer r.mu.Unlock()
		if r.ctx.Err() != nil || r.stopped || r.paired || r.expiredLocked() || !equal(v.Code, r.code) {
			reject(w, 403)
			return
		}
		r.paired = true
		r.code = ""
		r.activity = now
		http.SetCookie(w, &http.Cookie{Name: cookieName, Value: r.cookie, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode})
		respond(w, 200, map[string]any{"csrfToken": r.csrf})
		return
	}
	cookies := q.CookiesNamed(cookieName)
	if !r.paired || len(cookies) != 1 || !equal(cookies[0].Value, r.cookie) || (kind != "session" && !equal(q.Header.Get("X-Kinlogue-CSRF"), r.csrf)) {
		r.mu.Unlock()
		reject(w, 403)
		return
	}
	if kind != "upload" {
		if pr.requests >= 60 || r.global.requests >= 600 || (kind == "session" || kind == "status") && !pr.poll.IsZero() && now.Sub(pr.poll) < time.Second {
			r.mu.Unlock()
			reject(w, 429)
			return
		}
		pr.requests++
		r.global.requests++
		if kind == "session" || kind == "status" {
			pr.poll = now
		}
	}
	switch kind {
	case "session":
		values := make([]fileStatus, 0, len(r.files))
		for _, f := range r.files {
			values = append(values, f.fileStatus)
		}
		sort.Slice(values, func(i, j int) bool { return values[i].ID < values[j].ID })
		token := r.csrf
		r.mu.Unlock()
		respond(w, 200, map[string]any{"csrfToken": token, "files": values})
	case "logout":
		r.revokeLocked()
		r.mu.Unlock()
		http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: -1})
		respond(w, 204, nil)
		go r.Stop()
	case "reserve":
		r.mu.Unlock()
		r.reserve(w, q)
	case "status":
		f := r.files[id]
		if f == nil {
			r.mu.Unlock()
			reject(w, 404)
			return
		}
		v := f.fileStatus
		r.mu.Unlock()
		respond(w, 200, v)
	case "cancel":
		revision, ok := revision(q)
		f := r.files[id]
		if !ok || f != nil && (f.State == "saved" || revision < f.Revision) {
			r.mu.Unlock()
			reject(w, 409)
			return
		}
		if f == nil {
			if len(r.files) >= 1000 {
				r.mu.Unlock()
				reject(w, 429)
				return
			}
			f = &file{fileStatus: fileStatus{ID: id, Name: "file", Revision: revision}}
			r.files[id] = f
		}
		if f.cancel != nil {
			f.cancel()
		}
		f.State = "cancelled"
		f.Revision = revision
		r.activity = now
		r.mu.Unlock()
		respond(w, 200, map[string]any{"outcome": "cancelled"})
	case "upload":
		r.uploadLocked(w, q, ctx, id)
	default:
		r.mu.Unlock()
		reject(w, 404)
	}
}
func (r *Receiver) pruneLocked(now time.Time) {
	if now.Sub(r.global.start) >= time.Minute {
		r.global = rate{start: now}
	}
	for k, p := range r.peers {
		if now.Sub(p.start) >= time.Minute {
			delete(r.peers, k)
		}
	}
}
func revision(q *http.Request) (uint64, bool) {
	s := q.Header.Get("X-Kinlogue-Attempt-Revision")
	v, e := strconv.ParseUint(s, 10, 64)
	return v, e == nil && strconv.FormatUint(v, 10) == s && v <= 9007199254740991
}
func sanitize(s string) string {
	s = strings.Map(func(c rune) rune {
		if unicode.IsControl(c) || c == '/' || c == '\\' || c >= 0x202a && c <= 0x202e || c >= 0x2066 && c <= 0x2069 {
			return '_'
		}
		return c
	}, s)
	s = strings.TrimSpace(s)
	if s == "" {
		return "file"
	}
	return s
}
func (r *Receiver) reserve(w http.ResponseWriter, q *http.Request) {
	var v struct {
		ID       *string `json:"remoteFileID"`
		Name     *string `json:"displayName"`
		Size     *int64  `json:"declaredByteCount"`
		Media    *string `json:"mediaType,omitempty"`
		Revision *uint64 `json:"attemptRevision"`
	}
	if decode(q.Body, &v) != nil || v.ID == nil || v.Name == nil || v.Size == nil || v.Revision == nil || !canonicalID(*v.ID) || len(*v.Name) > 1024 || *v.Size < 0 || *v.Size > MaxFileBytes || *v.Revision > 9007199254740991 || v.Media != nil && (len(*v.Media) > 256 || strings.IndexFunc(*v.Media, unicode.IsControl) >= 0) {
		reject(w, 400)
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.ctx.Err() != nil || r.stopped || r.expiredLocked() {
		reject(w, 410)
		return
	}
	f := r.files[*v.ID]
	if f != nil {
		if f.State == "saved" || f.State == "cancelled" {
			respond(w, 201, map[string]any{"file": f.fileStatus})
			return
		}
		if f.State == "receiving" || *v.Revision < f.Revision || f.Size != *v.Size || f.Name != sanitize(*v.Name) {
			reject(w, 409)
			return
		}
		if f.State == "interrupted" && *v.Revision == f.Revision {
			reject(w, 409)
			return
		}
	} else {
		if len(r.files) >= 1000 {
			reject(w, 429)
			return
		}
		f = &file{}
		r.files[*v.ID] = f
	}
	f.fileStatus = fileStatus{ID: *v.ID, Name: sanitize(*v.Name), Size: *v.Size, Revision: *v.Revision, State: "reserved"}
	r.activity = time.Now()
	respond(w, 201, map[string]any{"file": f.fileStatus})
}

// uploadLocked always releases mu. Only final publication reacquires the gate,
// so slow phone reads do not block cancellation, desktop work or another file.
func (r *Receiver) uploadLocked(w http.ResponseWriter, q *http.Request, ctx context.Context, id string) {
	rev, ok := revision(q)
	f := r.files[id]
	if !ok || f == nil || rev != f.Revision || f.State == "cancelled" || f.State == "receiving" || f.State == "interrupted" {
		r.mu.Unlock()
		reject(w, 409)
		return
	}
	if q.ContentLength >= 0 && q.ContentLength != f.Size {
		r.mu.Unlock()
		reject(w, 400)
		return
	}
	if f.State == "saved" {
		r.activity = time.Now()
		r.mu.Unlock()
		respond(w, 200, map[string]any{"outcome": "saved"})
		return
	}
	if r.uploads >= 2 {
		r.mu.Unlock()
		reject(w, 429)
		return
	}
	uploadCtx, cancel := context.WithCancel(ctx)
	f.cancel = cancel
	f.State = "receiving"
	r.uploads++
	size, name := f.Size, f.Name
	r.mu.Unlock()
	defer cancel()
	closeBody := context.AfterFunc(uploadCtx, func() { _ = q.Body.Close() })
	defer closeBody()
	// The server-wide request deadline is too short for a large body. Replace it
	// with a progress deadline bounded by the total upload deadline; recorders and
	// other writers without deadline support keep the server defaults.
	transport := http.NewResponseController(w)
	uploadEnd := time.Now().Add(uploadBodyDeadline)
	_ = transport.SetWriteDeadline(uploadEnd.Add(requestDeadline))
	reader := &countReader{r: io.LimitReader(q.Body, size+1), ctx: uploadCtx, before: func() {
		next := time.Now().Add(uploadProgressDeadline)
		if next.After(uploadEnd) {
			next = uploadEnd
		}
		_ = transport.SetReadDeadline(next)
	}, progress: func(n int64) {
		r.mu.Lock()
		if f.State == "receiving" && f.Revision == rev {
			f.Received = min(n, size)
			if !r.stopped {
				r.activity = time.Now()
			}
		}
		r.mu.Unlock()
	}}
	staged, e := r.config.Stage(uploadCtx, name, size, reader)
	if e == nil {
		var b [1]byte
		_, end := reader.Read(b[:])
		if reader.n != size || end != io.EOF {
			e = errors.New("invalid upload length")
		}
	}
	// Network validation is performed outside mu: adapters can need OS locks.
	networkOK := r.config.ValidateNetwork()
	r.mu.Lock()
	if e == nil && staged != nil && !r.stopped && !r.expiredLocked() && networkOK && uploadCtx.Err() == nil && f.State == "receiving" && f.Revision == rev {
		e = staged.Commit(uploadCtx)
	} else if e == nil {
		e = errEnded
	}
	if e == nil {
		f.State = "saved"
		f.Received = size
		r.activity = time.Now()
	} else if f.State == "receiving" && f.Revision == rev {
		f.State = "interrupted"
	}
	f.cancel = nil
	r.uploads--
	r.mu.Unlock()
	if staged != nil {
		_ = staged.Abort()
	}
	if e != nil {
		reject(w, 409)
		return
	}
	respond(w, 200, map[string]any{"outcome": "saved"})
}

type countReader struct {
	r        io.Reader
	ctx      context.Context
	n        int64
	before   func()
	progress func(int64)
}

func (r *countReader) Read(b []byte) (int, error) {
	if e := r.ctx.Err(); e != nil {
		return 0, e
	}
	if r.before != nil {
		r.before()
	}
	if len(b) > 1024*1024 {
		b = b[:1024*1024]
	}
	n, e := r.r.Read(b)
	r.n += int64(n)
	r.progress(r.n)
	return n, e
}

// Flat request DTOs reject unknown fields, duplicate members and required nulls.
// The copied browser sends null for an unknown optional mediaType; only that
// field accepts null as absence. They also reject
// nested values and invalid UTF-8 before decoding into application types.
func decode(body io.Reader, v any) error {
	b, e := io.ReadAll(io.LimitReader(body, 65537))
	if e != nil || len(b) > 65536 || !utf8.Valid(b) {
		return errors.New("invalid JSON")
	}
	d := json.NewDecoder(bytes.NewReader(b))
	t, e := d.Token()
	if e != nil || t != json.Delim('{') {
		return errors.New("object required")
	}
	keys := map[string]bool{}
	for d.More() {
		t, e = d.Token()
		k, ok := t.(string)
		if e != nil || !ok || keys[k] {
			return errors.New("duplicate key")
		}
		keys[k] = true
		var raw json.RawMessage
		if d.Decode(&raw) != nil || (string(raw) == "null" && k != "mediaType") || len(raw) == 0 || raw[0] == '{' || raw[0] == '[' {
			return errors.New("invalid field")
		}
	}
	if _, e = d.Token(); e != nil {
		return e
	}
	if _, e = d.Token(); e != io.EOF {
		return errors.New("trailing JSON")
	}
	d = json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	return d.Decode(v)
}

// net/http normalizes identical Content-Length fields and discards a length
// alongside chunked encoding. Preserve the stricter wire boundary before that
// normalization. Responses always close, so this guard handles exactly one
// request head per socket. It never retains more than 16 KiB plus its 4 KiB
// reader and never reads an unbounded request line.
type headerConn struct {
	net.Conn
	reader  io.Reader
	release func()
	once    sync.Once
}

func (c *headerConn) Close() error { e := c.Conn.Close(); c.once.Do(c.release); return e }
func (c *headerConn) Read(p []byte) (int, error) {
	if c.reader == nil {
		br := bufio.NewReaderSize(c.Conn, 4096)
		head := make([]byte, 0, 4096)
		seen := map[string]int{}
		lines := 0
		for {
			line, e := br.ReadSlice('\n')
			if e != nil {
				return 0, errors.New("invalid HTTP head")
			}
			if len(head)+len(line) > 16384 || len(line) < 2 || line[len(line)-2] != '\r' {
				return 0, errors.New("invalid HTTP head")
			}
			head = append(head, line...)
			lines++
			if lines == 1 {
				if len(line) > 2048 {
					return 0, errors.New("invalid HTTP target")
				}
				continue
			}
			if len(line) == 2 {
				break
			}
			if lines > 101 || line[0] == ' ' || line[0] == '\t' {
				return 0, errors.New("invalid HTTP headers")
			}
			key, _, ok := strings.Cut(string(line), ":")
			if !ok {
				return 0, errors.New("invalid HTTP header")
			}
			key = strings.ToLower(key)
			seen[key]++
			switch key {
			case "host", "content-length", "transfer-encoding", "content-type", "cookie", "origin", "x-kinlogue-csrf", "x-kinlogue-attempt-revision":
				if seen[key] > 1 {
					return 0, errors.New("duplicate HTTP header")
				}
			}
			if seen["content-length"] > 0 && seen["transfer-encoding"] > 0 {
				return 0, errors.New("ambiguous HTTP framing")
			}
		}
		c.reader = io.MultiReader(bytes.NewReader(head), br)
	}
	return c.reader.Read(p)
}
