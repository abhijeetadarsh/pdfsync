package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

func main() {
	addr := flag.String("addr", env("PDFSYNC_ADDR", ":8080"), "listen address")
	dataDir := flag.String("data", env("PDFSYNC_DATA", "./data"), "data directory")
	maxMB := flag.Int64("max-upload-mb", 512, "max PDF size in MB")
	cors := flag.String("cors", env("PDFSYNC_CORS", "*"), "Access-Control-Allow-Origin value (empty to disable)")
	flag.Parse()

	blobDir := filepath.Join(*dataDir, "blobs")
	if err := os.MkdirAll(blobDir, 0o755); err != nil {
		log.Fatal(err)
	}
	store, err := OpenStore(filepath.Join(*dataDir, "pdfsync.db"))
	if err != nil {
		log.Fatal(err)
	}
	defer store.Close()

	srv := &Server{store: store, hub: NewHub(), blobDir: blobDir, maxBlobSize: *maxMB << 20, corsOrigins: *cors}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go srv.gcLoop(ctx)

	httpSrv := &http.Server{Addr: *addr, Handler: srv.Routes(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		sctx, c := context.WithTimeout(context.Background(), 10*time.Second)
		defer c()
		httpSrv.Shutdown(sctx)
	}()
	log.Printf("pdfsync server listening on %s (data: %s)", *addr, *dataDir)
	if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
