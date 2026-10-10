package desktop

import (
	"cmp"
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"
	"kinlogue/internal/candidate"
	"kinlogue/internal/document"
	"kinlogue/internal/library"
)

// Warm Sanctuary tokens shared with the Swift app (docs/design-system.md).
var (
	tokenChip      = ui.Hex("#E9E1DC")
	tokenContainer = ui.Hex("#F5ECE7")
	tokenTimeline  = ui.RGBA(30, 98, 84, 0.25)
	tokenHover     = ui.RGBA(30, 98, 84, 0.08)
	tokenDanger    = ui.Hex("#C0392B")
)

// Column widths follow the Swift NavigationSplitView ideals, scaled to the
// preview's minimum window so the detail column keeps room for originals.
const (
	sidebarWidth  = 232
	timelineWidth = 352
)

func warmTheme() *ui.Theme {
	t := ui.LightTheme()
	t.Background, t.Surface = ui.Hex("#FFF8F5"), ui.Hex("#FFFFFF")
	t.SurfaceHover, t.SurfacePressed = ui.Hex("#FBF2ED"), tokenContainer
	t.Text, t.TextMuted, t.Border = ui.Hex("#1E1B18"), ui.Hex("#3F4946"), ui.Hex("#BFC9C4")
	t.Accent, t.AccentHover, t.AccentPressed = ui.Hex("#1E6254"), ui.Hex("#15453B"), ui.Hex("#0F322B")
	t.Focus, t.Selection = ui.Hex("#1E6254"), ui.RGBA(30, 98, 84, 0.18)
	t.FontSize, t.Radius = 14, 8
	return t
}

func (s *screen) view(c *ui.Context) {
	theme := warmTheme()
	if c.Preferences().HighContrast {
		theme.Border = theme.TextMuted
	}
	if scale := c.Preferences().TextScale; scale > 1 {
		theme.FontSize *= scale
	}
	c.SetTheme(theme)
	s.composing = false
	blocked := s.modalOpen() || s.reviewOpen() || s.phone.receiverOpen
	ui.Row(c).Fill().Gap(0).Background(c.Theme().Background).Children(func() {
		if !s.recoveryOnly && !s.restartOnly && !s.activating {
			ui.Column(c).Width(sidebarWidth).Shrink(0).FillHeight().Background(c.Theme().Background).Disabled(blocked || s.backup.step != "").Children(func() { s.sidebar(c) })
			divider(c, true)
		}
		ui.Column(c).Grow(1).MinWidth(0).FillHeight().Children(func() {
			ui.Column(c).Grow(1).MinHeight(0).Disabled(blocked).Children(func() {
				switch {
				case s.backupPage || s.recoveryOnly || s.restartOnly:
					ui.Column(c).Fill().Padding(24).Children(func() { s.backupView(c) })
				case s.phonePage:
					s.toolbar(c, s.t("phone_uploads"))
					ui.Row(c).Grow(1).MinHeight(0).FillWidth().Children(func() {
						ui.Column(c).Width(timelineWidth).Shrink(0).FillHeight().Children(func() { s.phoneQueue(c) })
						divider(c, true)
						ui.Column(c).Grow(1).MinWidth(0).FillHeight().Children(func() { s.phoneSelection(c) })
					})
				default:
					title := s.t("family_timeline")
					if name := s.memberLabel(s.memberID); name != "" {
						title = name
					}
					s.toolbar(c, title)
					ui.Row(c).Grow(1).MinHeight(0).FillWidth().Children(func() {
						ui.Column(c).Width(timelineWidth).Shrink(0).FillHeight().Children(func() { s.list(c) })
						divider(c, true)
						ui.Column(c).Grow(1).MinWidth(0).FillHeight().Children(func() { s.detail(c) })
					})
				}
			})
			if s.message != "" && !successMessage(s.message) && !(s.phonePage && phoneInlineMessage(s.message)) {
				ui.Row(c).FillWidth().Padding(8, 18).Gap(8).AlignItems(ui.Center).Children(func() {
					color := c.Theme().TextMuted
					if errorMessage(s.message) {
						color = tokenDanger
						icon(c, iconWarning, 15, color)
					}
					ui.Text(c, s.t(s.message)).TextColor(color).Grow(1).MinWidth(0).MaxLines(2)
				})
			}
			if s.busy != "" {
				ui.Column(c).FillWidth().Padding(8, 18).Gap(6).Children(func() {
					ui.Row(c).Gap(10).AlignItems(ui.Center).Children(func() {
						key := s.busy
						if s.cancelling {
							key = "cancelling"
						}
						text := s.t(key)
						if s.progressTotal > 1 && !s.cancelling {
							text += s.t("progress_count", s.progressIndex, s.progressTotal)
						}
						// The rest of the window is disabled while a job runs, so a
						// moving indicator shows that the app has not stopped.
						ui.Spinner(c).Label(text)
						ui.Text(c, text).TextColor(c.Theme().Accent)
						if s.cancellable && ui.Button(c, s.t("cancel_task")).Disabled(s.cancelling).Clicked() {
							s.cancelling = true
							s.jobCancel()
						}
					})
					if s.slow && !s.cancelling && (s.busy == "importing" || s.busy == "processing" || s.busy == "phone_processing") {
						ui.Text(c, s.t("slow_recognition")).FontSize(12).TextColor(c.Theme().TextMuted).MaxLines(3)
					}
				})
			}
		})
	})
	// Outcomes of what the user just did show briefly as toasts, as macOS
	// apps do, instead of a line at the bottom that is easy to miss.
	if successMessage(s.message) {
		c.AddToast(ui.Toast{ID: s.message, Title: s.t(s.message), Type: "success"})
		s.message = ""
	}
	if !s.modalOpen() && !s.reviewOpen() && !s.phone.receiverOpen && c.Shortcut(ui.Cmd, ui.KeyF) {
		s.requestSearchFocus()
	}
	s.reviewSheet(c)
	s.receiverSheet(c)
	s.dialogs(c)
	s.phoneDialogs(c)
	if c.Shortcut(ui.Cmd, ui.KeyS) {
		s.queueSaveShortcut()
	}
	if s.consumeRequests() {
		// Requests can open a dirty guard after the dialogs were built.
		c.Invalidate()
	}
}

func divider(c *ui.Context, vertical bool) *ui.Element {
	if vertical {
		return ui.Box(c).Width(1).FillHeight().Shrink(0).Background(c.Theme().Border)
	}
	return ui.Box(c).Height(1).FillWidth().Shrink(0).Background(c.Theme().Border)
}

// toolbar stands in for the Swift window toolbar: the navigation title on the
// left and the global import and phone actions on the right.
func (s *screen) toolbar(c *ui.Context, title string) {
	ui.Row(c).FillWidth().Height(48).Shrink(0).Padding(0, 16, 0, 20).Gap(8).AlignItems(ui.Center).Children(func() {
		ui.Text(c, title).Bold().Grow(1).MinWidth(0).SingleLine().TextColor(c.Theme().TextMuted)
		if s.toolbarButton(c, iconImport, s.t("import_report"), s.t("import_report")) {
			s.queueNavigation(s.chooseFiles)
		}
		if s.phoneBackend != nil {
			label, glyph, help := s.t("phone_uploads"), iconPhone, s.t("phone_receive_title")
			if s.phone.status.Active {
				label, glyph, help = s.t("phone_receiving_toolbar"), iconWaves, s.t("phone_view_status")
			}
			if s.toolbarButton(c, glyph, label, help) {
				s.openReceiver()
			}
		}
	})
	divider(c, false)
}

func (s *screen) toolbarButton(c *ui.Context, glyph *ui.SVG, label, help string) bool {
	b := ui.ButtonBase(c).Label(label).Tooltip(help).Padding(6, 10).Radius(7).Gap(6).AlignItems(ui.Center).TextColor(c.Theme().TextMuted).Disabled(s.busy != "")
	if b.Hovered() {
		b.Background(tokenHover)
	}
	b.Children(func() {
		icon(c, glyph, 16, c.Theme().TextMuted)
		ui.Text(c, label).FontSize(13)
	})
	return b.Clicked()
}

func sectionHeader(c *ui.Context, text string) {
	ui.Text(c, text).Padding(14, 12, 4, 12).FontSize(12).Bold().TextColor(c.Theme().TextMuted)
}

func (s *screen) sidebar(c *ui.Context) {
	ui.Scroll(c).Grow(1).MinHeight(60).Children(func() {
		ui.Column(c).FillWidth().Padding(4, 10, 12, 10).Gap(2).Children(func() {
			sectionHeader(c, s.t("browse"))
			records := !s.backupPage && !s.phonePage
			if s.sidebarRow(c, iconClock, s.t("all_records"), "", records && s.memberID == allMembers) {
				s.selectMember(allMembers)
			}
			if s.phoneBackend != nil {
				label, glyph := s.t("phone_uploads"), iconTray
				if s.phone.status.Active {
					label, glyph = s.t("phone_uploads_receiving"), iconWaves
				}
				count := ""
				if n := s.phoneCount(); n > 0 {
					count = fmt.Sprint(n)
				}
				if s.sidebarRow(c, glyph, label, count, s.phonePage) {
					s.queueNavigation(s.showPhone)
				}
			}
			sectionHeader(c, s.t("members"))
			for _, member := range s.members {
				ui.Column(c).Key(member.ID).FillWidth().Children(func() {
					if s.sidebarRow(c, iconPerson, member.Name, "", records && member.ID == s.memberID) {
						s.selectMember(member.ID)
					}
				})
			}
			if s.sidebarRow(c, iconPersonPlus, s.t("add_member"), "", false) {
				s.queueNavigation(func() { s.newMember = true })
			}
			var waiting, background []library.Report
			for _, draft := range s.drafts {
				if draft.Status == "review" {
					waiting = append(waiting, draft)
				} else {
					background = append(background, draft)
				}
			}
			if len(waiting) > 0 {
				sectionHeader(c, s.t("awaiting_review_count", len(waiting)))
				for _, draft := range waiting {
					ui.Column(c).Key(draft.ID).FillWidth().Children(func() {
						// Name each draft so several waiting reports are distinguishable.
						name := strings.TrimSpace(draft.Review.Title)
						if name == "" {
							name = draft.FileName
						}
						if s.sidebarAction(c, iconDocClock, s.t("draft_awaiting"), name, s.t("open_draft_hint")) {
							s.open(draft.ID)
						}
					})
				}
			}
			if len(background) > 0 {
				sectionHeader(c, s.t("import_status"))
				for _, draft := range background {
					ui.Row(c).Key(draft.ID).FillWidth().Gap(4).AlignItems(ui.Center).Children(func() {
						if draft.Status == "processing" {
							ui.Row(c).Grow(1).MinHeight(36).Padding(0, 12).Gap(10).AlignItems(ui.Center).Children(func() {
								icon(c, iconHourglass, 16, c.Theme().TextMuted)
								ui.Text(c, s.t("draft_recognizing")).TextColor(c.Theme().TextMuted).SingleLine()
							})
							return
						}
						b := ui.ButtonBase(c).Label(s.t("draft_failed_retry")).Grow(1).MinWidth(0).MinHeight(36).Padding(0, 12).Radius(8).Gap(10).AlignItems(ui.Center).TextColor(c.Theme().TextMuted).Disabled(s.busy != "")
						if b.Hovered() {
							b.Background(tokenHover)
						}
						b.Children(func() {
							icon(c, iconRetry, 16, c.Theme().TextMuted)
							ui.Text(c, s.t("draft_failed_retry")).Grow(1).MinWidth(0).MaxLines(2)
						})
						if b.Clicked() {
							s.retryDraft(draft.ID)
						}
						t := ui.ButtonBase(c).Label(s.t("discard_failed_import")).Padding(6).Radius(6).TextColor(tokenDanger).Disabled(s.busy != "")
						t.Children(func() { icon(c, iconTrash, 16, tokenDanger) })
						if t.Clicked() {
							s.promptDelete(draft.ID)
						}
					})
				}
			}
		})
	})
	divider(c, false)
	ui.Column(c).FillWidth().Padding(10).Children(func() {
		if s.sidebarRow(c, iconGear, s.t("settings"), "", s.backupPage) {
			s.queueNavigation(s.showBackup)
		}
	})
}

// sidebarRow is a navigation row: Container background and Primary text when
// selected, Primary 8% on hover, at least 44pt high (design-system rule 8).
func (s *screen) sidebarRow(c *ui.Context, glyph *ui.SVG, label, trailing string, selected bool) bool {
	b := ui.ButtonBase(c).Label(label).Selected(selected).FillWidth().MinHeight(44).Padding(0, 12).Radius(8).Gap(10).AlignItems(ui.Center).Disabled(s.busy != "")
	color := c.Theme().TextMuted
	switch {
	case selected:
		color = c.Theme().Accent
		b.Background(tokenContainer)
	case b.Hovered():
		b.Background(tokenHover)
	}
	b.TextColor(color)
	b.Children(func() {
		icon(c, glyph, 17, color)
		ui.Text(c, label).Grow(1).MinWidth(0).SingleLine()
		if trailing != "" {
			ui.Text(c, trailing).FontSize(12).TextColor(color)
		}
	})
	return b.Clicked()
}

// sidebarAction is a command row (draft to review), not a navigation choice.
func (s *screen) sidebarAction(c *ui.Context, glyph *ui.SVG, label, detail, hint string) bool {
	accessible := label
	if detail != "" {
		accessible = s.t("labeled_item", label, detail)
	}
	b := ui.ButtonBase(c).Label(accessible).Tooltip(hint).FillWidth().MinHeight(44).Padding(4, 12).Radius(8).Gap(10).AlignItems(ui.Center).TextColor(c.Theme().TextMuted).Disabled(s.busy != "")
	if b.Hovered() {
		b.Background(tokenHover)
	}
	b.Children(func() {
		icon(c, glyph, 17, c.Theme().TextMuted)
		ui.Column(c).Grow(1).MinWidth(0).Gap(1).Children(func() {
			ui.Text(c, label).SingleLine()
			if detail != "" {
				ui.Text(c, detail).FontSize(11).SingleLine().TextColor(c.Theme().TextMuted)
			}
		})
		icon(c, iconChevron, 12, c.Theme().Border)
	})
	return b.Clicked()
}

func (s *screen) memberLabel(id string) string {
	for _, member := range s.members {
		if member.ID == id {
			return member.Name
		}
	}
	return ""
}

// formatDate renders a stored YYYY-MM-DD date like the Swift long style.
func (s *screen) formatDate(date string) string {
	t, err := time.Parse("2006-01-02", date)
	if date == "" || err != nil {
		return s.t("unknown_date")
	}
	if s.lang() == "en" {
		return t.Format("January 2, 2006")
	}
	return fmt.Sprintf("%d年%d月%d日", t.Year(), int(t.Month()), t.Day())
}

func (s *screen) list(c *ui.Context) {
	ui.Column(c).Fill().Children(func() {
		s.searchField(c)
		divider(c, false)
		records := s.records
		if len(records) == 0 {
			searching := strings.TrimSpace(s.query) != ""
			ui.Column(c).Grow(1).FillWidth().Center().Padding(24).Gap(10).Children(func() {
				icon(c, iconSearch, 34, c.Theme().TextMuted)
				title, detail := "empty_timeline", "empty_timeline_detail"
				if searching {
					title, detail = "empty_search", "empty_search_detail"
				}
				ui.Text(c, s.t(title)).FontSize(17).Bold()
				ui.Text(c, s.t(detail)).TextColor(c.Theme().TextMuted)
				if !searching && ui.PrimaryButton(c, s.t("import_first")).Disabled(s.busy != "").Clicked() {
					s.queueNavigation(s.chooseFiles)
				}
			})
			return
		}
		if scope := [2]string{s.memberID, s.query}; scope != s.reportListScope {
			s.reportList, s.reportListScope = ui.ListState{}, scope
			s.selectedReport = -1
		}
		s.reportList.Selected = &s.selectedReport
		s.reportList.Key = func(i int) any { return records[i].ID }
		s.reportList.Label = func(i int) string {
			if records[i].Review.Title != "" {
				return records[i].Review.Title
			}
			return records[i].FileName
		}
		searching := strings.TrimSpace(s.query) != ""
		list := ui.List(c, &s.reportList, len(records), func(i int) {
			r := records[i]
			ui.Column(c).FillWidth().Padding(0, 22, 0, 22).Background(c.Theme().Background).Children(func() {
				if !searching && (i == 0 || r.Review.Date != records[i-1].Review.Date) {
					ui.Text(c, s.formatDate(r.Review.Date)).FontSize(15).Bold().TextColor(c.Theme().Accent).Padding(20, 0, 10, 0)
				}
				ui.Row(c).FillWidth().Gap(14).Children(func() {
					ui.Column(c).Width(12).Shrink(0).FillHeight().AlignItems(ui.Center).Children(func() {
						ui.Box(c).Size(12, 12).Radius(6).Background(c.Theme().Accent).Margin(4, 0, 0, 0)
						ui.Box(c).Width(2).Grow(1).MinHeight(12).Background(tokenTimeline)
					})
					label := s.reportList.Label(i)
					highlighted := r.ID == s.report.ID || i == s.selectedReport
					card := ui.ButtonBase(c).Key(r.ID).Grow(1).MinWidth(0).Padding(16).Radius(16).Background(c.Theme().Surface).TextColor(c.Theme().Text).Border(1, c.Theme().Border).Label(label).Disabled(s.busy != "").Margin(0, 0, 12, 0)
					card.Shadow(0, 1, 3, 0, ui.RGBA(0, 0, 0, 0.06))
					if card.Hovered() {
						card.Background(c.Theme().SurfaceHover).Shadow(0, 4, 8, 0, ui.RGBA(0, 0, 0, 0.13))
					}
					if highlighted {
						card.Border(2, c.Theme().Accent)
					}
					card.Children(func() {
						ui.Column(c).FillWidth().Gap(9).Children(func() {
							ui.Row(c).FillWidth().Gap(8).AlignItems(ui.Center).Children(func() {
								ui.Text(c, label).FontSize(15).Bold().Grow(1).MinWidth(0).SingleLine()
								// A single member's timeline does not repeat its name on
								// every card; All Records needs it to tell people apart.
								if name := s.memberLabel(r.Review.MemberID); name != "" && s.memberID == allMembers {
									chip(c, name)
								}
							})
							if hospital := strings.TrimSpace(r.Review.Organization); hospital != "" {
								ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
									icon(c, iconBuilding, 14, c.Theme().TextMuted)
									ui.Text(c, hospital).FontSize(13).TextColor(c.Theme().TextMuted).SingleLine().MinWidth(0)
								})
							}
							// Like the Swift card, the conclusion is the second line. A
							// record without one keeps its original's name instead of a
							// claim about what the report says.
							if summary := firstLines(r.Summary); summary != "" {
								ui.Text(c, summary).FontSize(13).MaxLines(2)
							} else if r.FileName != "" {
								ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
									icon(c, iconDoc, 14, c.Theme().TextMuted)
									ui.Text(c, r.FileName).FontSize(13).TextColor(c.Theme().TextMuted).SingleLine().MinWidth(0)
								})
							}
						})
					})
					if card.Clicked() {
						s.open(r.ID)
					}
				})
			})
		}).Grow(1).MinHeight(0).Label(s.t("timeline")).Disabled(s.busy != "")
		if list.Submitted() && s.selectedReport >= 0 && s.selectedReport < len(records) {
			s.open(records[s.selectedReport].ID)
		}
	})
}

// searchField is the Swift capsule search above the timeline.
func (s *screen) searchField(c *ui.Context) {
	ui.Row(c).FillWidth().Padding(16).Children(func() {
		ui.Row(c).FillWidth().Padding(2, 6, 2, 14).Gap(6).AlignItems(ui.Center).Radius(20).Background(tokenContainer).Border(1, c.Theme().Border).Children(func() {
			icon(c, iconSearch, 15, c.Theme().TextMuted)
			field := ui.TextInput(c, &s.query).Label(s.t("search")).Placeholder(s.t("search_placeholder")).Grow(1).MinWidth(0).Background(tokenContainer).Border(0, tokenContainer).Padding(8, 2).Disabled(s.busy != "").Tooltip("⌘F")
			if s.focusSearch {
				s.focusSearch = false
				field.Focus()
			}
			s.composing = s.composing || field.Composing()
			if field.Submitted() && !field.Composing() {
				s.load(false)
			}
			if s.query != "" {
				clear := ui.ButtonBase(c).Label(s.t("clear_search")).Padding(4).Radius(10).Disabled(s.busy != "")
				clear.Children(func() { icon(c, iconClear, 15, c.Theme().TextMuted) })
				if clear.Clicked() {
					s.query = ""
					s.load(false)
				}
			}
		})
	})
}

func chip(c *ui.Context, text string) *ui.Element {
	return ui.Text(c, text).FontSize(11).Bold().SingleLine().TextColor(c.Theme().TextMuted).Background(tokenChip).Padding(4, 10).Radius(11).Shrink(0)
}

func firstLines(text string) string {
	lines := strings.FieldsFunc(text, func(r rune) bool { return r == '\n' || r == '\r' })
	for i := range lines {
		lines[i] = strings.TrimSpace(lines[i])
	}
	lines = slices.DeleteFunc(lines, func(l string) bool { return l == "" })
	if len(lines) > 2 {
		lines = lines[:2]
	}
	return strings.Join(lines, " ")
}

// detail is the Swift RecordDetailView: confirmed fields on top, the original
// pane below. Drafts and edits open in the review sheet instead.
func (s *screen) detail(c *ui.Context) {
	confirmed := s.report.ID != "" && s.report.Status == "confirmed" && !s.editingConfirmed
	if !confirmed {
		// One empty state for the whole column instead of two empty panes.
		ui.Column(c).Fill().Center().Gap(8).Padding(24).Children(func() {
			icon(c, iconDoc, 34, c.Theme().TextMuted)
			ui.Text(c, s.t("select_record")).FontSize(17).Bold()
			ui.Text(c, s.t("select_record_detail")).TextColor(c.Theme().TextMuted)
		})
		return
	}
	ui.Column(c).Fill().Gap(0).Children(func() {
		ui.Scroll(c).FillWidth().HeightPercent(42).MinHeight(180).Children(func() { s.summary(c) })
		ui.Column(c).Grow(1).MinHeight(0).FillWidth().Padding(0, 24, 24, 24).Children(func() {
			s.originalCard(c, confirmed)
		})
	})
}

// originalCard is the Swift record-original-pane: Container with an outline,
// a Primary "Original" label, a divider, then the inline original.
func (s *screen) originalCard(c *ui.Context, confirmed bool) {
	ui.Column(c).Key(s.report.ID).Fill().Padding(12).Gap(10).Background(tokenContainer).Border(1, c.Theme().Border).Radius(12).Label(s.t("original_pane")).Children(func() {
		ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
			icon(c, iconDoc, 17, c.Theme().Accent)
			ui.Text(c, s.t("original")).Bold().TextColor(c.Theme().Accent)
		})
		divider(c, false)
		if !confirmed {
			ui.Column(c).Fill().Center().Children(func() {
				ui.Text(c, s.t("original_placeholder")).TextColor(c.Theme().TextMuted)
			})
			return
		}
		s.original(c, false)
	})
}

func (s *screen) summary(c *ui.Context) {
	ui.Column(c).FillWidth().Gap(20).Padding(24).Children(func() {
		ui.Row(c).FillWidth().Gap(12).AlignItems(ui.Start).Children(func() {
			ui.Column(c).Grow(1).MinWidth(0).Gap(6).Children(func() {
				ui.Text(c, s.report.Review.Title).FontSize(21).Bold()
				member := s.memberLabel(s.report.Review.MemberID)
				if member == "" {
					member = s.t("member")
				}
				ui.Text(c, member+"  ·  "+s.formatDate(s.report.Review.Date)).TextColor(c.Theme().TextMuted)
			})
			ui.Row(c).Gap(6).AlignItems(ui.Center).Disabled(s.busy != "").Children(func() {
				if ui.Button(c, s.t("edit_record")).Clicked() {
					s.startEditing()
				}
				// Export and delete are less frequent; keep them one click away so
				// the destructive action does not compete with Edit.
				more := ui.ButtonBase(c).Label(s.t("more_actions")).Tooltip(s.t("more_actions")).Padding(7).Radius(7).Border(1, c.Theme().Border).Background(c.Theme().Surface)
				if more.Hovered() {
					more.Background(c.Theme().SurfaceHover)
				}
				more.Children(func() { icon(c, iconMore, 16, c.Theme().TextMuted) })
				more.Menu(func(m *ui.Menu) {
					if m.Item(s.t("export")).Chosen() {
						s.chooseExport()
					}
					m.Separator()
					if m.Item(s.t("delete_report")).Chosen() {
						s.promptDelete(s.report.ID)
					}
				})
			})
		})
		text := s.report.Review.Text
		s.detailCard(c, iconList, s.t("confirmed_text"), func() {
			if strings.TrimSpace(text) == "" {
				ui.Text(c, s.t("no_findings")).TextColor(c.Theme().TextMuted)
				return
			}
			ui.Text(c, text).Label(s.t("transcription")).Selectable()
		})
		s.detailCard(c, iconQuote, s.t("conclusion"), func() {
			conclusion := s.report.Review.Conclusion
			if strings.TrimSpace(conclusion) == "" {
				ui.Text(c, s.t("no_conclusion")).TextColor(c.Theme().TextMuted)
				return
			}
			// No label: mygo reads a label instead of the text it is set on.
			ui.Text(c, conclusion).Selectable()
			s.sourceLine(c, "conclusion", conclusion)
		})
		info := []struct{ key, value string }{
			{"organization", s.report.Review.Organization},
			{"department", s.report.Review.Department},
			{"report_type", s.report.Review.ReportType},
		}
		if slices.ContainsFunc(info, func(row struct{ key, value string }) bool { return strings.TrimSpace(row.value) != "" }) {
			s.detailCard(c, iconSeal, s.t("confirmed_info"), func() {
				for _, row := range info {
					if strings.TrimSpace(row.value) == "" {
						continue
					}
					ui.Row(c).FillWidth().Gap(8).AlignItems(ui.Start).Children(func() {
						ui.Text(c, s.t(row.key)).Width(84).Shrink(0).TextColor(c.Theme().TextMuted)
						ui.Column(c).Grow(1).MinWidth(0).Gap(3).Children(func() {
							ui.Text(c, row.value).Selectable()
							s.sourceLine(c, row.key, row.value)
						})
					})
				}
			})
		}
		if notes := s.report.Review.Notes; strings.TrimSpace(notes) != "" {
			s.detailCard(c, iconNote, s.t("notes"), func() {
				ui.Text(c, notes).Label(s.t("notes")).Selectable()
			})
		}
	})
}

// sourceLine is the Swift SourcePages caption under a confirmed field.
func (s *screen) sourceLine(c *ui.Context, key, value string) {
	if hint := s.sourceHint(key, value); hint != "" {
		ui.Text(c, hint).FontSize(11).TextColor(c.Theme().TextMuted)
	}
}

// detailCard is the Swift DetailCard: Container, Outline, 16pt corners.
func (s *screen) detailCard(c *ui.Context, glyph *ui.SVG, title string, content func()) {
	ui.Column(c).FillWidth().Gap(12).Padding(18).Background(tokenContainer).Border(1, c.Theme().Border).Radius(16).Children(func() {
		ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
			icon(c, glyph, 17, c.Theme().Accent)
			ui.Text(c, title).Bold().TextColor(c.Theme().Accent)
		})
		content()
	})
}

// original shows the selected source with the page bar above it, like the
// Swift inline original view. review adds source ordering and initial OCR.
func (s *screen) original(c *ui.Context, review bool) {
	ui.Column(c).Fill().Gap(8).Children(func() {
		if len(s.report.Sources) > 1 {
			choices := make([]choice, 0, len(s.edit.SourceIDs))
			for i, id := range s.edit.SourceIDs {
				for _, source := range s.report.Sources {
					if source.ID == id {
						choices = append(choices, choice{id, s.t("source_item", i+1, source.FileName)})
						break
					}
				}
			}
			ui.Row(c).FillWidth().Gap(8).AlignItems(ui.Center).Children(func() {
				ui.Column(c).Grow(1).MinWidth(0).Children(func() {
					selected := s.sourceID
					picker(c, &selected, choices, s.t("source_selector"), s.busy != "")
					if selected != s.sourceID {
						s.selectSource(selected)
					}
				})
				if review {
					i := slices.Index(s.edit.SourceIDs, s.sourceID)
					if s.iconButton(c, iconUp, s.t("source_up"), s.busy != "" || i <= 0) {
						s.moveSource(-1)
					}
					if s.iconButton(c, iconDown, s.t("source_down"), s.busy != "" || i < 0 || i >= len(s.edit.SourceIDs)-1) {
						s.moveSource(1)
					}
				}
			})
		}
		ui.Row(c).FillWidth().Gap(4).AlignItems(ui.Center).Children(func() {
			if s.iconButton(c, iconBack, s.t("previous_page"), s.page <= 1) {
				s.preview(s.page - 1)
			}
			ui.Text(c, s.t("page", s.page, max(1, s.source().Extraction.PageCount))).FontSize(12).TextColor(c.Theme().TextMuted)
			if s.iconButton(c, iconChevron, s.t("next_page"), s.page >= s.source().Extraction.PageCount) {
				s.preview(s.page + 1)
			}
		})
		image := func(e *ui.Element) {
			e.FillWidth().Background(c.Theme().Surface).Border(1, c.Theme().Border).Padding(8).Children(func() {
				if s.bitmap != nil {
					ui.Image(c, s.bitmap).Label(s.t("original")).Fill().Fit(ui.Contain)
				} else {
					key := s.previewError
					if key == "" {
						key = "preparing_original"
					}
					ui.Column(c).Fill().Center().Children(func() { ui.Text(c, s.t(key)).TextColor(c.Theme().TextMuted) })
				}
			})
		}
		if !review || s.source().Extraction.PageCount == 0 {
			image(ui.Column(c).Grow(1).MinHeight(160))
			return
		}
		if !s.showRaw {
			image(ui.Column(c).Grow(1).MinHeight(160))
			ui.Checkbox(c, &s.showRaw, s.t("raw_ocr"))
			return
		}
		// With the initial recognition open, the original and the text scroll
		// together so both stay reachable at the minimum window size.
		ui.Scroll(c).Grow(1).MinHeight(160).FillWidth().Label(s.t("original_pane")).Children(func() {
			ui.Column(c).FillWidth().Gap(8).Children(func() {
				image(ui.Column(c).Height(320))
				ui.Checkbox(c, &s.showRaw, s.t("raw_ocr"))
				ui.Text(c, s.t("raw_hint")).FontSize(12).TextColor(c.Theme().TextMuted)
				raw := s.initialText()
				ui.Field(c, s.t("source_page", s.page), func() { ui.TextArea(c, &raw).ReadOnly(true).Height(170).FillWidth() }).FillWidth()
			})
		})
	})
}

func (s *screen) iconButton(c *ui.Context, glyph *ui.SVG, label string, disabled bool) bool {
	b := ui.ButtonBase(c).Label(label).Tooltip(label).Padding(5).Radius(6).Disabled(disabled)
	color := c.Theme().Accent
	if disabled {
		color = c.Theme().Border
	} else if b.Hovered() {
		b.Background(tokenHover)
	}
	b.Children(func() { icon(c, glyph, 15, color) })
	return b.Clicked()
}

// reviewOpen reports the Swift review or edit sheet: a draft opened for
// review, or a confirmed record being edited.
func (s *screen) reviewOpen() bool {
	return s.report.ID != "" && !s.recoveryOnly && !s.restartOnly && !s.activating && (s.report.Status != "confirmed" || s.editingConfirmed)
}

// reviewSheet is the Swift ImportReviewView / RecordEditView: a sheet with the
// original on the left and the fields on the right. Like Swift, it cannot be
// dismissed by clicking outside it; its footer owns the exits.
func (s *screen) reviewSheet(c *ui.Context) {
	if !s.reviewOpen() {
		return
	}
	open := true
	panel := ui.Modal(c, &open, func() {
		// Shortcuts reach only the topmost modal, so the sheet owns Cmd+S.
		if c.Shortcut(ui.Cmd, ui.KeyS) {
			s.queueSaveShortcut()
		}
		editing := s.report.Status == "confirmed"
		ui.Column(c).Fill().Gap(0).Disabled(s.modalOpen()).Children(func() {
			title, hint := "review_title", "review_hint"
			if editing {
				title, hint = "edit_title", "edit_hint"
			}
			ui.Row(c).FillWidth().Padding(4, 4, 18, 4).Gap(12).AlignItems(ui.Center).Children(func() {
				ui.Column(c).Grow(1).MinWidth(0).Gap(4).Children(func() {
					ui.Text(c, s.t(title)).FontSize(21).Bold()
					ui.Text(c, s.t(hint)).TextColor(c.Theme().TextMuted)
				})
				if source := s.source(); s.report.Status == "review" || s.report.Status == "confirmed" {
					chip(c, s.methodLabel(source.Extraction))
				}
			})
			divider(c, false)
			ui.Row(c).Grow(1).MinHeight(0).FillWidth().Gap(0).Children(func() {
				ui.Column(c).WidthPercent(50).MinWidth(380).FillHeight().Padding(16, 16, 16, 4).Children(func() { s.original(c, true) })
				divider(c, true)
				ui.Scroll(c).Grow(1).MinWidth(0).FillHeight().Children(func() {
					ui.Column(c).FillWidth().Gap(16).Padding(20, 20, 20, 20).Children(func() { s.review(c) })
				})
			})
			divider(c, false)
			ui.Row(c).FillWidth().Padding(16, 4, 0, 4).Gap(8).AlignItems(ui.Center).Children(func() {
				failed := s.report.Status == "failed" || s.report.Status == "processing"
				if !editing {
					if ui.Button(c, s.t("discard_draft")).TextColor(tokenDanger).Disabled(s.busy != "").Clicked() {
						s.promptDelete(s.report.ID)
					}
				}
				ui.Box(c).Grow(1)
				if s.message != "" && (s.message == "save_failed" || s.message == "invalid_date" || s.message == "invalid_review") {
					ui.Text(c, s.t(s.message)).FontSize(12).TextColor(tokenDanger).MaxLines(2).Shrink(1)
				}
				// Cmd+Return runs the primary action. The footer is built after
				// the fields, so an active input-method composition blocks it.
				commit := c.Shortcut(ui.Cmd, ui.KeyEnter) && s.busy == "" && !s.composing && !s.modalOpen()
				switch {
				case editing:
					if ui.Button(c, s.t("cancel_edit")).Disabled(s.busy != "").Clicked() {
						s.edit, s.editingConfirmed, s.message = cloneEdit(s.report.Review), false, ""
					}
					ready := s.busy == "" && s.canConfirm() && !s.composing
					if ui.PrimaryButton(c, s.t("save_update")).Tooltip("⌘↩").Disabled(!ready).Clicked() || (commit && ready) {
						s.save(false, nil)
					}
				case failed:
					if ui.Button(c, s.t("close")).Disabled(s.busy != "").Clicked() {
						s.leave(s.clearReport)
					}
					if ui.PrimaryButton(c, s.t("retry")).Tooltip("⌘↩").Disabled(s.busy != "").Clicked() || commit {
						s.retry()
					}
				default:
					if ui.Button(c, s.t("save")).Disabled(s.busy != "" || s.composing).Clicked() {
						s.save(false, s.clearReport)
					}
					ready := s.busy == "" && s.canConfirm() && !s.composing
					if ui.PrimaryButton(c, s.t("confirm")).Tooltip("⌘↩").Disabled(!ready).Clicked() || (commit && ready) {
						s.save(true, nil)
					}
				}
			})
		})
	})
	if panel != nil {
		w, h := c.Size()
		panel.Width(min(w-40, 1180)).Height(min(h-40, 780)).Label(s.t("review_title"))
	}
	// Clicking outside or Escape never discards a review, matching the Swift
	// sheet's interactiveDismissDisabled; the footer owns the exits.
	_ = open
}

// methodLabel mirrors the Swift review header: which recognition produced
// the initial transcription of the selected original.
func (s *screen) methodLabel(e document.Extraction) string {
	text, vision := false, false
	for _, block := range e.Blocks {
		text = text || block.Method == "pdfTextLayer"
		vision = vision || block.Method == "vision"
	}
	switch {
	case text && vision:
		return s.t("method_mixed")
	case text:
		return s.t("method_text_layer")
	case vision:
		return s.t("method_vision")
	default:
		return s.t("method_none")
	}
}

// dateField replaces typing YYYY-MM-DD: a calendar picker for a known date,
// or an explicit unknown date, as the Swift date selection offers. A stored
// value that is not a valid date stays visible until replaced or cleared.
func (s *screen) dateField(c *ui.Context, value *string, label string, disabled bool) {
	ui.Row(c).FillWidth().Gap(8).AlignItems(ui.Center).Children(func() {
		if *value == "" {
			ui.Text(c, s.t("unknown_date")).TextColor(c.Theme().TextMuted).Grow(1).MinWidth(0)
			if ui.Button(c, s.t("date_choose")).Disabled(disabled).Clicked() {
				*value = time.Now().Format("2006-01-02")
			}
			return
		}
		if t, err := time.Parse("2006-01-02", *value); err == nil {
			chosen := ui.DateInput(c, &t).Label(label).Disabled(disabled)
			if chosen.Changed() {
				*value = t.Format("2006-01-02")
			}
			ui.Box(c).Grow(1)
		} else {
			ui.Text(c, *value).TextColor(tokenDanger).Grow(1).MinWidth(0)
		}
		if ui.Button(c, s.t("date_clear")).Disabled(disabled).Clicked() {
			*value = ""
		}
	})
}

// printedDates offers the dates the report prints under a known label. The
// user chooses; none is taken as the timeline date on its own.
func (s *screen) printedDates(c *ui.Context) {
	var offered []candidate.Date
	for _, date := range s.found.Dates {
		if date.Value != s.edit.Date && len(offered) < 4 {
			offered = append(offered, date)
		}
	}
	if len(offered) == 0 {
		return
	}
	ui.Row(c).FillWidth().Wrap().Gap(6).AlignItems(ui.Center).Children(func() {
		ui.Text(c, s.t("printed_dates")).FontSize(12).TextColor(c.Theme().TextMuted)
		for _, date := range offered {
			if ui.Button(c, s.t("date_kind_"+date.Kind)+" "+date.Value).Key(date.Kind + date.Value).FontSize(12).Clicked() {
				s.edit.Date = date.Value
			}
		}
	})
}

func (s *screen) review(c *ui.Context) {
	if s.report.Status == "failed" || s.report.Status == "processing" {
		ui.Column(c).FillWidth().Gap(10).Children(func() {
			ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
				icon(c, iconWarning, 18, tokenDanger)
				ui.Text(c, s.t("failed")).FontSize(18).Bold()
			})
			ui.Text(c, s.t(failureKey(s.report.Failure))).TextColor(c.Theme().TextMuted)
		})
		return
	}
	ui.Column(c).FillWidth().Gap(16).Disabled(s.busy != "").Children(func() {
		if s.canFill() {
			ui.Row(c).FillWidth().Gap(10).Padding(10, 12).AlignItems(ui.Center).Background(tokenContainer).Border(1, c.Theme().Border).Radius(10).Children(func() {
				icon(c, iconScan, 16, c.Theme().TextMuted)
				ui.Text(c, s.t("fill_available")).FontSize(12).TextColor(c.Theme().TextMuted).Grow(1).MinWidth(0).MaxLines(2)
				if ui.Button(c, s.t("fill_empty")).Clicked() {
					s.fillFromRecognition()
				}
			})
		}
		ui.Field(c, s.t("member"), func() {
			choices := []choice{{"", s.t("choose_member")}}
			for _, member := range s.members {
				choices = append(choices, choice{member.ID, member.Name})
			}
			picker(c, &s.edit.MemberID, choices, s.t("member"), false)
		}).FillWidth()
		ui.Field(c, s.t("date"), func() {
			s.dateField(c, &s.edit.Date, s.t("date"), false)
			s.printedDates(c)
		}).FillWidth()
		for _, field := range []struct {
			key   string
			value *string
		}{{"title", &s.edit.Title}, {"organization", &s.edit.Organization}, {"department", &s.edit.Department}, {"report_type", &s.edit.ReportType}} {
			ui.Field(c, s.t(field.key), func() {
				input := ui.TextInput(c, field.value).FillWidth()
				s.composing = s.composing || input.Composing()
			}).Description(s.sourceHint(field.key, *field.value)).FillWidth()
		}
		ui.Field(c, s.t("transcription"), func() {
			field := ui.TextArea(c, &s.edit.Text).Height(230).FillWidth().Padding(8)
			s.composing = s.composing || field.Composing()
		}).FillWidth()
		ui.Field(c, s.t("conclusion_verbatim"), func() {
			field := ui.TextArea(c, &s.edit.Conclusion).Height(120).FillWidth().Padding(8)
			s.composing = s.composing || field.Composing()
		}).Description(cmp.Or(s.sourceHint("conclusion", s.edit.Conclusion), s.t("verbatim_hint"))).FillWidth()
		ui.Field(c, s.t("notes_optional"), func() {
			field := ui.TextArea(c, &s.edit.Notes).Height(96).FillWidth().Padding(8)
			s.composing = s.composing || field.Composing()
		}).Description(s.t("notes_hint")).FillWidth()
	})
}

type choice struct{ value, label string }

func (c choice) String() string { return c.label }

// Values are IDs, independent of display labels, duplicate names and language.
func picker(c *ui.Context, value *string, options []choice, label string, disabled bool) {
	selectedLabel := ""
	for _, option := range options {
		if option.value == *value {
			selectedLabel = option.label
		}
	}
	selected := choice{*value, selectedLabel}
	p := ui.SelectBase(c, &selected)
	p.Trigger.Label(label).Disabled(disabled).FillWidth().Padding(9, 10).Background(c.Theme().Surface).Border(1, c.Theme().Border).Radius(7).Gap(6).Children(func() {
		ui.Text(c, selectedLabel).SingleLine().Grow(1).MinWidth(0)
		ui.Text(c, "▾").TextColor(c.Theme().TextMuted)
	})
	p.Popup(func(panel *ui.Element) {
		panel.Padding(4).Background(c.Theme().Surface).Border(1, c.Theme().Border).Radius(7)
		for _, option := range options {
			item := p.Item(option).Padding(9, 10).Radius(5).Label(option.label)
			if item.Highlighted() {
				item.Background(tokenContainer)
			}
			item.Children(func() { ui.Text(c, option.label) })
		}
	})
	*value = selected.value
}

func (s *screen) dialogs(c *ui.Context) {
	if s.pending != nil {
		open := true
		ui.Modal(c, &open, func() {
			ui.Text(c, s.t("unsaved")).FontSize(20).Bold()
			ui.Text(c, s.t("unsaved_detail"))
			if s.message == "save_failed" {
				ui.Text(c, s.t(s.message)).TextColor(tokenDanger)
			}
			ui.Column(c).Gap(8).Disabled(s.busy != "").Children(func() {
				if ui.PrimaryButton(c, s.t("save_continue")).FillWidth().Clicked() {
					s.save(false, s.pending)
				}
				if ui.Button(c, s.t("discard_changes")).FillWidth().Clicked() {
					next := s.pending
					s.pending = nil
					s.edit = cloneEdit(s.report.Review)
					next()
				}
				if ui.Button(c, s.t("keep_editing")).FillWidth().Clicked() {
					s.cancelLeave()
				}
			})
		}).Width(420).Label(s.t("unsaved"))
		if !open && s.busy == "" {
			s.cancelLeave()
		}
	}
	if s.newMember {
		open := true
		ui.Modal(c, &open, func() {
			ui.Text(c, s.t("add_member")).FontSize(20).Bold()
			ui.Text(c, s.t("member_hint")).TextColor(c.Theme().TextMuted)
			submitted := false
			ui.Field(c, s.t("member_name"), func() {
				field := ui.TextInput(c, &s.memberName).FillWidth().Disabled(s.busy != "").AutoFocus()
				submitted = field.Submitted() && !field.Composing()
				s.composing = s.composing || field.Composing()
			})
			if s.message == "member_failed" {
				ui.Text(c, s.t(s.message)).TextColor(tokenDanger)
			}
			ui.Row(c).Gap(8).Children(func() {
				ui.Box(c).Grow(1)
				if ui.Button(c, s.t("cancel")).Disabled(s.busy != "").Clicked() {
					s.newMember = false
				}
				if ui.PrimaryButton(c, s.t("save_member")).Disabled(s.busy != "" || strings.TrimSpace(s.memberName) == "").Clicked() || submitted {
					s.addMember()
				}
			})
		}).Width(440).Label(s.t("add_member"))
		if !open && s.busy == "" {
			s.newMember = false
		}
	}
	if s.deletePrompt {
		open := true
		draft := s.deleteTargetStatus() != "confirmed"
		title, detail, confirm, keep := "delete_title", "delete_detail", "delete_confirm", "keep"
		if draft {
			title, detail, confirm, keep = "discard_title", "discard_detail", "discard_confirm", "discard_keep"
		}
		ui.Modal(c, &open, func() {
			ui.Text(c, s.t(title)).FontSize(20).Bold()
			ui.Text(c, s.t(detail))
			ui.Column(c).Gap(8).Children(func() {
				if ui.Button(c, s.t(confirm)).FillWidth().TextColor(tokenDanger).Disabled(s.busy != "").Clicked() {
					s.deleteReport()
				}
				if ui.Button(c, s.t(keep)).FillWidth().Disabled(s.busy != "").Clicked() {
					s.cancelDelete()
				}
			})
		}).Width(420).Label(s.t(title))
		if !open && s.busy == "" {
			s.cancelDelete()
		}
	}
	if len(s.importPaths) > 0 {
		open := true
		ui.Modal(c, &open, func() {
			ui.Text(c, s.t("import_choice")).FontSize(20).Bold()
			ui.Text(c, s.t("import_choice_detail")).TextColor(c.Theme().TextMuted)
			if len(s.importPaths) > document.MaxSources {
				ui.Text(c, s.t("sources_limit")).TextColor(tokenDanger)
			}
			paths := s.importPaths
			// These rows contain no editable state. Identity follows each unique
			// position so moving a file preserves the viewport, even if paths repeat.
			ui.List(c, nil, len(paths), func(i int) {
				ui.Row(c).FillWidth().Gap(8).AlignItems(ui.Center).Children(func() {
					ui.Text(c, s.t("source_item", i+1, filepath.Base(paths[i]))).Grow(1).SingleLine()
					if s.iconButton(c, iconUp, s.t("file_up", i+1), i == 0) {
						paths[i], paths[i-1] = paths[i-1], paths[i]
					}
					if s.iconButton(c, iconDown, s.t("file_down", i+1), i == len(paths)-1) {
						paths[i], paths[i+1] = paths[i+1], paths[i]
					}
				})
			}).Height(230).FillWidth().Gap(8).Label(s.t("selected_files"))
			ui.Column(c).Gap(8).Children(func() {
				if ui.PrimaryButton(c, s.t("import_combined")).Disabled(len(s.importPaths) > document.MaxSources).FillWidth().Clicked() {
					s.importSelection(true)
				}
				if ui.Button(c, s.t("import_separate")).FillWidth().Clicked() {
					s.importSelection(false)
				}
				if ui.Button(c, s.t("cancel")).FillWidth().Clicked() {
					s.importPaths = nil
				}
			})
		}).Width(520).Label(s.t("import_choice"))
		if !open {
			s.importPaths = nil
		}
	}
}

// successMessage lists outcomes shown as a toast; everything else stays on
// screen until the next action.
func successMessage(key string) bool {
	switch key {
	case "saved", "updated", "confirmed", "exported", "export_cancelled", "phone_deleted", "phone_stopped", "phone_existing_confirmed":
		return true
	}
	return false
}

// errorMessage marks failures, which carry a warning icon and the danger color.
func errorMessage(key string) bool {
	switch key {
	case "invalid_date", "invalid_review", "unsupported", "locked", "limit", "invalid_document", "unavailable", "recognition_failed", "sources_limit", "wait_busy", "cleanup_pending", "phone_no_interface":
		return true
	}
	return strings.HasSuffix(key, "_failed")
}

// phoneInlineMessage lists messages the phone queue already shows inline.
func phoneInlineMessage(key string) bool {
	switch key {
	case "phone_load_failed", "phone_archive_failed", "phone_retry_failed", "phone_delete_failed", "phone_selection_changed":
		return true
	}
	return false
}

// requestSearchFocus is Cmd+F: focus the timeline search like the Swift app.
func (s *screen) requestSearchFocus() {
	if s.phonePage || s.backupPage || s.recoveryOnly || s.restartOnly || s.activating || s.modalOpen() || s.reviewOpen() || s.phone.receiverOpen {
		return
	}
	s.focusSearch = true
}
