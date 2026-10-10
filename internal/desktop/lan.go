package desktop

import (
	"context"
	"fmt"
	"image"
	"slices"
	"time"

	"github.com/egoist/mygo/ui"
	"kinlogue/internal/app"
	"kinlogue/internal/document"
	"kinlogue/internal/library"
	"kinlogue/internal/macos"
	"kinlogue/internal/qr"
)

// LANBackend is optional so recovery mode never opens a receiving session.
type LANBackend interface {
	LANInterfaces(context.Context) ([]macos.LANInterface, error)
	StartLAN(context.Context, macos.LANInterface) (app.LANStatus, error)
	StopLAN()
	RevokeLAN()
	LANStatus() app.LANStatus
	Inbox(context.Context) ([]library.InboxItem, error)
	GetInbox(context.Context, string) (library.InboxItem, error)
	RetryInbox(context.Context, library.InboxSelection) (library.InboxItem, error)
	DeleteInbox(context.Context, []library.InboxSelection) (library.DeleteResult, error)
	ArchiveInbox(context.Context, []library.InboxSelection, library.Edit) (library.Report, error)
	PreviewInbox(context.Context, library.InboxSelection, int) (image.Image, error)
}

type phoneFlow struct {
	refreshCancel                                 context.CancelFunc
	items                                         []library.InboxItem
	selected                                      []library.InboxSelection
	interfaces                                    []macos.LANInterface
	interfaceID, memberID, title, date            string
	status                                        app.LANStatus
	trusted, lifecycleReady, refreshing, stopping bool
	generation                                    uint64
	list                                          ui.ListState
	preview                                       library.InboxItem
	page                                          int
	bitmap                                        *ui.Bitmap
	deleteSelection                               []library.InboxSelection
	qr                                            *ui.Bitmap
	qrFor                                         string
	copied                                        bool
}

// phoneQR caches the address QR code. It encodes only the URL, never the
// pairing code, exactly like the Swift receiver sheet.
func (s *screen) phoneQR(address string) *ui.Bitmap {
	if address == "" {
		return nil
	}
	if s.phone.qrFor != address {
		s.phone.qrFor, s.phone.qr = address, nil
		if code, err := qr.Encode([]byte(address)); err == nil {
			s.phone.qr = ui.NewBitmap(code.Image(8))
		}
	}
	return s.phone.qr
}
func (s *screen) copyPhoneAddress() {
	if !s.phone.status.Active || s.phone.status.Address == "" || s.copyText == nil {
		return
	}
	s.copyText(s.phone.status.Address)
	s.phone.copied = true
}
func (s *screen) promptDeleteSelectedPhone() {
	if s.busy != "" || len(s.phone.selected) == 0 {
		return
	}
	s.phone.deleteSelection = append([]library.InboxSelection(nil), s.phone.selected...)
}
func phoneInterfaceID(i macos.LANInterface) string {
	return fmt.Sprintf("%d/%s/%d", i.Index, i.Address, i.PrefixBits)
}
func (s *screen) showPhone() {
	if s.phoneBackend == nil {
		return
	}
	s.clearReport()
	s.backupPage = false
	s.phonePage = true
	s.message = ""
	s.phone.generation++
	if s.phone.memberID == "" && len(s.members) > 0 {
		s.phone.memberID = s.members[0].ID
	}
	s.startPhoneRefresh()
	s.refreshPhone()
}
func (s *screen) refreshPhone() {
	if s.phoneBackend == nil || !s.phonePage || s.phone.refreshing || s.busy != "" || s.closed || s.shutdown != nil || s.activating || s.restartOnly {
		return
	}
	s.phone.refreshing = true
	generation := s.phone.generation
	backend := s.phoneBackend
	ctx := s.ctx
	go func() {
		items, err := backend.Inbox(ctx)
		interfaces, interfaceErr := backend.LANInterfaces(ctx)
		status := backend.LANStatus()
		s.post(func() {
			s.phone.refreshing = false
			if s.closed || !s.phonePage || generation != s.phone.generation || s.busy != "" {
				return
			}
			s.phone.status = status
			if err != nil {
				s.message = "phone_load_failed"
				return
			}
			s.applyPhoneItems(items)
			if interfaceErr == nil {
				s.phone.interfaces = interfaces
				if s.phone.interfaceID == "" && len(interfaces) > 0 {
					s.phone.interfaceID = phoneInterfaceID(interfaces[0])
				}
			}
		})
	}()
}
func (s *screen) applyPhoneItems(items []library.InboxItem) {
	s.phone.items = items
	valid := func(sel library.InboxSelection) bool {
		for _, item := range items {
			if item.ID == sel.ID && item.Revision == sel.Revision && item.Status == "reviewable" {
				return true
			}
		}
		return false
	}
	old := len(s.phone.selected)
	s.phone.selected = slices.DeleteFunc(s.phone.selected, func(sel library.InboxSelection) bool { return !valid(sel) })
	if len(s.phone.selected) != old {
		s.message = "phone_selection_changed"
	}
	if s.phone.preview.ID != "" {
		found := false
		for _, item := range items {
			if item.ID == s.phone.preview.ID && item.Revision == s.phone.preview.Revision {
				found = true
				break
			}
		}
		if !found {
			s.phone.preview = library.InboxItem{}
			s.phone.bitmap = nil
		}
	}
}
func (s *screen) togglePhoneItem(item library.InboxItem) {
	if s.busy != "" || item.Status != "reviewable" {
		return
	}
	for i, sel := range s.phone.selected {
		if sel.ID == item.ID {
			s.phone.selected = slices.Delete(s.phone.selected, i, i+1)
			return
		}
	}
	if len(s.phone.selected) >= document.MaxSources {
		s.message = "sources_limit"
		return
	}
	s.phone.selected = append(s.phone.selected, library.InboxSelection{ID: item.ID, Revision: item.Revision})
	if s.phone.title == "" {
		s.phone.title = item.FileName
	}
}
func (s *screen) movePhoneItem(index, delta int) {
	next := index + delta
	if s.busy != "" || index < 0 || index >= len(s.phone.selected) || next < 0 || next >= len(s.phone.selected) {
		return
	}
	s.phone.selected[index], s.phone.selected[next] = s.phone.selected[next], s.phone.selected[index]
}
func (s *screen) startPhone() {
	if s.phoneBackend == nil || !s.phone.trusted || !s.phone.lifecycleReady || s.phone.stopping || s.phone.status.Active || s.composing {
		return
	}
	var selected *macos.LANInterface
	for _, i := range s.phone.interfaces {
		if phoneInterfaceID(i) == s.phone.interfaceID {
			v := i
			selected = &v
			break
		}
	}
	if selected == nil {
		s.message = "phone_no_interface"
		return
	}
	iface := *selected
	s.phone.trusted = false
	s.phone.generation++
	s.job("phone_starting", false, func(ctx context.Context) func() {
		status, err := s.phoneBackend.StartLAN(ctx, iface)
		return func() {
			if err != nil {
				s.message = "phone_start_failed"
				return
			}
			s.phone.status = status
			s.phone.copied = false
			s.message = ""
		}
	})
}
func (s *screen) stopPhone() {
	if s.phoneBackend == nil || s.phone.stopping {
		return
	}
	s.phone.stopping = true
	s.phone.status = app.LANStatus{}
	s.phone.copied = false
	s.phone.trusted = false
	s.phone.generation++
	backend := s.phoneBackend
	go func() {
		backend.StopLAN()
		s.post(func() {
			if s.closed {
				return
			}
			s.phone.stopping = false
			s.phone.status = backend.LANStatus()
			s.message = "phone_stopped"
			s.refreshPhone()
		})
	}()
}
func (s *screen) retryPhone(item library.InboxItem) {
	sel := library.InboxSelection{ID: item.ID, Revision: item.Revision}
	s.phone.generation++
	s.job("phone_processing", true, func(ctx context.Context) func() {
		_, err := s.phoneBackend.RetryInbox(ctx, sel)
		items, loadErr := s.phoneBackend.Inbox(ctx)
		return func() {
			if loadErr == nil {
				s.applyPhoneItems(items)
			}
			if err != nil {
				s.message = "phone_retry_failed"
			} else {
				s.message = ""
			}
		}
	})
}
func (s *screen) archivePhone() {
	if s.phoneBackend == nil || len(s.phone.selected) == 0 || s.phone.memberID == "" || s.composing {
		return
	}
	selected := append([]library.InboxSelection(nil), s.phone.selected...)
	edit := library.Edit{MemberID: s.phone.memberID, Title: s.phone.title, Date: s.phone.date}
	s.phone.generation++
	s.job("phone_archiving", true, func(ctx context.Context) func() {
		report, err := s.phoneBackend.ArchiveInbox(ctx, selected, edit)
		return func() {
			if err != nil {
				s.message = "phone_archive_failed"
				return
			}
			s.phone.selected = nil
			s.phone.title = ""
			s.phone.date = ""
			s.phone.preview = library.InboxItem{}
			s.phone.bitmap = nil
			s.phonePage = false
			s.stopPhoneRefresh()
			s.memberID, s.query = "", ""
			s.accept(report)
			s.message = "phone_archived"
			if report.Status == "confirmed" {
				s.memberID = report.Review.MemberID
				s.message = "phone_existing_confirmed"
			}
			s.load(false)
		}
	})
}
func (s *screen) deletePhone() {
	selected := append([]library.InboxSelection(nil), s.phone.deleteSelection...)
	s.phone.deleteSelection = nil
	s.phone.generation++
	s.job("deleting", false, func(ctx context.Context) func() {
		result, err := s.phoneBackend.DeleteInbox(ctx, selected)
		items, loadErr := s.phoneBackend.Inbox(ctx)
		return func() {
			if loadErr == nil {
				s.applyPhoneItems(items)
			}
			if err == nil {
				s.phone.selected = slices.DeleteFunc(s.phone.selected, func(sel library.InboxSelection) bool {
					return slices.ContainsFunc(selected, func(d library.InboxSelection) bool { return d.ID == sel.ID })
				})
			}
			switch {
			case err != nil:
				s.message = "phone_delete_failed"
			case result.CleanupPending:
				s.message = "delete_cleanup_pending"
			default:
				s.message = "phone_deleted"
			}
		}
	})
}
func (s *screen) previewPhone(item library.InboxItem, page int) {
	if item.Status != "reviewable" {
		return
	}
	selection := library.InboxSelection{ID: item.ID, Revision: item.Revision}
	s.phone.generation++
	generation := s.phone.generation
	s.job("loading", true, func(ctx context.Context) func() {
		detail, err := s.phoneBackend.GetInbox(ctx, item.ID)
		var bitmap *ui.Bitmap
		if err == nil && detail.Revision == item.Revision {
			var img image.Image
			img, err = s.phoneBackend.PreviewInbox(ctx, selection, page)
			if err == nil {
				bitmap = ui.NewBitmap(img)
			}
		} else if err == nil {
			err = library.ErrState
		}
		return func() {
			if generation != s.phone.generation {
				return
			}
			if err != nil {
				s.message = "preview_failed"
				return
			}
			s.phone.preview = detail
			s.phone.page = page
			s.phone.bitmap = bitmap
			s.message = ""
		}
	})
}
func (s *screen) startPhoneRefresh() {
	if s.phoneBackend == nil {
		return
	}
	s.stopPhoneRefresh()
	ctx, cancel := context.WithCancel(s.ctx)
	s.phone.refreshCancel = cancel
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				s.post(func() { s.refreshPhone() })
			}
		}
	}()
}

func (s *screen) stopPhoneRefresh() {
	if s.phone.refreshCancel != nil {
		s.phone.refreshCancel()
		s.phone.refreshCancel = nil
	}
}
