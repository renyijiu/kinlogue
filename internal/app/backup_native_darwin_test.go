//go:build darwin

package app

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"kinlogue/internal/library"
	"kinlogue/internal/macos"
)

func TestBackupControllerNativeFilesRoundTrip(t *testing.T) {
	b, service, _, root, _ := backupFixture(t)
	b.writeBackup, b.readBackup = macos.WriteBackup, macos.ReadBackup
	ctx := context.Background()
	member, err := service.AddMember(ctx, "Synthetic backup member")
	if err != nil {
		t.Fatal(err)
	}
	report, err := service.ImportMany(ctx, []string{"/synthetic/first.pdf", "/synthetic/second.pdf"})
	if err != nil {
		t.Fatal(err)
	}
	edit := report.Review
	edit.MemberID, edit.Title, edit.Notes = member.ID, "Synthetic backup report", "Synthetic backup note"
	report, err = service.Confirm(ctx, report.ID, edit)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "synthetic.kinloguegobackup")
	code := backupCode(t)
	summary, err := b.CreateBackup(ctx, path, code)
	if err != nil || summary.Members != 1 || summary.Reports != 1 || summary.Sources != 2 {
		t.Fatal("native backup failed")
	}
	if _, err := service.DeleteReport(ctx, report.ID); err != nil {
		t.Fatal(err)
	}
	p, err := b.PrepareRestore(ctx, path, code)
	if err != nil || p.Summary != summary {
		t.Fatal("native restore preparation failed")
	}
	if reports, err := service.Search(ctx, member.ID, ""); err != nil || len(reports) != 0 {
		t.Fatal("native preparation changed active library")
	}
	if restart, err := b.ActivateRestore(p.Handle); !restart || err != nil {
		t.Fatal("native restore activation failed")
	}
	if err := b.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := library.OpenRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	restored, err := reopened.Store().Get(ctx, report.ID)
	if err != nil || !restored.Review.Equal(edit) || len(restored.Sources) != 2 {
		t.Fatal("native restore lost report data")
	}
	for _, source := range restored.Sources {
		data, err := reopened.Store().ReadOriginal(ctx, report.ID, source.ID)
		if err != nil || string(data) != "SYNTHETIC ORIGINAL" {
			t.Fatal("native restore lost original bytes")
		}
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("published backup is not private")
	}
}
