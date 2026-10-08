//go:build darwin

package macos

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"

	"github.com/ebitengine/purego/objc"
	"kinlogue/internal/backup"
)

var (
	ErrBackupWrite = errors.New("backup_file_write_failed")
	ErrBackupRead  = errors.New("backup_file_read_failed")
)

// WriteBackup scopes, coordinates, fully reads back, then atomically publishes
// the selected file. Callbacks must not reenter the serialized macos APIs.
func WriteBackup(ctx context.Context, destination string, write func(io.Writer) error, verify func(io.Reader) error) error {
	if verify == nil {
		return ErrBackupWrite
	}
	err := writeSelectedFile(ctx, destination, backup.MaxCiphertextBytes, write, func(file *os.File, info os.FileInfo) error {
		return readBackupStream(ctx, file, info, verify)
	})
	return backupFileError(err, ErrBackupWrite)
}

// ReadBackup keeps the selected-file scope, coordination and descriptor alive
// for the entire streaming callback. No original bytes are retained here.
func ReadBackup(ctx context.Context, path string, read func(io.Reader) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if read == nil || !validExportPath(path) {
		return ErrBackupRead
	}
	err := native(ctx, func() error {
		url := send(class("NSURL"), "fileURLWithPath:", uintptr(nsString(path)))
		if url == 0 {
			return ErrBackupRead
		}
		if byte(send(url, "startAccessingSecurityScopedResource")) != 0 {
			defer send(url, "stopAccessingSecurityScopedResource")
		}
		parent, err := openExportDirectory(filepath.Dir(path))
		if err != nil {
			return ErrBackupRead
		}
		defer parent.Close()
		parentInfo, err := parent.Stat()
		if err != nil {
			return ErrBackupRead
		}
		before, err := exportTarget(path)
		if err != nil || before == nil || before.Size() <= 0 || before.Size() > backup.MaxCiphertextBytes {
			return ErrBackupRead
		}
		coordinator := send(alloc("NSFileCoordinator"), "initWithFilePresenter:", 0)
		if coordinator == 0 {
			return ErrBackupRead
		}
		defer release(coordinator)
		var nsError id
		var result error = ErrBackupRead
		accessor := objc.NewBlock(func(_ objc.Block, coordinatedURL id) {
			coordinatedPath, err := stringCopy(send(coordinatedURL, "path"), 1<<16)
			if err != nil || coordinatedPath != path {
				return
			}
			result = readCoordinatedBackup(ctx, path, parentInfo, before, read)
		})
		defer accessor.Release()
		send(coordinator, "coordinateReadingItemAtURL:options:error:byAccessor:", uintptr(url), 1, uintptr(unsafe.Pointer(&nsError)), uintptr(accessor))
		if err := ctx.Err(); err != nil {
			return err
		}
		if nsError != 0 {
			return ErrBackupRead
		}
		return result
	})
	return backupFileError(err, ErrBackupRead)
}

func readCoordinatedBackup(ctx context.Context, path string, parentInfo, before os.FileInfo, read func(io.Reader) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return ErrBackupRead
	}
	file := os.NewFile(uintptr(fd), "")
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() || !sameBackupInfo(opened, before) {
		return ErrBackupRead
	}
	if err := readBackupStream(ctx, file, before, read); err != nil {
		return err
	}
	parent, err := os.Lstat(filepath.Dir(path))
	if err != nil || !parent.IsDir() || !os.SameFile(parent, parentInfo) || !sameExportTarget(path, before) {
		return ErrBackupRead
	}
	return nil
}

func readBackupStream(ctx context.Context, file *os.File, before os.FileInfo, read func(io.Reader) error) error {
	stream := &backupFileReader{ctx: ctx, reader: io.LimitReader(file, before.Size()+1)}
	if err := read(stream); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	// A successful callback must consume the complete selected file, even when
	// its inner parser treats an earlier format terminator as EOF.
	var tail [1]byte
	if n, err := stream.Read(tail[:]); stream.count != before.Size() || n != 0 || err != io.EOF {
		return ErrBackupRead
	}
	after, err := file.Stat()
	if err != nil || !sameBackupInfo(after, before) {
		return ErrBackupRead
	}
	return nil
}

func sameBackupInfo(a, b os.FileInfo) bool {
	return os.SameFile(a, b) && a.Size() == b.Size() && a.ModTime() == b.ModTime()
}

type backupFileReader struct {
	ctx    context.Context
	reader io.Reader
	count  int64
}

func (r *backupFileReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	n, err := r.reader.Read(p)
	r.count += int64(n)
	return n, err
}

func backupFileError(err, code error) error {
	if err == nil || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return err
	}
	return code
}
