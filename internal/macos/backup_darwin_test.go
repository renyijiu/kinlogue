//go:build darwin

package macos

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"kinlogue/internal/backup"
	"kinlogue/internal/library"
)

func TestBackupNativeSnapshotRoundTrip(t *testing.T) {
	ctx := context.Background()
	store, err := library.Open(filepath.Join(t.TempDir(), "library"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, err := store.AddMember(ctx, "Synthetic backup member"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateDraftSources(ctx, []string{"synthetic.pdf"}, func(int) ([]byte, error) { return []byte("SYNTHETIC ORIGINAL"), nil }); err != nil {
		t.Fatal(err)
	}
	code, err := backup.NewCode()
	if err != nil {
		t.Fatal("code generation failed")
	}
	path := filepath.Join(t.TempDir(), "synthetic.kinloguegobackup")
	for range 2 { // New file, then atomic replacement of that file.
		var digest [32]byte
		err = WriteBackup(ctx, path, func(w io.Writer) error {
			var e error
			digest, e = backup.Encrypt(ctx, w, code, func(w io.Writer) error { _, e := store.WriteSnapshot(ctx, w); return e })
			return e
		}, func(r io.Reader) error {
			return backup.Verify(ctx, r, code, digest, func(r io.Reader) error { _, e := library.VerifySnapshot(ctx, r); return e })
		})
		if err != nil {
			t.Fatal(err)
		}
		var summary library.SnapshotSummary
		err = ReadBackup(ctx, path, func(r io.Reader) error {
			return backup.Decrypt(ctx, r, code, func(r io.Reader) error { var e error; summary, e = library.VerifySnapshot(ctx, r); return e })
		})
		if err != nil || summary.Members != 1 || summary.Reports != 1 || summary.Sources != 1 {
			t.Fatal("native encrypted snapshot round trip failed")
		}
	}
}

func TestBackupCorruptReadbackPreservesPreviousTarget(t *testing.T) {
	ctx := context.Background()
	store, err := library.Open(filepath.Join(t.TempDir(), "library"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	code, err := backup.NewCode()
	if err != nil {
		t.Fatal("code generation failed")
	}
	path := filepath.Join(t.TempDir(), "synthetic.kinloguegobackup")
	old := []byte("SYNTHETIC PREVIOUS TARGET")
	if err := os.WriteFile(path, old, 0600); err != nil {
		t.Fatal(err)
	}
	var digest [32]byte
	err = WriteBackup(ctx, path, func(w io.Writer) error {
		var encrypted bytes.Buffer
		var err error
		digest, err = backup.Encrypt(ctx, &encrypted, code, func(w io.Writer) error { _, err := store.WriteSnapshot(ctx, w); return err })
		if err != nil {
			return err
		}
		data := encrypted.Bytes()
		data[len(data)-1] ^= 1
		_, err = w.Write(data)
		return err
	}, func(r io.Reader) error {
		return backup.Verify(ctx, r, code, digest, func(r io.Reader) error { _, err := library.VerifySnapshot(ctx, r); return err })
	})
	if !errors.Is(err, ErrBackupWrite) {
		t.Fatal("corrupt authenticated tail published")
	}
	got, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(got, old) {
		t.Fatal("failed authentication changed previous target")
	}
}

func TestBackupPublicationFailurePreservesTarget(t *testing.T) {
	for _, scenario := range []string{"write", "verify", "cancel", "changed target"} {
		t.Run(scenario, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "synthetic.kinloguegobackup")
			old := []byte("SYNTHETIC OLD TARGET")
			if err := os.WriteFile(path, old, 0600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			err := WriteBackup(ctx, path, func(w io.Writer) error {
				_, e := io.WriteString(w, "SYNTHETIC NEW TARGET")
				if scenario == "write" {
					return errors.New("synthetic private detail")
				}
				return e
			}, func(r io.Reader) error {
				_, e := io.Copy(io.Discard, r)
				if scenario == "verify" {
					return errors.New("synthetic private detail")
				}
				if scenario == "cancel" {
					cancel()
				}
				if scenario == "changed target" {
					replacement := filepath.Join(filepath.Dir(path), "replacement")
					if e := os.WriteFile(replacement, old, 0600); e != nil {
						return e
					}
					return os.Rename(replacement, path)
				}
				return e
			})
			if err == nil {
				t.Fatal("failed backup published")
			}
			if scenario == "cancel" {
				if !errors.Is(err, context.Canceled) {
					t.Fatal("cancellation lost")
				}
			} else if !errors.Is(err, ErrBackupWrite) {
				t.Fatal("non-content error not preserved")
			}
			got, e := os.ReadFile(path)
			if e != nil || !bytes.Equal(got, old) {
				t.Fatal("previous target changed")
			}
		})
	}
}

func TestReadBackupRejectsUnsafeAndChangingFiles(t *testing.T) {
	for _, scenario := range []string{"symlink", "directory", "fifo", "oversize", "replacement", "growth", "partial", "callback", "cancel"} {
		t.Run(scenario, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "synthetic.kinloguegobackup")
			if err := os.WriteFile(path, []byte("SYNTHETIC BACKUP"), 0600); err != nil {
				t.Fatal(err)
			}
			switch scenario {
			case "symlink":
				link := filepath.Join(filepath.Dir(path), "link")
				if err := os.Symlink(path, link); err != nil {
					t.Fatal(err)
				}
				path = link
			case "directory":
				path = filepath.Dir(path)
			case "fifo":
				path = filepath.Join(filepath.Dir(path), "fifo")
				if err := syscall.Mkfifo(path, 0600); err != nil {
					t.Fatal(err)
				}
			case "oversize":
				if err := os.Truncate(path, backup.MaxCiphertextBytes+1); err != nil {
					t.Fatal(err)
				}
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			called := false
			err := ReadBackup(ctx, path, func(r io.Reader) error {
				called = true
				if scenario == "partial" {
					return nil
				}
				if scenario == "callback" {
					return errors.New("synthetic private detail")
				}
				if _, err := io.Copy(io.Discard, r); err != nil {
					return err
				}
				switch scenario {
				case "cancel":
					cancel()
				case "replacement":
					other := filepath.Join(filepath.Dir(path), "replacement")
					if err := os.WriteFile(other, []byte("SYNTHETIC BACKUP"), 0600); err != nil {
						return err
					}
					return os.Rename(other, path)
				case "growth":
					return os.WriteFile(path, []byte("SYNTHETIC LONGER BACKUP"), 0600)
				}
				return nil
			})
			if scenario == "cancel" {
				if !errors.Is(err, context.Canceled) {
					t.Fatal("read cancellation lost")
				}
			} else if !errors.Is(err, ErrBackupRead) {
				t.Fatal("unsafe read did not fail with fixed error")
			}
			if (scenario == "symlink" || scenario == "directory" || scenario == "fifo" || scenario == "oversize") && called {
				t.Fatal("unsafe input reached callback")
			}
		})
	}
}

func TestReadBackupRejectsReplacedParentWithSameSelectedFile(t *testing.T) {
	root := t.TempDir()
	parent := filepath.Join(root, "selected")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(parent, "synthetic.kinloguegobackup")
	if err := os.WriteFile(path, []byte("SYNTHETIC BACKUP"), 0600); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	called := false
	err = ReadBackup(context.Background(), path, func(r io.Reader) error {
		called = true
		if _, err := io.Copy(io.Discard, r); err != nil {
			return err
		}
		moved := filepath.Join(root, "retained")
		if err := os.Rename(parent, moved); err != nil {
			return err
		}
		if err := os.Mkdir(parent, 0700); err != nil {
			return err
		}
		// Keep the selected inode unchanged so only the parent guard rejects it.
		return os.Link(filepath.Join(moved, filepath.Base(path)), path)
	})
	if !called || !errors.Is(err, ErrBackupRead) {
		t.Fatal("changed parent did not fail with fixed error")
	}
	after, err := os.Stat(path)
	if err != nil || !sameBackupInfo(before, after) {
		t.Fatal("fixture changed the selected file instead of its parent")
	}
}
