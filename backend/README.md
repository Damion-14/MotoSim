# MotoSim track server

The Go backend and its track storage run on your server. Uploaded terrain and ground art live on the `motosim-tracks` Docker volume. Download grants expire after six hours. The service removes expired files from disk at startup and checks for new expirations every minute while running.

Game Center remains a separate Apple-hosted dependency for invitations and real-time bike traffic.

## Run on the app network

1. Copy [.env.example](.env.example) to `.env` and set `MOTOSIM_UPLOAD_KEY` to a secret generated with `openssl rand -hex 32`. Share the key only with trusted track hosts.
2. From this directory run `docker compose up -d --build`. The Compose service uses the existing external Docker network `app-network`, matching Trakix. Point your HTTPS reverse proxy at `http://motosim-backend:8080`. Allow request bodies of at least 32 MiB and transfer timeouts of at least four minutes. Avoid logging the full `/v1/tracks/{grant}` path because the grant authorizes a download.
3. Verify `GET /health` through the reverse proxy. Enter the HTTPS address and upload key in **Track → Free Ride** on a host iPhone after importing a track. Guests open the Game Center invitation, which gives them the download grant inside the match.

For a native Go run, set `MOTOSIM_TRACK_DIR` to a private writable directory. It defaults to `./tracks`. The Docker image sets it to `/data/tracks`.

Run `go test -race ./...` for upload authorization, round-trip downloads from local storage, expired and tampered grants, and disk cleanup.
