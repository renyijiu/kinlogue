package desktop

import (
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
	"kinlogue/internal/library"
)

func confirmedTimeline(t *testing.T, member string) (*screen, *fakeBackend, func()) {
	t.Helper()
	s, f, drain := testScreen(t)
	s.clearReport()
	s.memberID = member
	f.report.Status = "confirmed"
	f.report.Review.Title = "Synthetic newest"
	s.records = []library.Report{
		{ID: "report-a", Status: "confirmed", FileName: "synthetic.pdf", Review: library.Edit{Title: "Synthetic newest", MemberID: "member-a"}},
		{ID: "report-b", Status: "confirmed", FileName: "synthetic-b.pdf", Review: library.Edit{Title: "Synthetic older", MemberID: "member-a"}},
	}
	return s, f, drain
}

func TestTimelineOpensNewestRecordWhenNothingIsOpen(t *testing.T) {
	s, f, drain := confirmedTimeline(t, allMembers)
	s.autoSelect()
	drain()
	if s.report.ID != "report-a" || s.report.Status != "confirmed" {
		t.Fatal("newest record was not opened")
	}
	// An open record is never replaced by a later load.
	f.report.ID = "report-b"
	s.autoSelect()
	if s.busy != "" || s.report.ID != "report-a" {
		t.Fatal("auto selection replaced the open record")
	}
}

func TestEmptyDetailIsOneState(t *testing.T) {
	s, _, _ := confirmedTimeline(t, allMembers)
	tt := ui.NewTester(s.view, 1240, 900)
	if !tt.HasText(s.t("select_record")) || tt.HasText(s.t("original_placeholder")) {
		t.Fatal("empty detail must be a single state without an empty original pane")
	}
}

func TestMemberChipOnlyInAllRecords(t *testing.T) {
	count := func(member string) int {
		s, _, _ := confirmedTimeline(t, member)
		tt := ui.NewTester(s.view, 1240, 900)
		n := 0
		for _, text := range tt.Texts() {
			if text == "Synthetic A" {
				n++
			}
		}
		return n
	}
	// The sidebar row counts twice, as its label and its visible text.
	// All Records: the sidebar row plus a chip on each of the two cards.
	// A member's timeline: the sidebar row and the toolbar title only.
	if all, own := count(allMembers), count("member-a"); all != 4 || own != 3 {
		t.Fatalf("member chips: all records %d, own timeline %d", all, own)
	}
}

func TestDetailHeaderKeepsEditAndMovesOtherActionsToMenu(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Status = "confirmed"
	f.report.Review.Date = "2025-11-22"
	s.accept(f.report)
	tt := ui.NewTester(s.view, 1240, 900)
	if _, ok := tt.Find(s.t("edit_record")); !ok {
		t.Fatal("Edit must stay visible")
	}
	if tt.HasText(s.t("delete_report")) || tt.HasText(s.t("export")) {
		t.Fatal("export and delete belong in the more menu")
	}
	if !tt.HasText("November 22, 2025") {
		t.Fatal("date belongs under the title")
	}
	if err := tt.Click(s.t("more_actions")); err != nil {
		t.Fatal(err)
	}
	if err := tt.ChooseMenuItem(s.t("delete_report")); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if !s.deletePrompt || s.deleteTarget != f.report.ID {
		t.Fatal("menu delete did not ask for confirmation")
	}
}

func TestSidebarNamesEachWaitingDraft(t *testing.T) {
	s, _, _ := testScreen(t)
	s.clearReport()
	s.drafts = []library.Report{
		{ID: "draft-a", Status: "review", FileName: "synthetic-a.pdf", Review: library.Edit{Title: "Synthetic blood test"}},
		{ID: "draft-b", Status: "review", FileName: "synthetic-b.pdf"},
	}
	tt := ui.NewTester(s.view, 1240, 900)
	if !tt.HasText("Synthetic blood test") || !tt.HasText("synthetic-b.pdf") || !tt.HasText(s.t("awaiting_review_count", 2)) {
		t.Fatal("waiting drafts are not distinguishable")
	}
}

func TestSuccessMessagesBecomeToasts(t *testing.T) {
	s, _, _ := confirmedTimeline(t, allMembers)
	s.message = "exported"
	tt := ui.NewTester(s.view, 1240, 900)
	tt.Frame()
	if s.message != "" {
		t.Fatal("a shown success toast must not linger as a status line")
	}
	s.message = "export_failed"
	tt.Frame()
	if s.message != "export_failed" || !tt.HasText(s.t("export_failed")) {
		t.Fatal("errors must stay visible until the next action")
	}
}

func TestCommandFFocusesSearch(t *testing.T) {
	s, _, _ := confirmedTimeline(t, allMembers)
	tt := ui.NewTester(s.view, 1240, 900)
	tt.Key(ui.Cmd, ui.KeyF)
	tt.Frame()
	if !tt.Focused(s.t("search")) {
		t.Fatal("Cmd+F did not focus the search field")
	}
}

func TestCommandReturnConfirmsReview(t *testing.T) {
	s, f, drain := testScreen(t)
	tt := ui.NewTester(s.view, 1240, 900)
	tt.Key(ui.Cmd, ui.KeyEnter)
	drain()
	if !f.confirmed || s.report.Status != "confirmed" {
		t.Fatal("Cmd+Return did not run the review sheet's primary action")
	}
}

func TestDateFieldChoosesAndClearsWithoutTyping(t *testing.T) {
	s, f, _ := testScreen(t)
	f.report.Review.Date = ""
	s.accept(f.report)
	tt := ui.NewTester(s.view, 1240, 900)
	if err := tt.Click(s.t("date_choose")); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if s.edit.Date != time.Now().Format("2006-01-02") {
		t.Fatalf("choosing a date did not set today: %q", s.edit.Date)
	}
	if err := tt.Click(s.t("date_clear")); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if s.edit.Date != "" {
		t.Fatal("clearing did not restore an unknown date")
	}
}

func TestPhoneArchiveBarWaitsForSelectionAndNoMemberIsPreselected(t *testing.T) {
	s, _, _ := phoneScreen(t)
	s.phone.memberID = ""
	s.showPhone()
	tt := ui.NewTester(s.view, 1240, 900)
	if tt.HasText(s.t("phone_archive")) || !tt.HasText(s.t("phone_select_hint")) {
		t.Fatal("archive form must wait for a selection")
	}
	s.togglePhoneItem(s.phone.items[0])
	tt.Frame()
	if !tt.HasText(s.t("phone_archive")) || s.phone.memberID != "" {
		t.Fatal("selection must show the archive form without choosing a member")
	}
}
