package app

import (
	"bytes"
	"context"
	"errors"
	"io"
	"testing"
	"time"

	"kinlogue/internal/document"
	"kinlogue/internal/library"
)

func exportFixture(t *testing.T) (*Service, *library.Store, library.Report) {
	t.Helper()
	a, store := newTestService(t, processor{func(context.Context, []byte) (document.Extraction, error) { return synthetic(), nil }})
	ctx := context.Background()
	r, err := a.Import(ctx, "/synthetic/input.pdf")
	if err != nil {
		t.Fatal(err)
	}
	m, err := a.AddMember(ctx, "Synthetic export member")
	if err != nil {
		t.Fatal(err)
	}
	e := r.Review
	e.MemberID, e.Title = m.ID, "Synthetic export report"
	r, err = a.Confirm(ctx, r.ID, e)
	if err != nil {
		t.Fatal(err)
	}
	return a, store, r
}

func awaitExport(t *testing.T, result <-chan error) error {
	t.Helper()
	select {
	case err := <-result:
		return err
	case <-time.After(3 * time.Second):
		t.Fatal("synthetic export did not settle")
		return nil
	}
}

func TestExportHoldsMutationAdmissionUntilPublication(t *testing.T) {
	a, _, r := exportFixture(t)
	entered, release := make(chan struct{}), make(chan struct{})
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	a.writeExport = func(ctx context.Context, _ string, write func(io.Writer) error) error {
		close(entered)
		<-release
		return write(io.Discard)
	}
	done := make(chan error, 1)
	go func() { done <- a.ExportOriginals(context.Background(), r.ID, "/synthetic/output.zip") }()
	<-entered
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := a.DeleteReport(ctx, r.ID); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal("queued deletion did not cancel")
	}
	if _, err := a.Get(context.Background(), r.ID); err != nil {
		t.Fatal("cancelled deletion changed the export snapshot")
	}
	close(release)
	if err := awaitExport(t, done); err != nil {
		t.Fatal(err)
	}
	if result, err := a.DeleteReport(context.Background(), r.ID); err != nil || result.CleanupPending {
		t.Fatal("mutation admission did not reopen after export")
	}
}

func TestCloseCancelsExportAndWaitsBeforeClosingStore(t *testing.T) {
	a, store, r := exportFixture(t)
	entered, cancelled, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	a.writeExport = func(ctx context.Context, _ string, _ func(io.Writer) error) error {
		close(entered)
		<-ctx.Done()
		close(cancelled)
		<-release
		return ctx.Err()
	}
	done, closed := make(chan error, 1), make(chan error, 1)
	go func() { done <- a.ExportOriginals(context.Background(), r.ID, "/synthetic/output.zip") }()
	<-entered
	go func() { closed <- a.Close() }()
	<-cancelled
	select {
	case <-closed:
		t.Fatal("Close returned while platform publication remained entered")
	default:
	}
	if _, err := store.Get(context.Background(), r.ID); err != nil {
		t.Fatal("Store closed before platform callback settled")
	}
	close(release)
	if err := awaitExport(t, done); !errors.Is(err, context.Canceled) {
		t.Fatal("unpublished export did not report cancellation")
	}
	if err := awaitExport(t, closed); err != nil {
		t.Fatal(err)
	}
}

func TestExportDoesNotMisreportCancellationAfterPublication(t *testing.T) {
	a, _, r := exportFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var archive bytes.Buffer
	a.writeExport = func(_ context.Context, _ string, write func(io.Writer) error) error {
		if err := write(&archive); err != nil {
			return err
		}
		cancel() // The platform has already committed the complete ZIP.
		return nil
	}
	if err := a.ExportOriginals(ctx, r.ID, "/synthetic/output.zip"); err != nil || archive.Len() == 0 {
		t.Fatal("successful publication was misreported as cancellation")
	}
}
