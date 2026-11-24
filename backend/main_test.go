package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

type memoryBucket map[string][]byte

func (b memoryBucket) put(_ context.Context, key string, f *os.File, size int64) error {
	data, err := io.ReadAll(io.LimitReader(f, size))
	if err == nil {
		b[key] = data
	}
	return err
}

func (b memoryBucket) get(_ context.Context, key string) (io.ReadCloser, int64, error) {
	data, ok := b[key]
	if !ok {
		return nil, 0, errTrackMissing
	}
	return io.NopCloser(bytes.NewReader(data)), int64(len(data)), nil
}

func TestTrackUploadDownloadAndExpiry(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	secret := strings.Repeat("a", 64)
	bucket := localBucket{root: t.TempDir()}
	handler := server{bucket: bucket, secret: []byte(secret), now: func() time.Time { return now },
		uploads: make(chan struct{}, 1)}.routes()
	contents := make([]byte, 44)
	copy(contents, "MSTK")
	fields := []uint32{1, math.Float32bits(20), math.Float32bits(20), math.Float32bits(5), 2, 2, 0, 0}
	for index, value := range fields {
		binary.LittleEndian.PutUint32(contents[4+index*4:], value)
	}
	request := func(method, path string, body io.Reader, authorized bool) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, body)
		if authorized {
			req.Header.Set("Authorization", "Bearer "+secret)
		}
		res := httptest.NewRecorder()
		handler.ServeHTTP(res, req)
		return res
	}

	if got := request("POST", "/v1/tracks", bytes.NewReader(contents), false).Code; got != http.StatusUnauthorized {
		t.Fatalf("anonymous upload status = %d", got)
	}
	created := request("POST", "/v1/tracks", bytes.NewReader(contents), true)
	if created.Code != http.StatusCreated {
		t.Fatalf("upload status = %d, body = %s", created.Code, created.Body)
	}
	var response struct {
		Grant     string
		SHA256    string
		ExpiresAt int64
	}
	if err := json.Unmarshal(created.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(contents)
	if response.SHA256 != hex.EncodeToString(digest[:]) || response.ExpiresAt != now.Add(trackTTL).Unix() {
		t.Fatalf("unexpected upload receipt: %+v", response)
	}
	key, _, _ := strings.Cut(response.Grant, ".")
	stored, err := os.ReadFile(bucket.path(objectPrefix + key))
	if err != nil || !bytes.Equal(stored, contents) {
		t.Fatal("temporary bucket did not get the uploaded bytes")
	}

	path := "/v1/tracks/" + response.Grant
	loaded := request("GET", path, nil, false)
	if loaded.Code != http.StatusOK || !bytes.Equal(loaded.Body.Bytes(), contents) {
		t.Fatalf("guest download status = %d, body = %s", loaded.Code, loaded.Body)
	}
	if got := request("GET", path+"0", nil, false).Code; got != http.StatusNotFound {
		t.Fatalf("tampered grant status = %d", got)
	}
	now = now.Add(trackTTL)
	if got := request("GET", path, nil, false).Code; got != http.StatusGone {
		t.Fatalf("expired grant status = %d", got)
	}
}

func TestUploadRejectsOversizeAndEmpty(t *testing.T) {
	secret := strings.Repeat("a", 64)
	bucket := memoryBucket{}
	h := server{bucket: bucket, secret: []byte(secret), now: time.Now, uploads: make(chan struct{}, 1)}.routes()
	for _, tc := range []struct{ size, status int }{{0, http.StatusBadRequest}, {maxTrackBytes + 1, http.StatusRequestEntityTooLarge}} {
		req := httptest.NewRequest("POST", "/v1/tracks", io.LimitReader(zeroReader{}, int64(tc.size)))
		req.Header.Set("Authorization", "Bearer "+secret)
		res := httptest.NewRecorder()
		h.ServeHTTP(res, req)
		if res.Code != tc.status {
			t.Errorf("upload %d bytes status = %d, want %d", tc.size, res.Code, tc.status)
		}
	}
	req := httptest.NewRequest("POST", "/v1/tracks", strings.NewReader("not a MotoSim track"))
	req.Header.Set("Authorization", "Bearer "+secret)
	res := httptest.NewRecorder()
	h.ServeHTTP(res, req)
	if res.Code != http.StatusUnprocessableEntity {
		t.Errorf("unrecognized package status = %d", res.Code)
	}
	if len(bucket) != 0 {
		t.Fatal("rejected upload reached the bucket")
	}
}

type zeroReader struct{}

func (zeroReader) Read(buf []byte) (int, error) {
	clear(buf)
	return len(buf), nil
}

func TestLocalCleanupPreservesActiveAndUnrelatedFiles(t *testing.T) {
	bucket := localBucket{root: t.TempDir()}
	now := time.Now()
	fresh := strings.Repeat("a", 32)
	expired := strings.Repeat("b", 32)
	for _, name := range []string{fresh, expired, "unrelated", ".pending-abandoned"} {
		path := bucket.path(name)
		if err := os.WriteFile(path, []byte("test"), 0600); err != nil {
			t.Fatal(err)
		}
		if name != fresh {
			old := now.Add(-trackTTL - 2*time.Minute)
			if err := os.Chtimes(path, old, old); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := bucket.prune(now); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{fresh, "unrelated"} {
		if _, err := os.Stat(bucket.path(name)); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{expired, ".pending-abandoned"} {
		if _, err := os.Stat(bucket.path(name)); !os.IsNotExist(err) {
			t.Fatalf("%s should be removed, got %v", name, err)
		}
	}
}
