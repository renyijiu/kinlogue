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
			ui.Column(c).Width(230).FillHeight().Padding(20, 16).Gap(14).Background(c.Theme().SurfacePressed).Disabled(s.modalOpen() || s.backup.step != "").Children(func() { s.sidebar(c) })
		}
		ui.Column(c).Grow(1).MinWidth(0).FillHeight().Padding(22).Gap(16).Children(func() {
			ui.Column(c).Grow(1).MinHeight(0).Disabled(s.modalOpen()).Children(func() {
				if s.backupPage || s.recoveryOnly || s.restartOnly {
					s.backupView(c)
				} else if s.report.ID == "" {
					s.list(c)
				} else {
					s.detail(c)
				}
			})
			if s.message != "" {
				ui.Text(c, s.t(s.message)).TextColor(c.Theme().TextMuted)
			}
			if s.busy != "" {
				ui.Row(c).Gap(12).AlignItems(ui.Center).Children(func() {
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
	ui.Text(c, s.t("app")).FontSize(22).Bold().TextColor(c.Theme().Accent)
	ui.Text(c, s.t("tagline")).TextColor(c.Theme().TextMuted).FontSize(12)
	if ui.PrimaryButton(c, s.t("import")).FillWidth().Height(42).Disabled(s.busy != "").Clicked() {
		s.queueNavigation(s.chooseFiles)
	}
	button := ui.Button(c, s.t("inbox")).FillWidth().Height(44).Disabled(s.busy != "")
	if s.memberID == "" && !s.backupPage {
		button.Background(c.Theme().Surface).TextColor(c.Theme().Accent)
	}
	if button.Clicked() {
		s.selectMember("")
	}
	ui.Text(c, s.t("members")).Bold().TextColor(c.Theme().TextMuted)
	ui.Scroll(c).Grow(1).MinHeight(60).Children(func() {
		ui.Column(c).FillWidth().Gap(6).Children(func() {
			if len(s.members) == 0 {
				ui.Text(c, s.t("empty_members")).FontSize(12)
			}
			for _, member := range s.members {
				b := ui.Button(c, member.Name).Key(member.ID).FillWidth().Height(44).Disabled(s.busy != "")
				if member.ID == s.memberID && !s.backupPage {
					b.Background(c.Theme().Surface).TextColor(c.Theme().Accent)
				}
				if b.Clicked() {
					s.selectMember(member.ID)
				}
			}
		})
	})
	if ui.Button(c, s.t("add_member")).FillWidth().Height(44).Disabled(s.busy != "").Clicked() {
		s.queueNavigation(func() { s.newMember = true })
	}
	if s.backups != nil && ui.Button(c, s.t("backup_home")).FillWidth().Height(44).Disabled(s.busy != "").Clicked() {
		s.queueNavigation(s.showBackup)
	}
	ui.Field(c, s.t("language"), func() {
		value := s.language
		picker(c, &value, []choice{{"system", s.t("system")}, {"zh-Hans", s.t("chinese")}, {"en", s.t("english")}}, s.t("language"), s.busy != "")
		if value != s.language {
			s.changeLanguage(value)
		}
	}).FillWidth()
	ui.Text(c, s.t("privacy")).FontSize(11).TextColor(c.Theme().TextMuted)
	ui.Text(c, s.t("preview_scope")).FontSize(11).TextColor(c.Theme().TextMuted)
}

func (s *screen) list(c *ui.Context) {
	title := s.t("inbox")
	if s.memberID != "" {
		for _, member := range s.members {
			if member.ID == s.memberID {
				title = member.Name
			}
		}
	}
	ui.Column(c).Fill().Gap(16).Children(func() {
		ui.Text(c, title).FontSize(28).Bold().TextColor(c.Theme().Accent)
		if s.memberID != "" {
			ui.Text(c, s.t("timeline")).TextColor(c.Theme().TextMuted)
			ui.Row(c).Gap(10).Children(func() {
				field := ui.TextInput(c, &s.query).Label(s.t("search")).Placeholder(s.t("search")).Grow(1).Disabled(s.busy != "")
				if ui.Button(c, s.t("search_action")).Disabled(s.busy != "").Clicked() || field.Submitted() {
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
				ui.Text(c, s.t(key)).FontSize(22).Bold()
				if s.memberID == "" {
					ui.Text(c, s.t("empty_inbox_detail")).TextColor(c.Theme().TextMuted)
				}
			})
		} else {
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
				label := s.reportList.Label(i)
				button := ui.ButtonBase(c).Key(r.ID).FillWidth().Padding(18).Radius(10).Background(c.Theme().Surface).Border(1, c.Theme().Border).Label(label).Disabled(s.busy != "")
				if i == s.selectedReport {
					button.Background(c.Theme().SurfacePressed).Border(2, c.Theme().Accent)
				}
				button.Children(func() {
					ui.Column(c).Gap(8).Children(func() {
						ui.Text(c, label).FontSize(17).Bold().SingleLine()
						ui.Row(c).Gap(16).Children(func() {
							date := r.Review.Date
							if date == "" {
								date = s.t("unknown_date")
							}
							ui.Text(c, date).TextColor(c.Theme().TextMuted)
							ui.Text(c, s.t(statusKey(r.Status))).TextColor(c.Theme().Accent)
						})
					})
				})
				if button.Clicked() {
					s.open(r.ID)
				}
			}).Grow(1).MinHeight(0).Gap(10).Label(s.t(listLabel)).Disabled(s.busy != "")
			if list.Submitted() && s.selectedReport >= 0 && s.selectedReport < len(records) {
				s.open(records[s.selectedReport].ID)
			}
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
		ui.Row(c).Gap(16).AlignItems(ui.Center).Children(func() {
			if ui.Button(c, s.t("back")).Disabled(s.busy != "").Clicked() {
				s.queueNavigation(func() { s.clearReport(); s.message = ""; s.load(false) })
			}
			ui.Text(c, s.report.FileName).FontSize(18).Bold().Grow(1).SingleLine()
			ui.Text(c, s.t(statusKey(s.report.Status))).TextColor(c.Theme().Accent)
		})
		ui.Row(c).Grow(1).MinHeight(0).Gap(22).Children(func() {
			ui.Column(c).WidthPercent(43).FillHeight().Gap(12).Children(func() { s.original(c) })
			ui.Scroll(c).Grow(1).MinWidth(0).Children(func() {
				ui.Column(c).FillWidth().Gap(14).Padding(0, 4, 12, 0).Children(func() { s.review(c) })
			})
		})
	})
}

func (s *screen) original(c *ui.Context) {
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
}

func (s *screen) review(c *ui.Context) {
	confirmed := s.report.Status == "confirmed"
	readOnly := confirmed && !s.editingConfirmed
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
		if readOnly {
			ui.Row(c).Gap(8).Wrap().Children(func() {
				if ui.PrimaryButton(c, s.t("edit_record")).Clicked() {
					s.startEditing()
				}
				if ui.Button(c, s.t("export")).Clicked() {
					s.chooseExport()
				}
			})
		}
		if readOnly {
			memberName := ""
			for _, member := range s.members {
				if member.ID == s.edit.MemberID {
					memberName = member.Name
				}
			}
			ui.Text(c, memberName).Bold()
		} else {
			ui.Field(c, s.t("member"), func() {
				choices := []choice{{"", s.t("choose_member")}}
				for _, member := range s.members {
					choices = append(choices, choice{member.ID, member.Name})
				}
				picker(c, &s.edit.MemberID, choices, s.t("member"), false)
			}).FillWidth()
		}
		ui.Field(c, s.t("title"), func() {
			field := ui.TextInput(c, &s.edit.Title).ReadOnly(readOnly).FillWidth()
			s.composing = s.composing || field.Composing()
		}).FillWidth()
		ui.Field(c, s.t("date"), func() {
			field := ui.TextInput(c, &s.edit.Date).ReadOnly(readOnly).FillWidth().Placeholder(s.t("unknown_date"))
			s.composing = s.composing || field.Composing()
		}).Description(s.t("date_hint")).FillWidth()
		ui.Field(c, s.t("transcription"), func() {
			field := ui.TextArea(c, &s.edit.Text).ReadOnly(readOnly).Height(230).FillWidth()
			s.composing = s.composing || field.Composing()
		}).FillWidth()
		ui.Field(c, s.t("notes"), func() {
			field := ui.TextArea(c, &s.edit.Notes).ReadOnly(readOnly).Height(100).FillWidth()
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
		if readOnly && ui.Button(c, s.t("delete_report")).TextColor(c.Theme().Danger).Clicked() {
			s.deletePrompt = true
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
