package app

import (
	"context"
	"errors"
	"io"
	"sync"

	"kinlogue/internal/backup"
	"kinlogue/internal/library"
)

var (
	ErrBackup  = errors.New("backup_failed")
	ErrRestore = errors.New("restore_failed")
)

// RestoreHandle identifies one preparation in one controller. The UI cannot
// supply a stage path or substitute a Runtime capability.
type RestoreHandle struct {
	owner      *BackupController
	generation uint64
}

type RestorePreparation struct {
	Handle  RestoreHandle
	Summary library.SnapshotSummary
}

// BackupController owns Runtime and, in normal mode, Service. Close this owner
// on exit; it drains work before releasing the stable parent lease. Recovery
// codes belong only to the current call and are never retained in this owner.
type BackupController struct {
	runtime           *library.Runtime
	service           *Service
	writeBackup       func(context.Context, string, func(io.Writer) error, func(io.Reader) error) error
	readBackup        func(context.Context, string, func(io.Reader) error) error
	shutdown          context.Context
	cancel            context.CancelFunc
	mu                sync.Mutex
	ops               sync.WaitGroup
	preparing, sealed bool
	prepared          *library.PreparedRestore
	generation        uint64
	activationDone    chan struct{}
	closeOnce         sync.Once
	closeError        error
}

func NewBackupController(runtime *library.Runtime, service *Service, write func(context.Context, string, func(io.Writer) error, func(io.Reader) error) error, read func(context.Context, string, func(io.Reader) error) error) *BackupController {
	b := NewRecoveryController(runtime, read)
	b.service, b.writeBackup = service, write
	return b
}

// NewRecoveryController admits preparation without fabricating a usable Store.
func NewRecoveryController(runtime *library.Runtime, read func(context.Context, string, func(io.Reader) error) error) *BackupController {
	ctx, cancel := context.WithCancel(context.Background())
	return &BackupController{runtime: runtime, readBackup: read, shutdown: ctx, cancel: cancel}
}

// startLocked registers work before Close can begin waiting for it.
func (b *BackupController) startLocked(ctx context.Context) (context.Context, func(), error) {
	if b.sealed {
		return nil, nil, ErrClosed
	}
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	b.ops.Add(1)
	c, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(b.shutdown, cancel)
	return c, func() { stop(); cancel(); b.ops.Done() }, nil
}

func (b *BackupController) CreateBackup(ctx context.Context, destination, code string) (library.SnapshotSummary, error) {
	b.mu.Lock()
	c, finish, err := b.startLocked(ctx)
	b.mu.Unlock()
	if err != nil {
		return library.SnapshotSummary{}, err
	}
	defer finish()
	if b.service == nil || b.writeBackup == nil {
		return library.SnapshotSummary{}, ErrBackup
	}
	return command(b.service, c, true, func(c context.Context) (library.SnapshotSummary, error) {
		var summary library.SnapshotSummary
		if _, err := backup.ValidateCode(code); err != nil {
			return summary, err
		}
		var digest [32]byte
		err := b.writeBackup(c, destination, func(w io.Writer) error {
			var err error
			digest, err = backup.Encrypt(c, w, code, func(w io.Writer) error {
				var err error
				summary, err = b.service.store.WriteSnapshot(c, w)
				return err
			})
			return err
		}, func(r io.Reader) error {
			return backup.Verify(c, r, code, digest, func(r io.Reader) error {
				_, err := library.VerifySnapshot(c, r)
				return err
			})
		})
		// Nil means the native atomic publication committed. A later shutdown
		// cancellation must not turn that published backup into a reported failure.
		if err != nil {
			return library.SnapshotSummary{}, backupOperationError(c, err, ErrBackup)
		}
		return summary, nil
	})
}

func (b *BackupController) PrepareRestore(ctx context.Context, path, code string) (RestorePreparation, error) {
	b.mu.Lock()
	if b.sealed {
		b.mu.Unlock()
		return RestorePreparation{}, ErrClosed
	}
	if b.preparing || b.prepared != nil {
		b.mu.Unlock()
		return RestorePreparation{}, library.ErrState
	}
	c, finish, err := b.startLocked(ctx)
	if err != nil {
		b.mu.Unlock()
		return RestorePreparation{}, err
	}
	b.preparing = true
	b.mu.Unlock()
	defer finish()
	defer func() { b.mu.Lock(); b.preparing = false; b.mu.Unlock() }()
	if _, err := backup.ValidateCode(code); err != nil {
		return RestorePreparation{}, err
	}
	if b.readBackup == nil {
		return RestorePreparation{}, ErrRestore
	}
	prepared, err := b.runtime.PrepareRestore(c, func(c context.Context, store *library.Store) error {
		return b.readBackup(c, path, func(r io.Reader) error {
			return backup.Decrypt(c, r, code, func(r io.Reader) error {
				_, err := store.RestoreSnapshot(c, r)
				return err
			})
		})
	})
	if err != nil {
		return RestorePreparation{}, backupOperationError(c, err, ErrRestore)
	}
	b.mu.Lock()
	if b.sealed || c.Err() != nil {
		b.mu.Unlock()
		_ = b.runtime.CancelRestore(prepared)
		if err := c.Err(); err != nil {
			return RestorePreparation{}, err
		}
		return RestorePreparation{}, ErrClosed
	}
	b.generation++
	b.prepared = prepared
	result := RestorePreparation{Handle: RestoreHandle{b, b.generation}, Summary: prepared.Summary}
	b.mu.Unlock()
	return result, nil
}

func (b *BackupController) validHandle(handle RestoreHandle) bool {
	return b.prepared != nil && handle.owner == b && handle.generation == b.generation
}

func (b *BackupController) CancelRestore(handle RestoreHandle) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.sealed {
		return ErrClosed
	}
	if !b.validHandle(handle) {
		return library.ErrState
	}
	if err := b.runtime.CancelRestore(b.prepared); err != nil {
		return backupOperationError(context.Background(), err, ErrRestore)
	}
	b.prepared = nil
	return nil
}

// ActivateRestore must run outside Service command. Once it accepts the handle,
// restartRequired is true on success AND failure, and cancellation is disabled.
func (b *BackupController) ActivateRestore(handle RestoreHandle) (restartRequired bool, err error) {
	b.mu.Lock()
	if b.sealed {
		restartRequired := b.activationDone != nil
		b.mu.Unlock()
		return restartRequired, ErrClosed
	}
	if !b.validHandle(handle) {
		b.mu.Unlock()
		return false, library.ErrState
	}
	b.sealed = true
	b.cancel()
	if b.service != nil {
		b.service.seal()
	}
	prepared := b.prepared
	b.activationDone = make(chan struct{})
	done := b.activationDone
	b.mu.Unlock()
	defer close(done)
	b.ops.Wait()
	if b.service != nil {
		if err := b.service.Close(); err != nil {
			return true, ErrRestore
		}
	}
	err = b.runtime.ActivateRestore(prepared)
	return true, backupOperationError(context.Background(), err, ErrRestore)
}

func (b *BackupController) Close() error {
	b.closeOnce.Do(func() {
		b.mu.Lock()
		b.sealed = true
		b.cancel()
		if b.service != nil {
			b.service.seal()
		}
		activation := b.activationDone
		b.mu.Unlock()
		if activation != nil {
			<-activation
		}
		b.ops.Wait()
		if b.service != nil {
			b.closeError = b.service.Close()
		}
		if err := b.runtime.Close(); err != nil {
			b.closeError = err
		}
	})
	return b.closeError
}

func backupOperationError(ctx context.Context, err, fallback error) error {
	if err == nil {
		return nil
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	for _, known := range []error{context.Canceled, context.DeadlineExceeded, backup.ErrCode, backup.ErrInvalid, backup.ErrLimit, library.ErrState, library.ErrCorrupt, library.ErrUnsupported, library.ErrClosed} {
		if errors.Is(err, known) {
			return known
		}
	}
	return fallback
}
