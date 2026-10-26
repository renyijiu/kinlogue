package desktop

import (
	"fmt"
	"strings"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

func (s *screen) backupView(c *ui.Context) {
	ui.Scroll(c).Fill().Children(func() {
		ui.Column(c).FillWidth().MaxWidth(840).Gap(28).Padding(32, 40).Children(func() {
			title := "settings"
			if s.recoveryOnly {
				title = "recovery_title"
			}
			if s.restartOnly {
				title = "restore_restart_title"
			}
			ui.Column(c).Gap(8).Children(func() {
				ui.Text(c, s.t(title)).FontSize(30).Bold()
				if title == "settings" {
					ui.Text(c, s.t("settings_subtitle")).FontSize(17).TextColor(c.Theme().TextMuted)
				}
			})
			if s.restartOnly {
				ui.Text(c, s.t("restore_restart_detail"))
				s.quitButton(c)
				return
			}
			if s.recoveryOnly {
				ui.Text(c, s.t("recovery_help")).TextColor(c.Theme().TextMuted)
			}
			ui.Column(c).FillWidth().Gap(28).Disabled(s.busy != "" || s.backup.step != "").Children(func() {
				if !s.recoveryOnly {
					s.settingsSection(c, iconSliders, s.t("general"), func() {
						ui.Row(c).FillWidth().Gap(24).AlignItems(ui.Center).Children(func() {
							ui.Column(c).Grow(1).MinWidth(0).Gap(5).Children(func() {
								ui.Text(c, s.t("language")).Bold()
								ui.Text(c, s.t("language_hint")).TextColor(c.Theme().TextMuted)
							})
							ui.Column(c).Width(220).Shrink(0).AlignItems(ui.End).Children(func() {
								ui.Column(c).Width(160).Children(func() {
									value := s.language
									picker(c, &value, []choice{{"system", s.t("system")}, {"zh-Hans", s.t("chinese")}, {"en", s.t("english")}}, s.t("language_hint"), s.busy != "")
									if value != s.language {
										s.changeLanguage(value)
									}
								})
							})
						})
					})
				}
				if s.backups != nil {
					s.settingsSection(c, iconDrive, s.t("data_backup"), func() {
						ui.Column(c).FillWidth().Gap(14).Children(func() {
							ui.Row(c).FillWidth().Gap(24).Children(func() {
								ui.Column(c).Grow(1).MinWidth(0).Gap(5).Children(func() {
									ui.Text(c, s.t("backup_home")).Bold()
									ui.Text(c, s.t("backup_help")).TextColor(c.Theme().TextMuted)
								})
								if !s.recoveryOnly {
									ui.Column(c).Width(220).Shrink(0).AlignItems(ui.End).Children(func() {
										if ui.Button(c, s.t("backup_create")).Clicked() {
											s.startBackup()
											c.Invalidate()
										}
									})
								}
							})
							divider(c, false)
							ui.Row(c).FillWidth().Justify(ui.End).Children(func() {
								if ui.Button(c, s.t("restore_choose")).Clicked() {
									s.chooseRestoreFile()
								}
							})
						})
					})
				}
				if !s.recoveryOnly {
					ui.Column(c).Gap(4).Children(func() {
						ui.Text(c, s.t("privacy")).FontSize(12).TextColor(c.Theme().TextMuted)
						ui.Text(c, s.t("preview_scope")).FontSize(12).TextColor(c.Theme().TextMuted)
					})
				}
			})
			if s.recoveryOnly {
				s.quitButton(c)
			}
		})
	})
}

func (s *screen) backupSheet(c *ui.Context) {
	if s.backup.step == "" || s.restartOnly {
		return
	}
	open := true
	_, h := c.Size()
	restoring := s.backup.step == "restore_code" || s.backup.step == "preparing" || s.backup.step == "prepared" || s.activating
	panel := ui.Modal(c, &open, func() {
		ui.Column(c.Key(s.backup.generation)).FillWidth().Gap(18).Children(func() {
			title := "backup_code_title"
			if restoring {
				title = "restore_sheet_title"
			}
			ui.Text(c, s.t(title)).FontSize(21).Bold()
			ui.Scroll(c).FillWidth().MaxHeight(max(160, h-220)).Children(func() {
				ui.Column(c).FillWidth().Gap(18).Children(func() {
					switch {
					case s.activating:
						ui.Text(c, s.t("restore_activating_detail")).TextColor(c.Theme().TextMuted)
					case s.busy != "":
						key := s.busy
						if s.cancelling {
							key = "cancelling"
						}
						ui.Spinner(c).Label(s.t(key))
						ui.Text(c, s.t(key))
					case s.backup.step == "generated":
						ui.Text(c, s.t("backup_code_warning")).TextColor(c.Theme().TextMuted)
						var parts []string
						for code := s.backup.code; code != ""; {
							n := min(48, len(code))
							parts = append(parts, code[:n])
							code = code[n:]
						}
						ui.Text(c, strings.Join(parts, "\n")).FontSize(14).FillWidth().Padding(14).Background(c.Theme().Background).Border(1, c.Theme().Border).Radius(10)
						ui.Text(c, s.t("backup_id", s.backup.publicID)).FontSize(12).TextColor(c.Theme().TextMuted)
						if ui.Button(c, s.t("backup_copy")).Clicked() {
							c.WriteClipboard(s.backup.code)
						}
					case s.backup.step == "reentry":
						ui.Text(c, s.t("backup_reentry_help")).TextColor(c.Theme().TextMuted)
						s.codeEditor(c, "backup_reentry")
					case s.backup.step == "restore_code":
						ui.Text(c, s.t("restore_code_help")).TextColor(c.Theme().TextMuted)
						s.codeEditor(c, "restore_code")
						if ui.PrimaryButton(c, s.t("restore_validate")).AlignSelf(ui.Start).Disabled(strings.TrimSpace(s.backup.input) == "" || s.composing).Clicked() {
							s.prepareRestore()
						}
					case s.backup.step == "prepared" && s.backup.prepared != nil:
						s.restoreSummary(c)
						ui.Row(c).FillWidth().Gap(8).AlignItems(ui.Start).Children(func() {
							warning := ui.Hex("#B8661F")
							icon(c, iconWarning, 16, warning)
							ui.Text(c, s.t("restore_replace_warning")).TextColor(warning).Grow(1).MinWidth(0)
						})
						if ui.Button(c, s.t("restore_replace")).AlignSelf(ui.Start).TextColor(c.Theme().Danger).Clicked() {
							s.activateRestore()
							c.Invalidate()
						}
					}
					if s.message != "" {
						ui.Text(c, s.t(s.message)).TextColor(c.Theme().Danger)
					}
				})
			})
			ui.Row(c).FillWidth().Gap(12).AlignItems(ui.Center).Children(func() {
				if restoring {
					ui.Box(c).Grow(1)
				}
				if s.busy == "" {
					if ui.Button(c, s.t("cancel")).Clicked() {
						s.cancelBackup()
						c.Invalidate()
					}
				} else if s.cancellable && !s.activating {
					if ui.Button(c, s.t("cancel_task")).Disabled(s.cancelling).Clicked() {
						s.cancelling = true
						s.jobCancel()
					}
				}
				if restoring {
					return
				}
				ui.Box(c).Grow(1)
				if s.busy != "" {
					return
				}
				switch s.backup.step {
				case "generated":
					if ui.PrimaryButton(c, s.t("backup_saved_code")).Clicked() {
						s.acknowledgeCode()
						c.Invalidate()
					}
				case "reentry":
					if ui.PrimaryButton(c, s.t("backup_choose_destination")).Disabled(!s.codeMatches() || s.composing).Clicked() {
						s.chooseBackupDestination()
					}
				}
			})
		})
	})
	if panel.Valid() {
		w, _ := c.Size()
		panel.Width(min(540, w-40)).Padding(28).Background(c.Theme().Surface).Label(s.t("data_backup"))
	}
	// Backup enrollment requires the explicit Cancel action; dismissing the
	// backdrop must not silently throw away an unsaved recovery code or stage.
}

func (s *screen) restoreSummary(c *ui.Context) {
	summary := s.backup.prepared.Summary
	ui.Column(c).FillWidth().Padding(14).Gap(8).Background(c.Theme().Background).Radius(10).Children(func() {
		ui.Text(c, s.t("restore_validated")).Bold()
		for _, row := range []struct{ key, value string }{
			{"restore_summary_members", fmt.Sprint(summary.Members)},
			{"restore_summary_reports", fmt.Sprint(summary.Reports)},
			{"restore_summary_sources", fmt.Sprint(summary.Sources)},
			{"restore_summary_inbox", fmt.Sprint(summary.Inbox)},
			{"restore_summary_bytes", s.formatBytes(summary.OriginalBytes)},
		} {
			ui.Row(c).FillWidth().Gap(12).Children(func() {
				ui.Text(c, s.t(row.key)).Grow(1).TextColor(c.Theme().TextMuted)
				ui.Text(c, row.value)
			})
		}
	})
}

func (s *screen) codeEditor(c *ui.Context, label string) {
	ui.Field(c, s.t(label), func() {
		field := ui.TextInput(c, &s.backup.input).Password().FillWidth().AutoFocus()
		s.composing = s.composing || field.Composing()
	}).FillWidth()
}

func (s *screen) quitButton(c *ui.Context) {
	if ui.Button(c, s.t("quit")).Clicked() {
		s.queueShutdown(func() { s.allowClose = true; s.stop(); mygo.App.Quit() })
	}
}

// settingsSection is a Swift settings group: a Primary section label above a
// white card with an outline.
func (s *screen) settingsSection(c *ui.Context, glyph *ui.SVG, title string, content func()) {
	ui.Column(c).FillWidth().Gap(12).Children(func() {
		ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
			icon(c, glyph, 20, c.Theme().Accent)
			ui.Text(c, title).FontSize(21).Bold().TextColor(c.Theme().Accent)
		})
		ui.Column(c).FillWidth().Padding(22).Background(c.Theme().Surface).Border(1, c.Theme().Border).Radius(14).Children(content)
	})
}
