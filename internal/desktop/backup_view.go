package desktop

import (
	"strings"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

func (s *screen) backupView(c *ui.Context) {
	ui.Scroll(c).Fill().Children(func() {
		ui.Column(c).FillWidth().MaxWidth(760).Gap(28).Padding(4).Children(func() {
			title := "settings"
			if s.recoveryOnly {
				title = "recovery_title"
			}
			if s.restartOnly {
				title = "restore_restart_title"
			}
			ui.Column(c).Gap(8).Children(func() {
				ui.Text(c, s.t(title)).FontSize(30).Bold()
				if title == "settings" && s.backup.step == "" && !s.activating {
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
			if s.activating {
				ui.Text(c, s.t("restore_activating_detail"))
				return
			}
			ui.Column(c.Key(s.backup.generation)).FillWidth().Gap(16).Disabled(s.busy != "").Children(func() {
				switch s.backup.step {
				case "":
					if !s.recoveryOnly {
						s.settingsSection(c, iconSliders, s.t("general"), func() {
							ui.Row(c).FillWidth().Gap(24).AlignItems(ui.Center).Children(func() {
								ui.Column(c).Grow(1).MinWidth(0).Gap(5).Children(func() {
									ui.Text(c, s.t("language")).Bold()
									ui.Text(c, s.t("language_hint")).TextColor(c.Theme().TextMuted)
								})
								ui.Column(c).Width(220).Shrink(0).Children(func() {
									value := s.language
									picker(c, &value, []choice{{"system", s.t("system")}, {"zh-Hans", s.t("chinese")}, {"en", s.t("english")}}, s.t("language_hint"), s.busy != "")
									if value != s.language {
										s.changeLanguage(value)
									}
								})
							})
						})
					}
					if s.backups != nil {
						s.settingsSection(c, iconDrive, s.t("data_backup"), func() {
							ui.Row(c).FillWidth().Gap(24).Children(func() {
								ui.Column(c).Grow(1).MinWidth(0).Gap(6).Children(func() {
									ui.Text(c, s.t("backup_home")).Bold()
									ui.Text(c, s.t("backup_help")).TextColor(c.Theme().TextMuted)
								})
								ui.Column(c).Width(220).Shrink(0).Gap(10).Children(func() {
									if !s.recoveryOnly && ui.PrimaryButton(c, s.t("backup_create")).FillWidth().Clicked() {
										s.startBackup()
										c.Invalidate()
									}
									if ui.Button(c, s.t("restore_choose")).FillWidth().Clicked() {
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
				case "generated":
					ui.Text(c, s.t("backup_code_title")).FontSize(21).Bold()
					ui.Text(c, s.t("backup_id", s.backup.publicID)).TextColor(c.Theme().TextMuted)
					ui.Text(c, s.t("backup_code_warning"))
					// Break the long identity for display; Copy always uses the exact code.
					parts := []string{}
					for code := s.backup.code; code != ""; {
						n := min(48, len(code))
						parts = append(parts, code[:n])
						code = code[n:]
					}
					ui.Text(c, strings.Join(parts, "\n")).FontSize(14)
					if ui.Button(c, s.t("backup_copy")).Clicked() {
						c.WriteClipboard(s.backup.code)
					}
					if ui.PrimaryButton(c, s.t("backup_saved_code")).Clicked() {
						s.acknowledgeCode()
						c.Invalidate()
					}
				case "reentry":
					ui.Text(c, s.t("backup_reentry_help"))
					s.codeEditor(c, "backup_reentry")
					if ui.PrimaryButton(c, s.t("backup_choose_destination")).Disabled(!s.codeMatches() || s.composing).Clicked() {
						s.chooseBackupDestination()
					}
				case "restore_code":
					ui.Text(c, s.t("restore_code_help"))
					s.codeEditor(c, "restore_code")
					if ui.PrimaryButton(c, s.t("restore_validate")).Disabled(strings.TrimSpace(s.backup.input) == "" || s.composing).Clicked() {
						s.prepareRestore()
					}
				case "prepared":
					if prepared := s.backup.prepared; prepared != nil {
						ui.Text(c, s.t("restore_validated")).FontSize(21).Bold()
						ui.Text(c, s.t("restore_summary", prepared.Summary.Members, prepared.Summary.Reports, prepared.Summary.Sources))
						ui.Text(c, s.t("restore_inbox", prepared.Summary.Inbox))
						ui.Text(c, s.t("restore_bytes", prepared.Summary.OriginalBytes))
						ui.Text(c, s.t("restore_replace_warning")).TextColor(c.Theme().Danger)
						if ui.Button(c, s.t("restore_replace")).TextColor(c.Theme().Danger).Height(44).Clicked() {
							s.activateRestore()
							c.Invalidate()
						}
					}
				}
				if s.backup.step != "" && s.busy == "" {
					if ui.Button(c, s.t("cancel")).Clicked() {
						s.cancelBackup()
						c.Invalidate()
					}
				}
			})
			if s.recoveryOnly {
				s.quitButton(c)
			}
		})
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
