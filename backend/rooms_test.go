package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func nextPeer() *roomPeer {
	return &roomPeer{out: make(chan roomEvent, 32), done: make(chan struct{})}
}

func TestRoomCapacityReadinessAndReconnect(t *testing.T) {
	hub := newRideHub()
	now := time.Now()
	hub.now = func() time.Time { return now }
	hostSocket := nextPeer()
	room, host, err := hub.attach(roomInput{Version: 1, Type: "host", Name: "Host"}, hostSocket)
	if err != nil {
		t.Fatal(err)
	}
	guests := make([]*roomPlayer, 0, 3)
	for i := 0; i < 3; i++ {
		peer := nextPeer()
		_, player, err := hub.attach(roomInput{Version: 1, Type: "join", Code: room.code}, peer)
		if err != nil {
			t.Fatal(err)
		}
		welcome := <-peer.out
		if welcome.Slot != i+1 || welcome.ID != player.id || welcome.Token == host.token {
			t.Fatalf("unexpected welcome: %+v", welcome)
		}
		guests = append(guests, player)
	}
	if _, _, err := hub.attach(roomInput{Version: 1, Type: "join", Code: room.code}, nextPeer()); err == nil {
		t.Fatal("fifth rider joined")
	}
	start := roomInput{Version: 1, Type: "start"}
	hub.input(room, host, hostSocket, start)
	if room.active {
		t.Fatal("started with riders loading")
	}
	for _, player := range room.players {
		hub.input(room, player, player.peer, roomInput{Version: 1, Type: "status", Status: "ready"})
	}
	hub.input(room, guests[0], guests[0].peer, start)
	if room.active {
		t.Fatal("guest started the room")
	}
	hub.input(room, host, hostSocket, start)
	if !room.active {
		t.Fatal("ready room did not start")
	}
	first := guests[0]
	hub.detach(room, first, first.peer)
	if _, _, err := hub.attach(roomInput{Version: 1, Type: "resume", Code: room.code, Token: "wrong"}, nextPeer()); err == nil {
		t.Fatal("invalid reconnect token was accepted")
	}
	newSocket := nextPeer()
	now = now.Add(5 * time.Second)
	_, resumed, err := hub.attach(roomInput{Version: 1, Type: "resume", Code: room.code, Token: first.token}, newSocket)
	if err != nil || resumed != first {
		t.Fatalf("failed to reattach existing rider: %v", err)
	}
	if welcome := <-newSocket.out; welcome.Slot != 1 || !welcome.Active || welcome.ID != first.id {
		t.Fatalf("unexpected reconnect welcome: %+v", welcome)
	}
	hub.detach(room, host, hostSocket)
	now = now.Add(reconnectGrace)
	hub.pruneLocked(now)
	if hub.rooms[room.code] != nil {
		t.Fatal("room remained open after host reconnect grace expired")
	}
}

func TestFreeRideOverWebSocket(t *testing.T) {
	listener := &pipeListener{incoming: make(chan net.Conn), done: make(chan struct{})}
	store := localBucket{root: t.TempDir()}
	app := server{hub: newRideHub(), bucket: store, now: time.Now, secret: []byte(strings.Repeat("a", 32)),
		uploads: make(chan struct{}, 1)}
	srv := &http.Server{Handler: app.routes()}
	go srv.Serve(listener)
	defer srv.Close()
	const url = "ws://localhost/v1/rooms/connect"
	transport := &http.Transport{DialContext: listener.dial}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	dial := func() *websocket.Conn {
		conn, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPClient: client})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.CloseNow() })
		return conn
	}
	send := func(conn *websocket.Conn, input any) {
		buf, err := json.Marshal(input)
		if err != nil {
			t.Fatal(err)
		}
		if err := conn.Write(ctx, websocket.MessageText, buf); err != nil {
			t.Fatal(err)
		}
	}
	read := func(conn *websocket.Conn, until func(roomEvent) bool) roomEvent {
		for {
			_, buf, err := conn.Read(ctx)
			if err != nil {
				t.Fatal(err)
			}
			var event roomEvent
			if err := json.Unmarshal(buf, &event); err != nil {
				t.Fatal(err)
			}
			if until(event) {
				return event
			}
		}
	}
	kind := func(s string) func(roomEvent) bool { return func(e roomEvent) bool { return e.Type == s } }

	pkg := testTrackPackage()
	upload, err := http.NewRequestWithContext(ctx, "POST", "http://localhost/v1/tracks", bytes.NewReader(pkg))
	if err != nil {
		t.Fatal(err)
	}
	upload.Header.Set("Authorization", "Bearer "+strings.Repeat("a", 32))
	response, err := client.Do(upload)
	if err != nil {
		t.Fatal(err)
	}
	var receipt struct{ Grant, SHA256 string }
	decodeErr := json.NewDecoder(response.Body).Decode(&receipt)
	response.Body.Close()
	if response.StatusCode != http.StatusCreated || decodeErr != nil {
		t.Fatalf("upload status = %d, error = %v", response.StatusCode, decodeErr)
	}
	host, guest := dial(), dial()
	send(host, map[string]any{"version": 1, "type": "host", "name": "Host",
		"track": roomTrack{Version: 1, Name: "Custom Circuit", Start: []float32{0, 0},
			Grant: receipt.Grant, Hash: receipt.SHA256}})
	hostWelcome := read(host, kind("welcome"))
	send(guest, map[string]any{"version": 1, "type": "join", "code": hostWelcome.Code, "name": "Guest"})
	guestWelcome := read(guest, kind("welcome"))
	if guestWelcome.Track == nil || guestWelcome.Track.Name != "Custom Circuit" || guestWelcome.Slot != 1 ||
		guestWelcome.Track.Hash != receipt.SHA256 {
		t.Fatalf("guest welcome: %+v", guestWelcome)
	}
	download, err := http.NewRequestWithContext(ctx, "GET", "http://localhost/v1/tracks/"+guestWelcome.Track.Grant, nil)
	if err != nil {
		t.Fatal(err)
	}
	response, err = client.Do(download)
	if err != nil {
		t.Fatal(err)
	}
	data, readErr := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusOK || readErr != nil || !bytes.Equal(data, pkg) {
		t.Fatalf("guest download status = %d, error = %v", response.StatusCode, readErr)
	}
	for _, conn := range []*websocket.Conn{host, guest} {
		send(conn, map[string]any{"version": 1, "type": "status", "status": "ready"})
	}
	read(host, func(e roomEvent) bool {
		return e.Type == "roster" && len(e.Riders) == 2 && e.Riders[0].Status == "ready" && e.Riders[1].Status == "ready"
	})
	send(host, map[string]any{"version": 1, "type": "start"})
	read(host, kind("started"))
	read(guest, kind("started"))
	pose := json.RawMessage(`{"sequence":1,"generation":0,"position":[4,1,0],"velocity":[0,0,0],"angles":[0,0,0],"steering":0,"wheelSpeed":[0,0],"wheelAngle":[0,0],"travel":[0.02,0.1],"rider":[0,0]}`)
	send(host, map[string]any{"version": 1, "type": "pose", "pose": pose})
	event := read(guest, kind("pose"))
	if event.ID != hostWelcome.ID || string(event.Pose) != string(pose) {
		t.Fatalf("pose relay: %+v", event)
	}
	guest.CloseNow()
	guest = dial()
	send(guest, map[string]any{"version": 1, "type": "resume", "code": hostWelcome.Code, "token": guestWelcome.Token})
	reconnect := read(guest, kind("welcome"))
	if reconnect.ID != guestWelcome.ID || !reconnect.Active {
		t.Fatalf("unexpected reconnect event: %+v", reconnect)
	}
	send(host, map[string]any{"version": 1, "type": "leave"})
	read(guest, kind("ended"))
}

// Run the HTTP upgrade and WebSocket framing over in-memory connections so this
// integration test also works where the test runner cannot bind a TCP port.
type pipeListener struct {
	incoming chan net.Conn
	done     chan struct{}
}

func (l *pipeListener) Accept() (net.Conn, error) {
	select {
	case conn := <-l.incoming:
		return conn, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *pipeListener) Close() error {
	close(l.done)
	return nil
}

func (*pipeListener) Addr() net.Addr { return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)} }

func (l *pipeListener) dial(ctx context.Context, _, _ string) (net.Conn, error) {
	client, server := net.Pipe()
	select {
	case l.incoming <- server:
		return client, nil
	case <-ctx.Done():
		client.Close()
		server.Close()
		return nil, ctx.Err()
	}
}
