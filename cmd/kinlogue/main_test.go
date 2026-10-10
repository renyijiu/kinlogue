package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"kinlogue/internal/app"
	"kinlogue/internal/desktop"
	"kinlogue/internal/library"
)

func TestRuntimeRoutesHealthyAndDegradedStartupAndClosesItsOwner(t *testing.T) {
	for _, degraded := range []bool{false, true} {
		parent := filepath.Join(t.TempDir(), "private")
		if err := os.Mkdir(parent, 0700); err != nil {
			t.Fatal(err)
		}
		root := filepath.Join(parent, "Library")
		runtime, err := library.OpenRuntime(root)
		if err != nil {
			t.Fatal(err)
		}
		if degraded {
			if err = runtime.Close(); err != nil {
				t.Fatal(err)
			}
			if err = os.WriteFile(filepath.Join(root, "unknown"), []byte("synthetic unsupported data"), 0600); err != nil {
				t.Fatal(err)
			}
			runtime, err = library.OpenRuntime(root)
			if err != nil {
				t.Fatal(err)
			}
		}
		ordinary, recovery := 0, 0
		expected := errors.New("synthetic_run_error")
		runErr, closeErr := runLibrary(runtime, func(backend desktop.Backend, backups desktop.BackupBackend, warning bool) error {
			ordinary++
			phone, ok := backend.(interface{ LANStatus() app.LANStatus })
			if !ok || phone.LANStatus().Active {
				t.Fatal("phone backend missing or reception auto-started")
			}
			if degraded || backups == nil || warning {
				t.Fatal("incorrect normal startup composition")
			}
			if _, err := backend.Members(context.Background()); err != nil {
				t.Fatal(err)
			}
			return expected
		}, func(backups desktop.BackupBackend) error {
			recovery++
			if !degraded || backups == nil {
				t.Fatal("incorrect recovery startup composition")
			}
			return expected
		})
		if runErr != expected || closeErr != nil || ordinary+recovery != 1 {
			t.Fatal("run/close result was lost")
		}
		if reopened, err := library.OpenRuntime(root); err != nil {
			t.Fatal("runtime owner retained its lease after UI exit")
		} else {
			reopened.Close()
		}
	}
}

func TestFatalStartupTextStaysLocalizedAndContentFree(t *testing.T) {
	for _, language := range []string{"en", "zh-Hans"} {
		for _, locked := range []bool{false, true} {
			title, message, button := startupText(language, locked)
			if title == "" || message == "" || button == "" {
				t.Fatal("missing localized fatal startup text")
			}
		}
	}
}
