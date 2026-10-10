package candidate

import (
	"reflect"
	"strings"
	"testing"

	"kinlogue/internal/document"
)

type option func(*document.Block)

func at(x, width float64) option {
	return func(b *document.Block) { b.Bounds.X, b.Bounds.Width = x, width }
}
func sized(height, confidence float64) option {
	return func(b *document.Block) { b.Bounds.Height, b.Confidence = height, confidence }
}

func line(text string, page int, y float64, options ...option) document.Block {
	b := document.Block{Page: page, Text: text, Bounds: document.Rect{X: 0.05, Y: y, Width: 0.8, Height: 0.04}, Confidence: 0.99, Method: "vision"}
	for _, option := range options {
		option(&b)
	}
	return b
}

func extract(pages int, blocks ...document.Block) Candidates {
	return Extract([]document.Extraction{{Kind: "pdf", PageCount: pages, Engine: "synthetic", Blocks: blocks}})
}

func TestKeepsExplicitSourceText(t *testing.T) {
	c := extract(2,
		line("合成市测试医院", 1, 0.90),
		line("姓名：测试成员", 1, 0.84),
		line("检查日期：2026-01-02", 1, 0.78),
		line("报告名称：合成随访报告", 1, 0.72),
		line("检查结论", 1, 0.60),
		line("合成观察文字。", 1, 0.54),
		line("备注", 1, 0.48),
		line("检验项目甲 12 ↑", 2, 0.80),
	)
	want := Candidates{Title: "合成随访报告", Organization: "合成市测试医院", Conclusion: "合成观察文字。", Dates: []Date{{"2026-01-02", KindExamination}}}
	if !reflect.DeepEqual(c, want) {
		t.Fatalf("candidates = %+v", c)
	}
}

func TestStopsAConclusionBeforeViewerActions(t *testing.T) {
	c := extract(1,
		line("CT", 1, 0.9),
		line("检查结论", 1, 0.7),
		line("合成结论正文。", 1, 0.6),
		line("查看原始影像", 1, 0.4),
		line("查看报告", 1, 0.3),
	)
	if c.ReportType != "CT" || c.Conclusion != "合成结论正文。" {
		t.Fatalf("candidates = %+v", c)
	}
}

func TestNothingIsWrittenWithoutASource(t *testing.T) {
	c := extract(1,
		line("项目甲 99 参考值 1~10", 1, 0.8),
		line("合成正文，没有任何标签或标题。", 1, 0.7),
		line("2026-01-02", 1, 0.6),
	)
	if !reflect.DeepEqual(c, Candidates{}) {
		t.Fatalf("invented candidates: %+v", c)
	}
}

func TestStableAcrossInputOrdering(t *testing.T) {
	top := line("报告日期：2026年02月03日", 1, 0.8)
	bottom := line("检查结论：合成结论", 1, 0.4)
	first, second := extract(1, bottom, top), extract(1, top, bottom)
	if !reflect.DeepEqual(first, second) || first.Conclusion != "合成结论" || !reflect.DeepEqual(first.Dates, []Date{{"2026-02-03", KindReport}}) {
		t.Fatalf("%+v / %+v", first, second)
	}
}

func TestAcceptsDecoratedAndCommonConclusionHeadings(t *testing.T) {
	headings := []string{"丨检查结论", "*检查结论", "＊检查结论"}
	for _, heading := range conclusionHeadings {
		headings = append(headings, heading)
	}
	for _, heading := range headings {
		c := extract(1,
			line(heading, 1, 0.7),
			line("合成结论正文。", 1, 0.6),
			line("审核时间：2026-08-10", 1, 0.4),
		)
		if c.Conclusion != "合成结论正文。" || len(c.Dates) != 0 {
			t.Fatalf("%s: %+v", heading, c)
		}
	}
}

func TestRecognizesCommonMetadataLabels(t *testing.T) {
	c := extract(1,
		line("患者姓名：合成成员", 1, 0.95),
		line("机构名称：合成健康中心", 1, 0.90),
		line("开单科室：合成门诊", 1, 0.85),
		line("报告类别：影像报告", 1, 0.80),
		line("检查名称：合成增强检查", 1, 0.75),
	)
	want := Candidates{Title: "合成增强检查", Organization: "合成健康中心", Department: "合成门诊", ReportType: "影像报告"}
	if !reflect.DeepEqual(c, want) {
		t.Fatalf("candidates = %+v", c)
	}
}

func TestRecognizesDateLabelsAndKinds(t *testing.T) {
	c := extract(1,
		line("出报告时间：2026-01-01 10:30", 1, 0.95),
		line("检查时间：2026-01-02 09:15", 1, 0.90),
		line("检验日期：2026/1/3", 1, 0.85),
		line("收样时间：2026-01-04 08:00", 1, 0.80),
		line("送检日期：2026-01-05", 1, 0.75),
		line("入院时间：2026-01-06 12:00", 1, 0.70),
		line("出院时间：2026-01-07 12:00", 1, 0.65),
		line("就诊日期：2026年1月8日", 1, 0.60),
		line("检查日期：2026-01-02", 1, 0.55), // the same day and kind again
	)
	want := []Date{
		{"2026-01-01", KindReport}, {"2026-01-02", KindExamination}, {"2026-01-03", KindExamination}, {"2026-01-04", KindCollection},
		{"2026-01-05", KindCollection}, {"2026-01-06", KindAdmission}, {"2026-01-07", KindDischarge}, {"2026-01-08", KindOther},
	}
	if !reflect.DeepEqual(c.Dates, want) {
		t.Fatalf("dates = %+v", c.Dates)
	}
}

func TestRejectsImpossibleCalendarDatesAndKeepsALeapDay(t *testing.T) {
	for _, value := range []string{"2025-02-29", "2026-02-30", "2026-00-10", "2026-13-10"} {
		if c := extract(1, line("检查日期："+value, 1, 0.8)); len(c.Dates) != 0 {
			t.Fatalf("%s accepted as %+v", value, c.Dates)
		}
	}
	if c := extract(1, line("报告日期：2024-02-29", 1, 0.8)); !reflect.DeepEqual(c.Dates, []Date{{"2024-02-29", KindReport}}) {
		t.Fatalf("leap day = %+v", c.Dates)
	}
}

func TestSeparatesFindingsFromDiagnosisAndStopsBeforeReportTime(t *testing.T) {
	c := extract(1,
		line("*检查所见", 1, 0.80),
		line("合成检查所见正文。", 1, 0.75),
		line("＊检查结论", 1, 0.60),
		line("合成检查结论正文。", 1, 0.55),
		line("合成检查结论续行。", 1, 0.50),
		line("报告时间：2026-07-22 15:30:00", 1, 0.40),
		line("审核者：合成审核者", 1, 0.35),
	)
	if c.Conclusion != "合成检查结论正文。\n合成检查结论续行。" || !reflect.DeepEqual(c.Dates, []Date{{"2026-07-22", KindReport}}) {
		t.Fatalf("candidates = %+v", c)
	}
}

func TestJoinsASameLineSplitDateLabelAndValue(t *testing.T) {
	c := extract(1,
		line("采样日期：", 1, 0.8, at(0.05, 0.18)),
		line("2026-07-18", 1, 0.801, at(0.25, 0.2)),
		line("无关同行字段", 1, 0.801, at(0.55, 0.2)),
	)
	if !reflect.DeepEqual(c.Dates, []Date{{"2026-07-18", KindCollection}}) {
		t.Fatalf("dates = %+v", c.Dates)
	}
	// A value far to the right, or on another line, belongs to something else.
	for _, value := range []document.Block{line("2026-07-18", 1, 0.801, at(0.45, 0.2)), line("2026-07-18", 1, 0.75, at(0.25, 0.2))} {
		if c := extract(1, line("采样日期：", 1, 0.8, at(0.05, 0.18)), value); len(c.Dates) != 0 {
			t.Fatalf("unrelated value joined: %+v", c.Dates)
		}
	}
}

func TestSkipsTimestampWatermarksInsideAConclusion(t *testing.T) {
	c := extract(1,
		line("丨检查结论", 1, 0.8),
		line("08:28", 1, 0.466, at(0.238, 0.122), sized(0.026, 0.5)),
		line("8A8", 1, 0.464, at(0.643, 0.044), sized(0.010, 0.3)),
		line("08:28", 1, 0.468, at(0.694, 0.125), sized(0.025, 0.3)),
		line("1. 合成结论正文。", 1, 0.436, sized(0.04, 0.5)),
		line("合成结论续行。", 1, 0.409),
		line("查看原始图像", 1, 0.3),
	)
	if c.Conclusion != "1. 合成结论正文。\n合成结论续行。" {
		t.Fatalf("conclusion = %q", c.Conclusion)
	}
	// One low-confidence number on its own may be the conclusion itself.
	c = extract(1, line("丨检查结论", 1, 0.8), line("12.0", 1, 0.7, sized(0.04, 0.4)), line("查看原始图像", 1, 0.3))
	if c.Conclusion != "12.0" {
		t.Fatalf("isolated number dropped: %q", c.Conclusion)
	}
}

func TestSourcesAreReadInReportOrder(t *testing.T) {
	first := document.Extraction{Kind: "pdf", PageCount: 2, Engine: "synthetic", Blocks: []document.Block{
		line("检查结论：合成第一原件第二页结论", 2, 0.8),
		line("审核者：合成审核者", 2, 0.7),
		line("医院名称：合成第一原件医院", 1, 0.9),
	}}
	second := document.Extraction{Kind: "png", PageCount: 1, Engine: "synthetic", Blocks: []document.Block{
		line("医院名称：合成第二原件医院", 1, 0.9),
		line("检查结论：合成第二原件结论", 1, 0.8),
		line("报告医师：合成医师", 1, 0.7),
	}}
	// A section runs on to the next page until a known heading ends it, as in
	// the Swift rules; both conclusions here end at a signature line.
	// Page one of the second original comes after both pages of the first.
	c := Extract([]document.Extraction{first, second})
	if c.Organization != "合成第一原件医院" || c.Conclusion != "合成第一原件第二页结论\n合成第二原件结论" {
		t.Fatalf("candidates = %+v", c)
	}
	c = Extract([]document.Extraction{second, first})
	if c.Organization != "合成第二原件医院" || c.Conclusion != "合成第二原件结论\n合成第一原件第二页结论" {
		t.Fatalf("reordered candidates = %+v", c)
	}
}

func TestOversizedShortCandidateIsDroppedNotCut(t *testing.T) {
	long := strings.Repeat("长", MaxShortBytes/3+1)
	c := extract(1, line("医院名称："+long, 1, 0.9), line("科室：合成科室\x00", 1, 0.8), line("报告类型：合成类型", 1, 0.7))
	if c.Organization != "" || c.Department != "" || c.ReportType != "合成类型" {
		t.Fatalf("candidates = %+v", c)
	}
}

func TestLocateFindsEveryLineOrNothing(t *testing.T) {
	sources := []document.Extraction{
		{Kind: "pdf", PageCount: 2, Engine: "synthetic", Blocks: []document.Block{line("医院名称：合成健康中心", 1, 0.9), line("合成结论续行。", 2, 0.8)}},
		{Kind: "png", PageCount: 1, Engine: "synthetic", Blocks: []document.Block{line("检查结论：合成结论正文。", 1, 0.8)}},
	}
	for _, test := range []struct {
		value string
		want  []Location
	}{
		{"合成健康中心", []Location{{1, 1}}},
		{" 合成结论正文。\n\n合成结论续行。 ", []Location{{1, 2}, {2, 1}}},
		{"合成结论正文。\n用户补充的一行", nil},
		{"人工录入的医院", nil},
		{"合", nil},
		{"", nil},
		{strings.Repeat("合成结论续行。\n", 65), nil},
	} {
		if got, _ := Locate(sources, test.value); !reflect.DeepEqual(got, test.want) {
			t.Fatalf("Locate(%q) = %+v, want %+v", test.value, got, test.want)
		}
	}
}

// The two layouts below copy the geometry of real recognitions, with every
// text replaced by synthetic wording.

// A phone screenshot of a report page: the exam name sits under its label,
// a notice mentions the hospital, and viewer buttons follow the findings.
func TestPhoneScreenshotLayout(t *testing.T) {
	c := extract(1,
		line("18:27", 1, 0.949, at(0.123, 0.120), sized(0.025, 1)),
		line("：！今85", 1, 0.948, at(0.700, 0.221), sized(0.026, 0.3)),
		line("检查报告", 1, 0.897, at(0.407, 0.180), sized(0.023, 0.5)),
		line("●••", 1, 0.904, at(0.792, 0.057), sized(0.013, 0.3)),
		line("医疗名称", 1, 0.839, at(0.041, 0.152), sized(0.021, 0.5)),
		line("合成部位CTA", 1, 0.799, at(0.038, 0.259), sized(0.027, 1)),
		line("姓名：合成成员", 1, 0.732, at(0.038, 0.243), sized(0.021, 0.5)),
		line("送检医生：合成医生", 1, 0.732, at(0.498, 0.303), sized(0.020, 0.5)),
		line("检查日期：2026-07-31 08:46:43", 1, 0.622, at(0.041, 0.562), sized(0.020, 1)),
		line("具体报告信息请以医院纸质报告为准。", 1, 0.576, at(0.041, 0.496), sized(0.018, 1)),
		line("检查结果", 1, 0.491, at(0.041, 0.170), sized(0.019, 0.5)),
		line("合成检查结果一句。", 1, 0.450, at(0.040, 0.474), sized(0.025, 1)),
		line("检查结果描述", 1, 0.366, at(0.041, 0.256), sized(0.021, 0.5)),
		line("合成描述第一行，", 1, 0.325, at(0.041, 0.896), sized(0.023, 0.5)),
		line("合成描述第二行。", 1, 0.299, at(0.041, 0.884), sized(0.028, 1)),
		line("查看影像", 1, 0.107, at(0.413, 0.171), sized(0.021, 0.5)),
		line("下载影像", 1, 0.036, at(0.413, 0.170), sized(0.022, 1)),
	)
	want := Candidates{
		Title:   "合成部位CTA",
		Results: "合成检查结果一句。\n合成描述第一行，\n合成描述第二行。",
		Dates:   []Date{{"2026-07-31", KindExamination}},
	}
	if !reflect.DeepEqual(c, want) {
		t.Fatalf("candidates = %+v", c)
	}
}

// A photographed paper report: a letterhead, the form's name, fields in
// columns, and a findings heading that recognition read with a variant
// character.
func TestPaperReportLayout(t *testing.T) {
	c := extract(1,
		line("合成市第一附属医院", 1, 0.906, at(0.282, 0.375), sized(0.058, 1)),
		line("MRI检査报告单", 1, 0.822, at(0.360, 0.206), sized(0.060, 0.5)),
		line("检查号：SYNTHETIC0001", 1, 0.739, at(0.579, 0.254), sized(0.045, 0.5)),
		line("扫码查看报告及影像", 1, 0.632, at(0.078, 0.177), sized(0.037, 1)),
		line("姓名：合成成员", 1, 0.551, at(0.071, 0.115), sized(0.040, 0.5)),
		line("登记号：", 1, 0.551, at(0.641, 0.078), sized(0.039, 0.5)),
		line("0000000001", 1, 0.554, at(0.751, 0.108), sized(0.032, 1)),
		line("8/6/2026 3:36:47", 1, 0.506, at(0.724, 0.124), sized(0.034, 1)),
		line("科室：合成内科门诊", 1, 0.473, at(0.070, 0.249), sized(0.063, 0.3)),
		line("检查日期：PM", 1, 0.477, at(0.637, 0.125), sized(0.053, 0.3)),
		line("合成成像，合成平扫", 1, 0.337, at(0.276, 0.353), sized(0.057, 0.5)),
		line("检査所见：", 1, 0.252, at(0.073, 0.112), sized(0.049, 0.5)),
		line("合成所见第一行，", 1, 0.179, at(0.133, 0.696), sized(0.052, 0.5)),
		line("合成所见第二行。", 1, 0.127, at(0.096, 0.575), sized(0.053, 1)),
	)
	want := Candidates{
		Organization: "合成市第一附属医院",
		Department:   "合成内科门诊",
		ReportType:   "MRI检查报告单",
		Results:      "合成所见第一行，\n合成所见第二行。",
	}
	if !reflect.DeepEqual(c, want) {
		t.Fatalf("candidates = %+v", c)
	}
}

func TestASentenceMentioningAHospitalIsNotItsName(t *testing.T) {
	for _, text := range []string{
		"具体报告信息请以医院纸质报告为准。", "本报告仅供本院医师参考", "如有疑问请到医院咨询", "医院地址：合成路 1 号", "扫码关注医院公众号",
		strings.Repeat("合成", 20) + "医院",
	} {
		if c := extract(1, line(text, 1, 0.9)); c.Organization != "" {
			t.Fatalf("%q read as a hospital name", text)
		}
	}
	for _, text := range []string{"合成市测试医院", "合成大学附属医院东院区", "合成市测试医院检验报告单"} {
		if c := extract(1, line(text, 1, 0.9)); c.Organization != text {
			t.Fatalf("%q not read as a hospital name: %+v", text, c)
		}
	}
}

func TestALabelAloneTakesTheValueBesideOrUnderIt(t *testing.T) {
	label := func(text string) document.Block { return line(text, 1, 0.8, at(0.05, 0.15)) }
	for name, test := range map[string]struct {
		blocks []document.Block
		want   string
	}{
		"under":            {[]document.Block{label("检查名称"), line("合成检查", 1, 0.76, at(0.05, 0.3))}, "合成检查"},
		"under, spaced":    {[]document.Block{label("检 查 名 称："), line("合成检查", 1, 0.76, at(0.06, 0.3))}, "合成检查"},
		"beside":           {[]document.Block{label("检查名称："), line("合成检查", 1, 0.801, at(0.25, 0.3))}, "合成检查"},
		"beside wins":      {[]document.Block{label("检查名称"), line("合成旁边", 1, 0.8, at(0.25, 0.3)), line("合成下方", 1, 0.76, at(0.05, 0.3))}, "合成旁边"},
		"nearest under":    {[]document.Block{label("检查名称"), line("合成较远", 1, 0.73, at(0.05, 0.3)), line("合成较近", 1, 0.77, at(0.05, 0.3))}, "合成较近"},
		"too far under":    {[]document.Block{label("检查名称"), line("合成检查", 1, 0.6, at(0.05, 0.3))}, ""},
		"another column":   {[]document.Block{label("检查名称"), line("合成检查", 1, 0.76, at(0.5, 0.3))}, ""},
		"another page":     {[]document.Block{label("检查名称"), line("合成检查", 2, 0.76, at(0.05, 0.3))}, ""},
		"another label":    {[]document.Block{label("检查名称"), line("姓名：合成成员", 1, 0.76, at(0.05, 0.3))}, ""},
		"a heading":        {[]document.Block{label("检查名称"), line("检查所见", 1, 0.76, at(0.05, 0.3))}, ""},
		"not only a label": {[]document.Block{label("检查名称及说明"), line("合成检查", 1, 0.76, at(0.05, 0.3))}, ""},
	} {
		if c := extract(2, test.blocks...); c.Title != test.want {
			t.Fatalf("%s: title = %q, want %q", name, c.Title, test.want)
		}
	}
}

func TestFindingsSectionsStopAtConclusionsAndButtons(t *testing.T) {
	c := extract(1,
		line("检查所见：合成所见同行。", 1, 0.9),
		line("合成所见续行。", 1, 0.85),
		line("诊断意见", 1, 0.8),
		line("合成诊断。", 1, 0.75),
		line("检查结果描述：合成描述。", 1, 0.7),
		line("下载报告", 1, 0.65),
		line("合成按钮之后的文字", 1, 0.6),
	)
	if c.Results != "合成所见同行。\n合成所见续行。\n合成描述。" || c.Conclusion != "合成诊断。" {
		t.Fatalf("candidates = %+v", c)
	}
}

func TestVariantCharactersMatchAndLocate(t *testing.T) {
	sources := []document.Extraction{{Kind: "png", PageCount: 1, Engine: "synthetic", Blocks: []document.Block{
		line("检査结论", 1, 0.8), line("合成复査结论。", 1, 0.7),
	}}}
	c := Extract(sources)
	if c.Conclusion != "合成复查结论。" {
		t.Fatalf("conclusion = %q", c.Conclusion)
	}
	// The corrected proposal is still found where recognition read the variant.
	if got, _ := Locate(sources, c.Conclusion); !reflect.DeepEqual(got, []Location{{1, 1}}) {
		t.Fatalf("Locate = %+v", got)
	}
}

func TestALabelNeedsASeparatorBeforeItsValue(t *testing.T) {
	c := extract(1, line("科室主任：合成主任", 1, 0.9), line("报告类型说明", 1, 0.8), line("标题栏", 1, 0.7))
	if !reflect.DeepEqual(c, Candidates{}) {
		t.Fatalf("a longer word was split at a label: %+v", c)
	}
	c = extract(1, line("科室 合成科室", 1, 0.9), line("报告类型:合成类型", 1, 0.8))
	if c.Department != "合成科室" || c.ReportType != "合成类型" {
		t.Fatalf("candidates = %+v", c)
	}
}

func TestLocateReportsTheLeastCertainBlock(t *testing.T) {
	sources := []document.Extraction{{Kind: "png", PageCount: 1, Engine: "synthetic", Blocks: []document.Block{
		line("合成清晰一行", 1, 0.8, sized(0.04, 1)), line("合成模糊一行", 1, 0.7, sized(0.04, 0.3)),
	}}}
	if _, confidence := Locate(sources, "合成清晰一行"); confidence != 1 {
		t.Fatalf("confidence = %v", confidence)
	}
	if _, confidence := Locate(sources, "合成清晰一行\n合成模糊一行"); confidence != 0.3 {
		t.Fatalf("confidence = %v", confidence)
	}
}
