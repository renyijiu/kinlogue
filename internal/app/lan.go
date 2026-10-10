package app

import (
	"context"
	"image"
	"io"
	"net"
	"net/netip"
	"sync"
	"time"

	"kinlogue/internal/document"
	"kinlogue/internal/lan"
	"kinlogue/internal/library"
	"kinlogue/internal/macos"
)

// LANConfig is injected at composition. Configuring it never opens a listener.
type LANConfig struct {
	Interfaces func() ([]macos.LANInterface, error)
	Listen     func(context.Context, macos.LANInterface) (net.Listener, error)
	Watch      func(context.Context, macos.LANInterface, func()) (func(), error)
}
type LANStatus struct {
	Active        bool
	Address, Code string
}
type lanController struct {
	service        *Service
	config         LANConfig
	transition     sync.Mutex
	mu             sync.Mutex
	session        *lanSession
	startingCancel context.CancelFunc
	revocation     uint64
}
type lanSession struct {
	receiver *lan.Receiver
	listener net.Listener
	cancel   context.CancelFunc
	unwatch  func()
	jobs     chan library.InboxSelection
	done     chan struct{}
	status   LANStatus
}

func (s *Service) ConfigureLAN(config LANConfig) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closing {
		return ErrClosed
	}
	if s.lan != nil || config.Interfaces == nil || config.Listen == nil || config.Watch == nil {
		return library.ErrState
	}
	s.lan = &lanController{service: s, config: config}
	return nil
}
func (s *Service) lanController() *lanController { s.mu.Lock(); defer s.mu.Unlock(); return s.lan }
func (s *Service) LANInterfaces(ctx context.Context) ([]macos.LANInterface, error) {
	return command(s, ctx, false, func(context.Context) ([]macos.LANInterface, error) {
		c := s.lanController()
		if c == nil {
			return nil, document.ErrUnavailable
		}
		return c.config.Interfaces()
	})
}
func (s *Service) StartLAN(ctx context.Context, iface macos.LANInterface) (LANStatus, error) {
	c := s.lanController()
	if c == nil {
		return LANStatus{}, document.ErrUnavailable
	}
	// Capture before command admission and transition waits: a delivered event
	// invalidates every older start request, including requests not yet starting.
	c.mu.Lock()
	generation := c.revocation
	c.mu.Unlock()
	return command(s, ctx, false, func(ctx context.Context) (LANStatus, error) {
		return c.start(ctx, iface, generation)
	})
}

// RevokeLAN cancels the current or starting session before returning, without
// waiting for storage/OCR cleanup. Lifecycle callbacks must use this operation.
func (s *Service) RevokeLAN() {
	c := s.lanController()
	if c == nil {
		return
	}
	c.mu.Lock()
	c.revocation++
	session, starting := c.session, c.startingCancel
	if starting != nil {
		starting()
	}
	if session != nil {
		session.cancel()
	}
	c.mu.Unlock()
	if session != nil {
		go c.stop(session)
	}
}

func (s *Service) StopLAN() {
	if c := s.lanController(); c != nil {
		c.stop(nil)
	}
}
func (s *Service) LANStatus() LANStatus {
	c := s.lanController()
	if c == nil {
		return LANStatus{}
	}
	c.mu.Lock()
	session := c.session
	c.mu.Unlock()
	// Receiver queries can wait for durable publication. Never hold the
	// controller lock here: stop needs it before cancelling that publication.
	if session == nil || !session.receiver.Active() {
		return LANStatus{}
	}
	status := session.status
	status.Code = session.receiver.PairingCode()
	return status
}
func (c *lanController) valid(iface macos.LANInterface) bool {
	rows, e := c.config.Interfaces()
	if e != nil {
		return false
	}
	for _, row := range rows {
		if row == iface {
			return true
		}
	}
	return false
}
func (c *lanController) start(ctx context.Context, iface macos.LANInterface, generation uint64) (LANStatus, error) {
	c.transition.Lock()
	defer c.transition.Unlock()
	if err := ctx.Err(); err != nil {
		return LANStatus{}, err
	}
	life, cancel := context.WithCancel(c.service.shutdown)
	c.mu.Lock()
	if c.session != nil || c.revocation != generation {
		c.mu.Unlock()
		cancel()
		return LANStatus{}, library.ErrState
	}
	c.startingCancel = cancel
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		c.startingCancel = nil
		c.mu.Unlock()
	}()
	if !c.valid(iface) {
		cancel()
		return LANStatus{}, document.ErrUnavailable
	}
	session := &lanSession{cancel: cancel, jobs: make(chan library.InboxSelection, library.MaxInboxItems), done: make(chan struct{})}
	unwatch, err := c.config.Watch(life, iface, func() { cancel(); go c.stop(session) })
	if err != nil {
		cancel()
		return LANStatus{}, document.ErrUnavailable
	}
	session.unwatch = unwatch
	listener, err := c.config.Listen(life, iface)
	if err != nil {
		cancel()
		unwatch()
		return LANStatus{}, document.ErrUnavailable
	}
	session.listener = listener
	if life.Err() != nil || !c.valid(iface) {
		cancel()
		listener.Close()
		unwatch()
		return LANStatus{}, document.ErrUnavailable
	}
	receiver, err := lan.New(lan.Config{Context: life, Authority: listener.Addr().String(), Prefix: netip.PrefixFrom(iface.Address, iface.PrefixBits).Masked(), ValidateNetwork: func() bool { return life.Err() == nil && c.valid(iface) }, Stage: func(ctx context.Context, name string, size int64, reader io.Reader) (lan.Staged, error) {
		// Network reads run outside Service's mutation gate. Receiver.Stop drains
		// the stage and final commit before Service can close its Store.
		upload, e := c.service.store.StageInbox(ctx, name, size, reader)
		if e != nil {
			return nil, e
		}
		return &lanUpload{upload: upload, session: session}, nil
	}})
	if err != nil {
		cancel()
		listener.Close()
		unwatch()
		return LANStatus{}, document.ErrUnavailable
	}
	session.receiver = receiver
	session.status = LANStatus{Active: true, Address: "http://" + listener.Addr().String(), Code: receiver.PairingCode()}
	c.mu.Lock()
	c.session = session
	c.mu.Unlock()
	go func() {
		defer close(session.done)
		for {
			select {
			case <-life.Done():
				return
			case item := <-session.jobs:
				if life.Err() != nil {
					return
				}
				_, _ = c.service.RetryInbox(life, item)
			}
		}
	}()
	go func() { _ = receiver.Serve(listener); c.stop(session) }()
	go func() { <-receiver.Done(); c.stop(session) }()
	if err := life.Err(); err != nil {
		go c.stop(session)
		return LANStatus{}, err
	}
	if err := ctx.Err(); err != nil {
		go c.stop(session)
		return LANStatus{}, err
	}
	return session.status, nil
}
func (c *lanController) stop(expected *lanSession) {
	c.transition.Lock()
	defer c.transition.Unlock()
	c.mu.Lock()
	session := c.session
	if session == nil || (expected != nil && session != expected) {
		c.mu.Unlock()
		return
	}
	c.session = nil
	c.mu.Unlock()
	session.cancel()
	session.listener.Close()
	session.receiver.Stop()
	if session.unwatch != nil {
		session.unwatch()
	}
	<-session.done
}

type lanUpload struct {
	upload  *library.InboxUpload
	session *lanSession
}

func (u *lanUpload) Abort() error { return u.upload.Abort() }
func (u *lanUpload) Commit(ctx context.Context) error {
	item, err := u.upload.Commit(ctx)
	if err != nil {
		return err
	}
	if item.Status == "stored" {
		select {
		case u.session.jobs <- library.InboxSelection{ID: item.ID, Revision: item.Revision}:
		default:
		}
	}
	return nil
}
func (s *Service) Inbox(ctx context.Context) ([]library.InboxItem, error) {
	return command(s, ctx, false, s.store.Inbox)
}
func (s *Service) GetInbox(ctx context.Context, id string) (library.InboxItem, error) {
	return command(s, ctx, false, func(c context.Context) (library.InboxItem, error) { return s.store.GetInbox(c, id) })
}
func (s *Service) RetryInbox(ctx context.Context, item library.InboxSelection) (library.InboxItem, error) {
	return command(s, ctx, true, func(c context.Context) (library.InboxItem, error) {
		row, err := s.store.BeginInboxProcessing(c, item.ID, item.Revision)
		if err != nil {
			return row, err
		}
		data, err := s.store.ReadInboxOriginal(c, row.ID, row.Revision)
		var extraction document.Extraction
		if err == nil {
			extraction, err = s.processor.Extract(c, data)
		}
		if c.Err() != nil {
			err = c.Err()
		}
		if err == nil {
			err = extraction.Validate()
		}
		if err == nil {
			saved, saveErr := s.store.SaveInboxExtraction(c, row.ID, row.Revision, extraction)
			if saveErr == nil {
				return saved, nil
			}
			err = saveErr
		}
		err = safeImportError(err)
		cleanup, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if failed, e := s.store.FailInbox(cleanup, row.ID, row.Revision, failureCode(err)); e == nil {
			row = failed
		}
		return row, err
	})
}
func (s *Service) DeleteInbox(ctx context.Context, selection []library.InboxSelection) (library.DeleteResult, error) {
	selection = append([]library.InboxSelection(nil), selection...)
	return command(s, ctx, true, func(c context.Context) (library.DeleteResult, error) { return s.store.DeleteInbox(c, selection) })
}
func (s *Service) ArchiveInbox(ctx context.Context, selection []library.InboxSelection, edit library.Edit) (library.Report, error) {
	selection = append([]library.InboxSelection(nil), selection...)
	return command(s, ctx, true, func(c context.Context) (library.Report, error) { return s.store.ArchiveInbox(c, selection, edit) })
}
func (s *Service) PreviewInbox(ctx context.Context, item library.InboxSelection, page int) (image.Image, error) {
	return command(s, ctx, false, func(c context.Context) (image.Image, error) {
		row, err := s.store.GetInbox(c, item.ID)
		if err != nil {
			return nil, err
		}
		if row.Revision != item.Revision {
			return nil, library.ErrState
		}
		if row.Status != "reviewable" || page < 1 || page > row.Extraction.PageCount {
			return nil, document.ErrInvalid
		}
		data, err := s.store.ReadInboxOriginal(c, item.ID, item.Revision)
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
