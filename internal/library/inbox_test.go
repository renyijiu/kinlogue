package library

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"kinlogue/internal/document"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func receiveTest(t *testing.T, s *Store, body string) InboxItem {
	t.Helper()
	u, e := s.StageInbox(ctx, "synthetic.pdf", int64(len(body)), bytes.NewBufferString(body))
	if e != nil {
		t.Fatal(e)
	}
	defer u.Abort()
	item, e := u.Commit(ctx)
	if e != nil {
		t.Fatal(e)
	}
	return item
}
func readyTest(t *testing.T, s *Store, item InboxItem) InboxItem {
	t.Helper()
	item, e := s.BeginInboxProcessing(ctx, item.ID, item.Revision)
	if e != nil {
		t.Fatal(e)
	}
	item, e = s.SaveInboxExtraction(ctx, item.ID, item.Revision, extraction())
	if e != nil {
		t.Fatal(e)
	}
	return item
}
func TestInboxArchiveAtomicAndExactDuplicate(t *testing.T) {
	s, _ := openTest(t)
	member, e := s.AddMember(ctx, "Synthetic member")
	if e != nil {
		t.Fatal(e)
	}
	a := readyTest(t, s, receiveTest(t, s, "synthetic-a"))
	b := readyTest(t, s, receiveTest(t, s, "synthetic-b"))
	stale := []InboxSelection{{a.ID, a.Revision - 1}, {b.ID, b.Revision}}
	if _, e = s.ArchiveInbox(ctx, stale, Edit{MemberID: member.ID}); !errors.Is(e, ErrState) {
		t.Fatalf("stale archive: %v", e)
	}
	items, _ := s.Inbox(ctx)
	if len(items) != 2 {
		t.Fatal("stale selection consumed queue")
	}
	r, e := s.ArchiveInbox(ctx, []InboxSelection{{b.ID, b.Revision}, {a.ID, a.Revision}}, Edit{MemberID: member.ID, Date: "2026-10-09"})
	if e != nil {
		t.Fatal(e)
	}
	if r.Status != "review" || r.Sources[0].ID != b.ID || r.Review.MemberID != member.ID {
		t.Fatalf("report: %+v", r)
	}
	a = readyTest(t, s, receiveTest(t, s, "synthetic-a"))
	b = readyTest(t, s, receiveTest(t, s, "synthetic-b"))
	duplicate, e := s.ArchiveInbox(ctx, []InboxSelection{{a.ID, a.Revision}, {b.ID, b.Revision}}, Edit{MemberID: member.ID, Date: "2026-10-08"})
	if e != nil || duplicate.ID != r.ID || duplicate.Review.Date != r.Review.Date {
		t.Fatalf("duplicate: %+v %v", duplicate, e)
	}
	items, _ = s.Inbox(ctx)
	if len(items) != 0 {
		t.Fatal("queue not consumed")
	}
	if _, e = s.ReadOriginal(ctx, r.ID, r.Sources[0].ID); e != nil {
		t.Fatal(e)
	}
}
func TestInboxArchiveIgnoresIncompleteLocalDuplicate(t *testing.T) {
	for _, status := range []string{"processing", "failed"} {
		t.Run(status, func(t *testing.T) {
			s, _ := openTest(t)
			member, err := s.AddMember(ctx, "Synthetic member")
			if err != nil {
				t.Fatal(err)
			}
			const body = "synthetic-local-and-phone-original"
			local, err := createSingle(s, ctx, "synthetic.pdf", []byte(body))
			if err != nil {
				t.Fatal(err)
			}
			if status == "failed" {
				if err = s.FailDraft(ctx, local.ID, "recognition_failed"); err != nil {
					t.Fatal(err)
				}
			}
			item := readyTest(t, s, receiveTest(t, s, body))
			report, err := s.ArchiveInbox(ctx, []InboxSelection{{item.ID, item.Revision}}, Edit{MemberID: member.ID})
			if err != nil {
				t.Fatal(err)
			}
			if report.ID == local.ID || report.Status != "review" || len(report.Sources) != 1 || report.Sources[0].Extraction.Text() != extraction().Text() {
				t.Fatalf("successful phone extraction replaced by incomplete local draft: %+v", report)
			}
			if original, err := s.ReadOriginal(ctx, report.ID, report.Sources[0].ID); err != nil || string(original) != body {
				t.Fatalf("archived original: %q %v", original, err)
			}
			unchanged, err := s.Get(ctx, local.ID)
			if err != nil || unchanged.Status != status {
				t.Fatalf("local draft changed: %+v %v", unchanged, err)
			}
			items, err := s.Inbox(ctx)
			if err != nil || len(items) != 0 {
				t.Fatalf("archive did not consume inbox: %+v %v", items, err)
			}
		})
	}
}

func TestInboxArchivePreservesConfirmedDuplicate(t *testing.T) {
	s, _ := openTest(t)
	member, err := s.AddMember(ctx, "Synthetic member")
	if err != nil {
		t.Fatal(err)
	}
	item := readyTest(t, s, receiveTest(t, s, "synthetic-confirmed-original"))
	report, err := s.ArchiveInbox(ctx, []InboxSelection{{item.ID, item.Revision}}, Edit{MemberID: member.ID})
	if err != nil {
		t.Fatal(err)
	}
	edit := report.Review
	edit.Title, edit.Date, edit.Text, edit.Notes = "Synthetic corrected title", "2026-10-09", "Synthetic corrected transcription", "Synthetic note"
	report, err = s.Confirm(ctx, report.ID, edit)
	if err != nil {
		t.Fatal(err)
	}
	item = readyTest(t, s, receiveTest(t, s, "synthetic-confirmed-original"))
	duplicate, err := s.ArchiveInbox(ctx, []InboxSelection{{item.ID, item.Revision}}, Edit{MemberID: member.ID, Title: "Different title", Date: "2026-10-08"})
	if err != nil {
		t.Fatal(err)
	}
	before, _ := json.Marshal(report)
	after, _ := json.Marshal(duplicate)
	if !bytes.Equal(before, after) {
		t.Fatalf("confirmed duplicate changed: before %s after %s", before, after)
	}
	items, err := s.Inbox(ctx)
	if err != nil || len(items) != 0 {
		t.Fatalf("duplicate did not consume inbox: %+v %v", items, err)
	}
}

func TestInboxStagingDoesNotLockAndCancellationCannotPublish(t *testing.T) {
	s, _ := openTest(t)
	read, write := io.Pipe()
	done := make(chan error, 1)
	c, cancel := context.WithCancel(ctx)
	go func() {
		u, e := s.StageInbox(c, "synthetic.pdf", 1, read)
		if u != nil {
			defer u.Abort()
		}
		done <- e
	}()
	members := make(chan error, 1)
	go func() { _, e := s.Members(ctx); members <- e }()
	select {
	case e := <-members:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(time.Second):
		t.Fatal("slow upload holds store")
	}
	cancel()
	write.Close()
	<-done
	u, e := s.StageInbox(ctx, "synthetic.pdf", 1, bytes.NewBufferString("x"))
	if e != nil {
		t.Fatal(e)
	}
	defer u.Abort()
	if _, e = u.Commit(c); !errors.Is(e, context.Canceled) {
		t.Fatalf("cancelled commit: %v", e)
	}
	items, _ := s.Inbox(ctx)
	if len(items) != 0 {
		t.Fatal("cancelled upload published")
	}
}
func TestInboxBackupAndRestart(t *testing.T) {
	s, path := openTest(t)
	a := readyTest(t, s, receiveTest(t, s, "synthetic-ready"))
	b := receiveTest(t, s, "synthetic-processing")
	b, e := s.BeginInboxProcessing(ctx, b.ID, b.Revision)
	if e != nil {
		t.Fatal(e)
	}
	dup := receiveTest(t, s, "synthetic-ready")
	if dup.ID != a.ID {
		t.Fatal("duplicate not merged")
	}
	var snapshot bytes.Buffer
	summary, e := s.WriteSnapshot(ctx, &snapshot)
	if e != nil || summary.Inbox != 2 {
		t.Fatalf("snapshot: %+v %v", summary, e)
	}
	restored, _ := openTest(t)
	if _, e = restored.RestoreSnapshot(ctx, bytes.NewReader(snapshot.Bytes())); e != nil {
		t.Fatal(e)
	}
	items, e := restored.Inbox(ctx)
	if e != nil || len(items) != 2 {
		t.Fatalf("restored: %+v %v", items, e)
	}
	rb, e := restored.GetInbox(ctx, b.ID)
	if e != nil || rb.Status != "failed" || rb.Failure != "interrupted" {
		t.Fatalf("processing snapshot: %+v %v", rb, e)
	}
	s.Close()
	s, e = Open(path)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	rb, e = s.GetInbox(ctx, b.ID)
	if e != nil || rb.Status != "failed" {
		t.Fatalf("restart: %+v %v", rb, e)
	}
	if _, e = s.SaveInboxExtraction(ctx, b.ID, b.Revision, extraction()); !errors.Is(e, ErrState) {
		t.Fatalf("late extraction: %v", e)
	}
}

func TestInboxDoesNotDiscardGoodCopyForDamagedDuplicateReport(t *testing.T) {
	s, path := openTest(t)
	m, _ := s.AddMember(ctx, "Synthetic member")
	a := readyTest(t, s, receiveTest(t, s, "synthetic-original"))
	r, e := s.ArchiveInbox(ctx, []InboxSelection{{a.ID, a.Revision}}, Edit{MemberID: m.ID})
	if e != nil {
		t.Fatal(e)
	}
	a = readyTest(t, s, receiveTest(t, s, "synthetic-original"))
	if e = os.WriteFile(filepath.Join(path, "originals", r.Sources[0].ID+".blob"), []byte("damaged"), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e = s.ArchiveInbox(ctx, []InboxSelection{{a.ID, a.Revision}}, Edit{MemberID: m.ID}); !errors.Is(e, ErrCorrupt) {
		t.Fatalf("damaged duplicate: %v", e)
	}
	if _, e = s.ReadInboxOriginal(ctx, a.ID, a.Revision); e != nil {
		t.Fatal("valid replacement lost", e)
	}
}

func TestInboxStageBoundsAbortAndLateResults(t *testing.T) {
	s, path := openTest(t)
	for _, body := range []string{"", "xx"} {
		if u, e := s.StageInbox(ctx, "synthetic.pdf", 1, bytes.NewBufferString(body)); e == nil {
			u.Abort()
			t.Fatal("size mismatch accepted")
		}
	}
	u, e := s.StageInbox(ctx, "synthetic.pdf", 1, bytes.NewBufferString("x"))
	if e != nil {
		t.Fatal(e)
	}
	if e = u.Abort(); e != nil {
		t.Fatal(e)
	}
	if e = u.Abort(); e != nil {
		t.Fatal(e)
	}
	if _, e = u.Commit(ctx); !errors.Is(e, ErrState) {
		t.Fatal("aborted stage committed")
	}
	entries, e := os.ReadDir(filepath.Join(path, "originals"))
	if e != nil || len(entries) != 0 {
		t.Fatal("aborted partial retained", e)
	}
	a := receiveTest(t, s, "synthetic-late")
	a, e = s.BeginInboxProcessing(ctx, a.ID, a.Revision)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.DeleteInbox(ctx, []InboxSelection{{a.ID, a.Revision}}); e != nil {
		t.Fatal(e)
	}
	if _, e = s.SaveInboxExtraction(ctx, a.ID, a.Revision, extraction()); !errors.Is(e, ErrNotFound) {
		t.Fatal("late OCR resurrected item", e)
	}
	entries, _ = os.ReadDir(filepath.Join(path, "originals"))
	if len(entries) != 0 {
		t.Fatal("known deletion not cleaned")
	}
}

func TestInboxMigrationVersionThreeAfterProcessKill(t *testing.T) {
	exe, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	for _, stage := range []string{"migration_uncommitted", "migration_committed"} {
		t.Run(stage, func(t *testing.T) {
			f := createMigrationV2Fixture(t)
			db, e := sql.Open("sqlite", filepath.Join(f.root, "library.sqlite"))
			if e != nil {
				t.Fatal(e)
			}
			if _, e = db.Exec("PRAGMA user_version=3"); e != nil {
				t.Fatal(e)
			}
			db.Close()
			lifetime, cancel := context.WithTimeout(ctx, 15*time.Second)
			defer cancel()
			cmd := exec.CommandContext(lifetime, exe, "-test.run=^TestMigrationCrashHelper$")
			cmd.Env = append(os.Environ(), "KINLOGUE_TEST_MIGRATION_ROOT="+f.root, "KINLOGUE_TEST_MIGRATION_STAGE="+stage)
			output, e := cmd.CombinedOutput()
			assertCheckpointKilled(t, lifetime, output, e, "migration checkpoint reached")
			s, e := Open(f.root)
			if e != nil {
				t.Fatal(e)
			}
			defer s.Close()
			assertMigratedV1Fixture(t, s, f)
			items, e := s.Inbox(ctx)
			if e != nil || len(items) != 0 {
				t.Fatal("migration lost empty inbox", e)
			}
		})
	}
}

func TestInboxArchiveCrashHelper(t *testing.T) {
	stage := os.Getenv("KINLOGUE_TEST_INBOX_STAGE")
	if stage == "" {
		return
	}
	s, e := Open(os.Getenv("KINLOGUE_TEST_INBOX_ROOT"))
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	items, e := s.Inbox(ctx)
	if e != nil {
		t.Fatal(e)
	}
	members, _ := s.Members(ctx)
	_, e = s.archiveInbox(ctx, []InboxSelection{{items[0].ID, items[0].Revision}}, Edit{MemberID: members[0].ID}, func(current string) {
		if current == stage {
			fmt.Fprintln(os.Stdout, "inbox checkpoint reached")
			killAtCheckpoint(t)
		}
	})
	t.Fatal("checkpoint not reached", e)
}
func TestInboxArchiveSurvivesProcessKill(t *testing.T) {
	exe, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	for _, stage := range []string{"archive_uncommitted", "archive_committed"} {
		t.Run(stage, func(t *testing.T) {
			s, path := openTest(t)
			s.AddMember(ctx, "Synthetic member")
			readyTest(t, s, receiveTest(t, s, "synthetic-durable"))
			s.Close()
			lifetime, cancel := context.WithTimeout(ctx, 15*time.Second)
			defer cancel()
			cmd := exec.CommandContext(lifetime, exe, "-test.run=^TestInboxArchiveCrashHelper$")
			cmd.Env = append(os.Environ(), "KINLOGUE_TEST_INBOX_ROOT="+path, "KINLOGUE_TEST_INBOX_STAGE="+stage)
			output, e := cmd.CombinedOutput()
			assertCheckpointKilled(t, lifetime, output, e, "inbox checkpoint reached")
			s, e = Open(path)
			if e != nil {
				t.Fatal(e)
			}
			defer s.Close()
			items, e := s.Inbox(ctx)
			if e != nil {
				t.Fatal(e)
			}
			reports, e := s.Drafts(ctx)
			if e != nil {
				t.Fatal(e)
			}
			if stage == "archive_uncommitted" {
				if len(items) != 1 || len(reports) != 0 {
					t.Fatal("partial metadata commit")
				}
				if _, e = s.ReadInboxOriginal(ctx, items[0].ID, items[0].Revision); e != nil {
					t.Fatal(e)
				}
			} else {
				if len(items) != 0 || len(reports) != 1 {
					t.Fatal("archive commit lost")
				}
				r, _ := s.Get(ctx, reports[0].ID)
				if _, e = s.ReadOriginal(ctx, r.ID, r.Sources[0].ID); e != nil {
					t.Fatal(e)
				}
			}
		})
	}
}

func TestInboxSnapshotRuntimeRecoveryAfterProcessKill(t *testing.T) {
	for _, stage := range []string{"renamed_new", "journal_committed"} {
		t.Run(stage, func(t *testing.T) {
			s, _ := openTest(t)
			a := readyTest(t, s, receiveTest(t, s, "synthetic-runtime-inbox"))
			var b bytes.Buffer
			if _, e := s.WriteSnapshot(ctx, &b); e != nil {
				t.Fatal(e)
			}
			path := filepath.Join(t.TempDir(), "synthetic.snapshot")
			if e := os.WriteFile(path, b.Bytes(), 0600); e != nil {
				t.Fatal(e)
			}
			root := runtimeTestRoot(t)
			runRuntimeKill(t, root, path, stage, "", true)
			r, e := OpenRuntime(root)
			if e != nil {
				t.Fatal(e)
			}
			defer r.Close()
			if stage == "renamed_new" {
				if r.Store() != nil || !errors.Is(r.OpenError(), ErrRestoreInterrupted) {
					t.Fatal("uncommitted candidate adopted")
				}
				return
			}
			if r.Store() == nil {
				t.Fatal("restore degraded", r.OpenError())
			}
			item, e := r.Store().GetInbox(ctx, a.ID)
			if e != nil || item.Status != "reviewable" {
				t.Fatalf("lost pending queue: %+v %v", item, e)
			}
			if _, e = r.Store().ReadInboxOriginal(ctx, a.ID, item.Revision); e != nil {
				t.Fatal(e)
			}
		})
	}
}

func TestInboxUnsupportedRetryAndBatchDeleteAreRevisionChecked(t *testing.T) {
	s, _ := openTest(t)
	a := receiveTest(t, s, "synthetic-unsupported")
	a, e := s.BeginInboxProcessing(ctx, a.ID, a.Revision)
	if e != nil {
		t.Fatal(e)
	}
	a, e = s.FailInbox(ctx, a.ID, a.Revision, "unsupported")
	if e != nil || a.Status != "unsupported" {
		t.Fatal(e)
	}
	old := a
	a, e = s.BeginInboxProcessing(ctx, a.ID, a.Revision)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.SaveInboxExtraction(ctx, a.ID, old.Revision, extraction()); !errors.Is(e, ErrState) {
		t.Fatal("stale worker accepted", e)
	}
	a, e = s.SaveInboxExtraction(ctx, a.ID, a.Revision, extraction())
	if e != nil {
		t.Fatal(e)
	}
	b := receiveTest(t, s, "synthetic-another")
	if _, e = s.DeleteInbox(ctx, []InboxSelection{{a.ID, a.Revision}, {b.ID, b.Revision + 1}}); !errors.Is(e, ErrState) {
		t.Fatal("stale delete accepted", e)
	}
	items, e := s.Inbox(ctx)
	if e != nil || len(items) != 2 {
		t.Fatal("batch delete partly applied", e)
	}
}

func TestInboxCapacityAndPartialBackupExclusion(t *testing.T) {
	s, _ := openTest(t)
	u, e := s.StageInbox(ctx, "synthetic-partial.pdf", 1, bytes.NewBufferString("x"))
	if e != nil {
		t.Fatal(e)
	}
	defer u.Abort()
	var b bytes.Buffer
	if summary, e := s.WriteSnapshot(ctx, &b); e != nil || summary.Inbox != 0 || summary.OriginalBytes != 0 {
		t.Fatal("unpublished upload included", e)
	}
	tx, e := s.db.Begin()
	if e != nil {
		t.Fatal(e)
	}
	for i := 0; i < MaxInboxItems; i++ {
		_, e = tx.Exec(`INSERT INTO inbox(id,file_name,status,revision,created_at,digest,byte_count) VALUES (?,'synthetic.pdf','stored',1,'2026-10-09T00:00:00Z',?,1)`, fmt.Sprintf("%032x", i+1), fmt.Sprintf("%064x", i+1))
		if e != nil {
			t.Fatal(e)
		}
	}
	if e = tx.Commit(); e != nil {
		t.Fatal(e)
	}
	if _, e = u.Commit(ctx); !errors.Is(e, document.ErrLimit) {
		t.Fatal("inbox capacity bypassed", e)
	}
}

func TestInboxSnapshotRejectsInvalidPendingGraph(t *testing.T) {
	s, _ := openTest(t)
	readyTest(t, s, receiveTest(t, s, "synthetic-a"))
	readyTest(t, s, receiveTest(t, s, "synthetic-b"))
	var b bytes.Buffer
	if _, e := s.WriteSnapshot(ctx, &b); e != nil {
		t.Fatal(e)
	}
	for _, mutation := range []string{"revision", "sequence", "extraction", "digest", "count"} {
		t.Run(mutation, func(t *testing.T) {
			entries := snapshotEntries(t, b.Bytes())
			if mutation == "count" {
				var h snapshotHeader
				json.Unmarshal(entries[0].data, &h)
				h.Inbox = MaxInboxItems + 1
				entries[0].data, _ = json.Marshal(h)
			} else {
				indexes := []int{}
				for i, entry := range entries {
					if strings.HasPrefix(entry.header.Name, "inbox/") {
						indexes = append(indexes, i)
					}
				}
				var item, other inboxRecord
				json.Unmarshal(entries[indexes[0]].data, &item)
				json.Unmarshal(entries[indexes[1]].data, &other)
				switch mutation {
				case "revision":
					item.Revision = 0
				case "sequence":
					item.Sequence = other.Sequence
				case "extraction":
					item.Extraction = document.Extraction{}
				case "digest":
					item.Digest = other.Digest
				}
				entries[indexes[0]].data, _ = json.Marshal(item)
			}
			if _, e := VerifySnapshot(ctx, bytes.NewReader(encodeSnapshotEntries(t, entries))); e == nil {
				t.Fatal("invalid pending graph accepted")
			}
		})
	}
}

func TestInboxLateDuplicateCannotResurrectRemovedContent(t *testing.T) {
	for _, operation := range []string{"delete", "archive"} {
		t.Run(operation, func(t *testing.T) {
			s, _ := openTest(t)
			a := readyTest(t, s, receiveTest(t, s, "synthetic-overlap"))
			m, _ := s.AddMember(ctx, "Synthetic member")
			u, e := s.StageInbox(ctx, "synthetic.pdf", int64(len("synthetic-overlap")), bytes.NewBufferString("synthetic-overlap"))
			if e != nil {
				t.Fatal(e)
			}
			defer u.Abort()
			if operation == "delete" {
				_, e = s.DeleteInbox(ctx, []InboxSelection{{a.ID, a.Revision}})
			} else {
				_, e = s.ArchiveInbox(ctx, []InboxSelection{{a.ID, a.Revision}}, Edit{MemberID: m.ID})
			}
			if e != nil {
				t.Fatal(e)
			}
			if _, e = u.Commit(ctx); !errors.Is(e, ErrState) {
				t.Fatalf("late duplicate resurrected removed content: %v", e)
			}
			if items, _ := s.Inbox(ctx); len(items) != 0 {
				t.Fatal("removed item reappeared")
			}
			// A deliberate new upload after the removal is still allowed.
			receiveTest(t, s, "synthetic-overlap")
		})
	}
}

func TestInboxRemovalFencesUploadAlreadyStreamingAndPrunesTombstones(t *testing.T) {
	s, _ := openTest(t)
	a := receiveTest(t, s, "synthetic-overlap")
	reader, writer := io.Pipe()
	result := make(chan *InboxUpload, 1)
	fail := make(chan error, 1)
	go func() {
		u, e := s.StageInbox(ctx, "synthetic.pdf", int64(len("synthetic-overlap")), reader)
		result <- u
		fail <- e
	}()
	// A successful pipe write proves admission happened before removal, while
	// the rest of the body still cannot supply its digest.
	if _, e := writer.Write([]byte("synthetic-")); e != nil {
		t.Fatal(e)
	}
	if _, e := s.DeleteInbox(ctx, []InboxSelection{{a.ID, a.Revision}}); e != nil {
		t.Fatal(e)
	}
	if _, e := writer.Write([]byte("overlap")); e != nil {
		t.Fatal(e)
	}
	writer.Close()
	u := <-result
	if e := <-fail; e != nil {
		t.Fatal(e)
	}
	defer u.Abort()
	if _, e := u.Commit(ctx); !errors.Is(e, ErrState) {
		t.Fatal("streaming duplicate escaped fence", e)
	}
	if e := u.Abort(); e != nil {
		t.Fatal(e)
	}
	s.mu.Lock()
	stages, removed := len(s.inboxStages), len(s.inboxRemoved)
	s.mu.Unlock()
	if stages != 0 || removed != 0 {
		t.Fatal("transient fence retained after all uploads drained")
	}
}
