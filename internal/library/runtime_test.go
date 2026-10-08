package library

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func runtimeTestRoot(t *testing.T) string {
	t.Helper()
	parent := filepath.Join(t.TempDir(), "private")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	return filepath.Join(parent, "Library")
}

func runtimeSnapshot(t *testing.T) []byte {
	t.Helper()
	s, _ := openTest(t)
	if _, err := s.AddMember(ctx, "Synthetic restored member"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateDraftSources(ctx, []string{"synthetic.pdf"}, func(int) ([]byte, error) { return []byte("synthetic original"), nil }); err != nil {
		t.Fatal(err)
	}
	var b bytes.Buffer
	if _, err := s.WriteSnapshot(ctx, &b); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func prepareRuntime(t *testing.T, r *Runtime, data []byte) *PreparedRestore {
	t.Helper()
	p, err := r.PrepareRestore(ctx, func(c context.Context, s *Store) error {
		_, err := s.RestoreSnapshot(c, bytes.NewReader(data))
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestRuntimePrepareCancelAndActivate(t *testing.T) {
	root := runtimeTestRoot(t)
	r, err := OpenRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if _, err := r.Store().AddMember(ctx, "Synthetic old member"); err != nil {
		t.Fatal(err)
	}
	data := runtimeSnapshot(t)
	p := prepareRuntime(t, r, data)
	if p.Summary.Members != 1 || p.Summary.Reports != 1 || p.Summary.Sources != 1 {
		t.Fatal("summary lost restored graph")
	}
	if err := r.ActivateRestore(p); !errors.Is(err, ErrState) {
		t.Fatal("activation must require closed store")
	}
	if err := r.CancelRestore(p); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(filepath.Dir(root), p.stage)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("owned cancelled stage remains")
	}
	if members, err := r.Store().Members(ctx); err != nil || len(members) != 1 || members[0].Name != "Synthetic old member" {
		t.Fatal("preparation changed old data")
	}
	p = prepareRuntime(t, r, data)
	if err := r.Store().Close(); err != nil {
		t.Fatal(err)
	}
	if err := r.ActivateRestore(p); err != nil {
		t.Fatal(err)
	}
	if _, err := r.PrepareRestore(ctx, nil); !errors.Is(err, ErrClosed) {
		t.Fatal("activation did not seal runtime")
	}
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		r, err = OpenRuntime(root)
		if err != nil {
			t.Fatal(err)
		}
		members, err := r.Store().Members(ctx)
		if err != nil || len(members) != 1 || members[0].Name != "Synthetic restored member" {
			t.Fatal("restore lost new data")
		}
		if err := r.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestRuntimeLocksAndDegradedOpen(t *testing.T) {
	root := runtimeTestRoot(t)
	r, err := OpenRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	if other, err := OpenRuntime(root); !errors.Is(err, ErrLocked) {
		if other != nil {
			other.Close()
		}
		t.Fatal("parent lease not held")
	}
	r.Close()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	if other, err := OpenRuntime(root); !errors.Is(err, ErrLocked) {
		if other != nil {
			other.Close()
		}
		t.Fatal("old binary lock not checked")
	}
	s.Close()
	if err := os.WriteFile(filepath.Join(root, "unknown"), []byte("synthetic opaque old data"), 0600); err != nil {
		t.Fatal(err)
	}
	r, err = OpenRuntime(root)
	if err != nil || r.Store() != nil || !errors.Is(r.OpenError(), ErrUnsupported) {
		t.Fatal("content error lost recovery entry")
	}
	defer r.Close()
	if old, err := Open(root); err == nil {
		old.Close()
		t.Fatal("degraded runtime released old lock")
	}
	p := prepareRuntime(t, r, runtimeSnapshot(t))
	if err := r.ActivateRestore(p); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(filepath.Join(filepath.Dir(root), p.retained, "unknown")); err != nil || string(data) != "synthetic opaque old data" {
		t.Fatal("opaque old tree not preserved")
	}
}

func TestRuntimeCancelRejectsReplacementAndUnknownContent(t *testing.T) {
	for _, damage := range []string{"extra", "symlink", "replaced"} {
		t.Run(damage, func(t *testing.T) {
			root := runtimeTestRoot(t)
			r, err := OpenRuntime(root)
			if err != nil {
				t.Fatal(err)
			}
			defer r.Close()
			p := prepareRuntime(t, r, runtimeSnapshot(t))
			stage := filepath.Join(filepath.Dir(root), p.stage)
			switch damage {
			case "extra":
				err = os.WriteFile(filepath.Join(stage, "unknown"), []byte("synthetic"), 0600)
			case "symlink":
				err = os.Symlink(t.TempDir(), filepath.Join(stage, "unknown"))
			case "replaced":
				err = os.Rename(stage, stage+"-saved")
				if err == nil {
					err = os.Mkdir(stage, 0700)
				}
			}
			if err != nil {
				t.Fatal(err)
			}
			if err := r.CancelRestore(p); !errors.Is(err, ErrCorrupt) {
				t.Fatal("unsafe stage cleanup accepted")
			}
			if _, err := os.Lstat(stage); err != nil {
				t.Fatal("unsafe stage removed")
			}
		})
	}
}

func TestRuntimeCancelledPreparationCleansOwnedPartialFiles(t *testing.T) {
	root := runtimeTestRoot(t)
	r, err := OpenRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	data := runtimeSnapshot(t)
	_, err = r.PrepareRestore(ctx, func(c context.Context, s *Store) error {
		_, err := s.RestoreSnapshot(c, bytes.NewReader(data[:len(data)-513]))
		return err
	})
	if err == nil {
		t.Fatal("truncated snapshot accepted")
	}
	entries, err := os.ReadDir(filepath.Dir(root))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if len(entry.Name()) > 14 && entry.Name()[:14] == "restore-stage-" {
			t.Fatal("failed preparation retained owned plaintext")
		}
	}
	if _, err := r.Store().AddMember(ctx, "Synthetic still writable"); err != nil {
		t.Fatal("failed preparation disabled old store")
	}
}

func TestRuntimeCrashHelper(t *testing.T) {
	stage := os.Getenv("KINLOGUE_TEST_RESTORE_STAGE")
	if stage == "" {
		return
	}
	root := os.Getenv("KINLOGUE_TEST_RESTORE_ROOT")
	checkpoint := func(current string) {
		if current == stage {
			fmt.Fprintln(os.Stdout, "restore checkpoint reached")
			killAtCheckpoint(t)
		}
	}
	if os.Getenv("KINLOGUE_TEST_RESTORE_ACTION") == "reconcile" {
		r, err := openRuntime(root, checkpoint)
		if r != nil {
			r.Close()
		}
		t.Fatalf("reconcile checkpoint not reached: %v", err)
	}
	var r *Runtime
	var err error
	if os.Getenv("KINLOGUE_TEST_RESTORE_ABSENT") == "1" {
		r, err = acquireRuntime(root, checkpoint)
	} else {
		r, err = openRuntime(root, checkpoint)
	}
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(os.Getenv("KINLOGUE_TEST_RESTORE_SNAPSHOT"))
	if err != nil {
		t.Fatal(err)
	}
	p := prepareRuntime(t, r, data)
	if r.Store() != nil {
		r.Store().Close()
	}
	err = r.ActivateRestore(p)
	r.Close()
	t.Fatalf("activation checkpoint not reached: %v", err)
}

func runRuntimeKill(t *testing.T, root, snapshot, stage, action string, absent bool) {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	lifetime, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	command := exec.CommandContext(lifetime, executable, "-test.run=^TestRuntimeCrashHelper$")
	command.Env = append(os.Environ(), "KINLOGUE_TEST_RESTORE_ROOT="+root, "KINLOGUE_TEST_RESTORE_SNAPSHOT="+snapshot, "KINLOGUE_TEST_RESTORE_STAGE="+stage, "KINLOGUE_TEST_RESTORE_ACTION="+action)
	if absent {
		command.Env = append(command.Env, "KINLOGUE_TEST_RESTORE_ABSENT=1")
	}
	output, err := command.CombinedOutput()
	assertCheckpointKilled(t, lifetime, output, err, "restore checkpoint reached")
}

func TestRuntimeRecoversAfterProcessKill(t *testing.T) {
	for _, absent := range []bool{false, true} {
		for _, stage := range []string{"journal_prepared_published", "journal_prepared", "journal_retiring_staged", "journal_retiring_published", "journal_retiring", "renamed_old", "synced_old", "journal_installing_staged", "journal_installing_published", "journal_installing", "renamed_new", "synced_new", "journal_committed_staged", "journal_committed_published", "journal_committed", "removed_journal", "retired_journal"} {
			if absent && (stage == "renamed_old" || stage == "synced_old") {
				continue
			}
			t.Run(fmt.Sprintf("%t_%s", absent, stage), func(t *testing.T) {
				root := runtimeTestRoot(t)
				if !absent {
					s, err := Open(root)
					if err != nil {
						t.Fatal(err)
					}
					s.AddMember(ctx, "Synthetic old member")
					s.Close()
				}
				snapshot := filepath.Join(t.TempDir(), "synthetic.snapshot")
				if err := os.WriteFile(snapshot, runtimeSnapshot(t), 0600); err != nil {
					t.Fatal(err)
				}
				runRuntimeKill(t, root, snapshot, stage, "activate", absent)
				for range 2 {
					r, err := OpenRuntime(root)
					if err != nil {
						t.Fatal(err)
					}
					committed := stage == "journal_committed_published" || stage == "journal_committed" || stage == "removed_journal" || stage == "retired_journal"
					if absent && !committed {
						if r.Store() != nil || !errors.Is(r.OpenError(), ErrRestoreInterrupted) {
							t.Fatal("absent rollback masked by empty initialization")
						}
						if _, err := os.Lstat(root); !errors.Is(err, os.ErrNotExist) {
							t.Fatal("absent rollback created root")
						}
					} else {
						members, err := r.Store().Members(ctx)
						expected := "Synthetic old member"
						if committed {
							expected = "Synthetic restored member"
						}
						if err != nil || len(members) != 1 || members[0].Name != expected {
							t.Fatal("restart exposed mixed or wrong library")
						}
					}
					r.Close()
				}
			})
		}
	}
}

func createRuntimeCrash(t *testing.T, absent bool, stage string) (string, string) {
	t.Helper()
	root := runtimeTestRoot(t)
	if !absent {
		s, err := Open(root)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.AddMember(ctx, "Synthetic old member"); err != nil {
			t.Fatal(err)
		}
		if err := s.Close(); err != nil {
			t.Fatal(err)
		}
	}
	snapshot := filepath.Join(t.TempDir(), "synthetic.snapshot")
	if err := os.WriteFile(snapshot, runtimeSnapshot(t), 0600); err != nil {
		t.Fatal(err)
	}
	runRuntimeKill(t, root, snapshot, stage, "activate", absent)
	return root, snapshot
}

func TestRuntimeRecoveryItselfSurvivesProcessKill(t *testing.T) {
	for _, absent := range []bool{false, true} {
		stages := []string{"journal_rolling_back_staged", "journal_rolling_back_published", "journal_rolling_back", "renamed_rollback_candidate", "synced_rollback_candidate"}
		if absent {
			stages = append(stages, "journal_interrupted_staged", "journal_interrupted_published", "journal_interrupted")
		} else {
			stages = append(stages, "renamed_rollback_old", "synced_rollback_old", "removed_journal", "retired_journal")
		}
		for _, stage := range stages {
			t.Run(fmt.Sprintf("%t_%s", absent, stage), func(t *testing.T) {
				root, snapshot := createRuntimeCrash(t, absent, "synced_new")
				runRuntimeKill(t, root, snapshot, stage, "reconcile", absent)
				for range 2 {
					r, err := OpenRuntime(root)
					if err != nil {
						t.Fatal(err)
					}
					if absent {
						if r.Store() != nil || !errors.Is(r.OpenError(), ErrRestoreInterrupted) {
							t.Fatal("restarted rollback initialized absent root")
						}
					} else {
						members, err := r.Store().Members(ctx)
						if err != nil || len(members) != 1 || members[0].Name != "Synthetic old member" {
							t.Fatal("restarted rollback lost old state")
						}
					}
					r.Close()
				}
			})
		}
	}
}

func TestRuntimeCommittedCorruptionRollsBackWithoutAdoption(t *testing.T) {
	for _, damage := range []string{"original", "database", "missing_database", "schema", "version", "orphan", "unknown"} {
		t.Run(damage, func(t *testing.T) {
			root, _ := createRuntimeCrash(t, false, "journal_committed")
			var err error
			switch damage {
			case "original":
				files, e := os.ReadDir(filepath.Join(root, "originals"))
				if e != nil || len(files) != 1 {
					t.Fatal("missing synthetic original")
				}
				err = os.WriteFile(filepath.Join(root, "originals", files[0].Name()), []byte("synthetic modified"), 0600)
			case "database":
				err = os.WriteFile(filepath.Join(root, "library.sqlite"), []byte("synthetic damaged database"), 0600)
			case "missing_database":
				err = os.Remove(filepath.Join(root, "library.sqlite"))
			case "schema", "version":
				db, e := sql.Open("sqlite", filepath.Join(root, "library.sqlite"))
				if e != nil {
					t.Fatal(e)
				}
				query := "CREATE TABLE unexpected(value TEXT)"
				if damage == "version" {
					query = "PRAGMA user_version=2"
				}
				_, err = db.Exec(query)
				db.Close()
			case "orphan":
				err = os.WriteFile(filepath.Join(root, "originals", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.blob"), []byte("synthetic orphan"), 0600)
			case "unknown":
				err = os.WriteFile(filepath.Join(root, "unexpected"), []byte("synthetic"), 0600)
			}
			if err != nil {
				t.Fatal(err)
			}
			for attempt := range 2 {
				r, err := OpenRuntime(root)
				if err != nil {
					t.Fatal(err)
				}
				if attempt == 0 && !errors.Is(r.OpenError(), ErrRestoreFailed) {
					t.Fatal("corrupt committed candidate lost failure warning")
				}
				members, err := r.Store().Members(ctx)
				if err != nil || len(members) != 1 || members[0].Name != "Synthetic old member" {
					t.Fatal("invalid candidate adopted instead of old state")
				}
				r.Close()
			}
		})
	}
}

func TestRuntimeAbsentInterruptedCanPrepareAgain(t *testing.T) {
	root, _ := createRuntimeCrash(t, true, "synced_new")
	r, err := OpenRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	p := prepareRuntime(t, r, runtimeSnapshot(t))
	if err := r.CancelRestore(p); err != nil {
		t.Fatal(err)
	}
	r.Close()
	r, err = OpenRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	if r.Store() != nil || !errors.Is(r.OpenError(), ErrRestoreInterrupted) {
		t.Fatal("cancel forgot absent interruption")
	}
	p = prepareRuntime(t, r, runtimeSnapshot(t))
	if err := r.ActivateRestore(p); err != nil {
		t.Fatal(err)
	}
	r.Close()
	r, err = OpenRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if r.Store() == nil || r.OpenError() != nil {
		t.Fatal("confirmed restore did not resolve absent interruption")
	}
}

func TestRuntimeUnsafePathsAndReceiptNeverInitialize(t *testing.T) {
	for _, damage := range []string{"parent_symlink", "parent_public", "root_symlink", "root_public", "lock_symlink", "receipt_corrupt", "receipt_symlink", "stage_replaced", "old_missing"} {
		t.Run(damage, func(t *testing.T) {
			root := runtimeTestRoot(t)
			if strings.HasPrefix(damage, "receipt") || damage == "stage_replaced" || damage == "old_missing" {
				root, _ = createRuntimeCrash(t, false, "journal_prepared")
			}
			var err error
			switch damage {
			case "parent_symlink":
				alias := filepath.Join(t.TempDir(), "alias")
				err = os.Symlink(filepath.Dir(root), alias)
				root = filepath.Join(alias, "Library")
			case "parent_public":
				err = os.Chmod(filepath.Dir(root), 0755)
			case "root_symlink":
				err = os.Symlink(t.TempDir(), root)
			case "root_public":
				err = os.Mkdir(root, 0755)
			case "lock_symlink":
				err = os.Symlink(filepath.Join(t.TempDir(), "outside"), filepath.Join(filepath.Dir(root), ".runtime.lock"))
			case "receipt_corrupt":
				err = os.WriteFile(filepath.Join(filepath.Dir(root), restoreJournalName), []byte("{synthetic invalid receipt}"), 0600)
			case "receipt_symlink":
				path := filepath.Join(filepath.Dir(root), restoreJournalName)
				err = os.Rename(path, path+"-saved")
				if err == nil {
					err = os.Symlink(path+"-saved", path)
				}
			case "stage_replaced", "old_missing":
				path := root
				if damage == "stage_replaced" {
					entries, e := os.ReadDir(filepath.Dir(root))
					if e != nil {
						t.Fatal(e)
					}
					for _, entry := range entries {
						if strings.HasPrefix(entry.Name(), "restore-stage-") {
							path = filepath.Join(filepath.Dir(root), entry.Name())
						}
					}
				}
				err = os.Rename(path, path+"-saved")
				if err == nil && damage == "stage_replaced" {
					err = os.Mkdir(path, 0700)
				}
			}
			if err != nil {
				t.Fatal(err)
			}
			for range 2 {
				r, err := OpenRuntime(root)
				if r != nil {
					r.Close()
				}
				if !errors.Is(err, ErrCorrupt) {
					t.Fatal("unsafe runtime accepted or initialized")
				}
			}
		})
	}
}

func TestRuntimeOldBinaryCannotRaceMissingRootOrDegradedLock(t *testing.T) {
	t.Run("missing_root", func(t *testing.T) {
		root := runtimeTestRoot(t)
		r, err := openRuntime(root, func(stage string) {
			if stage == "synced_old" {
				s, err := Open(root)
				if err != nil {
					t.Fatal(err)
				}
				s.AddMember(ctx, "Synthetic competing library")
				s.Close()
			}
		})
		if err != nil {
			t.Fatal(err)
		}
		p := prepareRuntime(t, r, runtimeSnapshot(t))
		r.Store().Close()
		if err := r.ActivateRestore(p); !errors.Is(err, ErrCorrupt) {
			t.Fatal("competing library was overwritten")
		}
		r.Close()
		for range 2 {
			if r, err := OpenRuntime(root); !errors.Is(err, ErrCorrupt) {
				if r != nil {
					r.Close()
				}
				t.Fatal("ambiguous roots adopted")
			}
		}
		s, err := Open(root)
		if err != nil {
			t.Fatal(err)
		}
		defer s.Close()
		members, err := s.Members(ctx)
		if err != nil || len(members) != 1 || members[0].Name != "Synthetic competing library" {
			t.Fatal("competing data lost")
		}
	})
	t.Run("degraded_lock", func(t *testing.T) {
		root := runtimeTestRoot(t)
		if err := os.Mkdir(root, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "unknown"), []byte("synthetic"), 0600); err != nil {
			t.Fatal(err)
		}
		r, err := OpenRuntime(root)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Close()
		f, err := os.OpenFile(filepath.Join(root, ".owner.lock"), os.O_RDWR, 0)
		if err != nil {
			t.Fatal(err)
		}
		defer f.Close()
		if syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) == nil {
			t.Fatal("degraded runtime did not hold old owner lock")
		}
	})
	t.Run("lock_after_service_close", func(t *testing.T) {
		root := runtimeTestRoot(t)
		r, err := OpenRuntime(root)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Close()
		p := prepareRuntime(t, r, runtimeSnapshot(t))
		r.Store().Close()
		s, err := Open(root)
		if err != nil {
			t.Fatal(err)
		}
		defer s.Close()
		if err := r.ActivateRestore(p); !errors.Is(err, ErrLocked) {
			t.Fatal("activation bypassed old owner lock")
		}
	})
}

func TestRuntimeCancellationAndStaleTokenLeaveCurrentLibraryUsable(t *testing.T) {
	r, err := OpenRuntime(runtimeTestRoot(t))
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	data := runtimeSnapshot(t)
	cancelled, cancel := context.WithCancel(ctx)
	_, err = r.PrepareRestore(cancelled, func(c context.Context, s *Store) error {
		_, err := s.RestoreSnapshot(c, bytes.NewReader(data))
		cancel()
		return err
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatal("cancelled preparation returned an activatable token")
	}
	p := prepareRuntime(t, r, data)
	if err := r.CancelRestore(p); err != nil {
		t.Fatal(err)
	}
	next := prepareRuntime(t, r, data)
	if err := r.CancelRestore(p); !errors.Is(err, ErrState) {
		t.Fatal("stale token cancelled newer preparation")
	}
	if err := r.ActivateRestore(p); !errors.Is(err, ErrState) {
		t.Fatal("stale token activated newer preparation")
	}
	copy := *next
	if err := r.CancelRestore(&copy); !errors.Is(err, ErrState) {
		t.Fatal("copied token acquired stage authority")
	}
	if err := r.CancelRestore(next); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Store().AddMember(ctx, "Synthetic still usable"); err != nil {
		t.Fatal(err)
	}
}

func TestRuntimeLiveReceiptCorruptionIsNotOverwritten(t *testing.T) {
	root := runtimeTestRoot(t)
	r, err := openRuntime(root, func(stage string) {
		if stage == "journal_prepared" {
			if err := os.WriteFile(filepath.Join(filepath.Dir(root), restoreJournalName), []byte("synthetic receipt corruption"), 0600); err != nil {
				t.Fatal(err)
			}
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	p := prepareRuntime(t, r, runtimeSnapshot(t))
	r.Store().Close()
	if err := r.ActivateRestore(p); !errors.Is(err, ErrCorrupt) {
		t.Fatal("same-inode receipt corruption was overwritten")
	}
	r.Close()
	if data, err := os.ReadFile(filepath.Join(filepath.Dir(root), restoreJournalName)); err != nil || string(data) != "synthetic receipt corruption" {
		t.Fatal("corrupt evidence was discarded")
	}
	if r, err := OpenRuntime(root); !errors.Is(err, ErrCorrupt) {
		if r != nil {
			r.Close()
		}
		t.Fatal("damaged receipt permitted restart")
	}
}
