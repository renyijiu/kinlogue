//go:build darwin

package app_test

import (
	"archive/zip"
	"bytes"
	"context"
	"fmt"
	"image"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kinlogue/internal/app"
	"kinlogue/internal/document"
	"kinlogue/internal/library"
	"kinlogue/internal/macos"
)

func TestNativeGroupedReportExportsReorderedOriginals(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	first := integrationPDF()
	second := bytes.ReplaceAll(first, []byte("RAW SOURCE"), []byte("NEW SOURCE"))
	paths := []string{filepath.Join(dir, "first.pdf"), filepath.Join(dir, "second.pdf")}
	for i, data := range [][]byte{first, second} {
		if err := os.WriteFile(paths[i], data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	store, err := library.Open(filepath.Join(dir, "library"))
	if err != nil {
		t.Fatal(err)
	}
	service := app.New(store, nativeProcessor{}, macos.ReadImportedFile, macos.WriteExport)
	defer service.Close()
	r, err := service.ImportMany(ctx, paths)
	if err != nil || r.Status != "review" || len(r.Sources) != 2 {
		t.Fatalf("native group: %v", err)
	}
	for _, source := range r.Sources {
		if source.Extraction.PageCount != 2 || source.Extraction.Blocks[1].Page != 2 {
			t.Fatal("source-local page lost")
		}
		if _, err := service.Preview(ctx, r.ID, source.ID, 2); err != nil {
			t.Fatal(err)
		}
	}
	m, err := service.AddMember(ctx, "Synthetic export member")
	if err != nil {
		t.Fatal(err)
	}
	e := r.Review
	e.MemberID, e.Title = m.ID, "Synthetic grouped report"
	r, err = service.Confirm(ctx, r.ID, e)
	if err != nil {
		t.Fatal(err)
	}
	e = r.Review
	e.SourceIDs = []string{r.Sources[1].ID, r.Sources[0].ID}
	e.Text = "合成确认后的修改"
	if _, err := service.UpdateConfirmed(ctx, r.ID, e); err != nil {
		t.Fatal(err)
	}
	export := filepath.Join(dir, "originals.zip")
	if err := service.ExportOriginals(ctx, r.ID, export); err != nil {
		t.Fatalf("native export: %v", err)
	}
	z, err := zip.OpenReader(export)
	if err != nil {
		t.Fatal(err)
	}
	defer z.Close()
	if len(z.File) != 2 {
		t.Fatal("export included non-original data")
	}
	for i, want := range [][]byte{second, first} {
		f, err := z.File[i].Open()
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(f)
		_ = f.Close()
		if err != nil || !bytes.Equal(data, want) {
			t.Fatal("export differs from ordered originals")
		}
	}
	deleted, err := service.DeleteReport(ctx, r.ID)
	if err != nil || deleted.CleanupPending {
		t.Fatalf("delete: %v", err)
	}
	if rows, err := service.Search(ctx, m.ID, ""); err != nil || len(rows) != 0 {
		t.Fatal("deleted report remains searchable")
	}
	for i, want := range [][]byte{first, second} {
		data, err := os.ReadFile(paths[i])
		if err != nil || !bytes.Equal(data, want) {
			t.Fatal("delete changed the external selected file")
		}
	}
}

type nativeProcessor struct{}

func (nativeProcessor) Extract(ctx context.Context, data []byte) (document.Extraction, error) {
	return macos.Extract(ctx, data)
}

func (nativeProcessor) RenderPage(ctx context.Context, data []byte, page int) (image.Image, error) {
	return macos.RenderPage(ctx, data, page)
}

// This integration uses the production file reader, PDFKit processor, service,
// and SQLite store together. Temporary paths are injected only by this test;
// the production composition root still requires its sandboxed bundle identity.
func TestNativeReportWorkflowSurvivesReopen(t *testing.T) {
	ctx := context.Background()
	root := filepath.Join(t.TempDir(), "library")
	source := filepath.Join(t.TempDir(), "synthetic.pdf")
	original := integrationPDF()
	if err := os.WriteFile(source, original, 0600); err != nil {
		t.Fatal("could not create synthetic source")
	}
	open := func() (*app.Service, *library.Store) {
		t.Helper()
		store, err := library.Open(root)
		if err != nil {
			t.Fatalf("open library: %v", err)
		}
		service := app.New(store, nativeProcessor{}, macos.ReadImportedFile, macos.WriteExport)
		t.Cleanup(func() {
			if err := service.Close(); err != nil {
				t.Errorf("close library: %v", err)
			}
		})
		return service, store
	}
	assertSearch := func(service *app.Service, member, query string, count int) {
		t.Helper()
		rows, err := service.Search(ctx, member, query)
		if err != nil || len(rows) != count {
			t.Fatalf("search visibility: count=%d want=%d error=%v", len(rows), count, err)
		}
	}

	service, _ := open()
	member, err := service.AddMember(ctx, "Synthetic member A")
	if err != nil {
		t.Fatal(err)
	}
	other, err := service.AddMember(ctx, "Synthetic member B")
	if err != nil {
		t.Fatal(err)
	}
	report, err := service.Import(ctx, source)
	if err != nil || report.Status != "review" {
		t.Fatalf("native import: status=%s error=%v", report.Status, err)
	}
	raw := report.Sources[0].Extraction
	if raw.Kind != "pdf" || raw.PageCount != 2 || len(raw.Blocks) != 2 {
		t.Fatal("native extraction lost PDF pages")
	}
	for i, block := range raw.Blocks {
		if block.Page != i+1 || block.Method != "pdfTextLayer" || block.Bounds.Width <= 0 || block.Bounds.Height <= 0 {
			t.Fatal("native extraction lost page provenance")
		}
		if !strings.Contains(block.Text, fmt.Sprintf("RAW SOURCE PAGE %d", i+1)) {
			t.Fatal("native extraction lost synthetic source anchor")
		}
	}
	if report.Review.Text != raw.Text() {
		t.Fatal("initial review did not receive native transcription")
	}
	assertSearch(service, member.ID, "", 0)
	edit := library.Edit{MemberID: member.ID, Title: "合成复核报告", Date: "2026-10-07", Text: "人工修正转录", Notes: "合成备注", SourceIDs: report.Review.SourceIDs}
	if _, err := service.SaveReview(ctx, report.ID, edit); err != nil {
		t.Fatal(err)
	}
	assertSearch(service, member.ID, "修正", 0)
	if err := service.Close(); err != nil {
		t.Fatal(err)
	}

	// A fresh store and service must recover the saved candidate and immutable
	// source without recognition running again or confirmation being implied.
	service, store := open()
	reopened, err := service.Get(ctx, report.ID)
	if err != nil || reopened.Status != "review" || !reopened.Review.Equal(edit) || !reflect.DeepEqual(reopened.Sources[0].Extraction, raw) {
		t.Fatal("saved review or native provenance changed after reopen")
	}
	members, err := service.Members(ctx)
	if err != nil || len(members) != 2 {
		t.Fatal("members did not survive reopen")
	}
	drafts, err := service.Drafts(ctx)
	if err != nil || len(drafts) != 1 || drafts[0].ID != report.ID {
		t.Fatal("saved review missing from drafts")
	}
	assertSearch(service, member.ID, "", 0)
	preview, err := service.Preview(ctx, report.ID, report.Sources[0].ID, 2)
	if err != nil || preview == nil || preview.Bounds().Dx() != 1200 || preview.Bounds().Dy() != 1600 {
		t.Fatalf("native page preview failed: %v", err)
	}
	data, err := store.ReadOriginal(ctx, report.ID, report.Sources[0].ID)
	if err != nil || !bytes.Equal(data, original) {
		t.Fatal("stored original changed across import and reopen")
	}
	confirmed, err := service.Confirm(ctx, report.ID, reopened.Review)
	if err != nil || confirmed.Status != "confirmed" || !reflect.DeepEqual(confirmed.Sources[0].Extraction, raw) {
		t.Fatal("confirmation changed source extraction or failed")
	}
	assertSearch(service, member.ID, "修正", 1)
	assertSearch(service, member.ID, "RAW SOURCE", 0)
	assertSearch(service, other.ID, "", 0)
	if err := service.Close(); err != nil {
		t.Fatal(err)
	}

	service, _ = open()
	confirmed, err = service.Get(ctx, report.ID)
	if err != nil || confirmed.Status != "confirmed" || !confirmed.Review.Equal(edit) || !reflect.DeepEqual(confirmed.Sources[0].Extraction, raw) {
		t.Fatal("confirmed record or provenance changed after second reopen")
	}
	assertSearch(service, member.ID, "修正", 1)
	assertSearch(service, other.ID, "", 0)
	if drafts, err := service.Drafts(ctx); err != nil || len(drafts) != 0 {
		t.Fatal("confirmed record still appears in drafts")
	}
	if data, err := os.ReadFile(source); err != nil || !bytes.Equal(data, original) {
		t.Fatal("import modified the selected source")
	}
}

// A generated two-page text PDF avoids binary fixtures and deliberately gives
// each page a different non-medical anchor so incorrect source ordering fails.
func integrationPDF() []byte {
	objects := []string{"<< /Type /Catalog /Pages 2 0 R >>", ""}
	kids := make([]string, 2)
	for i := range 2 {
		pageID := len(objects) + 1
		kids[i] = fmt.Sprintf("%d 0 R", pageID)
		content := fmt.Sprintf("BT /F1 28 Tf 40 100 Td (RAW SOURCE PAGE %d) Tj ET", i+1)
		objects = append(objects, fmt.Sprintf("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents %d 0 R >>", pageID+1), fmt.Sprintf("<< /Length %d >>\nstream\n%s\nendstream", len(content), content))
	}
	objects[1] = fmt.Sprintf("<< /Type /Pages /Kids [%s] /Count 2 >>", strings.Join(kids, " "))
	var buf bytes.Buffer
	buf.WriteString("%PDF-1.4\n")
	offsets := []int{0}
	for i, object := range objects {
		offsets = append(offsets, buf.Len())
		fmt.Fprintf(&buf, "%d 0 obj\n%s\nendobj\n", i+1, object)
	}
	xref := buf.Len()
	fmt.Fprintf(&buf, "xref\n0 %d\n0000000000 65535 f \n", len(offsets))
	for _, offset := range offsets[1:] {
		fmt.Fprintf(&buf, "%010d 00000 n \n", offset)
	}
	fmt.Fprintf(&buf, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", len(offsets), xref)
	return buf.Bytes()
}
