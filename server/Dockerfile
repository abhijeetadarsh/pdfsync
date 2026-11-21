FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /pdfsync-server .
# Empty data dir, copied below with the nonroot owner: a new volume mounted on
# /data takes over this ownership, so the server (uid 65532) can write to it.
RUN mkdir /data

FROM gcr.io/distroless/static:nonroot
COPY --from=build /pdfsync-server /pdfsync-server
COPY --from=build --chown=65532:65532 /data /data
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["/pdfsync-server", "-addr", ":8080", "-data", "/data"]
