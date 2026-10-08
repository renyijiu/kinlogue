package app

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"

	"kinlogue/internal/library"
)

var ErrExport = errors.New("original_export_failed")

// ExportOriginals holds mutation admission for one confirmed snapshot. The
// injected platform writer owns the selected-file authorization, ZIP integrity
// check and atomic publication; it must not call a native recognizer itself.
func (s *Service) ExportOriginals(ctx context.Context, id, destination string) error {
	_, err := command(s, ctx, true, func(c context.Context) (struct{}, error) {
		r, err := s.store.Get(c, id)
		if err != nil {
			return struct{}{}, err
		}
		if r.Status != "confirmed" {
			return struct{}{}, library.ErrState
		}
		if s.writeExport == nil {
			return struct{}{}, ErrExport
		}
		err = s.writeExport(c, destination, func(output io.Writer) error {
			archive := zip.NewWriter(output)
			for index, source := range r.Sources {
				if err := c.Err(); err != nil {
					return err
				}
				data, err := s.store.ReadOriginal(c, id, source.ID)
				if err != nil {
					return err
				}
				extension := map[string]string{"pdf": "pdf", "jpeg": "jpg", "png": "png", "heic": "heic", "tiff": "tiff"}[source.Extraction.Kind]
				if extension == "" {
					return library.ErrCorrupt
				}
				header := &zip.FileHeader{Name: fmt.Sprintf("%03d.%s", index+1, extension), Method: zip.Store}
				header.SetMode(0600)
				entry, err := archive.CreateHeader(header)
				if err != nil {
					return err
				}
				if _, err = io.Copy(entry, exportReader{c, bytes.NewReader(data)}); err != nil {
					return err
				}
			}
			if err := c.Err(); err != nil {
				return err
			}
			return archive.Close()
		})
		// A nil platform result means publication committed, even if shutdown
		// arrived just afterwards. Never report cancellation after that commit.
		if err != nil {
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				return struct{}{}, err
			}
			return struct{}{}, ErrExport
		}
		return struct{}{}, nil
	})
	return err
}

type exportReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r exportReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(p)
}
