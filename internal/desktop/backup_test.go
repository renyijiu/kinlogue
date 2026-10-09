package desktop

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/egoist/mygo/ui"
	"kinlogue/internal/app"
	"kinlogue/internal/backup"
	"kinlogue/internal/library"
)

type fakeBackup struct {
	writes, preparations, cancellations, activations int
	writeError, prepareError, activateError          error
	prepareStarted                                   chan struct{}
	prepareRelease                                   chan struct{}
	activateStarted                                  chan struct{}
	activateRelease                                  chan struct{}
	restart                                          bool
	prepared                                         app.RestorePreparation
	cancelledHandles                                 []app.RestoreHandle
}

func (f *fakeBackup) CreateBackup(context.Context, string, string) (library.SnapshotSummary, error) {
	f.writes++
	return library.SnapshotSummary{}, f.writeError
}
func (f *fakeBackup) PrepareRestore(context.Context, string, string) (app.RestorePreparation, error) {
	f.preparations++
	if f.prepareStarted != nil {
		close(f.prepareStarted)
		<-f.prepareRelease
	}
	if f.prepared.Summary.Members != 0 {
		return f.prepared, f.prepareError
	}
	return app.RestorePreparation{Summary: library.SnapshotSummary{Members: 2, Reports: 3, Sources: 4}}, f.prepareError
}
func (f *fakeBackup) CancelRestore(handle app.RestoreHandle) error {
	f.cancellations++
	f.cancelledHandles = append(f.cancelledHandles, handle)
	return nil
}
func (f *fakeBackup) ActivateRestore(app.RestoreHandle) (bool, error) {
	f.activations++
	if f.activateStarted != nil {
		close(f.activateStarted)
		<-f.activateRelease
	}
	return f.restart, f.activateError
}

func backupScreen(t *testing.T) (*screen, *fakeBackup, func()) {
	s, _, drain := testScreen(t)
	f := &fakeBackup{}
	s.backups = f
	s.showBackup()
	return s, f, drain
}

func TestBackupRequiresHiddenCodeReentryAndPanelCancelAbandonsIdentity(t *testing.T) {
	s, f, drain := backupScreen(t)
	tt := ui.NewTester(s.view, 1240, 1000)
	tt.SetClipboard("synthetic previous clipboard")
	if err := tt.Click("Create encrypted backup"); err != nil {
		t.Fatal(err)
	}
	code, publicID := s.backup.code, s.backup.publicID
	if len(code) < 48 || len(publicID) != 16 || tt.Clipboard() != "synthetic previous clipboard" {
		t.Fatal("identity missing or copied without consent")
	}
	if !tt.HasText(code[:48]) {
		t.Fatal("generated code was not displayed")
	}
	if err := tt.Click("Copy recovery code"); err != nil {
		t.Fatal(err)
	}
	if tt.Clipboard() != code {
		t.Fatal("explicit copy did not copy complete code")
	}
	if err := tt.Click("I saved the code"); err != nil {
		t.Fatal(err)
	}
	if s.backup.input != "" || tt.HasText(code[:48]) {
		t.Fatal("reentry was prefilled or generated code stayed visible")
	}
	if err := tt.Click("Re-enter recovery code"); err != nil {
		t.Fatal(err)
	}
	tt.Type("synthetic wrong code")
	chosen := false
	s.createBackup(func(string) (string, error) { chosen = true; return "synthetic.kinloguegobackup", nil })
	if chosen || f.writes != 0 || s.busy != "" {
		t.Fatal("wrong reentry reached destination or writer")
	}
	tt.Command("selectAll")
	tt.Type(code)
	s.createBackup(func(name string) (string, error) {
		if !strings.HasSuffix(name, "-"+publicID) || strings.Contains(name, ".kinloguegobackup") {
			t.Error("default filename must include public identity and let the panel add its extension")
		}
		return "", nil
	})
	drain()
	if f.writes != 0 || s.backup.code != "" || s.backup.input != "" || s.backup.step != "" || s.message != "backup_cancelled" {
		t.Fatal("panel cancel kept attempt or wrote backup")
	}
	s.startBackup()
	if s.backup.code == code || s.backup.publicID == publicID {
		t.Fatal("retry reused backup identity")
	}
}

func TestBackupSuccessAndFailureClearSecretsAndUseBackendOutcome(t *testing.T) {
	for _, fail := range []bool{false, true} {
		s, f, drain := backupScreen(t)
		if fail {
			f.writeError = errors.New("synthetic_private_path")
		}
		s.startBackup()
		s.acknowledgeCode()
		s.backup.input = s.backup.code
		s.createBackup(func(string) (string, error) { return "synthetic.kinloguegobackup", nil })
		drain()
		want := "backup_created"
		if fail {
			want = "backup_failed"
		}
		if f.writes != 1 || s.message != want || s.backup.code != "" || s.backup.input != "" {
			t.Fatal("publication outcome or secret lifecycle incorrect")
		}
	}
}

func TestBackupPasswordCancelReopenAndUndoCannotReviveSecret(t *testing.T) {
	s, _, _ := backupScreen(t)
	tt := ui.NewTester(s.view, 1240, 1000)
	for i := 0; i < 2; i++ {
		if err := tt.Click("Create encrypted backup"); err != nil {
			t.Fatal(err)
		}
		if err := tt.Click("I saved the code"); err != nil {
			t.Fatal(err)
		}
		if err := tt.Click("Re-enter recovery code"); err != nil {
			t.Fatal(err)
		}
		tt.Command("undo")
		if s.backup.input != "" {
			t.Fatal("new password editor revived old undo history")
		}
		tt.Type("synthetic ephemeral input")
		tt.SetClipboard("synthetic unchanged")
		tt.Command("selectAll")
		tt.Command("copy")
		tt.Command("cut")
		if tt.Clipboard() != "synthetic unchanged" || s.backup.input != "synthetic ephemeral input" || tt.HasText("synthetic ephemeral input") {
			t.Fatal("password field exposed or cut plaintext")
		}
		if err := tt.Click("Cancel"); err != nil {
			t.Fatal(err)
		}
		if s.backup.input != "" || s.backup.code != "" {
			t.Fatal("cancel kept secrets")
		}
	}
}

func TestBackupNavigationSeesPendingFirstInputAndComposition(t *testing.T) {
	for _, composing := range []bool{false, true} {
		s, _, _ := testScreen(t)
		s.backups = &fakeBackup{}
		request := false
		tt := ui.NewTester(func(c *ui.Context) {
			if request {
				request = false
				s.queueNavigation(s.showBackup)
			}
			s.view(c)
		}, 1240, 1100)
		if err := tt.Click("My notes"); err != nil {
			t.Fatal(err)
		}
		request = true
		if composing {
			tt.Compose("hecheng", 7)
		} else {
			tt.Type("X")
		}
		if s.backupPage || (!composing && (s.pending == nil || s.edit.Notes != "X")) || (composing && s.pending != nil) {
			t.Fatal("backup bypassed pending input guard")
		}
		if composing {
			tt.Compose("", 0)
			tt.Frame()
			if s.backupPage {
				t.Fatal("navigation replayed after composition")
			}
		}
	}
}

func TestRestorePreparationCancellationRejectsDelayedResult(t *testing.T) {
	s, f, drain := backupScreen(t)
	f.prepareStarted = make(chan struct{})
	f.prepareRelease = make(chan struct{})
	s.restoreFile(func() (string, error) { return "synthetic.kinloguegobackup", nil })
	drain()
	s.backup.input = "synthetic recovery input"
	s.prepareRestore()
	<-f.prepareStarted
	tt := ui.NewTester(s.view, 1240, 1000)
	if err := tt.Click("Cancel processing"); err != nil {
		t.Fatal(err)
	}
	close(f.prepareRelease)
	drain()
	if f.cancellations != 1 || f.activations != 0 || s.backup.prepared != nil || s.backup.input != "" {
		t.Fatal("cancelled preparation published a stage or retained secret")
	}
}

func TestPreparedSummaryRequiresConfirmationAndCancelUsesBackend(t *testing.T) {
	s, f, drain := backupScreen(t)
	s.restoreFile(func() (string, error) { return "synthetic.kinloguegobackup", nil })
	drain()
	s.backup.input = "synthetic recovery input"
	s.prepareRestore()
	drain()
	tt := ui.NewTester(s.view, 1240, 1000)
	if !tt.HasText("Members: 2 · Reports: 3 · Originals: 4") || f.activations != 0 || s.backup.input != "" {
		t.Fatal("unvalidated or automatic activation")
	}
	if err := tt.Click("Cancel"); err != nil {
		t.Fatal(err)
	}
	drain()
	if f.cancellations != 1 || s.backup.prepared != nil || s.backup.step != "" {
		t.Fatal("prepared cancel did not retire stage")
	}
}

func TestRestoreActivationFailureLocksNavigationAndQuitWaits(t *testing.T) {
	s, f, drain := backupScreen(t)
	f.restart = true
	f.activateError = errors.New("synthetic_activation_failure")
	f.activateStarted = make(chan struct{})
	f.activateRelease = make(chan struct{})
	s.restoreFile(func() (string, error) { return "synthetic.kinloguegobackup", nil })
	drain()
	s.backup.input = "synthetic recovery input"
	s.prepareRestore()
	drain()
	tt := ui.NewTester(s.view, 1240, 1000)
	if err := tt.Click("Replace entire library"); err != nil {
		t.Fatal(err)
	}
	<-f.activateStarted
	exited := false
	s.queueShutdown(func() { exited = true })
	tt.Frame()
	if exited || s.cancellable {
		t.Fatal("quit did not wait for activation")
	}
	close(f.activateRelease)
	drain()
	tt.Frame()
	if !s.restartOnly || !exited || s.message != "restore_restart_failed" {
		t.Fatal("accepted activation failure reopened ordinary UI")
	}
	advanced := false
	s.queueNavigation(func() { advanced = true })
	s.queueSaveShortcut()
	tt.Frame()
	if advanced || tt.HasText("Import reports…") {
		t.Fatal("restart-only allowed ordinary navigation")
	}
}

func TestRecoveryOnlyNeverLoadsOrdinaryBackend(t *testing.T) {
	s := newRecoveryScreen(&fakeBackup{}, "en")
	defer s.stop()
	s.load(true)
	tt := ui.NewTester(s.view, 1240, 900)
	if !tt.HasText("Recover your library") || tt.HasText("Import reports…") || s.busy != "" {
		t.Fatal("recovery attempted normal library flow")
	}
	s.queueSaveShortcut()
	s.queueNavigation(func() { t.Fatal("recovery navigated to ordinary workflow") })
	tt.Frame()
}

func TestRestorePasswordReopenUsesNewUndoHistory(t *testing.T) {
	s, _, drain := backupScreen(t)
	tt := ui.NewTester(s.view, 1240, 1000)
	for range 2 {
		s.restoreFile(func() (string, error) { return "synthetic.kinloguegobackup", nil })
		drain()
		tt.Frame()
		if err := tt.Click("Recovery code"); err != nil {
			t.Fatal(err)
		}
		tt.Command("undo")
		if s.backup.input != "" {
			t.Fatal("restore reopened an old secret editor")
		}
		tt.Type("synthetic restore input")
		tt.SetClipboard("synthetic unchanged")
		tt.Command("selectAll")
		tt.Command("copy")
		tt.Command("cut")
		if tt.Clipboard() != "synthetic unchanged" || tt.HasText("synthetic restore input") {
			t.Fatal("restore password exposed plaintext")
		}
		if err := tt.Click("Cancel"); err != nil {
			t.Fatal(err)
		}
	}
}

func TestBackupSidebarUsesUnsavedGuard(t *testing.T) {
	s, _, drain := testScreen(t)
	s.backups = &fakeBackup{}
	tt := ui.NewTester(s.view, 1240, 1100)
	if err := tt.Click("My notes"); err != nil {
		t.Fatal(err)
	}
	tt.Type("Synthetic saved before backup")
	if err := tt.Click("Settings"); err != nil {
		t.Fatal(err)
	}
	if s.backupPage || s.pending == nil {
		t.Fatal("sidebar skipped unsaved guard")
	}
	if err := tt.Click("Save and continue"); err != nil {
		t.Fatal(err)
	}
	drain()
	tt.Frame()
	if !s.backupPage || !tt.HasText("Create encrypted backup") || s.report.ID != "" {
		t.Fatal("saving did not continue to backup")
	}
}

func TestRestoreCancelAfterBackendReturnStillRetiresPreparation(t *testing.T) {
	s, f, _ := backupScreen(t)
	updates := make(chan func(), 4)
	s.post = func(fn func()) { updates <- fn }
	s.restoreFile(func() (string, error) { return "synthetic.kinloguegobackup", nil })
	(<-updates)()
	s.backup.input = "synthetic input"
	s.prepareRestore()
	complete := <-updates
	tt := ui.NewTester(s.view, 1240, 1000)
	if err := tt.Click("Cancel processing"); err != nil {
		t.Fatal(err)
	}
	complete()
	(<-updates)()
	if f.cancellations != 1 || s.backup.prepared != nil || s.backup.step != "" {
		t.Fatal("late cancel displayed completed preparation")
	}
}

func realBackupController(t *testing.T) (*app.BackupController, *app.Service, string) {
	t.Helper()
	parent := filepath.Join(t.TempDir(), "private")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(parent, "Library")
	runtime, err := library.OpenRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	service := app.New(runtime.Store(), nil, nil, nil)
	var published bytes.Buffer
	controller := app.NewBackupController(runtime, service, func(_ context.Context, _ string, write func(io.Writer) error, verify func(io.Reader) error) error {
		var temporary bytes.Buffer
		if err := write(&temporary); err != nil {
			return err
		}
		if err := verify(bytes.NewReader(temporary.Bytes())); err != nil {
			return err
		}
		published = temporary
		return nil
	}, func(_ context.Context, _ string, read func(io.Reader) error) error {
		return read(bytes.NewReader(published.Bytes()))
	})
	t.Cleanup(func() { _ = controller.Close() })
	return controller, service, root
}

func TestBackupAndRestoreViewUsesRealController(t *testing.T) {
	controller, service, root := realBackupController(t)
	if _, err := service.AddMember(context.Background(), "Synthetic backed-up member"); err != nil {
		t.Fatal(err)
	}
	s, _, drain := backupScreen(t)
	s.backend, s.backups = service, controller
	tt := ui.NewTester(s.view, 1240, 1000)
	if err := tt.Click("Create encrypted backup"); err != nil {
		t.Fatal(err)
	}
	code := s.backup.code
	if err := tt.Click("I saved the code"); err != nil {
		t.Fatal(err)
	}
	tt.Type(code)
	s.createBackup(func(string) (string, error) { return "synthetic.kinloguegobackup", nil })
	drain()
	if s.message != "backup_created" {
		t.Fatal("real controller did not publish verified backup")
	}
	if _, err := service.AddMember(context.Background(), "Synthetic later member"); err != nil {
		t.Fatal(err)
	}
	s.restoreFile(func() (string, error) { return "synthetic.kinloguegobackup", nil })
	drain()
	tt.Frame()
	tt.Type(code)
	if err := tt.Click("Validate backup"); err != nil {
		t.Fatal(err)
	}
	drain()
	tt.Frame()
	if s.backup.prepared == nil || s.backup.prepared.Summary.Members != 1 {
		t.Fatal("view did not receive fully validated snapshot")
	}
	if err := tt.Click("Replace entire library"); err != nil {
		t.Fatal(err)
	}
	drain()
	tt.Frame()
	if !s.restartOnly || s.message != "restore_restart" {
		t.Fatal("real activation did not enter restart-only")
	}
	if err := controller.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := library.OpenRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	members, err := reopened.Store().Members(context.Background())
	if err != nil || len(members) != 1 || members[0].Name != "Synthetic backed-up member" {
		t.Fatal("restart did not open restored snapshot")
	}
}

func TestStalePreparationCannotActivateOrClearNewerGeneration(t *testing.T) {
	controller, service, _ := realBackupController(t)
	if _, err := service.AddMember(context.Background(), "Synthetic member"); err != nil {
		t.Fatal(err)
	}
	code, err := backup.NewCode()
	if err != nil {
		t.Fatal("code generation failed")
	}
	if _, err = controller.CreateBackup(context.Background(), "synthetic", code); err != nil {
		t.Fatal(err)
	}
	old, err := controller.PrepareRestore(context.Background(), "synthetic", code)
	if err != nil {
		t.Fatal(err)
	}
	if err = controller.CancelRestore(old.Handle); err != nil {
		t.Fatal(err)
	}
	newer, err := controller.PrepareRestore(context.Background(), "synthetic", code)
	if err != nil {
		t.Fatal(err)
	}
	if old.Handle == newer.Handle {
		t.Fatal("fixture did not advance real handle generation")
	}
	s, f, _ := backupScreen(t)
	f.prepared = old
	updates := make(chan func(), 4)
	s.post = func(fn func()) { updates <- fn }
	s.restoreFile(func() (string, error) { return "synthetic", nil })
	(<-updates)()
	s.backup.input = "synthetic input"
	s.prepareRestore()
	complete := <-updates
	s.backup.generation++
	s.backup.step = "prepared"
	s.backup.prepared = &newer
	complete()
	(<-updates)()
	if len(f.cancelledHandles) != 1 || f.cancelledHandles[0] != old.Handle || s.backup.prepared == nil || s.backup.prepared.Handle != newer.Handle || f.activations != 0 {
		t.Fatal("old result activated or cleared the newer stage")
	}
}
