package desktop

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
	"kinlogue/internal/app"
	"kinlogue/internal/document"
	"kinlogue/internal/library"
)

// clickField clicks a review form field. The form is longer than its sheet
// since it gained the verbatim fields, so the fields at its end need scrolling
// into view first.
func clickField(tt *ui.Tester, label string) error {
	if label == "My Notes (Optional)" || label == "My Notes" || label == "Conclusion (Verbatim)" {
		if title, ok := tt.Find("Title"); ok {
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

func labeledSource(id, hospital string) library.Source {
	line := func(text string, y float64) document.Block {
		return document.Block{Page: 1, Text: text, Method: "synthetic", Confidence: 1, Bounds: document.Rect{X: .05, Y: y, Width: .8, Height: .04}}
	}
	return library.Source{ID: id, FileName: id + ".pdf", Extraction: document.Extraction{Kind: "pdf", PageCount: 1, Engine: "synthetic", Blocks: []document.Block{
		line("医院名称："+hospital, .9), line("申请科室：Synthetic Radiology", .85), line("检查日期：2026-01-02", .8), line("报告日期：2026-01-03", .75),
		line("检查结论", .6), line("Synthetic printed conclusion", .55), line("报告医师：Synthetic", .5),
	}}}
}

func TestOlderDraftFillsOnlyEmptyFieldsOnRequest(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Sources = []library.Source{labeledSource("source-a", "Synthetic Hospital")}
	f.report.Review.Organization = "Typed by the user"
	s.accept(f.report)
	tt := ui.NewTester(s.view, 1240, 900)
	if !tt.HasText(s.t("fill_available")) || s.dirty() {
		t.Fatal("a draft with proposals for empty fields must offer them without applying them")
	}
	if err := tt.Click(s.t("fill_empty")); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if s.edit.Organization != "Typed by the user" || s.edit.Title != "Synthetic report" {
		t.Fatal("filling replaced what the user had entered")
	}
	if s.edit.Department != "Synthetic Radiology" || s.edit.Conclusion != "Synthetic printed conclusion" || !s.dirty() {
		t.Fatalf("empty fields not filled: %+v", s.edit)
	}
	if s.edit.Date != "" {
		t.Fatal("filling chose a date")
	}
	if tt.HasText(s.t("fill_available")) {
		t.Fatal("offer stayed after nothing was left to fill")
	}
}

func TestPrintedDatesAreOfferedAndNeverChosenAutomatically(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Sources = []library.Source{labeledSource("source-a", "Synthetic Hospital")}
	s.accept(f.report)
	tt := ui.NewTester(s.view, 1240, 900)
	if s.edit.Date != "" || tt.HasText("January 3, 2026 · Report Date") {
		t.Fatal("dates must stay in the closed menu until the user chooses")
	}
	if err := tt.Click(s.t("unknown_date")); err != nil {
		t.Fatal(err)
	}
	if !tt.HasText("January 2, 2026 · Study Date") {
		t.Fatal("detected date menu lost its source category")
	}
	if err := tt.Click("January 3, 2026 · Report Date"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if s.edit.Date != "2026-01-03" || !s.dirty() {
		t.Fatalf("choosing a printed date did not set it: %q", s.edit.Date)
	}
	if !tt.HasText("January 3, 2026 · Report Date") || tt.HasText(s.t("manual_date")) {
		t.Fatal("a detected selection must not be presented as a manual date")
	}
}

func TestSourceHintFollowsTheCurrentText(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Sources = []library.Source{labeledSource("source-a", "Synthetic Hospital")}
	f.report.Review.Organization = "Synthetic Hospital"
	s.accept(f.report)
	tt := ui.NewTester(s.view, 1240, 900)
	if !tt.HasText("Source: original pages 1") {
		t.Fatal("a field found in the recognized text must name its page")
	}
	if err := clickField(tt, "Hospital"); err != nil {
		t.Fatal(err)
	}
	tt.Type(" annex")
	tt.Frame()
	// The original does not say this, so no page is claimed for it.
	if s.edit.Organization != "Synthetic Hospital annex" || tt.HasText("Source: original pages 1") {
		t.Fatal("edited text kept a source it no longer has")
	}

	// With several originals the hint names the original as the picker numbers it.
	f.report.Sources = []library.Source{labeledSource("source-a", "First Hospital"), labeledSource("source-b", "Second Hospital")}
	f.report.Review.SourceIDs = []string{"source-a", "source-b"}
	s.accept(f.report)
	if got := s.sourceHint("organization", "Second Hospital"); got != "Source: original 2 pages 1" {
		t.Fatalf("hint = %q", got)
	}
	s.edit.SourceIDs = []string{"source-b", "source-a"}
	if got := s.sourceHint("organization", "Second Hospital"); got != "Source: original 1 pages 1" {
		t.Fatalf("hint after reordering = %q", got)
	}
	s.language = "zh-Hans"
	if got := s.sourceHint("conclusion", "Synthetic printed conclusion"); got != "来源：原件 1 第 1 页" {
		t.Fatalf("Chinese hint = %q", got)
	}
}

func TestConfirmedDetailNamesSourcePages(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Status = "confirmed"
	f.report.Sources = []library.Source{labeledSource("source-a", "Synthetic Hospital")}
	f.report.Review.Organization, f.report.Review.Conclusion, f.report.Review.ReportType = "Synthetic Hospital", "Synthetic printed conclusion", "Entered by hand"
	s.accept(f.report)
	tt := ui.NewTester(s.view, 1240, 1800)
	hints := 0
	for _, text := range tt.Texts() {
		if text == "Source: original pages 1" {
			hints++
		}
	}
	// The hospital and the conclusion are on the page; the typed report type is not.
	if hints != 2 {
		t.Fatalf("detail shows %d source captions", hints)
	}
	// A confirmed record is not offered a fill until the user starts editing.
	if tt.HasText(s.t("fill_available")) {
		t.Fatal("fill offered outside the edit sheet")
	}
}

// gatedBackend holds each import until the test lets it through.
type gatedBackend struct {
	*fakeBackend
	started, release chan struct{}
}

func (g gatedBackend) Import(ctx context.Context, path string) (library.Report, error) {
	g.started <- struct{}{}
	<-g.release
	return g.fakeBackend.Import(ctx, path)
}

func TestLongImportShowsProgressAndExplainsTheWait(t *testing.T) {
	previous := slowAfter
	slowAfter = 20 * time.Millisecond
	t.Cleanup(func() { slowAfter = previous })
	s, f, _ := testScreen(t)
	s.clearReport()
	gate := gatedBackend{f, make(chan struct{}), make(chan struct{})}
	s.backend = gate
	updates := make(chan func(), 16)
	s.post = func(fn func()) { updates <- fn }
	tt := ui.NewTester(s.view, 1240, 900)
	// pump runs posted updates until the screen reaches the wanted state.
	pump := func(reached func() bool) {
		t.Helper()
		deadline := time.After(3 * time.Second)
		for !reached() {
			select {
			case fn := <-updates:
				fn()
			case <-deadline:
				t.Fatal("screen did not reach the expected state")
			}
		}
		tt.Frame()
	}
	s.importFiles([]string{"/synthetic/a.pdf", "/synthetic/b.pdf"})
	<-gate.started
	pump(func() bool { return s.progressIndex == 1 && s.slow })
	if !tt.HasText(s.t("importing")+s.t("progress_count", 1, 2)) || !tt.HasText(s.t("slow_recognition")) {
		t.Fatal("a long import must name the file it is on and explain the wait")
	}
	if _, ok := tt.Find(s.t("cancel_task")); !ok {
		t.Fatal("a long import must stay cancellable")
	}
	gate.release <- struct{}{}
	<-gate.started
	pump(func() bool { return s.progressIndex == 2 })
	if !tt.HasText(s.t("importing") + s.t("progress_count", 2, 2)) {
		t.Fatal("progress did not advance to the second file")
	}
	gate.release <- struct{}{}
	pump(func() bool { return s.busy == "" })
	if s.slow || s.progressTotal != 0 || tt.HasText(s.t("slow_recognition")) || len(f.imports) != 2 {
		t.Fatal("the explanation or progress outlived the import")
	}
}

func TestDatePickerFollowsTheInterfaceLanguage(t *testing.T) {
	s, f, drain := testScreen(t)
	f.report.Review.Date = "2026-07-10"
	s.accept(f.report)
	tt := ui.NewTester(s.view, 1240, 900)
	var requested string
	s.setLocale = func(locale string) string {
		requested = locale
		if locale == "" {
			locale = "en"
		}
		tt.SetLocale(locale)
		return locale
	}
	s.updateChrome()
	if err := tt.Click("7/10/2026"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if !tt.HasText("July 2026") || !tt.HasText("Mo") {
		t.Fatal("the English calendar lost its wording")
	}
	s.changeLanguage("zh-Hans")
	drain()
	tt.Frame()
	if !tt.HasText("2026年7月") || !tt.HasText("日") || tt.HasText("July 2026") || tt.HasText("Mo") {
		t.Fatal("the calendar did not follow the interface language")
	}
	if err := tt.Click("2026年7月21日"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if s.edit.Date != "2026-07-21" {
		t.Fatalf("choosing a day in the Chinese calendar set %q", s.edit.Date)
	}
	s.changeLanguage("system")
	drain()
	if requested != "" || s.lang() != "en" || s.edit.Date != "2026-07-21" {
		t.Fatal("following the system must clear the locale override without changing the date")
	}
	if err := tt.Click("7/21/2026"); err != nil {
		t.Fatal(err)
	}
	if !tt.HasText("July 2026") || tt.HasText("2026年7月") {
		t.Fatal("returning to the system language did not update the calendar")
	}
}

func TestSourceHintWarnsWhenRecognitionWasUnsure(t *testing.T) {
	s, f, _ := testScreen(t)
	source := labeledSource("source-a", "Synthetic Hospital")
	source.Extraction.Blocks[1].Confidence = 0.3 // the department line
	f.report.Sources = []library.Source{source}
	s.accept(f.report)
	if got := s.sourceHint("organization", "Synthetic Hospital"); got != "Source: original pages 1" {
		t.Fatalf("confident hint = %q", got)
	}
	if got := s.sourceHint("department", "Synthetic Radiology"); got != "Source: original pages 1"+s.t("source_unsure") {
		t.Fatalf("unsure hint = %q", got)
	}
}
