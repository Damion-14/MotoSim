# MotoSim Free Ride server

The Go service hosts private rooms for two to four riders, relays bike updates, and serves temporary copies of imported tracks. Rooms live in memory and end on a server restart or after six hours. A disconnected rider can reconnect for up to 30 seconds. The multiplayer runtime is self-hosted.

Track packages live on the `motosim-tracks` Docker volume. Download grants expire after six hours. The server prunes expired packages at startup and checks every minute while running.

## Run on the app network

1. Copy [.env.example](.env.example) to `.env` and set `MOTOSIM_UPLOAD_KEY` to a secret generated with `openssl rand -hex 32`. Share the key only with trusted custom-track hosts. Hosting the built-in circuit and joining any room use no upload key.
2. From this directory run `docker compose up -d --build`. The service uses the existing external Docker network `app-network`. Point your public HTTPS reverse proxy at `http://motosim-backend:8080`. Allow WebSocket upgrades on `/v1/rooms/connect`, preserve the public Host header, allow request bodies of at least 32 MiB, and allow track transfers up to four minutes. The WebSocket sends a heartbeat every 10 seconds. Avoid logging full download-grant paths under `/v1/tracks/`.
3. Verify `GET /health` through the reverse proxy. MotoSim defaults to `https://motosim.damedoll.com`. Override it with the `MOTOSIM_SERVER_URL` Xcode build setting or edit the address in Free Ride.

For a native Go run, set `MOTOSIM_TRACK_DIR` to a private writable directory. It defaults to `./tracks`. Docker uses `/data/tracks`.

Run `go test -race ./...` to exercise track upload, automatic download credentials, room readiness, pose relay, reconnect, host departure, and disk cleanup.
