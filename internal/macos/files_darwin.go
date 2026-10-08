//go:build darwin

package macos

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"github.com/ebitengine/purego/objc"
	"kinlogue/internal/document"
)

var ErrIdentity = errors.New("untrusted_application_identity")
var ErrRead = errors.New("import_read_failed")

// LibraryRoot accepts only the separately packaged preview identity, then asks
// Foundation for the sandbox-aware Application Support URL. There is no HOME,
// current-directory, command-line or environment override of this root.
func LibraryRoot() (string, error) {
	var root string
	err := native(context.Background(), func() error {
		bundle := send(class("NSBundle"), "mainBundle")
		identity, err := stringCopy(send(bundle, "bundleIdentifier"), 256)
		if err != nil || identity != "com.kinlogue.mac.gopreview" {
			return ErrIdentity
		}
		manager := send(class("NSFileManager"), "defaultManager")
		var nsError id
		url := send(manager, "URLForDirectory:inDomain:appropriateForURL:create:error:", 14, 1, 0, 1, uintptr(unsafe.Pointer(&nsError)))
		if url == 0 || nsError != 0 {
			return document.ErrUnavailable
		}
		base, err := stringCopy(send(url, "path"), 1<<16)
		if err != nil || !filepath.IsAbs(base) || filepath.Clean(base) != base {
			return ErrIdentity
		}
		if err := ensurePreviewParent(base); err != nil {
			return err
		}
		for _, component := range []string{"KinlogueGoPreview", "Library"} {
			url = send(url, "URLByAppendingPathComponent:isDirectory:", uintptr(nsString(component)), 1)
		}
		root, err = stringCopy(send(url, "path"), 1<<16)
		if err != nil || !filepath.IsAbs(root) || filepath.Clean(root) != root {
			return ErrIdentity
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	return root, nil
}

func ensurePreviewParent(base string) error {
	root, err := os.OpenRoot(base)
	if err != nil {
		return document.ErrUnavailable
	}
	defer root.Close()
	if err := root.Mkdir("KinlogueGoPreview", 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return document.ErrUnavailable
	}
	info, err := root.Lstat("KinlogueGoPreview")
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return ErrIdentity
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return ErrIdentity
	}
	return nil
}

// PreferredLanguage resolves the OS preference to one of the preview's two
// resource catalogs. Failure safely falls back to English.
func PreferredLanguage() string {
	language := "en"
	_ = native(context.Background(), func() error {
		languages := send(class("NSLocale"), "preferredLanguages")
		count := min(int(send(languages, "count")), 64)
		for index := 0; index < count; index++ {
			candidate, err := stringCopy(send(languages, "objectAtIndex:", uintptr(index)), 128)
			if err != nil {
				continue
			}
			if strings.HasPrefix(candidate, "zh") {
				language = "zh-Hans"
				break
			}
			if strings.HasPrefix(candidate, "en") {
				break
			}
		}
		return nil
	})
	return language
}

// ReadImportedFile scopes and coordinates the copy of a user-selected file.
// Selection must come from the system open panel; path strings are never used
// to grant access independently. All errors are stable and content/path-free.
func ReadImportedFile(path string) ([]byte, error) {
	if !filepath.IsAbs(path) || strings.IndexByte(path, 0) >= 0 || len(path) > 1<<16 {
		return nil, ErrRead
	}
	var data []byte
	err := native(context.Background(), func() error {
		url := send(class("NSURL"), "fileURLWithPath:", uintptr(nsString(path)))
		if url == 0 {
			return ErrRead
		}
		scoped := byte(send(url, "startAccessingSecurityScopedResource")) != 0
		if scoped {
			defer send(url, "stopAccessingSecurityScopedResource")
		}
		// Scope covers metadata and the copy. Reject special files before asking
		// file coordination to wait, then recheck the actual descriptor below.
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() {
			return ErrRead
		}
		if info.Size() > document.MaxFileBytes {
			return document.ErrLimit
		}
		// A false scope result is also normal for already-accessible files and
		// tests. The actual read remains subject to macOS sandbox enforcement.
		coordinator := send(alloc("NSFileCoordinator"), "initWithFilePresenter:", 0)
		if coordinator == 0 {
			return ErrRead
		}
		defer release(coordinator)
		var nsError id
		var readErr error = ErrRead
		accessor := objc.NewBlock(func(_ objc.Block, coordinatedURL id) {
			coordinatedPath, e := stringCopy(send(coordinatedURL, "path"), 1<<16)
			if e != nil {
				readErr = ErrRead
				return
			}
			data, readErr = readRegular(coordinatedPath)
		})
		defer accessor.Release()
		// ReadingWithoutChanges; never ResolvesSymbolicLink. O_NOFOLLOW remains
		// authoritative after any rename race during coordination.
		send(coordinator, "coordinateReadingItemAtURL:options:error:byAccessor:", uintptr(url), 1, uintptr(unsafe.Pointer(&nsError)), uintptr(accessor))
		if nsError != 0 {
			return ErrRead
		}
		return readErr
	})
	if err != nil {
		return nil, err
	}
	return data, nil
}

func readRegular(path string) ([]byte, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, ErrRead
	}
	file := os.NewFile(uintptr(fd), "")
	defer file.Close()
	before, err := file.Stat()
	if err != nil || !before.Mode().IsRegular() {
		return nil, ErrRead
	}
	if before.Size() > document.MaxFileBytes {
		return nil, document.ErrLimit
	}
	data, err := io.ReadAll(io.LimitReader(file, document.MaxFileBytes+1))
	if err != nil {
		return nil, ErrRead
	}
	if len(data) > document.MaxFileBytes {
		return nil, document.ErrLimit
	}
	after, err := file.Stat()
	if err != nil || after.Size() != before.Size() || after.ModTime() != before.ModTime() || int64(len(data)) != after.Size() {
		return nil, ErrRead
	}
	return data, nil
}
