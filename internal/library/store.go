// Package library owns the new, isolated Go library format. Original bytes and
// OCR are immutable; only explicitly confirmed corrections are searchable.
package library

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"kinlogue/internal/document"
	_ "modernc.org/sqlite"
)

var (
	ErrInvalid     = errors.New("library_invalid")
	ErrState       = errors.New("library_invalid_state")
	ErrNotFound    = errors.New("library_not_found")
	ErrCorrupt     = errors.New("library_damaged")
	ErrLocked      = errors.New("library_in_use")
	ErrUnsupported = errors.New("library_unsupported_format")
	ErrStorage     = errors.New("library_storage_failed")
	ErrClosed      = errors.New("library_closed")
)

type Member struct{ ID, Name string }
type Edit struct {
	MemberID, Title, Date, Text, Notes string
	SourceIDs                          []string
}

func (e Edit) Equal(other Edit) bool {
	return e.MemberID == other.MemberID && e.Title == other.Title && e.Date == other.Date && e.Text == other.Text && e.Notes == other.Notes && slices.Equal(e.SourceIDs, other.SourceIDs)
}

type Source struct {
	ID, FileName string
	Extraction   document.Extraction
}

type Report struct {
	ID, FileName, Status string
	Review               Edit
	Sources              []Source
	CreatedAt            string
	Failure              string
}

// Store is a single owner of a private library directory. Methods serialize
// lifecycle and writes; the advisory lock also excludes other app processes.
type Store struct {
	mu               sync.Mutex
	db               *sql.DB
	root             *os.Root
	originals        *os.Root
	lock             *os.File
	path             string
	identity         os.FileInfo
	originalIdentity os.FileInfo
	databaseIdentity os.FileInfo
	lockIdentity     os.FileInfo

	inboxEpoch   uint64
	inboxStages  map[*InboxUpload]struct{}
	inboxRemoved map[string]uint64

	snapshotRestoreReady bool
	restoreOwnedFiles    map[string]os.FileInfo
}

const reportSchema = `
CREATE TABLE reports (
 id TEXT PRIMARY KEY, file_name TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('processing','review','failed','confirmed')),
 member_id TEXT REFERENCES members(id), title TEXT NOT NULL DEFAULT '', report_date TEXT NOT NULL DEFAULT '',
 corrected_text TEXT NOT NULL DEFAULT '', notes TEXT NOT NULL DEFAULT '',
 created_at TEXT NOT NULL, failure TEXT NOT NULL DEFAULT ''
);
CREATE INDEX reports_member_date ON reports(member_id, status, report_date);
CREATE TABLE sources (
 id TEXT PRIMARY KEY, report_id TEXT NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
 position INTEGER NOT NULL CHECK(position >= 0), file_name TEXT NOT NULL, extraction TEXT NOT NULL DEFAULT '',
 digest TEXT NOT NULL, byte_count INTEGER NOT NULL CHECK(byte_count > 0)
);
CREATE INDEX sources_report_order ON sources(report_id, position);
CREATE TABLE pending_deletions (
 id TEXT PRIMARY KEY, digest TEXT NOT NULL, byte_count INTEGER NOT NULL,
 file_identity TEXT NOT NULL
);`

const schema = `
CREATE TABLE members (id TEXT PRIMARY KEY, name TEXT NOT NULL);
` + reportSchema + inboxSchema + `
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO settings VALUES ('language', 'system');
PRAGMA application_id=1263290191;
PRAGMA user_version=4;`

const migrationV2 = `
ALTER TABLE reports RENAME TO reports_v1;
DROP INDEX reports_member_date;
` + reportSchema + `
INSERT INTO reports(id,file_name,status,member_id,title,report_date,corrected_text,notes,created_at,failure)
 SELECT id,file_name,status,member_id,title,report_date,corrected_text,notes,created_at,failure FROM reports_v1;
INSERT INTO sources(id,report_id,position,file_name,extraction,digest,byte_count)
 SELECT id,id,0,file_name,extraction,digest,byte_count FROM reports_v1;
DROP TABLE reports_v1;
PRAGMA user_version=2;`

func Open(path string) (*Store, error) { return openLibrary(path, nil) }

// checkpoint is used by process-interruption tests; production has no callback
// or environment-controlled fault injection.
func openLibrary(path string, checkpoint func(string)) (_ *Store, err error) {
	reached := func(stage string) {
		if checkpoint != nil {
			checkpoint(stage)
		}
	}
	path, err = filepath.Abs(path)
	if err != nil {
		return nil, ErrInvalid
	}
	if info, e := os.Lstat(path); e == nil && info.Mode()&os.ModeSymlink != 0 {
		return nil, ErrCorrupt
	}
	// Resolve system aliases such as /var once, but never accept a symlink at
	// the library root itself. The caller supplies an existing trusted parent.
	parent, e := filepath.EvalSymlinks(filepath.Dir(path))
	if e != nil {
		return nil, ErrStorage
	}
	path = filepath.Join(parent, filepath.Base(path))
	if e = os.Mkdir(path, 0700); e != nil && !errors.Is(e, os.ErrExist) {
		return nil, ErrStorage
	}
	info, e := os.Lstat(path)
	if e != nil || !private(info, true) {
		return nil, ErrCorrupt
	}
	r, e := os.OpenRoot(path)
	if e != nil {
		return nil, ErrCorrupt
	}
	s := &Store{root: r, path: path, identity: info}
	defer func() {
		if err != nil {
			_ = s.Close()
		}
	}()
	if e = s.checkRoot(); e != nil {
		return nil, e
	}
	entries, e := os.ReadDir(path)
	if e != nil {
		return nil, ErrStorage
	}
	databaseExists, initializing := false, false
	for _, entry := range entries {
		name := entry.Name()
		if name != ".owner.lock" && name != "originals" && name != "library.sqlite" && name != "library.sqlite-journal" && name != ".initializing" {
			return nil, ErrUnsupported
		}
		fi, e := r.Lstat(name)
		if e != nil || !private(fi, name == "originals" || name == ".initializing") {
			return nil, ErrCorrupt
		}
		if name == "library.sqlite" {
			databaseExists = true
		}
		if name == ".initializing" {
			initializing = true
		}
	}
	s.lock, e = r.OpenFile(".owner.lock", os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0600)
	if e != nil {
		return nil, ErrCorrupt
	}
	if fi, e := s.lock.Stat(); e != nil || !private(fi, false) {
		return nil, ErrCorrupt
	} else {
		s.lockIdentity = fi
	}
	if e = syscall.Flock(int(s.lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); e != nil {
		return nil, ErrLocked
	}
	if e = r.Mkdir("originals", 0700); e != nil && !errors.Is(e, os.ErrExist) {
		return nil, ErrStorage
	}
	s.originalIdentity, e = r.Lstat("originals")
	if e != nil || !private(s.originalIdentity, true) {
		return nil, ErrCorrupt
	}
	s.originals, e = r.OpenRoot("originals")
	if e != nil {
		return nil, ErrCorrupt
	}
	if opened, e := s.originals.Stat("."); e != nil || !os.SameFile(opened, s.originalIdentity) {
		return nil, ErrCorrupt
	}
	// This durable, empty private directory proves that a version-zero DB
	// belongs to an unfinished first initialization. An arbitrary DB0 never
	// gains this marker and is never reset or implicitly adopted.
	var initializationIdentity os.FileInfo
	if initializing || !databaseExists {
		if !initializing {
			if e = r.Mkdir(".initializing", 0700); e != nil {
				return nil, ErrStorage
			}
			initializing = true
		}
		initializationIdentity, e = emptyPrivateDirectory(r, ".initializing")
		if e != nil {
			return nil, e
		}
		if e = syncDirectory(r); e != nil {
			return nil, e
		}
		reached("owner_durable")
	}
	if !databaseExists {
		originals, e := os.ReadDir(filepath.Join(path, "originals"))
		if e != nil || len(originals) != 0 {
			return nil, ErrCorrupt
		}
		f, e := r.OpenFile("library.sqlite", os.O_CREATE|os.O_EXCL|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
		if e != nil {
			return nil, ErrStorage
		}
		if e = f.Close(); e != nil {
			return nil, ErrStorage
		}
		reached("database_created")
	}
	s.databaseIdentity, e = r.Lstat("library.sqlite")
	if e != nil || !private(s.databaseIdentity, false) {
		return nil, ErrCorrupt
	}
	if e = s.checkRoot(); e != nil {
		return nil, e
	}
	s.db, e = sql.Open("sqlite", filepath.Join(path, "library.sqlite"))
	if e != nil {
		return nil, ErrStorage
	}
	s.db.SetMaxOpenConns(1)
	if _, e = s.db.Exec("PRAGMA foreign_keys=ON; PRAGMA busy_timeout=1000; PRAGMA trusted_schema=OFF;"); e != nil {
		return nil, ErrCorrupt
	}
	var version, application int
	if e = s.db.QueryRow("PRAGMA user_version").Scan(&version); e != nil {
		return nil, ErrCorrupt
	}
	if e = s.db.QueryRow("PRAGMA application_id").Scan(&application); e != nil {
		return nil, ErrCorrupt
	}
	needsSchema := initializing && version == 0 && application == 0
	s.snapshotRestoreReady = needsSchema
	if needsSchema {
		var objects int
		if e = s.db.QueryRow("SELECT count(*) FROM sqlite_schema").Scan(&objects); e != nil {
			return nil, ErrCorrupt
		}
		if objects != 0 {
			return nil, ErrUnsupported
		}
		if _, e = emptyPrivateDirectory(r, "originals"); e != nil {
			return nil, e
		}
	} else if (version != 1 && version != 2 && version != 3 && version != 4) || application != 1263290191 {
		return nil, ErrUnsupported
	}
	var check string
	if e = s.db.QueryRow("PRAGMA quick_check").Scan(&check); e != nil || check != "ok" {
		return nil, ErrCorrupt
	}
	if _, e = s.db.Exec("PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA;"); e != nil {
		return nil, ErrCorrupt
	}
	if needsSchema {
		tx, e := s.db.Begin()
		if e != nil {
			return nil, ErrStorage
		}
		if _, e = tx.Exec(schema); e != nil {
			_ = tx.Rollback()
			return nil, ErrStorage
		}
		reached("schema_uncommitted")
		if e = tx.Commit(); e != nil {
			return nil, ErrStorage
		}
		reached("schema_committed")
	}
	if !needsSchema && version < 4 {
		tx, e := s.db.Begin()
		if e != nil {
			return nil, ErrStorage
		}
		migration := inboxSchema + "PRAGMA user_version=4;"
		if version == 1 {
			migration = migrationV2 + migration
		}
		if _, e = tx.Exec(migration); e != nil {
			_ = tx.Rollback()
			return nil, ErrCorrupt
		}
		reached("migration_uncommitted")
		if e = tx.Commit(); e != nil {
			return nil, ErrStorage
		}
		reached("migration_committed")
	}
	if initializing {
		current, e := emptyPrivateDirectory(r, ".initializing")
		if e != nil || !os.SameFile(current, initializationIdentity) {
			return nil, ErrCorrupt
		}
		if e = r.Remove(".initializing"); e != nil {
			return nil, ErrStorage
		}
		if e = syncDirectory(r); e != nil {
			return nil, e
		}
	}
	// Recovery changes state only; it never restarts recognition.
	if _, e = s.db.Exec("UPDATE reports SET status='failed', failure='interrupted' WHERE status='processing'"); e != nil {
		return nil, ErrCorrupt
	}
	if _, e = s.db.Exec("UPDATE inbox SET status='failed', failure='interrupted', revision=revision+1 WHERE status='processing'"); e != nil {
		return nil, ErrCorrupt
	}
	// Cleanup failures leave durable queue entries. Opening never scans or
	// guesses which other unreferenced files may be safe to remove.
	_ = s.cleanupPending(context.Background())
	return s, nil
}

func emptyPrivateDirectory(root *os.Root, name string) (os.FileInfo, error) {
	info, err := root.Lstat(name)
	if err != nil || !private(info, true) {
		return nil, ErrCorrupt
	}
	f, err := root.OpenFile(name, os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, ErrCorrupt
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(opened, info) {
		return nil, ErrCorrupt
	}
	entries, err := f.ReadDir(1)
	if len(entries) != 0 || err != nil && !errors.Is(err, io.EOF) {
		return nil, ErrCorrupt
	}
	return info, nil
}

func syncDirectory(root *os.Root) error {
	f, err := root.OpenFile(".", os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return ErrCorrupt
	}
	err = f.Sync()
	closeErr := f.Close()
	if err != nil || closeErr != nil {
		return ErrStorage
	}
	return nil
}

func private(info os.FileInfo, directory bool) bool {
	if info == nil || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return false
	}
	if directory && !info.IsDir() || !directory && !info.Mode().IsRegular() {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == uint32(os.Getuid()) && (directory || stat.Nlink == 1)
}

func (s *Store) checkRoot() error {
	info, err := os.Lstat(s.path)
	if err != nil || !private(info, true) || !os.SameFile(info, s.identity) {
		return ErrCorrupt
	}
	openedRoot, err := s.root.Stat(".")
	if err != nil || !os.SameFile(openedRoot, s.identity) {
		return ErrCorrupt
	}
	if s.originalIdentity != nil {
		info, err = s.root.Lstat("originals")
		if err != nil || !private(info, true) || !os.SameFile(info, s.originalIdentity) {
			return ErrCorrupt
		}
	}
	for name, identity := range map[string]os.FileInfo{"library.sqlite": s.databaseIdentity, ".owner.lock": s.lockIdentity} {
		if identity == nil {
			continue
		}
		info, err = s.root.Lstat(name)
		if err != nil || !private(info, false) || !os.SameFile(info, identity) {
			return ErrCorrupt
		}
	}
	if journal, err := s.root.Lstat("library.sqlite-journal"); err == nil {
		if !private(journal, false) {
			return ErrCorrupt
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return ErrCorrupt
	}
	return nil
}

func (s *Store) begin(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if s.db == nil {
		return ErrClosed
	}
	return s.checkRoot()
}

func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var result error
	if s.db != nil {
		if s.db.Close() != nil {
			result = ErrStorage
		}
		s.db = nil
	}
	if s.root != nil {
		if s.root.Close() != nil {
			result = ErrStorage
		}
		s.root = nil
	}
	if s.originals != nil {
		if s.originals.Close() != nil {
			result = ErrStorage
		}
		s.originals = nil
	}
	if s.lock != nil {
		if s.lock.Close() != nil {
			result = ErrStorage
		}
		s.lock = nil
	}
	return result
}

func opaqueID() string    { return hex.EncodeToString(randomBytes()) }
func randomBytes() []byte { b := make([]byte, 16); _, _ = rand.Read(b); return b }
func validID(id string) bool {
	b, e := hex.DecodeString(id)
	return e == nil && len(b) == 16 && id == strings.ToLower(id)
}
func bounded(s string, max int) bool {
	return utf8.ValidString(s) && len(s) <= max && !strings.ContainsRune(s, 0)
}
func storageError(ctx context.Context, err error) error {
	if err == nil {
		return nil
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	return ErrStorage
}

func (s *Store) AddMember(ctx context.Context, name string) (Member, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return Member{}, err
	}
	name = strings.TrimSpace(name)
	if name == "" || !bounded(name, 256) {
		return Member{}, ErrInvalid
	}
	m := Member{ID: opaqueID(), Name: name}
	_, err := s.db.ExecContext(ctx, "INSERT INTO members(id,name) VALUES (?,?)", m.ID, m.Name)
	return m, storageError(ctx, err)
}

func (s *Store) Members(ctx context.Context) ([]Member, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx, "SELECT id,name FROM members ORDER BY name,id")
	if err != nil {
		return nil, storageError(ctx, err)
	}
	defer rows.Close()
	result := []Member{}
	for rows.Next() {
		var m Member
		if err := rows.Scan(&m.ID, &m.Name); err != nil {
			return nil, ErrCorrupt
		}
		result = append(result, m)
	}
	return result, storageError(ctx, rows.Err())
}

// CreateDraftSources reads and persists one source at a time. Only after all
// originals are durable does a single transaction publish the whole report.
func (s *Store) CreateDraftSources(ctx context.Context, names []string, read func(int) ([]byte, error)) (Report, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return Report{}, err
	}
	if len(names) == 0 || len(names) > document.MaxSources || read == nil {
		return Report{}, ErrInvalid
	}
	for _, name := range names {
		if !bounded(name, 1024) || strings.TrimSpace(name) == "" {
			return Report{}, ErrInvalid
		}
	}
	r := Report{ID: opaqueID(), FileName: names[0], Status: "processing", CreatedAt: time.Now().UTC().Format(time.RFC3339Nano)}
	type saved struct {
		digest string
		size   int
	}
	originals := make([]saved, 0, len(names))
	for i, name := range names {
		if err := ctx.Err(); err != nil {
			return Report{}, err
		}
		data, err := read(i)
		if err != nil {
			return Report{}, err
		}
		if len(data) == 0 || len(data) > document.MaxFileBytes {
			return Report{}, ErrInvalid
		}
		source := Source{ID: opaqueID(), FileName: name}
		if err := s.writeOriginal(ctx, source.ID, data); err != nil {
			return Report{}, err
		}
		digest := sha256.Sum256(data)
		originals = append(originals, saved{hex.EncodeToString(digest[:]), len(data)})
		r.Sources = append(r.Sources, source)
		r.Review.SourceIDs = append(r.Review.SourceIDs, source.ID)
	}
	if err := s.checkRoot(); err != nil {
		return Report{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Report{}, storageError(ctx, err)
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, "INSERT INTO reports(id,file_name,status,created_at) VALUES (?,?,?,?)", r.ID, r.FileName, r.Status, r.CreatedAt)
	if err == nil {
		for i, source := range r.Sources {
			_, err = tx.ExecContext(ctx, "INSERT INTO sources(id,report_id,position,file_name,digest,byte_count) VALUES (?,?,?,?,?,?)", source.ID, r.ID, i, source.FileName, originals[i].digest, originals[i].size)
			if err != nil {
				break
			}
		}
	}
	if err == nil {
		err = tx.Commit()
	}
	// Failed/uncertain publication can retain unreferenced originals. They are
	// not guessed at or swept by startup; only explicit report deletion queues
	// its known referenced originals.
	if err != nil {
		return Report{}, storageError(ctx, err)
	}
	return r, nil
}

func (s *Store) writeOriginal(ctx context.Context, id string, data []byte) error {
	return s.writeOriginalUsing(ctx, id, data, nil)
}

type originalFile interface {
	Write([]byte) (int, error)
	Sync() error
	Close() error
}

// wrap is an internal fault-test seam around a real owned file; callers and
// production imports cannot replace the filesystem implementation.
func (s *Store) writeOriginalUsing(ctx context.Context, id string, data []byte, wrap func(*os.File) originalFile) error {
	part, leaf := id+".part", id+".blob"
	f, err := s.originals.OpenFile(part, os.O_CREATE|os.O_EXCL|os.O_WRONLY|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return ErrStorage
	}
	defer f.Close()
	identity, err := f.Stat()
	if err != nil || !private(identity, false) {
		return ErrCorrupt
	}
	removed := false
	defer func() {
		if removed {
			return
		}
		// A replacement at this name belongs to somebody else. Unlink only
		// this operation's inode; a separately published blob is never removed.
		current, err := s.originals.Lstat(part)
		if err == nil && current.Mode().IsRegular() && os.SameFile(current, identity) {
			if s.originals.Remove(part) == nil {
				_ = syncDirectory(s.originals)
			}
		}
	}()
	var writer originalFile = f
	if wrap != nil {
		writer = wrap(f)
	}
	written, err := writer.Write(data)
	if err == nil && written != len(data) {
		err = io.ErrShortWrite
	}
	if err == nil {
		err = writer.Sync()
	}
	if closeErr := writer.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return ErrStorage
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	// Link publishes a complete file without replacing an existing object.
	if err = s.originals.Link(part, leaf); err != nil {
		return ErrStorage
	}
	if err = s.originals.Remove(part); err != nil {
		return ErrStorage
	}
	removed = true
	return syncDirectory(s.originals)
}

const reportColumns = "id,file_name,status,COALESCE(member_id,''),title,report_date,corrected_text,notes,created_at,failure"

type scanner interface{ Scan(...any) error }

func scanReport(row scanner) (Report, error) {
	var r Report
	err := row.Scan(&r.ID, &r.FileName, &r.Status, &r.Review.MemberID, &r.Review.Title, &r.Review.Date, &r.Review.Text, &r.Review.Notes, &r.CreatedAt, &r.Failure)
	if err != nil {
		return Report{}, err
	}
	if !validID(r.ID) {
		return Report{}, ErrCorrupt
	}
	return r, nil
}

func (s *Store) get(ctx context.Context, id string) (Report, error) {
	if !validID(id) {
		return Report{}, ErrNotFound
	}
	r, err := scanReport(s.db.QueryRowContext(ctx, "SELECT "+reportColumns+" FROM reports WHERE id=?", id))
	if err != nil {
		if errors.Is(err, ErrCorrupt) {
			return Report{}, err
		}
		return Report{}, storageError(ctx, err)
	}
	rows, err := s.db.QueryContext(ctx, "SELECT id,file_name,extraction,position FROM sources WHERE report_id=? ORDER BY position,id", id)
	if err != nil {
		return Report{}, storageError(ctx, err)
	}
	defer rows.Close()
	pages, textBytes, recognized := 0, 0, 0
	for rows.Next() {
		var source Source
		var raw string
		var position int
		if err := rows.Scan(&source.ID, &source.FileName, &raw, &position); err != nil || !validID(source.ID) || position != len(r.Sources) || !bounded(source.FileName, 1024) {
			return Report{}, ErrCorrupt
		}
		if raw != "" {
			if len(raw) > 2*document.MaxTextBytes || json.Unmarshal([]byte(raw), &source.Extraction) != nil || !validExtraction(source.Extraction) {
				return Report{}, ErrCorrupt
			}
			pages += source.Extraction.PageCount
			textBytes += extractionTextBytes(source.Extraction)
			recognized++
		}
		r.Sources = append(r.Sources, source)
		r.Review.SourceIDs = append(r.Review.SourceIDs, source.ID)
		if len(r.Sources) > document.MaxSources || pages > document.MaxPages || textBytes+max(0, recognized-1) > document.MaxTextBytes {
			return Report{}, ErrCorrupt
		}
	}
	if err := rows.Err(); err != nil {
		return Report{}, storageError(ctx, err)
	}
	if len(r.Sources) == 0 || (r.Status == "review" || r.Status == "confirmed") && recognized != len(r.Sources) {
		return Report{}, ErrCorrupt
	}
	return r, nil
}

func (s *Store) Get(ctx context.Context, id string) (Report, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return Report{}, err
	}
	return s.get(ctx, id)
}

// Match Extraction.Text's byte length without joining the source blocks.
// Empty blocks still contribute the separators between adjacent blocks.
func extractionTextBytes(e document.Extraction) int {
	n := max(0, len(e.Blocks)-1)
	for _, block := range e.Blocks {
		n += len(block.Text)
	}
	return n
}

func validExtraction(e document.Extraction) bool {
	if e.Validate() != nil || !bounded(e.Engine, 128) || extractionTextBytes(e) > document.MaxTextBytes {
		return false
	}
	switch e.Kind {
	case "pdf", "jpeg", "png", "heic", "tiff":
	default:
		return false
	}
	for _, block := range e.Blocks {
		if !bounded(block.Method, 64) {
			return false
		}
	}
	return true
}

func (s *Store) SaveSourceExtraction(ctx context.Context, id, sourceID string, e document.Extraction) (Report, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return Report{}, err
	}
	if !validExtraction(e) {
		return Report{}, ErrInvalid
	}
	r, err := s.get(ctx, id)
	if err != nil {
		return Report{}, err
	}
	if r.Status != "processing" && r.Status != "failed" {
		return Report{}, ErrState
	}
	index := slices.IndexFunc(r.Sources, func(source Source) bool { return source.ID == sourceID })
	if index < 0 {
		return Report{}, ErrNotFound
	}
	if r.Sources[index].Extraction.Engine != "" {
		return Report{}, ErrState
	}
	r.Sources[index].Extraction = e
	pages := 0
	texts := []string{}
	for _, source := range r.Sources {
		pages += source.Extraction.PageCount
		if source.Extraction.Engine != "" {
			texts = append(texts, source.Extraction.Text())
		}
	}
	text := strings.Join(texts, "\n")
	if pages > document.MaxPages || len(text) > document.MaxTextBytes {
		return Report{}, document.ErrLimit
	}
	raw, err := json.Marshal(e)
	if err != nil || len(raw) > 2*document.MaxTextBytes {
		return Report{}, ErrInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Report{}, storageError(ctx, err)
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, "UPDATE sources SET extraction=? WHERE id=? AND report_id=? AND extraction=''", string(raw), sourceID, id)
	if err == nil && len(texts) == len(r.Sources) {
		_, err = tx.ExecContext(ctx, "UPDATE reports SET corrected_text=?,status='review',failure='' WHERE id=?", text, id)
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		return Report{}, storageError(ctx, err)
	}
	return s.get(ctx, id)
}

func (s *Store) FailDraft(ctx context.Context, id, code string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return err
	}
	// This is an enum, not an error-message sink: paths/content never persist.
	switch code {
	case "interrupted", "recognition_failed", "unsupported", "invalid", "limit", "locked", "unavailable", "cancelled":
	default:
		return ErrInvalid
	}
	r, err := s.get(ctx, id)
	if err != nil {
		return err
	}
	if r.Status != "processing" && r.Status != "failed" {
		return ErrState
	}
	_, err = s.db.ExecContext(ctx, "UPDATE reports SET status='failed',failure=? WHERE id=?", code, id)
	return storageError(ctx, err)
}

func validEdit(e Edit) bool {
	return (e.MemberID == "" || validID(e.MemberID)) && bounded(e.Title, 1024) && bounded(e.Text, document.MaxTextBytes) && bounded(e.Notes, document.MaxTextBytes) && document.ValidateDate(e.Date) == nil
}

func (s *Store) saveReview(ctx context.Context, id string, e Edit, expected, status string) (Report, error) {
	if !validEdit(e) || status == "confirmed" && (e.MemberID == "" || strings.TrimSpace(e.Title) == "") {
		return Report{}, ErrInvalid
	}
	r, err := s.get(ctx, id)
	if err != nil {
		return Report{}, err
	}
	if r.Status != expected {
		return Report{}, ErrState
	}
	if len(e.SourceIDs) != len(r.Sources) {
		return Report{}, ErrInvalid
	}
	remaining := make(map[string]bool, len(r.Sources))
	for _, source := range r.Sources {
		remaining[source.ID] = true
	}
	for _, id := range e.SourceIDs {
		if !remaining[id] {
			return Report{}, ErrInvalid
		}
		delete(remaining, id)
	}
	var member any
	if e.MemberID != "" {
		var exists int
		if err := s.db.QueryRowContext(ctx, "SELECT 1 FROM members WHERE id=?", e.MemberID).Scan(&exists); err != nil {
			return Report{}, ErrInvalid
		}
		member = e.MemberID
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Report{}, storageError(ctx, err)
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, "UPDATE reports SET member_id=?,title=?,report_date=?,corrected_text=?,notes=?,status=? WHERE id=?", member, e.Title, e.Date, e.Text, e.Notes, status, id)
	if err == nil {
		for position, sourceID := range e.SourceIDs {
			_, err = tx.ExecContext(ctx, "UPDATE sources SET position=? WHERE id=? AND report_id=?", position, sourceID, id)
			if err != nil {
				break
			}
		}
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		return Report{}, storageError(ctx, err)
	}
	return s.get(ctx, id)
}

func (s *Store) SaveReview(ctx context.Context, id string, e Edit) (Report, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return Report{}, err
	}
	return s.saveReview(ctx, id, e, "review", "review")
}

func (s *Store) Confirm(ctx context.Context, id string, e Edit) (Report, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return Report{}, err
	}
	return s.saveReview(ctx, id, e, "review", "confirmed")
}

// UpdateConfirmed is a separate explicit user operation; neither recognition
// nor ordinary draft saving can change a confirmed record.
func (s *Store) UpdateConfirmed(ctx context.Context, id string, e Edit) (Report, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return Report{}, err
	}
	return s.saveReview(ctx, id, e, "confirmed", "confirmed")
}

func (s *Store) list(ctx context.Context, clause string, args ...any) ([]Report, error) {
	// Lists are metadata projections, even though the public return type is
	// Report. Get loads the selected report's complete text, notes and OCR.
	const columns = "id,file_name,status,COALESCE(member_id,''),title,report_date,created_at,failure"
	rows, err := s.db.QueryContext(ctx, "SELECT "+columns+" FROM reports "+clause, args...)
	if err != nil {
		return nil, storageError(ctx, err)
	}
	defer rows.Close()
	result := []Report{}
	for rows.Next() {
		var r Report
		err := rows.Scan(&r.ID, &r.FileName, &r.Status, &r.Review.MemberID, &r.Review.Title, &r.Review.Date, &r.CreatedAt, &r.Failure)
		if err != nil || !validID(r.ID) {
			return nil, ErrCorrupt
		}
		result = append(result, r)
	}
	return result, storageError(ctx, rows.Err())
}

// Drafts returns metadata only: Review.Text, Review.Notes and Sources are
// empty. Call Get to load full detail for a selected row.
func (s *Store) Drafts(ctx context.Context) ([]Report, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return nil, err
	}
	return s.list(ctx, "WHERE status <> 'confirmed' ORDER BY created_at DESC,id")
}

// Search matches confirmed corrected text/notes but returns metadata only.
// An empty memberID selects confirmed records across all family members.
// Review.Text, Review.Notes and Sources are loaded through Get, not lists.
func (s *Store) Search(ctx context.Context, memberID, query string) ([]Report, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return nil, err
	}
	if (memberID != "" && !validID(memberID)) || !bounded(query, 1024) {
		return nil, ErrInvalid
	}
	// instr treats %, _ and backslashes literally. SQLite lower folds ASCII;
	// Chinese characters remain exact, so both intended languages work.
	where := "WHERE status='confirmed'"
	args := []any{}
	if memberID != "" {
		where += " AND member_id=?"
		args = append(args, memberID)
	}
	where += " AND (instr(lower(title),lower(?))>0 OR instr(lower(corrected_text),lower(?))>0 OR instr(lower(notes),lower(?))>0) ORDER BY report_date DESC,created_at DESC,id"
	return s.list(ctx, where, append(args, query, query, query)...)
}

func (s *Store) ReadOriginal(ctx context.Context, reportID, sourceID string) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return nil, err
	}
	if !validID(reportID) || !validID(sourceID) {
		return nil, ErrNotFound
	}
	var digest string
	var length int64
	if err := s.db.QueryRowContext(ctx, "SELECT digest,byte_count FROM sources WHERE id=? AND report_id=?", sourceID, reportID).Scan(&digest, &length); err != nil {
		return nil, storageError(ctx, err)
	}
	if length < 1 || length > document.MaxFileBytes {
		return nil, ErrCorrupt
	}
	leaf := sourceID + ".blob"
	info, err := s.originals.Lstat(leaf)
	if err != nil || !private(info, false) || info.Size() != length {
		return nil, ErrCorrupt
	}
	f, err := s.originals.OpenFile(leaf, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, ErrCorrupt
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !private(opened, false) || !os.SameFile(info, opened) {
		return nil, ErrCorrupt
	}
	data, err := io.ReadAll(io.LimitReader(f, length+1))
	if err != nil {
		return nil, ErrStorage
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	actual := sha256.Sum256(data)
	if int64(len(data)) != length || hex.EncodeToString(actual[:]) != digest {
		return nil, ErrCorrupt
	}
	if err := s.checkRoot(); err != nil {
		return nil, err
	}
	return data, nil
}

func (s *Store) Language(ctx context.Context) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return "", err
	}
	var language string
	err := s.db.QueryRowContext(ctx, "SELECT value FROM settings WHERE key='language'").Scan(&language)
	if err != nil {
		return "", storageError(ctx, err)
	}
	if language != "system" && language != "zh-Hans" && language != "en" {
		return "", ErrCorrupt
	}
	return language, nil
}

func (s *Store) SetLanguage(ctx context.Context, language string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return err
	}
	if language != "system" && language != "zh-Hans" && language != "en" {
		return ErrInvalid
	}
	_, err := s.db.ExecContext(ctx, "UPDATE settings SET value=? WHERE key='language'", language)
	return storageError(ctx, err)
}
