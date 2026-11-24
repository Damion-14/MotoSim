FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/motosim-backend .

FROM alpine:3.22
RUN addgroup -S app && adduser -S -G app app \
    && mkdir -p /data/tracks && chown -R app:app /data
COPY --from=build /out/motosim-backend /usr/local/bin/motosim-backend
ENV MOTOSIM_TRACK_DIR=/data/tracks
USER app
EXPOSE 8080
ENTRYPOINT ["motosim-backend"]
