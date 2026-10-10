package library

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

const restoreJournalName = ".restore-journal"

type restoreJournal struct {
	Version                                                 int
	Root, Parent, ID, Candidate, Old, Digest, Schema, Phase string
}

func (j *restoreJournal) stage() string    { return "restore-stage-" + j.ID }
func (j *restoreJournal) retained() string { return "restore-retained-" + j.ID }

type restoreReceipt struct {
	Journal  restoreJournal
	Checksum string
}

func journalBytes(j *restoreJournal) []byte {
	payload, _ := json.Marshal(j)
	hash := sha256.Sum256(payload)
	data, _ := json.Marshal(restoreReceipt{*j, hex.EncodeToString(hash[:])})
	return data
}

func runtimeIdentityValid(s string) bool {
	parts := strings.Split(s, ":")
	if len(parts) != 2 {
		return false
	}
	for _, p := range parts {
		n, err := strconv.ParseUint(p, 10, 64)
		if err != nil || strconv.FormatUint(n, 10) != p {
			return false
		}
	}
	return true
}

func (r *Runtime) validJournal(j *restoreJournal) bool {
	if j.Version != 1 || j.Root != r.rootName || j.Parent != fileIdentity(r.parentIdentity) || !validID(j.ID) || !runtimeIdentityValid(j.Candidate) || j.Old != "" && !runtimeIdentityValid(j.Old) || j.Candidate == j.Old {
		return false
	}
	for _, digest := range []string{j.Digest, j.Schema} {
		decoded, err := hex.DecodeString(digest)
		if err != nil || len(decoded) != sha256.Size || digest != strings.ToLower(digest) {
			return false
		}
	}
	switch j.Phase {
	case "prepared", "retiring", "installing", "committed", "rolling_back":
		return true
	case "interrupted":
		return j.Old == ""
	}
	return false
}

func (r *Runtime) readJournal() error {
	if err := r.checkParent(); err != nil {
		return err
	}
	info, err := r.parent.Lstat(restoreJournalName)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || !private(info, false) || info.Size() > 8192 {
		return ErrCorrupt
	}
	f, err := r.parent.OpenFile(restoreJournalName, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return ErrCorrupt
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return ErrCorrupt
	}
	data, err := io.ReadAll(io.LimitReader(f, 8193))
	if err != nil || len(data) > 8192 {
		return ErrCorrupt
	}
	var receipt restoreReceipt
	if json.Unmarshal(data, &receipt) != nil || !bytes.Equal(data, journalBytes(&receipt.Journal)) || !r.validJournal(&receipt.Journal) {
		return ErrCorrupt
	}
	r.journal = &receipt.Journal
	r.journalIdentity = info
	r.journalData = data
	return r.checkJournalIdentity()
}

func (r *Runtime) checkJournalIdentity() error {
	if err := r.checkParent(); err != nil {
		return err
	}
	info, err := r.parent.Lstat(restoreJournalName)
	if r.journalIdentity == nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return ErrCorrupt
	}
	if err != nil || !private(info, false) || !os.SameFile(info, r.journalIdentity) {
		return ErrCorrupt
	}
	f, err := r.parent.OpenFile(restoreJournalName, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return ErrCorrupt
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(opened, r.journalIdentity) {
		return ErrCorrupt
	}
	data, err := io.ReadAll(io.LimitReader(f, 8193))
	if err != nil || !bytes.Equal(data, r.journalData) {
		return ErrCorrupt
	}
	return nil
}

func (r *Runtime) writeJournal(j *restoreJournal) error {
	if !r.validJournal(j) {
		return ErrCorrupt
	}
	if err := r.checkJournalIdentity(); err != nil {
		return err
	}
	name := ".restore-write-" + opaqueID()
	f, err := r.parent.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return ErrStorage
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return ErrStorage
	}
	defer func() {
		f.Close()
		if current, e := r.parent.Lstat(name); e == nil && os.SameFile(current, info) {
			_ = r.parent.Remove(name)
		}
	}()
	data := journalBytes(j)
	if n, e := f.Write(data); e != nil || n != len(data) {
		return ErrStorage
	}
	if f.Sync() != nil || f.Close() != nil {
		return ErrStorage
	}
	// Before the first receipt is published preparation has made no transaction
	// intent durable. Later temporary writes are recoverable from the old receipt.
	if r.journalIdentity != nil {
		r.reached("journal_" + j.Phase + "_staged")
	}
	if err = r.checkJournalIdentity(); err != nil {
		return err
	}
	if r.journalIdentity == nil {
		err = renameRuntimeExclusive(int(r.parentFile.Fd()), name, restoreJournalName)
	} else {
		err = r.parent.Rename(name, restoreJournalName)
	}
	if err != nil {
		return ErrStorage
	}
	r.journal = j
	r.journalIdentity = info
	r.journalData = data
	r.reached("journal_" + j.Phase + "_published")
	if err = syncDirectory(r.parent); err != nil {
		return err
	}
	r.reached("journal_" + j.Phase)
	return nil
}

func (r *Runtime) retireJournal() error {
	if err := r.checkJournalIdentity(); err != nil {
		return err
	}
	if r.journalIdentity == nil {
		return ErrCorrupt
	}
	if err := r.parent.Remove(restoreJournalName); err != nil {
		return ErrStorage
	}
	r.journal = nil
	r.journalIdentity = nil
	r.journalData = nil
	r.reached("removed_journal")
	if err := syncDirectory(r.parent); err != nil {
		return err
	}
	r.reached("retired_journal")
	return nil
}

func (r *Runtime) move(from, to, identity, checkpoint string) error {
	if got, err := r.directoryIdentity(from); err != nil || got != identity {
		return ErrCorrupt
	}
	if got, err := r.directoryIdentity(to); err != nil || got != "" {
		return ErrCorrupt
	}
	if err := renameRuntimeExclusive(int(r.parentFile.Fd()), from, to); err != nil {
		return ErrCorrupt
	}
	r.reached("renamed_" + checkpoint)
	if got, err := r.directoryIdentity(to); err != nil || got != identity {
		return ErrCorrupt
	}
	if err := syncDirectory(r.parent); err != nil {
		return err
	}
	r.reached("synced_" + checkpoint)
	return nil
}

// Each known directory must occur exactly once. Missing roots and unknown
// replacements never become authority to initialize, overwrite, or delete.
func (r *Runtime) checkLayout(j *restoreJournal) error {
	root, err := r.directoryIdentity(r.rootName)
	if err != nil {
		return err
	}
	stage, err := r.directoryIdentity(j.stage())
	if err != nil {
		return err
	}
	old, err := r.directoryIdentity(j.retained())
	if err != nil {
		return err
	}
	if root != "" && root != j.Candidate && root != j.Old || stage != "" && stage != j.Candidate || old != "" && (j.Old == "" || old != j.Old) {
		return ErrCorrupt
	}
	if (root == j.Candidate) == (stage == j.Candidate) {
		return ErrCorrupt
	}
	if j.Old != "" && ((root == j.Old) == (old == j.Old)) {
		return ErrCorrupt
	}
	switch j.Phase {
	case "prepared":
		if stage != j.Candidate || root != j.Old || old != "" {
			return ErrCorrupt
		}
	case "retiring":
		if stage != j.Candidate {
			return ErrCorrupt
		}
	case "installing":
		if j.Old != "" && old != j.Old {
			return ErrCorrupt
		}
	case "committed":
		if root != j.Candidate || stage != "" || old != j.Old {
			return ErrCorrupt
		}
	case "interrupted":
		if root != "" || stage != j.Candidate || old != "" {
			return ErrCorrupt
		}
	}
	return nil
}

func (r *Runtime) reconcile() error {
	j := r.journal
	if err := r.checkLayout(j); err != nil {
		return err
	}
	root, _ := r.directoryIdentity(r.rootName)
	candidateName := j.stage()
	if root == j.Candidate {
		candidateName = r.rootName
	}
	if info, err := r.parent.Lstat(candidateName + "/.owner.lock"); err != nil || !private(info, false) {
		return ErrCorrupt
	}
	candidateLock, err := r.lockDirectory(candidateName, j.Candidate)
	if err != nil {
		return err
	}
	defer candidateLock.Close()
	if j.Old != "" {
		name := j.retained()
		if root == j.Old {
			name = r.rootName
		}
		lock, err := r.lockDirectory(name, j.Old)
		if err != nil {
			return err
		}
		defer lock.Close()
	}
	if j.Phase == "interrupted" {
		r.openErr = ErrRestoreInterrupted
		return nil
	}
	if j.Phase == "committed" {
		if err = r.verifyCandidate(r.rootName, j); err == nil {
			return r.retireJournal()
		}
		r.openErr = ErrRestoreFailed
	} else {
		r.openErr = ErrRestoreInterrupted
	}
	if j.Phase != "rolling_back" {
		copy := *j
		copy.Phase = "rolling_back"
		j = &copy
		if err = r.writeJournal(j); err != nil {
			return err
		}
	}
	if root == j.Candidate {
		if err = r.move(r.rootName, j.stage(), j.Candidate, "rollback_candidate"); err != nil {
			return err
		}
	}
	if j.Old != "" {
		root, err = r.directoryIdentity(r.rootName)
		if err != nil {
			return err
		}
		if root != j.Old {
			if err = r.move(j.retained(), r.rootName, j.Old, "rollback_old"); err != nil {
				return err
			}
		}
		return r.retireJournal()
	}
	// This receipt intentionally survives restarts. Only a newly confirmed
	// activation may replace it; cancelling a new preparation keeps it intact.
	j.Phase = "interrupted"
	if err = r.writeJournal(j); err != nil {
		return err
	}
	r.openErr = ErrRestoreInterrupted
	return nil
}

func runtimeSchemaDigest(db *sql.DB) (string, error) {
	rows, err := db.Query("SELECT type,name,tbl_name,COALESCE(sql,'') FROM sqlite_schema ORDER BY type,name")
	if err != nil {
		return "", ErrCorrupt
	}
	defer rows.Close()
	hash := sha256.New()
	count := 0
	for rows.Next() {
		var row [4]string
		if rows.Scan(&row[0], &row[1], &row[2], &row[3]) != nil {
			return "", ErrCorrupt
		}
		count++
		if count > 32 {
			return "", ErrCorrupt
		}
		for _, part := range row {
			if len(part) > 16<<10 {
				return "", ErrCorrupt
			}
		}
		data, _ := json.Marshal(row)
		hash.Write(data)
	}
	if rows.Err() != nil {
		return "", ErrCorrupt
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// A candidate is read-only until the journal is retired. Open cannot be used
// here: its initializer/migrations/recovery could silently repair a bad stage.
func (r *Runtime) verifyCandidate(name string, j *restoreJournal) error {
	if got, err := r.directoryIdentity(name); err != nil || got != j.Candidate {
		return ErrCorrupt
	}
	root, err := r.parent.OpenRoot(name)
	if err != nil {
		return ErrCorrupt
	}
	s := &Store{root: root, path: filepath.Join(r.parentPath, name)}
	defer s.Close()
	s.identity, err = root.Lstat(".")
	if err != nil || fileIdentity(s.identity) != j.Candidate {
		return ErrCorrupt
	}
	f, err := root.OpenFile(".", os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return ErrCorrupt
	}
	entries, err := f.ReadDir(4)
	f.Close()
	if err != nil && !errors.Is(err, io.EOF) || len(entries) != 3 {
		return ErrCorrupt
	}
	for _, entry := range entries {
		if entry.Name() != "library.sqlite" && entry.Name() != "originals" && entry.Name() != ".owner.lock" {
			return ErrCorrupt
		}
	}
	s.databaseIdentity, err = root.Lstat("library.sqlite")
	if err != nil || !private(s.databaseIdentity, false) {
		return ErrCorrupt
	}
	s.lockIdentity, err = root.Lstat(".owner.lock")
	if err != nil || !private(s.lockIdentity, false) {
		return ErrCorrupt
	}
	s.originalIdentity, err = root.Lstat("originals")
	if err != nil || !private(s.originalIdentity, true) {
		return ErrCorrupt
	}
	s.originals, err = root.OpenRoot("originals")
	if err != nil {
		return ErrCorrupt
	}
	if err = s.checkRoot(); err != nil {
		return err
	}
	dbURL := (&url.URL{Scheme: "file", Path: filepath.Join(s.path, "library.sqlite"), RawQuery: "mode=ro"}).String()
	s.db, err = sql.Open("sqlite", dbURL)
	if err != nil {
		return ErrCorrupt
	}
	s.db.SetMaxOpenConns(1)
	if _, err = s.db.Exec("PRAGMA trusted_schema=OFF; PRAGMA query_only=ON;"); err != nil {
		return ErrCorrupt
	}
	var version, application int
	if s.db.QueryRow("PRAGMA user_version").Scan(&version) != nil || (version != 3 && version != 4) || s.db.QueryRow("PRAGMA application_id").Scan(&application) != nil || application != 1263290191 {
		return ErrCorrupt
	}
	if digest, err := runtimeSchemaDigest(s.db); err != nil || digest != j.Schema {
		return ErrCorrupt
	}
	var check string
	if s.db.QueryRow("PRAGMA quick_check").Scan(&check) != nil || check != "ok" {
		return ErrCorrupt
	}
	var sources, pending, settings, processing int
	if s.db.QueryRow("SELECT (SELECT count(*) FROM sources),(SELECT count(*) FROM pending_deletions),(SELECT count(*) FROM settings),(SELECT count(*) FROM reports WHERE status='processing')").Scan(&sources, &pending, &settings, &processing) != nil || sources > maxSnapshotSources || pending != 0 || settings != 1 || processing != 0 {
		return ErrCorrupt
	}
	inbox := 0
	if version >= 4 {
		var processingInbox int
		if s.db.QueryRow("SELECT count(*),COALESCE(sum(status='processing'),0) FROM inbox").Scan(&inbox, &processingInbox) != nil || inbox > MaxInboxItems || processingInbox != 0 {
			return ErrCorrupt
		}
	}
	foreignKeys, err := s.db.Query("PRAGMA foreign_key_check")
	if err != nil {
		return ErrCorrupt
	}
	invalid := foreignKeys.Next() || foreignKeys.Err() != nil
	foreignKeys.Close()
	if invalid {
		return ErrCorrupt
	}
	hash := sha256.New()
	summary, err := s.WriteSnapshot(context.Background(), hash)
	if err != nil || summary.Sources != sources || summary.Inbox != inbox || hex.EncodeToString(hash.Sum(nil)) != j.Digest {
		return ErrCorrupt
	}
	f, err = s.originals.OpenFile(".", os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return ErrCorrupt
	}
	defer f.Close()
	count := 0
	for {
		entries, err := f.ReadDir(128)
		count += len(entries)
		if count > sources+inbox {
			return ErrCorrupt
		}
		for _, entry := range entries {
			if !strings.HasSuffix(entry.Name(), ".blob") || !validID(strings.TrimSuffix(entry.Name(), ".blob")) {
				return ErrCorrupt
			}
		}
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return ErrCorrupt
		}
	}
	if count != sources+inbox {
		return ErrCorrupt
	}
	if got, err := r.directoryIdentity(name); err != nil || got != j.Candidate {
		return ErrCorrupt
	}
	return nil
}
