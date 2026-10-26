package desktop

import "github.com/egoist/mygo/ui"

func (s *screen) showReportOriginal() {
	page, reportID, sourceID := s.page, s.report.ID, s.sourceID
	s.viewerClose = func() {
		if s.report.ID == reportID && s.sourceID == sourceID && s.page != page {
			s.preview(page)
		}
	}
	s.originalViewer = "report"
	s.viewerZoom, s.viewerRotation, s.viewerViewport = 1, 0, ui.Rect{}
}

func (s *screen) showPhoneOriginal(id string) {
	item, ok := s.phoneItem(id)
	if !ok || item.Status != "reviewable" || s.busy != "" {
		return
	}
	previous, page := s.phone.preview, s.phone.page
	zoom, rotation := s.phoneZoom, s.phoneRotation
	s.viewerClose = func() {
		s.clearPhonePreview()
		if current, exists := s.phoneItem(previous.ID); exists && s.phoneSelected(previous.ID) && current.Revision == previous.Revision {
			s.previewPhone(current, max(1, page))
			s.phoneZoom, s.phoneRotation = zoom, rotation
		} else {
			s.ensurePhonePreview()
		}
	}
	s.originalViewer = "phone"
	s.viewerZoom, s.viewerRotation, s.viewerViewport = 1, 0, ui.Rect{}
	s.previewPhone(item, 1)
}

func (s *screen) closeOriginalViewer() {
	s.originalViewer = ""
	if s.viewerClose != nil {
		close := s.viewerClose
		s.viewerClose = nil
		close()
	}
}

func (s *screen) phonePreview(c *ui.Context) {
	ui.Column(c).FillWidth().Height(380).Gap(8).Children(func() {
		s.previewControls(c, true, false)
		message := "preparing_original"
		if s.phone.previewFailed {
			message = "original_unavailable"
		}
		s.previewCanvas(c, s.phone.bitmap, s.phoneZoom, s.phoneRotation, message, false)
	})
}

func (s *screen) originalSheet(c *ui.Context) {
	if s.originalViewer == "" {
		return
	}
	open := true
	panel := ui.Modal(c, &open, func() {
		ui.Column(c).Fill().Gap(12).Children(func() {
			ui.Row(c).FillWidth().Gap(12).AlignItems(ui.Center).Children(func() {
				icon(c, iconDoc, 18, c.Theme().Text)
				ui.Text(c, s.t("view_original")).Bold().Grow(1)
				if s.originalViewer == "report" && s.report.Status == "confirmed" && ui.Button(c, s.t("export")).Disabled(s.busy != "").Clicked() {
					s.chooseExport()
				}
				if ui.Button(c, s.t("close")).Clicked() || c.Shortcut(0, ui.KeyEscape) {
					s.closeOriginalViewer()
				}
			})
			divider(c, false)
			if s.originalViewer == "phone" {
				s.previewControls(c, true, true)
				message := "preparing_original"
				if s.phone.previewFailed {
					message = "original_unavailable"
				}
				s.previewCanvas(c, s.phone.bitmap, s.viewerZoom, s.viewerRotation, message, true)
			} else {
				s.previewControls(c, false, true)
				message := s.previewError
				if message == "" {
					message = "preparing_original"
				}
				s.previewCanvas(c, s.bitmap, s.viewerZoom, s.viewerRotation, message, true)
			}
		})
	})
	w, h := c.Size()
	panel.Width(min(w-40, 1120)).Height(h - 40).Label(s.t("original_viewer"))
	if !open && s.busy == "" {
		s.closeOriginalViewer()
	}
}

func (s *screen) previewControls(c *ui.Context, phone, viewer bool) {
	page, count, kind := s.page, s.source().Extraction.PageCount, s.source().Extraction.Kind
	zoom, rotation := &s.originalZoom, &s.originalRotation
	busy := s.previewBusy
	bitmap := s.bitmap
	pageTo := s.preview
	if phone {
		page, count, kind = s.phone.page, s.phone.preview.Extraction.PageCount, s.phone.preview.Extraction.Kind
		zoom, rotation, busy = &s.phoneZoom, &s.phoneRotation, s.phone.previewBusy
		bitmap = s.phone.bitmap
		pageTo = func(n int) { s.previewPhone(s.phone.preview, n) }
	}
	if viewer {
		zoom, rotation = &s.viewerZoom, &s.viewerRotation
	}
	imageSource := kind == "png" || kind == "jpeg" || kind == "heic" || kind == "tiff"
	if *zoom == 0 {
		*zoom = 1
	}
	ui.Row(c).FillWidth().Gap(4).AlignItems(ui.Center).Children(func() {
		if imageSource {
			key := "image_preview"
			if viewer {
				key = "original_image"
			}
			ui.Text(c, s.t(key)).FontSize(12).TextColor(c.Theme().TextMuted).SingleLine()
		} else {
			if s.iconButton(c, iconBack, s.t("previous_page"), page <= 1 || busy) {
				pageTo(page - 1)
			}
			ui.Text(c, s.t("page", max(1, page), max(1, count))).FontSize(12).TextColor(c.Theme().TextMuted).SingleLine()
			if s.iconButton(c, iconChevron, s.t("next_page"), page >= count || busy) {
				pageTo(page + 1)
			}
		}
		ui.Box(c).Grow(1)
		if imageSource {
			if s.iconButton(c, iconRotateLeft, s.t("rotate_left"), busy) {
				*rotation = (*rotation + 3) % 4
			}
			if s.iconButton(c, iconRotateRight, s.t("rotate_right"), busy) {
				*rotation = (*rotation + 1) % 4
			}
		}
		minimum, maximum := float32(.6), float32(2.4)
		if viewer {
			maximum = s.viewerMaximumZoom(bitmap, *rotation)
			if imageSource {
				minimum = .4
			}
			*zoom = min(*zoom, maximum)
		}
		if s.iconButton(c, iconZoomOut, s.t("zoom_out"), *zoom <= minimum || busy) {
			*zoom = max(minimum, *zoom-.2)
		}
		if s.iconButton(c, iconZoomIn, s.t("zoom_in"), *zoom >= maximum || busy) {
			*zoom = min(maximum, *zoom+.2)
		}
		if !viewer && (phone || !s.reviewOpen()) && ui.Button(c, s.t("view_original")).FontSize(12).Disabled(busy).Clicked() {
			if phone {
				s.showPhoneOriginal(s.phone.preview.ID)
			} else {
				s.showReportOriginal()
			}
		}
	})
}

func orientedBitmapSize(bitmap *ui.Bitmap, rotation int) (float32, float32) {
	if bitmap == nil {
		return 0, 0
	}
	w, h := bitmap.Size()
	if rotation%2 != 0 {
		w, h = h, w
	}
	return float32(w), float32(h)
}

func (s *screen) viewerMaximumZoom(bitmap *ui.Bitmap, rotation int) float32 {
	w, h := orientedBitmapSize(bitmap, rotation)
	if w <= 0 || h <= 0 || s.viewerViewport.W <= 0 || s.viewerViewport.H <= 0 {
		return 2.4
	}
	fit := min(s.viewerViewport.W/w, s.viewerViewport.H/h)
	return max(2.4, 1/fit)
}

func (s *screen) previewCanvas(c *ui.Context, bitmap *ui.Bitmap, zoom float32, rotation int, message string, viewer bool) {
	viewport := ui.ScrollBoth(c).FillWidth().Grow(1).MinHeight(0).Background(c.Theme().Surface).Label(s.t("original_canvas"))
	bounds := viewport.LayoutBounds()
	width, height := bounds.W, bounds.H
	if viewer && bounds != s.viewerViewport {
		s.viewerViewport = bounds
		c.Invalidate()
	}
	if width <= 0 {
		width = 400
		c.Invalidate()
	}
	viewport.Children(func() {
		if bitmap == nil {
			ui.Column(c).Width(width).MinHeight(180).Center().Children(func() { ui.Text(c, s.t(message)).TextColor(c.Theme().TextMuted) })
			return
		}
		bw, bh := orientedBitmapSize(bitmap, rotation)
		if bw <= 0 || bh <= 0 {
			return
		}
		scale := max(1, width-2) / bw
		if viewer && height > 0 {
			scale = min(scale, height/bh)
		}
		w, h := bw*scale*zoom, bh*scale*zoom
		canvasW, canvasH := w, h
		if viewer {
			canvasW, canvasH = max(w, width), max(h, height)
		}
		ui.Box(c).Size(canvasW, canvasH).Children(func() {
			iw, ih := w, h
			if rotation%2 != 0 {
				iw, ih = h, w
			}
			ui.Image(c, bitmap).Label(s.t("original")).Size(iw, ih).Absolute().Left((canvasW - iw) / 2).Top((canvasH - ih) / 2).Rotate(float32(rotation * 90)).Fit(ui.Contain)
		})
	})
}
