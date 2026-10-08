package library

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"

	"kinlogue/internal/document"
)

var ctx = context.Background()

func openTest(t *testing.T) (*Store, string) {
	t.Helper()
	root := filepath.Join(t.TempDir(), "library")
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s, root
}

func extraction() document.Extraction {
	return document.Extraction{Kind: "pdf", PageCount: 1, Engine: "synthetic", Blocks: []document.Block{{Page: 1, Text: "合成转录 Source OCR", Method: "synthetic", Confidence: 1}}}
}

func TestExtractionTextBytesIncludeEverySeparator(t *testing.T) {
	for _, test := range []struct {
		name  string
		texts []string
		want  int
	}{
		{"nil", nil, 0},
		{"empty", []string{}, 0},
		{"one empty block", []string{""}, 0},
		{"empty block separators", []string{"", "", ""}, 2},
		{"embedded newline", []string{"", "\n", ""}, 3},
		{"UTF-8 bytes", []string{"合成", "📄", ""}, 12},
		{"raw bytes", []string{"\xff", "x"}, 3},
	} {
		t.Run(test.name, func(t *testing.T) {
			var e document.Extraction
			for _, text := range test.texts {
				e.Blocks = append(e.Blocks, document.Block{Text: text})
			}
			if got := len(e.Text()); got != test.want {
				t.Fatalf("text byte count = %d, want %d", got, test.want)
			}
			if got := extractionTextBytes(e); got != test.want {
				t.Fatalf("allocation-free byte count = %d, want %d", got, test.want)
			}
		})
	}
}

func TestValidExtractionCountsSeparatorsAtTextLimit(t *testing.T) {
	for _, delta := range []int{-1, 0, 1} {
		e := extraction()
		e.Blocks = nil
		count := document.MaxTextBytes / document.MaxBlockBytes
		for i := range count {
			length := document.MaxBlockBytes
			if i == count-1 {
				length -= count - 1 - delta
			}
			e.Blocks = append(e.Blocks, document.Block{Page: 1, Text: strings.Repeat("x", length), Method: "synthetic"})
		}
		if e.Validate() != nil || len(e.Text()) != document.MaxTextBytes+delta {
			t.Fatalf("invalid boundary fixture for delta %d", delta)
		}
		if extractionTextBytes(e) != len(e.Text()) {
			t.Fatalf("byte counting differs from source text for delta %d", delta)
		}
		if validExtraction(e) != (delta <= 0) {
			t.Fatalf("joined text limit changed for delta %d", delta)
		}
	}
}

func ready(t *testing.T, s *Store) Report {
	t.Helper()
	r, err := createSingle(s, ctx, "../../synthetic.pdf", []byte("synthetic-original"))
	if err != nil {
		t.Fatal(err)
	}
	r, err = s.SaveSourceExtraction(ctx, r.ID, r.Sources[0].ID, extraction())
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestOriginalAndExtractionRoundTripReopen(t *testing.T) {
	s, root := openTest(t)
	r := ready(t, s)
	if r.Status != "review" {
		t.Fatalf("status %q", r.Status)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	got, err := s.Get(ctx, r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got.Sources[0].Extraction, extraction()) {
		t.Fatal("extraction changed")
	}
	data, err := s.ReadOriginal(ctx, r.ID, r.Sources[0].ID)
	if err != nil || !bytes.Equal(data, []byte("synthetic-original")) {
		t.Fatalf("original roundtrip: %v", err)
	}
	if got.FileName != "../../synthetic.pdf" {
		t.Fatal("display name changed")
	}
	files, err := os.ReadDir(filepath.Join(root, "originals"))
	if err != nil || len(files) != 1 || strings.Contains(files[0].Name(), "synthetic") {
		t.Fatal("original filename must be opaque")
	}
}

func TestConfirmationGateMemberIsolationAndLiteralSearch(t *testing.T) {
	s, _ := openTest(t)
	a, err := s.AddMember(ctx, "合成甲")
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.AddMember(ctx, "Synthetic B")
	if err != nil {
		t.Fatal(err)
	}
	r := ready(t, s)
	edit := Edit{SourceIDs: r.Review.SourceIDs, MemberID: a.ID, Title: "合成检查", Date: "2026-10-07", Text: "Corrected literal 10%_VALUE", Notes: "合成备注"}
	if _, err := s.SaveReview(ctx, r.ID, edit); err != nil {
		t.Fatal(err)
	}
	if hits, err := s.Search(ctx, a.ID, ""); err != nil || len(hits) != 0 {
		t.Fatal("draft leaked into timeline")
	}
	if _, err := s.Confirm(ctx, r.ID, edit); err != nil {
		t.Fatal(err)
	}
	for _, query := range []string{"", "检查", "corrected", "10%_value", "备注"} {
		hits, err := s.Search(ctx, a.ID, query)
		if err != nil || len(hits) != 1 {
			t.Fatalf("missing expected search: %v", err)
		}
	}
	for _, scope := range []struct{ member, query string }{{b.ID, ""}, {a.ID, "10__value"}, {a.ID, "Source OCR"}, {"", ""}} {
		hits, err := s.Search(ctx, scope.member, scope.query)
		if err == nil && len(hits) != 0 {
			t.Fatal("unscoped, OCR, or wildcard search leaked data")
		}
	}
	got, err := s.Get(ctx, r.ID)
	if err != nil || !reflect.DeepEqual(got.Sources[0].Extraction, extraction()) || !got.Review.Equal(edit) {
		t.Fatalf("review overwrote OCR: %v", err)
	}
	if _, err := s.SaveReview(ctx, r.ID, edit); !errors.Is(err, ErrState) {
		t.Fatal("confirmed record saved as draft")
	}
	if _, err := s.SaveSourceExtraction(ctx, r.ID, r.Sources[0].ID, extraction()); err == nil {
		t.Fatal("confirmed extraction overwritten")
	}
}

func TestInvalidConfirmationKeepsDraft(t *testing.T) {
	for _, test := range []struct {
		name       string
		invalidate func(*Edit)
	}{
		{"missing_member", func(e *Edit) { e.MemberID = "" }},
		{"malformed_member", func(e *Edit) { e.MemberID = "missing" }},
		{"unknown_member", func(e *Edit) { e.MemberID = opaqueID() }},
		{"empty_title", func(e *Edit) { e.Title = "" }},
		{"invalid_date", func(e *Edit) { e.Date = "2026-02-30" }},
		{"oversized_text", func(e *Edit) { e.Text = strings.Repeat("x", document.MaxTextBytes+1) }},
	} {
		t.Run(test.name, func(t *testing.T) {
			s, _ := openTest(t)
			r := ready(t, s)
			m, err := s.AddMember(ctx, "Synthetic")
			if err != nil {
				t.Fatal(err)
			}
			valid := Edit{SourceIDs: r.Review.SourceIDs, MemberID: m.ID, Title: "Synthetic title", Date: "2026-10-07", Text: "Synthetic correction", Notes: "Synthetic note"}
			invalid := valid
			test.invalidate(&invalid)
			if _, err := s.Confirm(ctx, r.ID, invalid); !errors.Is(err, ErrInvalid) {
				t.Fatalf("invalid confirmation returned %v", err)
			}
			got, err := s.Get(ctx, r.ID)
			if err != nil || !reflect.DeepEqual(got, r) {
				t.Fatal("invalid confirmation changed draft or source content")
			}
			// The same fixture with only the target condition repaired must succeed;
			// missing source order or another invalid field cannot mask this case.
			if _, err := s.Confirm(ctx, r.ID, valid); err != nil {
				t.Fatalf("repaired confirmation rejected: %v", err)
			}
		})
	}
	s, _ := openTest(t)
	r := ready(t, s)
	m, err := s.AddMember(ctx, "Synthetic")
	if err != nil {
		t.Fatal(err)
	}
	partial := Edit{SourceIDs: r.Review.SourceIDs, Text: "User correction"}
	if _, err := s.SaveReview(ctx, r.ID, partial); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SaveSourceExtraction(ctx, r.ID, r.Sources[0].ID, extraction()); err == nil {
		t.Fatal("immutable extraction changed")
	}
	if _, err := s.Confirm(ctx, r.ID, Edit{SourceIDs: r.Review.SourceIDs, MemberID: m.ID, Title: "Unknown date"}); err != nil {
		t.Fatal(err)
	}
}

func TestRecoveryAndLifetimeOwnerLock(t *testing.T) {
	s, root := openTest(t)
	r, err := createSingle(s, ctx, "synthetic.pdf", []byte("synthetic"))
	if err != nil {
		t.Fatal(err)
	}
	if other, err := Open(root); err == nil {
		other.Close()
		t.Fatal("overlapping owner allowed")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	got, err := s.Get(ctx, r.ID)
	if err != nil || got.Status != "failed" || got.Failure != "interrupted" {
		t.Fatalf("interruption recovery: %v", err)
	}
	if _, err := s.SaveSourceExtraction(ctx, r.ID, r.Sources[0].ID, extraction()); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DeleteReport(ctx, r.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Get(ctx, r.ID); err == nil {
		t.Fatal("deleted draft remains")
	}
}

func TestUnknownSchemaRefused(t *testing.T) {
	s, root := openTest(t)
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(root, "library.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("PRAGMA user_version=99"); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(filepath.Join(root, "library.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if s, err := Open(root); !errors.Is(err, ErrUnsupported) {
		if s != nil {
			s.Close()
		}
		t.Fatalf("unknown schema result: %v", err)
	}
	after, err := os.ReadFile(filepath.Join(root, "library.sqlite"))
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("unknown database changed")
	}
}

func TestPrivateFIFORefused(t *testing.T) {
	for _, entry := range []string{"library.sqlite", "library.sqlite-journal", ".owner.lock"} {
		t.Run(entry, func(t *testing.T) {
			root := t.TempDir()
			if err := os.Chmod(root, 0700); err != nil {
				t.Fatal(err)
			}
			if err := syscall.Mkfifo(filepath.Join(root, entry), 0600); err != nil {
				t.Fatal(err)
			}
			if s, err := Open(root); !errors.Is(err, ErrCorrupt) {
				if s != nil {
					s.Close()
				}
				t.Fatalf("unsafe private FIFO result: %v", err)
			}
		})
	}
}

func TestFailureCodeAndClosedErrorsAreFixed(t *testing.T) {
	s, _ := openTest(t)
	r, err := createSingle(s, ctx, "synthetic.pdf", []byte("synthetic"))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.FailDraft(ctx, r.ID, "arbitrary native error with content"); !errors.Is(err, ErrInvalid) {
		t.Fatal("arbitrary error persisted")
	}
	if err := s.FailDraft(ctx, r.ID, "unavailable"); err != nil {
		t.Fatal(err)
	}
	got, err := s.Get(ctx, r.ID)
	if err != nil || got.Status != "failed" || got.Failure != "unavailable" {
		t.Fatal("failure enum lost")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Members(ctx); !errors.Is(err, ErrClosed) {
		t.Fatal("closed store accepted access")
	}
	if err := s.Close(); err != nil {
		t.Fatal("close is not idempotent")
	}
}

func TestUnknownNonemptyDirectoryUntouched(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "existing.data"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	if s, err := Open(root); !errors.Is(err, ErrUnsupported) {
		if s != nil {
			s.Close()
		}
		t.Fatalf("unknown directory result: %v", err)
	}
	files, err := os.ReadDir(root)
	if err != nil || len(files) != 1 {
		t.Fatal("unknown directory changed")
	}
}

func TestUnsafeOriginalRejectedWithoutBlocking(t *testing.T) {
	for _, mode := range []string{"corrupt", "symlink", "fifo"} {
		t.Run(mode, func(t *testing.T) {
			s, root := openTest(t)
			r := ready(t, s)
			files, err := os.ReadDir(filepath.Join(root, "originals"))
			if err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(root, "originals", files[0].Name())
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			switch mode {
			case "corrupt":
				err = os.WriteFile(path, []byte("synthetic-corrupt!"), 0600)
			case "symlink":
				target := filepath.Join(t.TempDir(), "target")
				if err := os.WriteFile(target, []byte("synthetic-original"), 0600); err != nil {
					t.Fatal(err)
				}
				err = os.Symlink(target, path)
			case "fifo":
				err = syscall.Mkfifo(path, 0600)
			}
			if err != nil {
				t.Fatal(err)
			}
			if _, err := s.ReadOriginal(ctx, r.ID, r.Sources[0].ID); err == nil {
				t.Fatal("unsafe original accepted")
			}
		})
	}
}

func TestSymlinkedRootAndPrivateEntriesRefused(t *testing.T) {
	for _, entry := range []string{"root", "originals", "library.sqlite", ".owner.lock"} {
		t.Run(entry, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "library")
			target := t.TempDir()
			if entry != "root" {
				if err := os.Mkdir(root, 0700); err != nil {
					t.Fatal(err)
				}
			}
			link := root
			if entry != "root" {
				link = filepath.Join(root, entry)
			}
			if err := os.Symlink(target, link); err != nil {
				t.Fatal(err)
			}
			if s, err := Open(root); err == nil {
				s.Close()
				t.Fatal("symlink opened")
			}
		})
	}
}

func TestLanguageSurvivesReopen(t *testing.T) {
	s, root := openTest(t)
	if language, err := s.Language(ctx); err != nil || language != "system" {
		t.Fatal("default language")
	}
	if err := s.SetLanguage(ctx, "zh-Hans"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetLanguage(ctx, "invalid"); err == nil {
		t.Fatal("invalid language accepted")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if language, err := s.Language(ctx); err != nil || language != "zh-Hans" {
		t.Fatal("language lost")
	}
}

func TestPrivateDirectoryReplacementStopsAccess(t *testing.T) {
	s, root := openTest(t)
	r := ready(t, s)
	if err := os.Rename(filepath.Join(root, "originals"), filepath.Join(root, "old-originals")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("old-originals", filepath.Join(root, "originals")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ReadOriginal(ctx, r.ID, r.Sources[0].ID); err == nil {
		t.Fatal("replaced originals directory accepted")
	}
	if _, err := createSingle(s, ctx, "synthetic.pdf", []byte("synthetic")); err == nil {
		t.Fatal("write entered replaced originals directory")
	}
}

func TestCancelledAndInvalidOriginalNotPublished(t *testing.T) {
	s, root := openTest(t)
	if _, err := createSingle(s, ctx, "empty.pdf", nil); err == nil {
		t.Fatal("empty original accepted")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := createSingle(s, cancelled, "synthetic.pdf", []byte("synthetic")); err == nil {
		t.Fatal("cancelled import accepted")
	}
	drafts, err := s.Drafts(ctx)
	if err != nil || len(drafts) != 0 {
		t.Fatal("failed import published")
	}
	files, err := os.ReadDir(filepath.Join(root, "originals"))
	if err != nil || len(files) != 0 {
		t.Fatal("invalid import wrote original")
	}
}

func createSingle(s *Store, ctx context.Context, name string, data []byte) (Report, error) {
	return s.CreateDraftSources(ctx, []string{name}, func(int) ([]byte, error) { return data, nil })
}
