package desktop

import (
	"fmt"
	"time"

	"github.com/egoist/mygo/ui"
	"kinlogue/internal/library"
)

// phoneQueue is the Swift LANInboxView: header with the receive action, the
// pending list, and the archive bar at the bottom.
func (s *screen) phoneQueue(c *ui.Context) {
	s.ensurePhoneDate()
	ui.Column(c).Fill().Gap(0).Children(func() {
		ui.Column(c).FillWidth().Padding(16).Gap(10).Children(func() {
			ui.Row(c).FillWidth().Gap(10).AlignItems(ui.Center).Children(func() {
				ui.Column(c).Grow(1).MinWidth(0).Gap(3).Children(func() {
					ui.Text(c, s.t("phone_queue_title")).FontSize(20).Bold()
					if len(s.phone.items) > 0 {
						var total int64
						for _, item := range s.phone.items {
							total += item.ByteCount
						}
						ui.Text(c, s.t("phone_queue_summary", len(s.phone.items), s.formatBytes(total))).FontSize(12).TextColor(c.Theme().TextMuted)
					}
				})
				label := s.t("phone_receive")
				if s.phone.status.Active {
					label = s.t("phone_receiving")
				}
				if ui.PrimaryButton(c, label).Disabled(s.busy != "" || s.phone.stopping).Clicked() {
					s.openReceiver()
				}
			})
			if n := s.phone.notice; n != nil {
				ui.Row(c).FillWidth().Padding(10).Gap(8).AlignItems(ui.Center).Background(tokenContainer).Radius(9).Children(func() {
					icon(c, iconCheck, 16, c.Theme().Accent)
					key := "phone_notice_added"
					if n.duplicate {
						key = "phone_notice_duplicate"
					}
					ui.Text(c, s.t(key)).FontSize(13).Grow(1).MinWidth(0).MaxLines(2)
					if n.duplicate && ui.Button(c, s.t("phone_view_existing")).Clicked() {
						s.openPhoneDuplicate()
					}
					close := ui.ButtonBase(c).Label(s.t("phone_notice_close")).Padding(4).Radius(6)
					close.Children(func() { icon(c, iconClear, 14, c.Theme().TextMuted) })
					if close.Clicked() {
						s.phone.notice = nil
					}
				})
			}
			for _, key := range []string{"phone_load_failed", "phone_archive_failed", "phone_retry_failed", "phone_delete_failed", "phone_selection_changed"} {
				if s.message == key {
					ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
						icon(c, iconWarning, 14, tokenDanger)
						ui.Text(c, s.t(key)).FontSize(12).TextColor(tokenDanger).MaxLines(2)
					})
				}
			}
		})
		divider(c, false)
		if len(s.phone.items) == 0 {
			ui.Column(c).Grow(1).FillWidth().Center().Padding(24).Gap(10).Children(func() {
				icon(c, iconTray, 34, c.Theme().TextMuted)
				ui.Text(c, s.t("phone_empty")).FontSize(17).Bold()
				ui.Text(c, s.t("phone_empty_detail")).TextColor(c.Theme().TextMuted)
				if ui.PrimaryButton(c, s.t("phone_receive")).Disabled(s.busy != "").Clicked() {
					s.openReceiver()
				}
			})
			return
		}
		s.phone.list.Key = func(i int) any { return s.phone.items[i].ID }
		s.phone.list.Label = func(i int) string { return s.phone.items[i].FileName }
		ui.List(c, &s.phone.list, len(s.phone.items), func(i int) {
			s.phoneRow(c, s.phone.items[i])
		}).FillWidth().Grow(1).MinHeight(120)
		s.phoneArchiveBar(c)
	})
}

func (s *screen) phoneRow(c *ui.Context, item library.InboxItem) {
	selected := s.phoneSelected(item.ID)
	background := c.Theme().Background
	if selected {
		background = tokenContainer
	}
	ui.Row(c).FillWidth().Padding(2, 8).AlignItems(ui.Center).Background(background).Children(func() {
		row := ui.ButtonBase(c.Key(item.ID)).Label(s.t("phone_row_label", item.FileName, s.t(phoneStatusKey(item.Status)))).Selected(selected).Background(background).TextColor(c.Theme().Text).Grow(1).MinWidth(0).Padding(8).Radius(8).Gap(10).AlignItems(ui.Center).Disabled(s.busy != "" || item.Status != "reviewable")
		if !selected && row.Hovered() && item.Status == "reviewable" {
			row.Background(tokenHover)
		}
		row.Children(func() {
			glyph, color := phoneStatusIcon(item.Status), c.Theme().TextMuted
			switch item.Status {
			case "reviewable":
				color = c.Theme().Accent
			case "failed":
				color = tokenDanger
			case "unsupported":
				color = ui.Hex("#B8661F")
			}
			icon(c, glyph, 18, color)
			ui.Column(c).Grow(1).MinWidth(0).Gap(3).Children(func() {
				ui.Text(c, item.FileName).TextColor(c.Theme().Text).MaxLines(2)
				ui.Text(c, s.t(phoneStatusKey(item.Status))+"  "+s.formatBytes(item.ByteCount)+"  "+s.formatReceived(item.CreatedAt)).FontSize(11).TextColor(c.Theme().TextMuted).SingleLine()
			})
		})
		if row.Clicked() {
			s.selectPhoneItem(item, row.ClickModifiers())
		}
		if item.Status == "reviewable" && s.iconButton(c, iconEye, s.t("phone_preview_item", item.FileName), s.busy != "") {
			s.showPhoneOriginal(item.ID)
		}
		if (item.Status == "stored" || item.Status == "failed" || item.Status == "unsupported") && s.iconButton(c, iconRetry, s.t("phone_retry_item", item.FileName), s.busy != "") {
			s.retryPhone(item)
		}
		del := ui.ButtonBase(c).Label(s.t("phone_delete_item", item.FileName)).Tooltip(s.t("phone_delete_item", item.FileName)).Padding(5).Radius(6).Disabled(s.busy != "" || item.Status == "processing")
		del.Children(func() { icon(c, iconTrash, 15, tokenDanger) })
		if del.Clicked() {
			s.promptDeletePhoneItem(item)
		}
	})
}

func (s *screen) phoneArchiveBar(c *ui.Context) {
	divider(c, false)
	ui.Column(c).FillWidth().Gap(10).Padding(12).Background(tokenContainer).Children(func() {
		ui.Row(c).FillWidth().Gap(10).AlignItems(ui.Center).Children(func() {
			ui.Text(c, s.t("phone_selected_summary", len(s.phone.selected))).TextColor(c.Theme().TextMuted).Grow(1).MinWidth(0).MaxLines(2)
			if ui.Button(c, s.t("phone_delete_selected")).TextColor(tokenDanger).Disabled(s.busy != "" || len(s.phone.selected) == 0).Clicked() {
				s.promptDeleteSelectedPhone()
			}
		})
		options := []choice{{"", s.t("phone_choose_member")}}
		for _, member := range s.members {
			options = append(options, choice{member.ID, member.Name})
		}
		ui.Field(c, s.t("phone_file_for"), func() { picker(c, &s.phone.memberID, options, s.t("phone_file_for"), s.busy != "") }).FillWidth()
		ui.Field(c, s.t("phone_report_date"), func() {
			date, _ := time.Parse("2006-01-02", s.phone.date)
			if ui.DateInput(c, &date).Label(s.t("phone_report_date")).Disabled(s.busy != "").Changed() {
				s.phone.date = date.Format("2006-01-02")
			}
		}).FillWidth()
		ui.Row(c).FillWidth().Children(func() {
			ui.Box(c).Grow(1)
			if ui.PrimaryButton(c, s.t("phone_archive")).Disabled(s.busy != "" || len(s.phone.selected) == 0 || s.phone.memberID == "").Clicked() {
				s.archivePhone()
			}
		})
	})
}

// phoneSelection is the Swift LANPendingSelectionDetailView: the report
// page order and a full preview of one selected original.
func (s *screen) phoneSelection(c *ui.Context) {
	if len(s.phone.selected) == 0 {
		ui.Column(c).Fill().Center().Padding(24).Gap(10).Children(func() {
			icon(c, iconList, 34, c.Theme().TextMuted)
			ui.Text(c, s.t("phone_select_title")).FontSize(17).Bold()
			ui.Text(c, s.t("phone_select_detail")).TextColor(c.Theme().TextMuted)
		})
		return
	}
	ui.Scroll(c).Fill().Children(func() {
		ui.Column(c).FillWidth().Padding(24).Gap(18).Children(func() {
			ui.Column(c).Gap(4).Children(func() {
				ui.Text(c, s.t("phone_as_one_report")).FontSize(21).Bold()
				ui.Text(c, s.t("phone_order_summary", len(s.phone.selected))).TextColor(c.Theme().TextMuted)
			})
			divider(c, false)
			ui.Text(c, s.t("phone_page_order")).Bold()
			for index, selected := range s.phone.selected {
				item, _ := s.phoneItem(selected.ID)
				row := ui.Row(c.Key(selected.ID)).FillWidth().Gap(12).AlignItems(ui.Center).Padding(6, 8).Radius(8)
				if s.phone.preview.ID == selected.ID {
					row.Background(tokenContainer)
				}
				row.Children(func() {
					ui.Text(c, fmt.Sprint(index+1)).FontSize(12).TextColor(c.Theme().TextMuted).Width(24)
					background := c.Theme().Background
					if s.phone.preview.ID == selected.ID {
						background = tokenContainer
					}
					b := ui.ButtonBase(c).Label(s.t("phone_view_original", index+1)).Selected(s.phone.preview.ID == selected.ID).Background(background).TextColor(c.Theme().Text).Grow(1).MinWidth(0).Padding(4, 6).Radius(6).Disabled(s.busy != "")
					b.Children(func() {
						ui.Column(c).FillWidth().Gap(3).Children(func() {
							ui.Text(c, item.FileName).TextColor(c.Theme().Text).SingleLine()
							ui.Text(c, s.formatBytes(item.ByteCount)).FontSize(11).TextColor(c.Theme().TextMuted)
						})
					})
					if b.Clicked() {
						s.previewPhone(item, 1)
					}
					if s.iconButton(c, iconEye, s.t("phone_preview_item", item.FileName), s.busy != "") {
						s.showPhoneOriginal(item.ID)
					}
					if s.iconButton(c, iconUp, s.t("phone_move_forward", item.FileName), s.busy != "" || index == 0) {
						s.movePhoneItem(index, -1)
					}
					if s.iconButton(c, iconDown, s.t("phone_move_backward", item.FileName), s.busy != "" || index == len(s.phone.selected)-1) {
						s.movePhoneItem(index, 1)
					}
				})
				if index < len(s.phone.selected)-1 {
					divider(c, false)
				}
			}
			divider(c, false)
			if s.phone.preview.ID != "" {
				ui.Row(c).FillWidth().Gap(8).AlignItems(ui.Center).Children(func() {
					ui.Text(c, s.t("phone_full_preview")).Bold().Grow(1)
					for i, sel := range s.phone.selected {
						if sel.ID == s.phone.preview.ID {
							ui.Text(c, s.t("phone_item_of", i+1, len(s.phone.selected))).FontSize(12).TextColor(c.Theme().TextMuted)
						}
					}
				})
				s.phonePreview(c)
				divider(c, false)
			}
			ui.Text(c, s.t("phone_archive_help")).FontSize(12).TextColor(c.Theme().TextMuted)
		})
	})
}

// receiverSheet is the Swift LANReceiverSheet.
func (s *screen) receiverSheet(c *ui.Context) {
	if !s.phone.receiverOpen || s.phoneBackend == nil {
		return
	}
	open := true
	ui.Modal(c, &open, func() {
		// The sheet owns its default action before a focused checkbox can
		// interpret Return as toggling the trusted-network acknowledgement.
		startRequested := c.Shortcut(0, ui.KeyEnter)
		ui.Column(c).FillWidth().Gap(18).Disabled(s.modalOpen()).Children(func() {
			ui.Row(c).FillWidth().Gap(10).AlignItems(ui.Center).Children(func() {
				icon(c, iconPhone, 22, c.Theme().Text)
				ui.Text(c, s.t("phone_receive_title")).FontSize(21).Bold().Grow(1).MinWidth(0)
				if s.phone.status.Active {
					ui.Row(c).Gap(6).AlignItems(ui.Center).Label(s.t("phone_receiving_a11y")).Children(func() {
						icon(c, iconWaves, 16, c.Theme().Accent)
						ui.Text(c, s.t("phone_receiving_status")).TextColor(c.Theme().Accent)
					})
				}
			})
			if s.phone.status.Active {
				s.phoneActive(c)
			} else {
				s.phoneStart(c)
			}
			for _, key := range []string{"phone_start_failed", "phone_no_interface"} {
				if s.message == key {
					ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
						icon(c, iconWarning, 15, tokenDanger)
						ui.Text(c, s.t(key)).FontSize(13).TextColor(tokenDanger)
					})
				}
			}
			divider(c, false)
			ui.Row(c).FillWidth().Gap(8).AlignItems(ui.Center).Children(func() {
				canClose := !s.phone.stopping && s.busy != "phone_starting"
				if ui.Button(c, s.t("close")).Disabled(!canClose).Clicked() || (canClose && c.Shortcut(0, ui.KeyEscape)) {
					s.closeReceiver()
				}
				ui.Box(c).Grow(1)
				if s.phone.status.Active {
					if ui.Button(c, s.t("phone_stop")).TextColor(tokenDanger).Tooltip(s.t("phone_stop_hint")).Disabled(s.phone.stopping).Clicked() {
						s.stopPhone()
					}
				} else {
					ready := s.busy == "" && !s.phone.stopping && s.phone.trusted && s.phone.lifecycleReady && s.phone.interfaceID != "" && !s.composing
					if ui.PrimaryButton(c, s.t("phone_start")).Disabled(!ready).Clicked() || (ready && startRequested) {
						s.startPhone()
					}
				}
			})
		})
	}).Width(620).Padding(26).Label(s.t("phone_receive_title"))
	if !open && !s.phone.stopping && s.busy != "phone_starting" {
		s.closeReceiver()
	}
}

func (s *screen) phoneStart(c *ui.Context) {
	ui.Column(c).FillWidth().Gap(14).Padding(16).Background(c.Theme().Surface).Border(1, c.Theme().Border).Radius(12).Children(func() {
		ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
			icon(c, iconShield, 18, c.Theme().Text)
			ui.Text(c, s.t("phone_private_only")).Bold()
		})
		ui.Text(c, s.t("phone_plain_http"))
		switch len(s.phone.interfaces) {
		case 0:
			ui.Text(c, s.t("phone_no_interface")).TextColor(c.Theme().TextMuted)
		case 1:
			i := s.phone.interfaces[0]
			ui.Row(c).FillWidth().Gap(12).Children(func() {
				ui.Text(c, s.t("phone_interface")).TextColor(c.Theme().TextMuted)
				ui.Text(c, fmt.Sprintf("%s · %s", i.Address, i.Name)).Selectable()
			})
		default:
			options := []choice{{"", s.t("phone_choose")}}
			for _, i := range s.phone.interfaces {
				options = append(options, choice{phoneInterfaceID(i), fmt.Sprintf("%s · %s", i.Address, i.Name)})
			}
			ui.Field(c, s.t("phone_interface"), func() {
				picker(c, &s.phone.interfaceID, options, s.t("phone_interface"), s.busy != "" || s.phone.stopping)
			}).FillWidth()
		}
		if !s.phone.lifecycleReady {
			ui.Text(c, s.t("phone_lifecycle_unavailable")).TextColor(tokenDanger)
		}
		ui.Checkbox(c, &s.phone.trusted, s.t("phone_trusted")).Disabled(s.phone.interfaceID == "")
	})
}

// phoneActive mirrors the Swift receiver sheet: an address QR code (without the
// pairing code), the URL with a copy action, the one-time code and the
// troubleshooting note about guest isolation and the macOS firewall.
func (s *screen) phoneActive(c *ui.Context) {
	ui.Row(c).FillWidth().Gap(22).Children(func() {
		if bitmap := s.phoneQR(s.phone.status.Address); bitmap != nil {
			ui.Image(c, bitmap).Label(s.t("phone_qr_label")).Size(190, 190).Shrink(0).Fit(ui.Contain)
		} else {
			ui.Column(c).Size(190, 190).Shrink(0).Center().Children(func() {
				ui.Text(c, s.t("phone_qr_unavailable")).TextColor(c.Theme().TextMuted)
			})
		}
		ui.Column(c).Grow(1).MinWidth(0).Gap(14).Children(func() {
			ui.Text(c, s.t("phone_open_in_browser")).TextColor(c.Theme().TextMuted)
			ui.Text(c, s.phone.status.Address).Font("monospace").Bold().Selectable()
			ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
				if ui.Button(c, s.t("phone_copy_address")).Tooltip(s.t("phone_copy_hint")).Clicked() {
					s.copyPhoneAddress()
				}
				if s.phone.copied {
					ui.Text(c, s.t("phone_address_copied")).FontSize(12).TextColor(c.Theme().TextMuted)
				}
			})
			divider(c, false)
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

func phoneStatusKey(status string) string {
	switch status {
	case "stored":
		return "phone_stored"
	case "processing":
		return "phone_processing"
	case "reviewable":
		return "phone_ready"
	case "unsupported":
		return "phone_unsupported"
	default:
		return "phone_failed"
	}
}

func phoneStatusIcon(status string) *ui.SVG {
	switch status {
	case "reviewable":
		return iconCheck
	case "unsupported":
		return iconNo
	case "failed":
		return iconWarning
	default:
		return iconScan
	}
}

// formatBytes follows the Foundation file byte count style (decimal units).
func (s *screen) formatBytes(n int64) string {
	switch {
	case n < 1000:
		return s.t("bytes", n)
	case n < 1000*1000:
		return fmt.Sprintf("%d KB", (n+500)/1000)
	case n < 1000*1000*1000:
		return fmt.Sprintf("%.1f MB", float64(n)/1e6)
	default:
		return fmt.Sprintf("%.2f GB", float64(n)/1e9)
	}
}

// formatReceived shows the local month, day and time an item arrived.
func (s *screen) formatReceived(created string) string {
	t, err := time.Parse(time.RFC3339Nano, created)
	if err != nil {
		return ""
	}
	t = t.Local()
	if s.lang() == "en" {
		return t.Format("Jan 2, 15:04")
	}
	return fmt.Sprintf("%d月%d日 %s", int(t.Month()), t.Day(), t.Format("15:04"))
}

func (s *screen) phoneDialogs(c *ui.Context) {
	if len(s.phone.deleteSelection) == 0 {
		return
	}
	open := true
	ui.Modal(c, &open, func() {
		ui.Text(c, s.t("phone_delete_title")).FontSize(20).Bold()
		ui.Text(c, s.t("phone_delete_help"))
		ui.Column(c).Gap(8).Children(func() {
			if ui.Button(c, s.t("phone_delete_confirm")).FillWidth().TextColor(tokenDanger).Clicked() {
				s.deletePhone()
			}
			if ui.Button(c, s.t("cancel")).FillWidth().Clicked() {
				s.phone.deleteSelection = nil
			}
		})
	}).Width(420).Label(s.t("phone_delete_title"))
	if !open {
		s.phone.deleteSelection = nil
	}
}
