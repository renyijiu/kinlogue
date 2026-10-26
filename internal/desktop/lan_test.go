package desktop

import (
	"context"
	"errors"
	"image"
	"image/png"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
	"kinlogue/internal/app"
	"kinlogue/internal/library"
	"kinlogue/internal/macos"
)

type phoneBackend struct {
	*fakeBackend
	items         []library.InboxItem
	archiveError  error
	archived      []library.InboxSelection
	archiveEdit   library.Edit
	starts, stops int
	deleted       []library.InboxSelection
	statusMu      sync.Mutex
	status        app.LANStatus
}

func (f *phoneBackend) LANInterfaces(context.Context) ([]macos.LANInterface, error) {
	return []macos.LANInterface{{Name: "test", Index: 1, Address: netip.MustParseAddr("192.0.2.2"), PrefixBits: 24}}, nil
}
func (f *phoneBackend) StartLAN(context.Context, macos.LANInterface) (app.LANStatus, error) {
	f.starts++
	f.setStatus(app.LANStatus{Active: true, Address: "http://192.0.2.2:1234/", Code: "123456"})
	return f.LANStatus(), nil
}
func (f *phoneBackend) setStatus(v app.LANStatus) {
	f.statusMu.Lock()
	f.status = v
	f.statusMu.Unlock()
}
func (f *phoneBackend) RevokeLAN() { f.stops++; f.setStatus(app.LANStatus{}) }
func (f *phoneBackend) StopLAN()   { f.stops++; f.setStatus(app.LANStatus{}) }
func (f *phoneBackend) LANStatus() app.LANStatus {
	f.statusMu.Lock()
	defer f.statusMu.Unlock()
	return f.status
}
func (f *phoneBackend) Inbox(context.Context) ([]library.InboxItem, error) {
	return append([]library.InboxItem(nil), f.items...), nil
}
func (f *phoneBackend) GetInbox(_ context.Context, id string) (library.InboxItem, error) {
	for _, i := range f.items {
		if i.ID == id {
			return i, nil
		}
	}
	return library.InboxItem{}, library.ErrNotFound
}
func (f *phoneBackend) RetryInbox(context.Context, library.InboxSelection) (library.InboxItem, error) {
	return library.InboxItem{}, nil
}
func (f *phoneBackend) DeleteInbox(_ context.Context, selected []library.InboxSelection) (library.DeleteResult, error) {
	f.deleted = append([]library.InboxSelection(nil), selected...)
	f.items = slices.DeleteFunc(f.items, func(item library.InboxItem) bool {
		return slices.ContainsFunc(selected, func(sel library.InboxSelection) bool { return sel.ID == item.ID })
	})
	return library.DeleteResult{}, nil
}
func (f *phoneBackend) ArchiveInbox(_ context.Context, selected []library.InboxSelection, e library.Edit) (library.Report, error) {
	f.archived = append([]library.InboxSelection(nil), selected...)
	f.archiveEdit = e
	return f.report, f.archiveError
}
func (f *phoneBackend) PreviewInbox(context.Context, library.InboxSelection, int) (image.Image, error) {
	return image.NewRGBA(image.Rect(0, 0, 10, 10)), nil
}
func phoneScreen(t *testing.T) (*screen, *phoneBackend, func()) {
	t.Helper()
	s, base, _ := testScreen(t)
	f := &phoneBackend{fakeBackend: base, items: []library.InboxItem{{ID: "inbox-a", FileName: "synthetic-a.pdf", Status: "reviewable", Revision: 1}, {ID: "inbox-b", FileName: "synthetic-b.pdf", Status: "reviewable", Revision: 2}}}
	s.backend = f
	s.phoneBackend = f
	s.phonePage = true
	s.phone.lifecycleReady = true
	s.clearReport()
	s.phone.items = f.items
	s.phone.memberID = "member-a"
	s.phone.title = "Synthetic report"
	updates := make(chan func(), 20)
	s.post = func(fn func()) { updates <- fn }
	drain := func() {
		t.Helper()
		timeout := time.After(3 * time.Second)
		for s.busy != "" || s.previewBusy {
			select {
			case fn := <-updates:
				fn()
			case <-timeout:
				t.Fatal("phone UI did not finish")
			}
		}
	}
	return s, f, drain
}
func TestPhoneNavigationPreservesDirtyReport(t *testing.T) {
	s, f, _ := phoneScreen(t)
	s.phonePage = false
	s.accept(f.report)
	s.edit.Text = "Unsaved synthetic text"
	tt := ui.NewTester(s.view, 1240, 900)
	// The open review sheet blocks the sidebar, like a Swift sheet.
	_ = tt.Click("Phone Uploads")
	tt.Frame()
	if s.phonePage || s.pending != nil || s.edit.Text != "Unsaved synthetic text" || !tt.HasText("Confirm Report Information") {
		t.Fatal("phone navigation passed the open review sheet")
	}
}
func TestPhoneSelectionOrderAndRevisionFreeze(t *testing.T) {
	s, _, _ := phoneScreen(t)
	s.togglePhoneItem(s.phone.items[0])
	s.togglePhoneItem(s.phone.items[1])
	s.movePhoneItem(1, -1)
	if s.phone.selected[0].ID != "inbox-b" {
		t.Fatal("order not retained")
	}
	next := append([]library.InboxItem(nil), s.phone.items...)
	next[1].Revision++
	s.applyPhoneItems(next)
	if len(s.phone.selected) != 1 || s.phone.selected[0].ID != "inbox-a" {
		t.Fatal("refresh silently adopted changed revision")
	}
}

func TestPhoneRowSelectionMatchesNativeListModifiers(t *testing.T) {
	s, f, _ := phoneScreen(t)
	f.items = append(f.items,
		library.InboxItem{ID: "inbox-c", FileName: "synthetic-c.pdf", Status: "failed", Revision: 3},
		library.InboxItem{ID: "inbox-d", FileName: "synthetic-d.pdf", Status: "reviewable", Revision: 4})
	s.phone.items = f.items
	tt := ui.NewTester(s.view, 1240, 900)
	click := func(index int, modifiers ui.Modifiers) {
		t.Helper()
		item := f.items[index]
		if err := tt.ClickWith(modifiers, s.t("phone_row_label", item.FileName, s.t(phoneStatusKey(item.Status)))); err != nil {
			t.Fatal(err)
		}
	}
	ids := func(want ...string) {
		t.Helper()
		got := make([]string, len(s.phone.selected))
		for i, item := range s.phone.selected {
			got[i] = item.ID
		}
		if !slices.Equal(got, want) {
			t.Fatalf("selected IDs: got %v, want %v", got, want)
		}
	}
	click(0, 0)
	click(1, 0)
	ids("inbox-b")
	click(0, ui.Cmd)
	ids("inbox-b", "inbox-a")
	click(1, ui.Cmd)
	ids("inbox-a")
	click(0, 0)
	click(3, ui.Shift)
	ids("inbox-a", "inbox-b", "inbox-d")
}

func TestPhoneArchiveFormShowsDefaultDateBeforeSelection(t *testing.T) {
	s, _, _ := phoneScreen(t)
	s.phone.memberID = ""
	tt := ui.NewTester(s.view, 1240, 900)
	if !tt.HasText(s.t("phone_archive")) || !tt.HasText(s.t("phone_selected_summary", 0)) {
		t.Fatal("the archive form must remain visible before selection")
	}
	if s.phone.date != time.Now().Format("2006-01-02") || s.phone.memberID != "" {
		t.Fatal("phone filing should default to today without preselecting a member")
	}
}

func TestPhonePreviewDoesNotChangeFilingSelection(t *testing.T) {
	for _, hasSelection := range []bool{false, true} {
		t.Run(map[bool]string{false: "empty", true: "selected"}[hasSelection], func(t *testing.T) {
			s, f, _ := phoneScreen(t)
			if hasSelection {
				s.togglePhoneItem(f.items[0])
			}
			selected := append([]library.InboxSelection(nil), s.phone.selected...)
			tt := ui.NewTester(s.view, 1240, 900)
			if err := tt.Click(s.t("phone_preview_item", f.items[1].FileName)); err != nil {
				t.Fatal(err)
			}
			tt.Frame()
			if s.originalViewer != "phone" || !slices.Equal(selected, s.phone.selected) {
				t.Fatal("preview must open independently of the filing selection")
			}
			tt.Key(0, ui.KeyEscape)
			tt.Frame()
			if s.originalViewer != "" || !slices.Equal(selected, s.phone.selected) {
				t.Fatal("closing the viewer must retain the filing selection")
			}
			if hasSelection && s.phone.preview.ID != f.items[0].ID {
				t.Fatal("the inline preview must return to a selected original after closing the viewer")
			}
		})
	}
}

func TestPhoneArchiveFailureKeepsSelection(t *testing.T) {
	s, f, drain := phoneScreen(t)
	s.phone.date = "2025-11-22"
	f.archiveError = errors.New("synthetic failure")
	s.togglePhoneItem(s.phone.items[0])
	s.archivePhone()
	drain()
	if len(s.phone.selected) != 1 || !s.phonePage || s.message != "phone_archive_failed" || s.phone.date != "2025-11-22" {
		t.Fatal("failed archive lost selection")
	}
	f.archiveError = nil
	s.archivePhone()
	drain()
	// Like Swift, the queue stays open with a notice; the new draft waits in
	// the sidebar's Awaiting Review section.
	if !s.phonePage || s.report.ID != "" || len(s.phone.selected) != 0 || f.confirmed || s.phone.notice == nil || s.phone.notice.duplicate {
		t.Fatal("archive did not add one report for review and keep the queue")
	}
	if f.archiveEdit.MemberID != "member-a" || f.archiveEdit.Title != "synthetic-a.pdf" || f.archived[0].Revision != 1 {
		t.Fatal("archive did not freeze selection and metadata")
	}
	if s.phone.date != "2025-11-22" || f.archiveEdit.Date != "2025-11-22" {
		t.Fatal("filing must use and retain the chosen report date")
	}
	tt := ui.NewTester(s.view, 1240, 900)
	if !tt.HasText(s.t("phone_notice_added")) {
		t.Fatal("archive notice hidden")
	}
}
func TestPhoneStartRequiresExplicitTrust(t *testing.T) {
	s, f, drain := phoneScreen(t)
	s.phone.interfaces, _ = f.LANInterfaces(context.Background())
	s.phone.interfaceID = phoneInterfaceID(s.phone.interfaces[0])
	s.startPhone()
	drain()
	if f.starts != 0 {
		t.Fatal("started without trusted-network confirmation")
	}
	s.phone.trusted = true
	s.startPhone()
	drain()
	if f.starts != 1 || !s.phone.status.Active || s.phone.trusted {
		t.Fatal("explicit start not reflected or consent persisted")
	}
}

func TestPhoneMinimumWindowLayout(t *testing.T) {
	for _, lang := range []string{"en", "zh-Hans"} {
		for selectionCount := range 3 {
			s, f, _ := phoneScreen(t)
			s.phone.interfaces, _ = f.LANInterfaces(context.Background())
			s.phone.interfaceID = phoneInterfaceID(s.phone.interfaces[0])
			for _, item := range s.phone.items[:selectionCount] {
				s.togglePhoneItem(item)
			}
			s.language = lang
			tt := ui.NewTester(s.view, 1080, 700)
			keys := []string{"phone_uploads", "phone_receive", "phone_queue_title", "phone_delete_selected", "phone_archive", "phone_file_for", "phone_report_date"}
			if selectionCount > 0 {
				keys = append(keys, "phone_as_one_report", "phone_page_order")
			}
			for _, key := range keys {
				box, ok := tt.Find(s.t(key))
				if !ok || box.X < 0 || box.Y < 0 || box.X+box.W > 1081 || box.Y+box.H > 701 {
					t.Fatalf("%s, %d selected: minimum window control clipped: %s", lang, selectionCount, key)
				}
			}
			if dir := os.Getenv("KINLOGUE_LAN_UI_EVIDENCE"); dir != "" && selectionCount == 1 {
				file, err := os.Create(filepath.Join(dir, "phone-"+lang+".png"))
				if err != nil {
					t.Fatal(err)
				}
				err = png.Encode(file, tt.Image())
				closeErr := file.Close()
				if err != nil || closeErr != nil {
					t.Fatal("could not write synthetic UI evidence")
				}
			}
		}
	}
}

func TestPhoneFileImportShowsReportAndStopsPanelRefresh(t *testing.T) {
	for _, grouped := range []bool{false, true} {
		t.Run(map[bool]string{false: "single", true: "grouped"}[grouped], func(t *testing.T) {
			s, f, drain := phoneScreen(t)
			cancelled := false
			s.phone.refreshCancel = func() { cancelled = true }
			generation := s.phone.generation
			paths := []string{"synthetic.pdf"}
			if grouped {
				paths = append(paths, "synthetic-2.pdf")
			}
			s.chooseImport(paths)
			if grouped {
				s.importSelection(true)
			}
			drain()
			if s.phonePage || !cancelled || s.phone.generation <= generation || s.report.ID != f.report.ID {
				t.Fatal("file import did not leave phone panel and show report")
			}
			tt := ui.NewTester(s.view, 1240, 900)
			if _, ok := tt.Find(s.t("confirm")); !ok {
				t.Fatal("imported report confirmation not visible")
			}
		})
	}
}
func TestPhoneDuplicateConfirmedOpensExistingMember(t *testing.T) {
	s, f, drain := phoneScreen(t)
	f.report.Status = "confirmed"
	f.report.Review.MemberID = "member-existing"
	s.togglePhoneItem(s.phone.items[0])
	s.archivePhone()
	drain()
	if s.phone.notice == nil || !s.phone.notice.duplicate || !s.phonePage {
		t.Fatal("confirmed duplicate must report the existing record")
	}
	tt := ui.NewTester(s.view, 1240, 900)
	if err := tt.Click(s.t("phone_view_existing")); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	drain()
	if s.phonePage || s.memberID != "member-existing" || s.report.Status != "confirmed" || s.message != "phone_existing_confirmed" || f.confirmed {
		t.Fatal("View Existing Record must open the existing timeline without reconfirmation")
	}
}

func TestPhoneUnavailableLifecyclePreservesInbox(t *testing.T) {
	s, f, drain := phoneScreen(t)
	// Observer installation failed: receiving stays unavailable, organizing works.
	s.phone.lifecycleReady = false
	s.phone.trusted = true
	s.phone.interfaces, _ = f.LANInterfaces(context.Background())
	s.phone.interfaceID = phoneInterfaceID(s.phone.interfaces[0])
	s.startPhone()
	drain()
	if f.starts != 0 {
		t.Fatal("missing lifecycle observer must block receiving")
	}
	s.phone.receiverOpen = true
	tt := ui.NewTester(s.view, 1080, 700)
	for _, lang := range []string{"en", "zh-Hans"} {
		s.language = lang
		tt.Frame()
		if _, ok := tt.Find(s.t("phone_lifecycle_unavailable")); !ok {
			t.Fatal("disabled reason hidden")
		}
		if _, ok := tt.Find(f.items[0].FileName); !ok {
			t.Fatal("saved inbox hidden")
		}
	}
	s.phone.receiverOpen = false
	s.togglePhoneItem(s.phone.items[0])
	s.archivePhone()
	drain()
	if len(f.archived) != 1 || s.phone.notice == nil {
		t.Fatal("blocking reception must retain archive workflow")
	}
}

// The active panel mirrors the Swift sheet: QR code for the URL only, the URL
// with a copy action that never copies the pairing code, and the code itself.
func TestPhoneActivePanelShowsQRCodeAddressAndCode(t *testing.T) {
	for _, lang := range []string{"en", "zh-Hans"} {
		s, f, drain := phoneScreen(t)
		var copied []string
		s.copyText = func(v string) { copied = append(copied, v) }
		s.language = lang
		s.phone.trusted = true
		s.phone.interfaces, _ = f.LANInterfaces(context.Background())
		s.phone.interfaceID = phoneInterfaceID(s.phone.interfaces[0])
		s.phone.receiverOpen = true
		s.startPhone()
		drain()
		tt := ui.NewTester(s.view, 1080, 700)
		// The code is exposed digit by digit to VoiceOver, like the Swift sheet.
		for _, text := range []string{"http://192.0.2.2:1234/", s.t("phone_code_label", "1 2 3 4 5 6"), s.t("phone_troubleshoot"), s.t("phone_copy_address")} {
			box, ok := tt.Find(text)
			if !ok || box.X < 0 || box.Y < 0 || box.X+box.W > 1081 || box.Y+box.H > 701 {
				t.Fatalf("%s: active panel item hidden or clipped: %s", lang, text)
			}
		}
		if s.phone.qr == nil || s.phone.qrFor != "http://192.0.2.2:1234/" {
			t.Fatal("QR code must encode the advertised URL")
		}
		if err := tt.Click(s.t("phone_copy_address")); err != nil {
			t.Fatal(err)
		}
		tt.Frame()
		if len(copied) != 1 || copied[0] != "http://192.0.2.2:1234/" {
			t.Fatalf("copy must place only the URL on the clipboard: %q", copied)
		}
		if !tt.HasText(s.t("phone_address_copied")) {
			t.Fatal("copy confirmation hidden")
		}
		s.stopPhone()
		drain()
		if s.phone.copied || s.phone.status.Active {
			t.Fatal("stopping must clear the active panel")
		}
	}
}

func TestPhoneQRCodeFollowsAddress(t *testing.T) {
	s, _, _ := phoneScreen(t)
	first := s.phoneQR("http://192.0.2.2:1234/")
	if first == nil || s.phoneQR("http://192.0.2.2:1234/") != first {
		t.Fatal("QR code should be cached for one address")
	}
	if next := s.phoneQR("http://192.0.2.2:5678/"); next == nil || next == first {
		t.Fatal("a new address needs a new QR code")
	}
	if s.phoneQR("") != nil {
		t.Fatal("no address, no QR code")
	}
}

func TestPhoneDeleteSelectedRemovesOnlySelection(t *testing.T) {
	s, f, drain := phoneScreen(t)
	f.items = append(f.items, library.InboxItem{ID: "inbox-c", FileName: "synthetic-c.pdf", Status: "reviewable", Revision: 3})
	s.phone.items = f.items
	s.togglePhoneItem(s.phone.items[0])
	s.togglePhoneItem(s.phone.items[2])
	tt := ui.NewTester(s.view, 1080, 700)
	if err := tt.Click(s.t("phone_delete_selected")); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if len(s.phone.deleteSelection) != 2 || !tt.HasText(s.t("phone_delete_title")) {
		t.Fatal("delete prompt must freeze the whole selection")
	}
	s.deletePhone()
	drain()
	if len(f.deleted) != 2 || f.deleted[0] != (library.InboxSelection{ID: "inbox-a", Revision: 1}) || f.deleted[1] != (library.InboxSelection{ID: "inbox-c", Revision: 3}) {
		t.Fatalf("deleted the wrong items: %v", f.deleted)
	}
	if len(s.phone.selected) != 0 || len(s.phone.items) != 1 || s.phone.items[0].ID != "inbox-b" || s.message != "phone_deleted" {
		t.Fatal("unselected item must remain and selection must clear")
	}
}

// The receiver sheet follows Swift: trust confirmation before Start, and
// Close only dismisses the sheet while receiving continues.
func TestPhoneReceiverSheetStartsAndClosesWithoutStopping(t *testing.T) {
	s, f, drain := phoneScreen(t)
	s.phone.interfaces, _ = f.LANInterfaces(context.Background())
	s.phone.interfaceID = phoneInterfaceID(s.phone.interfaces[0])
	tt := ui.NewTester(s.view, 1240, 900)
	if err := tt.Click(s.t("phone_receive")); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if !s.phone.receiverOpen || !tt.HasText(s.t("phone_receive_title")) || !tt.HasText(s.t("phone_plain_http")) {
		t.Fatal("receive action did not present the receiver sheet")
	}
	_ = tt.Click(s.t("phone_start"))
	tt.Key(0, ui.KeyEnter)
	if f.starts != 0 {
		t.Fatal("started before the trusted network confirmation")
	}
	if err := tt.Click(s.t("phone_trusted")); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	tt.Key(0, ui.KeyEnter)
	drain()
	tt.Frame()
	if f.starts != 1 || !s.phone.status.Active || !tt.HasText("http://192.0.2.2:1234/") {
		t.Fatal("receiver did not start from the sheet")
	}
	tt.Key(0, ui.KeyEscape)
	tt.Frame()
	if s.phone.receiverOpen || !s.phone.status.Active || f.stops != 0 || !tt.HasText(s.t("phone_receiving")) {
		t.Fatal("closing the sheet must keep receiving, like Swift")
	}
}
