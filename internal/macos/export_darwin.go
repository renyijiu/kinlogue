//go:build darwin

package macos

import (
	"archive/zip"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unicode/utf8"
	"unsafe"

	"github.com/ebitengine/purego/objc"
	"golang.org/x/sys/unix"
	"kinlogue/internal/document"
)

var ErrWrite = errors.New("export_write_failed")

// Leave bounded space for ZIP headers while bounding even a malformed writer.
const maxExportBytes int64 = document.MaxSources*document.MaxFileBytes + 1<<20

// WriteExport publishes a validated ZIP at a system SavePanel selection. The
// panel is responsible for obtaining the user's permission to replace a file.
// The callback must only write ZIP bytes; it must not reenter macos APIs because
// it runs inside the serialized native scope and file coordination accessor.
func WriteExport(ctx context.Context, destination string, write func(io.Writer) error) error {
	return writeSelectedFile(ctx, destination, maxExportBytes, write, func(file *os.File, info os.FileInfo) error {
		return validateExportZIP(ctx, file, info.Size())
	})
}

func writeSelectedFile(ctx context.Context, destination string, limit int64, write func(io.Writer) error, verify func(*os.File, os.FileInfo) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if write == nil || verify == nil || !validExportPath(destination) {
		return ErrWrite
	}
	// Cancellation is checked before publication. native's usual late-output
	// cancellation rule would misreport a completed atomic publication as failure.
	err := native(context.Background(), func() error {
		if err := ctx.Err(); err != nil {
			return err
		}
		url := send(class("NSURL"), "fileURLWithPath:", uintptr(nsString(destination)))
		if url == 0 {
			return ErrWrite
		}
		if byte(send(url, "startAccessingSecurityScopedResource")) != 0 {
			defer send(url, "stopAccessingSecurityScopedResource")
		}
		parent, err := openExportDirectory(filepath.Dir(destination))
		if err != nil {
			return ErrWrite
		}
		defer parent.Close()
		parentInfo, err := parent.Stat()
		if err != nil {
			return ErrWrite
		}
		previous, err := exportTarget(destination)
		if err != nil {
			return ErrWrite
		}
		coordinator := send(alloc("NSFileCoordinator"), "initWithFilePresenter:", 0)
		if coordinator == 0 {
			return ErrWrite
		}
		defer release(coordinator)
		var nsError id
		var result error = ErrWrite
		accessor := objc.NewBlock(func(_ objc.Block, coordinatedURL id) {
			path, err := stringCopy(send(coordinatedURL, "path"), 1<<16)
			if err != nil || path != destination {
				return
			}
			result = writeCoordinatedFile(ctx, coordinatedURL, path, parent, parentInfo, previous, limit, write, verify)
		})
		defer accessor.Release()
		// ForReplacing is required even when the selected destination is new.
		send(coordinator, "coordinateWritingItemAtURL:options:error:byAccessor:", uintptr(url), 1<<3, uintptr(unsafe.Pointer(&nsError)), uintptr(accessor))
		if nsError != 0 {
			if err := ctx.Err(); err != nil {
				return err
			}
			return ErrWrite
		}
		return result
	})
	if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
		return ErrWrite
	}
	return err
}

func validExportPath(path string) bool {
	return filepath.IsAbs(path) && filepath.Clean(path) == path && path != "/" &&
		len(path) <= 1<<16 && strings.IndexByte(path, 0) < 0 && utf8.ValidString(path)
}

func openExportDirectory(path string) (*os.File, error) {
	// SavePanel authorizes the selected file, not enumeration of its parent.
	// The public Darwin O_SEARCH flag (O_EXEC | O_DIRECTORY in <sys/fcntl.h>)
	// pins the directory without requesting read access. It is available in
	// macOS 14's SDK but is not defined by the pinned Go syscall/x/sys packages.
	const openSearch = 0x40000000 | syscall.O_DIRECTORY
	fd, err := syscall.Open(path, openSearch|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, ErrWrite
	}
	return os.NewFile(uintptr(fd), ""), nil
}

func exportTarget(path string) (os.FileInfo, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil || !info.Mode().IsRegular() {
		return nil, ErrWrite
	}
	return info, nil
}

func sameExportTarget(path string, previous os.FileInfo) bool {
	current, err := exportTarget(path)
	if err != nil {
		return false
	}
	if current == nil || previous == nil {
		return current == nil && previous == nil
	}
	return os.SameFile(current, previous) && current.Size() == previous.Size() && current.ModTime() == previous.ModTime()
}

func writeCoordinatedFile(ctx context.Context, destinationURL id, destination string, parent *os.File, parentInfo, previous os.FileInfo, limit int64, write func(io.Writer) error, verify func(*os.File, os.FileInfo) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if !sameExportTarget(destination, previous) {
		return ErrWrite
	}
	manager := send(class("NSFileManager"), "defaultManager")
	var nsError id
	// The OS supplies a same-volume replacement directory with sandbox access;
	// NSSavePanel does not grant permission to create arbitrary sibling files.
	stagingURL := send(manager, "URLForDirectory:inDomain:appropriateForURL:create:error:", 99, 1, uintptr(destinationURL), 1, uintptr(unsafe.Pointer(&nsError)))
	if stagingURL == 0 || nsError != 0 {
		return ErrWrite
	}
	staging, err := stringCopy(send(stagingURL, "path"), 1<<16)
	if err != nil || !validExportPath(staging) {
		return ErrWrite
	}
	stagingInfo, err := os.Lstat(staging)
	if err != nil || !stagingInfo.IsDir() || stagingInfo.Mode().Perm()&0077 != 0 {
		return ErrWrite
	}
	stat, ok := stagingInfo.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return ErrWrite
	}
	// Remove only this empty OS-created directory, never recursive contents.
	defer func() {
		if info, err := os.Lstat(staging); err == nil && os.SameFile(info, stagingInfo) {
			_ = os.Remove(staging)
		}
	}()
	stagingDir, err := openExportDirectory(staging)
	if err != nil {
		return ErrWrite
	}
	defer stagingDir.Close()
	openedStage, err := stagingDir.Stat()
	if err != nil || !os.SameFile(openedStage, stagingInfo) {
		return ErrWrite
	}
	file, err := os.CreateTemp(staging, "export-")
	if err != nil {
		return ErrWrite
	}
	temporary := file.Name()
	original, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return ErrWrite
	}
	defer func() {
		_ = file.Close()
		if info, err := os.Lstat(temporary); err == nil && info.Mode().IsRegular() && os.SameFile(info, original) {
			_ = os.Remove(temporary)
		}
	}()
	writer := &exportWriter{ctx: ctx, file: file, remaining: limit}
	if err := write(writer); err != nil || writer.failed {
		if err := ctx.Err(); err != nil {
			return err
		}
		return ErrWrite
	}
	if err := file.Sync(); err != nil {
		return ErrWrite
	}
	if err := file.Close(); err != nil {
		return ErrWrite
	}
	fd, err := syscall.Open(temporary, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return ErrWrite
	}
	read := os.NewFile(uintptr(fd), "")
	defer read.Close()
	info, err := read.Stat()
	if err != nil || !info.Mode().IsRegular() || !os.SameFile(info, original) || info.Mode().Perm() != 0600 {
		return ErrWrite
	}
	if info.Size() <= 0 || info.Size() > limit {
		return ErrWrite
	}
	if err := verify(read, info); err != nil {
		return err
	}
	currentParent, err := os.Lstat(filepath.Dir(destination))
	if err != nil || !currentParent.IsDir() || !os.SameFile(currentParent, parentInfo) || !sameExportTarget(destination, previous) {
		return ErrWrite
	}
	currentStage, err := os.Lstat(temporary)
	if err != nil || !currentStage.Mode().IsRegular() || !os.SameFile(currentStage, info) || currentStage.Size() != info.Size() || currentStage.ModTime() != info.ModTime() {
		return ErrWrite
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	flags := uint32(0)
	if previous == nil {
		flags = unix.RENAME_EXCL
	}
	// Both descriptors pin the checked directories. Existing-file replacement
	// is atomic under coordination, not CAS against uncoordinated processes.
	if err := unix.RenameatxNp(int(stagingDir.Fd()), filepath.Base(temporary), int(parent.Fd()), filepath.Base(destination), flags); err != nil {
		return ErrWrite
	}
	// Rename is the commit point. A later cancellation or directory-sync failure
	// cannot safely roll it back; the complete, already-fsynced file is published.
	_ = parent.Sync()
	return nil
}

type exportWriter struct {
	ctx       context.Context
	file      *os.File
	remaining int64
	failed    bool
}

func (w *exportWriter) Write(data []byte) (int, error) {
	if err := w.ctx.Err(); err != nil {
		w.failed = true
		return 0, err
	}
	if w.failed || int64(len(data)) > w.remaining {
		w.failed = true
		return 0, ErrWrite
	}
	n, err := w.file.Write(data)
	w.remaining -= int64(n)
	if err != nil || n != len(data) {
		w.failed = true
		return n, ErrWrite
	}
	return n, nil
}

func validateExportZIP(ctx context.Context, file *os.File, size int64) error {
	if size <= 0 || size > maxExportBytes {
		return ErrWrite
	}
	// Our bounded writer emits ordinary ZIP, never ZIP64 or an archive comment.
	// Bound directory metadata before archive/zip allocates per-entry objects;
	// checking len(archive.File) afterwards alone would not bound that allocation.
	var end [22]byte
	if size < int64(len(end)) {
		return ErrWrite
	}
	if _, err := file.ReadAt(end[:], size-int64(len(end))); err != nil ||
		binary.LittleEndian.Uint32(end[:]) != 0x06054b50 ||
		binary.LittleEndian.Uint16(end[4:]) != 0 || binary.LittleEndian.Uint16(end[6:]) != 0 ||
		binary.LittleEndian.Uint16(end[20:]) != 0 {
		return ErrWrite
	}
	entries := binary.LittleEndian.Uint16(end[10:])
	directorySize := int64(binary.LittleEndian.Uint32(end[12:]))
	directoryOffset := int64(binary.LittleEndian.Uint32(end[16:]))
	if entries == 0 || entries > document.MaxSources || binary.LittleEndian.Uint16(end[8:]) != entries ||
		directorySize > 1<<20 || directoryOffset+directorySize != size-int64(len(end)) {
		return ErrWrite
	}
	archive, err := zip.NewReader(file, size)
	if err != nil || len(archive.File) == 0 || len(archive.File) > document.MaxSources {
		return ErrWrite
	}
	seen := make(map[string]bool, len(archive.File))
	var total uint64
	for _, entry := range archive.File {
		if err := ctx.Err(); err != nil {
			return err
		}
		name := entry.Name
		if len(name) == 0 || len(name) > 255 || name == "." || name == ".." || strings.ContainsAny(name, "/\\\x00") || !utf8.ValidString(name) || seen[name] || !entry.Mode().IsRegular() || entry.UncompressedSize64 > document.MaxFileBytes {
			return ErrWrite
		}
		seen[name] = true
		total += entry.UncompressedSize64
		if total > document.MaxSources*document.MaxFileBytes {
			return ErrWrite
		}
		reader, err := entry.Open()
		if err != nil {
			return ErrWrite
		}
		// Read through EOF to verify each entry's length and CRC, bounded even if
		// the ZIP claims a smaller length than its decompressed stream produces.
		n, copyErr := io.Copy(io.Discard, io.LimitReader(&exportReader{ctx: ctx, reader: reader}, document.MaxFileBytes+1))
		closeErr := reader.Close()
		if err := ctx.Err(); err != nil {
			return err
		}
		if copyErr != nil || closeErr != nil || uint64(n) != entry.UncompressedSize64 {
			return ErrWrite
		}
	}
	return nil
}

type exportReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r *exportReader) Read(data []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(data)
}
