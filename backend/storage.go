package main

import (
	"context"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type localBucket struct {
	root string
}

// Only the server's random IDs are used as filenames.
func (b localBucket) path(key string) string {
	return filepath.Join(b.root, strings.TrimPrefix(key, objectPrefix))
}

func (b localBucket) put(ctx context.Context, key string, source *os.File, size int64) error {
	file, err := os.CreateTemp(b.root, ".pending-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, copyErr := io.CopyN(file, source, size)
	closeErr := file.Close()
	if err := errors.Join(copyErr, closeErr, ctx.Err()); err != nil {
		return err
	}
	return os.Rename(file.Name(), b.path(key))
}

func (b localBucket) get(_ context.Context, key string) (io.ReadCloser, int64, error) {
	file, err := os.Open(b.path(key))
	if errors.Is(err, os.ErrNotExist) {
		return nil, 0, errTrackMissing
	}
	if err != nil {
		return nil, 0, err
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, 0, err
	}
	return file, info.Size(), nil
}

func (b localBucket) prune(now time.Time) error {
	entries, err := os.ReadDir(b.root)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		name := entry.Name()
		if !entry.Type().IsRegular() || (!idPattern.MatchString(name) && !strings.HasPrefix(name, ".pending-")) {
			continue
		}
		info, err := entry.Info()
		switch {
		case errors.Is(err, os.ErrNotExist):
			continue
		case err != nil:
			return err
		}
		// Allow for the upload grant being signed just after the file is committed.
		if now.Sub(info.ModTime()) >= trackTTL+time.Minute {
			if err := os.Remove(filepath.Join(b.root, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
		}
	}
	return nil
}

func (b localBucket) sweep(ctx context.Context) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			if err := b.prune(now); err != nil {
				log.Printf("Clean temporary tracks: %v", err)
			}
		}
	}
}
