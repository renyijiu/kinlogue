package desktop

import (
	"context"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
	"kinlogue/internal/app"
	"kinlogue/internal/document"
	"kinlogue/internal/library"
)

// evidenceProcessor renders a plain synthetic page so layout evidence never
// depends on native frameworks or real documents.
type evidenceProcessor struct{}

func (evidenceProcessor) Extract(context.Context, []byte) (document.Extraction, error) {
	return document.Extraction{}, document.ErrUnavailable
}
func (evidenceProcessor) RenderPage(context.Context, []byte, int) (image.Image, error) {
	img := image.NewRGBA(image.Rect(0, 0, 1240, 1754))
	draw.Draw(img, img.Bounds(), &image.Uniform{color.White}, image.Point{}, draw.Src)
	ink := &image.Uniform{color.RGBA{40, 40, 40, 255}}
	for i, width := range []int{900, 700, 0, 820, 760, 640, 0, 880, 520, 700, 610} {
		if width == 0 {
			continue
		}
		y := 120 + i*90
		draw.Draw(img, image.Rect(100, y, 100+width, y+28), ink, image.Point{}, draw.Src)
	}
	return img, nil
}

// TestUIEvidence writes synthetic screenshots of the main Go screens when
// KINLOGUE_UI_EVIDENCE names an output directory. It is a comparison aid for
// the Swift baseline, not an acceptance test, and is skipped by default.
func TestUIEvidence(t *testing.T) {
	dir := os.Getenv("KINLOGUE_UI_EVIDENCE")
	if dir == "" {
		t.Skip("set KINLOGUE_UI_EVIDENCE to write synthetic UI screenshots")
	}
	store, err := library.Open(filepath.Join(t.TempDir(), "library"))
	if err != nil {
		t.Fatal(err)
	}
	service := app.New(store, evidenceProcessor{}, nil, nil)
	t.Cleanup(func() { _ = service.Close() })
	ctx := context.Background()
	members := map[string]string{}
	for _, name := range []string{"奶奶（合成示例）", "妈妈（合成示例）", "我（合成示例）", "爸爸（合成示例）"} {
		m, err := service.AddMember(ctx, name)
		if err != nil {
			t.Fatal(err)
		}
		members[name] = m.ID
	}
	type row struct{ member, title, date string }
	rows := []row{
		{"我（合成示例）", "影像检查报告", "2025-11-22"},
		{"奶奶（合成示例）", "影像检查报告", "2025-11-21"},
		{"爸爸（合成示例）", "影像检查报告", "2025-11-20"},
		{"妈妈（合成示例）", "影像检查报告", "2025-11-19"},
		{"我（合成示例）", "实验室检查报告", "2025-10-21"},
		{"奶奶（合成示例）", "实验室检查报告", "2025-10-20"},
		{"爸爸（合成示例）", "实验室检查报告", "2025-10-19"},
		{"妈妈（合成示例）", "门诊复查记录", "2025-09-19"},
	}
	var first, draft string
	for i, r := range append(rows, row{"我（合成示例）", "待确认的合成报告", "2025-12-01"}) {
		report, err := store.CreateDraftSources(ctx, []string{"synthetic-report.pdf"}, func(int) ([]byte, error) { return []byte("synthetic-original"), nil })
		if err != nil {
			t.Fatal(err)
		}
		report, err = store.SaveSourceExtraction(ctx, report.ID, report.Sources[0].ID, document.Extraction{Kind: "pdf", PageCount: 1, Engine: "synthetic", Blocks: []document.Block{{Page: 1, Text: "合成示例内容 · 仅用于产品界面展示", Method: "synthetic", Confidence: 1}}})
		if err != nil {
			t.Fatal(err)
		}
		edit := report.Review
		edit.MemberID, edit.Title, edit.Date = members[r.member], r.title, r.date
		edit.Text, edit.Notes = "合成示例内容 · 仅用于产品界面展示", "合成备注 · 示例健康中心"
		// Every fourth record keeps the fields empty to show the fallbacks.
		if i%4 != 3 {
			edit.Organization, edit.Department, edit.ReportType = "示例健康中心（合成）", "合成示例科室", r.title
			edit.Conclusion = "合成示例结论 · 仅用于产品界面展示"
		}
		if i < len(rows) {
			if _, err = service.Confirm(ctx, report.ID, edit); err != nil {
				t.Fatal(err)
			}
			if first == "" {
				first = report.ID
			}
		} else {
			if _, err = service.SaveReview(ctx, report.ID, edit); err != nil {
				t.Fatal(err)
			}
			draft = report.ID
		}
	}

	write := func(tt *ui.Tester, name string) {
		t.Helper()
		f, err := os.Create(filepath.Join(dir, name+".png"))
		if err != nil {
			t.Fatal(err)
		}
		defer f.Close()
		if err := png.Encode(f, tt.Image()); err != nil {
			t.Fatal(err)
		}
	}
	screenFor := func() (*screen, func(), *ui.Tester) {
		s, _, drain := testScreen(t)
		s.clearReport()
		s.backend = service
		s.load(true)
		drain()
		s.language = "zh-Hans"
		return s, drain, ui.NewTester(s.view, 1366, 768)
	}
	settle := func(tt *ui.Tester, drain func()) {
		for range 3 {
			tt.Frame()
			drain()
		}
		tt.Frame()
	}

	s, drain, tt := screenFor()
	settle(tt, drain)
	write(tt, "01-all-records")
	s.open(first)
	settle(tt, drain)
	write(tt, "02-all-records-detail")
	s.startEditing()
	settle(tt, drain)
	write(tt, "03-confirmed-edit")

	s, drain, tt = screenFor()
	s.open(draft)
	settle(tt, drain)
	write(tt, "04-draft-review")

	s, drain, tt = screenFor()
	s.selectMember(members["我（合成示例）"])
	settle(tt, drain)
	write(tt, "05-member-timeline")

	s, drain, tt = screenFor()
	s.backups = &fakeBackup{}
	s.showBackup()
	settle(tt, drain)
	write(tt, "06-settings")

	p, f, _ := phoneScreen(t)
	p.language = "zh-Hans"
	p.phone.interfaces, _ = f.LANInterfaces(ctx)
	p.phone.interfaceID = phoneInterfaceID(p.phone.interfaces[0])
	ptt := ui.NewTester(p.view, 1366, 768)
	ptt.Frame()
	write(ptt, "07-phone-queue")
	var mu sync.Mutex
	var queued []func()
	p.post = func(fn func()) { mu.Lock(); queued = append(queued, fn); mu.Unlock() }
	p.togglePhoneItem(p.phone.items[0])
	p.togglePhoneItem(p.phone.items[1])
	flush := func() {
		for range 20 {
			time.Sleep(20 * time.Millisecond)
			mu.Lock()
			run := queued
			queued = nil
			mu.Unlock()
			for _, fn := range run {
				fn()
			}
			ptt.Frame()
		}
	}
	flush()
	write(ptt, "08-phone-selection")
	p.phone.receiverOpen = true
	ptt.Frame()
	write(ptt, "09-phone-receiver-start")
	p.phone.trusted = true
	p.startPhone()
	flush()
	write(ptt, "10-phone-receiving")
}
