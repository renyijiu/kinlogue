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

// clickField clicks a review form field. The form is longer than its sheet
// since it gained the verbatim fields, so the fields at its end need scrolling
// into view first.
func clickField(tt *ui.Tester, label string) error {
	if label == "My Notes (Optional)" || label == "Conclusion (Verbatim)" {
		if title, ok := tt.Find("Report Title"); ok {
			tt.Scroll(title.X+title.W/2, title.Y+title.H/2, 0, 2000)
		}
	}
	return tt.Click(label)
}

func TestReviewFormSavesAndConfirmsVerbatimFields(t *testing.T) {
	s, f, drain := testScreen(t)
	tt := ui.NewTester(s.view, 1240, 900)
	// In form order: reaching the conclusion scrolls the earlier fields away.
	for _, field := range [][2]string{
		{"Hospital", "Synthetic Hospital"},
		{"Department", "Synthetic Radiology"},
		{"Report Type", "Synthetic CT"},
		{"Conclusion (Verbatim)", "Synthetic verbatim conclusion"},
	} {
		if err := clickField(tt, field[0]); err != nil {
			t.Fatal(err)
		}
		tt.Type(field[1])
	}
	if !s.dirty() {
		t.Fatal("typing a verbatim field did not mark the draft dirty")
	}
	want := library.Edit{Organization: "Synthetic Hospital", Department: "Synthetic Radiology", ReportType: "Synthetic CT", Conclusion: "Synthetic verbatim conclusion"}
	same := func(e library.Edit) bool {
		return e.Organization == want.Organization && e.Department == want.Department && e.ReportType == want.ReportType && e.Conclusion == want.Conclusion
	}
	tt.Key(ui.Cmd, ui.KeyS)
	drain()
	if !same(f.saved) || f.confirmed || s.dirty() {
		t.Fatalf("draft save lost verbatim fields: %+v", f.saved)
	}
	tt.Frame()
	tt.Key(ui.Cmd, ui.KeyEnter)
	drain()
	if !f.confirmed || !same(f.saved) || !same(s.report.Review) {
		t.Fatal("confirmation lost verbatim fields")
	}
}

func TestConfirmedEditCancelRestoresVerbatimFields(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Status = "confirmed"
	f.report.Review.Organization = "Synthetic Hospital"
	s.accept(f.report)
	s.startEditing()
	tt := ui.NewTester(s.view, 1240, 900)
	if err := clickField(tt, "Hospital"); err != nil {
		t.Fatal(err)
	}
	tt.Type(" changed")
	if !s.dirty() {
		t.Fatal("edit not tracked")
	}
	if err := tt.Click(s.t("cancel_edit")); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if s.dirty() || s.edit.Organization != "Synthetic Hospital" || f.updated {
		t.Fatal("cancel did not restore the saved hospital")
	}
}

func TestDetailShowsConclusionAndConfirmedInformation(t *testing.T) {
	s, f, drain := testScreen(t)
	f.report.Status = "confirmed"
	s.accept(f.report)
	// Tall enough for every card: the summary scrolls in a shorter window.
	tt := ui.NewTester(s.view, 1240, 1800)
	// Nothing is claimed about a report whose fields were never entered.
	if !tt.HasText(s.t("no_conclusion")) || tt.HasText(s.t("confirmed_info")) {
		t.Fatal("empty fields must show one neutral conclusion placeholder and no information card")
	}
	f.report.Review.Conclusion = "Synthetic verbatim conclusion"
	f.report.Review.Organization = "Synthetic Hospital"
	f.report.Review.ReportType = "Synthetic CT"
	s.accept(f.report)
	tt.Frame()
	for _, text := range []string{"Synthetic verbatim conclusion", s.t("confirmed_info"), s.t("organization"), "Synthetic Hospital", s.t("report_type"), "Synthetic CT"} {
		if !tt.HasText(text) {
			t.Fatalf("detail does not show %q", text)
		}
	}
	if tt.HasText(s.t("no_conclusion")) || tt.HasText(s.t("department")) {
		t.Fatal("detail shows a placeholder or a row for an empty field")
	}
	s.changeLanguage("zh-Hans")
	drain()
	tt.Frame()
	for _, text := range []string{"检查结论", "已确认信息", "医院", "报告类型"} {
		if !tt.HasText(text) {
			t.Fatalf("Chinese detail does not show %q", text)
		}
	}
}

func TestTimelineCardShowsHospitalAndConclusionSummary(t *testing.T) {
	s, _, _ := confirmedTimeline(t, allMembers)
	s.records[0].Review.Organization = "Synthetic Hospital"
	s.records[0].Summary = "Synthetic first line\n\n  Synthetic second line\nSynthetic third line"
	tt := ui.NewTester(s.view, 1240, 900)
	if !tt.HasText("Synthetic Hospital") || !tt.HasText("Synthetic first line Synthetic second line") {
		t.Fatal("card does not show the hospital and the start of the conclusion")
	}
	// The original's name stands in only where there is no conclusion.
	if tt.HasText("synthetic.pdf") || !tt.HasText("synthetic-b.pdf") {
		t.Fatal("file name fallback is wrong")
	}
}

func TestVerbatimFieldsReachTimelineSearchAndDetailThroughRealLibrary(t *testing.T) {
	store, err := library.Open(filepath.Join(t.TempDir(), "library"))
	if err != nil {
		t.Fatal(err)
	}
	service := app.New(store, evidenceProcessor{}, nil, nil)
	t.Cleanup(func() { _ = service.Close() })
	ctx := context.Background()
	member, err := service.AddMember(ctx, "Synthetic A")
	if err != nil {
		t.Fatal(err)
	}
	for _, hospital := range []string{"Synthetic North Hospital", "Synthetic South Hospital"} {
		report, err := store.CreateDraftSources(ctx, []string{"synthetic.pdf"}, func(int) ([]byte, error) { return []byte("synthetic-original"), nil })
		if err != nil {
			t.Fatal(err)
		}
		report, err = store.SaveSourceExtraction(ctx, report.ID, report.Sources[0].ID, document.Extraction{Kind: "pdf", PageCount: 1, Engine: "synthetic", Blocks: []document.Block{{Page: 1, Text: "Initial OCR", Method: "synthetic", Confidence: 1}}})
		if err != nil {
			t.Fatal(err)
		}
		edit := report.Review
		edit.MemberID, edit.Title, edit.Organization, edit.Conclusion = member.ID, hospital+" record", hospital, "Conclusion from "+hospital
		if _, err = service.Confirm(ctx, report.ID, edit); err != nil {
			t.Fatal(err)
		}
	}
	s, _, drain := testScreen(t)
	s.clearReport()
	s.backend = service
	s.load(true)
	drain()
	tt := ui.NewTester(s.view, 1240, 1800)
	if err := tt.Click("Search Confirmed Records"); err != nil {
		t.Fatal(err)
	}
	tt.Type("north hospital")
	tt.Key(0, ui.KeyEnter)
	drain()
	tt.Frame()
	if len(s.records) != 1 || s.records[0].Review.Organization != "Synthetic North Hospital" || s.records[0].Summary != "Conclusion from Synthetic North Hospital" {
		t.Fatalf("hospital search returned %d records", len(s.records))
	}
	// Opening the result loads its complete fields through Get.
	if err := tt.Click("Synthetic North Hospital record"); err != nil {
		t.Fatal(err)
	}
	drain()
	tt.Frame()
	if s.report.Review.Conclusion != "Conclusion from Synthetic North Hospital" || !tt.HasText(s.t("confirmed_info")) {
		t.Fatal("opened record lacks its verbatim fields")
	}
}
