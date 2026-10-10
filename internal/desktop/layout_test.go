package desktop

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/egoist/mygo/ui"
	"kinlogue/internal/app"
	"kinlogue/internal/document"
	"kinlogue/internal/library"
)

func TestConfirmedReportKeepsTimelineAndOriginalBelowSummary(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Status = "confirmed"
	s.accept(f.report)
	s.memberID = "member-a"
	s.records = []library.Report{f.report, {ID: "report-b", Review: library.Edit{Title: "Another synthetic record"}}}
	tt := ui.NewTester(s.view, 1240, 880)
	if !tt.HasText("Another synthetic record") || !tt.HasText("All Records") {
		t.Fatal("opening a report hid the timeline or all-records navigation")
	}
	summary, ok := tt.Find("Findings")
	if !ok {
		t.Fatal("confirmed content is still an editing form")
	}
	original, ok := tt.Find("Original")
	if !ok || original.Y <= summary.Y {
		t.Fatal("original is not below the summary")
	}
	if err := tt.Click("Settings"); err != nil {
		t.Fatal(err)
	}
	if !tt.HasText("Language") || tt.HasText("Another synthetic record") {
		t.Fatal("settings did not replace report panes")
	}
}

// The review sheet blocks the timeline like a Swift sheet: clicking behind it
// neither switches records nor discards the edits.
func TestReviewSheetBlocksTimelineAndKeepsEdits(t *testing.T) {
	s, _, _ := testScreen(t)
	s.memberID = "member-a"
	s.records = []library.Report{{ID: "report-b", Review: library.Edit{Title: "Another synthetic record"}}}
	s.edit.Notes = "Unsaved synthetic note"
	tt := ui.NewTester(s.view, 1240, 880)
	_ = tt.Click("Another synthetic record")
	tt.Frame()
	if s.pending != nil || s.report.ID != "report-a" || s.edit.Notes != "Unsaved synthetic note" || !tt.HasText("Confirm Report Information") {
		t.Fatal("record switch passed the open review sheet")
	}
}

func TestInitialRecognitionIsReachableAtMinimumWindowHeight(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Status = "confirmed"
	f.report.Sources = append(f.report.Sources, library.Source{ID: "source-b", FileName: "second-synthetic.pdf"})
	f.report.Review.SourceIDs = append(f.report.Review.SourceIDs, "source-b")
	s.accept(f.report)
	s.startEditing()
	s.showRaw = true
	tt := ui.NewTester(s.view, 1080, 700)
	toggle, ok := tt.Find("Show initial recognition")
	if !ok {
		t.Fatal("initial recognition toggle missing from the edit sheet")
	}
	tt.Scroll(toggle.X+30, toggle.Y-40, 0, 1000)
	raw, ok := tt.Find("Source page 1")
	if !ok || raw.Y < 0 || raw.Y+raw.H > 700 {
		t.Fatal("initial recognition is clipped and cannot be scrolled into view")
	}
}

func TestAllRecordsSearchAndMemberFilterUseRealLibrary(t *testing.T) {
	store, err := library.Open(filepath.Join(t.TempDir(), "library"))
	if err != nil {
		t.Fatal(err)
	}
	service := app.New(store, nil, nil, nil)
	t.Cleanup(func() { _ = service.Close() })
	ctx := context.Background()
	for i, name := range []string{"Synthetic A", "Synthetic B", "Synthetic draft"} {
		member, err := service.AddMember(ctx, name)
		if err != nil {
			t.Fatal(err)
		}
		report, err := store.CreateDraftSources(ctx, []string{"synthetic.pdf"}, func(int) ([]byte, error) { return []byte("synthetic-original"), nil })
		if err != nil {
			t.Fatal(err)
		}
		report, err = store.SaveSourceExtraction(ctx, report.ID, report.Sources[0].ID, document.Extraction{Kind: "pdf", PageCount: 1, Engine: "synthetic", Blocks: []document.Block{{Page: 1, Text: "Initial OCR", Method: "synthetic", Confidence: 1}}})
		if err != nil {
			t.Fatal(err)
		}
		edit := report.Review
		edit.MemberID, edit.Title, edit.Text = member.ID, name+" record", "shared needle"
		if i < 2 {
			_, err = service.Confirm(ctx, report.ID, edit)
		} else {
			_, err = service.SaveReview(ctx, report.ID, edit)
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	s, _, drain := testScreen(t)
	s.clearReport()
	s.backend = service
	s.load(true)
	drain()
	tt := ui.NewTester(s.view, 1240, 880)
	if err := tt.Click("Search Confirmed Records"); err != nil {
		t.Fatal(err)
	}
	tt.Type("needle")
	tt.Key(0, ui.KeyEnter)
	drain()
	tt.Frame()
	if !tt.HasText("Synthetic A record") || !tt.HasText("Synthetic B record") || tt.HasText("Synthetic draft record") {
		t.Fatal("all-records search did not aggregate confirmed members only")
	}
	if err := tt.Click("Synthetic A"); err != nil {
		t.Fatal(err)
	}
	drain()
	tt.Frame()
	if !tt.HasText("Synthetic A record") || tt.HasText("Synthetic B record") {
		t.Fatal("member navigation lost member isolation")
	}
	if err := tt.Click("All Records"); err != nil {
		t.Fatal(err)
	}
	drain()
	tt.Frame()
	if !tt.HasText("Synthetic A record") || !tt.HasText("Synthetic B record") {
		t.Fatal("all-records navigation failed after member filtering")
	}
}
