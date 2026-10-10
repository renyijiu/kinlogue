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

// phoneNotice is the Swift archive notice: a new draft, or an existing
// report the selection duplicated.
type phoneNotice struct {
	reportID  string
	duplicate bool
	confirmed bool
	memberID  string
}

type phoneFlow struct {
	refreshCancel                                 context.CancelFunc
	items                                         []library.InboxItem
	selected                                      []library.InboxSelection
	interfaces                                    []macos.LANInterface
	interfaceID, memberID, title, date            string
	status                                        app.LANStatus
	trusted, lifecycleReady, refreshing, stopping bool
	receiverOpen                                  bool
	generation                                    uint64
	list                                          ui.ListState
	preview                                       library.InboxItem
	page                                          int
	bitmap                                        *ui.Bitmap
	previewGeneration                             uint64
	previewBusy, previewFailed                    bool
	deleteSelection                               []library.InboxSelection
	notice                                        *phoneNotice
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
func (s *screen) promptDeletePhoneItem(item library.InboxItem) {
	if s.busy != "" || item.Status == "processing" {
		return
	}
	s.phone.deleteSelection = []library.InboxSelection{{ID: item.ID, Revision: item.Revision}}
}

// phoneCount is the sidebar badge: the live queue on the phone page,
// otherwise the count from the last library load.
func (s *screen) phoneCount() int {
	if s.phonePage {
		return len(s.phone.items)
	}
	return s.inboxCount
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
	// No member is preselected: filing a report to the wrong person is easy
	// to miss, so the Swift picker starts at "Select Family Member…" too.
	s.startPhoneRefresh()
	s.refreshPhone()
}

// openReceiver is the Swift "receive from phone" action: it presents the
// receiver sheet with fresh addresses and status, from any section.
func (s *screen) openReceiver() {
	if s.phoneBackend == nil || s.busy != "" || s.closed || s.shutdown != nil {
		return
	}
	s.phone.receiverOpen = true
	s.phone.copied = false
	if s.phone.refreshCancel == nil {
		s.startPhoneRefresh()
	}
	s.refreshPhone()
}

func (s *screen) closeReceiver() {
	if s.phone.stopping {
		return
	}
	s.phone.receiverOpen = false
	s.phone.trusted = false
	if !s.phonePage && !s.phone.status.Active {
		s.stopPhoneRefresh()
	}
}

func (s *screen) refreshPhone() {
	watching := s.phonePage || s.phone.receiverOpen || s.phone.status.Active
	if s.phoneBackend == nil || !watching || s.phone.refreshing || s.busy != "" || s.closed || s.shutdown != nil || s.activating || s.restartOnly {
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
			if s.closed || generation != s.phone.generation || s.busy != "" {
				return
			}
			if s.phone.status.Active && !status.Active {
				s.phone.copied = false
			}
			s.phone.status = status
			if interfaceErr == nil {
				s.phone.interfaces = interfaces
				known := slices.ContainsFunc(interfaces, func(i macos.LANInterface) bool { return phoneInterfaceID(i) == s.phone.interfaceID })
				if !known {
					s.phone.interfaceID = ""
					if len(interfaces) > 0 {
						s.phone.interfaceID = phoneInterfaceID(interfaces[0])
					}
				}
			}
			if err != nil {
				if s.phonePage {
					s.message = "phone_load_failed"
				}
				return
			}
			s.inboxCount = len(items)
			if s.phonePage {
				s.applyPhoneItems(items)
			}
		})
	}()
}
func (s *screen) applyPhoneItems(items []library.InboxItem) {
	s.phone.items = items
	s.inboxCount = len(items)
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
			s.clearPhonePreview()
		}
	}
	s.ensurePhonePreview()
}
func (s *screen) phoneSelected(id string) bool {
	return slices.ContainsFunc(s.phone.selected, func(sel library.InboxSelection) bool { return sel.ID == id })
}
func (s *screen) togglePhoneItem(item library.InboxItem) {
	if s.busy != "" || item.Status != "reviewable" {
		return
	}
	s.phone.notice = nil
	for i, sel := range s.phone.selected {
		if sel.ID == item.ID {
			s.phone.selected = slices.Delete(s.phone.selected, i, i+1)
			if s.phone.preview.ID == item.ID {
				s.clearPhonePreview()
			}
			s.ensurePhonePreview()
			return
		}
	}
	if len(s.phone.selected) >= document.MaxSources {
		s.message = "sources_limit"
		return
	}
	s.phone.selected = append(s.phone.selected, library.InboxSelection{ID: item.ID, Revision: item.Revision})
	s.ensurePhonePreview()
}
func (s *screen) movePhoneItem(index, delta int) {
	next := index + delta
	if s.busy != "" || index < 0 || index >= len(s.phone.selected) || next < 0 || next >= len(s.phone.selected) {
		return
	}
	s.phone.selected[index], s.phone.selected[next] = s.phone.selected[next], s.phone.selected[index]
}
func (s *screen) phoneItem(id string) (library.InboxItem, bool) {
	for _, item := range s.phone.items {
		if item.ID == id {
			return item, true
		}
	}
	return library.InboxItem{}, false
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
			if s.phone.refreshCancel == nil {
				s.startPhoneRefresh()
			}
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

// archivePhone follows the Swift queue: the selection becomes one report for
// review and the queue stays open with a notice. The title starts as the
// first original's name and is reviewed with the other fields.
func (s *screen) archivePhone() {
	if s.phoneBackend == nil || len(s.phone.selected) == 0 || s.phone.memberID == "" || s.composing {
		return
	}
	selected := append([]library.InboxSelection(nil), s.phone.selected...)
	title := ""
	if first, ok := s.phoneItem(selected[0].ID); ok {
		title = first.FileName
	}
	edit := library.Edit{MemberID: s.phone.memberID, Title: title, Date: s.phone.date}
	existing := map[string]bool{}
	for _, d := range s.drafts {
		existing[d.ID] = true
	}
	member, query := s.memberID, s.query
	s.phone.generation++
	s.job("phone_archiving", true, func(ctx context.Context) func() {
		report, err := s.phoneBackend.ArchiveInbox(ctx, selected, edit)
		var items []library.InboxItem
		var data snapshot
		var loadErr error
		if err == nil {
			items, loadErr = s.phoneBackend.Inbox(ctx)
			if loadErr == nil {
				data, loadErr = s.read(ctx, member, query, false)
			}
		}
		return func() {
			if err != nil {
				s.message = "phone_archive_failed"
				return
			}
			s.phone.selected = nil
			s.phone.date = ""
			s.clearPhonePreview()
			if loadErr == nil {
				s.apply(data)
				s.applyPhoneItems(items)
			}
			confirmed := report.Status == "confirmed"
			s.phone.notice = &phoneNotice{reportID: report.ID, duplicate: confirmed || existing[report.ID], confirmed: confirmed, memberID: report.Review.MemberID}
			s.message = ""
		}
	})
}

// openPhoneDuplicate is "View Existing Record": a confirmed record opens in
// its member's timeline, an existing draft opens for review.
func (s *screen) openPhoneDuplicate() {
	notice := s.phone.notice
	if notice == nil || notice.reportID == "" {
		return
	}
	s.queueNavigation(func() {
		s.phone.notice = nil
		s.phonePage = false
		s.stopPhoneRefresh()
		s.phone.generation++
		if notice.confirmed && notice.memberID != "" {
			s.memberID, s.query = notice.memberID, ""
		}
		member, query, id := s.memberID, s.query, notice.reportID
		s.job("loading", false, func(ctx context.Context) func() {
			data, loadErr := s.read(ctx, member, query, false)
			report, err := s.backend.Get(ctx, id)
			return func() {
				if loadErr == nil {
					s.apply(data)
				}
				if err != nil {
					s.message = "load_failed"
					return
				}
				s.clearReport()
				s.accept(report)
				s.preview(1)
				if report.Status == "confirmed" {
					s.message = "phone_existing_confirmed"
				}
			}
		})
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
				s.message = "cleanup_pending"
			default:
				s.message = "phone_deleted"
			}
		}
	})
}

func (s *screen) clearPhonePreview() {
	s.phone.previewGeneration++
	s.phone.preview, s.phone.bitmap, s.phone.page = library.InboxItem{}, nil, 0
	s.phone.previewBusy, s.phone.previewFailed = false, false
}

// ensurePhonePreview shows the first selected original when nothing is
// previewed, like the Swift selection detail.
func (s *screen) ensurePhonePreview() {
	if s.phone.preview.ID != "" || len(s.phone.selected) == 0 {
		return
	}
	if item, ok := s.phoneItem(s.phone.selected[0].ID); ok {
		s.previewPhone(item, 1)
	}
}

// previewPhone loads one page without taking the shared busy state, so the
// queue stays usable while an original renders.
func (s *screen) previewPhone(item library.InboxItem, page int) {
	if s.phoneBackend == nil || item.Status != "reviewable" || page < 1 {
		return
	}
	s.phone.previewGeneration++
	generation := s.phone.previewGeneration
	s.phone.preview, s.phone.page, s.phone.bitmap = item, page, nil
	s.phone.previewBusy, s.phone.previewFailed = true, false
	backend, ctx := s.phoneBackend, s.ctx
	selection := library.InboxSelection{ID: item.ID, Revision: item.Revision}
	go func() {
		detail, err := backend.GetInbox(ctx, item.ID)
		var bitmap *ui.Bitmap
		if err == nil && detail.Revision == item.Revision {
			var img image.Image
			img, err = backend.PreviewInbox(ctx, selection, page)
			if err == nil && img != nil {
				bitmap = ui.NewBitmap(img)
			}
		} else if err == nil {
			err = library.ErrState
		}
		s.post(func() {
			if s.closed || generation != s.phone.previewGeneration {
				return
			}
			s.phone.previewBusy = false
			if err != nil || bitmap == nil {
				s.phone.previewFailed = true
				return
			}
			s.phone.preview, s.phone.bitmap = detail, bitmap
		})
	}()
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
