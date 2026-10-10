package library

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"os"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"kinlogue/internal/document"
)

const MaxInboxItems = 5000
const inboxSchema = `
CREATE TABLE inbox (
 sequence INTEGER PRIMARY KEY AUTOINCREMENT,
 id TEXT NOT NULL UNIQUE, file_name TEXT NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('stored','processing','reviewable','unsupported','failed')),
 revision INTEGER NOT NULL CHECK(revision > 0), created_at TEXT NOT NULL,
 failure TEXT NOT NULL DEFAULT '', extraction TEXT NOT NULL DEFAULT '',
 digest TEXT NOT NULL, byte_count INTEGER NOT NULL CHECK(byte_count > 0),
 UNIQUE(digest,byte_count)
);`

type InboxSelection struct {
	ID       string
	Revision int64
}
type InboxItem struct {
	ID, FileName, Status, CreatedAt, Failure string
	Revision, Sequence, ByteCount            int64
	Extraction                               document.Extraction
}

type inboxRecord struct {
	InboxItem
	Digest string
}

// InboxUpload owns an unpublished private file. Callers must Abort on every
// path, including after Commit. Commit and Abort are idempotent after success.
// The application owns admission/cancellation and drains these objects before
// closing the Store; slow reader operations never hold its metadata lock.
type InboxUpload struct {
	mu                   sync.Mutex
	store                *Store
	root                 *os.Root
	fileID, name, digest string
	size                 int64
	identity             os.FileInfo
	done                 bool
	committed            *InboxItem
	epoch                uint64
}

func (s *Store) StageInbox(ctx context.Context, name string, size int64, src io.Reader) (*InboxUpload, error) {
	if !bounded(name, 1024) || strings.TrimSpace(name) == "" || size < 1 || size > document.MaxFileBytes || src == nil {
		return nil, ErrInvalid
	}
	s.mu.Lock()
	if err := s.begin(ctx); err != nil {
		s.mu.Unlock()
		return nil, err
	}
	root, err := s.root.OpenRoot("originals")
	if err != nil {
		s.mu.Unlock()
		return nil, ErrStorage
	}
	u := &InboxUpload{store: s, root: root, fileID: opaqueID(), name: name, size: size, epoch: s.inboxEpoch}
	if s.inboxStages == nil {
		s.inboxStages = make(map[*InboxUpload]struct{})
	}
	s.inboxStages[u] = struct{}{}
	s.mu.Unlock()
	f, err := root.OpenFile(u.fileID+".part", os.O_CREATE|os.O_EXCL|os.O_WRONLY|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		u.Abort()
		return nil, ErrStorage
	}
	u.identity, err = f.Stat()
	if err != nil || !private(u.identity, false) {
		f.Close()
		u.Abort()
		return nil, ErrCorrupt
	}
	hash := sha256.New()
	n, err := io.CopyBuffer(io.MultiWriter(f, hash), &snapshotReader{ctx: ctx, r: io.LimitReader(src, size+1), left: size + 1}, make([]byte, 64<<10))
	if err == nil && n != size {
		err = ErrInvalid
	}
	if err == nil {
		err = f.Sync()
	}
	if e := f.Close(); err == nil {
		err = e
	}
	if err == nil {
		err = ctx.Err()
	}
	if err != nil {
		u.Abort()
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, ErrInvalid
	}
	u.digest = hex.EncodeToString(hash.Sum(nil))
	return u, nil
}

func (u *InboxUpload) abortLocked() error {
	if u.done {
		return nil
	}
	u.done = true
	defer u.root.Close()
	info, err := u.root.Lstat(u.fileID + ".part")
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || u.identity == nil || !os.SameFile(info, u.identity) {
		return ErrCorrupt
	}
	if err = u.root.Remove(u.fileID + ".part"); err != nil {
		return ErrStorage
	}
	return syncDirectory(u.root)
}
func (u *InboxUpload) Abort() error {
	u.mu.Lock()
	defer u.mu.Unlock()
	err := u.abortLocked()
	u.store.mu.Lock()
	u.store.finishInboxStage(u)
	u.store.mu.Unlock()
	return err
}

// Commit must be called inside the caller's short session publication gate,
// after checking its generation/attempt revision. The network body is finished.
func (u *InboxUpload) Commit(ctx context.Context) (InboxItem, error) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.committed != nil {
		return *u.committed, nil
	}
	if u.done {
		return InboxItem{}, ErrState
	}
	s := u.store
	s.mu.Lock()
	defer s.mu.Unlock()
	defer func() {
		if u.done {
			s.finishInboxStage(u)
		}
	}()
	if err := s.begin(ctx); err != nil {
		return InboxItem{}, err
	}
	if s.inboxRemoved[inboxContentKey(u.digest, u.size)] > u.epoch {
		return InboxItem{}, ErrState
	}
	var existing string
	err := s.db.QueryRowContext(ctx, "SELECT id FROM inbox WHERE digest=? AND byte_count=?", u.digest, u.size).Scan(&existing)
	if err == nil {
		r, e := s.getInbox(ctx, existing)
		if e != nil {
			return InboxItem{}, e
		}
		if _, e = s.verifyDeletionOriginal(ctx, deletion{id: r.ID, digest: r.Digest, size: r.ByteCount}); e != nil {
			return InboxItem{}, e
		}
		if e = u.abortLocked(); e != nil {
			return InboxItem{}, e
		}
		u.committed = &r.InboxItem
		return r.InboxItem, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return InboxItem{}, storageError(ctx, err)
	}
	var count int
	if err = s.db.QueryRowContext(ctx, "SELECT count(*) FROM inbox").Scan(&count); err != nil {
		return InboxItem{}, storageError(ctx, err)
	}
	if count >= MaxInboxItems {
		return InboxItem{}, document.ErrLimit
	}
	info, err := u.root.Lstat(u.fileID + ".part")
	if err != nil || !private(info, false) || !os.SameFile(info, u.identity) || info.Size() != u.size {
		return InboxItem{}, ErrCorrupt
	}
	if err = ctx.Err(); err != nil {
		return InboxItem{}, err
	}
	if err = u.root.Link(u.fileID+".part", u.fileID+".blob"); err != nil {
		return InboxItem{}, ErrStorage
	}
	if err = u.root.Remove(u.fileID + ".part"); err != nil {
		return InboxItem{}, ErrStorage
	}
	u.done = true
	defer u.root.Close()
	if err = syncDirectory(u.root); err != nil {
		return InboxItem{}, err
	}
	item := InboxItem{ID: u.fileID, FileName: u.name, Status: "stored", Revision: 1, CreatedAt: time.Now().UTC().Format(time.RFC3339Nano), ByteCount: u.size}
	result, err := s.db.ExecContext(ctx, `INSERT INTO inbox(id,file_name,status,revision,created_at,digest,byte_count) VALUES (?,?,?,?,?,?,?)`, item.ID, item.FileName, item.Status, item.Revision, item.CreatedAt, u.digest, u.size)
	if err != nil {
		return InboxItem{}, storageError(ctx, err)
	}
	item.Sequence, err = result.LastInsertId()
	if err != nil {
		return InboxItem{}, ErrStorage
	}
	u.committed = &item
	return item, nil
}

const inboxColumns = "id,file_name,status,revision,sequence,created_at,failure,byte_count,digest,extraction"

func scanInbox(row scanner) (inboxRecord, error) {
	var r inboxRecord
	var raw string
	err := row.Scan(&r.ID, &r.FileName, &r.Status, &r.Revision, &r.Sequence, &r.CreatedAt, &r.Failure, &r.ByteCount, &r.Digest, &raw)
	if err != nil {
		return r, err
	}
	if raw != "" && (len(raw) > 2*document.MaxTextBytes || json.Unmarshal([]byte(raw), &r.Extraction) != nil) {
		return r, ErrCorrupt
	}
	if !validInbox(r) {
		return r, ErrCorrupt
	}
	return r, nil
}
func validInbox(r inboxRecord) bool {
	if !validID(r.ID) || !bounded(r.FileName, 1024) || strings.TrimSpace(r.FileName) == "" || r.Revision < 1 || r.Revision >= math.MaxInt64-1 || r.Sequence < 1 || r.Sequence >= math.MaxInt64-1 || r.ByteCount < 1 || r.ByteCount > document.MaxFileBytes {
		return false
	}
	if _, e := time.Parse(time.RFC3339Nano, r.CreatedAt); e != nil {
		return false
	}
	digest, e := hex.DecodeString(r.Digest)
	if e != nil || len(digest) != sha256.Size || r.Digest != strings.ToLower(r.Digest) {
		return false
	}
	switch r.Status {
	case "stored", "processing":
		return r.Failure == "" && r.Extraction.Engine == "" && r.Extraction.Kind == "" && r.Extraction.PageCount == 0 && len(r.Extraction.Blocks) == 0
	case "reviewable":
		return r.Failure == "" && validExtraction(r.Extraction)
	case "failed", "unsupported":
		return validInboxFailure(r.Failure) && (r.Status != "unsupported" || r.Failure == "unsupported") && r.Extraction.Engine == "" && r.Extraction.Kind == "" && r.Extraction.PageCount == 0 && len(r.Extraction.Blocks) == 0
	}
	return false
}
func validInboxFailure(code string) bool {
	switch code {
	case "interrupted", "recognition_failed", "unsupported", "invalid", "limit", "locked", "unavailable", "cancelled":
		return true
	}
	return false
}
func (s *Store) getInbox(ctx context.Context, id string) (inboxRecord, error) {
	if !validID(id) {
		return inboxRecord{}, ErrNotFound
	}
	r, e := scanInbox(s.db.QueryRowContext(ctx, "SELECT "+inboxColumns+" FROM inbox WHERE id=?", id))
	if e != nil {
		if errors.Is(e, ErrCorrupt) {
			return r, e
		}
		return r, storageError(ctx, e)
	}
	return r, nil
}
func (s *Store) GetInbox(ctx context.Context, id string) (InboxItem, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if e := s.begin(ctx); e != nil {
		return InboxItem{}, e
	}
	r, e := s.getInbox(ctx, id)
	return r.InboxItem, e
}

// Inbox returns metadata only; GetInbox loads cached extraction when needed.
func (s *Store) Inbox(ctx context.Context) ([]InboxItem, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if e := s.begin(ctx); e != nil {
		return nil, e
	}
	rows, e := s.db.QueryContext(ctx, "SELECT id,file_name,status,revision,sequence,created_at,failure,byte_count FROM inbox ORDER BY sequence")
	if e != nil {
		return nil, storageError(ctx, e)
	}
	defer rows.Close()
	result := []InboxItem{}
	for rows.Next() {
		var r InboxItem
		if e = rows.Scan(&r.ID, &r.FileName, &r.Status, &r.Revision, &r.Sequence, &r.CreatedAt, &r.Failure, &r.ByteCount); e != nil {
			return nil, ErrCorrupt
		}
		result = append(result, r)
		if len(result) > MaxInboxItems {
			return nil, ErrCorrupt
		}
	}
	return result, storageError(ctx, rows.Err())
}
func (s *Store) ReadInboxOriginal(ctx context.Context, id string, revision int64) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if e := s.begin(ctx); e != nil {
		return nil, e
	}
	r, e := s.getInbox(ctx, id)
	if e != nil {
		return nil, e
	}
	if r.Revision != revision {
		return nil, ErrState
	}
	var b bytes.Buffer
	if e = s.writeSnapshotOriginal(ctx, &b, id, snapshotOriginal{r.Digest, r.ByteCount}); e != nil {
		return nil, e
	}
	return b.Bytes(), nil
}
func (s *Store) BeginInboxProcessing(ctx context.Context, id string, revision int64) (InboxItem, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if e := s.begin(ctx); e != nil {
		return InboxItem{}, e
	}
	r, e := s.getInbox(ctx, id)
	if e != nil {
		return InboxItem{}, e
	}
	if r.Revision != revision || (r.Status != "stored" && r.Status != "failed" && r.Status != "unsupported") {
		return InboxItem{}, ErrState
	}
	_, e = s.db.ExecContext(ctx, "UPDATE inbox SET status='processing',failure='',revision=revision+1 WHERE id=?", id)
	if e != nil {
		return InboxItem{}, storageError(ctx, e)
	}
	r, e = s.getInbox(ctx, id)
	return r.InboxItem, e
}
func (s *Store) SaveInboxExtraction(ctx context.Context, id string, revision int64, e document.Extraction) (InboxItem, error) {
	if !validExtraction(e) {
		return InboxItem{}, ErrInvalid
	}
	raw, err := json.Marshal(e)
	if err != nil || len(raw) > 2*document.MaxTextBytes {
		return InboxItem{}, ErrInvalid
	}
	return s.finishInbox(ctx, id, revision, "reviewable", "", string(raw))
}
func (s *Store) FailInbox(ctx context.Context, id string, revision int64, code string) (InboxItem, error) {
	if !validInboxFailure(code) {
		return InboxItem{}, ErrInvalid
	}
	status := "failed"
	if code == "unsupported" {
		status = "unsupported"
	}
	return s.finishInbox(ctx, id, revision, status, code, "")
}
func (s *Store) finishInbox(ctx context.Context, id string, revision int64, status, code, raw string) (InboxItem, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if e := s.begin(ctx); e != nil {
		return InboxItem{}, e
	}
	r, e := s.getInbox(ctx, id)
	if e != nil {
		return InboxItem{}, e
	}
	if r.Revision != revision || r.Status != "processing" {
		return InboxItem{}, ErrState
	}
	_, e = s.db.ExecContext(ctx, "UPDATE inbox SET status=?,failure=?,extraction=?,revision=revision+1 WHERE id=?", status, code, raw, id)
	if e != nil {
		return InboxItem{}, storageError(ctx, e)
	}
	r, e = s.getInbox(ctx, id)
	return r.InboxItem, e
}
func (s *Store) selectedInbox(ctx context.Context, selected []InboxSelection, limit int) ([]inboxRecord, error) {
	if len(selected) == 0 || len(selected) > limit {
		return nil, ErrInvalid
	}
	seen := map[string]bool{}
	records := make([]inboxRecord, 0, len(selected))
	for _, sel := range selected {
		if seen[sel.ID] {
			return nil, ErrInvalid
		}
		seen[sel.ID] = true
		r, e := s.getInbox(ctx, sel.ID)
		if e != nil {
			return nil, e
		}
		if r.Revision != sel.Revision {
			return nil, ErrState
		}
		records = append(records, r)
	}
	return records, nil
}
func (s *Store) inboxDeletions(ctx context.Context, records []inboxRecord) []deletion {
	result := make([]deletion, 0, len(records))
	for _, r := range records {
		d := deletion{id: r.ID, digest: r.Digest, size: r.ByteCount}
		if info, e := s.verifyDeletionOriginal(ctx, d); e == nil {
			d.identity = fileIdentity(info)
		}
		result = append(result, d)
	}
	return result
}
func removeInbox(ctx context.Context, tx *sql.Tx, records []inboxRecord, deletions []deletion) error {
	for _, d := range deletions {
		if _, e := tx.ExecContext(ctx, "INSERT INTO pending_deletions(id,digest,byte_count,file_identity) VALUES(?,?,?,?)", d.id, d.digest, d.size, d.identity); e != nil {
			return storageError(ctx, e)
		}
	}
	for _, r := range records {
		if _, e := tx.ExecContext(ctx, "DELETE FROM inbox WHERE id=? AND revision=?", r.ID, r.Revision); e != nil {
			return storageError(ctx, e)
		}
	}
	return nil
}
func (s *Store) DeleteInbox(ctx context.Context, selected []InboxSelection) (DeleteResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if e := s.begin(ctx); e != nil {
		return DeleteResult{}, e
	}
	records, e := s.selectedInbox(ctx, selected, MaxInboxItems)
	if e != nil {
		return DeleteResult{}, e
	}
	deletions := s.inboxDeletions(ctx, records)
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return DeleteResult{}, storageError(ctx, e)
	}
	defer tx.Rollback()
	if e = removeInbox(ctx, tx, records, deletions); e != nil {
		return DeleteResult{}, e
	}
	e = tx.Commit()
	s.rememberInboxRemoval(records)
	if e != nil {
		return DeleteResult{}, storageError(ctx, e)
	}
	return DeleteResult{CleanupPending: s.cleanupOriginals(ctx, deletions)}, nil
}

// ArchiveInbox moves the frozen ordered selection to a review report in one
// SQLite transaction. Exact content multiset matches reuse existing metadata.
func (s *Store) ArchiveInbox(ctx context.Context, selected []InboxSelection, edit Edit) (Report, error) {
	return s.archiveInbox(ctx, selected, edit, nil)
}
func (s *Store) archiveInbox(ctx context.Context, selected []InboxSelection, edit Edit, checkpoint func(string)) (Report, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if e := s.begin(ctx); e != nil {
		return Report{}, e
	}
	if !validEdit(edit) || edit.MemberID == "" {
		return Report{}, ErrInvalid
	}
	records, e := s.selectedInbox(ctx, selected, document.MaxSources)
	if e != nil {
		return Report{}, e
	}
	var member int
	if e = s.db.QueryRowContext(ctx, "SELECT count(*) FROM members WHERE id=?", edit.MemberID).Scan(&member); e != nil || member != 1 {
		return Report{}, ErrInvalid
	}
	r := Report{ID: opaqueID(), FileName: records[0].FileName, Status: "review", CreatedAt: time.Now().UTC().Format(time.RFC3339Nano), Review: Edit{MemberID: edit.MemberID, Date: edit.Date, Title: edit.Title, Notes: edit.Notes}}
	var originals []snapshotOriginal
	var texts []string
	var extractions []document.Extraction
	pages := 0
	for _, item := range records {
		if item.Status != "reviewable" {
			return Report{}, ErrState
		}
		if _, e = s.verifyDeletionOriginal(ctx, deletion{id: item.ID, digest: item.Digest, size: item.ByteCount}); e != nil {
			return Report{}, e
		}
		r.Sources = append(r.Sources, Source{ID: item.ID, FileName: item.FileName, Extraction: item.Extraction})
		r.Review.SourceIDs = append(r.Review.SourceIDs, item.ID)
		originals = append(originals, snapshotOriginal{item.Digest, item.ByteCount})
		texts = append(texts, item.Extraction.Text())
		extractions = append(extractions, item.Extraction)
		pages += item.Extraction.PageCount
	}
	r.Review.Text = strings.Join(texts, "\n")
	if pages > document.MaxPages || len(r.Review.Text) > document.MaxTextBytes {
		return Report{}, document.ErrLimit
	}
	// The title the user archived under is kept; only empty fields are filled.
	proposeFields(&r.Review, extractions)
	duplicate, e := s.matchInboxReport(ctx, originals)
	if e != nil {
		return Report{}, e
	}
	var deletions []deletion
	if duplicate != "" {
		r, e = s.get(ctx, duplicate)
		if e != nil {
			return Report{}, e
		}
		existingOriginals, err := s.snapshotOriginals(ctx, r)
		if err != nil {
			return Report{}, err
		}
		for i, source := range r.Sources {
			o := existingOriginals[i]
			if _, err = s.verifyDeletionOriginal(ctx, deletion{id: source.ID, digest: o.Digest, size: o.ByteCount}); err != nil {
				return Report{}, err
			}
		}
		deletions = s.inboxDeletions(ctx, records)
	}
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return Report{}, storageError(ctx, e)
	}
	defer tx.Rollback()
	if duplicate == "" {
		if e = insertSnapshotReport(ctx, tx, snapshotReport{Report: r, Originals: originals}); e != nil {
			return Report{}, e
		}
	}
	if e = removeInbox(ctx, tx, records, deletions); e != nil {
		return Report{}, e
	}
	if checkpoint != nil {
		checkpoint("archive_uncommitted")
	}
	e = tx.Commit()
	s.rememberInboxRemoval(records)
	if e != nil {
		return Report{}, storageError(ctx, e)
	}
	if checkpoint != nil {
		checkpoint("archive_committed")
	}
	_ = s.cleanupOriginals(ctx, deletions)
	return r, nil
}
func (s *Store) matchInboxReport(ctx context.Context, want []snapshotOriginal) (string, error) {
	// Grouping compares counts as well as digests: [A,A] is not [A,B].
	key := func(v snapshotOriginal) string { return inboxContentKey(v.Digest, v.ByteCount) }
	desired := make([]string, len(want))
	for i, v := range want {
		desired[i] = key(v)
	}
	sort.Strings(desired)
	// Incomplete local imports cannot replace successfully recognized inbox items.
	rows, e := s.db.QueryContext(ctx, "SELECT s.report_id,s.digest,s.byte_count FROM sources s JOIN reports r ON r.id=s.report_id WHERE r.status IN ('review','confirmed') ORDER BY s.report_id,s.position,s.id")
	if e != nil {
		return "", storageError(ctx, e)
	}
	defer rows.Close()
	last := ""
	var group []string
	matches := func() bool {
		if len(group) != len(desired) {
			return false
		}
		sort.Strings(group)
		return slices.Equal(group, desired)
	}
	for rows.Next() {
		var id string
		var o snapshotOriginal
		if e = rows.Scan(&id, &o.Digest, &o.ByteCount); e != nil {
			return "", ErrCorrupt
		}
		if last != "" && id != last {
			if matches() {
				return last, nil
			}
			group = nil
		}
		last = id
		group = append(group, key(o))
	}
	if e = rows.Err(); e != nil {
		return "", storageError(ctx, e)
	}
	if last != "" && matches() {
		return last, nil
	}
	return "", nil
}

// Removal fences last only as long as already admitted uploads. A failed or
// ambiguous commit is fenced conservatively too; a new explicit upload can
// always start after the operation. No network body holds this metadata lock.
func inboxContentKey(digest string, size int64) string {
	return digest + ":" + strconv.FormatInt(size, 10)
}
func (s *Store) rememberInboxRemoval(records []inboxRecord) {
	s.inboxEpoch++
	if len(s.inboxStages) == 0 {
		return
	}
	if s.inboxRemoved == nil {
		s.inboxRemoved = make(map[string]uint64)
	}
	for _, r := range records {
		s.inboxRemoved[inboxContentKey(r.Digest, r.ByteCount)] = s.inboxEpoch
	}
}
func (s *Store) finishInboxStage(u *InboxUpload) {
	delete(s.inboxStages, u)
	if len(s.inboxStages) == 0 {
		s.inboxRemoved = nil
		return
	}
	earliest := s.inboxEpoch
	for upload := range s.inboxStages {
		epoch := upload.epoch
		if epoch < earliest {
			earliest = epoch
		}
	}
	for key, epoch := range s.inboxRemoved {
		if epoch <= earliest {
			delete(s.inboxRemoved, key)
		}
	}
}
