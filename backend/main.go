package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	maxTrackBytes = 32 << 20
	trackTTL      = 6 * time.Hour
	objectPrefix  = "temporary-tracks/"
)

var (
	errTrackMissing = errors.New("track missing")
	idPattern       = regexp.MustCompile(`^[0-9a-f]{32}$`)
)

type bucket interface {
	put(context.Context, string, *os.File, int64) error
	get(context.Context, string) (io.ReadCloser, int64, error)
}

type server struct {
	bucket  bucket
	secret  []byte
	now     func() time.Time
	uploads chan struct{}
}

func (s server) routes() http.Handler {
	routes := http.NewServeMux()
	routes.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	routes.HandleFunc("POST /v1/tracks", s.upload)
	routes.HandleFunc("GET /v1/tracks/{grant}", s.download)
	return routes
}

func (s server) upload(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	provided, hasBearer := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	providedHash, secretHash := sha256.Sum256([]byte(provided)), sha256.Sum256(s.secret)
	if !hasBearer || !hmac.Equal(providedHash[:], secretHash[:]) {
		http.Error(w, "Invalid upload key", http.StatusUnauthorized)
		return
	}
	select {
	case s.uploads <- struct{}{}:
		defer func() { <-s.uploads }()
	default:
		http.Error(w, "Too many uploads in progress", http.StatusServiceUnavailable)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxTrackBytes)
	file, err := os.CreateTemp("", "motosim-track-*")
	if err != nil {
		log.Printf("open upload: %v", err)
		http.Error(w, "Upload unavailable", http.StatusServiceUnavailable)
		return
	}
	defer os.Remove(file.Name())
	defer file.Close()
	hash := sha256.New()
	size, err := io.Copy(io.MultiWriter(file, hash), r.Body)
	var tooBig *http.MaxBytesError
	switch {
	case errors.As(err, &tooBig):
		http.Error(w, "Track exceeds 32 MiB", http.StatusRequestEntityTooLarge)
		return
	case err != nil || size == 0:
		http.Error(w, "Incomplete or empty track", http.StatusBadRequest)
		return
	}
	if !validPackage(file, size) {
		http.Error(w, "Invalid or incompatible MotoSim track", http.StatusUnprocessableEntity)
		return
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		http.Error(w, "Upload unavailable", http.StatusServiceUnavailable)
		return
	}
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		http.Error(w, "Upload unavailable", http.StatusServiceUnavailable)
		return
	}
	id := hex.EncodeToString(random[:])
	if err := s.bucket.put(r.Context(), objectPrefix+id, file, size); err != nil {
		log.Printf("store track: %v", err)
		http.Error(w, "Could not store track", http.StatusServiceUnavailable)
		return
	}
	expires := s.now().Add(trackTTL).Unix()
	payload := id + "." + strconv.FormatInt(expires, 10)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"grant": payload + "." + s.signature(payload), "sha256": hex.EncodeToString(hash.Sum(nil)),
		"expiresAt": expires,
	})
}

// Validate the normalized client package before writing it to the bucket.
func validPackage(file *os.File, size int64) bool {
	var header [36]byte
	if _, err := file.ReadAt(header[:], 0); err != nil || string(header[:4]) != "MSTK" {
		return false
	}
	field := func(offset int) uint32 { return binary.LittleEndian.Uint32(header[offset:]) }
	inRange := func(offset int, low, high float32) bool {
		value := math.Float32frombits(field(offset))
		return value >= low && value <= high
	}
	if field(4) != 1 || !inRange(8, 4, 10_000) || !inRange(12, 4, 10_000) || !inRange(16, 0, 5_000) {
		return false
	}
	columns, rows, artWidth, artHeight := field(20), field(24), field(28), field(32)
	if columns < 2 || columns > 1025 || rows < 2 || rows > 1025 ||
		artWidth > 2048 || artHeight > 2048 || (artWidth == 0) != (artHeight == 0) {
		return false
	}
	return size == int64(len(header))+int64(columns*rows*2)+int64(artWidth*artHeight*4)
}

func (s server) signature(payload string) string {
	mac := hmac.New(sha256.New, s.secret)
	_, _ = io.WriteString(mac, "motosim-track-v1:"+payload)
	return hex.EncodeToString(mac.Sum(nil))
}

func (s server) download(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "private, no-store")
	grant := strings.Split(r.PathValue("grant"), ".")
	if len(grant) != 3 || !idPattern.MatchString(grant[0]) || len(grant[1]) > 12 ||
		!hmac.Equal([]byte(s.signature(grant[0]+"."+grant[1])), []byte(grant[2])) {
		http.NotFound(w, r)
		return
	}
	expires, err := strconv.ParseInt(grant[1], 10, 64)
	if err != nil || s.now().Unix() >= expires {
		http.Error(w, "Track download expired", http.StatusGone)
		return
	}
	body, size, err := s.bucket.get(r.Context(), objectPrefix+grant[0])
	if errors.Is(err, errTrackMissing) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		log.Printf("read track: %v", err)
		http.Error(w, "Could not read track", http.StatusServiceUnavailable)
		return
	}
	defer body.Close()
	if size <= 0 || size > maxTrackBytes {
		http.Error(w, "Invalid track size", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.Method != http.MethodHead {
		_, _ = io.CopyN(w, body, size)
	}
}

func main() {
	secret := os.Getenv("MOTOSIM_UPLOAD_KEY")
	if len(secret) < 32 {
		log.Fatal("Set MOTOSIM_UPLOAD_KEY (at least 32 bytes)")
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	root := os.Getenv("MOTOSIM_TRACK_DIR")
	if root == "" {
		root = "./tracks"
	}
	store := localBucket{root: root}
	if err := os.MkdirAll(root, 0700); err != nil {
		log.Fatal(err)
	}
	if err := store.prune(time.Now()); err != nil {
		log.Fatalf("Clean temporary tracks: %v", err)
	}
	go store.sweep(ctx)
	app := server{bucket: store, secret: []byte(secret), now: time.Now, uploads: make(chan struct{}, 4)}
	httpServer := &http.Server{
		Addr: ":8080", Handler: app.routes(), ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout: 2 * time.Minute, WriteTimeout: 4 * time.Minute, IdleTimeout: 45 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdown)
	}()
	log.Print("MotoSim track sharing listening on :8080")
	if err := httpServer.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
