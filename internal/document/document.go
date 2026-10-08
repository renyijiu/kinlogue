// Package document contains the source-transcription contract shared by storage,
// on-device recognition and review. Recognition never confirms a record.
package document

import (
	"errors"
	"math"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	MaxSources     = 20
	MaxFileBytes   = 100 << 20
	MaxPages       = 200
	MaxImageEdge   = 20_000
	MaxImagePixels = 120_000_000
	MaxPDFEdge     = 14_400
	MaxRenderEdge  = 2_400
	MaxBlocks      = 4_096
	MaxBlockBytes  = 64 << 10
	MaxTextBytes   = 1 << 20
)

var (
	ErrInvalid     = errors.New("invalid_document")
	ErrUnsupported = errors.New("unsupported_document")
	ErrLimit       = errors.New("document_resource_limit")
	ErrLocked      = errors.New("locked_document")
	ErrUnavailable = errors.New("recognition_unavailable")
)

// Rect uses normalized page coordinates with the origin at the bottom left.
type Rect struct{ X, Y, Width, Height float64 }

type Block struct {
	Page       int
	Text       string
	Bounds     Rect
	Confidence float64
	Method     string
}

type Extraction struct {
	Kind      string // pdf, jpeg, png, heic, or tiff, determined from content
	PageCount int
	Engine    string
	Blocks    []Block
}

func (e Extraction) Validate() error {
	if e.PageCount < 1 || e.Engine == "" {
		return ErrInvalid
	}
	if e.PageCount > MaxPages || len(e.Blocks) > MaxBlocks {
		return ErrLimit
	}
	bytes := 0
	for _, b := range e.Blocks {
		if b.Page < 1 || b.Page > e.PageCount || !utf8.ValidString(b.Text) || b.Method == "" {
			return ErrInvalid
		}
		if math.IsNaN(b.Confidence) || b.Confidence < 0 || b.Confidence > 1 {
			return ErrInvalid
		}
		for _, n := range []float64{b.Bounds.X, b.Bounds.Y, b.Bounds.Width, b.Bounds.Height} {
			if math.IsNaN(n) || math.IsInf(n, 0) || n < 0 || n > 1 {
				return ErrInvalid
			}
		}
		if b.Bounds.X+b.Bounds.Width > 1.000001 || b.Bounds.Y+b.Bounds.Height > 1.000001 {
			return ErrInvalid
		}
		bytes += len(b.Text)
		if len(b.Text) > MaxBlockBytes || bytes > MaxTextBytes {
			return ErrLimit
		}
	}
	return nil
}

func (e Extraction) Text() string {
	parts := make([]string, 0, len(e.Blocks))
	for _, b := range e.Blocks {
		parts = append(parts, b.Text)
	}
	return strings.Join(parts, "\n")
}

// An empty date explicitly means unknown; dates are civil days, not instants.
func ValidateDate(value string) error {
	if value == "" {
		return nil
	}
	d, err := time.Parse("2006-01-02", value)
	if err != nil || d.Format("2006-01-02") != value {
		return ErrInvalid
	}
	return nil
}
