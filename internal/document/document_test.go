package document

import (
	"strings"
	"testing"
)

func TestExtractionValidation(t *testing.T) {
	good := Extraction{PageCount: 1, Engine: "synthetic", Blocks: []Block{{Page: 1, Text: "Synthetic report", Bounds: Rect{Width: 1, Height: 1}, Confidence: 1, Method: "text-layer"}}}
	if err := good.Validate(); err != nil {
		t.Fatal(err)
	}
	bad := good
	bad.Blocks = append([]Block(nil), good.Blocks...)
	bad.Blocks[0].Page = 2
	if err := bad.Validate(); err == nil {
		t.Fatal("accepted a nonexistent source page")
	}
	bad.Blocks[0] = good.Blocks[0]
	bad.Blocks[0].Text = strings.Repeat("x", MaxBlockBytes+1)
	if err := bad.Validate(); err == nil {
		t.Fatal("accepted oversized transcription")
	}
}

func TestDateMustBeExplicitAndValid(t *testing.T) {
	for _, value := range []string{"", "2024-02-29", "2026-10-07"} {
		if err := ValidateDate(value); err != nil {
			t.Fatalf("valid date rejected: %v", err)
		}
	}
	for _, value := range []string{"2025-02-29", "2026-02-30", "tomorrow", "2026-1-2"} {
		if err := ValidateDate(value); err == nil {
			t.Fatal("invalid date accepted")
		}
	}
}
