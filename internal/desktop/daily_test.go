package desktop

import (
	"context"
	"errors"
	"fmt"
	"image"
	"slices"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
	"kinlogue/internal/document"
	"kinlogue/internal/library"
)

func twoSources(s *screen) {
	s.report.Sources = append(s.report.Sources, library.Source{ID: "source-b", FileName: "synthetic-second.png", Extraction: document.Extraction{PageCount: 1, Blocks: []document.Block{{Page: 1, Text: "Synthetic source B"}}}})
	s.report.Sources[0].Extraction.Blocks = []document.Block{{Page: 1, Text: "Synthetic source A"}}
	s.report.Review.SourceIDs = []string{"source-a", "source-b"}
	s.accept(s.report)
}

func TestConfirmedEditingIsExplicitAndUpdatesInsteadOfReconfirming(t *testing.T) {
	s, f, drain := testScreen(t)
	f.report.Status = "confirmed"
	s.accept(f.report)
	tt := ui.NewTester(s.view, 1240, 1000)
	if err := tt.Click("Edit"); err != nil {
		t.Fatal(err)
	}
	if err := tt.Click("Report Title"); err != nil {
		t.Fatal(err)
	}
	tt.Key(ui.Cmd, ui.KeyA)
	tt.Type("Synthetic corrected title")
	if !s.dirty() || f.report.Review.Title != "Synthetic report" {
		t.Fatal("unpublished edits must leave confirmed backend unchanged")
	}
	tt.Key(ui.Cmd, ui.KeyS)
	drain()
	if !f.updated || f.confirmed || s.editingConfirmed || s.dirty() || f.saved.Title != "Synthetic corrected title" {
		t.Fatal("save did not atomically update the confirmed record and return to read-only")
	}
}

func TestConfirmedCancelAndFailedSavePreserveCorrectBaseline(t *testing.T) {
	s, f, drain := testScreen(t)
	f.report.Status = "confirmed"
	s.accept(f.report)
	tt := ui.NewTester(s.view, 1240, 1000)
	if err := tt.Click("Edit"); err != nil {
		t.Fatal(err)
	}
	s.edit.Notes = "Synthetic unsaved note"
	f.saveError = errors.New("synthetic_save_failure")
	s.save(false, nil)
	drain()
	tt.Frame()
	if !s.editingConfirmed || s.edit.Notes != "Synthetic unsaved note" || !tt.HasText("Could not save. Your edits are still on this page.") {
		t.Fatal("save failure lost confirmed edit session or hid the error")
	}
	// Like the Swift edit sheet, Cancel is an explicit choice to discard.
	if err := tt.Click("Cancel"); err != nil {
		t.Fatal(err)
	}
	if s.editingConfirmed || s.dirty() || s.edit.Notes != "" || f.report.Review.Notes != "" || s.pending != nil {
		t.Fatal("cancel did not restore the saved baseline")
	}
}

func TestSourceReorderIsDirtyWithoutMutatingOriginalsOrText(t *testing.T) {
	s, _, _ := testScreen(t)
	twoSources(s)
	tt := ui.NewTester(s.view, 1240, 1000)
	before := s.edit.Text
	if err := tt.Click("Move original down"); err != nil {
		t.Fatal(err)
	}
	if !s.dirty() || !slices.Equal(s.edit.SourceIDs, []string{"source-b", "source-a"}) || !slices.Equal(s.report.Review.SourceIDs, []string{"source-a", "source-b"}) {
		t.Fatal("reorder did not isolate the edit from the saved order")
	}
	if s.sourceID != "source-a" || s.initialText() != "Synthetic source A" || s.edit.Text != before {
		t.Fatal("reorder changed source identity or transcription")
	}
}

func TestMultipleFilesRequireExplicitGroupingAndKeepChosenOrder(t *testing.T) {
	s, f, drain := testScreen(t)
	s.importPaths = []string{"synthetic-first.png", "synthetic-second.png"}
	tt := ui.NewTester(s.view, 1240, 1000)
	if !tt.HasText("Import separately") || !tt.HasText("Combine into one report") || len(f.imports) != 0 || len(f.grouped) != 0 {
		t.Fatal("multiple files did not wait for an explicit choice")
	}
	if err := tt.Click("Move file 1 down"); err != nil {
		t.Fatal(err)
	}
	if err := tt.Click("Combine into one report"); err != nil {
		t.Fatal(err)
	}
	drain()
	if !slices.Equal(f.grouped, []string{"synthetic-second.png", "synthetic-first.png"}) || len(f.imports) != 0 || len(s.importPaths) != 0 {
		t.Fatal("grouped import did not use the user-selected order exactly once")
	}
}

func TestGroupingLimitAndCancelDoNotStartImport(t *testing.T) {
	s, f, _ := testScreen(t)
	s.importPaths = make([]string, document.MaxSources+1)
	tt := ui.NewTester(s.view, 1240, 1000)
	_ = tt.Click("Combine into one report")
	if s.busy != "" || len(f.grouped) != 0 {
		t.Fatal("over-limit group was submitted")
	}
	if err := tt.Click("Cancel"); err != nil {
		t.Fatal(err)
	}
	if len(s.importPaths) != 0 || len(f.imports) != 0 {
		t.Fatal("cancel did not clear selection without importing")
	}
}

func TestCommittedDeletionClearsConfirmedDetailAndReportsPendingCleanup(t *testing.T) {
	s, f, drain := testScreen(t)
	s.report.Status = "confirmed"
	s.records = []library.Report{s.report}
	f.cleanupPending = true
	s.deletePrompt = true
	tt := ui.NewTester(s.view, 1240, 1000)
	if !tt.HasText("The record and originals it no longer shares will no longer be viewable in Kinlogue. Source files you originally selected and exported copies are not deleted.") {
		t.Fatal("delete scope is inaccurate")
	}
	if err := tt.Click("Delete from Kinlogue"); err != nil {
		t.Fatal(err)
	}
	drain()
	if s.report.ID != "" || s.deletePrompt || f.deleted != "report-a" || s.message != "cleanup_pending" {
		t.Fatal("committed deletion retained the detail or lost cleanup warning")
	}
}

func TestReportListKeyboardSelectsAndOpensMetadataRecord(t *testing.T) {
	s, f, drain := testScreen(t)
	s.clearReport()
	s.memberID = "member-a"
	s.records = []library.Report{{ID: "report-a", Review: library.Edit{Title: "Synthetic first"}}, {ID: "report-b", Review: library.Edit{Title: "Synthetic second"}}}
	f.report.ID = "report-b"
	tt := ui.NewTester(func(c *ui.Context) { s.list(c); s.consumeRequests() }, 800, 600)
	// Search field, then the timeline list.
	tt.Key(0, ui.KeyTab)
	tt.Key(0, ui.KeyTab)
	tt.Key(0, ui.KeyDown)
	tt.Key(0, ui.KeyDown)
	if s.reportList.Selected == nil || *s.reportList.Selected != 1 {
		t.Fatal("report list has no arrow-key selection")
	}
	tt.Key(0, ui.KeyEnter)
	drain()
	if s.report.ID != "report-b" {
		t.Fatal("Enter did not load selected record")
	}
}

func TestNewMemberAutofocusAndEnter(t *testing.T) {
	s, f, drain := testScreen(t)
	s.newMember = true
	tt := ui.NewTester(s.view, 1240, 1000)
	if !tt.Focused("Member name") {
		t.Fatal("member name must receive focus")
	}
	tt.Type("Synthetic keyboard member")
	tt.Key(0, ui.KeyEnter)
	drain()
	if f.added != "Synthetic keyboard member" || s.newMember {
		t.Fatal("Enter did not create member")
	}
}

type sourceDelayedPreview struct {
	*fakeBackend
	started chan string
	release chan struct{}
}

func (f *sourceDelayedPreview) Preview(_ context.Context, _, source string, _ int) (image.Image, error) {
	f.started <- source
	if source == "source-a" {
		<-f.release
	}
	n := 12
	if source == "source-b" {
		n = 24
	}
	return image.NewRGBA(image.Rect(0, 0, n, n)), nil
}

func TestSwitchSourceRejectsOldPreviewAndRawText(t *testing.T) {
	s, f, _ := testScreen(t)
	twoSources(s)
	backend := &sourceDelayedPreview{f, make(chan string, 2), make(chan struct{})}
	s.backend = backend
	updates := make(chan func(), 4)
	s.post = func(fn func()) { updates <- fn }
	s.preview(1)
	<-backend.started
	s.sourceID = "source-b"
	s.preview(1)
	if s.initialText() != "Synthetic source B" {
		t.Fatal("source-local raw text cache reused another original")
	}
	close(backend.release)
	timeout := time.After(3 * time.Second)
	for s.previewBusy {
		select {
		case fn := <-updates:
			fn()
		case <-timeout:
			t.Fatal("new preview did not finish")
		}
	}
	for len(updates) > 0 {
		(<-updates)()
	}
	w, _ := s.bitmap.Size()
	if w != 24 || s.sourceID != "source-b" {
		t.Fatal("old original replaced selected source")
	}
}

func TestSeparateChoiceImportsEveryFileWithoutCombining(t *testing.T) {
	s, f, drain := testScreen(t)
	s.chooseImport([]string{"synthetic-one.png", "synthetic-two.pdf"})
	if len(f.imports) != 0 {
		t.Fatal("selection bypassed the grouping choice")
	}
	s.importSelection(false)
	drain()
	if !slices.Equal(f.imports, []string{"synthetic-one.png", "synthetic-two.pdf"}) || len(f.grouped) != 0 {
		t.Fatal("separate choice did not retain file boundaries")
	}
}

func TestConfirmedDirtyShutdownUsesUpdateAndWaits(t *testing.T) {
	s, f, drain := testScreen(t)
	f.report.Status = "confirmed"
	s.accept(f.report)
	s.startEditing()
	s.edit.Title = "Synthetic close correction"
	exited := false
	s.requestShutdown(func() { exited = true })
	if exited || s.pending == nil {
		t.Fatal("confirmed edits bypassed close guard")
	}
	tt := ui.NewTester(s.view, 1240, 1000)
	if err := tt.Click("Save and continue"); err != nil {
		t.Fatal(err)
	}
	drain()
	if !exited || !f.updated || s.dirty() || f.saved.Title != "Synthetic close correction" {
		t.Fatal("close did not save confirmed correction before continuing")
	}
}

func TestCommittedDeletionCannotReturnStaleRowsAfterReloadFailure(t *testing.T) {
	s, f, drain := testScreen(t)
	s.records = []library.Report{s.report, {ID: "other-record"}}
	s.drafts = []library.Report{s.report}
	s.backend = reloadFailure{f}
	s.deleteReport()
	drain()
	if s.report.ID != "" || len(s.drafts) != 0 || len(s.records) != 1 || s.records[0].ID != "other-record" || s.message != "load_failed" {
		t.Fatal("reload failure made committed deletion ambiguous")
	}
}

func TestExportCancelIsNormalAndOnlyConfirmedSnapshotCanExport(t *testing.T) {
	s, f, drain := testScreen(t)
	chose := false
	s.exportOriginals(func() (string, error) { chose = true; return "synthetic.zip", nil })
	if chose || s.busy != "" {
		t.Fatal("draft reached export")
	}
	s.report.Status = "confirmed"
	for _, previous := range []string{"exported", "export_failed"} {
		s.message = previous
		s.exportOriginals(func() (string, error) { return "", nil })
		drain()
		if s.message != "export_cancelled" || f.exported != [2]string{} {
			t.Fatal("save-panel cancel retained an unrelated export outcome")
		}
	}
	s.exportOriginals(func() (string, error) { return "", errors.New("synthetic_panel_failure") })
	drain()
	if s.message != "export_failed" || f.exported != [2]string{} {
		t.Fatal("panel failure reached exporter")
	}
	s.exportOriginals(func() (string, error) { return "synthetic.zip", nil })
	drain()
	if s.message != "exported" || f.exported != [2]string{"report-a", "synthetic.zip"} {
		t.Fatal("selected confirmed report was not exported")
	}
	s.startEditing()
	chose = false
	s.exportOriginals(func() (string, error) { chose = true; return "synthetic.zip", nil })
	if chose || s.busy != "" {
		t.Fatal("unpublished confirmed edits reached export")
	}
}

func TestNativeSaveIncludesTextQueuedBeforeTheFrame(t *testing.T) {
	for _, label := range []string{"Report Title", "Findings (Verbatim)", "My Notes (Optional)"} {
		t.Run(label, func(t *testing.T) {
			s, f, drain := testScreen(t)
			saveBeforeFrame := false
			tt := ui.NewTester(func(c *ui.Context) {
				// Window.Update runs the native menu callback before building
				// the frame that consumes the latest text event.
				if saveBeforeFrame {
					saveBeforeFrame = false
					s.queueSaveShortcut()
				}
				s.view(c)
			}, 1240, 1100)
			if err := clickField(tt, label); err != nil {
				t.Fatal(err)
			}
			tt.Command("selectAll")
			saveBeforeFrame = true
			tt.Type("Synthetic newest input")
			drain()
			var got string
			switch label {
			case "Report Title":
				got = f.saved.Title
			case "Findings (Verbatim)":
				got = f.saved.Text
			case "My Notes (Optional)":
				got = f.saved.Notes
			}
			if got != "Synthetic newest input" {
				t.Fatal("native save omitted the last queued input")
			}
		})
	}
}

func TestNativeSaveWaitsForPendingComposition(t *testing.T) {
	s, f, drain := testScreen(t)
	saveBeforeFrame := false
	tt := ui.NewTester(func(c *ui.Context) {
		if saveBeforeFrame {
			saveBeforeFrame = false
			s.queueSaveShortcut()
		}
		s.view(c)
	}, 1240, 1100)
	if err := tt.Click("Report Title"); err != nil {
		t.Fatal(err)
	}
	saveBeforeFrame = true
	tt.Compose("hecheng", 7)
	if s.busy != "" {
		drain()
	}
	if !s.composing || f.saved.Title != "" {
		t.Fatal("native save passed the pending composition guard")
	}
	tt.Compose("", 0)
	tt.Type("Synthetic committed input")
	if f.saved.Title != "" || s.busy != "" {
		t.Fatal("ignored save request ran later without another explicit save")
	}
}

func TestNativeNavigationWaitsForPendingFirstEdit(t *testing.T) {
	for _, confirmed := range []bool{false, true} {
		status := "draft"
		if confirmed {
			status = "confirmed"
		}
		// Import is blocked while the review sheet is open, like a Swift sheet;
		// TestImportIsBlockedWhileReviewSheetIsOpen covers it.
		for _, action := range []string{"close", "quit"} {
			t.Run(status+"/"+action, func(t *testing.T) {
				s, f, drain := testScreen(t)
				if confirmed {
					s.report.Status = "confirmed"
					s.startEditing()
				}
				beforeFrame, advanced := false, false
				tt := ui.NewTester(func(c *ui.Context) {
					if beforeFrame {
						beforeFrame = false
						if s.dirty() || s.edit.Notes != "" {
							t.Fatal("first input was not pending before native callback")
						}
						// Model Window.Update before field construction through the
						// same helpers used by the production native callbacks.
						if action == "import" {
							s.queueNavigation(func() { advanced = true })
						} else {
							s.queueShutdown(func() { advanced, s.allowClose = true, true })
						}
					}
					s.view(c)
				}, 1240, 1100)
				if err := clickField(tt, "My Notes (Optional)"); err != nil {
					t.Fatal(err)
				}
				beforeFrame = true
				tt.Type("X")
				if advanced || s.allowClose || s.pending == nil || s.edit.Notes != "X" || !s.dirty() {
					t.Fatal("native action bypassed the first pending edit's dirty guard")
				}
				if !tt.HasText("Unsaved Changes") {
					t.Fatal("native dirty guard was not rendered")
				}
				if err := tt.Click("Save and continue"); err != nil {
					t.Fatal(err)
				}
				drain()
				if !advanced || f.saved.Notes != "X" || f.updated != confirmed {
					t.Fatal("native continuation did not preserve the first edit")
				}
			})
		}
	}
}

func TestNativeShutdownTakesPriorityOverSameFrameImportAndSave(t *testing.T) {
	for _, shutdownFirst := range []bool{false, true} {
		t.Run(fmt.Sprintf("shutdown-first-%v", shutdownFirst), func(t *testing.T) {
			s, f, drain := testScreen(t)
			beforeFrame, exited, imported := false, false, false
			tt := ui.NewTester(func(c *ui.Context) {
				if beforeFrame {
					beforeFrame = false
					shutdown := func() { s.queueShutdown(func() { exited = true }) }
					others := func() {
						s.queueNavigation(func() { imported = true })
						s.queueSaveShortcut()
					}
					if shutdownFirst {
						shutdown()
						others()
					} else {
						others()
						shutdown()
					}
				}
				s.view(c)
			}, 1240, 1100)
			if err := clickField(tt, "My Notes (Optional)"); err != nil {
				t.Fatal(err)
			}
			beforeFrame = true
			tt.Type("X")
			if s.busy != "" {
				drain()
			}
			if exited || imported || f.saved.Notes != "" || s.pending == nil || s.edit.Notes != "X" {
				t.Fatal("same-frame import/save bypassed shutdown's dirty guard")
			}
			if err := tt.Click("Keep Editing"); err != nil {
				t.Fatal(err)
			}
			tt.Frame()
			if exited || imported || f.saved.Notes != "" || s.pending != nil || s.busy != "" {
				t.Fatal("cancelled shutdown replayed a lower priority intent")
			}
		})
	}
}

func TestNativeNavigationRendersGuardWithoutAnotherInputEvent(t *testing.T) {
	s, _, _ := testScreen(t)
	tt := ui.NewTester(s.view, 1240, 1100)
	s.edit.Notes = "Synthetic existing unsaved note"
	advanced := false
	s.queueShutdown(func() { advanced = true })
	tt.Frame()
	if advanced || s.pending == nil || !tt.HasText("Unsaved Changes") {
		t.Fatal("native request did not render its dirty guard without another input")
	}
}

func TestNativeNavigationDoesNotInterruptOrReplayComposition(t *testing.T) {
	for _, action := range []string{"close", "quit", "import"} {
		t.Run(action, func(t *testing.T) {
			s, _, _ := testScreen(t)
			beforeFrame, advanced := false, false
			tt := ui.NewTester(func(c *ui.Context) {
				if beforeFrame {
					beforeFrame = false
					if action == "import" {
						s.queueNavigation(func() { advanced = true })
					} else {
						s.queueShutdown(func() { advanced = true })
					}
				}
				s.view(c)
			}, 1240, 1100)
			if err := clickField(tt, "My Notes (Optional)"); err != nil {
				t.Fatal(err)
			}
			beforeFrame = true
			tt.Compose("hecheng", 7)
			if advanced || !s.composing || s.pending != nil || s.shutdown != nil {
				t.Fatal("native navigation interrupted an active composition")
			}
			tt.Compose("", 0)
			tt.Type("Synthetic committed text")
			tt.Frame()
			if advanced || s.pending != nil || s.shutdown != nil || s.edit.Notes != "Synthetic committed text" {
				t.Fatal("ignored native navigation replayed after composition")
			}
		})
	}
}

func TestSaveCapturesSourceOrderBeforeBackgroundWrite(t *testing.T) {
	s, f, drain := testScreen(t)
	twoSources(s)
	backend := &shutdownSaveBackend{fakeBackend: f, started: make(chan context.Context, 1), release: make(chan struct{})}
	s.backend = backend
	s.moveSource(1)
	s.save(false, nil)
	<-backend.started
	// A state change after admission must not mutate the captured write.
	s.edit.SourceIDs[0] = "synthetic-later-value"
	close(backend.release)
	drain()
	if !slices.Equal(f.saved.SourceIDs, []string{"source-b", "source-a"}) {
		t.Fatal("submitted order shared the mutable editor slice")
	}
}

func TestEditorCommandsAndCompositionStayScopedToCurrentReport(t *testing.T) {
	for _, label := range []string{"Report Title", "Findings (Verbatim)", "My Notes (Optional)"} {
		t.Run(label, func(t *testing.T) {
			s, _, _ := testScreen(t)
			tt := ui.NewTester(s.view, 1240, 1100)
			if err := clickField(tt, label); err != nil {
				t.Fatal(err)
			}
			tt.Command("selectAll")
			tt.Command("copy")
			before := tt.Clipboard()
			tt.Compose("hecheng", 7)
			tt.Compose("", 0)
			tt.Command("selectAll")
			tt.Command("copy")
			if tt.Clipboard() != before {
				t.Fatal("cancelled composition lost original field")
			}
			tt.Command("selectAll")
			tt.Type("合成替换")
			tt.Command("undo")
			tt.Command("selectAll")
			tt.Command("copy")
			if tt.Clipboard() != before {
				t.Fatal("single undo did not restore replaced field")
			}
			tt.Command("redo")
			tt.Command("selectAll")
			tt.Command("copy")
			if tt.Clipboard() != "合成替换" {
				t.Fatal("redo did not restore synthetic replacement")
			}
		})
	}
}

func TestDiscardedConfirmedEditDoesNotLeakIntoNextUndoHistory(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Status = "confirmed"
	s.accept(f.report)
	tt := ui.NewTester(s.view, 1240, 1100)
	_ = tt.Click("Edit")
	_ = tt.Click("Report Title")
	tt.Command("selectAll")
	tt.Type("Synthetic discarded title")
	tt.Command("selectAll")
	tt.Type("Synthetic second discarded title")
	s.cancelEditing()
	tt.Frame()
	_ = tt.Click("Discard changes")
	_ = tt.Click("Edit")
	_ = tt.Click("Report Title")
	tt.Command("undo")
	if s.edit.Title != "Synthetic report" || s.dirty() {
		t.Fatal("new editing session inherited discarded undo history")
	}
}

func TestLargeImportChoiceBuildsOnlyVisibleRows(t *testing.T) {
	s, f, _ := testScreen(t)
	for i := range 1000 {
		s.importPaths = append(s.importPaths, fmt.Sprintf("synthetic-%04d.png", i))
	}
	tt := ui.NewTester(s.view, 1240, 1000)
	// The first frame includes estimated-height overscan plus underlying screen
	// labels. Its size must stay bounded independently of the 1000 selected files.
	if !tt.HasText("1. synthetic-0000.png") || tt.HasText("1000. synthetic-0999.png") || len(tt.Texts()) > 300 {
		t.Fatal("import choice eagerly built off-screen file rows")
	}
	r, ok := tt.Find("Selected files")
	if !ok || r.H != 230 {
		t.Fatal("missing file list or changed viewport height")
	}
	for range 8 {
		tt.Scroll(r.X+r.W/2, r.Y+r.H/2, 0, 200_000)
	}
	if !tt.HasText("1000. synthetic-0999.png") || len(tt.Texts()) > 300 {
		t.Fatal("virtualized import choice cannot reach the last file with bounded rows")
	}
	if err := tt.Click("Move file 1000 up"); err != nil {
		t.Fatal(err)
	}
	if s.importPaths[998] != "synthetic-0999.png" || s.importPaths[999] != "synthetic-0998.png" {
		t.Fatal("reordering a file after scrolling changed the wrong files")
	}
	tt.Frame()
	if !tt.HasText("999. synthetic-0999.png") || !tt.HasText("1000. synthetic-0998.png") || tt.HasText("1. synthetic-0000.png") {
		t.Fatal("reordering at the bottom moved the file list viewport")
	}
	if err := tt.Click("Cancel"); err != nil {
		t.Fatal(err)
	}
	if len(s.importPaths) != 0 || len(f.imports) != 0 || len(f.grouped) != 0 {
		t.Fatal("cancel submitted or retained the large file selection")
	}
}

func TestImportIsBlockedWhileReviewSheetIsOpen(t *testing.T) {
	s, f, _ := testScreen(t)
	tt := ui.NewTester(s.view, 1240, 1000)
	s.edit.Notes = "Synthetic unsaved note"
	imported := false
	s.queueNavigation(func() { imported = true })
	tt.Frame()
	if imported || s.pending != nil || s.edit.Notes != "Synthetic unsaved note" || len(f.imports) != 0 {
		t.Fatal("navigation passed an open review sheet")
	}
	if !tt.HasText("Confirm Report Information") {
		t.Fatal("review sheet closed by blocked navigation")
	}
}

func TestReviewLaterSavesAndClosesSheet(t *testing.T) {
	s, f, drain := testScreen(t)
	tt := ui.NewTester(s.view, 1240, 1000)
	s.edit.Text = "Synthetic deferred correction"
	if err := tt.Click("Review Later"); err != nil {
		t.Fatal(err)
	}
	drain()
	tt.Frame()
	if f.saved.Text != "Synthetic deferred correction" || f.confirmed || s.report.ID != "" || tt.HasText("Confirm Report Information") {
		t.Fatal("Review Later must save the draft and close the sheet")
	}
}
