package app

import (
	"context"
	"errors"
	"image"
	"path/filepath"
	"testing"
	"time"

	"kinlogue/internal/document"
	"kinlogue/internal/library"
)

type processor struct {
	extract func(context.Context, []byte) (document.Extraction, error)
}

func (p processor) Extract(c context.Context, b []byte) (document.Extraction, error) {
	return p.extract(c, b)
}
func (p processor) RenderPage(context.Context, []byte, int) (image.Image, error) {
	return image.NewRGBA(image.Rect(0, 0, 2, 2)), nil
}

func synthetic() document.Extraction {
	return document.Extraction{Kind: "pdf", PageCount: 1, Engine: "synthetic", Blocks: []document.Block{{Page: 1, Text: "Synthetic OCR", Method: "synthetic", Confidence: 1}}}
}

func newTestService(t *testing.T, p Processor) (*Service, *library.Store) {
	t.Helper()
	s, err := library.Open(filepath.Join(t.TempDir(), "library"))
	if err != nil {
		t.Fatal(err)
	}
	a := New(s, p, func(string) ([]byte, error) { return []byte("synthetic-original"), nil }, nil)
	t.Cleanup(func() { _ = a.Close() })
	return a, s
}

func TestImportReviewConfirmSearchRealStorage(t *testing.T) {
	a, s := newTestService(t, processor{func(context.Context, []byte) (document.Extraction, error) { return synthetic(), nil }})
	c := context.Background()
	m, err := a.AddMember(c, "Synthetic member")
	if err != nil {
		t.Fatal(err)
	}
	r, err := a.Import(c, "/synthetic/input.pdf")
	if err != nil || r.Status != "review" || r.FileName != "input.pdf" {
		t.Fatalf("import: %v, %s", err, r.Status)
	}
	if rows, err := a.Search(c, m.ID, ""); err != nil || len(rows) != 0 {
		t.Fatal("draft searchable")
	}
	edit := library.Edit{MemberID: m.ID, Title: "合成检查", Date: "2026-10-07", Text: "用户确认的文字", SourceIDs: r.Review.SourceIDs}
	if _, err := a.SaveReview(c, r.ID, edit); err != nil {
		t.Fatal(err)
	}
	if _, err := a.Confirm(c, r.ID, edit); err != nil {
		t.Fatal(err)
	}
	rows, err := a.Search(c, m.ID, "确认")
	if err != nil || len(rows) != 1 {
		t.Fatal("confirmed transcript missing")
	}
	got, err := s.Get(c, r.ID)
	if err != nil || got.Sources[0].Extraction.Text() != "Synthetic OCR" {
		t.Fatal("source extraction overwritten")
	}
	if _, err := a.Preview(c, r.ID, r.Sources[0].ID, 1); err != nil {
		t.Fatal(err)
	}
	if _, err := a.Preview(c, r.ID, r.Sources[0].ID, 2); !errors.Is(err, document.ErrInvalid) {
		t.Fatal("invalid preview page accepted")
	}
}

func TestCancelledRecognitionCannotPublishLateSuccess(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	a, s := newTestService(t, processor{func(context.Context, []byte) (document.Extraction, error) {
		close(entered)
		<-release
		return synthetic(), nil
	}})
	c, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, err := a.Import(c, "/synthetic/input.pdf"); done <- err }()
	<-entered
	cancel()
	close(release)
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("expected cancellation, got %v", err)
	}
	rows, err := s.Drafts(context.Background())
	if err != nil || len(rows) != 1 || rows[0].Status != "failed" {
		t.Fatal("late success published")
	}
	full, err := s.Get(context.Background(), rows[0].ID)
	if err != nil || len(full.Sources) != 1 || full.Sources[0].Extraction.Engine != "" {
		t.Fatal("cancelled source result was persisted")
	}
}

func TestCloseCancelsAndWaitsBeforeClosingStorage(t *testing.T) {
	entered := make(chan struct{})
	cancelled := make(chan struct{})
	release := make(chan struct{})
	a, _ := newTestService(t, processor{func(c context.Context, _ []byte) (document.Extraction, error) {
		close(entered)
		<-c.Done()
		close(cancelled)
		<-release
		return synthetic(), nil
	}})
	done := make(chan error, 1)
	go func() { _, err := a.Import(context.Background(), "/synthetic/input.pdf"); done <- err }()
	<-entered
	closed := make(chan error, 1)
	go func() { closed <- a.Close() }()
	<-cancelled
	select {
	case <-closed:
		t.Fatal("closed before recognition settled")
	case <-time.After(20 * time.Millisecond):
	}
	if _, err := a.Members(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatal("command admitted while closing")
	}
	close(release)
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatal("shutdown did not cancel import")
	}
	if err := <-closed; err != nil {
		t.Fatal(err)
	}
}

func TestRetryDoesNotOverwriteReviewedReport(t *testing.T) {
	calls := 0
	a, _ := newTestService(t, processor{func(context.Context, []byte) (document.Extraction, error) {
		calls++
		if calls == 1 {
			return document.Extraction{}, document.ErrUnavailable
		}
		return synthetic(), nil
	}})
	c := context.Background()
	r, err := a.Import(c, "/synthetic/input.pdf")
	if !errors.Is(err, document.ErrUnavailable) || r.Status != "failed" {
		t.Fatal("failure not persisted")
	}
	if img, err := a.Preview(c, r.ID, r.Sources[0].ID, 1); err != nil || img == nil {
		t.Fatal("failed recognition hid a readable original")
	}
	if _, err := a.Preview(c, r.ID, r.Sources[0].ID, 2); !errors.Is(err, document.ErrInvalid) {
		t.Fatal("failed recognition exposed an unverified page")
	}
	r, err = a.Retry(c, r.ID)
	if err != nil || r.Status != "review" {
		t.Fatal("explicit retry failed")
	}
	if _, err := a.Retry(c, r.ID); !errors.Is(err, library.ErrState) {
		t.Fatal("reviewed source could be replaced")
	}
	if calls != 2 {
		t.Fatal("invalid retry reached OCR")
	}
}

func TestRejectedExtractionRemainsRecoverable(t *testing.T) {
	a, s := newTestService(t, processor{func(context.Context, []byte) (document.Extraction, error) {
		e := synthetic()
		e.Kind = "unknown"
		return e, nil
	}})
	r, err := a.Import(context.Background(), "/synthetic/input.pdf")
	if !errors.Is(err, library.ErrInvalid) || r.Status != "failed" {
		t.Fatal("rejected extraction left a processing draft")
	}
	if got, err := s.Get(context.Background(), r.ID); err != nil || got.Sources[0].Extraction.Engine != "" {
		t.Fatal("invalid extraction was persisted")
	}
}
