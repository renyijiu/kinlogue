package app

import (
	"bytes"
	"context"
	"errors"
	"image"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"kinlogue/internal/backup"
	"kinlogue/internal/document"
	"kinlogue/internal/library"
)

func backupFixture(t *testing.T) (*BackupController, *Service, *library.Runtime, string, *bytes.Buffer) {
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
	service := New(runtime.Store(), processor{func(context.Context, []byte) (document.Extraction, error) { return synthetic(), nil }}, func(string) ([]byte, error) { return []byte("SYNTHETIC ORIGINAL"), nil }, nil)
	var published bytes.Buffer
	controller := NewBackupController(runtime, service, func(c context.Context, _ string, write func(io.Writer) error, verify func(io.Reader) error) error {
		var temporary bytes.Buffer
		if err := write(&temporary); err != nil {
			return err
		}
		if err := verify(bytes.NewReader(temporary.Bytes())); err != nil {
			return err
		}
		if err := c.Err(); err != nil {
			return err
		}
		published.Reset()
		_, _ = published.Write(temporary.Bytes())
		return nil
	}, func(_ context.Context, _ string, read func(io.Reader) error) error {
		return read(bytes.NewReader(published.Bytes()))
	})
	t.Cleanup(func() { _ = controller.Close() })
	return controller, service, runtime, root, &published
}

func backupCode(t *testing.T) string {
	t.Helper()
	code, err := backup.NewCode()
	if err != nil {
		t.Fatal("code generation failed")
	}
	return code
}

func TestBackupHoldsMutationsThroughReadbackAndPublication(t *testing.T) {
	b, s, _, _, _ := backupFixture(t)
	code := backupCode(t)
	ctx := context.Background()
	if _, err := s.AddMember(ctx, "Synthetic member"); err != nil {
		t.Fatal(err)
	}
	entered, release := make(chan struct{}), make(chan struct{})
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	original := b.writeBackup
	b.writeBackup = func(c context.Context, path string, write func(io.Writer) error, verify func(io.Reader) error) error {
		return original(c, path, write, func(r io.Reader) error {
			if err := verify(r); err != nil {
				return err
			}
			close(entered)
			<-release
			return nil
		})
	}
	done := make(chan error, 1)
	go func() { _, err := b.CreateBackup(ctx, "/synthetic/backup", code); done <- err }()
	<-entered
	wait, cancel := context.WithTimeout(ctx, 40*time.Millisecond)
	defer cancel()
	if _, err := s.AddMember(wait, "Synthetic queued member"); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal("backup released mutation queue before publication")
	}
	close(release)
	if err := awaitExport(t, done); err != nil {
		t.Fatal(err)
	}
	p, err := b.PrepareRestore(ctx, "/synthetic/backup", code)
	if err != nil || p.Summary.Members != 1 {
		t.Fatal("snapshot did not retain one consistent library")
	}
	if err := b.CancelRestore(p.Handle); err != nil {
		t.Fatal(err)
	}
}

func TestBackupCloseCancelsAndWaitsAndCommittedBackupStaysSuccessful(t *testing.T) {
	t.Run("close waits", func(t *testing.T) {
		b, s, runtime, _, _ := backupFixture(t)
		entered, cancelled, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
		defer func() {
			select {
			case <-release:
			default:
				close(release)
			}
		}()
		b.writeBackup = func(c context.Context, _ string, _ func(io.Writer) error, _ func(io.Reader) error) error {
			close(entered)
			<-c.Done()
			close(cancelled)
			<-release
			return c.Err()
		}
		done, closed := make(chan error, 1), make(chan error, 1)
		code := backupCode(t)
		go func() { _, err := b.CreateBackup(context.Background(), "/synthetic/backup", code); done <- err }()
		<-entered
		go func() { closed <- b.Close() }()
		<-cancelled
		select {
		case <-closed:
			t.Fatal("Close returned before backup settled")
		default:
		}
		if _, err := runtime.Store().Members(context.Background()); err != nil {
			t.Fatal("Store closed with backup entered")
		}
		close(release)
		if err := awaitExport(t, done); !errors.Is(err, context.Canceled) {
			t.Fatal("backup did not cancel")
		}
		if err := awaitExport(t, closed); err != nil {
			t.Fatal(err)
		}
		if _, err := s.Members(context.Background()); !errors.Is(err, ErrClosed) {
			t.Fatal("closed controller left Service open")
		}
	})
	t.Run("committed", func(t *testing.T) {
		b, _, _, _, _ := backupFixture(t)
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		original := b.writeBackup
		b.writeBackup = func(c context.Context, path string, write func(io.Writer) error, verify func(io.Reader) error) error {
			err := original(c, path, write, verify)
			if err == nil {
				cancel()
			}
			return err
		}
		if _, err := b.CreateBackup(ctx, "/synthetic/backup", backupCode(t)); err != nil {
			t.Fatal("committed backup reported cancellation")
		}
	})
}

func TestPrepareWrongCodeCancelAndStaleHandlesKeepActiveLibrary(t *testing.T) {
	b, s, _, _, _ := backupFixture(t)
	ctx := context.Background()
	if _, err := s.AddMember(ctx, "Synthetic original member"); err != nil {
		t.Fatal(err)
	}
	code := backupCode(t)
	if _, err := b.CreateBackup(ctx, "/synthetic/backup", code); err != nil {
		t.Fatal(err)
	}
	if _, err := b.PrepareRestore(ctx, "/synthetic/backup", backupCode(t)); err == nil {
		t.Fatal("wrong code prepared")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := b.PrepareRestore(cancelled, "/synthetic/backup", code); !errors.Is(err, context.Canceled) {
		t.Fatal("cancelled preparation accepted")
	}
	p, err := b.PrepareRestore(ctx, "/synthetic/backup", code)
	if err != nil {
		t.Fatal(err)
	}
	if err := b.CancelRestore(p.Handle); err != nil {
		t.Fatal(err)
	}
	next, err := b.PrepareRestore(ctx, "/synthetic/backup", code)
	if err != nil {
		t.Fatal(err)
	}
	foreign, _, _, _, _ := backupFixture(t)
	for _, handle := range []RestoreHandle{{}, p.Handle, {owner: foreign, generation: next.Handle.generation}} {
		if restart, err := b.ActivateRestore(handle); restart || err == nil {
			t.Fatal("invalid handle crossed activation boundary")
		}
		if err := b.CancelRestore(handle); err == nil {
			t.Fatal("stale handle cancelled current preparation")
		}
	}
	if _, err := s.AddMember(ctx, "Synthetic later member"); err != nil {
		t.Fatal("preparation changed active library usability")
	}
	if members, err := s.Members(ctx); err != nil || len(members) != 2 {
		t.Fatal("preparation modified active library")
	}
	if err := b.CancelRestore(next.Handle); err != nil {
		t.Fatal("stale handle cleared new stage")
	}
}

type blockedBackupProcessor struct{ previewEntered, importEntered, previewCancelled, importCancelled, release chan struct{} }

func (p blockedBackupProcessor) Extract(c context.Context, _ []byte) (document.Extraction, error) {
	close(p.importEntered)
	<-c.Done()
	close(p.importCancelled)
	<-p.release
	return synthetic(), nil
}
func (p blockedBackupProcessor) RenderPage(c context.Context, _ []byte, _ int) (image.Image, error) {
	close(p.previewEntered)
	<-c.Done()
	close(p.previewCancelled)
	<-p.release
	return image.NewRGBA(image.Rect(0, 0, 2, 2)), nil
}

func TestActivateDrainsNativePreviewAndImportBeforeRootSwitch(t *testing.T) {
	b, s, runtime, root, _ := backupFixture(t)
	ctx := context.Background()
	r, err := s.Import(ctx, "/synthetic/source.pdf")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.AddMember(ctx, "Synthetic restored member"); err != nil {
		t.Fatal(err)
	}
	code := backupCode(t)
	if _, err := b.CreateBackup(ctx, "/synthetic/backup", code); err != nil {
		t.Fatal(err)
	}
	p, err := b.PrepareRestore(ctx, "/synthetic/backup", code)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.AddMember(ctx, "Synthetic old-only member"); err != nil {
		t.Fatal(err)
	}
	processor := blockedBackupProcessor{make(chan struct{}), make(chan struct{}), make(chan struct{}), make(chan struct{}), make(chan struct{})}
	defer func() {
		select {
		case <-processor.release:
		default:
			close(processor.release)
		}
	}()
	s.processor = processor
	preview, importing := make(chan error, 1), make(chan error, 1)
	go func() { _, err := s.Preview(ctx, r.ID, r.Sources[0].ID, 1); preview <- err }()
	<-processor.previewEntered
	go func() { _, err := s.Import(ctx, "/synthetic/late.pdf"); importing <- err }()
	<-processor.importEntered
	activated := make(chan error, 1)
	go func() {
		restart, err := b.ActivateRestore(p.Handle)
		if !restart {
			activated <- errors.New("activation did not require restart")
			return
		}
		activated <- err
	}()
	<-processor.previewCancelled
	<-processor.importCancelled
	closed := make(chan error, 1)
	go func() { closed <- b.Close() }()
	select {
	case <-activated:
		t.Fatal("activation returned before native work settled")
	default:
	}
	if _, err := s.Members(ctx); !errors.Is(err, ErrClosed) {
		t.Fatal("read admitted during activation")
	}
	if _, err := s.AddMember(ctx, "Synthetic rejected member"); !errors.Is(err, ErrClosed) {
		t.Fatal("write admitted during activation")
	}
	if members, err := runtime.Store().Members(ctx); err != nil || len(members) != 2 {
		t.Fatal("active Store closed before entered work drained")
	}
	close(processor.release)
	if err := awaitExport(t, preview); !errors.Is(err, context.Canceled) {
		t.Fatal("late preview escaped cancellation")
	}
	if err := awaitExport(t, importing); !errors.Is(err, context.Canceled) {
		t.Fatal("late import escaped cancellation")
	}
	if err := awaitExport(t, activated); err != nil {
		t.Fatal(err)
	}
	if err := awaitExport(t, closed); err != nil {
		t.Fatal("concurrent Close did not wait for activation")
	}
	if err := b.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := library.OpenRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if members, err := reopened.Store().Members(ctx); err != nil || len(members) != 1 {
		t.Fatal("activated snapshot not installed")
	}
	if drafts, err := reopened.Store().Drafts(ctx); err != nil || len(drafts) != 1 {
		t.Fatal("late import contaminated restored snapshot")
	}
}

func TestRecoveryControllerRestoresUnreadableLibrary(t *testing.T) {
	b, s, _, root, published := backupFixture(t)
	ctx := context.Background()
	if _, err := s.AddMember(ctx, "Synthetic recovered member"); err != nil {
		t.Fatal(err)
	}
	code := backupCode(t)
	if _, err := b.CreateBackup(ctx, "/synthetic/backup", code); err != nil {
		t.Fatal(err)
	}
	data := append([]byte(nil), published.Bytes()...)
	if err := b.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "library.sqlite"), []byte("SYNTHETIC CORRUPT DATABASE"), 0600); err != nil {
		t.Fatal(err)
	}
	runtime, err := library.OpenRuntime(root)
	if err != nil || runtime.Store() != nil || runtime.OpenError() == nil {
		t.Fatal("degraded Runtime unavailable")
	}
	recovery := NewRecoveryController(runtime, func(_ context.Context, _ string, read func(io.Reader) error) error {
		return read(bytes.NewReader(data))
	})
	defer recovery.Close()
	p, err := recovery.PrepareRestore(ctx, "/synthetic/backup", code)
	if err != nil || p.Summary.Members != 1 {
		t.Fatal("degraded preparation failed")
	}
	if restart, err := recovery.ActivateRestore(p.Handle); !restart || err != nil {
		t.Fatal("degraded activation failed")
	}
	if err := recovery.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := library.OpenRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if members, err := reopened.Store().Members(ctx); err != nil || len(members) != 1 {
		t.Fatal("degraded recovery did not install data")
	}
}

func TestPrepareCancellationAndCloseWaitForEnteredReader(t *testing.T) {
	for _, shutdown := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancel", true: "close"}[shutdown], func(t *testing.T) {
			b, s, _, root, _ := backupFixture(t)
			ctx := context.Background()
			if _, err := s.AddMember(ctx, "Synthetic active member"); err != nil {
				t.Fatal(err)
			}
			code := backupCode(t)
			if _, err := b.CreateBackup(ctx, "/synthetic/backup", code); err != nil {
				t.Fatal(err)
			}
			entered, cancelled, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
			defer func() {
				select {
				case <-release:
				default:
					close(release)
				}
			}()
			original := b.readBackup
			b.readBackup = func(c context.Context, path string, read func(io.Reader) error) error {
				if err := original(c, path, read); err != nil {
					return err
				}
				close(entered)
				<-c.Done()
				close(cancelled)
				<-release
				return c.Err()
			}
			preparing, cancel := context.WithCancel(ctx)
			defer cancel()
			done, closed := make(chan error, 1), make(chan error, 1)
			go func() { _, err := b.PrepareRestore(preparing, "/synthetic/backup", code); done <- err }()
			<-entered
			if shutdown {
				go func() { closed <- b.Close() }()
			} else {
				cancel()
			}
			<-cancelled
			if _, err := s.store.Members(ctx); err != nil {
				t.Fatal("preparation closed old Store")
			}
			if shutdown {
				select {
				case <-closed:
					t.Fatal("Close returned while reader was entered")
				default:
				}
			}
			close(release)
			if err := awaitExport(t, done); !errors.Is(err, context.Canceled) {
				t.Fatal("cancelled preparation returned a stage")
			}
			if shutdown {
				if err := awaitExport(t, closed); err != nil {
					t.Fatal(err)
				}
			} else {
				if _, err := s.AddMember(ctx, "Synthetic later member"); err != nil {
					t.Fatal("cancelled prepare stopped ordinary use")
				}
				b.readBackup = original
				p, err := b.PrepareRestore(ctx, "/synthetic/backup", code)
				if err != nil {
					t.Fatal("cancelled stage prevented new preparation")
				}
				if err := b.CancelRestore(p.Handle); err != nil {
					t.Fatal(err)
				}
			}
			entries, err := os.ReadDir(filepath.Dir(root))
			if err != nil {
				t.Fatal(err)
			}
			for _, entry := range entries {
				if entry.IsDir() && entry.Name() != "Library" {
					t.Fatal("cancelled owned stage remained")
				}
			}
		})
	}
}

func TestFailedActivationStillRequiresRestart(t *testing.T) {
	b, s, _, root, _ := backupFixture(t)
	ctx := context.Background()
	code := backupCode(t)
	if _, err := b.CreateBackup(ctx, "/synthetic/backup", code); err != nil {
		t.Fatal(err)
	}
	p, err := b.PrepareRestore(ctx, "/synthetic/backup", code)
	if err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Dir(root))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.IsDir() && entry.Name() != "Library" {
			if err := os.WriteFile(filepath.Join(filepath.Dir(root), entry.Name(), "unknown"), []byte("SYNTHETIC UNOWNED FILE"), 0600); err != nil {
				t.Fatal(err)
			}
		}
	}
	if restart, err := b.ActivateRestore(p.Handle); !restart || err == nil {
		t.Fatal("activation failure allowed continued use")
	}
	if _, err := s.Members(ctx); !errors.Is(err, ErrClosed) {
		t.Fatal("activation failure reopened Service")
	}
	if err := b.CancelRestore(p.Handle); !errors.Is(err, ErrClosed) {
		t.Fatal("activation failure allowed cancellation")
	}
	if _, err := b.PrepareRestore(ctx, "/synthetic/backup", code); !errors.Is(err, ErrClosed) {
		t.Fatal("activation failure admitted new preparation")
	}
}
