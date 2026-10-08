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
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	"kinlogue/internal/document"
)

func killAtCheckpoint(t *testing.T) {
	t.Helper()
	if err := syscall.Kill(os.Getpid(), syscall.SIGKILL); err != nil {
		t.Fatal("checkpoint SIGKILL request failed")
	}
	// On Darwin kill can return before the signal terminates this process.
	// A following os.Exit competes with SIGKILL and can falsely report a normal
	// exit; wait instead, with a failed-test fallback if delivery never happens.
	timer := time.NewTimer(10 * time.Second)
	defer timer.Stop()
	<-timer.C
	t.Fatal("checkpoint SIGKILL was not delivered")
}

func assertCheckpointKilled(t *testing.T, lifetime context.Context, output []byte, err error, marker string) {
	t.Helper()
	// CommandContext also sends SIGKILL on timeout; that is not crash evidence.
	if lifetime.Err() != nil {
		t.Fatal("checkpoint child timed out")
	}
	var exit *exec.ExitError
	reached := bytes.Contains(output, []byte(marker))
	if !errors.As(err, &exit) || !reached {
		t.Fatalf("child checkpoint: exited=%t reached=%t", exit != nil, reached)
	}
	status, ok := exit.Sys().(syscall.WaitStatus)
	if !ok {
		t.Fatal("checkpoint child has no POSIX wait status")
	}
	if !status.Signaled() || status.Signal() != syscall.SIGKILL {
		t.Fatalf("checkpoint child termination: signaled=%t signal=%d exit=%d", status.Signaled(), status.Signal(), status.ExitStatus())
	}
}

func TestInitializationCrashHelper(t *testing.T) {
	stage := os.Getenv("KINLOGUE_TEST_INIT_STAGE")
	if stage == "" {
		return
	}
	s, err := openLibrary(os.Getenv("KINLOGUE_TEST_INIT_ROOT"), func(current string) {
		if current == stage {
			fmt.Fprintln(os.Stdout, "checkpoint reached")
			killAtCheckpoint(t)
		}
	})
	if s != nil {
		_ = s.Close()
	}
	t.Fatalf("checkpoint not reached: %v", err)
}

func TestInitializationRecoversAfterProcessKill(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, stage := range []string{"owner_durable", "database_created", "schema_uncommitted", "schema_committed"} {
		t.Run(stage, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "library")
			lifetime, cancel := context.WithTimeout(ctx, 15*time.Second)
			defer cancel()
			command := exec.CommandContext(lifetime, executable, "-test.run=^TestInitializationCrashHelper$")
			command.Env = append(os.Environ(), "KINLOGUE_TEST_INIT_ROOT="+root, "KINLOGUE_TEST_INIT_STAGE="+stage)
			output, err := command.CombinedOutput()
			assertCheckpointKilled(t, lifetime, output, err, "checkpoint reached")
			s, err := Open(root)
			if err != nil {
				t.Fatalf("restart after %s: %v", stage, err)
			}
			m, err := s.AddMember(ctx, "Synthetic restarted member")
			if err != nil {
				t.Fatal(err)
			}
			if err := s.Close(); err != nil {
				t.Fatal(err)
			}
			s, err = Open(root)
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			members, err := s.Members(ctx)
			if err != nil || len(members) != 1 || members[0] != m {
				t.Fatal("recovered initialization was not durable")
			}
			if _, err := os.Lstat(filepath.Join(root, ".initializing")); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("committed initialization marker remains")
			}
		})
	}
}

func TestInitializationMarkerCannotAdoptUnknownDatabase(t *testing.T) {
	for _, unsafe := range []string{"symlink", "public", "nonempty", "user_table", "unknown_version", "originals"} {
		t.Run(unsafe, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "library")
			if err := os.Mkdir(root, 0700); err != nil {
				t.Fatal(err)
			}
			marker := filepath.Join(root, ".initializing")
			if unsafe == "symlink" {
				if err := os.Symlink(t.TempDir(), marker); err != nil {
					t.Fatal(err)
				}
			} else if err := os.Mkdir(marker, 0700); err != nil {
				t.Fatal(err)
			}
			if unsafe == "public" {
				if err := os.Chmod(marker, 0755); err != nil {
					t.Fatal(err)
				}
			}
			if unsafe == "nonempty" {
				if err := os.WriteFile(filepath.Join(marker, "unknown"), []byte("synthetic"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.Mkdir(filepath.Join(root, "originals"), 0700); err != nil {
				t.Fatal(err)
			}
			if unsafe == "originals" {
				if err := os.WriteFile(filepath.Join(root, "originals", "unknown.blob"), []byte("synthetic"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			path := filepath.Join(root, "library.sqlite")
			if err := os.WriteFile(path, nil, 0600); err != nil {
				t.Fatal(err)
			}
			if unsafe == "user_table" || unsafe == "unknown_version" {
				db, err := sql.Open("sqlite", path)
				if err != nil {
					t.Fatal(err)
				}
				query := "CREATE TABLE unrelated(value TEXT); INSERT INTO unrelated VALUES('synthetic')"
				if unsafe == "unknown_version" {
					query = "PRAGMA user_version=99"
				}
				if _, err := db.Exec(query); err != nil {
					t.Fatal(err)
				}
				if err := db.Close(); err != nil {
					t.Fatal(err)
				}
			}
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if s, err := Open(root); err == nil {
				s.Close()
				t.Fatal("unsafe initialization adopted")
			}
			after, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(before, after) {
				t.Fatal("unknown database changed")
			}
		})
	}
}

type failingOriginal struct {
	*os.File
	stage string
}

func (f failingOriginal) Write(data []byte) (int, error) {
	if f.stage == "write" {
		n, _ := f.File.Write(data[:1])
		return n, errors.New("synthetic write failure")
	}
	if f.stage == "short" {
		return f.File.Write(data[:1])
	}
	return f.File.Write(data)
}
func (f failingOriginal) Sync() error {
	if f.stage == "sync" {
		return errors.New("synthetic sync failure")
	}
	return f.File.Sync()
}
func (f failingOriginal) Close() error {
	err := f.File.Close()
	if f.stage == "close" {
		return errors.New("synthetic close failure")
	}
	return err
}

func TestOriginalPartCleanupAfterFileFailure(t *testing.T) {
	for _, stage := range []string{"write", "short", "sync", "close"} {
		t.Run(stage, func(t *testing.T) {
			s, root := openTest(t)
			err := s.writeOriginalUsing(ctx, opaqueID(), []byte("synthetic original"), func(f *os.File) originalFile { return failingOriginal{f, stage} })
			if !errors.Is(err, ErrStorage) {
				t.Fatalf("file failure result: %v", err)
			}
			files, err := os.ReadDir(filepath.Join(root, "originals"))
			if err != nil || len(files) != 0 {
				t.Fatal("failed write retained a part or published a blob")
			}
		})
	}
}

func TestOriginalPartCleanupPreservesReplacement(t *testing.T) {
	s, root := openTest(t)
	id := opaqueID()
	path := filepath.Join(root, "originals", id+".part")
	err := s.writeOriginalUsing(ctx, id, []byte("synthetic original"), func(f *os.File) originalFile {
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("synthetic replacement"), 0600); err != nil {
			t.Fatal(err)
		}
		return failingOriginal{f, "write"}
	})
	if !errors.Is(err, ErrStorage) {
		t.Fatal("expected injected write failure")
	}
	data, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(data, []byte("synthetic replacement")) {
		t.Fatal("cleanup deleted somebody else's part")
	}
}

func TestOwnedEmptyInitializationResumes(t *testing.T) {
	root := filepath.Join(t.TempDir(), "library")
	for _, dir := range []string{root, filepath.Join(root, ".initializing"), filepath.Join(root, "originals")} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "library.sqlite"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	s, err := Open(root)
	if err != nil {
		t.Fatalf("owned empty initialization did not resume: %v", err)
	}
	defer s.Close()
	if _, err := s.AddMember(ctx, "Synthetic resumed member"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(root, ".initializing")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("initialization marker remains")
	}
}

func TestUnownedEmptyDatabaseIsNotInitialized(t *testing.T) {
	root := filepath.Join(t.TempDir(), "library")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "library.sqlite")
	if err := os.WriteFile(path, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if s, err := Open(root); !errors.Is(err, ErrUnsupported) {
		if s != nil {
			s.Close()
		}
		t.Fatalf("unowned database result: %v", err)
	}
	if data, err := os.ReadFile(path); err != nil || len(data) != 0 {
		t.Fatal("unowned database changed")
	}
}

func TestOriginalPartCleanupAfterCancellationAndLinkFailure(t *testing.T) {
	for _, cause := range []string{"cancel", "link"} {
		t.Run(cause, func(t *testing.T) {
			s, root := openTest(t)
			id := opaqueID()
			c := ctx
			if cause == "cancel" {
				cancelled, cancel := context.WithCancel(ctx)
				cancel()
				c = cancelled
			} else {
				if err := os.WriteFile(filepath.Join(root, "originals", id+".blob"), []byte("published synthetic original"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			if err := s.writeOriginal(c, id, []byte("new synthetic original")); err == nil {
				t.Fatal("expected publication failure")
			}
			if _, err := os.Lstat(filepath.Join(root, "originals", id+".part")); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("failed publication left its owned part")
			}
			if cause == "link" {
				data, err := os.ReadFile(filepath.Join(root, "originals", id+".blob"))
				if err != nil || !bytes.Equal(data, []byte("published synthetic original")) {
					t.Fatal("published original changed")
				}
			}
		})
	}
}

func TestListsOnlyHydrateMetadataAtScale(t *testing.T) {
	s, _ := openTest(t)
	member, err := s.AddMember(ctx, "Synthetic scale member")
	if err != nil {
		t.Fatal(err)
	}
	text := strings.Repeat("合成", (document.MaxBlockBytes-6)/6)
	e := document.Extraction{Kind: "pdf", Engine: "synthetic", PageCount: 1, Blocks: []document.Block{{Page: 1, Text: text, Method: "synthetic", Confidence: 1}}}
	var selected string
	const count = 128
	for i := 0; i < count; i++ {
		r, err := createSingle(s, ctx, "synthetic.pdf", []byte("synthetic scale original"))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.SaveSourceExtraction(ctx, r.ID, r.Sources[0].ID, e); err != nil {
			t.Fatal(err)
		}
		edit := Edit{SourceIDs: r.Review.SourceIDs, MemberID: member.ID, Title: "Synthetic scale report", Text: text, Notes: text}
		if i%2 == 0 {
			if _, err := s.Confirm(ctx, r.ID, edit); err != nil {
				t.Fatal(err)
			}
			selected = r.ID
		} else if _, err := s.SaveReview(ctx, r.ID, edit); err != nil {
			t.Fatal(err)
		}
	}
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	drafts, err := s.Drafts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	records, err := s.Search(ctx, member.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	runtime.ReadMemStats(&after)
	if len(drafts) != count/2 || len(records) != count/2 {
		t.Fatal("list lost records")
	}
	for _, rows := range [][]Report{drafts, records} {
		for _, r := range rows {
			if r.Review.Text != "" || r.Review.Notes != "" || len(r.Sources) != 0 || len(r.Review.SourceIDs) != 0 {
				t.Fatal("list hydrated report bodies")
			}
			if r.FileName == "" || r.Review.Title == "" || r.Review.MemberID != member.ID {
				t.Fatal("list omitted required metadata")
			}
		}
	}
	allocated := after.TotalAlloc - before.TotalAlloc
	if allocated > 4<<20 {
		t.Fatalf("metadata list allocated %d bytes for %d reports", allocated, count)
	}
	t.Logf("%d synthetic reports containing %d source/corrected/note bytes: list allocations %d bytes", count, count*len(text)*3, allocated)
	full, err := s.Get(ctx, selected)
	if err != nil || full.Review.Text != text || full.Review.Notes != text || full.Sources[0].Extraction.Text() != text {
		t.Fatal("Get no longer returns full detail")
	}
}
