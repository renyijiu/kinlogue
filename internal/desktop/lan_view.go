package desktop

import (
	"fmt"
	"slices"

	"github.com/egoist/mygo/ui"
	"kinlogue/internal/library"
)

func (s *screen) phoneView(c *ui.Context) {
	ui.Column(c).Fill().Padding(20).Gap(12).Children(func() {
		ui.Text(c, s.t("phone_uploads")).FontSize(24).Bold()
		ui.Text(c, s.t("phone_help")).TextColor(c.Theme().TextMuted)
		ui.Column(c).FillWidth().Gap(8).Padding(12).Background(c.Theme().Surface).Radius(10).Children(func() {
			if s.phone.status.Active {
				s.phoneActive(c)
			} else {
				ui.Text(c, s.t("phone_private_only")).Bold()
				ui.Text(c, s.t("phone_plain_http")).FontSize(12).TextColor(c.Theme().TextMuted)
				options := make([]choice, 0, len(s.phone.interfaces))
				for _, i := range s.phone.interfaces {
					options = append(options, choice{phoneInterfaceID(i), fmt.Sprintf("%s · %s", i.Name, i.Address)})
				}
				picker(c, &s.phone.interfaceID, options, s.t("phone_interface"), s.busy != "" || s.phone.stopping)
				if len(options) == 0 {
					ui.Text(c, s.t("phone_no_interface"))
				}
				if !s.phone.lifecycleReady {
					ui.Text(c, s.t("phone_lifecycle_unavailable"))
				}
				ui.Checkbox(c, &s.phone.trusted, s.t("phone_trusted"))
			}
			ui.Row(c).Gap(8).Children(func() {
				if ui.Button(c, s.t("phone_start")).Disabled(s.busy != "" || s.phone.status.Active || s.phone.stopping || !s.phone.trusted || !s.phone.lifecycleReady || len(s.phone.interfaces) == 0).Clicked() {
					s.startPhone()
				}
				if ui.Button(c, s.t("phone_stop")).Disabled(!s.phone.status.Active || s.phone.stopping).Clicked() {
					s.stopPhone()
				}
				if ui.Button(c, s.t("phone_refresh")).Disabled(s.phone.refreshing || s.busy != "").Clicked() {
					s.refreshPhone()
				}
			})
		})
		ui.Row(c).FillWidth().Grow(1).MinHeight(180).Gap(16).Children(func() {
			ui.Column(c).WidthPercent(48).FillHeight().Gap(8).Children(func() {
				ui.Text(c, s.t("phone_queue", len(s.phone.items))).Bold()
				if len(s.phone.items) == 0 {
					ui.Text(c, s.t("phone_empty"))
					return
				}
				s.phone.list.Key = func(i int) any { return s.phone.items[i].ID }
				s.phone.list.Label = func(i int) string { return s.phone.items[i].FileName }
				ui.List(c, &s.phone.list, len(s.phone.items), func(i int) {
					item := s.phone.items[i]
					ui.Column(c).FillWidth().Padding(10).Gap(6).Children(func() {
						ui.Text(c, item.FileName).SingleLine().Bold()
						ui.Text(c, s.t(phoneStatusKey(item.Status))).FontSize(12).TextColor(c.Theme().TextMuted)
						ui.Row(c).Gap(6).Wrap().Children(func() {
							selected := slices.ContainsFunc(s.phone.selected, func(v library.InboxSelection) bool { return v.ID == item.ID })
							label := "phone_select"
							if selected {
								label = "phone_unselect"
							}
							if ui.Button(c, s.t(label)).Disabled(s.busy != "" || item.Status != "reviewable").Clicked() {
								s.togglePhoneItem(item)
							}
							if ui.Button(c, s.t("phone_preview")).Disabled(s.busy != "" || item.Status != "reviewable").Clicked() {
								s.previewPhone(item, 1)
							}
							if ui.Button(c, s.t("phone_retry")).Disabled(s.busy != "" || item.Status == "processing" || item.Status == "reviewable").Clicked() {
								s.retryPhone(item)
							}
							if ui.Button(c, s.t("phone_delete")).Disabled(s.busy != "" || item.Status == "processing").Clicked() {
								s.phone.deleteSelection = []library.InboxSelection{{ID: item.ID, Revision: item.Revision}}
							}
						})
					})
				}).FillWidth().Grow(1).MinHeight(120)
			})
			ui.Scroll(c).Grow(1).MinWidth(0).FillHeight().Children(func() {
				ui.Column(c).FillWidth().Gap(10).Children(func() {
					ui.Text(c, s.t("phone_selection", len(s.phone.selected))).Bold()
					for index, selected := range s.phone.selected {
						name := ""
						for _, item := range s.phone.items {
							if item.ID == selected.ID {
								name = item.FileName
								break
							}
						}
						ui.Row(c).Key(selected.ID).FillWidth().Gap(6).Children(func() {
							ui.Text(c, s.t("source_item", index+1, name)).Grow(1).MinWidth(0).SingleLine()
							if ui.Button(c, s.t("source_up")).Disabled(s.busy != "" || index == 0).Clicked() {
								s.movePhoneItem(index, -1)
							}
							if ui.Button(c, s.t("source_down")).Disabled(s.busy != "" || index == len(s.phone.selected)-1).Clicked() {
								s.movePhoneItem(index, 1)
							}
						})
					}
					if len(s.phone.selected) > 0 {
						if ui.Button(c, s.t("phone_delete_selected")).TextColor(c.Theme().Danger).Disabled(s.busy != "").Clicked() {
							s.promptDeleteSelectedPhone()
						}
					}
					options := make([]choice, 0, len(s.members))
					for _, member := range s.members {
						options = append(options, choice{member.ID, member.Name})
					}
					ui.Field(c, s.t("member"), func() { picker(c, &s.phone.memberID, options, s.t("member"), s.busy != "") }).FillWidth()
					ui.Field(c, s.t("title"), func() {
						e := ui.TextInput(c, &s.phone.title).FillWidth().Disabled(s.busy != "")
						s.composing = s.composing || e.Composing()
					}).FillWidth()
					ui.Field(c, s.t("date"), func() {
						e := ui.TextInput(c, &s.phone.date).FillWidth().Disabled(s.busy != "")
						s.composing = s.composing || e.Composing()
					}).FillWidth()
					ui.Text(c, s.t("phone_archive_help")).FontSize(12).TextColor(c.Theme().TextMuted)
					if ui.Button(c, s.t("phone_archive")).Disabled(s.busy != "" || len(s.phone.selected) == 0 || s.phone.memberID == "").Clicked() {
						s.archivePhone()
					}
					if s.phone.preview.ID != "" {
						ui.Text(c, s.phone.preview.FileName).SingleLine().Bold()
						ui.Text(c, s.t("page", s.phone.page, s.phone.preview.Extraction.PageCount))
						if s.phone.bitmap != nil {
							ui.Image(c, s.phone.bitmap).Label(s.t("original")).FillWidth().Height(260).Fit(ui.Contain)
						}
						ui.Row(c).Gap(8).Children(func() {
							if ui.Button(c, s.t("previous_page")).Disabled(s.busy != "" || s.phone.page <= 1).Clicked() {
								s.previewPhone(s.phone.preview, s.phone.page-1)
							}
							if ui.Button(c, s.t("next_page")).Disabled(s.busy != "" || s.phone.page >= s.phone.preview.Extraction.PageCount).Clicked() {
								s.previewPhone(s.phone.preview, s.phone.page+1)
							}
						})
					}
				})
			})
		})
	})
}
func phoneStatusKey(status string) string {
	switch status {
	case "stored":
		return "phone_stored"
	case "processing":
		return "phone_processing"
	case "reviewable":
		return "phone_ready"
	case "unsupported":
		return "unsupported"
	default:
		return "phone_failed"
	}
}
func (s *screen) phoneDialogs(c *ui.Context) {
	if len(s.phone.deleteSelection) == 0 {
		return
	}
	open := true
	ui.Modal(c, &open, func() {
		ui.Text(c, s.t("phone_delete_title", len(s.phone.deleteSelection))).FontSize(20).Bold()
		ui.Text(c, s.t("phone_delete_help"))
		ui.Row(c).Gap(8).Children(func() {
			if ui.Button(c, s.t("cancel")).Clicked() {
				s.phone.deleteSelection = nil
			}
			if ui.Button(c, s.t("phone_delete")).Clicked() {
				s.deletePhone()
			}
		})
	})
	if !open {
		s.phone.deleteSelection = nil
	}
}

// phoneActive mirrors the Swift receiver sheet: an address QR code (without the
// pairing code), the URL with a copy action, the one-time code and the
// troubleshooting note about guest isolation and the macOS firewall.
func (s *screen) phoneActive(c *ui.Context) {
	ui.Row(c).FillWidth().Gap(22).Children(func() {
		if bitmap := s.phoneQR(s.phone.status.Address); bitmap != nil {
			ui.Image(c, bitmap).Label(s.t("phone_qr_label")).Size(190, 190).Shrink(0).Fit(ui.Contain)
		}
		ui.Column(c).Grow(1).MinWidth(0).Gap(8).Children(func() {
			ui.Text(c, s.t("phone_receiving")).Bold().TextColor(c.Theme().Accent)
			ui.Text(c, s.t("phone_open_in_browser")).TextColor(c.Theme().TextMuted)
			ui.Text(c, s.phone.status.Address).Font("monospace").Bold().Selectable()
			ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
				if ui.Button(c, s.t("phone_copy_address")).Clicked() {
					s.copyPhoneAddress()
				}
				if s.phone.copied {
					ui.Text(c, s.t("phone_address_copied")).FontSize(12).TextColor(c.Theme().TextMuted)
				}
			})
			ui.Divider(c)
			if s.phone.status.Code == "" {
				ui.Text(c, s.t("phone_paired")).Bold()
			} else {
				ui.Text(c, s.t("phone_code_title")).TextColor(c.Theme().TextMuted)
				ui.Text(c, s.phone.status.Code).Font("monospace").FontSize(32).Bold().Label(s.t("phone_code_label", spacedDigits(s.phone.status.Code)))
				ui.Text(c, s.t("phone_code_help")).FontSize(12).TextColor(c.Theme().TextMuted)
			}
			ui.Text(c, s.t("phone_troubleshoot")).FontSize(12)
		})
	})
}

func spacedDigits(code string) string {
	out := make([]rune, 0, 2*len(code))
	for i, r := range code {
		if i > 0 {
			out = append(out, ' ')
		}
		out = append(out, r)
	}
	return string(out)
}
