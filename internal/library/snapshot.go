package library

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"kinlogue/internal/document"
)

const (
	MaxSnapshotBytes   int64 = 64 << 30
	maxSnapshotHeader        = 32 << 20
	maxSnapshotReport        = 64 << 20
	maxSnapshotRecords       = 100_000
	maxSnapshotSources       = 1_000_000
)

// SnapshotSummary is returned only after every record and original is valid.
type SnapshotSummary struct {
	Members, Reports, Sources int
	OriginalBytes             int64
}

type snapshotHeader struct {
	Version  int
	Language string
	Members  []Member
	Reports  int
}

type snapshotOriginal struct {
	Digest    string
	ByteCount int64
}

type snapshotReport struct {
	Report
	Originals []snapshotOriginal
}

type snapshotGraph struct {
	members    map[string]bool
	sources    map[string]bool
	lastReport string
	summary    SnapshotSummary
}

func newSnapshotGraph(h snapshotHeader) (*snapshotGraph, error) {
	if h.Version != 1 {
		return nil, ErrUnsupported
	}
	if !snapshotLanguage(h.Language) || len(h.Members) > maxSnapshotRecords || h.Reports < 0 || h.Reports > maxSnapshotRecords {
		return nil, ErrCorrupt
	}
	g := &snapshotGraph{members: make(map[string]bool), sources: make(map[string]bool)}
	for _, m := range h.Members {
		if !validID(m.ID) || !bounded(m.Name, 256) || strings.TrimSpace(m.Name) == "" || g.members[m.ID] {
			return nil, ErrCorrupt
		}
		g.members[m.ID] = true
	}
	g.summary.Members = len(h.Members)
	return g, nil
}

func snapshotLanguage(s string) bool { return s == "system" || s == "zh-Hans" || s == "en" }

func (g *snapshotGraph) report(r *snapshotReport) error {
	if !validID(r.ID) || r.ID <= g.lastReport || !bounded(r.FileName, 1024) || strings.TrimSpace(r.FileName) == "" || !validEdit(r.Review) || r.Review.MemberID != "" && !g.members[r.Review.MemberID] {
		return ErrCorrupt
	}
	if _, err := time.Parse(time.RFC3339Nano, r.CreatedAt); err != nil {
		return ErrCorrupt
	}
	if len(r.Sources) == 0 || len(r.Sources) > document.MaxSources || len(r.Originals) != len(r.Sources) || len(r.Review.SourceIDs) != len(r.Sources) {
		return ErrCorrupt
	}
	switch r.Status {
	case "processing":
		if r.Failure != "" {
			return ErrCorrupt
		}
		r.Status, r.Failure = "failed", "interrupted"
	case "failed":
		switch r.Failure {
		case "interrupted", "recognition", "recognition_failed", "unsupported", "invalid", "limit", "locked", "unavailable", "cancelled":
		default:
			return ErrCorrupt
		}
	case "review", "confirmed":
		if r.Failure != "" {
			return ErrCorrupt
		}
	default:
		return ErrCorrupt
	}
	if r.Status == "confirmed" && (r.Review.MemberID == "" || strings.TrimSpace(r.Review.Title) == "") {
		return ErrCorrupt
	}
	pages, textBytes, recognized := 0, 0, 0
	for i, source := range r.Sources {
		if !validID(source.ID) || g.sources[source.ID] || r.Review.SourceIDs[i] != source.ID || !bounded(source.FileName, 1024) || strings.TrimSpace(source.FileName) == "" {
			return ErrCorrupt
		}
		e := source.Extraction
		if e.Engine != "" {
			if !validExtraction(e) {
				return ErrCorrupt
			}
			raw, err := json.Marshal(e)
			if err != nil || len(raw) > 2*document.MaxTextBytes {
				return ErrCorrupt
			}
			pages += e.PageCount
			textBytes += extractionTextBytes(e)
			recognized++
		} else if e.Kind != "" || e.PageCount != 0 || len(e.Blocks) != 0 {
			return ErrCorrupt
		}
		original := r.Originals[i]
		digest, err := hex.DecodeString(original.Digest)
		if err != nil || len(digest) != sha256.Size || original.Digest != strings.ToLower(original.Digest) || original.ByteCount < 1 || original.ByteCount > document.MaxFileBytes {
			return ErrCorrupt
		}
		g.sources[source.ID] = true
		g.summary.Sources++
		g.summary.OriginalBytes += original.ByteCount
		if g.summary.Sources > maxSnapshotSources || g.summary.OriginalBytes > MaxSnapshotBytes {
			return ErrCorrupt
		}
	}
	if pages > document.MaxPages || textBytes+max(0, recognized-1) > document.MaxTextBytes || (r.Status == "review" || r.Status == "confirmed") && recognized != len(r.Sources) {
		return ErrCorrupt
	}
	g.lastReport = r.ID
	g.summary.Reports++
	return nil
}

// WriteSnapshot holds the Store lock until all saved records and their original
// bytes have been streamed. Unreferenced files and deletion work are excluded.
func (s *Store) WriteSnapshot(ctx context.Context, dst io.Writer) (SnapshotSummary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return SnapshotSummary{}, err
	}
	h := snapshotHeader{Version: 1, Members: []Member{}}
	if err := s.db.QueryRowContext(ctx, "SELECT value FROM settings WHERE key='language'").Scan(&h.Language); err != nil {
		return SnapshotSummary{}, storageError(ctx, err)
	}
	rows, err := s.db.QueryContext(ctx, "SELECT id,name FROM members ORDER BY name,id")
	if err != nil {
		return SnapshotSummary{}, storageError(ctx, err)
	}
	for rows.Next() {
		var m Member
		if err = rows.Scan(&m.ID, &m.Name); err != nil {
			break
		}
		h.Members = append(h.Members, m)
		if len(h.Members) > maxSnapshotRecords {
			err = ErrCorrupt
			break
		}
	}
	if err == nil {
		err = rows.Err()
	}
	_ = rows.Close()
	if err != nil {
		return SnapshotSummary{}, snapshotError(ctx, err)
	}
	// Close Rows before fetching details: Store owns a single SQLite connection.
	rows, err = s.db.QueryContext(ctx, "SELECT id FROM reports ORDER BY id")
	if err != nil {
		return SnapshotSummary{}, storageError(ctx, err)
	}
	var ids []string
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			break
		}
		ids = append(ids, id)
		if len(ids) > maxSnapshotRecords {
			err = ErrCorrupt
			break
		}
	}
	if err == nil {
		err = rows.Err()
	}
	_ = rows.Close()
	if err != nil {
		return SnapshotSummary{}, snapshotError(ctx, err)
	}
	h.Reports = len(ids)
	g, err := newSnapshotGraph(h)
	if err != nil {
		return SnapshotSummary{}, err
	}
	data, err := marshalSnapshotHeader(h)
	if err != nil {
		return SnapshotSummary{}, err
	}
	w := tar.NewWriter(&snapshotWriter{ctx: ctx, w: dst, left: MaxSnapshotBytes})
	if err = writeSnapshotEntry(w, "library.json", data); err != nil {
		return SnapshotSummary{}, snapshotError(ctx, err)
	}
	for _, id := range ids {
		report, err := s.get(ctx, id)
		if err != nil {
			return SnapshotSummary{}, err
		}
		r := snapshotReport{Report: report}
		if r.Originals, err = s.snapshotOriginals(ctx, r.Report); err != nil {
			return SnapshotSummary{}, err
		}
		if err = g.report(&r); err != nil {
			return SnapshotSummary{}, err
		}
		data, err = json.Marshal(r)
		if err != nil || len(data) > maxSnapshotReport {
			return SnapshotSummary{}, ErrCorrupt
		}
		if err = writeSnapshotEntry(w, "reports/"+r.ID+".json", data); err != nil {
			return SnapshotSummary{}, snapshotError(ctx, err)
		}
		for i, source := range r.Sources {
			if err = w.WriteHeader(snapshotTarHeader("originals/"+source.ID+".blob", r.Originals[i].ByteCount)); err != nil {
				return SnapshotSummary{}, snapshotError(ctx, err)
			}
			if err = s.writeSnapshotOriginal(ctx, w, source.ID, r.Originals[i]); err != nil {
				return SnapshotSummary{}, err
			}
		}
	}
	if err = w.Close(); err != nil {
		return SnapshotSummary{}, snapshotError(ctx, err)
	}
	if err = s.begin(ctx); err != nil {
		return SnapshotSummary{}, err
	}
	return g.summary, nil
}

func (s *Store) snapshotOriginals(ctx context.Context, report Report) ([]snapshotOriginal, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT id,digest,byte_count FROM sources WHERE report_id=? ORDER BY position,id", report.ID)
	if err != nil {
		return nil, storageError(ctx, err)
	}
	defer rows.Close()
	result := make([]snapshotOriginal, 0, len(report.Sources))
	for rows.Next() {
		var id string
		var original snapshotOriginal
		if err := rows.Scan(&id, &original.Digest, &original.ByteCount); err != nil {
			return nil, storageError(ctx, err)
		}
		if len(result) >= len(report.Sources) || id != report.Sources[len(result)].ID {
			return nil, ErrCorrupt
		}
		result = append(result, original)
	}
	if err := rows.Err(); err != nil {
		return nil, storageError(ctx, err)
	}
	if len(result) != len(report.Sources) {
		return nil, ErrCorrupt
	}
	return result, nil
}

func marshalSnapshotHeader(h snapshotHeader) ([]byte, error) {
	// Bound the header while appending individual members; json.Marshal on the
	// entire member list could allocate far beyond its encoded-size budget.
	var b bytes.Buffer
	prefix, _ := json.Marshal(struct {
		Version  int
		Language string
	}{h.Version, h.Language})
	b.Write(prefix[:len(prefix)-1])
	b.WriteString(`,"Members":[`)
	for i, m := range h.Members {
		data, err := json.Marshal(m)
		if err != nil || b.Len()+len(data)+64 > maxSnapshotHeader {
			return nil, ErrCorrupt
		}
		if i > 0 {
			b.WriteByte(',')
		}
		b.Write(data)
	}
	count, _ := json.Marshal(h.Reports)
	b.WriteString(`],"Reports":`)
	b.Write(count)
	b.WriteByte('}')
	return b.Bytes(), nil
}

func snapshotTarHeader(name string, size int64) *tar.Header {
	return &tar.Header{Name: name, Size: size, Mode: 0600, Typeflag: tar.TypeReg, Format: tar.FormatUSTAR}
}
func writeSnapshotEntry(w *tar.Writer, name string, data []byte) error {
	if err := w.WriteHeader(snapshotTarHeader(name, int64(len(data)))); err != nil {
		return err
	}
	_, err := w.Write(data)
	return err
}

func (s *Store) writeSnapshotOriginal(ctx context.Context, w io.Writer, id string, o snapshotOriginal) error {
	leaf := id + ".blob"
	info, err := s.originals.Lstat(leaf)
	if err != nil || !private(info, false) || info.Size() != o.ByteCount {
		return ErrCorrupt
	}
	f, err := s.originals.OpenFile(leaf, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return ErrCorrupt
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !private(opened, false) || !os.SameFile(opened, info) {
		return ErrCorrupt
	}
	hash := sha256.New()
	n, err := io.Copy(io.MultiWriter(w, hash), &snapshotReader{ctx: ctx, r: io.LimitReader(f, o.ByteCount+1), left: o.ByteCount + 1})
	if err != nil {
		return snapshotError(ctx, err)
	}
	if n != o.ByteCount || hex.EncodeToString(hash.Sum(nil)) != o.Digest {
		return ErrCorrupt
	}
	current, err := s.originals.Lstat(leaf)
	if err != nil || !os.SameFile(current, info) {
		return ErrCorrupt
	}
	return nil
}

// VerifySnapshot validates the complete logical graph and every original,
// including the archive's exact end, without creating a database.
func VerifySnapshot(ctx context.Context, src io.Reader) (SnapshotSummary, error) {
	return readSnapshot(ctx, src, nil, nil)
}

// RestoreSnapshot only accepts a newly initialized, empty Store. On failure its
// owned staging files may remain; the caller must discard the entire stage.
func (s *Store) RestoreSnapshot(ctx context.Context, src io.Reader) (SnapshotSummary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return SnapshotSummary{}, err
	}
	if !s.snapshotRestoreReady {
		return SnapshotSummary{}, ErrState
	}
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT (SELECT count(*) FROM members)+(SELECT count(*) FROM reports)+(SELECT count(*) FROM sources)+(SELECT count(*) FROM pending_deletions)+(SELECT count(*) FROM settings WHERE key!='language' OR value!='system')`).Scan(&count); err != nil {
		return SnapshotSummary{}, storageError(ctx, err)
	}
	if count != 0 {
		return SnapshotSummary{}, ErrState
	}
	if _, err := emptyPrivateDirectory(s.root, "originals"); err != nil {
		return SnapshotSummary{}, ErrState
	}
	s.snapshotRestoreReady = false
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return SnapshotSummary{}, storageError(ctx, err)
	}
	defer tx.Rollback()
	summary, err := readSnapshot(ctx, src, func(h snapshotHeader) error {
		for _, m := range h.Members {
			if _, err := tx.ExecContext(ctx, "INSERT INTO members(id,name) VALUES (?,?)", m.ID, m.Name); err != nil {
				return storageError(ctx, err)
			}
		}
		_, err := tx.ExecContext(ctx, "UPDATE settings SET value=? WHERE key='language'", h.Language)
		return storageError(ctx, err)
	}, func(r snapshotReport, index int, src io.Reader) error {
		if index < 0 {
			return insertSnapshotReport(ctx, tx, r)
		}
		return s.restoreSnapshotOriginal(ctx, r.Sources[index].ID, r.Originals[index], src)
	})
	if err != nil {
		return SnapshotSummary{}, err
	}
	if err = s.begin(ctx); err != nil {
		return SnapshotSummary{}, err
	}
	if err = syncDirectory(s.originals); err != nil {
		return SnapshotSummary{}, err
	}
	if err = tx.Commit(); err != nil {
		return SnapshotSummary{}, storageError(ctx, err)
	}
	return summary, nil
}

func insertSnapshotReport(ctx context.Context, tx *sql.Tx, r snapshotReport) error {
	var member any
	if r.Review.MemberID != "" {
		member = r.Review.MemberID
	}
	_, err := tx.ExecContext(ctx, `INSERT INTO reports(id,file_name,status,member_id,title,report_date,corrected_text,notes,created_at,failure) VALUES (?,?,?,?,?,?,?,?,?,?)`, r.ID, r.FileName, r.Status, member, r.Review.Title, r.Review.Date, r.Review.Text, r.Review.Notes, r.CreatedAt, r.Failure)
	if err != nil {
		return storageError(ctx, err)
	}
	for i, source := range r.Sources {
		raw := ""
		if source.Extraction.Engine != "" {
			b, _ := json.Marshal(source.Extraction)
			raw = string(b)
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO sources(id,report_id,position,file_name,extraction,digest,byte_count) VALUES (?,?,?,?,?,?,?)`, source.ID, r.ID, i, source.FileName, raw, r.Originals[i].Digest, r.Originals[i].ByteCount)
		if err != nil {
			return storageError(ctx, err)
		}
	}
	return nil
}

func (s *Store) restoreSnapshotOriginal(ctx context.Context, id string, o snapshotOriginal, src io.Reader) error {
	// This Store is an unpublished owned stage, so no separate .part publication
	// is needed; its database transaction commits only after full verification.
	f, err := s.originals.OpenFile(id+".blob", os.O_CREATE|os.O_EXCL|os.O_WRONLY|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return ErrStorage
	}
	if s.restoreOwnedFiles != nil {
		info, e := f.Stat()
		if e != nil || !private(info, false) {
			f.Close()
			return ErrCorrupt
		}
		s.restoreOwnedFiles["originals/"+id+".blob"] = info
	}
	n, err := io.Copy(f, src)
	if err == nil && n != o.ByteCount {
		err = ErrCorrupt
	}
	if err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	return snapshotError(ctx, err)
}

func readSnapshot(ctx context.Context, src io.Reader, header func(snapshotHeader) error, entry func(snapshotReport, int, io.Reader) error) (SnapshotSummary, error) {
	r := &snapshotReader{ctx: ctx, r: src, left: MaxSnapshotBytes}
	size, err := readSnapshotHeader(r, "library.json", maxSnapshotHeader)
	if err != nil {
		return SnapshotSummary{}, snapshotError(ctx, err)
	}
	var h snapshotHeader
	if err = readSnapshotJSON(r, size, &h); err != nil {
		return SnapshotSummary{}, snapshotError(ctx, err)
	}
	g, err := newSnapshotGraph(h)
	if err != nil {
		return SnapshotSummary{}, err
	}
	if header != nil {
		if err = header(h); err != nil {
			return SnapshotSummary{}, err
		}
	}
	for range h.Reports {
		// Report IDs are data until graph validation; no archive path is opened.
		name, size, err := readSnapshotTarHeader(r, maxSnapshotReport)
		if err != nil {
			return SnapshotSummary{}, snapshotError(ctx, err)
		}
		var report snapshotReport
		if err = readSnapshotJSON(r, size, &report); err != nil {
			return SnapshotSummary{}, snapshotError(ctx, err)
		}
		if err = g.report(&report); err != nil {
			return SnapshotSummary{}, err
		}
		if name != "reports/"+report.ID+".json" {
			return SnapshotSummary{}, ErrCorrupt
		}
		if entry != nil {
			if err = entry(report, -1, nil); err != nil {
				return SnapshotSummary{}, err
			}
		}
		for i, source := range report.Sources {
			o := report.Originals[i]
			size, err = readSnapshotHeader(r, "originals/"+source.ID+".blob", document.MaxFileBytes)
			if err != nil || size != o.ByteCount {
				return SnapshotSummary{}, snapshotError(ctx, ErrCorrupt)
			}
			hash := sha256.New()
			limited := &io.LimitedReader{R: r, N: size}
			body := io.TeeReader(limited, hash)
			if entry != nil {
				err = entry(report, i, body)
			} else {
				_, err = io.Copy(io.Discard, body)
			}
			if err != nil {
				return SnapshotSummary{}, snapshotError(ctx, err)
			}
			if limited.N != 0 || hex.EncodeToString(hash.Sum(nil)) != o.Digest {
				return SnapshotSummary{}, ErrCorrupt
			}
			if err = readSnapshotZeros(r, (512-size%512)%512); err != nil {
				return SnapshotSummary{}, snapshotError(ctx, err)
			}
		}
	}
	if err = readSnapshotZeros(r, 1024); err != nil {
		return SnapshotSummary{}, snapshotError(ctx, err)
	}
	var tail [1]byte
	if n, err := r.Read(tail[:]); n != 0 || err != io.EOF {
		return SnapshotSummary{}, snapshotError(ctx, ErrCorrupt)
	}
	return g.summary, nil
}

func readSnapshotHeader(r io.Reader, want string, limit int64) (int64, error) {
	name, size, err := readSnapshotTarHeader(r, limit)
	if err != nil {
		return 0, err
	}
	if name != want {
		return 0, ErrCorrupt
	}
	return size, nil
}

func readSnapshotTarHeader(r io.Reader, limit int64) (string, int64, error) {
	var raw [512]byte
	if _, err := io.ReadFull(r, raw[:]); err != nil {
		return "", 0, err
	}
	// archive/tar hides extended headers. Inspect one raw block first, then
	// accept only the canonical USTAR headers this format actually emits.
	if raw[156] != tar.TypeReg {
		return "", 0, ErrCorrupt
	}
	h, err := tar.NewReader(bytes.NewReader(raw[:])).Next()
	if err != nil || h.Size < 0 || h.Size > limit || h.Format != tar.FormatUSTAR {
		return "", 0, ErrCorrupt
	}
	var canonical bytes.Buffer
	w := tar.NewWriter(&canonical)
	if err = w.WriteHeader(snapshotTarHeader(h.Name, h.Size)); err != nil || !bytes.Equal(raw[:], canonical.Bytes()) {
		return "", 0, ErrCorrupt
	}
	return h.Name, h.Size, nil
}

func readSnapshotJSON(r io.Reader, size int64, dst any) error {
	data := make([]byte, int(size))
	if _, err := io.ReadFull(r, data); err != nil {
		return err
	}
	if !utf8.Valid(data) {
		return ErrCorrupt
	}
	// encoding/json otherwise accepts duplicate keys and silently uses the last.
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	if err := uniqueSnapshotJSON(d, 0, 0); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return ErrCorrupt
	}
	d = json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(dst); err != nil {
		return ErrCorrupt
	}
	return readSnapshotZeros(r, (512-size%512)%512)
}

func uniqueSnapshotJSON(d *json.Decoder, depth, arrayLimit int) error {
	if depth > 32 {
		return ErrCorrupt
	}
	t, err := d.Token()
	if err != nil {
		return ErrCorrupt
	}
	delim, ok := t.(json.Delim)
	if !ok {
		return nil
	}
	if delim != '{' && delim != '[' {
		return ErrCorrupt
	}
	keys := map[string]bool{}
	count := 0
	for d.More() {
		count++
		childLimit := 0
		if delim == '{' {
			if count > 12 {
				return ErrCorrupt
			}
			key, err := d.Token()
			if err != nil {
				return ErrCorrupt
			}
			name, ok := key.(string)
			if !ok || keys[name] {
				return ErrCorrupt
			}
			keys[name] = true
			switch name {
			case "Members":
				childLimit = maxSnapshotRecords
			case "Sources", "SourceIDs", "Originals":
				childLimit = document.MaxSources
			case "Blocks":
				childLimit = document.MaxBlocks
			case "Version", "Language", "Reports", "ID", "Name", "FileName", "Status", "Review", "CreatedAt", "Failure", "MemberID", "Title", "Date", "Text", "Notes", "Extraction", "Kind", "PageCount", "Engine", "Page", "Bounds", "Confidence", "Method", "X", "Y", "Width", "Height", "Digest", "ByteCount":
			default:
				return ErrCorrupt
			}
		} else if count > arrayLimit {
			return ErrCorrupt
		}
		if err := uniqueSnapshotJSON(d, depth+1, childLimit); err != nil {
			return err
		}
	}
	_, err = d.Token()
	return err
}

func readSnapshotZeros(r io.Reader, n int64) error {
	var zeros [1024]byte
	if _, err := io.ReadFull(r, zeros[:n]); err != nil {
		return err
	}
	for _, b := range zeros[:n] {
		if b != 0 {
			return ErrCorrupt
		}
	}
	return nil
}

type snapshotReader struct {
	ctx      context.Context
	r        io.Reader
	left     int64
	exceeded bool
}

func (r *snapshotReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	if r.exceeded {
		return 0, ErrCorrupt
	}
	if int64(len(p)) > r.left+1 {
		p = p[:r.left+1]
	}
	n, err := r.r.Read(p)
	r.left -= int64(n)
	if r.left < 0 {
		r.exceeded = true
		return 0, ErrCorrupt
	}
	return n, err
}

type snapshotWriter struct {
	ctx  context.Context
	w    io.Writer
	left int64
}

func (w *snapshotWriter) Write(p []byte) (int, error) {
	if err := w.ctx.Err(); err != nil {
		return 0, err
	}
	if int64(len(p)) > w.left {
		return 0, ErrCorrupt
	}
	n, err := w.w.Write(p)
	w.left -= int64(n)
	if err == nil && n != len(p) {
		err = io.ErrShortWrite
	}
	return n, err
}
func snapshotError(ctx context.Context, err error) error {
	if err == nil {
		return nil
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if errors.Is(err, ErrStorage) {
		return ErrStorage
	}
	return ErrCorrupt
}
