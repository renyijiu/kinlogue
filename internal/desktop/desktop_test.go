package desktop

import (
	"context"
	"errors"
	"fmt"
	"image"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
	"kinlogue/internal/document"
	"kinlogue/internal/library"
)

type fakeBackend struct {
	report         library.Report
	saved          library.Edit
	confirmed      bool
	saveError      error
	language       string
	updated        bool
	imports        []string
	grouped        []string
	deleted        string
	cleanupPending bool
	exported       [2]string
	added          string
}

func (f *fakeBackend) Members(context.Context) ([]library.Member, error) {
	return []library.Member{{ID: "member-a", Name: "Synthetic A"}}, nil
}
func (f *fakeBackend) AddMember(_ context.Context, name string) (library.Member, error) {
	f.added = name
	return library.Member{}, nil
}
func (f *fakeBackend) Drafts(context.Context) ([]library.Report, error) {
	return []library.Report{f.report}, nil
}
func (f *fakeBackend) Search(context.Context, string, string) ([]library.Report, error) {
	return nil, nil
}
func (f *fakeBackend) Get(context.Context, string) (library.Report, error) { return f.report, nil }
func (f *fakeBackend) Import(_ context.Context, path string) (library.Report, error) {
	f.imports = append(f.imports, path)
	return f.report, nil
}
func (f *fakeBackend) ImportMany(_ context.Context, paths []string) (library.Report, error) {
	f.grouped = append([]string(nil), paths...)
	return f.report, nil
}
func (f *fakeBackend) Retry(context.Context, string) (library.Report, error) { return f.report, nil }
func (f *fakeBackend) SaveReview(_ context.Context, _ string, e library.Edit) (library.Report, error) {
	if f.saveError != nil {
		return library.Report{}, f.saveError
	}
	f.saved = e
	f.report.Review = e
	return f.report, nil
}
func (f *fakeBackend) Confirm(ctx context.Context, id string, e library.Edit) (library.Report, error) {
	f.confirmed = true
	r, err := f.SaveReview(ctx, id, e)
	r.Status = "confirmed"
	return r, err
}
func (f *fakeBackend) UpdateConfirmed(ctx context.Context, id string, e library.Edit) (library.Report, error) {
	f.updated = true
	return f.SaveReview(ctx, id, e)
}
func (f *fakeBackend) Preview(context.Context, string, string, int) (image.Image, error) {
	return image.NewRGBA(image.Rect(0, 0, 12, 12)), nil
}
func (f *fakeBackend) DeleteReport(_ context.Context, id string) (library.DeleteResult, error) {
	f.deleted = id
	return library.DeleteResult{CleanupPending: f.cleanupPending}, nil
}
func (f *fakeBackend) ExportOriginals(_ context.Context, id, destination string) error {
	f.exported = [2]string{id, destination}
	return nil
}
func (f *fakeBackend) Language(context.Context) (string, error) { return f.language, nil }
func (f *fakeBackend) SetLanguage(_ context.Context, lang string) error {
	f.language = lang
	return nil
}

func testScreen(t *testing.T) (*screen, *fakeBackend, func()) {
	t.Helper()
	f := &fakeBackend{report: library.Report{ID: "report-a", Status: "review", FileName: "synthetic.pdf", Review: library.Edit{MemberID: "member-a", Title: "Synthetic report", Text: "Uncorrected text", SourceIDs: []string{"source-a"}}, Sources: []library.Source{{ID: "source-a", FileName: "synthetic.pdf", Extraction: document.Extraction{PageCount: 1}}}}}
	s := newScreen(f, "en")
	s.members, _ = f.Members(context.Background())
	s.accept(f.report)
	updates := make(chan func(), 16)
	s.post = func(fn func()) { updates <- fn }
	drain := func() {
		t.Helper()
		deadline := time.After(3 * time.Second)
		for s.busy != "" || s.previewBusy {
			select {
			case fn := <-updates:
				fn()
			case <-deadline:
				t.Fatal("UI work did not finish")
			}
		}
	}
	t.Cleanup(s.stop)
	return s, f, drain
}

func TestReviewEditingAndExplicitConfirmation(t *testing.T) {
	s, f, drain := testScreen(t)
	tt := ui.NewTester(s.view, 1240, 900)
	if err := tt.Click("Corrected transcription"); err != nil {
		t.Fatal(err)
	}
	tt.Key(ui.Cmd, ui.KeyA)
	tt.Type("Synthetic corrected text")
	if !s.dirty() {
		t.Fatal("editing did not mark the draft dirty")
	}
	if err := tt.Click("Save for later"); err != nil {
		t.Fatal(err)
	}
	drain()
	if f.saved.Text != "Synthetic corrected text" || f.confirmed || s.dirty() {
		t.Fatal("save did not preserve an unconfirmed correction")
	}
	tt.Frame()
	if err := tt.Click("Confirm record"); err != nil {
		t.Fatal(err)
	}
	drain()
	if !f.confirmed || s.report.Status != "confirmed" {
		t.Fatal("explicit confirmation was not submitted")
	}
}

func TestDirtyNavigationSaveFailureKeepsEditsAndCancelStays(t *testing.T) {
	s, f, drain := testScreen(t)
	s.edit.Text = "Unsaved synthetic correction"
	moved := false
	s.leave(func() { moved = true })
	tt := ui.NewTester(s.view, 1240, 900)
	if !tt.HasText("Unsaved changes") || moved {
		t.Fatal("navigation did not wait for a choice")
	}
	if err := tt.Click("Cancel"); err != nil {
		t.Fatal(err)
	}
	if moved || s.pending != nil || !s.dirty() {
		t.Fatal("cancel discarded edits or navigated")
	}
	s.leave(func() { moved = true })
	f.saveError = errors.New("synthetic_failure")
	tt.Frame()
	if err := tt.Click("Save and continue"); err != nil {
		t.Fatal(err)
	}
	drain()
	if moved || s.edit.Text != "Unsaved synthetic correction" || !s.dirty() {
		t.Fatal("failed save lost the editing session")
	}
	tt.Frame()
	if err := tt.Click("Discard changes"); err != nil {
		t.Fatal(err)
	}
	if !moved {
		t.Fatal("explicit discard did not navigate")
	}
}

func TestLanguageSwitchTranslatesExistingErrorWithoutChangingContent(t *testing.T) {
	s, _, drain := testScreen(t)
	s.message = "save_failed"
	before := s.edit
	s.changeLanguage("zh-Hans")
	drain()
	tt := ui.NewTester(s.view, 1240, 900)
	if !tt.HasText("保存失败") || !s.edit.Equal(before) {
		t.Fatal("language did not update the existing error independently of content")
	}
	for key, translations := range stringsTable {
		if translations[0] == "" || translations[1] == "" {
			t.Errorf("missing language for %s", key)
		}
	}
}

func TestConfirmDisabledUntilMemberChosenAndRecognitionComplete(t *testing.T) {
	s, f, _ := testScreen(t)
	s.edit.MemberID = ""
	tt := ui.NewTester(s.view, 1240, 900)
	_ = tt.Click("Confirm record")
	if f.confirmed || s.busy != "" {
		t.Fatal("confirmation ran without member")
	}
	s.edit.MemberID = "member-a"
	s.report.Status = "processing"
	tt.Frame()
	_ = tt.Click("Confirm record")
	if f.confirmed || s.busy != "" {
		t.Fatal("confirmation ran while processing")
	}
}

type delayedPreview struct {
	*fakeBackend
	started chan int
	release chan struct{}
}

func (f *delayedPreview) Preview(_ context.Context, _ string, _ string, page int) (image.Image, error) {
	f.started <- page
	if page == 1 {
		<-f.release
	} // Simulate a native call that ignores cancellation.
	return image.NewRGBA(image.Rect(0, 0, page*12, page*12)), nil
}

func TestLatePreviewCannotReplaceNewPageOrEditedContent(t *testing.T) {
	s, f, _ := testScreen(t)
	delayed := &delayedPreview{fakeBackend: f, started: make(chan int, 2), release: make(chan struct{})}
	s.backend = delayed
	s.report.Sources[0].Extraction.PageCount = 2
	s.edit.Text = "Synthetic unsaved correction"
	updates := make(chan func(), 4)
	s.post = func(fn func()) { updates <- fn }
	s.preview(1)
	select {
	case <-delayed.started:
	case <-time.After(time.Second):
		t.Fatal("preview did not start")
	}
	s.preview(2)
	close(delayed.release)
	deadline := time.After(3 * time.Second)
	for s.previewBusy {
		select {
		case fn := <-updates:
			fn()
		case <-deadline:
			t.Fatal("latest preview did not finish")
		}
	}
	if s.page != 2 || s.bitmap == nil || s.edit.Text != "Synthetic unsaved correction" {
		t.Fatal("preview overwrote page or edit selection")
	}
	if width, _ := s.bitmap.Size(); width != 24 {
		t.Fatal("late previous page replaced the current page")
	}
	for len(updates) > 0 {
		(<-updates)()
	}
	if width, _ := s.bitmap.Size(); width != 24 {
		t.Fatal("queued stale preview replaced current page")
	}
}

func TestInitialRecognitionStaysReadableAfterCorrectionAndConfirmation(t *testing.T) {
	s, _, _ := testScreen(t)
	s.report.Status = "confirmed"
	s.report.Sources[0].Extraction.Blocks = []document.Block{{Page: 1, Text: "Synthetic initial OCR"}}
	s.edit.Text = "Synthetic corrected transcription"
	tt := ui.NewTester(s.view, 1240, 900)
	if err := tt.Click("Show initial recognition"); err != nil {
		t.Fatal(err)
	}
	if err := tt.Click("Source page 1"); err != nil {
		t.Fatal(err)
	}
	tt.Key(ui.Cmd, ui.KeyA)
	tt.Key(ui.Cmd, ui.KeyC)
	if tt.Clipboard() != "Synthetic initial OCR" {
		t.Fatal("initial recognition cannot be read independently of correction")
	}
	before := s.edit.Text
	_ = tt.Click("Corrected transcription")
	tt.Key(ui.Cmd, ui.KeyA)
	tt.Key(ui.Cmd, ui.KeyC)
	if tt.Clipboard() != before {
		t.Fatal("confirmed correction is not readable")
	}
	tt.Type("Should not replace confirmed text")
	if s.edit.Text != before {
		t.Fatal("confirmed transcription was editable")
	}
}

func TestInitialRecognitionFollowsPageAndReopenedReport(t *testing.T) {
	s, f, drain := testScreen(t)
	r := f.report
	r.Sources[0].Extraction.PageCount = 2
	r.Sources[0].Extraction.Blocks = []document.Block{
		{Page: 1, Text: "Synthetic first line"},
		{Page: 2, Text: "Synthetic second page"},
		{Page: 1, Text: "Synthetic last line"},
	}
	s.accept(r)
	tt := ui.NewTester(s.view, 1240, 900)
	readPage := func(label, want string) {
		t.Helper()
		if !s.showRaw {
			if err := tt.Click("Show initial recognition"); err != nil {
				t.Fatal(err)
			}
		}
		if err := tt.Click(label); err != nil {
			t.Fatal(err)
		}
		tt.Key(ui.Cmd, ui.KeyA)
		tt.Key(ui.Cmd, ui.KeyC)
		if tt.Clipboard() != want {
			t.Fatal("source text does not match the selected report page")
		}
	}
	readPage("Source page 1", "Synthetic first line\nSynthetic last line")
	s.preview(2)
	drain()
	tt.Frame()
	readPage("Source page 2", "Synthetic second page")
	s.clearReport()
	r.Sources[0].Extraction.Blocks = []document.Block{{Page: 1, Text: "Synthetic reopened source"}}
	s.accept(r)
	tt.Frame()
	readPage("Source page 1", "Synthetic reopened source")
}

func BenchmarkInitialRecognitionText(b *testing.B) {
	s := newScreen(nil, "en")
	defer s.stop()
	s.report.Sources = []library.Source{{ID: "source-a"}}
	s.sourceID = "source-a"
	for range document.MaxTextBytes / document.MaxBlockBytes {
		s.report.Sources[0].Extraction.Blocks = append(s.report.Sources[0].Extraction.Blocks, document.Block{Page: 1, Text: strings.Repeat("a", document.MaxBlockBytes)})
	}
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		if len(s.initialText()) != document.MaxTextBytes+len(s.report.Sources[0].Extraction.Blocks)-1 {
			b.Fatal("source text was truncated")
		}
	}
}

type reloadFailure struct{ *fakeBackend }

func (f reloadFailure) Members(context.Context) ([]library.Member, error) {
	return nil, errors.New("synthetic_reload_failure")
}

func TestSuccessfulSaveRemainsSavedWhenListRefreshFails(t *testing.T) {
	s, f, drain := testScreen(t)
	s.backend = reloadFailure{f}
	s.edit.Text = "Synthetic saved correction"
	s.save(false, nil)
	drain()
	if s.dirty() || s.report.Review.Text != f.saved.Text || len(s.members) != 1 || s.message != "load_failed" {
		t.Fatal("reload failure undid a successful save or erased unrelated data")
	}
}

func TestRepeatedFramesDoNotStartBackgroundWork(t *testing.T) {
	s, f, _ := testScreen(t)
	s.backend = &delayedPreview{fakeBackend: f, started: make(chan int, 1), release: make(chan struct{})}
	tt := ui.NewTester(s.view, 1240, 900)
	for range 20 {
		tt.Frame()
	}
	if s.busy != "" || s.previewBusy {
		t.Fatal("rendering started background work")
	}
}

type shutdownImportBackend struct {
	*fakeBackend
	started   chan struct{}
	cancelled chan struct{}
	release   chan struct{}
	imports   atomic.Int32
	previews  atomic.Int32
}

func (f *shutdownImportBackend) Import(ctx context.Context, _ string) (library.Report, error) {
	f.imports.Add(1)
	close(f.started)
	<-ctx.Done()
	close(f.cancelled)
	<-f.release // Service still has failure persistence / native cleanup to finish.
	report := f.report
	report.Status, report.Failure = "failed", "cancelled"
	return report, ctx.Err()
}

func (f *shutdownImportBackend) Preview(ctx context.Context, id, sourceID string, page int) (image.Image, error) {
	f.previews.Add(1)
	return f.fakeBackend.Preview(ctx, id, sourceID, page)
}

func TestShutdownDuringFirstBatchImportCancelsAndWaitsForCleanup(t *testing.T) {
	s, f, drain := testScreen(t)
	backend := &shutdownImportBackend{fakeBackend: f, started: make(chan struct{}), cancelled: make(chan struct{}), release: make(chan struct{})}
	s.backend = backend
	released := false
	defer func() {
		if !released {
			close(backend.release)
		}
	}()
	s.importFiles([]string{"synthetic-first.pdf", "synthetic-second.pdf"})
	select {
	case <-backend.started:
	case <-time.After(time.Second):
		t.Fatal("import did not start")
	}
	exited := false
	// This is the shared handler used by window close and Cmd-Q.
	s.requestShutdown(func() { exited = true })
	if exited || !s.cancelling {
		t.Fatal("close must cancel the active import and wait, not forget the request")
	}
	select {
	case <-backend.cancelled:
	case <-time.After(time.Second):
		t.Fatal("import context was not cancelled")
	}
	if exited {
		t.Fatal("closed before import cleanup finished")
	}
	close(backend.release)
	released = true
	drain()
	if !exited || backend.imports.Load() != 1 {
		t.Fatal("shutdown did not resume or started a later batch item")
	}
	if backend.previews.Load() != 0 {
		t.Fatal("shutdown started a new preview after cancelled import")
	}
}

type shutdownSaveBackend struct {
	*fakeBackend
	started chan context.Context
	release chan struct{}
}

func (f *shutdownSaveBackend) SaveReview(ctx context.Context, id string, edit library.Edit) (library.Report, error) {
	f.started <- ctx
	<-f.release
	return f.fakeBackend.SaveReview(ctx, id, edit)
}

func TestShutdownDuringSaveWaitsWithoutCancellingWrite(t *testing.T) {
	s, f, drain := testScreen(t)
	backend := &shutdownSaveBackend{fakeBackend: f, started: make(chan context.Context, 1), release: make(chan struct{})}
	s.backend = backend
	s.edit.Text = "Synthetic correction to save"
	s.save(false, nil)
	ctx := <-backend.started
	exited := false
	s.requestShutdown(func() { exited = true })
	if ctx.Err() != nil || exited {
		t.Fatal("close cancelled an in-flight save or closed before it finished")
	}
	close(backend.release)
	drain()
	if !exited || s.dirty() || f.saved.Text != "Synthetic correction to save" {
		t.Fatal("close request did not resume after successful save")
	}
}

func TestShutdownAfterFailedSavePreservesEditsAndCancelStaysOpen(t *testing.T) {
	s, f, drain := testScreen(t)
	f.saveError = errors.New("synthetic_save_failure")
	backend := &shutdownSaveBackend{fakeBackend: f, started: make(chan context.Context, 1), release: make(chan struct{})}
	s.backend = backend
	s.edit.Text = "Synthetic unsaved correction"
	s.save(false, nil)
	<-backend.started
	exited := false
	s.requestShutdown(func() { exited = true })
	close(backend.release)
	drain()
	if exited || s.pending == nil || !s.dirty() || s.edit.Text != "Synthetic unsaved correction" {
		t.Fatal("failed save lost edits or did not resume the dirty close guard")
	}
	tt := ui.NewTester(s.view, 1240, 900)
	if err := tt.Click("Cancel"); err != nil {
		t.Fatal(err)
	}
	if exited || s.pending != nil || !s.dirty() {
		t.Fatal("cancel did not preserve the editing session")
	}
	s.changeLanguage("zh-Hans")
	drain()
	if exited || s.language != "zh-Hans" {
		t.Fatal("cancel left a hidden shutdown request behind")
	}
}

func TestLargeTimelineBuildsVisibleRowsAndCanReachLastRecord(t *testing.T) {
	s, f, drain := testScreen(t)
	s.clearReport()
	s.memberID = "member-a"
	for i := range 10_000 {
		s.records = append(s.records, library.Report{ID: fmt.Sprintf("report-%d", i), Status: "confirmed", Review: library.Edit{Title: fmt.Sprintf("Synthetic report %05d", i)}})
	}
	tt := ui.NewTester(s.view, 1240, 900)
	if !tt.HasText("Synthetic report 00000") || tt.HasText("Synthetic report 09999") || len(tt.Texts()) > 300 {
		t.Fatal("timeline eagerly constructed off-screen rows")
	}
	// Scroll through the container rather than loading another API page.
	for range 8 {
		tt.Scroll(1000, 500, 0, 200_000)
	}
	if !tt.HasText("Synthetic report 09999") {
		t.Fatal("virtualized timeline cannot reach the last record")
	}
	f.report.ID, f.report.Status = "report-9999", "confirmed"
	if err := tt.Click("Synthetic report 09999"); err != nil {
		t.Fatal(err)
	}
	drain()
	if s.report.ID != "report-9999" {
		t.Fatal("last visible row did not load its full report")
	}
}

func TestCancellingShutdownRestartsInterruptedPreview(t *testing.T) {
	s, f, _ := testScreen(t)
	backend := &delayedPreview{fakeBackend: f, started: make(chan int, 2), release: make(chan struct{})}
	s.backend = backend
	updates := make(chan func(), 4)
	s.post = func(fn func()) { updates <- fn }
	s.edit.Text = "Synthetic unsaved correction"
	s.preview(1)
	<-backend.started
	exited := false
	s.requestShutdown(func() { exited = true })
	tt := ui.NewTester(s.view, 1240, 900)
	if err := tt.Click("Cancel"); err != nil {
		t.Fatal(err)
	}
	close(backend.release)
	deadline := time.After(3 * time.Second)
	for s.previewBusy || len(updates) > 0 {
		select {
		case fn := <-updates:
			fn()
		case <-deadline:
			t.Fatal("preview did not resume")
		}
	}
	if exited || s.bitmap == nil || s.edit.Text != "Synthetic unsaved correction" {
		t.Fatal("cancel left the preview interrupted or lost edits")
	}
}

func BenchmarkTimelineVisibleRows(b *testing.B) {
	for _, count := range []int{100, 10_000} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			s := newScreen(nil, "en")
			defer s.stop()
			s.memberID = "member-a"
			for i := range count {
				s.records = append(s.records, library.Report{ID: fmt.Sprint(i), Status: "confirmed", Review: library.Edit{Title: fmt.Sprintf("Synthetic report %05d", i)}})
			}
			tt := ui.NewTester(s.view, 1240, 900)
			b.ReportAllocs()
			b.ResetTimer()
			for b.Loop() {
				tt.Frame()
			}
		})
	}
}
