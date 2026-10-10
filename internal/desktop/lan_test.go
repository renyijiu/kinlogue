package desktop

import (
	"context"
	"errors"
	"image"
	"image/png"
	"net/netip"
	"os"
	"path/filepath"
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
}

func (f *phoneBackend) LANInterfaces(context.Context) ([]macos.LANInterface, error) {
	return []macos.LANInterface{{Name: "test", Index: 1, Address: netip.MustParseAddr("192.0.2.2"), PrefixBits: 24}}, nil
}
func (f *phoneBackend) StartLAN(context.Context, macos.LANInterface) (app.LANStatus, error) {
	f.starts++
	return app.LANStatus{Active: true, Address: "http://192.0.2.2:1234", Code: "123456"}, nil
}
func (f *phoneBackend) RevokeLAN()               { f.stops++ }
func (f *phoneBackend) StopLAN()                 { f.stops++ }
func (f *phoneBackend) LANStatus() app.LANStatus { return app.LANStatus{} }
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
func (f *phoneBackend) DeleteInbox(context.Context, []library.InboxSelection) (library.DeleteResult, error) {
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
	if err := tt.Click("Phone uploads"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if s.phonePage || s.pending == nil || s.edit.Text != "Unsaved synthetic text" {
		t.Fatal("phone navigation discarded unsaved report")
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
func TestPhoneArchiveFailureKeepsSelection(t *testing.T) {
	s, f, drain := phoneScreen(t)
	f.archiveError = errors.New("synthetic failure")
	s.togglePhoneItem(s.phone.items[0])
	s.archivePhone()
	drain()
	if len(s.phone.selected) != 1 || !s.phonePage || s.message != "phone_archive_failed" {
		t.Fatal("failed archive lost selection")
	}
	f.archiveError = nil
	s.archivePhone()
	drain()
	if s.phonePage || s.report.ID != f.report.ID || len(s.phone.selected) != 0 || f.confirmed {
		t.Fatal("archive did not open unconfirmed report")
	}
	if f.archiveEdit.MemberID != "member-a" || f.archived[0].Revision != 1 {
		t.Fatal("archive did not freeze selection and metadata")
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
		s, f, _ := phoneScreen(t)
		s.phone.interfaces, _ = f.LANInterfaces(context.Background())
		s.phone.interfaceID = phoneInterfaceID(s.phone.interfaces[0])
		s.togglePhoneItem(s.phone.items[0])
		s.language = lang
		tt := ui.NewTester(s.view, 1080, 700)
		for _, key := range []string{"phone_uploads", "phone_start", "phone_refresh", "phone_archive"} {
			box, ok := tt.Find(s.t(key))
			if !ok || box.X < 0 || box.Y < 0 || box.X+box.W > 1081 || box.Y+box.H > 701 {
				t.Fatalf("minimum window control clipped: %s", key)
			}
		}
		if dir := os.Getenv("KINLOGUE_LAN_UI_EVIDENCE"); dir != "" {
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
	if s.memberID != "member-existing" || s.report.Status != "confirmed" || s.message != "phone_existing_confirmed" || f.confirmed {
		t.Fatal("confirmed duplicate must open existing timeline without reconfirmation")
	}
}

func TestPhoneUnavailableLifecyclePreservesInbox(t *testing.T) {
	s, f, drain := phoneScreen(t)
	s.phone.lifecycleReady = macos.LANReceptionReadiness() == nil
	s.phone.trusted = true
	s.phone.interfaces, _ = f.LANInterfaces(context.Background())
	s.phone.interfaceID = phoneInterfaceID(s.phone.interfaces[0])
	s.startPhone()
	drain()
	if f.starts != 0 || s.phone.lifecycleReady {
		t.Fatal("unsupported lock capability must block receiving")
	}
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
	s.togglePhoneItem(s.phone.items[0])
	s.archivePhone()
	drain()
	if len(f.archived) != 1 || s.report.ID != f.report.ID {
		t.Fatal("blocking reception must retain archive workflow")
	}
}
