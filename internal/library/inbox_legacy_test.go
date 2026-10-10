package library

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// Construct the shipped v3 schema and a frozen v1 tar independently of the
// current Store initializer and snapshot header encoder. This models a v3
// binary killed with a committed, unretired restore journal.
func TestInboxLegacyV1BackupAndUnretiredV3Journal(t *testing.T) {
	fixture := createMigrationV2Fixture(t)
	db, e := sql.Open("sqlite", filepath.Join(fixture.root, "library.sqlite"))
	if e != nil {
		t.Fatal(e)
	}
	if _, e = db.Exec("PRAGMA user_version=3; UPDATE reports SET status='failed',failure='interrupted' WHERE status='processing'"); e != nil {
		t.Fatal(e)
	}
	schemaDigest, e := runtimeSchemaDigest(db)
	if e != nil {
		t.Fatal(e)
	}
	var old bytes.Buffer
	w := tar.NewWriter(&old)
	members := append([]Member(nil), fixture.members...)
	sort.Slice(members, func(i, j int) bool { return members[i].Name < members[j].Name })
	header, _ := json.Marshal(struct {
		Version  int
		Language string
		Members  []Member
		Reports  int
	}{1, "zh-Hans", members, len(fixture.reports)})
	if e = writeSnapshotEntry(w, "library.json", header); e != nil {
		t.Fatal(e)
	}
	for _, item := range fixture.reports {
		hash := sha256.Sum256(item.original)
		status, failure := item.status, item.failure
		if status == "processing" {
			status = "failed"
			failure = "interrupted"
		}
		review := item.review
		review.SourceIDs = []string{item.id}
		report := snapshotReport{Report: Report{ID: item.id, FileName: item.fileName, Status: status, CreatedAt: item.createdAt, Failure: failure, Review: review, Sources: []Source{{ID: item.id, FileName: item.fileName, Extraction: item.extraction}}}, Originals: []snapshotOriginal{{hex.EncodeToString(hash[:]), int64(len(item.original))}}}
		data, _ := json.Marshal(report)
		if e = writeSnapshotEntry(w, "reports/"+item.id+".json", data); e != nil {
			t.Fatal(e)
		}
		if e = writeSnapshotEntry(w, "originals/"+item.id+".blob", item.original); e != nil {
			t.Fatal(e)
		}
	}
	if e = w.Close(); e != nil {
		t.Fatal(e)
	}
	db.Close()
	target, _ := openTest(t)
	if summary, e := target.RestoreSnapshot(ctx, bytes.NewReader(old.Bytes())); e != nil || summary.Inbox != 0 || summary.Reports != 4 {
		t.Fatalf("legacy backup: %+v %v", summary, e)
	}
	if e = os.WriteFile(filepath.Join(fixture.root, ".owner.lock"), nil, 0600); e != nil {
		t.Fatal(e)
	}
	root := runtimeTestRoot(t)
	runtime, e := acquireRuntime(root, nil)
	if e != nil {
		t.Fatal(e)
	}
	if e = os.Rename(fixture.root, root); e != nil {
		t.Fatal(e)
	}
	identity, e := runtime.directoryIdentity(runtime.rootName)
	if e != nil {
		t.Fatal(e)
	}
	hash := sha256.Sum256(old.Bytes())
	journal := &restoreJournal{Version: 1, Root: runtime.rootName, Parent: fileIdentity(runtime.parentIdentity), ID: opaqueID(), Candidate: identity, Digest: hex.EncodeToString(hash[:]), Schema: schemaDigest, Phase: "committed"}
	if e = runtime.verifyCandidate(runtime.rootName, journal); e != nil {
		t.Fatal("legacy checksum rejected", e)
	}
	if e = runtime.writeJournal(journal); e != nil {
		t.Fatal(e)
	}
	runtime.Close()
	runtime, e = OpenRuntime(root)
	if e != nil {
		t.Fatal(e)
	}
	defer runtime.Close()
	if runtime.Store() == nil {
		t.Fatal("legacy journal failed", runtime.OpenError())
	}
	items, e := runtime.Store().Inbox(ctx)
	if e != nil || len(items) != 0 {
		t.Fatal("legacy recovery/migration failed", e)
	}
	var version int
	if e = runtime.Store().db.QueryRow("PRAGMA user_version").Scan(&version); e != nil || version != 4 {
		t.Fatal("v3 was not upgraded after journal retired")
	}
	if _, e = os.Stat(filepath.Join(filepath.Dir(root), restoreJournalName)); !os.IsNotExist(e) {
		t.Fatal("journal not retired")
	}
}
