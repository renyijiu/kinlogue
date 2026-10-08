//go:build darwin

package macos

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"golang.org/x/sys/unix"
	"kinlogue/internal/document"
)

func TestExportDirectorySupportsPublicationWithoutListingPermission(t *testing.T) {
	destination := t.TempDir()
	if err := os.Chmod(destination, 0300); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(destination, 0700) })
	if _, err := os.ReadDir(destination); !errors.Is(err, os.ErrPermission) {
		t.Fatal("fixture must deny directory listing")
	}
	parent, err := openExportDirectory(destination)
	if err != nil {
		t.Fatal("publication must not require listing the destination directory")
	}
	defer parent.Close()
	info, err := parent.Stat()
	if err != nil || !info.IsDir() {
		t.Fatal("cannot verify the pinned destination directory")
	}
	source := filepath.Join(t.TempDir(), "original.zip")
	data := exportZIP(t, 1)
	if err := os.WriteFile(source, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := unix.RenameatxNp(unix.AT_FDCWD, source, int(parent.Fd()), "synthetic.zip", unix.RENAME_EXCL); err != nil {
		t.Fatal("cannot publish through the pinned directory")
	}
	got, err := os.ReadFile(filepath.Join(destination, "synthetic.zip"))
	if err != nil || !bytes.Equal(got, data) {
		t.Fatal("published bytes changed")
	}
}

func exportZIP(t *testing.T, count int) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for index := range count {
		entry, err := writer.CreateHeader(&zip.FileHeader{Name: fmt.Sprintf("source-%02d.txt", index+1), Method: zip.Store})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(entry, "SYNTHETIC ORIGINAL"); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func exportBytes(data []byte) func(io.Writer) error {
	return func(w io.Writer) error { _, err := w.Write(data); return err }
}

func TestWriteExportCreatesAndReplacesCompleteZIP(t *testing.T) {
	destination := filepath.Join(t.TempDir(), "synthetic.zip")
	for _, count := range []int{1, 2, document.MaxSources} {
		data := exportZIP(t, count)
		var temporary string
		if err := WriteExport(context.Background(), destination, func(w io.Writer) error {
			temporary = w.(*exportWriter).file.Name()
			return exportBytes(data)(w)
		}); err != nil {
			t.Fatal(err)
		}
		assertExportStagingRemoved(t, temporary)
		got, err := os.ReadFile(destination)
		if err != nil || !bytes.Equal(got, data) {
			t.Fatal("published export differs from complete synthetic ZIP")
		}
		info, err := os.Stat(destination)
		if err != nil || info.Mode().Perm() != 0600 {
			t.Fatal("export permissions are not private")
		}
		entries, err := os.ReadDir(filepath.Dir(destination))
		if err != nil || len(entries) != 1 {
			t.Fatal("export left temporary entries")
		}
	}
}

func TestWriteExportFailuresPreservePreviousFile(t *testing.T) {
	good := exportZIP(t, 1)
	badCRC := bytes.Clone(good)
	index := bytes.Index(badCRC, []byte("SYNTHETIC ORIGINAL"))
	badCRC[index] ^= 1
	oversize := bytes.Clone(good)
	central := bytes.Index(oversize, []byte("PK\x01\x02"))
	binary.LittleEndian.PutUint32(oversize[central+24:], uint32(document.MaxFileBytes+1))
	oversizeDirectory := bytes.Clone(good)
	binary.LittleEndian.PutUint32(oversizeDirectory[len(oversizeDirectory)-10:], 1<<20+1)
	tests := []struct {
		name  string
		write func(io.Writer) error
	}{
		{"writer failure", func(w io.Writer) error { _, _ = w.Write(good); return errors.New("synthetic private detail") }},
		{"bad CRC", exportBytes(badCRC)},
		{"truncated", exportBytes(good[:len(good)-10])},
		{"invalid", exportBytes([]byte("SYNTHETIC INVALID ARCHIVE"))},
		{"empty", exportBytes(exportZIP(t, 0))},
		{"too many sources", exportBytes(exportZIP(t, document.MaxSources+1))},
		{"oversize header", exportBytes(oversize)},
		{"oversize directory", exportBytes(oversizeDirectory)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			destination := filepath.Join(t.TempDir(), "synthetic.zip")
			if err := os.WriteFile(destination, []byte("SYNTHETIC PREVIOUS"), 0600); err != nil {
				t.Fatal(err)
			}
			var temporary string
			err := WriteExport(context.Background(), destination, func(w io.Writer) error {
				temporary = w.(*exportWriter).file.Name()
				return test.write(w)
			})
			if !errors.Is(err, ErrWrite) || err.Error() != "export_write_failed" {
				t.Fatalf("expected path-free export error, got %v", err)
			}
			assertPreviousExport(t, destination, "SYNTHETIC PREVIOUS")
			assertExportStagingRemoved(t, temporary)
		})
	}
}

func TestWriteExportCancellationDoesNotPublish(t *testing.T) {
	for _, existing := range []bool{false, true} {
		t.Run(fmt.Sprint(existing), func(t *testing.T) {
			destination := filepath.Join(t.TempDir(), "synthetic.zip")
			if existing {
				if err := os.WriteFile(destination, []byte("SYNTHETIC PREVIOUS"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			err := WriteExport(ctx, destination, func(w io.Writer) error {
				_, err := w.Write(exportZIP(t, 1))
				cancel()
				return err
			})
			if !errors.Is(err, context.Canceled) {
				t.Fatalf("expected cancellation, got %v", err)
			}
			if existing {
				assertPreviousExport(t, destination, "SYNTHETIC PREVIOUS")
			} else if _, err := os.Lstat(destination); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("cancelled export published")
			}
		})
	}
}

func TestWriteExportRejectsUnsafeTargets(t *testing.T) {
	for _, kind := range []string{"symlink", "fifo", "directory"} {
		t.Run(kind, func(t *testing.T) {
			dir := t.TempDir()
			destination := filepath.Join(dir, "synthetic.zip")
			switch kind {
			case "symlink":
				if err := os.Symlink("missing", destination); err != nil {
					t.Fatal(err)
				}
			case "fifo":
				if err := syscall.Mkfifo(destination, 0600); err != nil {
					t.Fatal(err)
				}
			case "directory":
				if err := os.Mkdir(destination, 0700); err != nil {
					t.Fatal(err)
				}
			}
			called := false
			err := WriteExport(context.Background(), destination, func(io.Writer) error { called = true; return nil })
			if !errors.Is(err, ErrWrite) || called {
				t.Fatal("unsafe destination accepted")
			}
		})
	}
	for _, destination := range []string{"relative.zip", "/", "/synthetic/../unsafe.zip", "/synthetic\x00.zip"} {
		if err := WriteExport(context.Background(), destination, exportBytes(exportZIP(t, 1))); !errors.Is(err, ErrWrite) {
			t.Fatal("invalid destination accepted")
		}
	}
}

func TestWriteExportDoesNotOverwriteConcurrentReplacement(t *testing.T) {
	for _, existed := range []bool{false, true} {
		t.Run(fmt.Sprint(existed), func(t *testing.T) {
			dir := t.TempDir()
			destination := filepath.Join(dir, "synthetic.zip")
			if existed {
				if err := os.WriteFile(destination, []byte("SYNTHETIC PREVIOUS"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			err := WriteExport(context.Background(), destination, func(w io.Writer) error {
				_, err := w.Write(exportZIP(t, 1))
				other := filepath.Join(dir, "concurrent")
				if err := os.WriteFile(other, []byte("SYNTHETIC CONCURRENT"), 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.Rename(other, destination); err != nil {
					t.Fatal(err)
				}
				return err
			})
			if !errors.Is(err, ErrWrite) {
				t.Fatal("concurrent replacement accepted")
			}
			assertPreviousExport(t, destination, "SYNTHETIC CONCURRENT")
		})
	}
}

func TestWriteExportRejectsUnsafeZIPEntries(t *testing.T) {
	for _, name := range []string{"../original.txt", "/original.txt", "folder/original.txt", "original\\file.txt", strings.Repeat("x", 256)} {
		var data bytes.Buffer
		zw := zip.NewWriter(&data)
		entry, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.WriteString(entry, "SYNTHETIC")
		if err := zw.Close(); err != nil {
			t.Fatal(err)
		}
		destination := filepath.Join(t.TempDir(), "synthetic.zip")
		if err := WriteExport(context.Background(), destination, exportBytes(data.Bytes())); !errors.Is(err, ErrWrite) {
			t.Fatal("unsafe archive entry accepted")
		}
	}
}

func TestWriteExportRejectsChangedParent(t *testing.T) {
	root := t.TempDir()
	parent := filepath.Join(root, "selected")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(parent, "synthetic.zip")
	if err := os.WriteFile(destination, []byte("SYNTHETIC PREVIOUS"), 0600); err != nil {
		t.Fatal(err)
	}
	var temporary string
	err := WriteExport(context.Background(), destination, func(w io.Writer) error {
		temporary = w.(*exportWriter).file.Name()
		if err := os.Rename(parent, filepath.Join(root, "moved")); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(parent, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(destination, []byte("SYNTHETIC CONCURRENT"), 0600); err != nil {
			t.Fatal(err)
		}
		return exportBytes(exportZIP(t, 1))(w)
	})
	if !errors.Is(err, ErrWrite) {
		t.Fatal("changed parent was accepted")
	}
	assertPreviousExport(t, destination, "SYNTHETIC CONCURRENT")
	assertPreviousExport(t, filepath.Join(root, "moved", "synthetic.zip"), "SYNTHETIC PREVIOUS")
	assertExportStagingRemoved(t, temporary)
}

func TestExportWriterEnforcesBoundAndStickyFailure(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "synthetic-")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	w := &exportWriter{ctx: context.Background(), file: file, remaining: 2}
	if n, err := w.Write([]byte("AB")); err != nil || n != 2 {
		t.Fatal("exact bound was rejected")
	}
	if n, err := w.Write([]byte("C")); !errors.Is(err, ErrWrite) || n != 0 {
		t.Fatal("overflow was accepted")
	}
	if _, err := w.Write(nil); !errors.Is(err, ErrWrite) {
		t.Fatal("overflow was forgotten")
	}
	info, err := file.Stat()
	if err != nil || info.Size() != 2 {
		t.Fatal("writer exceeded bound")
	}
}

func assertExportStagingRemoved(t *testing.T, temporary string) {
	t.Helper()
	if temporary == "" {
		t.Fatal("writer never received staging file")
	}
	if _, err := os.Lstat(temporary); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("temporary file remains")
	}
	if _, err := os.Lstat(filepath.Dir(temporary)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("temporary directory remains")
	}
}

func assertPreviousExport(t *testing.T, destination, previous string) {
	t.Helper()
	got, err := os.ReadFile(destination)
	if err != nil || string(got) != previous {
		t.Fatal("previous export changed")
	}
	entries, err := os.ReadDir(filepath.Dir(destination))
	if err != nil || len(entries) != 1 {
		t.Fatal("temporary export entries remain")
	}
}
