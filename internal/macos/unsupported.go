//go:build !darwin

package macos

import (
	"context"
	"errors"
	"image"
	"io"
	"kinlogue/internal/document"
)

func Extract(context.Context, []byte) (document.Extraction, error) {
	return document.Extraction{}, document.ErrUnavailable
}
func RenderPage(context.Context, []byte, int) (image.Image, error) {
	return nil, document.ErrUnavailable
}
func LibraryRoot() (string, error)            { return "", document.ErrUnavailable }
func ReadImportedFile(string) ([]byte, error) { return nil, document.ErrUnavailable }
func PreferredLanguage() string               { return "en" }

var ErrWrite = errors.New("export_write_failed")

func WriteExport(ctx context.Context, _ string, _ func(io.Writer) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return ErrWrite
}
