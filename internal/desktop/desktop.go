// Package desktop renders the native report workflow. State belongs to the
// main thread; background operations publish through Window.Update.
package desktop

import (
	"context"
	"errors"
	"image"
	"slices"
	"strings"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
	"kinlogue/internal/document"
	"kinlogue/internal/library"
	"kinlogue/internal/macos"
)

type Backend interface {
	Members(context.Context) ([]library.Member, error)
	AddMember(context.Context, string) (library.Member, error)
	Drafts(context.Context) ([]library.Report, error)
	Search(context.Context, string, string) ([]library.Report, error)
	Get(context.Context, string) (library.Report, error)
	Import(context.Context, string) (library.Report, error)
	ImportMany(context.Context, []string) (library.Report, error)
	Retry(context.Context, string) (library.Report, error)
	SaveReview(context.Context, string, library.Edit) (library.Report, error)
	Confirm(context.Context, string, library.Edit) (library.Report, error)
	UpdateConfirmed(context.Context, string, library.Edit) (library.Report, error)
	Preview(context.Context, string, string, int) (image.Image, error)
	DeleteReport(context.Context, string) (library.DeleteResult, error)
	ExportOriginals(context.Context, string, string) error
	Language(context.Context) (string, error)
	SetLanguage(context.Context, string) error
}

const allMembers = "all"

type screen struct {
	phoneBackend                     LANBackend
	phonePage                        bool
	phone                            phoneFlow
	backend                          Backend
	backups                          BackupBackend
	backup                           backupFlow
	backupPage, recoveryOnly         bool
	restartOnly, activating          bool
	win                              *mygo.Window
	post                             func(func())
	ctx                              context.Context
	stop                             context.CancelFunc
	jobCancel                        context.CancelFunc
	previewCancel                    context.CancelFunc
	previewGate                      chan struct{}
	jobGeneration, previewGeneration uint64
	closed, allowClose               bool
	busy, message                    string
	cancellable, cancelling          bool
	language, systemLanguage         string
	members                          []library.Member
	drafts, records                  []library.Report
	memberID, query                  string
	report                           library.Report
	edit                             library.Edit
	page                             int
	sourceID, cachedSourceID         string
	sourcePage                       int
	sourceText                       string
	bitmap                           *ui.Bitmap
	previewBusy                      bool
	previewPaused                    bool
	previewError                     string
	pending                          func()
	shutdown                         func()
	reportList                       ui.ListState
	reportListScope                  [2]string
	newMember, deletePrompt, showRaw bool
	memberName                       string
	editingConfirmed                 bool
	selectedReport                   int
	importPaths                      []string
	composing                        bool
	saveRequested                    bool
	navigationRequested              func()
	shutdownRequested                func()
}

func newScreen(backend Backend, systemLanguage string) *screen {
	ctx, stop := context.WithCancel(context.Background())
	result := &screen{backend: backend, ctx: ctx, stop: stop, language: "system", systemLanguage: systemLanguage, memberID: allMembers, page: 1, selectedReport: -1, previewGate: make(chan struct{}, 1)}
	result.phoneBackend, _ = backend.(LANBackend)
	return result
}

func Run(backend Backend, backups BackupBackend, startupWarning bool) error {
	s := newScreen(backend, macos.PreferredLanguage())
	s.backups = backups
	if startupWarning {
		s.message = "restore_startup_warning"
	}
	return s.run()
}

func (s *screen) run() error {
	defer s.stop()
	defer s.clearBackupSecrets()
	mygo.App.WhenReady(func() {
		mygo.Theme.SetSource(mygo.ThemeLight)
		s.win = mygo.NewWindow(mygo.WindowOptions{Title: s.t("app"), Width: 1240, Height: 880, MinWidth: 1080, MinHeight: 700, Content: ui.View(s.view)})
		s.post = s.win.Update
		if s.phoneBackend != nil && macos.LANReceptionReadiness() == nil {
			remove, err := macos.ObserveLANLifecycle(s.phoneBackend.RevokeLAN)
			s.phone.lifecycleReady = err == nil
			if err == nil {
				s.win.OnClosed(remove)
			}
		}
		s.updateChrome()
		s.win.OnClose(func(e *mygo.CloseEvent) {
			if s.allowClose {
				return
			}
			e.PreventDefault()
			s.win.Update(func() {
				s.queueShutdown(func() {
					s.allowClose = true
					// Close destroys the surface synchronously on the main thread;
					// leave the frame consuming this intent before doing that.
					s.win.Update(s.win.Close)
				})
			})
		})
		s.win.OnClosed(func() { s.closed = true; s.stop() })
		mygo.App.OnWindowAllClosed(func() { mygo.App.Quit() })
		mygo.App.OnBeforeQuit(func(e *mygo.QuitEvent) {
			if s.allowClose || s.closed {
				return
			}
			e.PreventDefault()
			s.win.Update(func() {
				s.queueShutdown(func() {
					s.allowClose = true
					s.stop()
					mygo.App.Quit() // Quit posts its close sequence after this frame.
				})
			})
		})
		s.load(true)
	})
	return mygo.App.Run()
}

func (s *screen) t(key string, args ...any) string {
	lang := s.language
	if lang == "system" {
		lang = s.systemLanguage
	}
	return translate(lang, key, args...)
}

func (s *screen) updateChrome() {
	if s.win == nil {
		return
	}
	s.win.SetTitle(s.t("app"))
	items := []*mygo.MenuItem{
		{Label: s.t("app"), Submenu: []*mygo.MenuItem{{Label: s.t("quit"), Role: mygo.RoleQuit}}},
	}
	if !s.recoveryOnly && !s.restartOnly && !s.activating {
		items = append(items, &mygo.MenuItem{Label: s.t("file_menu"), Submenu: []*mygo.MenuItem{
			{Label: s.t("import"), Accelerator: "CmdOrCtrl+O", Click: func(*mygo.MenuItem, *mygo.Window) {
				s.win.Update(func() { s.queueNavigation(s.chooseFiles) })
			}},
			{Label: s.t("save_menu"), Accelerator: "CmdOrCtrl+S", Click: func(*mygo.MenuItem, *mygo.Window) { s.win.Update(s.queueSaveShortcut) }},
			{Label: s.t("close_window"), Role: mygo.RoleClose},
		}})
	}
	if !s.restartOnly && !s.activating {
		items = append(items, &mygo.MenuItem{Label: s.t("edit_menu"), Submenu: []*mygo.MenuItem{
			{Label: s.t("undo"), Role: mygo.RoleUndo}, {Label: s.t("redo"), Role: mygo.RoleRedo}, mygo.Separator(),
			{Label: s.t("cut"), Role: mygo.RoleCut}, {Label: s.t("copy"), Role: mygo.RoleCopy}, {Label: s.t("paste"), Role: mygo.RolePaste}, {Label: s.t("select_all"), Role: mygo.RoleSelectAll},
		}})
	}
	mygo.App.SetMenu(mygo.NewMenu(items))
}

// job captures inputs before starting and accepts only this operation's result.
// Work returns a main-thread closure; no background goroutine reads UI fields.
func (s *screen) job(key string, cancellable bool, work func(context.Context) func()) {
	if s.busy != "" || s.closed || s.shutdown != nil {
		return
	}
	s.jobGeneration++
	generation := s.jobGeneration
	ctx, cancel := context.WithCancel(s.ctx)
	s.jobCancel, s.busy, s.cancellable, s.cancelling = cancel, key, cancellable, false
	go func() {
		complete := work(ctx)
		cancel()
		s.post(func() {
			if s.closed || generation != s.jobGeneration {
				return
			}
			s.busy, s.cancellable, s.jobCancel = "", false, nil
			complete()
			if s.busy == "" {
				s.cancelling = false
			}
			s.continueShutdown()
		})
	}()
}

type snapshot struct {
	members         []library.Member
	drafts, records []library.Report
	language        string
}

func (s *screen) read(ctx context.Context, member, query string, language bool) (snapshot, error) {
	var result snapshot
	var err error
	if result.members, err = s.backend.Members(ctx); err != nil {
		return result, err
	}
	if result.drafts, err = s.backend.Drafts(ctx); err != nil {
		return result, err
	}
	if member != "" {
		if member == allMembers {
			member = ""
		}
		if result.records, err = s.backend.Search(ctx, member, query); err != nil {
			return result, err
		}
	}
	if language {
		result.language, err = s.backend.Language(ctx)
	}
	return result, err
}

func (s *screen) apply(data snapshot) {
	s.members, s.drafts, s.records = data.members, data.drafts, data.records
	if data.language != "" {
		s.language = data.language
		s.updateChrome()
	}
}

func (s *screen) load(language bool) {
	if s.recoveryOnly || s.restartOnly || s.activating {
		return
	}
	member, query := s.memberID, s.query
	s.job("loading", false, func(ctx context.Context) func() {
		data, err := s.read(ctx, member, query, language)
		return func() {
			if err != nil {
				s.message = "load_failed"
				return
			}
			s.apply(data)
		}
	})
}

func (s *screen) dirty() bool {
	return s.report.ID != "" && (s.report.Status == "review" || s.editingConfirmed) && !s.edit.Equal(s.report.Review)
}

func (s *screen) modalOpen() bool {
	return len(s.phone.deleteSelection) > 0 || s.pending != nil || s.newMember || s.deletePrompt || len(s.importPaths) > 0 || s.shutdown != nil
}

// Native callbacks run before queued editor events reach their bindings.
// Consume their intents at the end of view, after fields and composition state.
func (s *screen) queueSaveShortcut() { s.saveRequested = true }

func (s *screen) queueShutdown(next func()) {
	s.shutdownRequested = next
	s.navigationRequested, s.saveRequested = nil, false
}

func (s *screen) queueNavigation(next func()) {
	if s.shutdownRequested == nil && s.shutdown == nil && !s.recoveryOnly && !s.restartOnly && !s.activating && s.backup.step == "" {
		s.navigationRequested = next
	}
}

func (s *screen) consumeRequests() bool {
	shutdown, navigation, save := s.shutdownRequested, s.navigationRequested, s.saveRequested
	s.shutdownRequested, s.navigationRequested, s.saveRequested = nil, nil, false
	// An input method owns an unfinished candidate. The user can issue the
	// action again after committing or cancelling it; never replay it later.
	if s.closed || s.allowClose || s.composing {
		return false
	}
	// A close request wins over navigation and save, regardless of callback
	// order. Only its existing save/discard/cancel guard may continue it.
	switch {
	case shutdown != nil:
		s.requestShutdown(shutdown)
	case navigation != nil:
		if !s.modalOpen() {
			s.leave(navigation)
		}
	case save:
		s.saveShortcut()
	default:
		return false
	}
	return true
}

func (s *screen) saveShortcut() {
	if s.busy != "" || s.modalOpen() || s.composing || s.backupPage || s.recoveryOnly || s.restartOnly || s.activating {
		return
	}
	if s.report.Status == "review" || s.editingConfirmed {
		s.save(false, nil)
	}
}

func (s *screen) leave(next func()) {
	if s.shutdown != nil {
		s.message = "shutdown_waiting"
		return
	}
	if s.busy != "" {
		s.message = "wait_busy"
		return
	}
	if s.dirty() {
		s.pending = next
		return
	}
	next()
}

// Close is a lifecycle request, not navigation: stop admitting work, cancel
// cancellable recognition, and retain the request until entered work settles.
// Service.Close still owns waiting for native calls and closing the database.
func (s *screen) requestShutdown(next func()) {
	if s.closed {
		return
	}
	s.shutdown, s.pending = next, nil
	s.stopPhone()
	s.clearBackupSecrets()
	s.newMember, s.deletePrompt = false, false
	s.importPaths = nil
	s.previewGeneration++
	s.previewPaused = s.previewPaused || s.previewBusy
	s.previewBusy = false
	if s.previewCancel != nil {
		s.previewCancel()
	}
	if s.busy != "" {
		s.message = "shutdown_waiting"
		if s.cancellable && s.jobCancel != nil {
			s.cancelling = true
			s.jobCancel()
		}
		return
	}
	s.continueShutdown()
}

func (s *screen) continueShutdown() {
	if s.closed || s.busy != "" || s.shutdown == nil {
		return
	}
	next := s.shutdown
	// Hand the intent to the ordinary save/discard/cancel guard. Clearing it
	// here makes Cancel revoke the close request, including after save failure.
	s.shutdown = nil
	s.leave(next)
}

func (s *screen) cancelLeave() {
	s.pending = nil
	if s.previewPaused {
		s.preview(s.page)
	}
}

func (s *screen) selectMember(id string) {
	s.queueNavigation(func() {
		s.clearReport()
		s.backupPage = false
		s.phonePage = false
		s.stopPhoneRefresh()
		s.phone.generation++
		s.memberID, s.query, s.message = id, "", ""
		s.load(false)
	})
}

func (s *screen) clearReport() {
	s.previewGeneration++
	if s.previewCancel != nil {
		s.previewCancel()
	}
	s.report, s.edit, s.bitmap, s.page, s.previewError, s.previewBusy, s.showRaw = library.Report{}, library.Edit{}, nil, 1, "", false, false
	s.sourcePage, s.sourceText = 0, ""
	s.sourceID, s.cachedSourceID, s.editingConfirmed = "", "", false
	s.previewPaused = false
}

func (s *screen) accept(report library.Report) {
	previousReport, previousSource := s.report.ID, s.sourceID
	s.report, s.edit = report, cloneEdit(report.Review)
	s.sourceID = ""
	if previousReport == report.ID {
		for _, source := range report.Sources {
			if source.ID == previousSource {
				s.sourceID = previousSource
				break
			}
		}
	}
	if s.sourceID == "" && len(report.Sources) > 0 {
		s.sourceID = report.Sources[0].ID
	}
	s.editingConfirmed = false
	s.showRaw = false
	s.sourcePage, s.sourceText = 0, ""
	s.cachedSourceID = ""
}

func cloneEdit(edit library.Edit) library.Edit {
	edit.SourceIDs = slices.Clone(edit.SourceIDs)
	return edit
}

func (s *screen) source() library.Source {
	for _, source := range s.report.Sources {
		if source.ID == s.sourceID {
			return source
		}
	}
	return library.Source{}
}

func (s *screen) selectSource(id string) {
	if id == s.sourceID {
		return
	}
	for _, source := range s.report.Sources {
		if source.ID == id {
			s.sourceID = id
			s.preview(1)
			return
		}
	}
}

func (s *screen) moveSource(delta int) {
	if s.busy != "" || (s.report.Status != "review" && !s.editingConfirmed) {
		return
	}
	i := slices.Index(s.edit.SourceIDs, s.sourceID)
	if i < 0 || i+delta < 0 || i+delta >= len(s.edit.SourceIDs) {
		return
	}
	s.edit.SourceIDs[i], s.edit.SourceIDs[i+delta] = s.edit.SourceIDs[i+delta], s.edit.SourceIDs[i]
}

func (s *screen) startEditing() {
	if s.report.Status == "confirmed" && s.busy == "" {
		s.edit = cloneEdit(s.report.Review)
		s.editingConfirmed = true
		s.message = ""
	}
}

func (s *screen) cancelEditing() {
	s.leave(func() { s.edit = cloneEdit(s.report.Review); s.editingConfirmed = false; s.message = "" })
}

func (s *screen) initialText() string {
	if s.sourcePage == s.page && s.cachedSourceID == s.sourceID {
		return s.sourceText
	}
	parts := []string{}
	for _, block := range s.source().Extraction.Blocks {
		if block.Page == s.page {
			parts = append(parts, block.Text)
		}
	}
	// Recognition is immutable between report snapshots. Retain only the
	// selected page instead of joining up to 1 MiB again on every UI frame.
	s.sourcePage, s.sourceText = s.page, strings.Join(parts, "\n")
	s.cachedSourceID = s.sourceID
	return s.sourceText
}

func (s *screen) open(id string) {
	s.queueNavigation(func() {
		s.job("loading", false, func(ctx context.Context) func() {
			report, err := s.backend.Get(ctx, id)
			return func() {
				if err != nil {
					s.message = "load_failed"
					return
				}
				s.clearReport()
				s.accept(report)
				s.message = ""
				s.preview(1)
			}
		})
	})
}

func (s *screen) preview(page int) {
	if s.shutdown != nil || s.closed || s.report.ID == "" || s.sourceID == "" || page < 1 || page > max(1, s.source().Extraction.PageCount) {
		return
	}
	s.previewGeneration++
	generation, id, sourceID := s.previewGeneration, s.report.ID, s.sourceID
	if s.previewCancel != nil {
		s.previewCancel()
	}
	ctx, cancel := context.WithCancel(s.ctx)
	s.previewPaused = false
	s.previewCancel, s.page, s.bitmap, s.previewBusy, s.previewError = cancel, page, nil, true, ""
	go func() {
		// Native decoding is not necessarily interruptible. Keep at most one
		// call in flight while cancelled, queued page requests exit promptly.
		select {
		case s.previewGate <- struct{}{}:
		case <-ctx.Done():
			return
		}
		if ctx.Err() != nil {
			<-s.previewGate
			return
		}
		img, err := s.backend.Preview(ctx, id, sourceID, page)
		<-s.previewGate
		var bitmap *ui.Bitmap
		if ctx.Err() == nil && err == nil && img != nil && img.Bounds().Dx() > 0 && img.Bounds().Dy() > 0 && img.Bounds().Dx() <= document.MaxRenderEdge && img.Bounds().Dy() <= document.MaxRenderEdge {
			bitmap = ui.NewBitmap(img)
		}
		cancel()
		s.post(func() {
			if s.closed || generation != s.previewGeneration || s.report.ID != id || s.sourceID != sourceID {
				return
			}
			s.previewBusy = false
			if bitmap == nil {
				s.previewError = "preview_failed"
				return
			}
			s.bitmap = bitmap
		})
	}()
}

func (s *screen) canConfirm() bool {
	if (s.report.Status != "review" && !s.editingConfirmed) || strings.TrimSpace(s.edit.Title) == "" || document.ValidateDate(s.edit.Date) != nil {
		return false
	}
	for _, member := range s.members {
		if member.ID == s.edit.MemberID {
			return true
		}
	}
	return false
}

func (s *screen) save(confirm bool, after func()) {
	if s.composing || s.report.ID == "" || (s.report.Status != "review" && !s.editingConfirmed) {
		return
	}
	if document.ValidateDate(s.edit.Date) != nil {
		s.message = "invalid_date"
		return
	}
	if (confirm || s.editingConfirmed) && !s.canConfirm() {
		s.message = "invalid_review"
		return
	}
	id, edit, member, query, updating := s.report.ID, cloneEdit(s.edit), s.memberID, s.query, s.editingConfirmed
	s.job("saving", false, func(ctx context.Context) func() {
		var report library.Report
		var err error
		if updating {
			report, err = s.backend.UpdateConfirmed(ctx, id, edit)
		} else if confirm {
			report, err = s.backend.Confirm(ctx, id, edit)
		} else {
			report, err = s.backend.SaveReview(ctx, id, edit)
		}
		var data snapshot
		var loadErr error
		if err == nil {
			data, loadErr = s.read(ctx, member, query, false)
		}
		return func() {
			if err != nil {
				s.message = "save_failed"
				return
			}
			s.accept(report)
			if loadErr == nil {
				s.apply(data)
			}
			s.message = "saved"
			if updating {
				s.message = "updated"
			}
			if confirm {
				s.message = "confirmed"
			}
			if loadErr != nil {
				s.message = "load_failed"
			}
			if after != nil && s.shutdown == nil {
				s.pending = nil
				after()
			}
		}
	})
}

func (s *screen) chooseFiles() {
	if s.win == nil || s.busy != "" || s.recoveryOnly || s.restartOnly || s.activating {
		return
	}
	s.backupPage = false
	parent, title, detail, filter := s.win, s.t("import"), s.t("import_detail"), s.t("formats")
	s.job("loading", false, func(ctx context.Context) func() {
		paths, err := mygo.Dialog.Open(mygo.OpenDialogOptions{Parent: parent, Title: title, Message: detail, Multiple: true, Filters: []mygo.FileFilter{{Name: filter, Extensions: []string{"pdf", "jpg", "jpeg", "png", "heic", "tif", "tiff"}}}})
		return func() {
			if err != nil {
				s.message = "import_failed"
				return
			}
			s.chooseImport(paths)
		}
	})
}

func (s *screen) chooseImport(paths []string) {
	if s.closed || s.shutdown != nil {
		return
	}
	if len(paths) > 0 {
		s.phonePage = false
		s.stopPhoneRefresh()
		s.phone.generation++
	}
	if len(paths) == 1 {
		s.importFiles(paths)
	} else if len(paths) > 1 {
		s.importPaths = slices.Clone(paths)
	}
}

func (s *screen) importSelection(combined bool) {
	if len(s.importPaths) == 0 || s.busy != "" {
		return
	}
	if combined && len(s.importPaths) > document.MaxSources {
		s.message = "sources_limit"
		return
	}
	paths := slices.Clone(s.importPaths)
	s.importPaths = nil
	if !combined {
		s.importFiles(paths)
		return
	}
	member, query := s.memberID, s.query
	s.job("importing", true, func(ctx context.Context) func() {
		report, err := s.backend.ImportMany(ctx, paths)
		data, loadErr := s.read(s.ctx, member, query, false)
		return func() {
			if loadErr == nil {
				s.apply(data)
			}
			s.message = errorKey(err, "import_failed")
			if report.ID != "" {
				s.clearReport()
				s.accept(report)
				s.preview(1)
			}
		}
	})
}

func (s *screen) importFiles(paths []string) {
	member, query := s.memberID, s.query
	s.job("importing", true, func(ctx context.Context) func() {
		var latest library.Report
		var failure error
		for _, path := range paths {
			if ctx.Err() != nil {
				failure = ctx.Err()
				break
			}
			report, err := s.backend.Import(ctx, path)
			if report.ID != "" {
				latest = report
			}
			if err != nil {
				failure = err
			}
		}
		// Cancellation stops processing, but reload uses the screen lifetime to
		// reveal drafts that were durably imported before the cancellation.
		data, loadErr := s.read(s.ctx, member, query, false)
		return func() {
			if loadErr == nil {
				s.apply(data)
			}
			s.message = errorKey(failure, "import_failed")
			if latest.ID != "" {
				s.clearReport()
				s.accept(latest)
				s.preview(1)
			}
		}
	})
}

func (s *screen) retry() {
	id, member, query := s.report.ID, s.memberID, s.query
	s.job("processing", true, func(ctx context.Context) func() {
		report, err := s.backend.Retry(ctx, id)
		data, loadErr := s.read(s.ctx, member, query, false)
		return func() {
			if loadErr == nil {
				s.apply(data)
			}
			s.message = errorKey(err, "recognition_failed")
			if report.ID != "" {
				s.accept(report)
				s.preview(1)
			}
		}
	})
}

func (s *screen) addMember() {
	name, member, query := strings.TrimSpace(s.memberName), s.memberID, s.query
	if name == "" {
		return
	}
	s.job("saving", false, func(ctx context.Context) func() {
		_, err := s.backend.AddMember(ctx, name)
		var data snapshot
		var loadErr error
		if err == nil {
			data, loadErr = s.read(ctx, member, query, false)
		}
		return func() {
			if err != nil {
				s.message = "member_failed"
				return
			}
			if loadErr == nil {
				s.apply(data)
			}
			s.newMember = false
			s.memberName = ""
			s.message = ""
			if loadErr != nil {
				s.message = "load_failed"
			}
		}
	})
}

func (s *screen) deleteReport() {
	id, member, query := s.report.ID, s.memberID, s.query
	s.job("deleting", false, func(ctx context.Context) func() {
		result, err := s.backend.DeleteReport(ctx, id)
		var data snapshot
		var loadErr error
		if err == nil {
			data, loadErr = s.read(ctx, member, query, false)
		}
		return func() {
			if err != nil {
				s.message = "delete_failed"
				return
			}
			s.clearReport()
			if loadErr == nil {
				s.apply(data)
			}
			// Deletion already committed even if refreshing lists failed. Never
			// leave a stale row that could be mistaken for the retained record.
			s.drafts = slices.DeleteFunc(s.drafts, func(r library.Report) bool { return r.ID == id })
			s.records = slices.DeleteFunc(s.records, func(r library.Report) bool { return r.ID == id })
			s.deletePrompt = false
			s.message = ""
			if loadErr != nil {
				s.message = "load_failed"
			}
			if result.CleanupPending {
				s.message = "cleanup_pending"
			}
		}
	})
}

func (s *screen) chooseExport() {
	if s.win == nil || s.busy != "" || s.report.Status != "confirmed" || s.editingConfirmed {
		return
	}
	parent, title, detail := s.win, s.t("export"), s.t("export_detail")
	s.exportOriginals(func() (string, error) {
		return mygo.Dialog.Save(mygo.SaveDialogOptions{Parent: parent, Title: title, Message: detail, DefaultPath: "Kinlogue-originals.zip", Filters: []mygo.FileFilter{{Name: "ZIP", Extensions: []string{"zip"}}}, CreateDirectories: true})
	})
}

// Keep the save-panel outcome in the same job as publication, including
// cancellation. A chosen path never lives in long-lived screen state.
func (s *screen) exportOriginals(choose func() (string, error)) {
	if s.report.Status != "confirmed" || s.editingConfirmed {
		return
	}
	id := s.report.ID
	s.job("exporting", false, func(ctx context.Context) func() {
		destination, err := choose()
		if err == nil && destination != "" {
			err = s.backend.ExportOriginals(ctx, id, destination)
		}
		return func() {
			if err != nil {
				s.message = "export_failed"
			} else if destination != "" {
				s.message = "exported"
			} else {
				s.message = "export_cancelled"
			}
		}
	})
}

func (s *screen) changeLanguage(language string) {
	s.job("saving", false, func(ctx context.Context) func() {
		err := s.backend.SetLanguage(ctx, language)
		return func() {
			if err != nil {
				s.message = "language_failed"
				return
			}
			s.language = language
			s.updateChrome()
		}
	})
}

func errorKey(err error, fallback string) string {
	if err == nil {
		return ""
	}
	switch {
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return "cancelled"
	case errors.Is(err, document.ErrUnsupported):
		return "unsupported"
	case errors.Is(err, document.ErrLocked):
		return "locked"
	case errors.Is(err, document.ErrLimit):
		return "limit"
	case errors.Is(err, document.ErrInvalid):
		return "invalid_document"
	case errors.Is(err, document.ErrUnavailable):
		return "unavailable"
	default:
		return fallback
	}
}

func failureKey(failure string) string {
	switch failure {
	case "unsupported", "unsupported_document":
		return "unsupported"
	case "locked", "locked_document":
		return "locked"
	case "limit", "document_resource_limit":
		return "limit"
	case "invalid", "invalid_document":
		return "invalid_document"
	case "unavailable", "recognition_unavailable":
		return "unavailable"
	case "cancelled", "interrupted":
		return "cancelled"
	default:
		return "recognition_failed"
	}
}
