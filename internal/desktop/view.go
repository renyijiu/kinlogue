package desktop

import (
	"path/filepath"
	"slices"
	"strings"

	"github.com/egoist/mygo/ui"
	"kinlogue/internal/document"
)

func warmTheme() *ui.Theme {
	t := ui.LightTheme()
	t.Background, t.Surface = ui.Hex("#FFF8F5"), ui.Hex("#FFFFFF")
	t.SurfaceHover, t.SurfacePressed = ui.Hex("#FBF2ED"), ui.Hex("#F5ECE7")
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
	ui.Row(c).Fill().Gap(0).Children(func() {
		if !s.recoveryOnly && !s.restartOnly && !s.activating {
			ui.Column(c).Width(196).Shrink(0).FillHeight().Padding(16, 10).Gap(12).Background(c.Theme().Background).Disabled(s.modalOpen() || s.backup.step != "").Children(func() { s.sidebar(c) })
			ui.Box(c).Width(1).FillHeight().Background(c.Theme().Border)
		}
		ui.Column(c).Grow(1).MinWidth(0).FillHeight().Children(func() {
			ui.Column(c).Grow(1).MinHeight(0).Disabled(s.modalOpen()).Children(func() {
				if s.backupPage || s.recoveryOnly || s.restartOnly {
					ui.Column(c).Fill().Padding(24).Children(func() { s.backupView(c) })
					return
				}
				ui.Row(c).FillWidth().Padding(10, 18).Gap(12).AlignItems(ui.Center).Children(func() {
					ui.Text(c, s.t("family_timeline")).Bold().Grow(1).TextColor(c.Theme().TextMuted)
					if ui.Button(c, s.t("import")).Disabled(s.busy != "").Clicked() {
						s.queueNavigation(s.chooseFiles)
					}
				})
				ui.Box(c).Height(1).FillWidth().Background(c.Theme().Border)
				ui.Row(c).Grow(1).MinHeight(0).FillWidth().Children(func() {
					ui.Column(c).Width(284).Shrink(0).FillHeight().Padding(16, 14).Children(func() { s.list(c) })
					ui.Box(c).Width(1).FillHeight().Background(c.Theme().Border)
					ui.Column(c).Grow(1).MinWidth(0).FillHeight().Padding(18).Children(func() {
						if s.report.ID == "" {
							ui.Column(c).Fill().Center().Gap(12).Children(func() {
								ui.Text(c, s.t("select_record")).FontSize(22).Bold()
								ui.Text(c, s.t("select_record_detail")).TextColor(c.Theme().TextMuted)
							})
						} else {
							s.detail(c)
						}
					})
				})
			})
			if s.message != "" {
				ui.Text(c, s.t(s.message)).Padding(8, 18).TextColor(c.Theme().TextMuted)
			}
			if s.busy != "" {
				ui.Row(c).Padding(8, 18).Gap(12).AlignItems(ui.Center).Children(func() {
					key := s.busy
					if s.cancelling {
						key = "cancelling"
					}
					ui.Text(c, s.t(key)).TextColor(c.Theme().Accent)
					if s.cancellable && ui.Button(c, s.t("cancel_task")).Disabled(s.cancelling).Clicked() {
						s.cancelling = true
						s.jobCancel()
					}
				})
			}
		})
	})
	s.dialogs(c)
	if c.Shortcut(ui.Cmd, ui.KeyS) {
		s.queueSaveShortcut()
	}
	if s.consumeRequests() {
		// Requests can open a dirty guard after the dialogs were built.
		c.Invalidate()
	}
}

func (s *screen) sidebar(c *ui.Context) {
	ui.Text(c, s.t("brand")).Padding(4, 10).FontSize(20).Bold().TextColor(c.Theme().Accent)
	ui.Text(c, s.t("browse")).Padding(0, 10).FontSize(11).TextColor(c.Theme().TextMuted)
	if s.sidebarButton(c, s.t("all_records"), "◷", s.memberID == allMembers && !s.backupPage) {
		s.selectMember(allMembers)
	}
	if s.sidebarButton(c, s.t("inbox"), "▤", s.memberID == "" && !s.backupPage) {
		s.selectMember("")
	}
	ui.Text(c, s.t("members")).Padding(10, 10, 0, 10).FontSize(11).TextColor(c.Theme().TextMuted)
	ui.Scroll(c).Grow(1).MinHeight(60).Children(func() {
		ui.Column(c).FillWidth().Gap(4).Children(func() {
			if len(s.members) == 0 {
				ui.Text(c, s.t("empty_members")).Padding(10).FontSize(12).TextColor(c.Theme().TextMuted)
			}
			for _, member := range s.members {
				ui.Column(c).Key(member.ID).FillWidth().Children(func() {
					if s.sidebarButton(c, member.Name, "●", member.ID == s.memberID && !s.backupPage) {
						s.selectMember(member.ID)
					}
				})
			}
			if s.sidebarButton(c, s.t("add_member"), "+", false) {
				s.queueNavigation(func() { s.newMember = true })
			}
		})
	})
	ui.Box(c).Height(1).FillWidth().Background(c.Theme().Border)
	if s.sidebarButton(c, s.t("settings"), "⚙", s.backupPage) {
		s.queueNavigation(s.showBackup)
	}
}

func (s *screen) sidebarButton(c *ui.Context, label, icon string, selected bool) bool {
	b := ui.ButtonBase(c).Label(label).Selected(selected).FillWidth().Height(44).Padding(10).Radius(7).Gap(10).AlignItems(ui.Center).Disabled(s.busy != "")
	b.Background(c.Theme().Background).TextColor(c.Theme().TextMuted)
	if selected {
		b.Background(c.Theme().SurfacePressed).TextColor(c.Theme().Accent)
	} else if b.Hovered() {
		b.Background(c.Theme().SurfaceHover)
	}
	b.Children(func() { ui.Text(c, icon).Width(16); ui.Text(c, label).Grow(1).MinWidth(0).SingleLine() })
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

func (s *screen) list(c *ui.Context) {
	title := s.t("inbox")
	if s.memberID == allMembers {
		title = s.t("all_records")
	} else if s.memberID != "" {
		title = s.memberLabel(s.memberID)
	}
	ui.Column(c).Fill().Gap(14).Children(func() {
		ui.Text(c, title).FontSize(16).Bold().TextColor(c.Theme().Accent).SingleLine()
		if s.memberID != "" {
			ui.Row(c).Gap(6).Children(func() {
				field := ui.TextInput(c, &s.query).Label(s.t("search")).Placeholder(s.t("search")).MinWidth(0).Grow(1).Disabled(s.busy != "")
				if ui.Button(c, "⌕").Label(s.t("search_action")).Disabled(s.busy != "").Clicked() || field.Submitted() {
					s.load(false)
				}
			})
		}
		records := s.drafts
		if s.memberID != "" {
			records = s.records
		}
		if len(records) == 0 {
			ui.Column(c).Grow(1).FillWidth().Center().Gap(12).Children(func() {
				key := "empty_inbox"
				if s.memberID != "" {
					key = "empty_timeline"
					if s.query != "" {
						key = "empty_search"
					}
				}
				ui.Text(c, s.t(key)).FontSize(16).Bold()
				if s.memberID == "" {
					ui.Text(c, s.t("empty_inbox_detail")).TextColor(c.Theme().TextMuted)
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
		listLabel := "inbox"
		if s.memberID != "" {
			listLabel = "timeline"
		}
		list := ui.List(c, &s.reportList, len(records), func(i int) {
			r := records[i]
			if i == 0 || r.Review.Date != records[i-1].Review.Date {
				date := r.Review.Date
				if date == "" {
					date = s.t("unknown_date")
				}
				ui.Text(c, date).FontSize(12).Bold().TextColor(c.Theme().Accent).Background(c.Theme().Background).Padding(8, 0)
			}
			ui.Row(c).FillWidth().Gap(8).Background(c.Theme().Background).Children(func() {
				ui.Column(c).Width(8).FillHeight().AlignItems(ui.Center).Children(func() {
					ui.Box(c).Size(7, 7).Radius(4).Background(c.Theme().Accent).Margin(14, 0, 0, 0)
					ui.Box(c).Width(1).Grow(1).Background(c.Theme().Border)
				})
				label := s.reportList.Label(i)
				button := ui.ButtonBase(c).Key(r.ID).Grow(1).MinWidth(0).Padding(12).Radius(10).Background(c.Theme().Surface).TextColor(c.Theme().Text).Border(1, c.Theme().Border).Label(label).Disabled(s.busy != "")
				if i == s.selectedReport {
					button.Background(c.Theme().SurfacePressed)
				}
				if r.ID == s.report.ID {
					button.Border(2, c.Theme().Accent)
				} else if button.Hovered() {
					button.Background(c.Theme().SurfaceHover)
				}
				button.Children(func() {
					ui.Column(c).FillWidth().Gap(8).Children(func() {
						ui.Text(c, label).FontSize(14).Bold().SingleLine()
						if name := s.memberLabel(r.Review.MemberID); name != "" {
							ui.Text(c, name).FontSize(11).TextColor(c.Theme().TextMuted).Background(c.Theme().SurfacePressed).Padding(3, 7).Radius(6).AlignSelf(ui.Start)
						}
						ui.Text(c, s.t(statusKey(r.Status))).FontSize(11).TextColor(c.Theme().TextMuted)
					})
				})
				if button.Clicked() {
					s.open(r.ID)
				}
			})
		}).Grow(1).MinHeight(0).Gap(10).Label(s.t(listLabel)).Disabled(s.busy != "")
		if list.Submitted() && s.selectedReport >= 0 && s.selectedReport < len(records) {
			s.open(records[s.selectedReport].ID)
		}
	})
}

func statusKey(status string) string {
	switch status {
	case "confirmed":
		return "confirmed"
	case "processing":
		return "processing"
	case "failed":
		return "failed"
	default:
		return "review"
	}
}

func (s *screen) detail(c *ui.Context) {
	ui.Column(c).Key(s.report.ID).Fill().Gap(14).Children(func() {
		if s.report.Status == "confirmed" && !s.editingConfirmed {
			ui.Scroll(c).FillWidth().HeightPercent(40).MinHeight(180).Children(func() { s.summary(c) })
			ui.Column(c).Grow(1).MinHeight(0).FillWidth().Padding(12).Gap(8).Background(c.Theme().SurfacePressed).Border(1, c.Theme().Border).Radius(12).Children(func() { s.original(c) })
			return
		}
		ui.Text(c, s.report.FileName).FontSize(18).Bold().SingleLine()
		ui.Row(c).Grow(1).MinHeight(0).Gap(16).Children(func() {
			ui.Column(c).WidthPercent(40).FillHeight().Gap(10).Children(func() { s.original(c) })
			ui.Scroll(c).Grow(1).MinWidth(0).Children(func() {
				ui.Column(c).FillWidth().Gap(14).Padding(0, 4, 12, 0).Children(func() { s.review(c) })
			})
		})
	})
}

func (s *screen) summary(c *ui.Context) {
	ui.Column(c).FillWidth().Gap(14).Padding(0, 4, 12, 0).Children(func() {
		ui.Text(c, s.report.Review.Title).FontSize(20).Bold()
		ui.Row(c).Gap(10).Wrap().AlignItems(ui.Center).Children(func() {
			ui.Text(c, s.memberLabel(s.report.Review.MemberID)).TextColor(c.Theme().TextMuted)
			date := s.report.Review.Date
			if date == "" {
				date = s.t("unknown_date")
			}
			ui.Text(c, date).FontSize(12).Padding(4, 8).Radius(6).Background(c.Theme().SurfacePressed)
		})
		ui.Row(c).Gap(8).Wrap().Disabled(s.busy != "").Children(func() {
			if ui.Button(c, s.t("edit_record")).Clicked() {
				s.startEditing()
			}
			if ui.Button(c, s.t("export")).Clicked() {
				s.chooseExport()
			}
			if ui.Button(c, s.t("delete_report")).TextColor(c.Theme().Danger).Clicked() {
				s.deletePrompt = true
			}
		})
		ui.Text(c, s.t("confirmed_hint")).FontSize(12).TextColor(c.Theme().TextMuted)
		for _, item := range []struct{ heading, label, value string }{{"confirmed_text", "transcription", s.report.Review.Text}, {"notes", "notes", s.report.Review.Notes}} {
			if item.value == "" {
				continue
			}
			ui.Column(c).FillWidth().Gap(8).Padding(14).Background(c.Theme().SurfacePressed).Border(1, c.Theme().Border).Radius(12).Children(func() {
				ui.Text(c, s.t(item.heading)).FontSize(12).Bold().TextColor(c.Theme().Accent)
				value := item.value
				ui.TextArea(c, &value).Label(s.t(item.label)).ReadOnly(true).FillWidth().Height(100).Padding(0).Background(c.Theme().SurfacePressed).Border(0, c.Theme().SurfacePressed)
			})
		}
	})
}

func (s *screen) original(c *ui.Context) {
	ui.Scroll(c).Fill().Label(s.t("original_pane")).Children(func() {
		column := ui.Column(c).FillWidth().MinHeightPercent(100).Gap(8)
		if !s.showRaw {
			column.HeightPercent(100)
		}
		column.Children(func() {
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
				selected := s.sourceID
				picker(c, &selected, choices, s.t("source_selector"), s.busy != "")
				if selected != s.sourceID {
					s.selectSource(selected)
				}
				if s.report.Status == "review" || s.editingConfirmed {
					i := slices.Index(s.edit.SourceIDs, s.sourceID)
					ui.Row(c).Gap(8).Children(func() {
						if ui.Button(c, s.t("source_up")).Disabled(s.busy != "" || i <= 0).Clicked() {
							s.moveSource(-1)
						}
						if ui.Button(c, s.t("source_down")).Disabled(s.busy != "" || i < 0 || i >= len(s.edit.SourceIDs)-1).Clicked() {
							s.moveSource(1)
						}
					})
				}
			}
			ui.Row(c).Gap(8).Children(func() {
				ui.Text(c, s.t("original")).FontSize(18).Bold().Grow(1)
				ui.Text(c, s.t("page", s.page, max(1, s.source().Extraction.PageCount))).TextColor(c.Theme().TextMuted)
			})
			ui.Column(c).Grow(1).MinHeight(200).FillWidth().Background(c.Theme().Surface).Border(1, c.Theme().Border).Radius(8).Padding(8).Children(func() {
				if s.bitmap != nil {
					ui.Image(c, s.bitmap).Label(s.t("original")).Fill().Fit(ui.Contain)
				} else {
					key := s.previewError
					if key == "" {
						key = "loading"
					}
					ui.Column(c).Fill().Center().Children(func() { ui.Text(c, s.t(key)).TextColor(c.Theme().TextMuted) })
				}
			})
			ui.Row(c).Gap(8).Children(func() {
				if ui.Button(c, s.t("previous_page")).Disabled(s.page <= 1).Clicked() {
					s.preview(s.page - 1)
				}
				if ui.Button(c, s.t("next_page")).Disabled(s.page >= s.source().Extraction.PageCount).Clicked() {
					s.preview(s.page + 1)
				}
			})
			if s.source().Extraction.PageCount > 0 {
				ui.Checkbox(c, &s.showRaw, s.t("raw_ocr"))
				if s.showRaw {
					ui.Text(c, s.t("raw_hint")).FontSize(12).TextColor(c.Theme().TextMuted)
					raw := s.initialText()
					ui.Field(c, s.t("source_page", s.page), func() { ui.TextArea(c, &raw).ReadOnly(true).Height(170).FillWidth() }).FillWidth()
				}
			}

		})
	})
}

func (s *screen) review(c *ui.Context) {
	confirmed := s.report.Status == "confirmed"
	if s.report.Status == "failed" || s.report.Status == "processing" {
		ui.Text(c, s.t("failed")).FontSize(22).Bold()
		ui.Text(c, s.t(failureKey(s.report.Failure))).TextColor(c.Theme().TextMuted)
		ui.Row(c).Gap(8).Children(func() {
			if ui.PrimaryButton(c, s.t("retry")).Disabled(s.busy != "").Clicked() {
				s.retry()
			}
			if ui.Button(c, s.t("discard_draft")).TextColor(c.Theme().Danger).Disabled(s.busy != "").Clicked() {
				s.deletePrompt = true
			}
		})
		return
	}
	key := "review_hint"
	if confirmed {
		key = "confirmed_hint"
	}
	ui.Text(c, s.t(key)).TextColor(c.Theme().TextMuted)
	ui.Column(c).FillWidth().Gap(14).Disabled(s.busy != "").Children(func() {
		ui.Field(c, s.t("member"), func() {
			choices := []choice{{"", s.t("choose_member")}}
			for _, member := range s.members {
				choices = append(choices, choice{member.ID, member.Name})
			}
			picker(c, &s.edit.MemberID, choices, s.t("member"), false)
		}).FillWidth()
		ui.Field(c, s.t("title"), func() {
			field := ui.TextInput(c, &s.edit.Title).FillWidth()
			s.composing = s.composing || field.Composing()
		}).FillWidth()
		ui.Field(c, s.t("date"), func() {
			field := ui.TextInput(c, &s.edit.Date).FillWidth().Placeholder(s.t("unknown_date"))
			s.composing = s.composing || field.Composing()
		}).Description(s.t("date_hint")).FillWidth()
		ui.Field(c, s.t("transcription"), func() {
			field := ui.TextArea(c, &s.edit.Text).Height(230).FillWidth()
			s.composing = s.composing || field.Composing()
		}).FillWidth()
		ui.Field(c, s.t("notes"), func() {
			field := ui.TextArea(c, &s.edit.Notes).Height(100).FillWidth()
			s.composing = s.composing || field.Composing()
		}).FillWidth()
		if s.editingConfirmed {
			ui.Row(c).Gap(8).Wrap().Children(func() {
				if ui.PrimaryButton(c, s.t("save_update")).Disabled(!s.canConfirm() || s.composing).Clicked() {
					s.save(false, nil)
				}
				if ui.Button(c, s.t("cancel_edit")).Clicked() {
					s.cancelEditing()
				}
			})
		}
		if !confirmed {
			ui.Row(c).Gap(8).Wrap().Children(func() {
				if ui.Button(c, s.t("save")).Disabled(s.composing).Clicked() {
					s.save(false, nil)
				}
				if ui.PrimaryButton(c, s.t("confirm")).Disabled(!s.canConfirm() || s.composing).Clicked() {
					s.save(true, nil)
				}
			})
			if ui.Button(c, s.t("discard_draft")).TextColor(c.Theme().Danger).Clicked() {
				s.deletePrompt = true
			}
		}
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
	p.Trigger.Label(label).Disabled(disabled).FillWidth().Padding(10).Background(c.Theme().Surface).Border(1, c.Theme().Border).Radius(6).Children(func() { ui.Text(c, selectedLabel).SingleLine(); ui.Text(c, "▾") })
	p.Popup(func(panel *ui.Element) {
		panel.Padding(4).Background(c.Theme().Surface).Border(1, c.Theme().Border).Radius(6)
		for _, option := range options {
			item := p.Item(option).Padding(10).Label(option.label)
			if item.Highlighted() {
				item.Background(c.Theme().SurfacePressed)
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
			ui.Text(c, s.t("unsaved")).FontSize(22).Bold()
			ui.Text(c, s.t("unsaved_detail"))
			if s.message != "" {
				ui.Text(c, s.t(s.message)).TextColor(c.Theme().Danger)
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
				if ui.Button(c, s.t("cancel")).FillWidth().Clicked() {
					s.cancelLeave()
				}
			})
		}).Label(s.t("unsaved"))
		if !open && s.busy == "" {
			s.cancelLeave()
		}
	}
	if s.newMember {
		open := true
		ui.Modal(c, &open, func() {
			ui.Text(c, s.t("add_member")).FontSize(22).Bold()
			ui.Text(c, s.t("member_hint"))
			submitted := false
			ui.Field(c, s.t("member_name"), func() {
				field := ui.TextInput(c, &s.memberName).FillWidth().Disabled(s.busy != "").AutoFocus()
				submitted = field.Submitted() && !field.Composing()
				s.composing = s.composing || field.Composing()
			})
			if s.message != "" {
				ui.Text(c, s.t(s.message)).TextColor(c.Theme().Danger)
			}
			ui.Row(c).Gap(8).Children(func() {
				if ui.Button(c, s.t("cancel")).Disabled(s.busy != "").Clicked() {
					s.newMember = false
				}
				if ui.PrimaryButton(c, s.t("add_member")).Disabled(s.busy != "" || strings.TrimSpace(s.memberName) == "").Clicked() || submitted {
					s.addMember()
				}
			})
		}).Label(s.t("add_member"))
		if !open && s.busy == "" {
			s.newMember = false
		}
	}
	if s.deletePrompt {
		open := true
		ui.Modal(c, &open, func() {
			ui.Text(c, s.t("delete_title")).FontSize(22).Bold()
			ui.Text(c, s.t("delete_detail"))
			ui.Row(c).Gap(8).Children(func() {
				if ui.Button(c, s.t("cancel")).Disabled(s.busy != "").Clicked() {
					s.deletePrompt = false
				}
				if ui.Button(c, s.t("delete_confirm")).TextColor(c.Theme().Danger).Disabled(s.busy != "").Clicked() {
					s.deleteReport()
				}
			})
		}).Label(s.t("delete_title"))
		if !open && s.busy == "" {
			s.deletePrompt = false
		}
	}
	if len(s.importPaths) > 0 {
		open := true
		ui.Modal(c, &open, func() {
			ui.Text(c, s.t("import_choice")).FontSize(22).Bold()
			ui.Text(c, s.t("import_choice_detail"))
			if len(s.importPaths) > document.MaxSources {
				ui.Text(c, s.t("sources_limit")).TextColor(c.Theme().Danger)
			}
			paths := s.importPaths
			// These rows contain no editable state. Identity follows each unique
			// position so moving a file preserves the viewport, even if paths repeat.
			ui.List(c, nil, len(paths), func(i int) {
				ui.Row(c).FillWidth().Gap(8).Children(func() {
					ui.Text(c, s.t("source_item", i+1, filepath.Base(paths[i]))).Grow(1).SingleLine()
					if ui.Button(c, "↑").Label(s.t("file_up", i+1)).Disabled(i == 0).Clicked() {
						paths[i], paths[i-1] = paths[i-1], paths[i]
					}
					if ui.Button(c, "↓").Label(s.t("file_down", i+1)).Disabled(i == len(paths)-1).Clicked() {
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
		}).Label(s.t("import_choice"))
		if !open {
			s.importPaths = nil
		}
	}
}
