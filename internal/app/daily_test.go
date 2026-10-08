package app

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"io"
	"path/filepath"
	"reflect"
	"testing"

	"kinlogue/internal/document"
	"kinlogue/internal/library"
)

func TestGroupedImportRetryKeepsSuccessfulSourceAndLocalPages(t *testing.T) {
	ctx := context.Background()
	calls := map[string]int{}
	a, _ := newTestService(t, processor{func(_ context.Context, data []byte) (document.Extraction, error) {
		name := string(data)
		calls[name]++
		if name == "second.pdf" && calls[name] == 1 {
			return document.Extraction{}, document.ErrUnavailable
		}
		e := synthetic()
		e.Blocks[0].Text = name
		return e, nil
	}})
	a.readFile = func(path string) ([]byte, error) { return []byte(filepath.Base(path)), nil }
	r, err := a.ImportMany(ctx, []string{"/synthetic/first.pdf", "/synthetic/second.pdf"})
	if !errors.Is(err, document.ErrUnavailable) || r.Status != "failed" || len(r.Sources) != 2 {
		t.Fatalf("grouped failure not recoverable: %v", err)
	}
	if r.Sources[0].Extraction.Text() != "first.pdf" || r.Sources[1].Extraction.Engine != "" {
		t.Fatal("partial source outcome lost or published as success")
	}
	if _, err := a.Preview(ctx, r.ID, r.Sources[1].ID, 1); err != nil {
		t.Fatal("failed source original should remain inspectable")
	}
	r, err = a.Retry(ctx, r.ID)
	if err != nil || r.Status != "review" || calls["first.pdf"] != 1 || calls["second.pdf"] != 2 {
		t.Fatal("retry repeated successful OCR or failed to complete")
	}
	if r.Review.Text != "first.pdf\nsecond.pdf" || r.Sources[0].Extraction.Blocks[0].Page != 1 || r.Sources[1].Extraction.Blocks[0].Page != 1 {
		t.Fatal("report text or source-local page provenance changed")
	}
	if _, err := a.Preview(ctx, r.ID, "other-source", 1); !errors.Is(err, library.ErrNotFound) {
		t.Fatal("preview accepted an unrelated source")
	}
}

func TestConfirmedCorrectionExportAndDeleteUseActualStoredOriginals(t *testing.T) {
	ctx := context.Background()
	a, _ := newTestService(t, processor{func(_ context.Context, data []byte) (document.Extraction, error) {
		e := synthetic()
		e.Blocks[0].Text = string(data)
		return e, nil
	}})
	a.readFile = func(path string) ([]byte, error) { return []byte(filepath.Base(path)), nil }
	var archive bytes.Buffer
	writeCalls := 0
	a.writeExport = func(c context.Context, path string, write func(io.Writer) error) error {
		writeCalls++
		return write(&archive)
	}
	r, err := a.ImportMany(ctx, []string{"/synthetic/one.pdf", "/synthetic/two.pdf"})
	if err != nil {
		t.Fatal(err)
	}
	if err := a.ExportOriginals(ctx, r.ID, "/synthetic/output.zip"); !errors.Is(err, library.ErrState) || writeCalls != 0 {
		t.Fatal("draft export reached publication")
	}
	m, _ := a.AddMember(ctx, "Synthetic A")
	other, _ := a.AddMember(ctx, "Synthetic B")
	e := r.Review
	e.MemberID, e.Title, e.Text = m.ID, "Synthetic report", "旧修正"
	r, err = a.Confirm(ctx, r.ID, e)
	if err != nil {
		t.Fatal(err)
	}
	raw := append([]library.Source(nil), r.Sources...)
	e = r.Review
	e.SourceIDs = []string{r.Sources[1].ID, r.Sources[0].ID}
	e.MemberID, e.Text, e.Notes = other.ID, "新修正", "Private synthetic note excluded from ZIP"
	if rows, _ := a.Search(ctx, m.ID, "旧修正"); len(rows) != 1 {
		t.Fatal("local edits changed saved content")
	}
	r, err = a.UpdateConfirmed(ctx, r.ID, e)
	if err != nil || r.Status != "confirmed" || !r.Review.Equal(e) {
		t.Fatal("confirmed edit did not commit")
	}
	if !reflect.DeepEqual(r.Sources[0], raw[1]) || !reflect.DeepEqual(r.Sources[1], raw[0]) {
		t.Fatal("reorder changed original recognition")
	}
	if rows, _ := a.Search(ctx, m.ID, ""); len(rows) != 0 {
		t.Fatal("old member still sees moved record")
	}
	if rows, _ := a.Search(ctx, other.ID, "新修正"); len(rows) != 1 {
		t.Fatal("new member cannot search correction")
	}
	if err := a.ExportOriginals(ctx, r.ID, "/synthetic/output.zip"); err != nil {
		t.Fatal(err)
	}
	z, err := zip.NewReader(bytes.NewReader(archive.Bytes()), int64(archive.Len()))
	if err != nil || len(z.File) != 2 {
		t.Fatal("invalid original-only ZIP")
	}
	for i, want := range []string{"two.pdf", "one.pdf"} {
		f, err := z.File[i].Open()
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(f)
		_ = f.Close()
		if err != nil || string(data) != want {
			t.Fatal("ZIP did not preserve source order and bytes")
		}
		if z.File[i].Name != []string{"001.pdf", "002.pdf"}[i] {
			t.Fatal("ZIP exposed a display name or unsafe path")
		}
	}
	deleted, err := a.DeleteReport(ctx, r.ID)
	if err != nil || deleted.CleanupPending {
		t.Fatal("deletion did not finish owned source cleanup")
	}
	if _, err := a.Get(ctx, r.ID); !errors.Is(err, library.ErrNotFound) {
		t.Fatal("deleted record remains visible")
	}
}

func TestGroupedImportRejectsSourceCountBeforeReading(t *testing.T) {
	a, _ := newTestService(t, processor{func(context.Context, []byte) (document.Extraction, error) { return synthetic(), nil }})
	reads := 0
	a.readFile = func(string) ([]byte, error) { reads++; return nil, nil }
	if _, err := a.ImportMany(context.Background(), make([]string, document.MaxSources+1)); !errors.Is(err, document.ErrLimit) || reads != 0 {
		t.Fatal("source budget did not reject before file access")
	}
}
