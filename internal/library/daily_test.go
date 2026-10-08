package library

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"kinlogue/internal/document"
)

func multiDraft(t *testing.T, s *Store) Report {
	t.Helper()
	r, err := s.CreateDraftSources(ctx, []string{"synthetic-a.pdf", "../../synthetic-b.png"}, func(i int) ([]byte, error) { return []byte{byte(i + 1)}, nil })
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func finishSources(t *testing.T, s *Store, r Report) Report {
	t.Helper()
	for _, source := range r.Sources {
		var err error
		r, err = s.SaveSourceExtraction(ctx, r.ID, source.ID, extraction())
		if err != nil {
			t.Fatal(err)
		}
	}
	return r
}

func TestMultipleSourcesPublishTogetherAndKeepExtractionImmutable(t *testing.T) {
	s, root := openTest(t)
	r := multiDraft(t, s)
	if len(r.Sources) != 2 || r.Sources[0].ID == r.Sources[1].ID {
		t.Fatal("source identities")
	}
	partial, err := s.SaveSourceExtraction(ctx, r.ID, r.Sources[0].ID, extraction())
	if err != nil || partial.Status != "processing" || partial.Review.Text != "" {
		t.Fatalf("partial report became review: %v", err)
	}
	if _, err := s.SaveReview(ctx, r.ID, partial.Review); !errors.Is(err, ErrState) {
		t.Fatal("partial report editable")
	}
	if _, err := s.SaveSourceExtraction(ctx, r.ID, r.Sources[0].ID, extraction()); !errors.Is(err, ErrState) {
		t.Fatal("source OCR overwritten")
	}
	r, err = s.SaveSourceExtraction(ctx, r.ID, r.Sources[1].ID, extraction())
	if err != nil || r.Status != "review" || r.Review.Text != extraction().Text()+"\n"+extraction().Text() {
		t.Fatalf("complete report: %v", err)
	}
	edit := r.Review
	edit.Text = "synthetic manually corrected"
	edit.SourceIDs = []string{r.Sources[1].ID, r.Sources[0].ID}
	r, err = s.SaveReview(ctx, r.ID, edit)
	if err != nil || r.Sources[0].FileName != "../../synthetic-b.png" || !r.Review.Equal(edit) {
		t.Fatal("source order not saved")
	}
	if _, err := s.SaveSourceExtraction(ctx, r.ID, r.Sources[0].ID, extraction()); !errors.Is(err, ErrState) {
		t.Fatal("late OCR replaced review")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	r, err = s.Get(ctx, r.ID)
	if err != nil || !r.Review.Equal(edit) || !reflect.DeepEqual(r.Sources[0].Extraction, extraction()) {
		t.Fatal("multi report changed after reopen")
	}
	data, err := s.ReadOriginal(ctx, r.ID, r.Sources[0].ID)
	if err != nil || !reflect.DeepEqual(data, []byte{2}) {
		t.Fatal("source original changed")
	}
}

func TestSourceOrderingMustBeCompletePermutation(t *testing.T) {
	s, _ := openTest(t)
	r := finishSources(t, s, multiDraft(t, s))
	for _, ids := range [][]string{nil, {r.Sources[0].ID}, {r.Sources[0].ID, r.Sources[0].ID}, {r.Sources[0].ID, opaqueID()}} {
		edit := r.Review
		edit.SourceIDs = ids
		if _, err := s.SaveReview(ctx, r.ID, edit); !errors.Is(err, ErrInvalid) {
			t.Fatal("incomplete or foreign order accepted")
		}
	}
	other := multiDraft(t, s)
	if _, err := s.ReadOriginal(ctx, r.ID, other.Sources[0].ID); !errors.Is(err, ErrNotFound) {
		t.Fatal("cross-report source lookup accepted")
	}
}

func TestMultipleSourcesBoundedAndCallbackFailureDoesNotPublish(t *testing.T) {
	s, _ := openTest(t)
	calls := 0
	read := func(int) ([]byte, error) { calls++; return []byte("synthetic"), nil }
	for _, names := range [][]string{nil, make([]string, document.MaxSources+1), {"valid", " "}} {
		if _, err := s.CreateDraftSources(ctx, names, read); !errors.Is(err, ErrInvalid) {
			t.Fatal("invalid group accepted")
		}
	}
	if calls != 0 {
		t.Fatal("invalid names read original")
	}
	_, err := s.CreateDraftSources(ctx, []string{"one", "two"}, func(i int) ([]byte, error) {
		if i == 1 {
			return nil, document.ErrUnavailable
		}
		return []byte("synthetic"), nil
	})
	if !errors.Is(err, document.ErrUnavailable) {
		t.Fatal("read failure lost")
	}
	if drafts, err := s.Drafts(ctx); err != nil || len(drafts) != 0 {
		t.Fatal("partial import published")
	}
}

func TestAggregateExtractionLimitDoesNotPublishHalfReview(t *testing.T) {
	for _, kind := range []string{"pages", "text"} {
		t.Run(kind, func(t *testing.T) {
			s, _ := openTest(t)
			r := multiDraft(t, s)
			e := extraction()
			if kind == "pages" {
				e.PageCount = document.MaxPages
			} else {
				e.Blocks = nil
				for i := 0; i < 12; i++ {
					e.Blocks = append(e.Blocks, document.Block{Page: 1, Text: strings.Repeat("x", document.MaxBlockBytes), Method: "synthetic"})
				}
			}
			if _, err := s.SaveSourceExtraction(ctx, r.ID, r.Sources[0].ID, e); err != nil {
				t.Fatal(err)
			}
			if kind == "pages" {
				e = extraction()
			}
			if _, err := s.SaveSourceExtraction(ctx, r.ID, r.Sources[1].ID, e); !errors.Is(err, document.ErrLimit) {
				t.Fatalf("aggregate limit: %v", err)
			}
			got, err := s.Get(ctx, r.ID)
			if err != nil || got.Status != "processing" || got.Review.Text != "" || got.Sources[1].Extraction.Engine != "" {
				t.Fatal("failed extraction published")
			}
		})
	}
}

func TestConfirmedEditMovesMemberWithoutChangingOriginal(t *testing.T) {
	s, _ := openTest(t)
	a, _ := s.AddMember(ctx, "Synthetic A")
	b, _ := s.AddMember(ctx, "Synthetic B")
	r := finishSources(t, s, multiDraft(t, s))
	edit := r.Review
	edit.MemberID, edit.Title = a.ID, "Synthetic original title"
	if _, err := s.UpdateConfirmed(ctx, r.ID, edit); !errors.Is(err, ErrState) {
		t.Fatal("draft updated as confirmed")
	}
	r, err := s.Confirm(ctx, r.ID, edit)
	if err != nil {
		t.Fatal(err)
	}
	edit.MemberID, edit.Title, edit.Text = b.ID, "Synthetic revised title", "synthetic corrected record"
	edit.SourceIDs = []string{r.Sources[1].ID, r.Sources[0].ID}
	got, err := s.UpdateConfirmed(ctx, r.ID, edit)
	if err != nil || got.Status != "confirmed" || !got.Review.Equal(edit) || !reflect.DeepEqual(got.Sources[0].Extraction, extraction()) {
		t.Fatalf("confirmed edit: %v", err)
	}
	if results, _ := s.Search(ctx, a.ID, ""); len(results) != 0 {
		t.Fatal("old member retained record")
	}
	if results, _ := s.Search(ctx, b.ID, "corrected"); len(results) != 1 {
		t.Fatal("new member cannot search edited record")
	}
	invalid := edit
	invalid.Title = ""
	if _, err := s.UpdateConfirmed(ctx, r.ID, invalid); !errors.Is(err, ErrInvalid) {
		t.Fatal("invalid confirmed edit accepted")
	}
	got, _ = s.Get(ctx, r.ID)
	if !got.Review.Equal(edit) {
		t.Fatal("invalid edit modified confirmed record")
	}
}

func TestConfirmedEditFailureRollsBackFieldsAndSourceOrder(t *testing.T) {
	s, root := openTest(t)
	a, err := s.AddMember(ctx, "Synthetic A")
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.AddMember(ctx, "Synthetic B")
	if err != nil {
		t.Fatal(err)
	}
	r := finishSources(t, s, multiDraft(t, s))
	before := r.Review
	before.MemberID, before.Title, before.Date = a.ID, "Synthetic saved title", "2026-10-01"
	before.Text, before.Notes = "Synthetic saved correction", "Synthetic saved notes"
	r, err = s.Confirm(ctx, r.ID, before)
	if err != nil {
		t.Fatal(err)
	}
	after := before
	after.MemberID, after.Title, after.Date = b.ID, "Synthetic changed title", "2026-10-07"
	after.Text, after.Notes = "Synthetic changed correction", "Synthetic changed notes"
	after.SourceIDs = []string{r.Sources[1].ID, r.Sources[0].ID}
	originals := make(map[string][]byte, len(r.Sources))
	for _, source := range r.Sources {
		data, err := s.ReadOriginal(ctx, r.ID, source.ID)
		if err != nil {
			t.Fatal(err)
		}
		originals[source.ID] = data
	}
	// The source moving to position 1 is updated after the first source and
	// after the report row; abort this real SQLite statement inside the transaction.
	trigger := "CREATE TRIGGER reject_second_position BEFORE UPDATE OF position ON sources WHEN NEW.report_id='" + r.ID + "' AND NEW.position=1 BEGIN SELECT RAISE(ABORT, 'synthetic position failure'); END"
	if _, err := s.db.Exec(trigger); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpdateConfirmed(ctx, r.ID, after); !errors.Is(err, ErrStorage) {
		t.Fatalf("injected edit failure: %v", err)
	}
	assertUnchanged := func() {
		t.Helper()
		got, err := s.Get(ctx, r.ID)
		if err != nil || !reflect.DeepEqual(got, r) {
			t.Fatalf("failed edit changed fields, order, or source OCR: %v", err)
		}
		for _, source := range r.Sources {
			data, err := s.ReadOriginal(ctx, r.ID, source.ID)
			if err != nil || !bytes.Equal(data, originals[source.ID]) {
				t.Fatal("failed edit changed original bytes")
			}
		}
		hits, err := s.Search(ctx, a.ID, "saved correction")
		if err != nil || len(hits) != 1 || hits[0].ID != r.ID {
			t.Fatal("failed edit removed old member's searchable record")
		}
		if hits, err := s.Search(ctx, b.ID, ""); err != nil || len(hits) != 0 {
			t.Fatal("failed edit published record under new member")
		}
	}
	assertUnchanged()
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	assertUnchanged()
	if _, err := s.db.Exec("DROP TRIGGER reject_second_position"); err != nil {
		t.Fatal(err)
	}
	got, err := s.UpdateConfirmed(ctx, r.ID, after)
	if err != nil || !got.Review.Equal(after) || got.Sources[0].ID != after.SourceIDs[0] {
		t.Fatalf("edit did not succeed after removing failure: %v", err)
	}
	for _, source := range got.Sources {
		data, err := s.ReadOriginal(ctx, got.ID, source.ID)
		if err != nil || !bytes.Equal(data, originals[source.ID]) || !reflect.DeepEqual(source.Extraction, extraction()) {
			t.Fatal("successful retry changed source content")
		}
	}
	if hits, err := s.Search(ctx, a.ID, ""); err != nil || len(hits) != 0 {
		t.Fatal("successful edit retained old member's record")
	}
	if hits, err := s.Search(ctx, b.ID, "changed correction"); err != nil || len(hits) != 1 {
		t.Fatal("successful edit missing from new member's search")
	}
}

func TestDeleteReportRemovesOnlyOwnedReferencedOriginals(t *testing.T) {
	s, root := openTest(t)
	r := finishSources(t, s, multiDraft(t, s))
	unrelated := filepath.Join(root, "originals", opaqueID()+".blob")
	if err := os.WriteFile(unrelated, []byte("synthetic unreferenced"), 0600); err != nil {
		t.Fatal(err)
	}
	result, err := s.DeleteReport(ctx, r.ID)
	if err != nil || result.CleanupPending {
		t.Fatalf("delete: %v pending %v", err, result.CleanupPending)
	}
	if _, err := s.Get(ctx, r.ID); !errors.Is(err, ErrNotFound) {
		t.Fatal("deleted report remains")
	}
	for _, source := range r.Sources {
		if _, err := os.Lstat(filepath.Join(root, "originals", source.ID+".blob")); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("owned original remains")
		}
	}
	if _, err := os.Stat(unrelated); err != nil {
		t.Fatal("unrelated orphan deleted")
	}
}

func TestDeleteCleanupPendingRetriesOnReopenAndPreservesReplacement(t *testing.T) {
	for _, replace := range []bool{false, true} {
		name := "resume"
		if replace {
			name = "replacement"
		}
		t.Run(name, func(t *testing.T) {
			s, root := openTest(t)
			r := finishSources(t, s, multiDraft(t, s))
			if err := os.Chmod(filepath.Join(root, "originals"), 0500); err != nil {
				t.Fatal(err)
			}
			result, err := s.DeleteReport(ctx, r.ID)
			if err != nil || !result.CleanupPending {
				t.Fatalf("committed deletion did not report pending cleanup: %v", err)
			}
			if _, err := s.Get(ctx, r.ID); !errors.Is(err, ErrNotFound) {
				t.Fatal("committed delete reported as still present")
			}
			if err := os.Chmod(filepath.Join(root, "originals"), 0700); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(root, "originals", r.Sources[0].ID+".blob")
			if replace {
				// Keep the old inode alive so inode reuse cannot hide replacement.
				if err := os.Rename(path, path+".saved"); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, []byte{1}, 0600); err != nil {
					t.Fatal(err)
				}
			}
			if err := s.Close(); err != nil {
				t.Fatal(err)
			}
			s, err = Open(root)
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			_, err = os.Lstat(path)
			if replace && err != nil || !replace && !errors.Is(err, os.ErrNotExist) {
				t.Fatal("cleanup identity check failed")
			}
		})
	}
}

func TestDeleteAndReadOriginalSerialize(t *testing.T) {
	s, _ := openTest(t)
	r := finishSources(t, s, multiDraft(t, s))
	var wait sync.WaitGroup
	for i := 0; i < 8; i++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			_, err := s.ReadOriginal(context.Background(), r.ID, r.Sources[0].ID)
			if err != nil && !errors.Is(err, ErrNotFound) {
				t.Errorf("concurrent original access: %v", err)
			}
		}()
	}
	if _, err := s.DeleteReport(ctx, r.ID); err != nil {
		t.Fatal(err)
	}
	wait.Wait()
}

func TestDeleteFailureBeforeCommitKeepsReportAndAllOriginals(t *testing.T) {
	s, root := openTest(t)
	r := finishSources(t, s, multiDraft(t, s))
	if _, err := s.db.Exec("CREATE TRIGGER reject_delete BEFORE DELETE ON reports BEGIN SELECT RAISE(ABORT, 'synthetic'); END"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DeleteReport(ctx, r.ID); !errors.Is(err, ErrStorage) {
		t.Fatalf("expected write failure: %v", err)
	}
	if _, err := s.Get(ctx, r.ID); err != nil {
		t.Fatal("uncommitted deletion lost report")
	}
	var count int
	if err := s.db.QueryRow("SELECT count(*) FROM pending_deletions").Scan(&count); err != nil || count != 0 {
		t.Fatal("uncommitted deletion left cleanup authority")
	}
	for _, source := range r.Sources {
		if _, err := os.Stat(filepath.Join(root, "originals", source.ID+".blob")); err != nil {
			t.Fatal("uncommitted deletion removed original")
		}
	}
}

func TestDeletionCrashHelper(t *testing.T) {
	root := os.Getenv("KINLOGUE_TEST_DELETE_ROOT")
	if root == "" {
		return
	}
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.deleteReport(ctx, os.Getenv("KINLOGUE_TEST_DELETE_ID"), func() {
		fmt.Fprintln(os.Stdout, "delete committed")
		killAtCheckpoint(t)
	})
	t.Fatalf("deletion checkpoint not reached: %v", err)
}

func TestDeletionCommitSurvivesProcessKillAndCleansOnOpen(t *testing.T) {
	s, root := openTest(t)
	r := finishSources(t, s, multiDraft(t, s))
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	lifetime, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	command := exec.CommandContext(lifetime, executable, "-test.run=^TestDeletionCrashHelper$")
	command.Env = append(os.Environ(), "KINLOGUE_TEST_DELETE_ROOT="+root, "KINLOGUE_TEST_DELETE_ID="+r.ID)
	output, err := command.CombinedOutput()
	assertCheckpointKilled(t, lifetime, output, err, "delete committed")
	// The checkpoint precedes every unlink.
	for _, source := range r.Sources {
		if _, err := os.Stat(filepath.Join(root, "originals", source.ID+".blob")); err != nil {
			t.Fatal("checkpoint removed original")
		}
	}
	s, err = Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.Get(ctx, r.ID); !errors.Is(err, ErrNotFound) {
		t.Fatal("deleted report returned after restart")
	}
	for _, source := range r.Sources {
		if _, err := os.Stat(filepath.Join(root, "originals", source.ID+".blob")); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("queued cleanup did not resume")
		}
	}
	var count int
	if err := s.db.QueryRow("SELECT count(*) FROM pending_deletions").Scan(&count); err != nil || count != 0 {
		t.Fatal("durable cleanup queue remains")
	}
}

func TestDeleteDamagedOriginalOnlyRemovesReport(t *testing.T) {
	for _, kind := range []string{"symlink", "hardlink", "corrupt", "missing"} {
		t.Run(kind, func(t *testing.T) {
			s, root := openTest(t)
			r := ready(t, s)
			path := filepath.Join(root, "originals", r.Sources[0].ID+".blob")
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			target := filepath.Join(t.TempDir(), "synthetic")
			if err := os.WriteFile(target, []byte("synthetic-original"), 0600); err != nil {
				t.Fatal(err)
			}
			var err error
			switch kind {
			case "symlink":
				err = os.Symlink(target, path)
			case "hardlink":
				err = os.Link(target, path)
			case "corrupt":
				err = os.WriteFile(path, []byte("synthetic-corrupt!"), 0600)
			}
			if err != nil {
				t.Fatal(err)
			}
			result, err := s.DeleteReport(ctx, r.ID)
			if err != nil || result.CleanupPending != (kind != "missing") {
				t.Fatalf("damaged deletion result: %v pending %v", err, result.CleanupPending)
			}
			if _, err := s.Get(ctx, r.ID); !errors.Is(err, ErrNotFound) {
				t.Fatal("report was not deleted")
			}
			if kind != "missing" {
				if _, err := os.Lstat(path); err != nil {
					t.Fatal("unsafe original unlinked")
				}
			}
			if data, err := os.ReadFile(target); err != nil || string(data) != "synthetic-original" {
				t.Fatal("unowned target changed")
			}
			another := ready(t, s)
			if result, err := s.DeleteReport(ctx, another.ID); err != nil || result.CleanupPending {
				t.Fatal("unrelated queue changed this deletion result")
			}
		})
	}
}
