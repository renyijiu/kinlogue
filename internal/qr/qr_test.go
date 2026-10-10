package qr

import (
	"bytes"
	"strings"
	"testing"
)

// Reed-Solomon check from the ISO/IEC 18004 annex example for "01234567"
// (version 1-M data codewords).
func TestReedSolomonKnownAnswer(t *testing.T) {
	data := []byte{0x10, 0x20, 0x0c, 0x56, 0x61, 0x80, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11}
	want := []byte{0xa5, 0x24, 0xd4, 0xc1, 0xed, 0x36, 0xc7, 0x87, 0x2c, 0x55}
	if got := reedSolomon(data, 10); !bytes.Equal(got, want) {
		t.Fatalf("got % x", got)
	}
}

func TestFormatAndVersionBitsKnownAnswers(t *testing.T) {
	// Level M with mask 0 and mask 5 from the standard format table.
	if got := formatBits(0); got != 0b101010000010010 {
		t.Fatalf("format M/0 = %015b", got)
	}
	if got := formatBits(5); got != 0b100000011001110 {
		t.Fatalf("format M/5 = %015b", got)
	}
	// Version 7 information from the standard version table.
	if got := versionBits(7); got != 0b000111110010010100 {
		t.Fatalf("version 7 = %018b", got)
	}
}

func TestVersionSelectionAndLimits(t *testing.T) {
	for _, tc := range []struct {
		n, version int
	}{{14, 1}, {15, 2}, {26, 2}, {27, 3}, {62, 4}, {63, 5}, {213, 10}} {
		c, err := Encode(bytes.Repeat([]byte{'a'}, tc.n))
		if err != nil || c.Version != tc.version || c.Size != 17+4*tc.version {
			t.Fatalf("%d bytes: version %v err %v", tc.n, c, err)
		}
	}
	if _, err := Encode(bytes.Repeat([]byte{'a'}, 214)); err != ErrTooLong {
		t.Fatal("expected ErrTooLong")
	}
}

func TestFunctionPatterns(t *testing.T) {
	c, err := Encode([]byte("http://192.168.1.20:52345/"))
	if err != nil {
		t.Fatal(err)
	}
	for _, corner := range [][2]int{{0, 0}, {c.Size - 7, 0}, {0, c.Size - 7}} {
		for i := 0; i < 7; i++ {
			for _, p := range [][2]int{{i, 0}, {i, 6}, {0, i}, {6, i}} {
				if !c.Dark(corner[0]+p[0], corner[1]+p[1]) {
					t.Fatal("finder border must be dark")
				}
			}
		}
		if !c.Dark(corner[0]+3, corner[1]+3) || c.Dark(corner[0]+1, corner[1]+1) {
			t.Fatal("finder core or ring is wrong")
		}
	}
	for i := 8; i < c.Size-8; i++ {
		if c.Dark(i, 6) != (i%2 == 0) || c.Dark(6, i) != (i%2 == 0) {
			t.Fatal("timing pattern is wrong")
		}
	}
	if !c.Dark(8, c.Size-8) {
		t.Fatal("dark module missing")
	}
	img := c.Image(3)
	if img.Bounds().Dx() != (c.Size+8)*3 || img.GrayAt(0, 0).Y != 0xff || img.GrayAt(12, 12).Y != 0 {
		t.Fatal("image quiet zone or scale is wrong")
	}
}

// String renders the matrix for the external decoder fixtures.
func (c *Code) String() string {
	var b strings.Builder
	for y := 0; y < c.Size; y++ {
		for x := 0; x < c.Size; x++ {
			if c.Dark(x, y) {
				b.WriteByte('1')
			} else {
				b.WriteByte('0')
			}
		}
		b.WriteByte('\n')
	}
	return b.String()
}
