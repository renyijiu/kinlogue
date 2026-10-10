// Package candidate proposes report fields from saved recognition. It copies
// text that recognition found under known labels and headings; it never
// writes text that is not in the source and never confirms anything. The rules
// follow the Swift ReportCandidateExtractor.
package candidate

import (
	"math"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"kinlogue/internal/document"
)

// Date kinds, by the label a date was printed under.
const (
	KindReport      = "report"
	KindExamination = "examination"
	KindCollection  = "collection"
	KindAdmission   = "admission"
	KindDischarge   = "discharge"
	KindOther       = "other"
)

// Date is a calendar day the report prints under a known label. It is offered
// to the user, never chosen for them.
type Date struct{ Value, Kind string }

// Candidates are verbatim proposals; an empty field means nothing was found.
// Results is the findings section the report prints under a known heading.
type Candidates struct {
	Title, Organization, Department, ReportType, Results, Conclusion string
	Dates                                                            []Date
}

// MaxShortBytes bounds every single-line candidate, as the library bounds the
// fields they fill.
const MaxShortBytes = 1024

var (
	organizationLabels = []string{"医疗机构名称", "医院名称", "机构名称", "医疗机构", "送检单位", "检查机构", "检验机构"}
	departmentLabels   = []string{"申请科室", "开单科室", "送检科室", "就诊科室", "临床科室", "执行科室", "检查科室", "检验科室", "科室"}
	reportTypeLabels   = []string{"报告类型", "报告类别", "报告种类", "检查类型", "检查类别", "检验类型"}
	titleLabels        = []string{"报告标题", "报告名称", "检查名称", "检查项目", "检验名称", "检验项目", "项目名称", "医疗名称", "标题"}
	conclusionHeadings = []string{
		"检查结论", "检查诊断", "诊断意见", "诊断结论", "报告结论", "诊断提示", "诊断印象",
		"影像学诊断", "影像诊断", "放射学诊断", "超声诊断", "内镜诊断", "病理诊断",
	}
	// A longer heading comes before one it starts with, or its tail would be
	// read as the first line of the section.
	resultHeadings = []string{
		"检查所见", "检查结果描述", "检查结果", "检查表现", "影像所见", "影像学表现", "放射学表现",
		"超声所见", "内镜所见", "病理所见", "检验结果",
	}
	// Order matters: a longer label must come before one it starts with.
	dateLabels = []struct{ label, kind string }{
		{"出报告时间", KindReport}, {"报告日期时间", KindReport}, {"报告时间", KindReport}, {"报告日期", KindReport},
		{"检查时间", KindExamination}, {"检查日期", KindExamination}, {"检验时间", KindExamination}, {"检验日期", KindExamination},
		{"采样时间", KindCollection}, {"采样日期", KindCollection}, {"采集时间", KindCollection}, {"采集日期", KindCollection},
		{"收样时间", KindCollection}, {"收样日期", KindCollection}, {"送检时间", KindCollection}, {"送检日期", KindCollection},
		{"入院时间", KindAdmission}, {"入院日期", KindAdmission}, {"出院时间", KindDischarge}, {"出院日期", KindDischarge},
		{"就诊时间", KindOther}, {"就诊日期", KindOther},
	}
	otherStops = []string{
		"备注", "审核时间", "审核日期", "报告医师", "审核医师", "审核者",
		"查看原始影像", "查看原始图像", "查看报告", "查看影像", "查看图像", "下载影像", "下载图像", "下载报告",
		"扫码", "扫一扫", "简体中文", "English",
	}
	// A line with these is a sentence about the hospital, not its name.
	organizationNoise     = []string{"请", "为准", "仅供", "参考", "如有", "咨询", "扫码", "。", "，", ",", "；", ";", "！", "!", "？", "?", "：", ":"}
	standaloneReportTypes = []string{
		"CT", "CTA", "MR", "MRI", "MRA", "X线", "DR", "CR", "超声", "B超", "PET-CT", "PET/CT",
		"检验报告", "化验单", "病理报告", "内镜报告", "心电图报告", "体检报告",
	}
	// labeledLine is a short label and its separator, as in "姓名：".
	labeledLine = regexp.MustCompile(`^[^：:]{1,8}[：:]`)
	// Recognition often reads these simplified characters as a variant form.
	variants    = strings.NewReplacer("査", "查")
	datePattern = regexp.MustCompile(`(\d{4})\s*(?:-|/|年)\s*(\d{1,2})\s*(?:-|/|月)\s*(\d{1,2})(?:日)?`)
)

const (
	headingDecorations = "|｜丨│┃¦·•●○■□▪-—_*＊ "
	labelSeparators    = " :："
	// Blocks whose baselines differ by no more than this share a line.
	rowTolerance       = 0.008
	readingTolerance   = 0.01
	dateValueMaxGap    = 0.1
	dateValueMaxBlocks = 4
	// A value printed under its label starts at the same left edge, within a
	// few lines of it.
	valueBelowMaxDrop  = 0.08
	valueBelowMaxShift = 0.03
)

type block struct {
	document.Block
	page  int // one-based across the ordered sources
	order int
	text  string // trimmed
}

// Extract reads the sources in report order. The same input always gives the
// same candidates, whatever order recognition listed the blocks in.
func Extract(sources []document.Extraction) Candidates {
	var blocks []block
	offset := 0
	for _, source := range sources {
		for _, b := range source.Blocks {
			if text := variants.Replace(strings.TrimSpace(b.Text)); text != "" {
				blocks = append(blocks, block{Block: b, page: offset + b.Page, order: len(blocks), text: text})
			}
		}
		offset += source.PageCount
	}
	sort.SliceStable(blocks, func(i, j int) bool {
		a, b := blocks[i], blocks[j]
		if a.page != b.page {
			return a.page < b.page
		}
		// Coordinates start at the bottom left, so a higher line reads first.
		if math.Abs(a.Bounds.Y-b.Bounds.Y) > readingTolerance {
			return a.Bounds.Y > b.Bounds.Y
		}
		if a.Bounds.X != b.Bounds.X {
			return a.Bounds.X < b.Bounds.X
		}
		return a.order < b.order
	})
	var c Candidates
	for _, b := range blocks {
		if c.Organization == "" {
			c.Organization = short(fieldValue(blocks, b, organizationLabels))
		}
		if c.Department == "" {
			c.Department = short(fieldValue(blocks, b, departmentLabels))
		}
		if c.ReportType == "" {
			c.ReportType = short(fieldValue(blocks, b, reportTypeLabels))
		}
		// A line that is only a modality, or the form's own name such as
		// "MRI检查报告单", says what kind of report this is.
		if c.ReportType == "" && (slices.ContainsFunc(standaloneReportTypes, func(name string) bool { return strings.EqualFold(b.text, name) }) ||
			strings.HasSuffix(b.text, "报告单") && utf8.RuneCountInString(b.text) <= 24 && !labeledLine.MatchString(b.text)) {
			c.ReportType = short(b.text)
		}
		if c.Title == "" {
			c.Title = short(fieldValue(blocks, b, titleLabels))
		}
		if c.Organization == "" && letterhead(b.text) {
			c.Organization = short(b.text)
		}
	}
	c.Results = section(blocks, resultHeadings)
	c.Conclusion = section(blocks, conclusionHeadings)
	c.Dates = dates(blocks)
	return c
}

// letterhead reports a short line that names a hospital. A sentence that
// merely mentions one, such as a notice to rely on the paper report, is not
// a name.
func letterhead(text string) bool {
	if utf8.RuneCountInString(text) > 40 || !strings.Contains(text, "医院") && !strings.Contains(text, "院区") {
		return false
	}
	return !slices.ContainsFunc(organizationNoise, func(noise string) bool { return strings.Contains(text, noise) })
}

// fieldValue reads the value a label introduces: after it in the same block,
// or, when the block holds the label alone, in the block beside or under it.
func fieldValue(blocks []block, b block, labels []string) string {
	if value := labeledValue(b.text, labels); value != "" {
		return value
	}
	bare := strings.Trim(strings.Join(strings.Fields(b.text), ""), labelSeparators)
	if !slices.Contains(labels, bare) {
		return ""
	}
	var beside, under *block
	for i := range blocks {
		other := &blocks[i]
		if other.page != b.page || other.order == b.order {
			continue
		}
		drop := b.Bounds.Y - other.Bounds.Y
		switch {
		case math.Abs(drop) <= rowTolerance && other.Bounds.X > b.Bounds.X && other.Bounds.X-(b.Bounds.X+b.Bounds.Width) <= dateValueMaxGap:
			if beside == nil || other.Bounds.X < beside.Bounds.X {
				beside = other
			}
		case drop > rowTolerance && drop <= valueBelowMaxDrop && math.Abs(other.Bounds.X-b.Bounds.X) <= valueBelowMaxShift:
			if under == nil || other.Bounds.Y > under.Bounds.Y {
				under = other
			}
		}
	}
	for _, value := range []*block{beside, under} {
		// Another label, heading or button there means this label has no value.
		if value != nil && !labeledLine.MatchString(value.text) && !isStop(strings.TrimLeft(value.text, headingDecorations)) {
			return value.text
		}
	}
	return ""
}

// short drops a single-line candidate the field could not hold. Text is never
// shortened: a cut value would no longer be what the report says.
func short(s string) string {
	if len(s) > MaxShortBytes || strings.ContainsRune(s, 0) || !utf8.ValidString(s) {
		return ""
	}
	return s
}

// labeledValue needs a separator after the label: "科室主任" is not a
// department named "主任".
func labeledValue(text string, labels []string) string {
	for _, label := range labels {
		if rest, ok := strings.CutPrefix(text, label); ok && strings.TrimLeft(rest, labelSeparators) != rest {
			if rest = strings.Trim(rest, labelSeparators); rest != "" {
				return rest
			}
		}
	}
	return ""
}

func prefixOf(text string, prefixes []string) (string, bool) {
	for _, prefix := range prefixes {
		if strings.HasPrefix(text, prefix) {
			return prefix, true
		}
	}
	return "", false
}

func isStop(heading string) bool {
	if _, ok := prefixOf(heading, resultHeadings); ok {
		return true
	}
	if _, ok := prefixOf(heading, conclusionHeadings); ok {
		return true
	}
	if _, _, ok := dateLabel(heading); ok {
		return true
	}
	_, ok := prefixOf(heading, otherStops)
	return ok
}

// section collects the lines under each of the headings until the next known
// heading. Nothing is written when the report has no such section.
func section(blocks []block, headings []string) string {
	overlays := numericOverlays(blocks)
	var lines []string
	collecting := false
	for _, b := range blocks {
		heading := strings.TrimLeft(b.text, headingDecorations)
		if found, ok := prefixOf(heading, headings); ok {
			collecting = true
			if rest := strings.Trim(heading[len(found):], labelSeparators); rest != "" && !overlays[b.order] {
				lines = append(lines, rest)
			}
		} else if collecting {
			if isStop(heading) {
				collecting = false
			} else if !overlays[b.order] {
				lines = append(lines, b.text)
			}
		}
	}
	text := strings.TrimSpace(strings.Join(lines, "\n"))
	if len(text) > document.MaxTextBytes || strings.ContainsRune(text, 0) || !utf8.ValidString(text) {
		return ""
	}
	return text
}

// numericOverlays finds low-confidence number fragments that recognition read
// out of a watermark or timestamp printed across the page: the same number at
// two places on one line, and small fragments beside two of them.
func numericOverlays(blocks []block) map[int]bool {
	digits := func(text string) (count, digits int, letters, han bool) {
		for _, r := range text {
			if unicode.IsSpace(r) {
				continue
			}
			count++
			if unicode.IsDigit(r) {
				digits++
			}
			letters = letters || unicode.IsLetter(r)
			han = han || unicode.Is(unicode.Han, r)
		}
		return
	}
	overlaps := func(a, b document.Rect) bool { return a.Y <= b.Y+b.Height && b.Y <= a.Y+a.Height }
	var numeric []block
	for _, b := range blocks {
		count, n, letters, _ := digits(b.text)
		if b.Confidence <= 0.5 && count > 0 && !letters && n >= 2 && n*2 >= count {
			numeric = append(numeric, b)
		}
	}
	result := map[int]bool{}
	var strong []block
	for _, b := range numeric {
		if slices.ContainsFunc(numeric, func(other block) bool {
			return other.order != b.order && other.page == b.page && other.text == b.text && overlaps(other.Bounds, b.Bounds)
		}) {
			strong = append(strong, b)
			result[b.order] = true
		}
	}
	for _, b := range blocks {
		count, n, _, han := digits(b.text)
		if result[b.order] || b.Confidence > 0.5 || b.Bounds.Width > 0.08 || count == 0 || count > 4 || n < 2 || n*2 < count || han {
			continue
		}
		beside := 0
		for _, other := range strong {
			if other.page == b.page && overlaps(other.Bounds, b.Bounds) {
				beside++
			}
		}
		if beside >= 2 {
			result[b.order] = true
		}
	}
	return result
}

func dateLabel(text string) (label, kind string, ok bool) {
	for _, entry := range dateLabels {
		if strings.HasPrefix(text, entry.label) {
			return entry.label, entry.kind, true
		}
	}
	return "", "", false
}

// labeledDate reads a date only from text that starts with a date label, and
// only when it names a real calendar day.
func labeledDate(text string) (Date, bool) {
	_, kind, ok := dateLabel(text)
	match := datePattern.FindStringSubmatch(text)
	if !ok || match == nil {
		return Date{}, false
	}
	year, _ := strconv.Atoi(match[1])
	month, _ := strconv.Atoi(match[2])
	day, _ := strconv.Atoi(match[3])
	// time.Date would turn 30 February into a day in March.
	t := time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.UTC)
	if t.Year() != year || int(t.Month()) != month || t.Day() != day {
		return Date{}, false
	}
	value := t.Format("2006-01-02")
	if document.ValidateDate(value) != nil {
		return Date{}, false
	}
	return Date{Value: value, Kind: kind}, true
}

func dates(blocks []block) []Date {
	var result []Date
	add := func(d Date) {
		if !slices.Contains(result, d) {
			result = append(result, d)
		}
	}
	for _, b := range blocks {
		if d, ok := labeledDate(b.text); ok {
			add(d)
			continue
		}
		if _, _, ok := dateLabel(b.text); !ok {
			continue
		}
		// The label and its value were recognized as separate blocks: join the
		// blocks that follow closely on the same line.
		var line []block
		for _, other := range blocks {
			if other.page == b.page && other.Bounds.X > b.Bounds.X && math.Abs(other.Bounds.Y-b.Bounds.Y) <= rowTolerance {
				line = append(line, other)
			}
		}
		sort.SliceStable(line, func(i, j int) bool { return line[i].Bounds.X < line[j].Bounds.X })
		joined, previous := b.text, b
		for i, next := range line {
			if i == dateValueMaxBlocks || next.Bounds.X-(previous.Bounds.X+previous.Bounds.Width) > dateValueMaxGap {
				break
			}
			joined, previous = joined+" "+next.text, next
			if d, ok := labeledDate(joined); ok {
				add(d)
				break
			}
		}
	}
	return result
}

// Location is a one-based source and page within it.
type Location struct{ Source, Page int }

// Locate reports the pages whose recognized text contains value. It finds
// where a field can be checked against the original; it does not know who
// typed the field. Every line of value must appear, or nothing is reported.
func Locate(sources []document.Extraction, value string) []Location {
	var lines []string
	for _, line := range strings.FieldsFunc(value, func(r rune) bool { return r == '\n' || r == '\r' }) {
		if line = variants.Replace(strings.TrimSpace(line)); line != "" {
			lines = append(lines, line)
		}
	}
	if len(lines) == 0 || len(lines) > 64 {
		return nil
	}
	var result []Location
	for _, line := range lines {
		// One character is found on almost any page and proves nothing.
		if utf8.RuneCountInString(line) < 2 {
			return nil
		}
		found := false
	search:
		for i, source := range sources {
			for _, b := range source.Blocks {
				if strings.Contains(variants.Replace(b.Text), line) {
					if at := (Location{i + 1, b.Page}); !slices.Contains(result, at) {
						result = append(result, at)
					}
					found = true
					break search
				}
			}
		}
		if !found {
			return nil
		}
	}
	slices.SortFunc(result, func(a, b Location) int {
		if a.Source != b.Source {
			return a.Source - b.Source
		}
		return a.Page - b.Page
	})
	return result
}
