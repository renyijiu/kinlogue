// Package qr encodes short byte strings, such as the phone upload URL, as QR
// Code symbols (ISO/IEC 18004) using byte mode and error correction level M.
// It supports versions 1 through 10, which covers any URL Kinlogue shows.
// The encoder is self-contained so the preview needs no extra module.
package qr

import (
	"errors"
	"image"
	"image/color"
)

// ErrTooLong reports input that does not fit version 10 at level M.
var ErrTooLong = errors.New("qr: data too long")

// Code is a square module matrix; true marks a dark module.
type Code struct {
	Size    int
	Version int
	Mask    int
	modules []bool
}

// Dark reports whether module (x, y) is dark. Outside the symbol is light.
func (c *Code) Dark(x, y int) bool {
	if x < 0 || y < 0 || x >= c.Size || y >= c.Size {
		return false
	}
	return c.modules[y*c.Size+x]
}

// Image renders the symbol with the standard four-module quiet zone. Each
// module is scale pixels wide; scale below one is treated as one.
func (c *Code) Image(scale int) *image.Gray {
	if scale < 1 {
		scale = 1
	}
	const quiet = 4
	side := (c.Size + 2*quiet) * scale
	img := image.NewGray(image.Rect(0, 0, side, side))
	for i := range img.Pix {
		img.Pix[i] = 0xff
	}
	for y := 0; y < c.Size; y++ {
		for x := 0; x < c.Size; x++ {
			if !c.Dark(x, y) {
				continue
			}
			for dy := 0; dy < scale; dy++ {
				for dx := 0; dx < scale; dx++ {
					img.SetGray((x+quiet)*scale+dx, (y+quiet)*scale+dy, color.Gray{})
				}
			}
		}
	}
	return img
}

// Error correction level M block structure per version: EC codewords per
// block, then (blocks, data codewords) for group one and group two.
var blocksM = [11][5]int{
	{},
	{10, 1, 16, 0, 0},
	{16, 1, 28, 0, 0},
	{26, 1, 44, 0, 0},
	{18, 2, 32, 0, 0},
	{24, 2, 43, 0, 0},
	{16, 4, 27, 0, 0},
	{18, 4, 31, 0, 0},
	{22, 2, 38, 2, 39},
	{22, 3, 36, 2, 37},
	{26, 4, 43, 1, 44},
}

var alignment = [11][]int{
	{}, {}, {6, 18}, {6, 22}, {6, 26}, {6, 30}, {6, 34},
	{6, 22, 38}, {6, 24, 42}, {6, 26, 46}, {6, 28, 50},
}

func dataCapacity(version int) int {
	b := blocksM[version]
	return b[1]*b[2] + b[3]*b[4]
}

func countBits(version int) int {
	if version <= 9 {
		return 8
	}
	return 16
}

// Encode returns the smallest symbol that holds data, choosing the mask with
// the lowest standard penalty score.
func Encode(data []byte) (*Code, error) {
	for version := 1; version <= 10; version++ {
		if 4+countBits(version)+8*len(data) <= 8*dataCapacity(version) {
			return encode(data, version, -1), nil
		}
	}
	return nil, ErrTooLong
}

func encode(data []byte, version, forcedMask int) *Code {
	codewords := interleave(version, dataCodewords(data, version))
	base := newMatrix(version)
	base.placeData(codewords)
	best, bestScore := (*matrix)(nil), 0
	for mask := 0; mask < 8; mask++ {
		if forcedMask >= 0 && mask != forcedMask {
			continue
		}
		candidate := base.withMask(mask)
		score := candidate.penalty()
		if best == nil || score < bestScore {
			best, bestScore = candidate, score
		}
	}
	return &Code{Size: best.size, Version: version, Mask: best.mask, modules: best.dark}
}

type bitBuffer struct {
	bytes []byte
	n     int
}

func (b *bitBuffer) put(value uint, bits int) {
	for i := bits - 1; i >= 0; i-- {
		if b.n%8 == 0 {
			b.bytes = append(b.bytes, 0)
		}
		if value>>uint(i)&1 == 1 {
			b.bytes[b.n/8] |= 0x80 >> uint(b.n%8)
		}
		b.n++
	}
}

func dataCodewords(data []byte, version int) []byte {
	capacity := dataCapacity(version)
	var b bitBuffer
	b.put(0b0100, 4)
	b.put(uint(len(data)), countBits(version))
	for _, v := range data {
		b.put(uint(v), 8)
	}
	terminator := min(4, 8*capacity-b.n)
	b.put(0, terminator)
	if b.n%8 != 0 {
		b.put(0, 8-b.n%8)
	}
	for pad := 0; len(b.bytes) < capacity; pad++ {
		if pad%2 == 0 {
			b.bytes = append(b.bytes, 0xec)
		} else {
			b.bytes = append(b.bytes, 0x11)
		}
	}
	return b.bytes
}

func interleave(version int, data []byte) []byte {
	spec := blocksM[version]
	ec := spec[0]
	var blocks, checks [][]byte
	offset := 0
	for group := 0; group < 2; group++ {
		count, size := spec[1+2*group], spec[2+2*group]
		for i := 0; i < count; i++ {
			block := data[offset : offset+size]
			offset += size
			blocks = append(blocks, block)
			checks = append(checks, reedSolomon(block, ec))
		}
	}
	var out []byte
	longest := max(spec[2], spec[4])
	for i := 0; i < longest; i++ {
		for _, block := range blocks {
			if i < len(block) {
				out = append(out, block[i])
			}
		}
	}
	for i := 0; i < ec; i++ {
		for _, check := range checks {
			out = append(out, check[i])
		}
	}
	return out
}

var gfExp, gfLog = func() ([512]byte, [256]byte) {
	var exp [512]byte
	var log [256]byte
	x := 1
	for i := 0; i < 255; i++ {
		exp[i] = byte(x)
		log[x] = byte(i)
		x <<= 1
		if x&0x100 != 0 {
			x ^= 0x11d
		}
	}
	for i := 255; i < 512; i++ {
		exp[i] = exp[i-255]
	}
	return exp, log
}()

func gfMul(a, b byte) byte {
	if a == 0 || b == 0 {
		return 0
	}
	return gfExp[int(gfLog[a])+int(gfLog[b])]
}

func reedSolomon(data []byte, degree int) []byte {
	// Generator polynomial (x - a^0)(x - a^1)...(x - a^(degree-1)), with the
	// implicit leading coefficient 1 omitted.
	generator := make([]byte, degree)
	generator[degree-1] = 1
	root := byte(1)
	for i := 0; i < degree; i++ {
		for j := 0; j < degree; j++ {
			generator[j] = gfMul(generator[j], root)
			if j+1 < degree {
				generator[j] ^= generator[j+1]
			}
		}
		root = gfMul(root, 2)
	}
	remainder := make([]byte, degree)
	for _, b := range data {
		factor := b ^ remainder[0]
		copy(remainder, remainder[1:])
		remainder[degree-1] = 0
		for i := range remainder {
			remainder[i] ^= gfMul(generator[i], factor)
		}
	}
	return remainder
}

type matrix struct {
	size     int
	mask     int
	dark     []bool
	reserved []bool
}

func newMatrix(version int) *matrix {
	size := 17 + 4*version
	m := &matrix{size: size, dark: make([]bool, size*size), reserved: make([]bool, size*size)}
	for _, corner := range [][2]int{{0, 0}, {size - 7, 0}, {0, size - 7}} {
		m.finder(corner[0], corner[1])
	}
	for i := 8; i < size-8; i++ {
		m.set(i, 6, i%2 == 0)
		m.set(6, i, i%2 == 0)
	}
	positions := alignment[version]
	last := len(positions) - 1
	for i, y := range positions {
		for j, x := range positions {
			// Skip the three corners occupied by finder patterns. Patterns on the
			// timing lines are drawn and replace those timing modules.
			if i == 0 && j == 0 || i == 0 && j == last || i == last && j == 0 {
				continue
			}
			for dy := -2; dy <= 2; dy++ {
				for dx := -2; dx <= 2; dx++ {
					edge := max(abs(dx), abs(dy))
					m.set(x+dx, y+dy, edge != 1)
				}
			}
		}
	}
	// Format areas (written after masking) and the fixed dark module.
	for i := 0; i < 9; i++ {
		m.reserve(8, i)
		m.reserve(i, 8)
	}
	for i := 0; i < 8; i++ {
		m.reserve(size-1-i, 8)
		m.reserve(8, size-1-i)
	}
	m.set(8, size-8, true)
	if version >= 7 {
		bits := versionBits(version)
		for i := 0; i < 18; i++ {
			on := bits>>uint(i)&1 == 1
			a, b := i/3, size-11+i%3
			m.set(a, b, on)
			m.set(b, a, on)
		}
	}
	return m
}

func (m *matrix) set(x, y int, dark bool) {
	m.dark[y*m.size+x] = dark
	m.reserved[y*m.size+x] = true
}

func (m *matrix) reserve(x, y int) { m.reserved[y*m.size+x] = true }

func (m *matrix) finder(left, top int) {
	for dy := -1; dy <= 7; dy++ {
		for dx := -1; dx <= 7; dx++ {
			x, y := left+dx, top+dy
			if x < 0 || y < 0 || x >= m.size || y >= m.size {
				continue
			}
			ring := max(abs(dx-3), abs(dy-3))
			m.set(x, y, ring != 2 && ring != 4)
		}
	}
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

func (m *matrix) placeData(codewords []byte) {
	bit := 0
	total := 8 * len(codewords)
	upward := true
	for right := m.size - 1; right >= 1; right -= 2 {
		if right == 6 {
			right = 5
		}
		for step := 0; step < m.size; step++ {
			y := step
			if upward {
				y = m.size - 1 - step
			}
			for column := 0; column < 2; column++ {
				x := right - column
				if m.reserved[y*m.size+x] {
					continue
				}
				if bit < total {
					m.dark[y*m.size+x] = codewords[bit/8]>>uint(7-bit%8)&1 == 1
				}
				bit++
			}
		}
		upward = !upward
	}
}

func maskBit(mask, x, y int) bool {
	switch mask {
	case 0:
		return (x+y)%2 == 0
	case 1:
		return y%2 == 0
	case 2:
		return x%3 == 0
	case 3:
		return (x+y)%3 == 0
	case 4:
		return (y/2+x/3)%2 == 0
	case 5:
		return x*y%2+x*y%3 == 0
	case 6:
		return (x*y%2+x*y%3)%2 == 0
	default:
		return ((x+y)%2+x*y%3)%2 == 0
	}
}

func (m *matrix) withMask(mask int) *matrix {
	out := &matrix{size: m.size, mask: mask, dark: append([]bool(nil), m.dark...), reserved: m.reserved}
	for y := 0; y < m.size; y++ {
		for x := 0; x < m.size; x++ {
			if !m.reserved[y*m.size+x] && maskBit(mask, x, y) {
				out.dark[y*m.size+x] = !out.dark[y*m.size+x]
			}
		}
	}
	out.writeFormat()
	return out
}

func bch(value, generator uint, bits int) uint {
	degree := 0
	for g := generator; g > 1; g >>= 1 {
		degree++
	}
	remainder := value << uint(degree)
	for i := bits + degree - 1; i >= degree; i-- {
		if remainder>>uint(i)&1 == 1 {
			remainder ^= generator << uint(i-degree)
		}
	}
	return value<<uint(degree) | remainder
}

func formatBits(mask int) uint {
	// Level M is 00 in the two error correction bits.
	return bch(uint(mask), 0x537, 5) ^ 0x5412
}

func versionBits(version int) uint { return bch(uint(version), 0x1f25, 6) }

func (m *matrix) writeFormat() {
	bits := formatBits(m.mask)
	on := func(i int) bool { return bits>>uint(i)&1 == 1 }
	size := m.size
	for i := 0; i < 15; i++ {
		// Around the top-left finder.
		switch {
		case i < 6:
			m.dark[i*size+8] = on(i)
		case i < 8:
			m.dark[(i+1)*size+8] = on(i)
		case i == 8:
			m.dark[8*size+7] = on(i)
		default:
			m.dark[8*size+14-i] = on(i)
		}
		// Split copy beside the other two finders.
		if i < 8 {
			m.dark[8*size+size-1-i] = on(i)
		} else {
			m.dark[(size-15+i)*size+8] = on(i)
		}
	}
	m.dark[(size-8)*size+8] = true
}

func (m *matrix) at(x, y int) bool { return m.dark[y*m.size+x] }

func (m *matrix) penalty() int {
	size := m.size
	score := 0
	// Rule 1: runs of five or more same-colour modules in a row or column.
	for _, vertical := range []bool{false, true} {
		for a := 0; a < size; a++ {
			run, last := 0, false
			for b := 0; b < size; b++ {
				x, y := b, a
				if vertical {
					x, y = a, b
				}
				v := m.at(x, y)
				if b > 0 && v == last {
					run++
				} else {
					if run >= 5 {
						score += run - 2
					}
					run, last = 1, v
				}
			}
			if run >= 5 {
				score += run - 2
			}
		}
	}
	// Rule 2: 2x2 blocks of one colour.
	for y := 0; y < size-1; y++ {
		for x := 0; x < size-1; x++ {
			v := m.at(x, y)
			if v == m.at(x+1, y) && v == m.at(x, y+1) && v == m.at(x+1, y+1) {
				score += 3
			}
		}
	}
	// Rule 3: finder-like 1:1:3:1:1 patterns with four light modules beside them.
	pattern := []bool{true, false, true, true, true, false, true}
	light := func(x, y int, vertical bool, from, to int) bool {
		for i := from; i < to; i++ {
			px, py := i, y
			if vertical {
				px, py = x, i
			}
			if px >= 0 && py >= 0 && px < size && py < size && m.at(px, py) {
				return false
			}
		}
		return true
	}
	for _, vertical := range []bool{false, true} {
		for a := 0; a < size; a++ {
			for b := 0; b+7 <= size; b++ {
				match := true
				for i, want := range pattern {
					x, y := b+i, a
					if vertical {
						x, y = a, b+i
					}
					if m.at(x, y) != want {
						match = false
						break
					}
				}
				if !match {
					continue
				}
				x, y := 0, a
				if vertical {
					x, y = a, 0
				}
				if light(x, y, vertical, b-4, b) || light(x, y, vertical, b+7, b+11) {
					score += 40
				}
			}
		}
	}
	// Rule 4: deviation of the dark proportion from 50%.
	dark := 0
	for _, v := range m.dark {
		if v {
			dark++
		}
	}
	percent := dark * 100 / (size * size)
	deviation := abs(percent-50) / 5
	score += deviation * 10
	return score
}
