// Package app composes the local library and recognition backend. Every command
// participates in shutdown; mutations share one cancellable admission queue.
package app

import (
	"context"
	"errors"
	"image"
	"io"
	"path/filepath"
	"sync"
	"time"

	"kinlogue/internal/document"
	"kinlogue/internal/library"
)

var (
	ErrClosed = errors.New("application_closed")
	ErrImport = errors.New("import_failed")
)

// Processor produces an untrusted transcription candidate, never a confirmed
// medical conclusion. Native OCR is the only production implementation today.
type Processor interface {
	Extract(context.Context, []byte) (document.Extraction, error)
	RenderPage(context.Context, []byte, int) (image.Image, error)
}

type Service struct {
	store       *library.Store
	processor   Processor
	readFile    func(string) ([]byte, error)
	writeExport func(context.Context, string, func(io.Writer) error) error
	shutdown    context.Context
	cancel      context.CancelFunc
	mutations   chan struct{}
	mu          sync.Mutex
	closing     bool
	ops         sync.WaitGroup
	closeOnce   sync.Once
	closeError  error
}

func New(s *library.Store, p Processor, readFile func(string) ([]byte, error), writeExport func(context.Context, string, func(io.Writer) error) error) *Service {
	c, cancel := context.WithCancel(context.Background())
	return &Service{store: s, processor: p, readFile: readFile, writeExport: writeExport, shutdown: c, cancel: cancel, mutations: make(chan struct{}, 1)}
}

func command[T any](s *Service, ctx context.Context, mutation bool, fn func(context.Context) (T, error)) (T, error) {
	var zero T
	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		return zero, ErrClosed
	}
	s.ops.Add(1)
	s.mu.Unlock()
	defer s.ops.Done()
	c, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(s.shutdown, cancel)
	defer stop()
	defer cancel()
	if mutation {
		select {
		case s.mutations <- struct{}{}:
			defer func() { <-s.mutations }()
		case <-c.Done():
			return zero, c.Err()
		}
	}
	if err := c.Err(); err != nil {
		return zero, err
	}
	return fn(c)
}

// Close stops admission, cancels entered commands and waits for the native
// recognizer to return before closing SQLite. A native call may not interrupt.
func (s *Service) Close() error {
	s.closeOnce.Do(func() {
		s.seal()
		s.ops.Wait()
		s.closeError = s.store.Close()
	})
	return s.closeError
}

func (s *Service) seal() {
	s.mu.Lock()
	s.closing = true
	s.cancel()
	s.mu.Unlock()
}

// Import treats one selected file as a separate report. ImportMany is the
// explicit grouped-report path; neither guesses relationships from names.
func (s *Service) Import(ctx context.Context, path string) (library.Report, error) {
	return s.ImportMany(ctx, []string{path})
}

func (s *Service) ImportMany(ctx context.Context, paths []string) (library.Report, error) {
	paths = append([]string(nil), paths...)
	return command(s, ctx, true, func(c context.Context) (library.Report, error) {
		if len(paths) > document.MaxSources {
			return library.Report{}, document.ErrLimit
		}
		if len(paths) == 0 {
			return library.Report{}, document.ErrInvalid
		}
		names := make([]string, len(paths))
		for i, path := range paths {
			names[i] = filepath.Base(path)
		}
		r, err := s.store.CreateDraftSources(c, names, func(i int) ([]byte, error) {
			if err := c.Err(); err != nil {
				return nil, err
			}
			data, err := s.readFile(paths[i])
			if err != nil {
				return nil, safeImportError(err)
			}
			if len(data) > document.MaxFileBytes {
				return nil, document.ErrLimit
			}
			if len(data) == 0 {
				return nil, document.ErrInvalid
			}
			return data, c.Err()
		})
		if err != nil {
			return r, err
		}
		return s.recognize(c, r)
	})
}

func (s *Service) Retry(ctx context.Context, id string) (library.Report, error) {
	return command(s, ctx, true, func(c context.Context) (library.Report, error) {
		r, err := s.store.Get(c, id)
		if err != nil {
			return library.Report{}, err
		}
		if r.Status != "failed" {
			return library.Report{}, library.ErrState
		}
		return s.recognize(c, r)
	})
}

func (s *Service) recognize(c context.Context, r library.Report) (library.Report, error) {
	var err error
	for _, source := range r.Sources {
		if source.Extraction.Engine != "" {
			continue
		}
		var data []byte
		data, err = s.store.ReadOriginal(c, r.ID, source.ID)
		if err != nil {
			break
		}
		var extraction document.Extraction
		extraction, err = s.processor.Extract(c, data)
		if c.Err() != nil {
			err = c.Err()
		}
		if err == nil {
			err = extraction.Validate()
		}
		if err != nil {
			err = safeImportError(err)
			break
		}
		var saved library.Report
		saved, err = s.store.SaveSourceExtraction(c, r.ID, source.ID, extraction)
		if err != nil {
			break
		}
		r = saved
	}
	if err == nil && r.Status == "review" {
		return r, nil
	}
	if err == nil {
		err = library.ErrState
	}
	// Cleanup stays registered with shutdown and holds mutation admission until
	// a cancelled/failed report is recoverable. Successful sources are immutable.
	cleanup, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = s.store.FailDraft(cleanup, r.ID, failureCode(err))
	if failed, getErr := s.store.Get(cleanup, r.ID); getErr == nil {
		r = failed
	}
	return r, err
}

func safeImportError(err error) error {
	for _, known := range []error{context.Canceled, context.DeadlineExceeded, document.ErrInvalid, document.ErrUnsupported, document.ErrLimit, document.ErrLocked, document.ErrUnavailable} {
		if errors.Is(err, known) {
			return known
		}
	}
	return ErrImport
}
func failureCode(err error) string {
	switch {
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return "cancelled"
	case errors.Is(err, document.ErrLimit):
		return "limit"
	case errors.Is(err, document.ErrLocked):
		return "locked"
	case errors.Is(err, document.ErrUnsupported):
		return "unsupported"
	case errors.Is(err, document.ErrInvalid):
		return "invalid"
	case errors.Is(err, document.ErrUnavailable):
		return "unavailable"
	default:
		return "recognition_failed"
	}
}

func (s *Service) Preview(ctx context.Context, id, sourceID string, page int) (image.Image, error) {
	return command(s, ctx, false, func(c context.Context) (image.Image, error) {
		r, err := s.store.Get(c, id)
		if err != nil {
			return nil, err
		}
		var source *library.Source
		for i := range r.Sources {
			if r.Sources[i].ID == sourceID {
				source = &r.Sources[i]
				break
			}
		}
		if source == nil {
			return nil, library.ErrNotFound
		}
		maxPage := source.Extraction.PageCount
		if maxPage == 0 && r.Status == "failed" {
			maxPage = 1
		}
		if page < 1 || page > maxPage {
			return nil, document.ErrInvalid
		}
		data, err := s.store.ReadOriginal(c, id, sourceID)
		if err != nil {
			return nil, err
		}
		img, err := s.processor.RenderPage(c, data, page)
		if c.Err() != nil {
			return nil, c.Err()
		}
		if err != nil {
			return nil, safeImportError(err)
		}
		return img, nil
	})
}

func (s *Service) Members(c context.Context) ([]library.Member, error) {
	return command(s, c, false, s.store.Members)
}
func (s *Service) AddMember(c context.Context, name string) (library.Member, error) {
	return command(s, c, true, func(c context.Context) (library.Member, error) { return s.store.AddMember(c, name) })
}
func (s *Service) Drafts(c context.Context) ([]library.Report, error) {
	return command(s, c, false, s.store.Drafts)
}
func (s *Service) Search(c context.Context, memberID, query string) ([]library.Report, error) {
	return command(s, c, false, func(c context.Context) ([]library.Report, error) { return s.store.Search(c, memberID, query) })
}
func (s *Service) Get(c context.Context, id string) (library.Report, error) {
	return command(s, c, false, func(c context.Context) (library.Report, error) { return s.store.Get(c, id) })
}
func (s *Service) SaveReview(c context.Context, id string, e library.Edit) (library.Report, error) {
	return command(s, c, true, func(c context.Context) (library.Report, error) { return s.store.SaveReview(c, id, e) })
}
func (s *Service) Confirm(c context.Context, id string, e library.Edit) (library.Report, error) {
	return command(s, c, true, func(c context.Context) (library.Report, error) { return s.store.Confirm(c, id, e) })
}
func (s *Service) UpdateConfirmed(c context.Context, id string, e library.Edit) (library.Report, error) {
	return command(s, c, true, func(c context.Context) (library.Report, error) { return s.store.UpdateConfirmed(c, id, e) })
}
func (s *Service) DeleteReport(c context.Context, id string) (library.DeleteResult, error) {
	return command(s, c, true, func(c context.Context) (library.DeleteResult, error) { return s.store.DeleteReport(c, id) })
}
func (s *Service) Language(c context.Context) (string, error) {
	return command(s, c, false, s.store.Language)
}
func (s *Service) SetLanguage(c context.Context, language string) error {
	_, err := command(s, c, true, func(c context.Context) (struct{}, error) { return struct{}{}, s.store.SetLanguage(c, language) })
	return err
}
