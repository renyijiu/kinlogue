package backup

import (
	"bytes"
	"context"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestEncryptionAuthenticatesCompleteStream(t *testing.T) {
	ctx := context.Background()
	code, err := NewCode()
	if err != nil {
		t.Fatal(err)
	}
	other, err := NewCode()
	if err != nil {
		t.Fatal(err)
	}
	id, err := ValidateCode(code)
	if err != nil || id == "" {
		t.Fatal("invalid generated code")
	}
	if otherID, _ := ValidateCode(other); id == otherID {
		t.Fatal("reused backup identity")
	}
	plain := bytes.Repeat([]byte("synthetic archive"), 10000)
	var ciphertext bytes.Buffer
	digest, err := Encrypt(ctx, &ciphertext, code, func(w io.Writer) error { _, err := w.Write(plain); return err })
	if err != nil {
		t.Fatal(err)
	}
	read := func(r io.Reader) error {
		got, err := io.ReadAll(r)
		if err == nil && !bytes.Equal(got, plain) {
			t.Fatal("plaintext changed")
		}
		return err
	}
	if err := Verify(ctx, bytes.NewReader(ciphertext.Bytes()), code, digest, read); err != nil {
		t.Fatal(err)
	}
	badDigest := digest
	badDigest[0] ^= 1
	if err := Verify(ctx, bytes.NewReader(ciphertext.Bytes()), code, badDigest, read); err == nil {
		t.Fatal("wrong readback digest accepted")
	}
	if err := Decrypt(ctx, bytes.NewReader(ciphertext.Bytes()), other, read); err == nil {
		t.Fatal("wrong code accepted")
	}
	for name, mutate := range map[string]func([]byte) []byte{
		"truncated": func(b []byte) []byte { return b[:len(b)-1] },
		"tampered":  func(b []byte) []byte { b[len(b)-1] ^= 1; return b },
		"tail":      func(b []byte) []byte { return append(b, 1) },
	} {
		t.Run(name, func(t *testing.T) {
			bad := mutate(append([]byte{}, ciphertext.Bytes()...))
			if err := Decrypt(ctx, bytes.NewReader(bad), code, func(r io.Reader) error { var b [1]byte; _, err := r.Read(b[:]); return err }); err == nil {
				t.Fatal("incomplete authentication accepted")
			}
		})
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := Encrypt(cancelled, io.Discard, code, func(w io.Writer) error { _, err := w.Write(plain); return err }); !errors.Is(err, context.Canceled) {
		t.Fatal("cancel ignored")
	}
	if _, err := ValidateCode("synthetic-invalid-code"); err == nil {
		t.Fatal("invalid code accepted")
	}
}

type failFinalWriter struct {
	bytes.Buffer
	writes int
}

func (w *failFinalWriter) Write(p []byte) (int, error) {
	w.writes++
	if w.writes > 2 {
		return 0, errors.New("synthetic_failure")
	}
	return w.Buffer.Write(p)
}
func TestEncryptionChecksFinalWriterClose(t *testing.T) {
	code, _ := NewCode()
	w := &failFinalWriter{}
	if _, err := Encrypt(context.Background(), w, code, func(w io.Writer) error { _, err := w.Write([]byte("short synthetic")); return err }); err == nil {
		t.Fatal("final flush failure accepted")
	}
}

func TestEncryptionBudgetsAndCancellationDuringRead(t *testing.T) {
	ctx := context.Background()
	code, _ := NewCode()
	oversized := strings.NewReader("age-encryption.org/v1\n" + strings.Repeat("-> synthetic\nYQ\n", 10000))
	if err := Decrypt(ctx, oversized, code, func(r io.Reader) error { _, err := io.Copy(io.Discard, r); return err }); err == nil {
		t.Fatalf("unbounded header: %v", err)
	}
	r := &budgetReader{ctx: ctx, r: strings.NewReader("four"), left: 3}
	if _, err := io.ReadAll(r); !errors.Is(err, ErrLimit) {
		t.Fatal("read budget bypassed")
	}
	w := &budgetWriter{ctx: ctx, w: io.Discard, left: 3}
	if _, err := w.Write([]byte("four")); !errors.Is(err, ErrLimit) {
		t.Fatal("write budget bypassed")
	}
	var ciphertext bytes.Buffer
	_, err := Encrypt(ctx, &ciphertext, code, func(w io.Writer) error { _, err := w.Write(bytes.Repeat([]byte("synthetic"), 20000)); return err })
	if err != nil {
		t.Fatal(err)
	}
	cancelled, cancel := context.WithCancel(ctx)
	if err := Decrypt(cancelled, bytes.NewReader(ciphertext.Bytes()), code, func(r io.Reader) error { var b [1]byte; _, err := r.Read(b[:]); cancel(); return err }); !errors.Is(err, context.Canceled) {
		t.Fatal("read cancellation ignored")
	}
}
