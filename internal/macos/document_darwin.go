//go:build darwin

package macos

import (
	"bytes"
	"context"
	"image"
	"math"
	"sort"
	"strings"
	"unicode"
	"unicode/utf16"
	"unsafe"

	"github.com/ebitengine/purego/objc"
	"kinlogue/internal/document"
)

// Extract returns unconfirmed, source-linked transcription. A canceled or failed
// operation returns no partial output. Native requests are synchronous; context
// cancellation is observed before/after them and between PDF pages.
func Extract(ctx context.Context, data []byte) (document.Extraction, error) {
	var result document.Extraction
	err := native(ctx, func() error {
		if err := checkData(data); err != nil {
			return err
		}
		if bytes.HasPrefix(data, []byte("%PDF-")) {
			pdf, count, err := openPDF(ctx, data)
			if err != nil {
				return err
			}
			defer release(pdf)
			result = document.Extraction{Kind: "pdf", PageCount: count, Engine: "pdfkit-text-v1+vision-vnrecognizetext-r3"}
			for pageNumber := 1; pageNumber <= count; pageNumber++ {
				if err := ctx.Err(); err != nil {
					return err
				}
				// Reclaim page-local selections/strings before advancing to the next page.
				err := func() error {
					pool := poolPush()
					defer poolPop(pool)
					page, box, err := pdfPage(pdf, pageNumber)
					if err != nil {
						return err
					}
					text, err := stringCopy(send(page, "string"), document.MaxTextBytes)
					if err != nil {
						return err
					}
					if usableText(text) {
						return appendPDFText(&result, page, pageNumber, box, text)
					}
					if err := ctx.Err(); err != nil {
						return err
					}
					img, err := renderPDF(page, box)
					if err != nil {
						return err
					}
					defer imageRelease(img)
					return recognize(ctx, &result, img, pageNumber)
				}()
				if err != nil {
					return err
				}
			}
		} else {
			img, kind, err := openImage(data)
			if err != nil {
				return err
			}
			defer imageRelease(img)
			result = document.Extraction{Kind: kind, PageCount: 1, Engine: "vision-vnrecognizetext-r3"}
			if err := recognize(ctx, &result, img, 1); err != nil {
				return err
			}
		}
		return result.Validate()
	})
	if err != nil {
		return document.Extraction{}, err
	}
	return result, nil
}

// RenderPage produces one transient, orientation-correct raster; page is one
// based for both PDFs and images. Neither source bytes nor pixels are persisted.
func RenderPage(ctx context.Context, data []byte, pageNumber int) (image.Image, error) {
	var result image.Image
	err := native(ctx, func() error {
		if err := checkData(data); err != nil {
			return err
		}
		if pageNumber < 1 {
			return document.ErrInvalid
		}
		var img uintptr
		if bytes.HasPrefix(data, []byte("%PDF-")) {
			pdf, count, err := openPDF(ctx, data)
			if err != nil {
				return err
			}
			defer release(pdf)
			if pageNumber > count {
				return document.ErrInvalid
			}
			page, box, err := pdfPage(pdf, pageNumber)
			if err != nil {
				return err
			}
			img, err = renderPDF(page, box)
			if err != nil {
				return err
			}
		} else {
			if pageNumber != 1 {
				return document.ErrInvalid
			}
			var err error
			img, _, err = openImage(data)
			if err != nil {
				return err
			}
		}
		defer imageRelease(img)
		if err := ctx.Err(); err != nil {
			return err
		}
		var err error
		result, err = copyImage(img)
		return err
	})
	if err != nil {
		return nil, err
	}
	return result, nil
}

func checkData(data []byte) error {
	if len(data) > document.MaxFileBytes {
		return document.ErrLimit
	}
	if len(data) == 0 {
		return document.ErrInvalid
	}
	return nil
}

func openPDF(ctx context.Context, data []byte) (id, int, error) {
	pdf := send(alloc("PDFDocument"), "initWithData:", uintptr(nsData(data)))
	if pdf == 0 {
		return 0, 0, document.ErrInvalid
	}
	if byte(send(pdf, "isLocked")) != 0 {
		release(pdf)
		return 0, 0, document.ErrLocked
	}
	count := int(send(pdf, "pageCount"))
	if count < 1 || count > document.MaxPages {
		release(pdf)
		return 0, 0, document.ErrLimit
	}
	// Check all boxes even when only one page will be rendered, before decoding.
	for n := 1; n <= count; n++ {
		if err := ctx.Err(); err != nil {
			release(pdf)
			return 0, 0, err
		}
		if _, _, err := pdfPage(pdf, n); err != nil {
			release(pdf)
			return 0, 0, err
		}
	}
	return pdf, count, nil
}

func pdfPage(pdf id, number int) (id, rect, error) {
	page := send(pdf, "pageAtIndex:", uintptr(number-1))
	if page == 0 {
		return 0, rect{}, document.ErrInvalid
	}
	box := msgRectArg(page, objc.RegisterName("boundsForBox:"), 0)
	if !finite(box.Origin.X) || !finite(box.Origin.Y) || !finite(box.Size.Width) || !finite(box.Size.Height) || box.Size.Width <= 0 || box.Size.Height <= 0 || box.Size.Width > document.MaxPDFEdge || box.Size.Height > document.MaxPDFEdge {
		return 0, rect{}, document.ErrLimit
	}
	return page, box, nil
}

func usableText(text string) bool {
	count, meaningful, bad := 0, 0, 0
	for _, r := range text {
		if unicode.IsSpace(r) {
			continue
		}
		count++
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			meaningful++
		}
		if unicode.IsControl(r) || r == unicode.ReplacementChar {
			bad++
		}
	}
	return count >= 8 && meaningful >= 8 && bad*10 <= count
}

func appendPDFText(result *document.Extraction, page id, pageNumber int, box rect, text string) error {
	// PDFSelection uses UTF-16 offsets, not Go byte/rune indices. Keeping the
	// delimiters in each slice preserves offsets for CRLF and supplementary chars.
	units := utf16.Encode([]rune(text))
	rotation := int(send(page, "rotation"))
	for start := 0; start < len(units); {
		end := start
		for end < len(units) && units[end] != '\n' && units[end] != '\r' && units[end] != 0x2028 && units[end] != 0x2029 {
			end++
		}
		line := strings.TrimSpace(string(utf16.Decode(units[start:end])))
		if line != "" {
			selection := msgRange(page, objc.RegisterName("selectionForRange:"), nsRange{uintptr(start), uintptr(end - start)})
			bounds := box
			if selection != 0 {
				bounds = msgRectArg(selection, objc.RegisterName("boundsForPage:"), uintptr(page))
			}
			if err := appendBlock(result, document.Block{Page: pageNumber, Text: line, Bounds: uprightBounds(normalize(bounds, box), rotation), Confidence: 1, Method: "pdfTextLayer"}); err != nil {
				return err
			}
		}
		start = end
		if start < len(units) {
			if units[start] == '\r' && start+1 < len(units) && units[start+1] == '\n' {
				start++
			}
			start++
		}
	}
	return nil
}

// PDF text selections are in unrotated page space. Match the upright raster
// used by RenderPage and Vision so every method's source rectangle is usable.
func uprightBounds(r document.Rect, rotation int) document.Rect {
	switch ((rotation % 360) + 360) % 360 {
	case 90:
		return document.Rect{X: r.Y, Y: 1 - r.X - r.Width, Width: r.Height, Height: r.Width}
	case 180:
		return document.Rect{X: 1 - r.X - r.Width, Y: 1 - r.Y - r.Height, Width: r.Width, Height: r.Height}
	case 270:
		return document.Rect{X: 1 - r.Y - r.Height, Y: r.X, Width: r.Height, Height: r.Width}
	default:
		return r
	}
}

func appendBlock(result *document.Extraction, block document.Block) error {
	if len(result.Blocks) >= document.MaxBlocks || len(block.Text) > document.MaxBlockBytes {
		return document.ErrLimit
	}
	bytes := len(block.Text)
	for _, previous := range result.Blocks {
		bytes += len(previous.Text)
	}
	if bytes > document.MaxTextBytes {
		return document.ErrLimit
	}
	result.Blocks = append(result.Blocks, block)
	return nil
}

func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }
func normalize(bounds, box rect) document.Rect {
	x0 := (bounds.Origin.X - box.Origin.X) / box.Size.Width
	y0 := (bounds.Origin.Y - box.Origin.Y) / box.Size.Height
	x1 := x0 + bounds.Size.Width/box.Size.Width
	y1 := y0 + bounds.Size.Height/box.Size.Height
	for _, v := range []float64{x0, y0, x1, y1} {
		if !finite(v) {
			return document.Rect{Width: 1, Height: 1}
		}
	}
	x0 = math.Max(0, math.Min(1, x0))
	y0 = math.Max(0, math.Min(1, y0))
	x1 = math.Max(x0, math.Min(1, x1))
	y1 = math.Max(y0, math.Min(1, y1))
	return document.Rect{X: x0, Y: y0, Width: x1 - x0, Height: y1 - y0}
}

func openImage(data []byte) (uintptr, string, error) {
	options := imageOptions(map[string]int{"kCGImageSourceShouldCache": 0})
	source := sourceCreate(nsData(data), options)
	if source == 0 {
		return 0, "", document.ErrUnsupported
	}
	defer cfRelease(source)
	uti, err := stringCopy(sourceType(source), 256)
	if err != nil {
		return 0, "", err
	}
	kind := map[string]string{"public.jpeg": "jpeg", "public.png": "png", "public.heic": "heic", "public.heif": "heic", "public.tiff": "tiff"}[uti]
	if kind == "" {
		return 0, "", document.ErrUnsupported
	}
	if sourceCount(source) != 1 {
		return 0, "", document.ErrLimit
	}
	properties := sourceProperties(source, 0, options)
	if properties == 0 {
		return 0, "", document.ErrInvalid
	}
	defer cfRelease(uintptr(properties))
	dimension := func(key string) int64 {
		return int64(send(send(properties, "objectForKey:", uintptr(imageKeys[key])), "longLongValue"))
	}
	w, h := dimension("kCGImagePropertyPixelWidth"), dimension("kCGImagePropertyPixelHeight")
	if err := validateRasterDimensions(w, h); err != nil {
		return 0, "", err
	}
	// ImageIO applies EXIF orientation to the bounded raster. Vision and preview
	// therefore use the same upright coordinate system and orientation=.up.
	img := sourceThumbnail(source, 0, imageOptions(map[string]int{"kCGImageSourceCreateThumbnailFromImageAlways": 1, "kCGImageSourceCreateThumbnailWithTransform": 1, "kCGImageSourceThumbnailMaxPixelSize": document.MaxRenderEdge, "kCGImageSourceShouldCacheImmediately": 1}))
	if img == 0 {
		return 0, "", document.ErrInvalid
	}
	if imageWidth(img) > document.MaxRenderEdge || imageHeight(img) > document.MaxRenderEdge || imageWidth(img) == 0 || imageHeight(img) == 0 {
		imageRelease(img)
		return 0, "", document.ErrLimit
	}
	defer imageRelease(img)
	// In transparent scans, alpha can carry the entire glyph while RGB is all
	// black. Composite onto the same white paper for OCR and original preview;
	// dropping alpha or leaving its interpretation to Vision loses that text.
	opaque, err := whitePaperImage(img)
	if err != nil {
		return 0, "", err
	}
	return opaque, kind, nil
}

func validateRasterDimensions(width, height int64) error {
	if width < 1 || height < 1 {
		return document.ErrInvalid
	}
	// Check edges before multiplication, so even corrupt huge metadata cannot
	// overflow the pixel count. No decoded raster is allocated by this policy.
	if width > document.MaxImageEdge || height > document.MaxImageEdge || width*height > document.MaxImagePixels {
		return document.ErrLimit
	}
	return nil
}

func whitePaperImage(img uintptr) (uintptr, error) {
	w, h := int(imageWidth(img)), int(imageHeight(img))
	bitmap, err := newBitmap(w, h)
	if err != nil {
		return 0, err
	}
	defer contextRelease(bitmap)
	target := rect{Size: size{float64(w), float64(h)}}
	contextFillColor(bitmap, 1, 1, 1, 1)
	contextFillRect(bitmap, target)
	contextDrawImage(bitmap, target, img)
	opaque := bitmapImage(bitmap)
	if opaque == 0 {
		return 0, document.ErrInvalid
	}
	return opaque, nil
}

func newBitmap(w, h int) (uintptr, error) {
	if w < 1 || h < 1 || w > document.MaxRenderEdge || h > document.MaxRenderEdge {
		return 0, document.ErrLimit
	}
	space := colorSpaceCreate()
	if space == 0 {
		return 0, document.ErrUnavailable
	}
	defer colorSpaceRelease(space)
	// Fixed RGBA byte order, 8-bit components, premultiplied alpha.
	bitmap := bitmapCreate(0, uintptr(w), uintptr(h), 8, uintptr(w*4), space, 1|(4<<12))
	if bitmap == 0 {
		return 0, document.ErrLimit
	}
	return bitmap, nil
}

func renderPDF(page id, box rect) (uintptr, error) {
	ref := uintptr(send(page, "pageRef"))
	if ref == 0 {
		return 0, document.ErrInvalid
	}
	w, h := box.Size.Width, box.Size.Height
	rotation := ((pdfRotation(ref) % 360) + 360) % 360
	if rotation == 90 || rotation == 270 {
		w, h = h, w
	}
	scale := math.Min(float64(document.MaxRenderEdge)/math.Max(w, h), 2)
	width, height := int(math.Ceil(w*scale)), int(math.Ceil(h*scale))
	bitmap, err := newBitmap(width, height)
	if err != nil {
		return 0, err
	}
	defer contextRelease(bitmap)
	target := rect{Size: size{float64(width), float64(height)}}
	contextFillColor(bitmap, 1, 1, 1, 1)
	contextFillRect(bitmap, target)
	// PDFKit draws the rotated page and its annotations in page-point space.
	// Apply our explicit scale: CGPDFPageGetDrawingTransform only downscales,
	// which would otherwise center a small original in a larger raster.
	contextConcat(bitmap, affine{A: scale, D: scale})
	send(page, "setDisplaysAnnotations:", 1)
	send(page, "drawWithBox:toContext:", 0, bitmap)
	img := bitmapImage(bitmap)
	if img == 0 {
		return 0, document.ErrInvalid
	}
	return img, nil
}

func copyImage(img uintptr) (image.Image, error) {
	w, h := int(imageWidth(img)), int(imageHeight(img))
	bitmap, err := newBitmap(w, h)
	if err != nil {
		return nil, err
	}
	defer contextRelease(bitmap)
	contextDrawImage(bitmap, rect{Size: size{float64(w), float64(h)}}, img)
	p := bitmapData(bitmap)
	if p == 0 {
		return nil, document.ErrInvalid
	}
	result := image.NewRGBA(image.Rect(0, 0, w, h))
	copy(result.Pix, unsafe.Slice(*(**byte)(unsafe.Pointer(&p)), len(result.Pix)))
	return result, nil
}

func recognize(ctx context.Context, result *document.Extraction, img uintptr, page int) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	request := send(alloc("VNRecognizeTextRequest"), "init")
	if request == 0 {
		return document.ErrUnavailable
	}
	defer release(request)
	send(request, "setRevision:", 3)
	send(request, "setRecognitionLevel:", 0)
	send(request, "setUsesLanguageCorrection:", 0)
	var nsError id
	supported := send(request, "supportedRecognitionLanguagesAndReturnError:", uintptr(unsafe.Pointer(&nsError)))
	if nsError != 0 || supported == 0 {
		return document.ErrUnavailable
	}
	// Language configuration is checked, rather than silently accepting a
	// different engine/revision. macOS 14+ revision 3 supports these languages.
	for _, language := range []string{"zh-Hans", "en-US"} {
		if byte(send(supported, "containsObject:", uintptr(nsString(language)))) == 0 {
			return document.ErrUnavailable
		}
	}
	send(request, "setRecognitionLanguages:", uintptr(nsArray(nsString("zh-Hans"), nsString("en-US"))))
	handler := send(alloc("VNImageRequestHandler"), "initWithCGImage:orientation:options:", img, 1, uintptr(nsDict(nil)))
	if handler == 0 {
		return document.ErrUnavailable
	}
	defer release(handler)
	if err := ctx.Err(); err != nil {
		return err
	}
	ok := byte(send(handler, "performRequests:error:", uintptr(nsArray(request)), uintptr(unsafe.Pointer(&nsError)))) != 0
	if err := ctx.Err(); err != nil {
		return err
	}
	if !ok || nsError != 0 {
		return document.ErrUnavailable
	}
	observations := send(request, "results")
	count := int(send(observations, "count"))
	if count > document.MaxBlocks-len(result.Blocks) {
		return document.ErrLimit
	}
	blocks := make([]document.Block, 0, count)
	for i := 0; i < count; i++ {
		observation := send(observations, "objectAtIndex:", uintptr(i))
		candidates := send(observation, "topCandidates:", 1)
		if send(candidates, "count") == 0 {
			continue
		}
		candidate := send(candidates, "objectAtIndex:", 0)
		text, err := stringCopy(send(candidate, "string"), document.MaxBlockBytes)
		if err != nil {
			return err
		}
		if strings.TrimSpace(text) == "" {
			continue
		}
		bounds := msgRect(observation, objc.RegisterName("boundingBox"))
		blocks = append(blocks, document.Block{Page: page, Text: text, Bounds: normalize(bounds, rect{Size: size{1, 1}}), Confidence: float64(msgConfidence(candidate, objc.RegisterName("confidence"))), Method: "vision"})
	}
	sort.SliceStable(blocks, func(i, j int) bool {
		a, b := blocks[i].Bounds, blocks[j].Bounds
		if math.Abs(a.Y-b.Y) > .01 {
			return a.Y > b.Y
		}
		return a.X < b.X
	})
	for _, block := range blocks {
		if err := appendBlock(result, block); err != nil {
			return err
		}
	}
	return nil
}
