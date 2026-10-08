package library

import "golang.org/x/sys/unix"

func renameRuntimeExclusive(fd int, from, to string) error {
	return unix.RenameatxNp(fd, from, fd, to, unix.RENAME_EXCL)
}
