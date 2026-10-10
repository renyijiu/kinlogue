package desktop

import (
	"context"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"kinlogue/internal/app"
	"kinlogue/internal/backup"
	"kinlogue/internal/library"
	"kinlogue/internal/macos"
)

// Recovery has its own backend so an unavailable library never needs a fake
// ordinary service. Main owns closing the controller after the window exits.
type BackupBackend interface {
	CreateBackup(context.Context, string, string) (library.SnapshotSummary, error)
	PrepareRestore(context.Context, string, string) (app.RestorePreparation, error)
	CancelRestore(app.RestoreHandle) error
	ActivateRestore(app.RestoreHandle) (bool, error)
}

type backupFlow struct {
	generation                        uint64
	step, code, input, publicID, path string
	prepared                          *app.RestorePreparation
}

func newRecoveryScreen(backend BackupBackend, language string) *screen {
	s := newScreen(nil, language)
	s.backups, s.recoveryOnly, s.backupPage = backend, true, true
	return s
}

func RunRecovery(backend BackupBackend) error {
	return newRecoveryScreen(backend, macos.PreferredLanguage()).run()
}

func (s *screen) showBackup() {
	s.clearReport()
	s.backupPage, s.message = true, ""
	s.phonePage = false
	s.stopPhoneRefresh()
	s.phone.generation++
}

func (s *screen) clearBackupSecrets() {
	s.backup.code, s.backup.input, s.backup.path = "", "", ""
	// mygo's setText preserves Undo. Identity, not an empty binding, separates
	// sensitive editors across attempts and steps.
	s.backup.generation++
}

func (s *screen) resetBackup() {
	s.clearBackupSecrets()
	s.backup.step, s.backup.publicID, s.backup.prepared = "", "", nil
}

func (s *screen) backupIdle() bool {
	return s.backups != nil && s.backupPage && !s.restartOnly && !s.activating && s.busy == "" && s.shutdown == nil && !s.closed && !s.allowClose
}

func (s *screen) startBackup() {
	if !s.backupIdle() || s.recoveryOnly || s.backup.step != "" {
		return
	}
	s.resetBackup()
	code, err := backup.NewCode()
	if err != nil {
		s.message = "backup_failed"
		return
	}
	id, err := backup.ValidateCode(code)
	if err != nil {
		s.message = "backup_failed"
		return
	}
	s.backup.code, s.backup.publicID, s.backup.step, s.message = code, id, "generated", ""
}

func (s *screen) acknowledgeCode() {
	if !s.backupIdle() || s.backup.step != "generated" {
		return
	}
	s.backup.input, s.backup.step = "", "reentry"
	s.backup.generation++
}

func (s *screen) codeMatches() bool {
	return s.backup.code != "" && strings.TrimSpace(s.backup.input) == s.backup.code
}

func (s *screen) chooseBackupDestination() {
	parent, title := s.win, s.t("backup_create")
	s.createBackup(func(name string) (string, error) {
		return mygo.Dialog.Save(mygo.SaveDialogOptions{Parent: parent, Title: title, DefaultPath: name, Filters: []mygo.FileFilter{{Name: title, Extensions: []string{"kinloguegobackup"}}}, CreateDirectories: true})
	})
}

func (s *screen) createBackup(choose func(string) (string, error)) {
	if !s.backupIdle() || s.backup.step != "reentry" || !s.codeMatches() || s.composing {
		return
	}
	code := s.backup.code
	// NSSavePanel adds the extension from its content-type filter.
	name := "Kinlogue-" + time.Now().Format("2006-01-02") + "-" + s.backup.publicID
	s.clearBackupSecrets()
	s.backup.step, s.message = "creating", ""
	s.job("backup_creating", true, func(ctx context.Context) func() {
		destination, err := choose(name)
		key := "backup_cancelled"
		if err != nil {
			key = "backup_failed"
		} else if destination != "" && ctx.Err() == nil {
			_, err = s.backups.CreateBackup(ctx, destination, code)
			key = "backup_created"
			if err != nil {
				key = errorKey(err, "backup_failed")
			}
		}
		code = ""
		return func() { s.resetBackup(); s.message = key }
	})
}

func (s *screen) chooseRestoreFile() {
	parent, title, detail := s.win, s.t("restore_choose"), s.t("restore_file_detail")
	s.restoreFile(func() (string, error) {
		paths, err := mygo.Dialog.Open(mygo.OpenDialogOptions{Parent: parent, Title: title, Message: detail, Filters: []mygo.FileFilter{{Name: title, Extensions: []string{"kinloguegobackup"}}}})
		if err != nil || len(paths) != 1 {
			return "", err
		}
		return paths[0], nil
	})
}

func (s *screen) restoreFile(choose func() (string, error)) {
	if !s.backupIdle() || s.backup.step != "" {
		return
	}
	s.resetBackup()
	generation := s.backup.generation
	s.message = ""
	s.job("restore_choosing", false, func(ctx context.Context) func() {
		path, err := choose()
		cancelled := ctx.Err() != nil
		return func() {
			if generation != s.backup.generation || s.shutdown != nil {
				return
			}
			if err != nil {
				s.message = "restore_failed"
				return
			}
			if path == "" || cancelled {
				s.message = "restore_cancelled"
				return
			}
			s.backup.path, s.backup.step = path, "restore_code"
		}
	})
}

func (s *screen) prepareRestore() {
	if !s.backupIdle() || s.backup.step != "restore_code" || strings.TrimSpace(s.backup.input) == "" || s.composing {
		return
	}
	path, code := s.backup.path, s.backup.input
	s.clearBackupSecrets()
	generation := s.backup.generation
	s.backup.step, s.message = "preparing", ""
	s.job("restore_preparing", true, func(ctx context.Context) func() {
		prepared, err := s.backups.PrepareRestore(ctx, path, code)
		code, path = "", ""
		cancelled := ctx.Err() != nil
		return func() {
			if err == nil && (generation != s.backup.generation || s.cancelling || s.shutdown != nil || cancelled) {
				s.cancelPreparation(prepared, generation)
				return
			}
			if generation != s.backup.generation {
				return
			}
			if err != nil {
				s.resetBackup()
				s.message = errorKey(err, "restore_failed")
				return
			}
			s.backup.prepared, s.backup.step = &prepared, "prepared"
		}
	})
}

func (s *screen) cancelPreparation(prepared app.RestorePreparation, generation uint64) {
	// Keep entered cleanup visible to Quit. It retires only this exact handle;
	// a late result must never reset a newer flow.
	shutdown := s.shutdown
	s.shutdown = nil
	s.job("restore_cancelling", false, func(context.Context) func() {
		err := s.backups.CancelRestore(prepared.Handle)
		return func() {
			if generation == s.backup.generation {
				if err != nil {
					s.backup.prepared, s.backup.step, s.message = &prepared, "prepared", "restore_cancel_failed"
				} else {
					s.resetBackup()
					s.message = "restore_cancelled"
				}
			}
		}
	})
	s.shutdown = shutdown
}

func (s *screen) cancelBackup() {
	if !s.backupIdle() {
		return
	}
	if s.backup.prepared != nil {
		s.cancelPreparation(*s.backup.prepared, s.backup.generation)
		return
	}
	s.resetBackup()
	s.message = ""
}

func (s *screen) activateRestore() {
	if !s.backupIdle() || s.backup.step != "prepared" || s.backup.prepared == nil {
		return
	}
	handle := s.backup.prepared.Handle
	s.activating, s.message = true, ""
	s.updateChrome()
	s.job("restore_activating", false, func(context.Context) func() {
		restart, err := s.backups.ActivateRestore(handle)
		return func() {
			s.activating = false
			if restart {
				s.restartOnly = true
				s.resetBackup()
				s.clearReport()
				s.members, s.drafts, s.records = nil, nil, nil
				s.message = "restore_restart"
				if err != nil {
					s.message = "restore_restart_failed"
				}
			} else {
				s.message = "restore_failed"
			}
			s.updateChrome()
		}
	})
}
