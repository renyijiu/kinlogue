package library

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"kinlogue/internal/document"
)

func fieldsEdit(r Report, member string) Edit {
	e := r.Review
	e.MemberID, e.Title = member, "Synthetic title"
	e.Organization, e.Department, e.ReportType = "合成医院 Synthetic Hospital", "合成科室", "Synthetic CT"
	e.Conclusion = "合成结论 Verbatim Conclusion"
	return e
}

func TestStructuredFieldsSurviveSaveConfirmEditAndReopen(t *testing.T) {
	s, root := openTest(t)
	m, _ := s.AddMember(ctx, "Synthetic member")
	r := ready(t, s)
	if r.Review.hasFields() {
		t.Fatal("recognition must not fill verbatim fields")
	}
	e := fieldsEdit(r, m.ID)
	saved, err := s.SaveReview(ctx, r.ID, e)
	if err != nil || !saved.Review.Equal(e) {
		t.Fatalf("draft fields not saved: %v", err)
	}
	e.Department = "合成科室二"
	confirmed, err := s.Confirm(ctx, r.ID, e)
	if err != nil || !confirmed.Review.Equal(e) {
		t.Fatalf("confirmation lost fields: %v", err)
	}
	e.Conclusion, e.Organization = "", ""
	updated, err := s.UpdateConfirmed(ctx, r.ID, e)
	if err != nil || !updated.Review.Equal(e) {
		t.Fatalf("confirmed edit could not clear fields: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if got, err := s.Get(ctx, r.ID); err != nil || !got.Review.Equal(e) {
		t.Fatalf("fields changed across reopen: %v", err)
	}
}

func TestStructuredFieldsAreBoundedAndInvalidEditKeepsReport(t *testing.T) {
	s, _ := openTest(t)
	m, _ := s.AddMember(ctx, "Synthetic member")
	r := ready(t, s)
	good := fieldsEdit(r, m.ID)
	if _, err := s.SaveReview(ctx, r.ID, good); err != nil {
		t.Fatal(err)
	}
	for name, mutate := range map[string]func(*Edit){
		"organization": func(e *Edit) { e.Organization = strings.Repeat("x", 1025) },
		"department":   func(e *Edit) { e.Department = strings.Repeat("x", 1025) },
		"report type":  func(e *Edit) { e.ReportType = strings.Repeat("x", 1025) },
		"conclusion":   func(e *Edit) { e.Conclusion = strings.Repeat("x", document.MaxTextBytes+1) },
		"invalid text": func(e *Edit) { e.Organization = "\xff" },
		"NUL":          func(e *Edit) { e.Conclusion = "a\x00b" },
	} {
		bad := good
		mutate(&bad)
		if _, err := s.SaveReview(ctx, r.ID, bad); !errors.Is(err, ErrInvalid) {
			t.Fatalf("%s: unbounded field accepted: %v", name, err)
		}
		if got, err := s.Get(ctx, r.ID); err != nil || !got.Review.Equal(good) {
			t.Fatalf("%s: rejected edit changed the draft", name)
		}
	}
	limit := good
	limit.Organization, limit.Conclusion = strings.Repeat("x", 1024), strings.Repeat("y", document.MaxTextBytes)
	if _, err := s.SaveReview(ctx, r.ID, limit); err != nil {
		t.Fatalf("fields at their limits rejected: %v", err)
	}
}

func TestSearchCoversConfirmedStructuredFieldsOnly(t *testing.T) {
	s, _ := openTest(t)
	a, _ := s.AddMember(ctx, "Synthetic member A")
	b, _ := s.AddMember(ctx, "Synthetic member B")
	confirmed := ready(t, s)
	e := fieldsEdit(confirmed, a.ID)
	if _, err := s.Confirm(ctx, confirmed.ID, e); err != nil {
		t.Fatal(err)
	}
	draft := ready(t, s)
	if _, err := s.SaveReview(ctx, draft.ID, fieldsEdit(draft, a.ID)); err != nil {
		t.Fatal(err)
	}
	for _, query := range []string{"合成医院", "synthetic hospital", "合成科室", "SYNTHETIC ct", "合成结论", "verbatim conclusion"} {
		for _, member := range []string{"", a.ID} {
			found, err := s.Search(ctx, member, query)
			if err != nil || len(found) != 1 || found[0].ID != confirmed.ID {
				t.Fatalf("%q did not find exactly the confirmed report: %v", query, err)
			}
		}
		if found, err := s.Search(ctx, b.ID, query); err != nil || len(found) != 0 {
			t.Fatalf("%q leaked into another member", query)
		}
	}
	// The match is literal: SQL wildcards are ordinary characters.
	if found, err := s.Search(ctx, "", "合成%"); err != nil || len(found) != 0 {
		t.Fatal("wildcard matched a field")
	}
}

func TestListRowsCarryShortFieldsAndBoundedSummary(t *testing.T) {
	s, _ := openTest(t)
	m, _ := s.AddMember(ctx, "Synthetic member")
	r := ready(t, s)
	e := fieldsEdit(r, m.ID)
	e.Conclusion = strings.Repeat("结", SummaryRunes+50)
	if _, err := s.Confirm(ctx, r.ID, e); err != nil {
		t.Fatal(err)
	}
	found, err := s.Search(ctx, "", "")
	if err != nil || len(found) != 1 {
		t.Fatal(err)
	}
	row := found[0]
	if row.Review.Organization != e.Organization || row.Review.Department != e.Department || row.Review.ReportType != e.ReportType {
		t.Fatal("list row lost short fields")
	}
	if row.Review.Conclusion != "" || row.Review.Text != "" || row.Review.Notes != "" {
		t.Fatal("list row loaded long text")
	}
	if utf8.RuneCountInString(row.Summary) != SummaryRunes || !strings.HasPrefix(e.Conclusion, row.Summary) {
		t.Fatalf("summary is not the bounded start of the conclusion: %d runes", utf8.RuneCountInString(row.Summary))
	}
	if got, _ := s.Get(ctx, r.ID); got.Review.Conclusion != e.Conclusion || got.Summary != "" {
		t.Fatal("full report must carry the whole conclusion")
	}
}

// createMigrationV4Fixture builds the shipped v4 library directly from the
// frozen v2 fixture and inbox statements, without the current Open.
func createMigrationV4Fixture(t *testing.T) migrationV1Fixture {
	t.Helper()
	f := createMigrationV2Fixture(t)
	db, err := sql.Open("sqlite", filepath.Join(f.root, "library.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(inboxSchema + "PRAGMA user_version=4; UPDATE reports SET status='failed',failure='interrupted' WHERE status='processing'"); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestNewAndMigratedLibrariesShareOneSchema(t *testing.T) {
	fresh, _ := openTest(t)
	want := migrationSchemaSnapshot(t, fresh.db)
	for name, fixture := range map[string]func(*testing.T) migrationV1Fixture{"v1": createMigrationV1Fixture, "v2": createMigrationV2Fixture, "v4": createMigrationV4Fixture} {
		f := fixture(t)
		s, err := Open(f.root)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if got := migrationSchemaSnapshot(t, s.db); !reflect.DeepEqual(got, want) {
			t.Fatalf("%s migrated to a different schema than a new library", name)
		}
		s.Close()
	}
}

func TestMigrationVersionFourKeepsReportsAndAcceptsFields(t *testing.T) {
	f := createMigrationV4Fixture(t)
	for range 2 {
		s, err := Open(f.root)
		if err != nil {
			t.Fatal(err)
		}
		assertMigratedV1Fixture(t, s, f)
		s.Close()
	}
	s, err := Open(f.root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	confirmed := f.reports[1]
	got, err := s.Get(ctx, confirmed.id)
	if err != nil || got.Review.hasFields() {
		t.Fatal("migration invented field values")
	}
	e := fieldsEdit(got, got.Review.MemberID)
	e.Title = got.Review.Title
	if updated, err := s.UpdateConfirmed(ctx, confirmed.id, e); err != nil || !updated.Review.Equal(e) {
		t.Fatalf("migrated report cannot take fields: %v", err)
	}
}

func TestMigrationVersionFourRecoversAfterProcessKill(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, stage := range []string{"migration_uncommitted", "migration_committed"} {
		t.Run(stage, func(t *testing.T) {
			f := createMigrationV4Fixture(t)
			lifetime, cancel := context.WithTimeout(ctx, 15*time.Second)
			defer cancel()
			command := exec.CommandContext(lifetime, executable, "-test.run=^TestMigrationCrashHelper$")
			command.Env = append(os.Environ(), "KINLOGUE_TEST_MIGRATION_ROOT="+f.root, "KINLOGUE_TEST_MIGRATION_STAGE="+stage)
			output, err := command.CombinedOutput()
			assertCheckpointKilled(t, lifetime, output, err, "migration checkpoint reached")
			db, err := sql.Open("sqlite", filepath.Join(f.root, "library.sqlite"))
			if err != nil {
				t.Fatal(err)
			}
			var version, columns int
			if db.QueryRow("PRAGMA user_version").Scan(&version) != nil || db.QueryRow("SELECT count(*) FROM pragma_table_info('reports') WHERE name IN ('organization','department','report_type','conclusion')").Scan(&columns) != nil {
				t.Fatal("interrupted migration unreadable")
			}
			db.Close()
			// The version and the columns it promises change together.
			if stage == "migration_uncommitted" && (version != 4 || columns != 0) || stage == "migration_committed" && (version != 5 || columns != 4) {
				t.Fatalf("version %d with %d field columns escaped the migration transaction", version, columns)
			}
			for range 2 {
				s, err := Open(f.root)
				if err != nil {
					t.Fatal(err)
				}
				assertMigratedV1Fixture(t, s, f)
				s.Close()
			}
		})
	}
}

func TestSnapshotRoundTripKeepsStructuredFields(t *testing.T) {
	s, _ := openTest(t)
	m, _ := s.AddMember(ctx, "Synthetic member")
	r := ready(t, s)
	e := fieldsEdit(r, m.ID)
	if _, err := s.Confirm(ctx, r.ID, e); err != nil {
		t.Fatal(err)
	}
	plain := ready(t, s)
	var archive bytes.Buffer
	if _, err := s.WriteSnapshot(ctx, &archive); err != nil {
		t.Fatal(err)
	}
	entries := snapshotEntries(t, archive.Bytes())
	if !bytes.HasPrefix(entries[0].data, []byte(`{"Version":3,`)) {
		t.Fatal("a library with field columns must write snapshot v3")
	}
	for _, entry := range entries {
		// A report without field values serializes exactly as in snapshot v2.
		if entry.header.Name == "reports/"+plain.ID+".json" {
			for _, key := range []string{"Organization", "Department", "ReportType", "Conclusion", "Summary"} {
				if bytes.Contains(entry.data, []byte(`"`+key+`"`)) {
					t.Fatalf("empty %s was written", key)
				}
			}
		}
	}
	target, _ := openTest(t)
	if _, err := target.RestoreSnapshot(ctx, bytes.NewReader(archive.Bytes())); err != nil {
		t.Fatal(err)
	}
	if got, err := target.Get(ctx, r.ID); err != nil || !got.Review.Equal(e) {
		t.Fatalf("restore lost fields: %v", err)
	}
	if found, _ := target.Search(ctx, "", "verbatim conclusion"); len(found) != 1 {
		t.Fatal("restored fields are not searchable")
	}
	var again bytes.Buffer
	if _, err := target.WriteSnapshot(ctx, &again); err != nil || !bytes.Equal(archive.Bytes(), again.Bytes()) {
		t.Fatal("snapshot with fields is not deterministic")
	}

	// Older formats never wrote fields; accepting them there would let two
	// readers disagree about one archive.
	for _, version := range []string{`{"Version":1,`, `{"Version":2,`} {
		old := snapshotEntries(t, archive.Bytes())
		old[0].data = append([]byte(version), old[0].data[len(`{"Version":3,`):]...)
		if version == `{"Version":1,` {
			old[0].data = bytes.Replace(old[0].data, []byte(`,"Inbox":0`), nil, 1)
		}
		other, _ := openTest(t)
		if _, err := other.RestoreSnapshot(ctx, bytes.NewReader(encodeSnapshotEntries(t, old))); !errors.Is(err, ErrCorrupt) {
			t.Fatalf("%s accepted structured fields: %v", version, err)
		}
		if members, _ := other.Members(ctx); len(members) != 0 {
			t.Fatal("rejected restore committed data")
		}
	}
}

// These mirror the report JSON of the shipped snapshot v2 writer, independent
// of the current Edit and Report types.
type frozenV2Edit struct {
	MemberID, Title, Date, Text, Notes string
	SourceIDs                          []string
}

type frozenV2Report struct {
	ID, FileName, Status string
	Review               frozenV2Edit
	Sources              []Source
	CreatedAt            string
	Failure              string
	Originals            []snapshotOriginal
}

// A v4 binary killed with a committed, unretired restore journal leaves a v4
// candidate whose digest covers the v2 serialization. The current reader must
// verify it byte for byte before it migrates anything.
func TestFieldsUnretiredV4JournalAndLegacyV2Backup(t *testing.T) {
	fixture := createMigrationV4Fixture(t)
	db, err := sql.Open("sqlite", filepath.Join(fixture.root, "library.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	schemaDigest, err := runtimeSchemaDigest(db)
	db.Close()
	if err != nil {
		t.Fatal(err)
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
		Inbox    int
	}{2, "zh-Hans", members, len(fixture.reports), 0})
	if err = writeSnapshotEntry(w, "library.json", header); err != nil {
		t.Fatal(err)
	}
	for _, item := range fixture.reports {
		hash := sha256.Sum256(item.original)
		status, failure := item.status, item.failure
		if status == "processing" {
			status, failure = "failed", "interrupted"
		}
		review := frozenV2Edit{item.review.MemberID, item.review.Title, item.review.Date, item.review.Text, item.review.Notes, []string{item.id}}
		data, _ := json.Marshal(frozenV2Report{ID: item.id, FileName: item.fileName, Status: status, Review: review, Sources: []Source{{ID: item.id, FileName: item.fileName, Extraction: item.extraction}}, CreatedAt: item.createdAt, Failure: failure, Originals: []snapshotOriginal{{hex.EncodeToString(hash[:]), int64(len(item.original))}}})
		if err = writeSnapshotEntry(w, "reports/"+item.id+".json", data); err != nil {
			t.Fatal(err)
		}
		if err = writeSnapshotEntry(w, "originals/"+item.id+".blob", item.original); err != nil {
			t.Fatal(err)
		}
	}
	if err = w.Close(); err != nil {
		t.Fatal(err)
	}
	target, _ := openTest(t)
	if summary, err := target.RestoreSnapshot(ctx, bytes.NewReader(old.Bytes())); err != nil || summary.Reports != len(fixture.reports) {
		t.Fatalf("legacy v2 backup: %+v %v", summary, err)
	}
	if got, err := target.Get(ctx, fixture.reports[1].id); err != nil || got.Review.hasFields() {
		t.Fatal("legacy backup restored with invented fields")
	}

	if err = os.WriteFile(filepath.Join(fixture.root, ".owner.lock"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	root := runtimeTestRoot(t)
	runtime, err := acquireRuntime(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Rename(fixture.root, root); err != nil {
		t.Fatal(err)
	}
	identity, err := runtime.directoryIdentity(runtime.rootName)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(old.Bytes())
	journal := &restoreJournal{Version: 1, Root: runtime.rootName, Parent: fileIdentity(runtime.parentIdentity), ID: opaqueID(), Candidate: identity, Digest: hex.EncodeToString(hash[:]), Schema: schemaDigest, Phase: "committed"}
	if err = runtime.verifyCandidate(runtime.rootName, journal); err != nil {
		t.Fatal("v4 candidate checksum rejected:", err)
	}
	if err = runtime.writeJournal(journal); err != nil {
		t.Fatal(err)
	}
	runtime.Close()
	runtime, err = OpenRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	if runtime.Store() == nil {
		t.Fatal("v4 journal failed:", runtime.OpenError())
	}
	var version int
	if err = runtime.Store().db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 5 {
		t.Fatal("v4 was not upgraded after the journal retired")
	}
	fixture.root = root
	assertMigratedV1Fixture(t, runtime.Store(), fixture)
	if _, err = os.Stat(filepath.Join(filepath.Dir(root), restoreJournalName)); !os.IsNotExist(err) {
		t.Fatal("journal not retired")
	}
}
