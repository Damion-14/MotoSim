package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/coder/websocket"
)

const (
	reconnectGrace = 30 * time.Second
	wireVersion    = 1
	trackVersion   = 1
	maxRooms       = 128
)

type roomTrack struct {
	Version int       `json:"version"`
	Name    string    `json:"name"`
	Grant   string    `json:"grant,omitempty"`
	Hash    string    `json:"sha256,omitempty"`
	Start   []float32 `json:"start"`
	Heading float32   `json:"heading"`
}

type roomInput struct {
	Version int             `json:"version"`
	Type    string          `json:"type"`
	Code    string          `json:"code"`
	Name    string          `json:"name"`
	Token   string          `json:"token"`
	Status  string          `json:"status"`
	Track   *roomTrack      `json:"track"`
	Pose    json.RawMessage `json:"pose"`
}

type riderView struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Status string `json:"status"`
}

type roomEvent struct {
	Type   string          `json:"type"`
	Code   string          `json:"code,omitempty"`
	Token  string          `json:"token,omitempty"`
	ID     string          `json:"id,omitempty"`
	Slot   int             `json:"slot,omitempty"`
	Track  *roomTrack      `json:"track,omitempty"`
	Riders []riderView     `json:"riders,omitempty"`
	Active bool            `json:"active,omitempty"`
	Pose   json.RawMessage `json:"pose,omitempty"`
	Notice string          `json:"notice,omitempty"`
}

type roomPeer struct {
	out  chan roomEvent
	done chan struct{}
}

type roomPlayer struct {
	id, name, token, status string
	peer                    *roomPeer
	leftAt, lastPose        time.Time
	sequence, generation    uint32
	hasPose                 bool
}

type rideRoom struct {
	code, host string
	track      *roomTrack
	players    [4]*roomPlayer
	active     bool
	expires    time.Time
}

type rideHub struct {
	mu      sync.Mutex
	rooms   map[string]*rideRoom
	clients chan struct{}
	now     func() time.Time
}

func newRideHub() *rideHub {
	return &rideHub{rooms: make(map[string]*rideRoom), clients: make(chan struct{}, 256), now: time.Now}
}

func randomID(bytes int) string {
	buf := make([]byte, bytes)
	_, _ = rand.Read(buf)
	return hex.EncodeToString(buf)
}

func cleanRiderName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 100 || utf8.RuneCountInString(name) > 24 ||
		strings.ContainsFunc(name, unicode.IsControl) {
		return "Rider"
	}
	return name
}

func (h *rideHub) attach(input roomInput, peer *roomPeer) (*rideRoom, *roomPlayer, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.now()
	h.pruneLocked(now)
	if input.Version != wireVersion {
		return nil, nil, errors.New("Update MotoSim to join this server.")
	}
	code := strings.ToUpper(strings.TrimSpace(input.Code))
	room := h.rooms[code]
	switch input.Type {
	case "host":
		if len(h.rooms) >= maxRooms {
			return nil, nil, errors.New("The server is full. Try again later.")
		}
		for {
			code = strings.ToUpper(randomID(4))
			if h.rooms[code] == nil {
				break
			}
		}
		room = &rideRoom{code: code, track: input.Track, expires: now.Add(trackTTL)}
		h.rooms[code] = room
	case "join", "resume":
		if room == nil {
			return nil, nil, errors.New("That Free Ride is unavailable. Check the join code.")
		}
	default:
		return nil, nil, errors.New("Open a Free Ride room first.")
	}

	if input.Type == "resume" {
		for slot, player := range room.players {
			if player == nil || player.token != input.Token {
				continue
			}
			if player.peer != nil {
				close(player.peer.done)
			}
			player.peer = peer
			player.leftAt = time.Time{}
			h.welcome(room, player, slot)
			h.roster(room)
			return room, player, nil
		}
		return nil, nil, errors.New("Your connection expired. Ask the host for a new ride.")
	}
	if room.active {
		return nil, nil, errors.New("The ride has already started.")
	}
	for slot, entry := range room.players {
		if entry != nil {
			continue
		}
		player := &roomPlayer{id: randomID(8), token: randomID(24), name: cleanRiderName(input.Name),
			status: "loading", peer: peer}
		room.players[slot] = player
		if input.Type == "host" {
			room.host = player.id
		}
		h.welcome(room, player, slot)
		h.roster(room)
		return room, player, nil
	}
	return nil, nil, errors.New("This Free Ride already has four riders.")
}

func (h *rideHub) welcome(room *rideRoom, player *roomPlayer, slot int) {
	player.peer.out <- roomEvent{Type: "welcome", Code: room.code, Token: player.token, ID: player.id,
		Slot: slot, Track: room.track, Active: room.active, Riders: room.riders()}
}

func (r *rideRoom) riders() []riderView {
	var riders []riderView
	for _, player := range r.players {
		if player == nil {
			continue
		}
		status := player.status
		if player.peer == nil {
			status = "reconnecting"
		}
		riders = append(riders, riderView{ID: player.id, Name: player.name, Status: status})
	}
	return riders
}

func (h *rideHub) roster(room *rideRoom) {
	h.broadcast(room, roomEvent{Type: "roster", Riders: room.riders()}, nil)
}

func (h *rideHub) broadcast(room *rideRoom, event roomEvent, skip *roomPlayer) {
	for _, player := range room.players {
		if player != nil && player != skip && player.peer != nil {
			if event.Type == "pose" && len(player.peer.out) >= 4 {
				continue // Movement can be discarded for slow readers.
			}
			h.send(player, event)
		}
	}
}

func (h *rideHub) send(player *roomPlayer, event roomEvent) {
	select {
	case player.peer.out <- event:
	default:
		close(player.peer.done)
		player.peer = nil
		player.leftAt = h.now()
	}
}

func (h *rideHub) input(room *rideRoom, player *roomPlayer, peer *roomPeer, input roomInput) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.rooms[room.code] != room || player.peer != peer || input.Version != wireVersion {
		return
	}
	switch input.Type {
	case "leave":
		h.remove(room, player)
	case "status":
		if !room.active && input.Status != player.status {
			switch input.Status {
			case "loading", "downloading", "ready", "failed":
				player.status = input.Status
				h.roster(room)
			}
		}
	case "start":
		if player.id != room.host || room.active {
			return
		}
		riders := room.riders()
		if len(riders) < 2 {
			h.send(player, roomEvent{Type: "notice", Notice: "At least two riders must be ready."})
			return
		}
		for _, rider := range riders {
			if rider.Status != "ready" {
				h.send(player, roomEvent{Type: "notice", Notice: "Wait for every rider to finish loading."})
				return
			}
		}
		room.active = true
		h.broadcast(room, roomEvent{Type: "started"}, nil)
	case "pose":
		now := h.now()
		if !room.active || now.Sub(player.lastPose) < 25*time.Millisecond {
			return
		}
		var pose snapshotCheck
		if json.Unmarshal(input.Pose, &pose) != nil || !pose.valid() ||
			(player.hasPose && (pose.Sequence <= player.sequence || pose.Generation < player.generation)) {
			return
		}
		player.lastPose = now
		player.sequence, player.generation, player.hasPose = pose.Sequence, pose.Generation, true
		h.broadcast(room, roomEvent{Type: "pose", ID: player.id, Pose: input.Pose}, player)
	}
}

type snapshotCheck struct {
	Sequence, Generation                                              uint32
	Position, Velocity, Angles, WheelSpeed, WheelAngle, Travel, Rider []float32
	Steering                                                          *float32
}

func (p snapshotCheck) valid() bool {
	return p.Sequence > 0 && p.Steering != nil && *p.Steering >= -0.55 && *p.Steering <= 0.55 &&
		bounded(p.Position, 3, 20_000) && bounded(p.Velocity, 3, 200) && bounded(p.Angles, 3, 50_000) &&
		bounded(p.WheelSpeed, 2, 2_000) && bounded(p.WheelAngle, 2, 10_000_000) &&
		bounded(p.Rider, 2, 1.01) && bounded(p.Travel, 2, 0.310) &&
		p.Travel[0] >= 0 && p.Travel[1] >= 0 && p.Travel[1] <= 0.300
}

func bounded(values []float32, count int, limit float32) bool {
	if len(values) != count {
		return false
	}
	for _, value := range values {
		if !(value >= -limit && value <= limit) {
			return false
		}
	}
	return true
}

func (h *rideHub) detach(room *rideRoom, player *roomPlayer, peer *roomPeer) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.rooms[room.code] == room && player.peer == peer {
		player.peer = nil
		player.leftAt = h.now()
		h.roster(room)
	}
}

func (h *rideHub) remove(room *rideRoom, player *roomPlayer) {
	if player.id == room.host {
		h.end(room, "The host ended the Free Ride.")
		return
	}
	for slot, entry := range room.players {
		if entry == player {
			room.players[slot] = nil
			h.roster(room)
			return
		}
	}
}

func (h *rideHub) end(room *rideRoom, reason string) {
	delete(h.rooms, room.code)
	h.broadcast(room, roomEvent{Type: "ended", Notice: reason}, nil)
}

func (h *rideHub) pruneLocked(now time.Time) {
	for _, room := range h.rooms {
		if !now.Before(room.expires) {
			h.end(room, "The Free Ride expired.")
			continue
		}
		for _, player := range room.players {
			if player != nil && player.peer == nil && now.Sub(player.leftAt) >= reconnectGrace {
				h.remove(room, player)
				if player.id == room.host {
					break
				}
			}
		}
	}
}

func (h *rideHub) sweep(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			h.mu.Lock()
			h.pruneLocked(h.now())
			h.mu.Unlock()
		}
	}
}

func (s server) roomSocket(w http.ResponseWriter, r *http.Request) {
	select {
	case s.hub.clients <- struct{}{}:
		defer func() { <-s.hub.clients }()
	default:
		http.Error(w, "The server is full", http.StatusServiceUnavailable)
		return
	}
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(8192)
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	handshake, finish := context.WithTimeout(ctx, 8*time.Second)
	first, err := readRoomInput(handshake, conn)
	finish()
	if err != nil {
		return
	}
	if first.Type == "host" && !s.validRoomTrack(first.Track) {
		_ = writeRoomEvent(ctx, conn, roomEvent{Type: "error", Notice: "The selected track is invalid or expired. Host again."})
		return
	}
	peer := &roomPeer{out: make(chan roomEvent, 32), done: make(chan struct{})}
	room, player, err := s.hub.attach(first, peer)
	if err != nil {
		_ = writeRoomEvent(ctx, conn, roomEvent{Type: "error", Notice: err.Error()})
		return
	}
	defer s.hub.detach(room, player, peer)
	go func() {
		defer cancel()
		ping := time.NewTicker(10 * time.Second)
		defer ping.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-peer.done:
				return
			case event := <-peer.out:
				if writeRoomEvent(ctx, conn, event) != nil || event.Type == "ended" {
					return
				}
			case <-ping.C:
				probe, stop := context.WithTimeout(ctx, 5*time.Second)
				err := conn.Ping(probe)
				stop()
				if err != nil || writeRoomEvent(ctx, conn, roomEvent{Type: "heartbeat"}) != nil {
					return
				}
			}
		}
	}()
	for {
		input, err := readRoomInput(ctx, conn)
		if err != nil {
			return
		}
		s.hub.input(room, player, peer, input)
		if input.Type == "leave" {
			return
		}
	}
}

func readRoomInput(ctx context.Context, conn *websocket.Conn) (roomInput, error) {
	var input roomInput
	kind, data, err := conn.Read(ctx)
	if err != nil {
		return input, err
	}
	if kind != websocket.MessageText {
		return input, errors.New("expected text frame")
	}
	return input, json.Unmarshal(data, &input)
}

func writeRoomEvent(ctx context.Context, conn *websocket.Conn, event roomEvent) error {
	data, err := json.Marshal(event)
	if err != nil {
		return err
	}
	deadline, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return conn.Write(deadline, websocket.MessageText, data)
}

func (s server) validRoomTrack(track *roomTrack) bool {
	if track == nil || track.Version != trackVersion || track.Name == "" || len(track.Name) > 400 ||
		!bounded(track.Start, 2, 5000) || !(track.Heading > -100 && track.Heading < 100) {
		return false
	}
	if track.Grant == "" && track.Hash == "" {
		return true
	}
	hash, err := hex.DecodeString(track.Hash)
	if err != nil || len(hash) != 32 || track.Hash != strings.ToLower(track.Hash) {
		return false
	}
	_, expiry, valid := s.verifyGrant(track.Grant)
	return valid && s.now().Unix() < expiry
}
