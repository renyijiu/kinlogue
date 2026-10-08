package library

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"strconv"
	"syscall"

	"kinlogue/internal/document"
)

type DeleteResult struct{ CleanupPending bool }

type deletion struct {
	id, digest, identity string
	size                 int64
}

// DeleteReport durably removes the report and queues precisely its original
// copies before unlinking any file. Cleanup failures never restore the record
// or pretend the database deletion failed.
func (s *Store) DeleteReport(ctx context.Context, id string) (DeleteResult, error) {
	return s.deleteReport(ctx, id, nil)
}

func (s *Store) deleteReport(ctx context.Context, id string, checkpoint func()) (DeleteResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.begin(ctx); err != nil {
		return DeleteResult{}, err
	}
	if !validID(id) {
		return DeleteResult{}, ErrNotFound
	}
	var exists int
	if err := s.db.QueryRowContext(ctx, "SELECT 1 FROM reports WHERE id=?", id).Scan(&exists); err != nil {
		return DeleteResult{}, storageError(ctx, err)
	}
	rows, err := s.db.QueryContext(ctx, "SELECT id,digest,byte_count FROM sources WHERE report_id=?", id)
	if err != nil {
		return DeleteResult{}, storageError(ctx, err)
	}
	items := []deletion{}
	for rows.Next() {
		var d deletion
		if err = rows.Scan(&d.id, &d.digest, &d.size); err != nil {
			break
		}
		if !validID(d.id) {
			err = ErrCorrupt
			break
		}
		items = append(items, d)
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return DeleteResult{}, storageError(ctx, err)
	}
	for i := range items {
		if err := ctx.Err(); err != nil {
			return DeleteResult{}, err
		}
		// A missing or damaged original does not prevent deleting its record.
		// An unverified file gets no unlink authorization in the queue.
		if info, err := s.verifyDeletionOriginal(ctx, items[i]); err == nil {
			items[i].identity = fileIdentity(info)
		}
	}
	if err := s.begin(ctx); err != nil {
		return DeleteResult{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return DeleteResult{}, storageError(ctx, err)
	}
	defer tx.Rollback()
	for _, d := range items {
		_, err = tx.ExecContext(ctx, "INSERT INTO pending_deletions(id,digest,byte_count,file_identity) VALUES (?,?,?,?)", d.id, d.digest, d.size, d.identity)
		if err != nil {
			return DeleteResult{}, storageError(ctx, err)
		}
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM reports WHERE id=?", id); err != nil {
		return DeleteResult{}, storageError(ctx, err)
	}
	if err = tx.Commit(); err != nil {
		// A commit error can be ambiguous. Only a readable authoritative absence
		// under the same owner allows cleanup; otherwise no original is touched.
		if s.checkRoot() != nil {
			return DeleteResult{}, ErrStorage
		}
		var remaining int
		if queryErr := s.db.QueryRow("SELECT count(*) FROM reports WHERE id=?", id).Scan(&remaining); queryErr != nil || remaining != 0 {
			return DeleteResult{}, storageError(ctx, err)
		}
	}
	if checkpoint != nil {
		checkpoint()
	}
	return DeleteResult{CleanupPending: s.cleanupOriginals(ctx, items)}, nil
}

func fileIdentity(info os.FileInfo) string {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return ""
	}
	return strconv.FormatUint(uint64(stat.Dev), 10) + ":" + strconv.FormatUint(stat.Ino, 10)
}

// verifyDeletionOriginal streams the digest through a bounded descriptor.
// Identity is checked both before and after reading, without trusting names.
func (s *Store) verifyDeletionOriginal(ctx context.Context, d deletion) (os.FileInfo, error) {
	if !validID(d.id) || d.size < 1 || d.size > document.MaxFileBytes {
		return nil, ErrCorrupt
	}
	decoded, err := hex.DecodeString(d.digest)
	if err != nil || len(decoded) != sha256.Size {
		return nil, ErrCorrupt
	}
	leaf := d.id + ".blob"
	info, err := s.originals.Lstat(leaf)
	if err != nil || !private(info, false) || info.Size() != d.size {
		return nil, ErrCorrupt
	}
	f, err := s.originals.OpenFile(leaf, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, ErrCorrupt
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !private(opened, false) || !os.SameFile(opened, info) {
		return nil, ErrCorrupt
	}
	hash := sha256.New()
	n, err := io.Copy(hash, io.LimitReader(f, d.size+1))
	if err != nil || n != d.size || hex.EncodeToString(hash.Sum(nil)) != d.digest {
		return nil, ErrCorrupt
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	current, err := s.originals.Lstat(leaf)
	if err != nil || !private(current, false) || !os.SameFile(current, info) {
		return nil, ErrCorrupt
	}
	return current, nil
}

// cleanupPending returns whether any queued cleanup remains. Unknown orphan
// files and unsafe replacements are never enumerated or unlinked.
func (s *Store) cleanupPending(ctx context.Context) bool {
	if s.begin(ctx) != nil {
		return true
	}
	rows, err := s.db.QueryContext(ctx, "SELECT id,digest,byte_count,file_identity FROM pending_deletions")
	if err != nil {
		return true
	}
	items := []deletion{}
	for rows.Next() {
		var d deletion
		if err = rows.Scan(&d.id, &d.digest, &d.size, &d.identity); err != nil {
			break
		}
		items = append(items, d)
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return true
	}
	return s.cleanupOriginals(ctx, items)
}

func (s *Store) cleanupOriginals(ctx context.Context, items []deletion) bool {
	pending := false
	for _, d := range items {
		if s.begin(ctx) != nil || !validID(d.id) {
			pending = true
			continue
		}
		var references int
		if err := s.db.QueryRowContext(ctx, "SELECT count(*) FROM sources WHERE id=?", d.id).Scan(&references); err != nil || references != 0 {
			pending = true
			continue
		}
		leaf := d.id + ".blob"
		_, statErr := s.originals.Lstat(leaf)
		if !errors.Is(statErr, os.ErrNotExist) {
			info, err := s.verifyDeletionOriginal(ctx, d)
			if err != nil || d.identity == "" || fileIdentity(info) != d.identity || s.checkRoot() != nil {
				pending = true
				continue
			}
			if err := s.originals.Remove(leaf); err != nil {
				pending = true
				continue
			}
		}
		// Make the unlink durable before forgetting its recovery entry. A crash
		// after unlink but before queue removal simply retries an absent file.
		if syncDirectory(s.originals) != nil {
			pending = true
			continue
		}
		if _, err := s.db.ExecContext(ctx, "DELETE FROM pending_deletions WHERE id=?", d.id); err != nil {
			pending = true
		}
	}
	return pending
}
