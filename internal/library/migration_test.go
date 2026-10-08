package library

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"kinlogue/internal/document"
)

// This is the original Go preview v1 schema, deliberately independent of the
// current schema constant. Rebuilding fixtures through Open would only test
// the new format against itself and miss destructive migration regressions.
const migrationV1Schema = `
CREATE TABLE members (id TEXT PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE reports (
 id TEXT PRIMARY KEY, file_name TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('processing','review','failed','confirmed')),
 member_id TEXT REFERENCES members(id), title TEXT NOT NULL DEFAULT '', report_date TEXT NOT NULL DEFAULT '',
 corrected_text TEXT NOT NULL DEFAULT '', notes TEXT NOT NULL DEFAULT '', extraction TEXT NOT NULL DEFAULT '',
 created_at TEXT NOT NULL, failure TEXT NOT NULL DEFAULT '', digest TEXT NOT NULL, byte_count INTEGER NOT NULL CHECK(byte_count > 0)
);
CREATE INDEX reports_member_date ON reports(member_id, status, report_date);
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO settings VALUES ('language', 'zh-Hans');
PRAGMA application_id=1263290191;
PRAGMA user_version=1;`

type migrationV1Report struct {
	id, fileName, status, createdAt, failure string
	review                                   Edit
	extraction                               document.Extraction
	original                                 []byte
}

type migrationV1Fixture struct {
	root    string
	members []Member
	reports []migrationV1Report
}

func createMigrationV1Fixture(t *testing.T) migrationV1Fixture {
	t.Helper()
	f := migrationV1Fixture{
		root: filepath.Join(t.TempDir(), "library"),
		members: []Member{
			{ID: "10000000000000000000000000000001", Name: "合成旧成员甲"},
			{ID: "10000000000000000000000000000002", Name: "Synthetic legacy member B"},
		},
	}
	for _, path := range []string{f.root, filepath.Join(f.root, "originals")} {
		if err := os.Mkdir(path, 0700); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(f.root, "library.sqlite")
	if err := os.WriteFile(path, nil, 0600); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec("PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA; PRAGMA foreign_keys=ON;" + migrationV1Schema); err != nil {
		t.Fatal(err)
	}
	for _, member := range f.members {
		if _, err := db.Exec("INSERT INTO members(id,name) VALUES(?,?)", member.ID, member.Name); err != nil {
			t.Fatal(err)
		}
	}
	for i, status := range []string{"review", "confirmed", "failed", "processing"} {
		r := migrationV1Report{
			id:        fmt.Sprintf("2000000000000000000000000000000%d", i+1),
			fileName:  fmt.Sprintf("../../synthetic-v1-%d.pdf", i+1),
			status:    status,
			createdAt: fmt.Sprintf("2026-10-0%dT01:02:03.000000001Z", i+1),
			original:  []byte(fmt.Sprintf("synthetic original v1 %d", i+1)),
		}
		var member any
		raw := ""
		if status == "review" || status == "confirmed" {
			r.review = Edit{MemberID: f.members[0].ID, Title: "合成旧标题 " + status, Text: "合成已修正文案 " + status, Notes: "合成旧备注 " + status}
			if status == "confirmed" {
				r.review.Date = "2026-10-02"
			}
			member = r.review.MemberID
			r.extraction = document.Extraction{
				Kind: "pdf", PageCount: 2, Engine: "synthetic-v1",
				Blocks: []document.Block{
					{Page: 1, Text: "raw-v1 synthetic page one", Method: "synthetic", Confidence: .95, Bounds: document.Rect{X: .1, Y: .2, Width: .3, Height: .1}},
					{Page: 2, Text: "raw-v1 合成第二页", Method: "synthetic", Confidence: .8, Bounds: document.Rect{X: .2, Y: .3, Width: .4, Height: .2}},
				},
			}
			encoded, err := json.Marshal(r.extraction)
			if err != nil {
				t.Fatal(err)
			}
			raw = string(encoded)
		}
		if status == "failed" {
			r.failure = "recognition"
		}
		r.review.SourceIDs = []string{r.id}
		digest := sha256.Sum256(r.original)
		if _, err := db.Exec(`INSERT INTO reports
		 (id,file_name,status,member_id,title,report_date,corrected_text,notes,extraction,created_at,failure,digest,byte_count)
		 VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)`, r.id, r.fileName, r.status, member, r.review.Title, r.review.Date, r.review.Text, r.review.Notes, raw, r.createdAt, r.failure, hex.EncodeToString(digest[:]), len(r.original)); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(f.root, "originals", r.id+".blob"), r.original, 0600); err != nil {
			t.Fatal(err)
		}
		f.reports = append(f.reports, r)
	}
	return f
}

func assertMigratedV1Fixture(t *testing.T, s *Store, f migrationV1Fixture) {
	t.Helper()
	var version, application int
	if err := s.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 2 {
		t.Fatalf("migration version = %d, error %v", version, err)
	}
	if err := s.db.QueryRow("PRAGMA application_id").Scan(&application); err != nil || application != 1263290191 {
		t.Fatal("migration lost application identity")
	}
	members, err := s.Members(ctx)
	if err != nil || len(members) != len(f.members) {
		t.Fatal("migration lost members")
	}
	for _, expected := range f.members {
		found := false
		for _, got := range members {
			found = found || got == expected
		}
		if !found {
			t.Fatal("migration changed member identity or name")
		}
	}
	if language, err := s.Language(ctx); err != nil || language != "zh-Hans" {
		t.Fatal("migration changed language preference")
	}
	for _, expected := range f.reports {
		got, err := s.Get(ctx, expected.id)
		if err != nil {
			t.Fatalf("migrated record unavailable: %v", err)
		}
		status, failure := expected.status, expected.failure
		if status == "processing" {
			status, failure = "failed", "interrupted"
		}
		if got.ID != expected.id || got.Status != status || got.Failure != failure || got.CreatedAt != expected.createdAt || !got.Review.Equal(expected.review) {
			t.Fatal("migration changed report identity, state, creation date or user corrections")
		}
		if len(got.Sources) != 1 {
			t.Fatal("old report did not become exactly one source")
		}
		source := got.Sources[0]
		if source.ID != expected.id || source.FileName != expected.fileName || !reflect.DeepEqual(source.Extraction, expected.extraction) {
			t.Fatal("migration changed the original source identity, display name or raw extraction")
		}
		data, err := s.ReadOriginal(ctx, got.ID, source.ID)
		if err != nil || !bytes.Equal(data, expected.original) {
			t.Fatal("migration lost original bytes or integrity metadata")
		}
	}
	drafts, err := s.Drafts(ctx)
	if err != nil || len(drafts) != 3 {
		t.Fatal("migration changed draft visibility")
	}
	for _, query := range []string{"", "已修正文案", "旧备注", "旧标题"} {
		found, err := s.Search(ctx, f.members[0].ID, query)
		if err != nil || len(found) != 1 || found[0].ID != f.reports[1].id {
			t.Fatal("migration lost confirmed corrected-content search")
		}
	}
	for _, query := range []struct{ member, text string }{{f.members[0].ID, "raw-v1"}, {f.members[1].ID, ""}} {
		found, err := s.Search(ctx, query.member, query.text)
		if err != nil || len(found) != 0 {
			t.Fatal("migration leaked raw extraction or another member's records")
		}
	}
	files, err := os.ReadDir(filepath.Join(f.root, "originals"))
	if err != nil || len(files) != len(f.reports) {
		t.Fatal("migration duplicated or removed original blobs")
	}
}

func TestMigrationPreservesVersionOneLibrary(t *testing.T) {
	f := createMigrationV1Fixture(t)
	for attempt := 0; attempt < 2; attempt++ {
		s, err := Open(f.root)
		if err != nil {
			t.Fatalf("opening existing v1 library: %v", err)
		}
		assertMigratedV1Fixture(t, s, f)
		if err := s.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestMigrationRetainsOriginalIntegrityCheck(t *testing.T) {
	f := createMigrationV1Fixture(t)
	s, err := Open(f.root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	r := f.reports[1]
	altered := append([]byte(nil), r.original...)
	altered[0] ^= 1 // Same length: byte-count validation cannot hide a lost hash.
	if err := os.WriteFile(filepath.Join(f.root, "originals", r.id+".blob"), altered, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ReadOriginal(ctx, r.id, r.id); !errors.Is(err, ErrCorrupt) {
		t.Fatalf("migrated original no longer detects changed content: %v", err)
	}
}

func TestMigrationCrashHelper(t *testing.T) {
	stage := os.Getenv("KINLOGUE_TEST_MIGRATION_STAGE")
	if stage == "" {
		return
	}
	s, err := openLibrary(os.Getenv("KINLOGUE_TEST_MIGRATION_ROOT"), func(current string) {
		if current == stage {
			fmt.Fprintln(os.Stdout, "migration checkpoint reached")
			killAtCheckpoint(t)
		}
	})
	if s != nil {
		_ = s.Close()
	}
	t.Fatalf("migration checkpoint not reached: %v", err)
}

func TestMigrationRecoversAfterProcessKill(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, stage := range []string{"migration_uncommitted", "migration_committed"} {
		t.Run(stage, func(t *testing.T) {
			f := createMigrationV1Fixture(t)
			commandContext, cancel := context.WithTimeout(ctx, 15*time.Second)
			defer cancel()
			command := exec.CommandContext(commandContext, executable, "-test.run=^TestMigrationCrashHelper$")
			command.Env = append(os.Environ(), "KINLOGUE_TEST_MIGRATION_ROOT="+f.root, "KINLOGUE_TEST_MIGRATION_STAGE="+stage)
			output, err := command.CombinedOutput()
			assertCheckpointKilled(t, commandContext, output, err, "migration checkpoint reached")
			for attempt := 0; attempt < 2; attempt++ {
				s, err := Open(f.root)
				if err != nil {
					t.Fatalf("restart after %s: %v", stage, err)
				}
				assertMigratedV1Fixture(t, s, f)
				if err := s.Close(); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

func migrationSchemaSnapshot(t *testing.T, db *sql.DB) [][4]string {
	t.Helper()
	rows, err := db.Query("SELECT type,name,tbl_name,COALESCE(sql,'') FROM sqlite_schema ORDER BY type,name")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var result [][4]string
	for rows.Next() {
		var row [4]string
		if err := rows.Scan(&row[0], &row[1], &row[2], &row[3]); err != nil {
			t.Fatal(err)
		}
		result = append(result, row)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return result
}

func TestMigrationRejectsInvalidOldSchemaWithoutPartialUpgrade(t *testing.T) {
	f := createMigrationV1Fixture(t)
	db, err := sql.Open("sqlite", filepath.Join(f.root, "library.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("ALTER TABLE reports DROP COLUMN digest"); err != nil {
		t.Fatal(err)
	}
	before := migrationSchemaSnapshot(t, db)
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if s, err := Open(f.root); err == nil {
		_ = s.Close()
		t.Fatal("invalid old schema accepted")
	}
	db, err = sql.Open("sqlite", filepath.Join(f.root, "library.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var version int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 1 {
		t.Fatal("failed migration published a version change")
	}
	if after := migrationSchemaSnapshot(t, db); !reflect.DeepEqual(before, after) {
		t.Fatal("failed migration changed schema or left partial tables")
	}
	for _, expected := range f.reports {
		var status, text, raw string
		if err := db.QueryRow("SELECT status,corrected_text,extraction FROM reports WHERE id=?", expected.id).Scan(&status, &text, &raw); err != nil {
			t.Fatal("failed migration removed an old row")
		}
		if status != expected.status || text != expected.review.Text {
			t.Fatal("failed migration changed old report state or corrections")
		}
		if expected.extraction.Engine != "" {
			var got document.Extraction
			if json.Unmarshal([]byte(raw), &got) != nil || !reflect.DeepEqual(got, expected.extraction) {
				t.Fatal("failed migration changed raw extraction")
			}
		}
		data, err := os.ReadFile(filepath.Join(f.root, "originals", expected.id+".blob"))
		if err != nil || !bytes.Equal(data, expected.original) {
			t.Fatal("failed migration changed original bytes")
		}
	}
}
