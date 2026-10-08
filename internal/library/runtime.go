package library

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"syscall"
)

var (
	ErrRestoreInterrupted = errors.New("library_restore_interrupted")
	ErrRestoreFailed      = errors.New("library_restore_failed")
)

// Runtime owns the stable parent lease through normal use, degraded recovery,
// and activation. App commands must drain and close Store before activation.
type Runtime struct {
	mu                                sync.Mutex
	parent                            *os.Root
	parentFile, lease, oldLock        *os.File
	parentPath, rootName, oldIdentity string
	parentIdentity, leaseIdentity     os.FileInfo
	store                             *Store
	openErr                           error
	prepared                          *PreparedRestore
	journal                           *restoreJournal
	journalIdentity                   os.FileInfo
	journalData                       []byte
	sealed, closed                    bool
	checkpoint                        func(string)
}

// PreparedRestore is an in-process capability. Paths and ownership never come
// back from the UI; changing Summary cannot change the prepared transaction.
type PreparedRestore struct {
	Summary                                         SnapshotSummary
	owner                                           *Runtime
	stage, retained, identity, digest, schemaDigest string
	files                                           map[string]os.FileInfo
	used                                            bool
}

func OpenRuntime(path string) (*Runtime, error) { return openRuntime(path, nil) }

func acquireRuntime(path string, checkpoint func(string)) (_ *Runtime, err error) {
	path, err = filepath.Abs(path)
	if err != nil {
		return nil, ErrInvalid
	}
	parentPath := filepath.Dir(path)
	initialParent, e := os.Lstat(parentPath)
	if e != nil || !private(initialParent, true) {
		return nil, ErrCorrupt
	}
	parentPath, err = filepath.EvalSymlinks(parentPath)
	if err != nil {
		return nil, ErrCorrupt
	}
	r := &Runtime{parentPath: parentPath, rootName: filepath.Base(path), checkpoint: checkpoint}
	defer func() {
		if err != nil {
			r.Close()
		}
	}()
	r.parent, err = os.OpenRoot(parentPath)
	if err != nil {
		return nil, ErrCorrupt
	}
	r.parentIdentity, err = r.parent.Lstat(".")
	if err != nil || !private(r.parentIdentity, true) || !os.SameFile(initialParent, r.parentIdentity) {
		return nil, ErrCorrupt
	}
	r.parentFile, err = r.parent.OpenFile(".", os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, ErrCorrupt
	}
	r.lease, err = r.parent.OpenFile(".runtime.lock", os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0600)
	if err != nil {
		return nil, ErrCorrupt
	}
	r.leaseIdentity, err = r.lease.Stat()
	if err != nil || !private(r.leaseIdentity, false) {
		return nil, ErrCorrupt
	}
	if syscall.Flock(int(r.lease.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		return nil, ErrLocked
	}
	if err = r.checkParent(); err != nil {
		return nil, err
	}
	return r, nil
}

func openRuntime(path string, checkpoint func(string)) (_ *Runtime, err error) {
	r, err := acquireRuntime(path, checkpoint)
	if err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			r.Close()
		}
	}()
	if err = r.readJournal(); err != nil {
		return nil, err
	}
	if r.journal != nil {
		if err = r.reconcile(); err != nil {
			return nil, err
		}
		if r.journal != nil && r.journal.Phase == "interrupted" {
			return r, nil
		}
	}
	r.oldIdentity, err = r.directoryIdentity(r.rootName)
	if err != nil {
		return nil, err
	}
	// Check the old in-root lease even for contents Open rejects before locking.
	if r.oldIdentity != "" {
		lock, e := r.lockDirectory(r.rootName, r.oldIdentity)
		if e != nil {
			return nil, e
		}
		lock.Close()
	}
	r.store, err = Open(filepath.Join(r.parentPath, r.rootName))
	if err == nil {
		if r.oldIdentity != "" && r.oldIdentity != fileIdentity(r.store.identity) {
			return nil, ErrCorrupt
		}
		r.oldIdentity = fileIdentity(r.store.identity)
		if err = r.checkParent(); err != nil {
			return nil, err
		}
		return r, nil
	}
	if !errors.Is(err, ErrCorrupt) && !errors.Is(err, ErrUnsupported) {
		return nil, err
	}
	r.openErr = err
	currentIdentity, err := r.directoryIdentity(r.rootName)
	if err != nil || currentIdentity == "" || r.oldIdentity != "" && r.oldIdentity != currentIdentity {
		return nil, ErrCorrupt
	}
	r.oldIdentity = currentIdentity
	r.oldLock, err = r.lockDirectory(r.rootName, r.oldIdentity)
	if err != nil {
		return nil, err
	}
	return r, nil
}

func (r *Runtime) Store() *Store    { r.mu.Lock(); defer r.mu.Unlock(); return r.store }
func (r *Runtime) OpenError() error { r.mu.Lock(); defer r.mu.Unlock(); return r.openErr }

func (r *Runtime) reached(stage string) {
	if r.checkpoint != nil {
		r.checkpoint(stage)
	}
}

func (r *Runtime) checkParent() error {
	if r.parent == nil || r.parentFile == nil {
		return ErrClosed
	}
	current, err := os.Lstat(r.parentPath)
	if err != nil || !private(current, true) || !os.SameFile(current, r.parentIdentity) {
		return ErrCorrupt
	}
	opened, err := r.parentFile.Stat()
	if err != nil || !os.SameFile(opened, r.parentIdentity) {
		return ErrCorrupt
	}
	if r.leaseIdentity != nil {
		current, err = r.parent.Lstat(".runtime.lock")
		if err != nil || !private(current, false) || !os.SameFile(current, r.leaseIdentity) {
			return ErrCorrupt
		}
	}
	return nil
}

func (r *Runtime) directoryIdentity(name string) (string, error) {
	if err := r.checkParent(); err != nil {
		return "", err
	}
	info, err := r.parent.Lstat(name)
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil || !private(info, true) {
		return "", ErrCorrupt
	}
	return fileIdentity(info), nil
}

func (r *Runtime) lockDirectory(name, identity string) (*os.File, error) {
	if got, err := r.directoryIdentity(name); err != nil || identity == "" || got != identity {
		return nil, ErrCorrupt
	}
	root, err := r.parent.OpenRoot(name)
	if err != nil {
		return nil, ErrCorrupt
	}
	defer root.Close()
	lock, err := root.OpenFile(".owner.lock", os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0600)
	if err != nil {
		return nil, ErrCorrupt
	}
	ok := false
	defer func() {
		if !ok {
			lock.Close()
		}
	}()
	info, err := lock.Stat()
	if err != nil || !private(info, false) {
		return nil, ErrCorrupt
	}
	if syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		return nil, ErrLocked
	}
	current, err := root.Lstat(".owner.lock")
	if err != nil || !os.SameFile(info, current) {
		return nil, ErrCorrupt
	}
	if got, err := r.directoryIdentity(name); err != nil || got != identity {
		return nil, ErrCorrupt
	}
	ok = true
	return lock, nil
}

// PrepareRestore is cancellable and leaves the current Store available. The
// callback only populates the supplied fresh Store; it must not retain it.
func (r *Runtime) PrepareRestore(ctx context.Context, populate func(context.Context, *Store) error) (_ *PreparedRestore, err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.sealed {
		return nil, ErrClosed
	}
	if r.prepared != nil || populate == nil {
		return nil, ErrState
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	if err = r.checkParent(); err != nil {
		return nil, err
	}
	id := opaqueID()
	p := &PreparedRestore{owner: r, stage: "restore-stage-" + id, retained: "restore-retained-" + id, files: map[string]os.FileInfo{}}
	if err = r.parent.Mkdir(p.stage, 0700); err != nil {
		return nil, ErrStorage
	}
	p.identity, err = r.directoryIdentity(p.stage)
	if err != nil {
		return nil, err
	}
	if err = syncDirectory(r.parent); err != nil {
		return nil, err
	}
	s, err := Open(filepath.Join(r.parentPath, p.stage))
	if err != nil {
		return nil, err
	}
	p.files["library.sqlite"] = s.databaseIdentity
	p.files[".owner.lock"] = s.lockIdentity
	p.files["originals"] = s.originalIdentity
	s.restoreOwnedFiles = p.files
	defer func() {
		closeErr := s.Close()
		if err == nil && closeErr != nil {
			err = closeErr
		}
		if err != nil {
			_ = r.cleanupStage(p)
		}
	}()
	p.schemaDigest, err = runtimeSchemaDigest(s.db)
	if err != nil {
		return nil, err
	}
	if err = populate(ctx, s); err != nil {
		return nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	hash := sha256.New()
	p.Summary, err = s.WriteSnapshot(ctx, hash)
	if err != nil {
		return nil, err
	}
	p.digest = hex.EncodeToString(hash.Sum(nil))
	if digest, e := runtimeSchemaDigest(s.db); e != nil || digest != p.schemaDigest {
		return nil, ErrCorrupt
	}
	if err = s.Close(); err != nil {
		return nil, err
	}
	if err = r.checkStageFiles(p); err != nil {
		return nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	r.prepared = p
	return p, nil
}

func (r *Runtime) checkStageFiles(p *PreparedRestore) error {
	if got, err := r.directoryIdentity(p.stage); err != nil || got != p.identity {
		return ErrCorrupt
	}
	root, err := r.parent.OpenRoot(p.stage)
	if err != nil {
		return ErrCorrupt
	}
	defer root.Close()
	if info, e := root.Lstat("."); e != nil || fileIdentity(info) != p.identity {
		return ErrCorrupt
	}
	for _, dir := range []string{".", "originals"} {
		f, err := root.OpenFile(dir, os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
		if err != nil {
			return ErrCorrupt
		}
		for {
			entries, readErr := f.ReadDir(128)
			for _, entry := range entries {
				name := entry.Name()
				if dir != "." {
					name = dir + "/" + name
				}
				info, e := root.Lstat(name)
				owned := p.files[name]
				if e != nil || owned == nil || !private(info, name == "originals") || !os.SameFile(info, owned) {
					f.Close()
					return ErrCorrupt
				}
			}
			if errors.Is(readErr, io.EOF) {
				break
			}
			if readErr != nil {
				f.Close()
				return ErrCorrupt
			}
		}
		f.Close()
	}
	for name, owned := range p.files {
		info, e := root.Lstat(name)
		if e != nil || !private(info, name == "originals") || !os.SameFile(info, owned) {
			return ErrCorrupt
		}
	}
	return nil
}

func (r *Runtime) cleanupStage(p *PreparedRestore) error {
	// Check the complete receipt before deleting anything; unknown additions,
	// replacements and links keep the entire stage available for inspection.
	if err := r.checkStageFiles(p); err != nil {
		return err
	}
	root, err := r.parent.OpenRoot(p.stage)
	if err != nil {
		return ErrCorrupt
	}
	defer root.Close()
	if info, e := root.Lstat("."); e != nil || fileIdentity(info) != p.identity {
		return ErrCorrupt
	}
	for name, owned := range p.files {
		if name == "originals" {
			continue
		}
		info, e := root.Lstat(name)
		if e != nil || !os.SameFile(info, owned) {
			return ErrCorrupt
		}
		if e = root.Remove(name); e != nil {
			return ErrStorage
		}
	}
	if err = root.Remove("originals"); err != nil {
		return ErrStorage
	}
	if got, e := r.directoryIdentity(p.stage); e != nil || got != p.identity {
		return ErrCorrupt
	}
	if err = r.parent.Remove(p.stage); err != nil {
		return ErrStorage
	}
	return syncDirectory(r.parent)
}

func (r *Runtime) CancelRestore(p *PreparedRestore) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.sealed {
		return ErrClosed
	}
	if p == nil || p.owner != r || r.prepared != p || p.used {
		return ErrState
	}
	if err := r.cleanupStage(p); err != nil {
		return err
	}
	p.used = true
	r.prepared = nil
	return nil
}

// ActivateRestore cannot be cancelled. Success and failure after this boundary
// both require restart; only startup reconciliation can reopen business use.
func (r *Runtime) ActivateRestore(p *PreparedRestore) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.sealed {
		return ErrClosed
	}
	if p == nil || p.owner != r || r.prepared != p || p.used {
		return ErrState
	}
	if r.store != nil {
		r.store.mu.Lock()
		open := r.store.db != nil
		r.store.mu.Unlock()
		if open {
			return ErrState
		}
	}
	r.sealed = true
	p.used = true
	if err := r.checkStageFiles(p); err != nil {
		return err
	}
	if current, err := r.directoryIdentity(r.rootName); err != nil || current != r.oldIdentity {
		return ErrCorrupt
	}
	if r.oldIdentity != "" && r.oldLock == nil {
		var err error
		r.oldLock, err = r.lockDirectory(r.rootName, r.oldIdentity)
		if err != nil {
			return err
		}
	}
	candidateLock, err := r.lockDirectory(p.stage, p.identity)
	if err != nil {
		return err
	}
	defer candidateLock.Close()
	j := &restoreJournal{Version: 1, Root: r.rootName, Parent: fileIdentity(r.parentIdentity), ID: p.stage[len("restore-stage-"):], Candidate: p.identity, Old: r.oldIdentity, Digest: p.digest, Schema: p.schemaDigest, Phase: "prepared"}
	if err = r.verifyCandidate(p.stage, j); err != nil {
		return err
	}
	if r.journal != nil {
		if r.journal.Phase != "interrupted" {
			return ErrState
		}
		if err = r.checkLayout(r.journal); err != nil {
			return err
		}
	}
	if err = r.writeJournal(j); err != nil {
		return err
	}
	j.Phase = "retiring"
	if err = r.writeJournal(j); err != nil {
		return err
	}
	if j.Old != "" {
		if err = r.move(r.rootName, j.retained(), j.Old, "old"); err != nil {
			return err
		}
	}
	j.Phase = "installing"
	if err = r.writeJournal(j); err != nil {
		return err
	}
	if err = r.move(j.stage(), r.rootName, j.Candidate, "new"); err != nil {
		return err
	}
	if err = r.verifyCandidate(r.rootName, j); err != nil {
		return err
	}
	j.Phase = "committed"
	if err = r.writeJournal(j); err != nil {
		return err
	}
	return r.retireJournal()
}

func (r *Runtime) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return nil
	}
	r.closed = true
	var result error
	if r.prepared != nil && !r.prepared.used && r.parent != nil {
		if err := r.cleanupStage(r.prepared); err != nil {
			result = err
		}
	}
	if r.store != nil {
		if err := r.store.Close(); err != nil {
			result = err
		}
	}
	// Keep the stable lease until the Store and every recovery handle are closed.
	for _, f := range []*os.File{r.oldLock, r.parentFile} {
		if f != nil && f.Close() != nil {
			result = ErrStorage
		}
	}
	if r.parent != nil {
		if r.parent.Close() != nil {
			result = ErrStorage
		}
		r.parent = nil
	}
	if r.lease != nil {
		if r.lease.Close() != nil {
			result = ErrStorage
		}
		r.lease = nil
	}
	return result
}
