FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /pdfsync-server .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /pdfsync-server /pdfsync-server
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["/pdfsync-server", "-addr", ":8080", "-data", "/data"]
