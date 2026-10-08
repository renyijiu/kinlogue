// Package backup provides the authenticated stream used by manual backups. It
// owns no files and never persists the per-backup recovery identity.
package backup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"strings"

	"filippo.io/age"
)

const (
	MaxPlaintextBytes  int64 = 64 << 30
	MaxCiphertextBytes int64 = 65 << 30
)

var (
	ErrCode    = errors.New("backup_invalid_code")
	ErrInvalid = errors.New("backup_invalid_data")
	ErrLimit   = errors.New("backup_resource_limit")
	ErrWrite   = errors.New("backup_write_failed")
)

func NewCode() (string, error) {
	identity, err := age.GenerateHybridIdentity()
	if err != nil {
		return "", ErrCode
	}
	return identity.String(), nil
}

func parseCode(code string) (*age.HybridIdentity, error) {
	if len(code) > 512 {
		return nil, ErrCode
	}
	identity, err := age.ParseHybridIdentity(strings.TrimSpace(code))
	if err != nil {
		return nil, ErrCode
	}
	return identity, nil
}

// ValidateCode returns a public identifier for pairing a code with its backup.
func ValidateCode(code string) (string, error) {
	identity, err := parseCode(code)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256([]byte(identity.Recipient().String()))
	return hex.EncodeToString(digest[:8]), nil
}

// Encrypt returns the plaintext digest for full readback verification. Success
// includes Close: age buffers and authenticates the final chunk there.
func Encrypt(ctx context.Context, dst io.Writer, code string, write func(io.Writer) error) ([32]byte, error) {
	var result [32]byte
	if err := ctx.Err(); err != nil {
		return result, err
	}
	identity, err := parseCode(code)
	if err != nil {
		return result, err
	}
	output := &budgetWriter{ctx: ctx, w: dst, left: MaxCiphertextBytes}
	encrypted, err := age.Encrypt(output, identity.Recipient())
	if err != nil {
		return result, cryptoError(ctx, err, ErrWrite)
	}
	hash := sha256.New()
	plain := &budgetWriter{ctx: ctx, w: io.MultiWriter(encrypted, hash), left: MaxPlaintextBytes}
	if err = write(plain); err != nil {
		return result, cryptoError(ctx, err, ErrWrite)
	}
	if plain.err != nil {
		return result, cryptoError(ctx, plain.err, ErrWrite)
	}
	if err = encrypted.Close(); err != nil {
		return result, cryptoError(ctx, err, ErrWrite)
	}
	if output.err != nil {
		return result, cryptoError(ctx, output.err, ErrWrite)
	}
	if err = ctx.Err(); err != nil {
		return result, err
	}
	copy(result[:], hash.Sum(nil))
	return result, nil
}

// Decrypt does not trust the consumer's EOF. Even a consumer which returns
// early must pass authentication of every remaining chunk and the true EOF.
func Decrypt(ctx context.Context, src io.Reader, code string, read func(io.Reader) error) error {
	_, err := decrypt(ctx, src, code, read)
	return err
}

func Verify(ctx context.Context, src io.Reader, code string, expected [32]byte, read func(io.Reader) error) error {
	actual, err := decrypt(ctx, src, code, read)
	if err != nil {
		return err
	}
	if actual != expected {
		return ErrInvalid
	}
	return nil
}

func decrypt(ctx context.Context, src io.Reader, code string, read func(io.Reader) error) ([32]byte, error) {
	var result [32]byte
	if err := ctx.Err(); err != nil {
		return result, err
	}
	identity, err := parseCode(code)
	if err != nil {
		return result, err
	}
	// The pinned age parser separately caps headers at 2 MiB and 1,024 stanzas.
	input := &budgetReader{ctx: ctx, r: src, left: MaxCiphertextBytes}
	plain, err := age.Decrypt(input, identity)
	if err != nil {
		return result, cryptoError(ctx, err, ErrInvalid)
	}
	hash := sha256.New()
	plaintext := &budgetReader{ctx: ctx, r: io.TeeReader(plain, hash), left: MaxPlaintextBytes}
	if err = read(plaintext); err != nil {
		return result, cryptoError(ctx, err, ErrInvalid)
	}
	if _, err = io.Copy(io.Discard, plaintext); err != nil {
		return result, cryptoError(ctx, err, ErrInvalid)
	}
	if err = ctx.Err(); err != nil {
		return result, err
	}
	copy(result[:], hash.Sum(nil))
	return result, nil
}

type budgetReader struct {
	ctx      context.Context
	r        io.Reader
	left     int64
	exceeded bool
}

func (r *budgetReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	if r.exceeded {
		return 0, ErrLimit
	}
	if int64(len(p)) > r.left+1 {
		p = p[:r.left+1]
	}
	n, err := r.r.Read(p)
	r.left -= int64(n)
	if r.left < 0 {
		r.exceeded = true
		return 0, ErrLimit
	}
	return n, err
}

type budgetWriter struct {
	ctx  context.Context
	w    io.Writer
	left int64
	err  error
}

func (w *budgetWriter) Write(p []byte) (int, error) {
	if w.err != nil {
		return 0, w.err
	}
	if err := w.ctx.Err(); err != nil {
		w.err = err
		return 0, err
	}
	if int64(len(p)) > w.left {
		w.err = ErrLimit
		return 0, w.err
	}
	n, err := w.w.Write(p)
	w.left -= int64(n)
	if err == nil && n != len(p) {
		err = io.ErrShortWrite
	}
	w.err = err
	return n, err
}
func cryptoError(ctx context.Context, err, errorCode error) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if errors.Is(err, ErrLimit) {
		return ErrLimit
	}
	return errorCode
}
