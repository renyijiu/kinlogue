package library

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"kinlogue/internal/backup"
	"kinlogue/internal/document"
)

func TestSnapshotRoundTripPreservesSavedGraph(t *testing.T) {
	s, root := openTest(t)
	m, _ := s.AddMember(ctx, "Synthetic member A")
	_, _ = s.AddMember(ctx, "Synthetic member B")
	_ = s.SetLanguage(ctx, "zh-Hans")
	r := finishSources(t, s, multiDraft(t, s))
	e := r.Review
	e.MemberID, e.Title, e.Date, e.Text, e.Notes = m.ID, "Synthetic title", "2026-10-08", "Corrected text", "Synthetic notes"
	e.SourceIDs[0], e.SourceIDs[1] = e.SourceIDs[1], e.SourceIDs[0]
	r, err := s.Confirm(ctx, r.ID, e)
	if err != nil {
		t.Fatal(err)
	}
	draft := ready(t, s)
	failed := multiDraft(t, s)
	_, _ = s.SaveSourceExtraction(ctx, failed.ID, failed.Sources[0].ID, extraction())
	_ = s.FailDraft(ctx, failed.ID, "recognition_failed")
	failed, _ = s.Get(ctx, failed.ID)
	processing := multiDraft(t, s)
	deleted := ready(t, s)
	_, _ = s.DeleteReport(ctx, deleted.ID)
	if err := os.WriteFile(filepath.Join(root, "originals", opaqueID()+".blob"), []byte("unreachable synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	var archive bytes.Buffer
	summary, err := s.WriteSnapshot(ctx, &archive)
	if err != nil {
		t.Fatal(err)
	}
	if summary.Members != 2 || summary.Reports != 4 || summary.Sources != 7 {
		t.Fatalf("wrong snapshot counts: %+v", summary)
	}
	if verified, err := VerifySnapshot(ctx, bytes.NewReader(archive.Bytes())); err != nil || verified != summary {
		t.Fatalf("verify: %+v %v", verified, err)
	}
	target, _ := openTest(t)
	if restored, err := target.RestoreSnapshot(ctx, bytes.NewReader(archive.Bytes())); err != nil || restored != summary {
		t.Fatalf("restore: %+v %v", restored, err)
	}
	for _, want := range []Report{r, draft, failed, processing} {
		if want.Status == "processing" {
			want.Status, want.Failure = "failed", "interrupted"
		}
		got, err := target.Get(ctx, want.ID)
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Fatalf("saved graph changed: %v", err)
		}
		for _, source := range want.Sources {
			a, e1 := s.ReadOriginal(ctx, want.ID, source.ID)
			b, e2 := target.ReadOriginal(ctx, want.ID, source.ID)
			if e1 != nil || e2 != nil || !bytes.Equal(a, b) {
				t.Fatal("original changed")
			}
		}
	}
	if language, _ := target.Language(ctx); language != "zh-Hans" {
		t.Fatal("language lost")
	}
	wantMembers, _ := s.Members(ctx)
	if gotMembers, _ := target.Members(ctx); !reflect.DeepEqual(wantMembers, gotMembers) {
		t.Fatal("member identities or names changed")
	}
	if found, _ := target.Search(ctx, m.ID, ""); len(found) != 1 || found[0].ID != r.ID {
		t.Fatal("confirmation gate changed")
	}
	var again bytes.Buffer
	if _, err := target.WriteSnapshot(ctx, &again); err != nil || !bytes.Equal(archive.Bytes(), again.Bytes()) {
		t.Fatalf("snapshot not deterministic: %v", err)
	}
	if _, err := target.RestoreSnapshot(ctx, bytes.NewReader(archive.Bytes())); !errors.Is(err, ErrState) {
		t.Fatal("nonempty restore accepted")
	}
}

func TestSnapshotRoundTripPreservesMigratedVersionOneLibrary(t *testing.T) {
	f := createMigrationV1Fixture(t)
	s, err := Open(f.root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var archive bytes.Buffer
	if _, err := s.WriteSnapshot(ctx, &archive); err != nil {
		t.Fatal("migrated library could not be backed up:", err)
	}
	target, _ := openTest(t)
	if _, err := target.RestoreSnapshot(ctx, &archive); err != nil {
		t.Fatal("migrated library could not be restored:", err)
	}
	f.root = target.path
	assertMigratedV1Fixture(t, target, f)
}

type snapshotEntry struct {
	header tar.Header
	data   []byte
}

func snapshotEntries(t *testing.T, data []byte) []snapshotEntry {
	t.Helper()
	r := tar.NewReader(bytes.NewReader(data))
	var entries []snapshotEntry
	for {
		h, err := r.Next()
		if err == io.EOF {
			return entries
		}
		if err != nil {
			t.Fatal(err)
		}
		b, err := io.ReadAll(r)
		if err != nil {
			t.Fatal(err)
		}
		entries = append(entries, snapshotEntry{*h, b})
	}
}

func encodeSnapshotEntries(t *testing.T, entries []snapshotEntry) []byte {
	t.Helper()
	var out bytes.Buffer
	w := tar.NewWriter(&out)
	for _, e := range entries {
		e.header.Size = int64(len(e.data))
		if e.header.Typeflag == tar.TypeSymlink {
			e.header.Size = 0
			e.data = nil
		}
		if err := w.WriteHeader(&e.header); err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write(e.data); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func TestSnapshotRejectsMalformedArchiveAndGraph(t *testing.T) {
	s, _ := openTest(t)
	ready(t, s)
	var out bytes.Buffer
	if _, err := s.WriteSnapshot(ctx, &out); err != nil {
		t.Fatal(err)
	}
	tests := map[string]func([]snapshotEntry) []snapshotEntry{
		"unknown entry":   func(es []snapshotEntry) []snapshotEntry { es[1].header.Name = "unknown"; return es },
		"duplicate entry": func(es []snapshotEntry) []snapshotEntry { return append(es, es[1]) },
		"link": func(es []snapshotEntry) []snapshotEntry {
			es[2].header.Typeflag = tar.TypeSymlink
			es[2].header.Linkname = "elsewhere"
			return es
		},
		"future version": func(es []snapshotEntry) []snapshotEntry {
			es[0].data = bytes.Replace(es[0].data, []byte(`"Version":2`), []byte(`"Version":9`), 1)
			return es
		},
		"report count limit": func(es []snapshotEntry) []snapshotEntry {
			var h snapshotHeader
			_ = json.Unmarshal(es[0].data, &h)
			h.Reports = maxSnapshotRecords + 1
			es[0].data, _ = json.Marshal(h)
			return es
		},
		"duplicate member": func(es []snapshotEntry) []snapshotEntry {
			var h snapshotHeader
			_ = json.Unmarshal(es[0].data, &h)
			m := Member{ID: opaqueID(), Name: "Synthetic duplicate"}
			h.Members = []Member{m, m}
			es[0].data, _ = json.Marshal(h)
			return es
		},
		"unknown JSON": func(es []snapshotEntry) []snapshotEntry {
			es[0].data = append([]byte(`{"Unknown":true,`), es[0].data[1:]...)
			return es
		},
		"duplicate JSON": func(es []snapshotEntry) []snapshotEntry {
			es[0].data = append([]byte(`{"Version":1,`), es[0].data[1:]...)
			return es
		},
		"trailing JSON": func(es []snapshotEntry) []snapshotEntry { es[0].data = append(es[0].data, []byte(`{}`)...); return es },
		"missing member": func(es []snapshotEntry) []snapshotEntry {
			var r snapshotReport
			_ = json.Unmarshal(es[1].data, &r)
			r.Review.MemberID = opaqueID()
			es[1].data, _ = json.Marshal(r)
			return es
		},
		"duplicate source": func(es []snapshotEntry) []snapshotEntry {
			var r snapshotReport
			_ = json.Unmarshal(es[1].data, &r)
			r.Sources = append(r.Sources, r.Sources[0])
			r.Review.SourceIDs = append(r.Review.SourceIDs, r.Sources[0].ID)
			r.Originals = append(r.Originals, r.Originals[0])
			es[1].data, _ = json.Marshal(r)
			return es
		},
		"bad hash": func(es []snapshotEntry) []snapshotEntry { es[2].data[0] ^= 1; return es },
		"oversized original": func(es []snapshotEntry) []snapshotEntry {
			var r snapshotReport
			_ = json.Unmarshal(es[1].data, &r)
			r.Originals[0].ByteCount = 101 << 20
			es[1].data, _ = json.Marshal(r)
			return es
		},
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			bad := encodeSnapshotEntries(t, mutate(snapshotEntries(t, out.Bytes())))
			target, _ := openTest(t)
			if _, err := target.RestoreSnapshot(ctx, bytes.NewReader(bad)); err == nil {
				t.Fatal("malformed snapshot accepted")
			}
			if members, _ := target.Members(ctx); len(members) != 0 {
				t.Fatal("failed restore committed data")
			}
		})
	}
	for name, bad := range map[string][]byte{"truncated": out.Bytes()[:out.Len()-1], "tail": append(append([]byte{}, out.Bytes()...), 1), "extra zeros": append(append([]byte{}, out.Bytes()...), make([]byte, 512)...)} {
		t.Run(name, func(t *testing.T) {
			if _, err := VerifySnapshot(ctx, bytes.NewReader(bad)); err == nil {
				t.Fatal("bad tail accepted")
			}
		})
	}
}

type blockingSnapshotWriter struct {
	bytes.Buffer
	entered chan struct{}
	release chan struct{}
	blocked bool
}

func (w *blockingSnapshotWriter) Write(p []byte) (int, error) {
	if !w.blocked {
		w.blocked = true
		close(w.entered)
		<-w.release
	}
	return w.Buffer.Write(p)
}

func TestSnapshotSerializesWithMutationsAndCancellation(t *testing.T) {
	s, _ := openTest(t)
	w := &blockingSnapshotWriter{entered: make(chan struct{}), release: make(chan struct{})}
	defer func() {
		select {
		case <-w.release:
		default:
			close(w.release)
		}
	}()
	done := make(chan error, 1)
	go func() { _, err := s.WriteSnapshot(ctx, w); done <- err }()
	<-w.entered
	modified := make(chan error, 1)
	go func() { _, err := s.AddMember(ctx, "Synthetic later"); modified <- err }()
	select {
	case <-modified:
		t.Fatal("mutation interleaved snapshot")
	case <-time.After(20 * time.Millisecond):
	}
	close(w.release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if err := <-modified; err != nil {
		t.Fatal(err)
	}
	if summary, err := VerifySnapshot(ctx, bytes.NewReader(w.Bytes())); err != nil || summary.Members != 0 {
		t.Fatal("mixed snapshot")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := s.WriteSnapshot(cancelled, io.Discard); !errors.Is(err, context.Canceled) {
		t.Fatal("cancel ignored")
	}
	target, _ := openTest(t)
	if _, err := target.RestoreSnapshot(cancelled, bytes.NewReader(w.Bytes())); !errors.Is(err, context.Canceled) {
		t.Fatal("restore cancel ignored")
	}
	if summary, err := target.RestoreSnapshot(ctx, bytes.NewReader(w.Bytes())); err != nil || summary != (SnapshotSummary{}) {
		t.Fatalf("empty snapshot did not restore: %v", err)
	}
}

type countedSnapshotReader struct {
	io.Reader
	bytes int
}

func (r *countedSnapshotReader) Read(p []byte) (int, error) {
	n, err := r.Reader.Read(p)
	r.bytes += n
	return n, err
}

func TestSnapshotJSONRejectsExpandedCollectionsBeforeDecoding(t *testing.T) {
	for _, key := range []string{"Sources", "SourceIDs", "Originals", "Blocks", "Members"} {
		t.Run(key, func(t *testing.T) {
			limit := document.MaxSources
			if key == "Blocks" {
				limit = document.MaxBlocks
			}
			if key == "Members" {
				limit = maxSnapshotRecords
			}
			data := `{"` + key + `":[` + strings.Repeat(`null,`, limit+10) + `null]}`
			r := &countedSnapshotReader{Reader: strings.NewReader(data)}
			if err := uniqueSnapshotJSON(json.NewDecoder(r), 0, 0); err == nil {
				t.Fatal("unbounded typed collection accepted")
			}
			if r.bytes > limit*5+1024 {
				t.Fatal("preflight read past collection limit")
			}
		})
	}
}

func TestSnapshotRejectsOversizedHeaderBeforePayloadRead(t *testing.T) {
	var out bytes.Buffer
	w := tar.NewWriter(&out)
	if err := w.WriteHeader(snapshotTarHeader("library.json", maxSnapshotHeader+1)); err != nil {
		t.Fatal(err)
	}
	r := &countedSnapshotReader{Reader: bytes.NewReader(out.Bytes())}
	if _, err := VerifySnapshot(ctx, r); err == nil || r.bytes != 512 {
		t.Fatalf("oversized header consumed payload: %d %v", r.bytes, err)
	}
}

func TestSnapshotRejectsExtensionsBrokenOriginalsAndReopenedDestination(t *testing.T) {
	s, root := openTest(t)
	r := ready(t, s)
	var out bytes.Buffer
	if _, err := s.WriteSnapshot(ctx, &out); err != nil {
		t.Fatal(err)
	}
	entries := snapshotEntries(t, out.Bytes())
	entries[0].header.Format = tar.FormatPAX
	entries[0].header.PAXRecords = map[string]string{"comment": "synthetic"}
	if _, err := VerifySnapshot(ctx, bytes.NewReader(encodeSnapshotEntries(t, entries))); err == nil {
		t.Fatal("PAX extension accepted")
	}
	if err := os.WriteFile(filepath.Join(root, "originals", r.Sources[0].ID+".blob"), []byte("synthetic-corruption"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.WriteSnapshot(ctx, io.Discard); err == nil {
		t.Fatal("broken original exported")
	}
	target, path := openTest(t)
	if err := target.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if _, err := reopened.RestoreSnapshot(ctx, bytes.NewReader(out.Bytes())); !errors.Is(err, ErrState) {
		t.Fatal("existing destination accepted")
	}
}

func TestEncryptedSnapshotAuthenticatesBeforeStoreCommit(t *testing.T) {
	s, _ := openTest(t)
	r := ready(t, s)
	code, err := backup.NewCode()
	if err != nil {
		t.Fatal(err)
	}
	var ciphertext bytes.Buffer
	digest, err := backup.Encrypt(ctx, &ciphertext, code, func(w io.Writer) error { _, err := s.WriteSnapshot(ctx, w); return err })
	if err != nil {
		t.Fatal(err)
	}
	if err := backup.Verify(ctx, bytes.NewReader(ciphertext.Bytes()), code, digest, func(r io.Reader) error { _, err := VerifySnapshot(ctx, r); return err }); err != nil {
		t.Fatal(err)
	}
	for _, truncated := range []bool{false, true} {
		t.Run(map[bool]string{false: "complete", true: "truncated"}[truncated], func(t *testing.T) {
			target, _ := openTest(t)
			data := ciphertext.Bytes()
			if truncated {
				data = data[:len(data)-1]
			}
			err := backup.Decrypt(ctx, bytes.NewReader(data), code, func(r io.Reader) error { _, err := target.RestoreSnapshot(ctx, r); return err })
			if truncated {
				if err == nil {
					t.Fatal("unauthenticated store committed")
				}
				if _, err := target.Get(ctx, r.ID); !errors.Is(err, ErrNotFound) {
					t.Fatal("failed decrypt left committed record")
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				if restored, err := target.Get(ctx, r.ID); err != nil || !reflect.DeepEqual(restored, r) {
					t.Fatal("encrypted saved graph changed")
				}
			}
		})
	}
}
