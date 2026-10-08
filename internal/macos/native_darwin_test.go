//go:build darwin

package macos

import (
	"bytes"
	"compress/zlib"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"unsafe"

	"github.com/ebitengine/purego"

	"kinlogue/internal/document"
)

// Every source is generated in memory; fixtures contain no patient information.
func syntheticPDF(pages int, width, height int) []byte {
	return syntheticPDFRotation(pages, width, height, 0)
}

func syntheticPDFRotation(pages int, width, height, rotation int) []byte {
	objects := []string{"<< /Type /Catalog /Pages 2 0 R >>", ""}
	kids := make([]string, pages)
	for i := range pages {
		pageID := len(objects) + 1
		kids[i] = fmt.Sprintf("%d 0 R", pageID)
		content := "BT /F1 28 Tf 40 100 Td (SYNTHETIC REPORT 12345) Tj ET"
		objects = append(objects, fmt.Sprintf("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] /Rotate %d /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents %d 0 R >>", width, height, rotation, pageID+1), fmt.Sprintf("<< /Length %d >>\nstream\n%s\nendstream", len(content), content))
	}
	objects[1] = fmt.Sprintf("<< /Type /Pages /Kids [%s] /Count %d >>", strings.Join(kids, " "), pages)
	return encodePDFObjects(objects)
}

func encodePDFObjects(objects []string) []byte {
	var buf bytes.Buffer
	buf.WriteString("%PDF-1.4\n")
	offsets := []int{0}
	for i, object := range objects {
		offsets = append(offsets, buf.Len())
		fmt.Fprintf(&buf, "%d 0 obj\n%s\nendobj\n", i+1, object)
	}
	xref := buf.Len()
	fmt.Fprintf(&buf, "xref\n0 %d\n0000000000 65535 f \n", len(offsets))
	for _, offset := range offsets[1:] {
		fmt.Fprintf(&buf, "%010d 00000 n \n", offset)
	}
	fmt.Fprintf(&buf, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", len(offsets), xref)
	return buf.Bytes()
}

func TestPDFTextAndBoundedRendering(t *testing.T) {
	data := syntheticPDF(2, 600, 800)
	got, err := Extract(context.Background(), data)
	if err != nil {
		t.Fatal(err)
	}
	if err := got.Validate(); err != nil {
		t.Fatal(err)
	}
	if got.Kind != "pdf" || got.PageCount != 2 || len(got.Blocks) != 2 {
		t.Fatalf("unexpected extraction shape: %s / %d / %d", got.Kind, got.PageCount, len(got.Blocks))
	}
	for i, b := range got.Blocks {
		if b.Page != i+1 || b.Method != "pdfTextLayer" || b.Text != "SYNTHETIC REPORT 12345" || b.Bounds.Width <= 0 || b.Bounds.Height <= 0 {
			t.Fatal("missing text-layer source provenance")
		}
	}
	img, err := RenderPage(context.Background(), data, 2)
	if err != nil {
		t.Fatal(err)
	}
	if img.Bounds().Dx() != 1200 || img.Bounds().Dy() != 1600 {
		t.Fatal("unexpected raster dimensions")
	}
	for _, page := range []int{-1, 0, 3} {
		if _, err := RenderPage(context.Background(), data, page); !errors.Is(err, document.ErrInvalid) {
			t.Fatalf("page %d: %v", page, err)
		}
	}
}

func TestImageOnlyPDFUsesVisionWithPageProvenance(t *testing.T) {
	// The PDF contains only raster XObjects, with no fonts or text operators.
	// Rendering a synthetic source first supplies a legible in-memory scan.
	img, err := RenderPage(context.Background(), syntheticPDF(1, 600, 300), 1)
	if err != nil {
		t.Fatal(err)
	}
	width, height := img.Bounds().Dx(), img.Bounds().Dy()
	gray := make([]byte, width*height)
	for y := range height {
		for x := range width {
			r, _, _, _ := img.At(x, y).RGBA()
			gray[y*width+x] = uint8(r >> 8)
		}
	}
	var compressed bytes.Buffer
	zw := zlib.NewWriter(&compressed)
	if _, err := zw.Write(gray); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	content := "q 600 0 0 300 0 0 cm /Scan Do Q"
	data := encodePDFObjects([]string{
		"<< /Type /Catalog /Pages 2 0 R >>",
		"<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
		"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 300] /Resources << /XObject << /Scan 5 0 R >> >> /Contents 6 0 R >>",
		"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 300] /Resources << /XObject << /Scan 5 0 R >> >> /Contents 6 0 R >>",
		fmt.Sprintf("<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode /Length %d >>\nstream\n%s\nendstream", width, height, compressed.Len(), compressed.Bytes()),
		fmt.Sprintf("<< /Length %d >>\nstream\n%s\nendstream", len(content), content),
	})
	got, err := Extract(context.Background(), data)
	if err != nil {
		t.Fatal(err)
	}
	if err := got.Validate(); err != nil {
		t.Fatal(err)
	}
	if got.Kind != "pdf" || got.PageCount != 2 {
		t.Fatal("scan did not preserve PDF kind/page count")
	}
	anchors := map[int]bool{1: false, 2: false}
	for _, block := range got.Blocks {
		if block.Method != "vision" || block.Page < 1 || block.Page > 2 || block.Bounds.Width <= 0 || block.Bounds.Height <= 0 {
			t.Fatal("scan did not preserve Vision method and page/source provenance")
		}
		if strings.Contains(block.Text, "SYNTHETIC") {
			anchors[block.Page] = true
		}
	}
	if !anchors[1] || !anchors[2] {
		t.Fatal("Vision did not recognize the synthetic anchor on both scanned pages")
	}
}

func TestValidationAndCancellation(t *testing.T) {
	for _, data := range [][]byte{nil, []byte("not a report"), []byte("%PDF-1.4\ntruncated")} {
		if _, err := Extract(context.Background(), data); err == nil {
			t.Fatal("invalid input accepted")
		}
	}
	for _, data := range [][]byte{syntheticPDF(201, 600, 800), syntheticPDF(1, 14401, 800), make([]byte, document.MaxFileBytes+1)} {
		if _, err := Extract(context.Background(), data); !errors.Is(err, document.ErrLimit) {
			t.Fatalf("resource bound: %v", err)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Extract(ctx, syntheticPDF(1, 600, 800)); !errors.Is(err, context.Canceled) {
		t.Fatalf("extract cancellation: %v", err)
	}
	if _, err := RenderPage(ctx, syntheticPDF(1, 600, 800), 1); !errors.Is(err, context.Canceled) {
		t.Fatalf("render cancellation: %v", err)
	}
}

func TestVisionGeneratedPNG(t *testing.T) {
	img, err := RenderPage(context.Background(), syntheticPDF(1, 600, 300), 1)
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	got, err := Extract(context.Background(), buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if err := got.Validate(); err != nil {
		t.Fatal(err)
	}
	if got.Kind != "png" || !strings.Contains(got.Text(), "SYNTHETIC") {
		t.Fatal("Vision did not recognize generated anchor")
	}
	for _, b := range got.Blocks {
		if b.Method != "vision" || b.Page != 1 {
			t.Fatal("missing Vision provenance")
		}
	}
}

func TestTransparentBlackTextPNGUsesSameWhitePaperForOCRAndPreview(t *testing.T) {
	opaque, err := RenderPage(context.Background(), syntheticPDF(1, 600, 300), 1)
	if err != nil {
		t.Fatal(err)
	}
	transparent := image.NewNRGBA(opaque.Bounds())
	visiblePixels := 0
	for y := range opaque.Bounds().Dy() {
		for x := range opaque.Bounds().Dx() {
			r, _, _, _ := opaque.At(x, y).RGBA()
			alpha := uint8(255 - (r >> 8))
			if alpha > 0 {
				visiblePixels++
			}
			transparent.SetNRGBA(x, y, color.NRGBA{A: alpha})
		}
	}
	if visiblePixels == 0 {
		t.Fatal("generated transparent fixture is blank")
	}
	var b bytes.Buffer
	if err := png.Encode(&b, transparent); err != nil {
		t.Fatal(err)
	}
	got, err := Extract(context.Background(), b.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got.Text(), "SYNTHETIC") {
		t.Error("Vision lost visible black text on transparent PNG")
	}
	preview, err := RenderPage(context.Background(), b.Bytes(), 1)
	if err != nil {
		t.Fatal(err)
	}
	if preview.Bounds() != opaque.Bounds() {
		t.Fatal("background normalization changed geometry")
	}
	r, g, bl, a := preview.At(0, 0).RGBA()
	if r != 0xffff || g != 0xffff || bl != 0xffff || a != 0xffff {
		t.Error("transparent paper is not shown as opaque white in preview")
	}
	for _, block := range got.Blocks {
		if block.Method != "vision" || block.Page != 1 {
			t.Fatal("transparent PNG lost source provenance")
		}
	}
}

func TestImportedFileRejectsSpecialFiles(t *testing.T) {
	dir := t.TempDir()
	regular := filepath.Join(dir, "synthetic.pdf")
	want := syntheticPDF(1, 600, 800)
	if err := os.WriteFile(regular, want, 0600); err != nil {
		t.Fatal(err)
	}
	got, err := ReadImportedFile(regular)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("read regular: %v", err)
	}
	link := filepath.Join(dir, "symlink")
	if err := os.Symlink(regular, link); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(dir, "fifo")
	if err := syscall.Mkfifo(fifo, 0600); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{link, fifo, dir, filepath.Join(dir, "absent")} {
		if _, err := ReadImportedFile(path); err == nil || strings.Contains(err.Error(), dir) {
			t.Fatal("special file accepted or path disclosed")
		}
	}
}

func TestLibraryRootRejectsUnbundledProcess(t *testing.T) {
	if _, err := LibraryRoot(); err == nil {
		t.Fatal("untrusted process obtained a library root")
	}
}

func TestLockedPDFIsRejected(t *testing.T) {
	var encrypted []byte
	err := native(context.Background(), func() error {
		pdf, _, err := openPDF(context.Background(), syntheticPDF(1, 600, 800))
		if err != nil {
			return err
		}
		defer release(pdf)
		options := send(class("NSMutableDictionary"), "dictionary")
		for _, symbol := range []string{"PDFDocumentOwnerPasswordOption", "PDFDocumentUserPasswordOption"} {
			p, e := purego.Dlsym(purego.RTLD_DEFAULT, symbol)
			if e != nil {
				return document.ErrUnavailable
			}
			key := **(**id)(unsafe.Pointer(&p))
			send(options, "setObject:forKey:", uintptr(nsString("synthetic-test-only")), uintptr(key))
		}
		data := send(pdf, "dataRepresentationWithOptions:", uintptr(options))
		if data == 0 {
			return document.ErrInvalid
		}
		n := int(send(data, "length"))
		if n < 1 || n > document.MaxFileBytes {
			return document.ErrLimit
		}
		p := send(data, "bytes")
		encrypted = append([]byte(nil), unsafe.Slice(*(**byte)(unsafe.Pointer(&p)), n)...)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Extract(context.Background(), encrypted); !errors.Is(err, document.ErrLocked) {
		t.Fatalf("encrypted PDF: %v", err)
	}
	if _, err := RenderPage(context.Background(), encrypted, 1); !errors.Is(err, document.ErrLocked) {
		t.Fatalf("encrypted PDF preview: %v", err)
	}
}

func TestMalformedPNGWithOversizedHeaderIsRejected(t *testing.T) {
	for _, dims := range [][2]uint32{{20001, 1}, {20000, 6001}} {
		var b bytes.Buffer
		if err := png.Encode(&b, image.NewRGBA(image.Rect(0, 0, 1, 1))); err != nil {
			t.Fatal(err)
		}
		data := b.Bytes()
		binary.BigEndian.PutUint32(data[16:20], dims[0])
		binary.BigEndian.PutUint32(data[20:24], dims[1])
		binary.BigEndian.PutUint32(data[29:33], crc32.ChecksumIEEE(data[12:29]))
		// ImageIO may reject inconsistent compressed data before returning its
		// declared dimensions; either refusal happens before raster allocation.
		if _, err := RenderPage(context.Background(), data, 1); !errors.Is(err, document.ErrLimit) && !errors.Is(err, document.ErrInvalid) {
			t.Fatalf("image dimensions %v: %v", dims, err)
		}
	}
}

func TestValidPNGOverEdgeLimitIsRejected(t *testing.T) {
	// A valid single-row image is enough to prove the content geometry check;
	// the fixture needs only ~20 KB of pixels, rather than a giant allocation.
	var b bytes.Buffer
	if err := png.Encode(&b, image.NewGray(image.Rect(0, 0, document.MaxImageEdge+1, 1))); err != nil {
		t.Fatal(err)
	}
	if _, err := RenderPage(context.Background(), b.Bytes(), 1); !errors.Is(err, document.ErrLimit) {
		t.Fatalf("valid oversized PNG preview: %v", err)
	}
	if _, err := Extract(context.Background(), b.Bytes()); !errors.Is(err, document.ErrLimit) {
		t.Fatalf("valid oversized PNG recognition: %v", err)
	}
}

func TestRasterDimensionPolicyBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name          string
		width, height int64
		want          error
	}{
		{"zero width", 0, 1, document.ErrInvalid},
		{"negative height", 1, -1, document.ErrInvalid},
		{"edge inclusive", document.MaxImageEdge, 1, nil},
		{"width over", document.MaxImageEdge + 1, 1, document.ErrLimit},
		{"height over", 1, document.MaxImageEdge + 1, document.ErrLimit},
		{"pixel inclusive", document.MaxImageEdge, document.MaxImagePixels / document.MaxImageEdge, nil},
		{"pixels over", document.MaxImageEdge, document.MaxImagePixels/document.MaxImageEdge + 1, document.ErrLimit},
		{"large dimensions cannot overflow product", 1<<63 - 1, 1<<63 - 1, document.ErrLimit},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := validateRasterDimensions(tc.width, tc.height); !errors.Is(err, tc.want) {
				t.Fatalf("dimension policy: got %v, want %v", err, tc.want)
			}
		})
	}
}

func TestJPEGOrientationMatchesPreviewCoordinates(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 80, 40))
	for y := range 40 {
		for x := range 80 {
			c := color.RGBA{R: 240, A: 255}
			if x >= 40 {
				c = color.RGBA{B: 240, A: 255}
			}
			img.SetRGBA(x, y, c)
		}
	}
	var b bytes.Buffer
	if err := jpeg.Encode(&b, img, &jpeg.Options{Quality: 100}); err != nil {
		t.Fatal(err)
	}
	// EXIF orientation 6 means a clockwise quarter-turn. Construct a tiny,
	// little-endian TIFF IFD in a JPEG APP1 segment without external fixtures.
	exif := []byte{'E', 'x', 'i', 'f', 0, 0, 'I', 'I', 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 1, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0}
	data := append([]byte{0xff, 0xd8, 0xff, 0xe1, 0, byte(len(exif) + 2)}, exif...)
	data = append(data, b.Bytes()[2:]...)
	got, err := RenderPage(context.Background(), data, 1)
	if err != nil {
		t.Fatal(err)
	}
	if got.Bounds().Dx() != 40 || got.Bounds().Dy() != 80 {
		t.Fatalf("orientation dimensions: %v", got.Bounds())
	}
	r, _, bl, _ := got.At(20, 10).RGBA()
	if r <= bl {
		t.Fatal("orientation did not preserve top-left source placement")
	}
	r, _, bl, _ = got.At(20, 70).RGBA()
	if bl <= r {
		t.Fatal("orientation did not preserve bottom-right source placement")
	}
}

func TestOutputBudgetsAndLateCancellation(t *testing.T) {
	for _, text := range []string{strings.Repeat("a", document.MaxBlockBytes+1)} {
		var result document.Extraction
		if err := appendBlock(&result, document.Block{Text: text}); !errors.Is(err, document.ErrLimit) {
			t.Fatal("block byte budget not enforced")
		}
	}
	var result document.Extraction
	for range document.MaxBlocks {
		if err := appendBlock(&result, document.Block{Text: "a"}); err != nil {
			t.Fatal(err)
		}
	}
	if err := appendBlock(&result, document.Block{Text: "a"}); !errors.Is(err, document.ErrLimit) {
		t.Fatal("block count budget not enforced")
	}
	result = document.Extraction{}
	for range document.MaxTextBytes / document.MaxBlockBytes {
		if err := appendBlock(&result, document.Block{Text: strings.Repeat("a", document.MaxBlockBytes)}); err != nil {
			t.Fatal(err)
		}
	}
	if err := appendBlock(&result, document.Block{Text: "a"}); !errors.Is(err, document.ErrLimit) {
		t.Fatal("aggregate byte budget not enforced")
	}
	ctx, cancel := context.WithCancel(context.Background())
	if err := native(ctx, func() error { cancel(); return nil }); !errors.Is(err, context.Canceled) {
		t.Fatal("late cancellation reported success")
	}
}

func TestPreviewParentRejectsUnsafeExistingDirectory(t *testing.T) {
	base := t.TempDir()
	if err := ensurePreviewParent(base); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(base, "KinlogueGoPreview"))
	if err != nil || info.Mode().Perm() != 0700 {
		t.Fatal("private parent permissions")
	}
	unsafeBase := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(unsafeBase, "KinlogueGoPreview")); err != nil {
		t.Fatal(err)
	}
	if err := ensurePreviewParent(unsafeBase); !errors.Is(err, ErrIdentity) {
		t.Fatal("symlink preview parent accepted")
	}
	if err := os.Chmod(filepath.Join(base, "KinlogueGoPreview"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := ensurePreviewParent(base); !errors.Is(err, ErrIdentity) {
		t.Fatal("publicly readable preview parent accepted")
	}
}

func TestTIFFRejectsMultipleFrames(t *testing.T) {
	for _, frames := range []uintptr{1, 2} {
		data := syntheticTIFF(t, frames)
		got, err := RenderPage(context.Background(), data, 1)
		if frames == 1 {
			if err != nil || got.Bounds().Dx() != 8 || got.Bounds().Dy() != 4 {
				t.Fatalf("single-frame TIFF: %v", err)
			}
		} else if !errors.Is(err, document.ErrLimit) {
			t.Fatalf("multiple-frame TIFF: %v", err)
		}
	}
}

func syntheticTIFF(t *testing.T, frames uintptr) []byte {
	t.Helper()
	var encoded []byte
	err := native(context.Background(), func() error {
		var b bytes.Buffer
		if err := png.Encode(&b, image.NewRGBA(image.Rect(0, 0, 8, 4))); err != nil {
			return err
		}
		img, _, err := openImage(b.Bytes())
		if err != nil {
			return err
		}
		defer imageRelease(img)
		var create func(id, id, uintptr, id) uintptr
		var add func(uintptr, uintptr, id)
		var finalize func(uintptr) bool
		purego.RegisterLibFunc(&create, purego.RTLD_DEFAULT, "CGImageDestinationCreateWithData")
		purego.RegisterLibFunc(&add, purego.RTLD_DEFAULT, "CGImageDestinationAddImage")
		purego.RegisterLibFunc(&finalize, purego.RTLD_DEFAULT, "CGImageDestinationFinalize")
		buffer := send(class("NSMutableData"), "data")
		destination := create(buffer, nsString("public.tiff"), frames, 0)
		if destination == 0 {
			return document.ErrUnavailable
		}
		defer cfRelease(destination)
		for range frames {
			add(destination, img, 0)
		}
		if !finalize(destination) {
			return document.ErrInvalid
		}
		n := int(send(buffer, "length"))
		p := send(buffer, "bytes")
		encoded = append([]byte(nil), unsafe.Slice(*(**byte)(unsafe.Pointer(&p)), n)...)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func TestLargeImagePreviewIsBounded(t *testing.T) {
	var b bytes.Buffer
	if err := png.Encode(&b, image.NewGray(image.Rect(0, 0, 5000, 2500))); err != nil {
		t.Fatal(err)
	}
	got, err := RenderPage(context.Background(), b.Bytes(), 1)
	if err != nil {
		t.Fatal(err)
	}
	if got.Bounds().Dx() != document.MaxRenderEdge || got.Bounds().Dy() != document.MaxRenderEdge/2 {
		t.Fatal("image thumbnail was not bounded")
	}
}

func TestReadImportedFileRejectsOversizedSparseSource(t *testing.T) {
	path := filepath.Join(t.TempDir(), "synthetic.bin")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(document.MaxFileBytes + 1); err != nil {
		f.Close()
		t.Fatal(err)
	}
	f.Close()
	if _, err := ReadImportedFile(path); !errors.Is(err, document.ErrLimit) {
		t.Fatalf("oversized source: %v", err)
	}
}

func TestRotatedPDFSourcesMatchRenderedPage(t *testing.T) {
	for _, rotation := range []int{0, 90, 180, 270} {
		data := syntheticPDFRotation(1, 600, 800, rotation)
		extraction, err := Extract(context.Background(), data)
		if err != nil {
			t.Fatal(err)
		}
		img, err := RenderPage(context.Background(), data, 1)
		if err != nil {
			t.Fatal(err)
		}
		width, height := img.Bounds().Dx(), img.Bounds().Dy()
		minX, minY, maxX, maxY := width, height, -1, -1
		for y := range height {
			for x := range width {
				r, g, b, _ := img.At(x, y).RGBA()
				if r < 0x8000 && g < 0x8000 && b < 0x8000 {
					minX = min(minX, x)
					maxX = max(maxX, x)
					minY = min(minY, y)
					maxY = max(maxY, y)
				}
			}
		}
		if maxX < 0 || len(extraction.Blocks) != 1 {
			t.Fatal("missing synthetic page text")
		}
		source := extraction.Blocks[0].Bounds
		centerX := float64(minX+maxX) / 2 / float64(width)
		centerY := 1 - float64(minY+maxY)/2/float64(height)
		if centerX < source.X || centerX > source.X+source.Width || centerY < source.Y || centerY > source.Y+source.Height {
			t.Fatalf("rotated source no longer identifies rendered text (rotation %d): source=%+v center=%f,%f dimensions=%d,%d", rotation, source, centerX, centerY, width, height)
		}
	}
}

func TestPDFPreviewIncludesAnnotationAppearance(t *testing.T) {
	appearance := "1 0 0 rg 0 0 100 100 re f"
	data := encodePDFObjects([]string{
		"<< /Type /Catalog /Pages 2 0 R >>",
		"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
		"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Annots [4 0 R] /Contents 5 0 R /Resources << >> >>",
		"<< /Type /Annot /Subtype /Stamp /Rect [40 50 140 150] /F 4 /AP << /N 6 0 R >> >>",
		"<< /Length 0 >>\nstream\n\nendstream",
		fmt.Sprintf("<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources << >> /Length %d >>\nstream\n%s\nendstream", len(appearance), appearance),
	})
	img, err := RenderPage(context.Background(), data, 1)
	if err != nil {
		t.Fatal(err)
	}
	r, g, b, _ := img.At(180, 200).RGBA()
	if r < 0xf000 || g > 0x1000 || b > 0x1000 {
		t.Fatal("PDF annotation appearance was omitted from original preview")
	}
}
