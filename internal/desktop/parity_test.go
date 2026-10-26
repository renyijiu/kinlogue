package desktop

import (
	"context"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
	"kinlogue/internal/document"
	"kinlogue/internal/library"
)

func TestOriginalViewerZoomAndRotationDoNotEditReport(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Status = "confirmed"
	f.report.Sources[0].Extraction.Kind = "png"
	s.accept(f.report)
	s.bitmap = ui.NewBitmap(image.NewRGBA(image.Rect(0, 0, 200, 400)))
	before := cloneEdit(s.edit)
	tt := ui.NewTester(s.view, 1080, 700)
	if err := tt.Click(s.t("view_original")); err != nil {
		t.Fatal(err)
	}
	if s.originalViewer != "report" || !tt.HasText(s.t("export")) {
		t.Fatal("viewer or original export is unavailable")
	}
	// The full tree also contains identically named, disabled inline controls.
	tt = ui.NewTester(s.originalSheet, 1080, 700)
	if err := tt.Click(s.t("zoom_in")); err != nil {
		t.Fatal(err)
	}
	if err := tt.Click(s.t("rotate_right")); err != nil {
		t.Fatal(err)
	}
	if s.viewerZoom <= 1 || s.viewerRotation != 1 || s.originalZoom != 1 || s.originalRotation != 0 || !s.edit.Equal(before) {
		t.Fatal("preview controls did not stay within presentation state")
	}
	if err := tt.Click(s.t("close")); err != nil {
		t.Fatal(err)
	}
	if s.originalViewer != "" || !s.edit.Equal(before) {
		t.Fatal("closing the viewer changed the record")
	}
}

func TestOriginalViewerInitiallyFitsTheWholePage(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Status = "confirmed"
	s.accept(f.report)
	s.bitmap = ui.NewBitmap(image.NewRGBA(image.Rect(0, 0, 200, 1200)))
	s.showReportOriginal()
	tt := ui.NewTester(s.originalSheet, 1080, 700)
	tt.Frame()
	viewport, ok := tt.Find(s.t("original_canvas"))
	if !ok {
		t.Fatal("viewer has no canvas")
	}
	page, ok := tt.Find(s.t("original"))
	if !ok || page.X < viewport.X || page.Y < viewport.Y || page.X+page.W > viewport.X+viewport.W+1 || page.Y+page.H > viewport.Y+viewport.H+1 {
		t.Fatalf("whole-page fit failed: page=%+v canvas=%+v", page, viewport)
	}
}

func TestPreviewControlsUseStoredDocumentKinds(t *testing.T) {
	for _, kind := range []string{"png", "jpeg", "heic", "tiff", "pdf"} {
		for _, phone := range []bool{false, true} {
			for _, viewer := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/phone=%v/viewer=%v", kind, phone, viewer), func(t *testing.T) {
					s, f, _ := testScreen(t)
					f.report.Status = "confirmed"
					f.report.Sources[0].Extraction.Kind = kind
					s.accept(f.report)
					s.phone.preview.Extraction.Kind = kind
					tt := ui.NewTester(func(c *ui.Context) { s.previewControls(c, phone, viewer) }, 800, 100)
					tt.Frame()
					for _, key := range []string{"rotate_left", "rotate_right"} {
						_, found := tt.Find(s.t(key))
						if found != (kind != "pdf") {
							t.Fatalf("%s availability for %s: %v", key, kind, found)
						}
					}
					_, pages := tt.Find(s.t("previous_page"))
					if pages != (kind == "pdf") {
						t.Fatalf("page navigation for %s: %v", kind, pages)
					}
				})
			}
		}
	}
}

func TestChangingOriginalResetsInlineTransform(t *testing.T) {
	s, _, drain := testScreen(t)
	twoSources(s)
	s.originalZoom, s.originalRotation = 2, 1
	s.selectSource("source-b")
	drain()
	if s.originalZoom != 1 || s.originalRotation != 0 {
		t.Fatal("new report original inherited the previous transform")
	}
	p, _, wait := phoneScreen(t)
	p.previewPhone(p.phone.items[0], 1)
	wait()
	p.phoneZoom, p.phoneRotation = 2, 1
	p.previewPhone(p.phone.items[1], 1)
	wait()
	if p.phoneZoom != 1 || p.phoneRotation != 0 {
		t.Fatal("new inbox original inherited the previous transform")
	}
}

func TestEditEscapeCancelsButDoesNotInterruptComposition(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Status = "confirmed"
	s.accept(f.report)
	s.startEditing()
	tt := ui.NewTester(s.view, 1240, 900)
	if err := tt.Click(s.t("title")); err != nil {
		t.Fatal(err)
	}
	tt.Compose("hecheng", 7)
	tt.Key(0, ui.KeyEscape)
	if !s.editingConfirmed {
		t.Fatal("Escape closed the edit while an input method owned it")
	}
	tt.Compose("", 0)
	tt.Frame()
	tt.Type("synthetic change")
	tt.Key(0, ui.KeyEscape)
	if s.editingConfirmed || s.edit.Title != f.report.Review.Title || f.updated {
		t.Fatal("Escape did not cancel the edit without saving")
	}
}

func TestEnterInSingleLineFieldConfirmsButTextAreaKeepsNewlines(t *testing.T) {
	s, f, drain := testScreen(t)
	tt := ui.NewTester(s.view, 1240, 900)
	if err := tt.Click(s.t("transcription")); err != nil {
		t.Fatal(err)
	}
	tt.Key(0, ui.KeyEnter)
	if f.confirmed || s.busy != "" {
		t.Fatal("Enter in a multiline field submitted the review")
	}
	if err := tt.Click(s.t("title")); err != nil {
		t.Fatal(err)
	}
	tt.Key(0, ui.KeyEnter)
	drain()
	if !f.confirmed {
		t.Fatal("Enter in a single-line field did not invoke the default action")
	}
}

type paritySearchRequest struct {
	query  string
	result chan []library.Report
}
type paritySearchBackend struct {
	*fakeBackend
	requests chan paritySearchRequest
}

func (b *paritySearchBackend) Search(_ context.Context, _, query string) ([]library.Report, error) {
	request := paritySearchRequest{query, make(chan []library.Report, 1)}
	b.requests <- request
	return <-request.result, nil
}

func TestLiveSearchIgnoresLateResultsAndMemberChanges(t *testing.T) {
	s, f, _ := testScreen(t)
	s.clearReport()
	b := &paritySearchBackend{f, make(chan paritySearchRequest, 2)}
	s.backend = b
	updates := make(chan func(), 2)
	s.post = func(fn func()) { updates <- fn }
	s.query = "first"
	s.searchRecords()
	first := <-b.requests
	s.query = "second"
	s.searchRecords()
	second := <-b.requests
	second.result <- []library.Report{{ID: "new"}}
	(<-updates)()
	first.result <- []library.Report{{ID: "old"}}
	(<-updates)()
	if len(s.records) != 1 || s.records[0].ID != "new" || s.searchBusy {
		t.Fatal("late search replaced the newest result")
	}
	s.query = "third"
	s.searchRecords()
	third := <-b.requests
	s.cancelSearch()
	s.memberID = "different-member"
	s.records = nil
	third.result <- []library.Report{{ID: "wrong-member"}}
	(<-updates)()
	if len(s.records) != 0 || s.searchBusy {
		t.Fatal("search result crossed member navigation")
	}
}

func TestOriginalViewerBlocksNativeNavigationAndSearch(t *testing.T) {
	s, _, _ := testScreen(t)
	s.clearReport()
	s.originalViewer = "report"
	navigated := false
	s.queueNavigation(func() { navigated = true })
	s.consumeRequests()
	s.requestSearchFocus()
	if navigated || s.focusSearch {
		t.Fatal("native commands escaped the original viewer")
	}
}

func TestSearchUpdatesWithoutReturnAndWaitsForComposition(t *testing.T) {
	s, f, _ := testScreen(t)
	s.clearReport()
	b := &paritySearchBackend{f, make(chan paritySearchRequest, 4)}
	s.backend = b
	updates := make(chan func(), 4)
	s.post = func(fn func()) { updates <- fn }
	tt := ui.NewTester(s.view, 1240, 900)
	if err := tt.Click(s.t("search")); err != nil {
		t.Fatal(err)
	}
	finish := func(query string) {
		t.Helper()
		select {
		case request := <-b.requests:
			if request.query != query {
				t.Fatalf("query %q, want %q", request.query, query)
			}
			request.result <- []library.Report{{ID: "match", Review: library.Edit{Title: "Synthetic matching report"}}}
		case <-time.After(3 * time.Second):
			t.Fatal("typing did not start live search")
		}
		select {
		case update := <-updates:
			update()
		case <-time.After(3 * time.Second):
			t.Fatal("search did not finish")
		}
		tt.Frame()
		if !tt.HasText("Synthetic matching report") {
			t.Fatal("search result was not rendered")
		}
	}
	tt.Type("synthetic")
	finish("synthetic")
	tt.Compose("ni", 2)
	if s.searchBusy {
		t.Fatal("unfinished composition started a search")
	}
	tt.Type("你")
	finish("synthetic你")
}

func TestResizedSplitPanesKeepDetailActionsReachable(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Status = "confirmed"
	f.report.Review.Date = "2026-10-26"
	s.accept(f.report)
	tt := ui.NewTester(s.view, 1440, 900)
	drag := func(x, y, toX, toY float32) {
		tt.Press(x, y)
		tt.Move(toX, toY)
		tt.Release(toX, toY)
		tt.Frame()
	}
	drag(s.sidebarSize, 450, 340, 450)
	if s.sidebarSize <= sidebarWidth {
		t.Fatal("sidebar divider did not move")
	}
	drag(s.sidebarSize+1+s.timelineSize, 450, 950, 450)
	if s.timelineSize <= timelineWidth {
		t.Fatal("timeline divider did not move")
	}
	drag(1100, 53+s.summaryHeight, 1100, 650)
	if s.summaryHeight <= 280 {
		t.Fatal("summary divider did not move")
	}
	tt.SetSize(1080, 700)
	tt.Frame()
	for _, key := range []string{"edit_record", "delete_report", "view_original"} {
		r, ok := tt.Find(s.t(key))
		if !ok || r.X < 0 || r.Y < 0 || r.X+r.W > 1080 || r.Y+r.H > 700 {
			t.Fatalf("action clipped after resize: %s %+v", key, r)
		}
	}
	r, ok := tt.Find(s.t("original_pane"))
	if !ok || r.H < 250 || r.Y+r.H > 700 {
		t.Fatalf("original pane clipped after resize: %+v", r)
	}
}

func TestInlineOriginalUsesSwiftZoomStepsAndLimits(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Status = "confirmed"
	s.accept(f.report)
	tt := ui.NewTester(s.view, 1240, 900)
	if err := tt.Click(s.t("zoom_in")); err != nil {
		t.Fatal(err)
	}
	if s.originalZoom < 1.19 || s.originalZoom > 1.21 {
		t.Fatalf("zoom step is not 20%%: %v", s.originalZoom)
	}
	for range 12 {
		_ = tt.Click(s.t("zoom_in"))
	}
	if s.originalZoom != 2.4 {
		t.Fatalf("inline maximum: %v", s.originalZoom)
	}
	for range 12 {
		_ = tt.Click(s.t("zoom_out"))
	}
	if s.originalZoom != .6 {
		t.Fatalf("inline minimum: %v", s.originalZoom)
	}
}

func TestCancelAndReopenRestoresSavedDateSelection(t *testing.T) {
	for _, saved := range []string{"", "2026-10-26"} {
		t.Run(saved, func(t *testing.T) {
			s, f, _ := testScreen(t)
			f.report.Status, f.report.Review.Date = "confirmed", saved
			s.accept(f.report)
			s.startEditing()
			tt := ui.NewTester(s.view, 1240, 900)
			from, to := "unknown_date", "date_manual"
			if saved != "" {
				from, to = to, from
			}
			if err := tt.Click(s.t(from)); err != nil {
				t.Fatal(err)
			}
			if err := tt.Click(s.t(to)); err != nil {
				t.Fatal(err)
			}
			if err := tt.Click(s.t("cancel_edit")); err != nil {
				t.Fatal(err)
			}
			s.startEditing()
			tt.Frame()
			want := ""
			if saved != "" {
				want = "manual"
			}
			if s.edit.Date != saved || s.dateMode != want || (saved != "" && !tt.HasText(s.t("manual_date"))) {
				t.Fatalf("saved date and menu disagree: %q %q", s.edit.Date, s.dateMode)
			}
		})
	}
}

func TestOpeningRecordKeepsPendingSearchResult(t *testing.T) {
	s, f, _ := testScreen(t)
	s.clearReport()
	f.report.Status = "confirmed"
	b := &paritySearchBackend{f, make(chan paritySearchRequest, 1)}
	s.backend = b
	updates := make(chan func(), 8)
	s.post = func(fn func()) { updates <- fn }
	s.query = "matching"
	s.searchRecords()
	request := <-b.requests
	s.open(f.report.ID)
	s.consumeRequests()
	deadline := time.After(3 * time.Second)
	for s.busy != "" || s.previewBusy {
		select {
		case update := <-updates:
			update()
		case <-deadline:
			t.Fatal("opening did not finish")
		}
	}
	request.result <- []library.Report{{ID: "matching-result"}}
	select {
	case update := <-updates:
		update()
	case <-deadline:
		t.Fatal("search did not finish")
	}
	if s.report.ID != f.report.ID || len(s.records) != 1 || s.records[0].ID != "matching-result" {
		t.Fatal("opening a record discarded the current query's result")
	}
}

func TestRotatedOriginalRemainsReachableAtZoomLimits(t *testing.T) {
	s, _, _ := testScreen(t)
	page := image.NewRGBA(image.Rect(0, 0, 120, 240))
	red, green, blue, yellow := color.RGBA{255, 0, 0, 255}, color.RGBA{0, 255, 0, 255}, color.RGBA{0, 0, 255, 255}, color.RGBA{255, 255, 0, 255}
	for i, ink := range []color.RGBA{red, green, blue, yellow} {
		x, y := (i%2)*60, (i/2)*120
		draw.Draw(page, image.Rect(x, y, x+60, y+120), &image.Uniform{ink}, image.Point{}, draw.Src)
	}
	bitmap := ui.NewBitmap(page)
	zoom := float32(.6)
	tt := ui.NewTester(func(c *ui.Context) {
		c.SetTheme(warmTheme())
		ui.Column(c).Fill().Children(func() { s.previewCanvas(c, bitmap, zoom, 1, "", false) })
	}, 400, 300)
	tt.Frame()
	check := func(x, y int, want color.RGBA) {
		t.Helper()
		if got := tt.Image().RGBAAt(x, y); got != want {
			t.Fatalf("rotated page pixel (%d,%d): got %+v want %+v", x, y, got, want)
		}
	}
	check(30, 30, blue)
	check(200, 30, red)
	check(30, 100, yellow)
	check(200, 100, green)
	zoom = 2.4
	tt.Frame()
	check(30, 30, blue)
	tt.Scroll(200, 150, 10000, 10000)
	check(350, 250, green)
}

func TestPhoneAdditiveRangeAndOversizedRangeKeepFrozenSelection(t *testing.T) {
	s, f, _ := phoneScreen(t)
	s.phone.items = nil
	for i := range document.MaxSources + 1 {
		s.phone.items = append(s.phone.items, library.InboxItem{ID: fmt.Sprintf("synthetic-%d", i), Status: "reviewable", Revision: int64(i + 1)})
	}
	f.items = s.phone.items
	s.selectPhoneItem(s.phone.items[0], 0)
	s.selectPhoneItem(s.phone.items[2], ui.Cmd)
	s.selectPhoneItem(s.phone.items[3], ui.Cmd|ui.Shift)
	if len(s.phone.selected) != 3 {
		t.Fatal("additive range discarded existing selections")
	}
	for i, index := range []int{0, 2, 3} {
		want := library.InboxSelection{ID: s.phone.items[index].ID, Revision: s.phone.items[index].Revision}
		if s.phone.selected[i] != want {
			t.Fatal("additive range changed order or frozen revisions")
		}
	}
	s.phone.selectionAnchor = s.phone.items[0].ID
	before := append([]library.InboxSelection(nil), s.phone.selected...)
	s.selectPhoneItem(s.phone.items[document.MaxSources], ui.Cmd|ui.Shift)
	if s.message != "sources_limit" || len(s.phone.selected) != len(before) {
		t.Fatal("oversized range replaced the previous selection")
	}
	for i := range before {
		if s.phone.selected[i] != before[i] {
			t.Fatal("oversized range changed a frozen selection")
		}
	}
}
