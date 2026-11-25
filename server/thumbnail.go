package main

import (
	"bytes"
	"image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
)

const maxThumbnailBytes = 1 << 20

func (s *Server) thumbnailPath(sha string) string { return s.blobPath(sha) + ".png" }

// Thumbnails are optional client-generated previews. PDF ownership controls access.
func (s *Server) handleThumbnail(w http.ResponseWriter, r *http.Request) {
	sha := r.PathValue("sha")
	if !shaRe.MatchString(sha) {
		httpErr(w, 400, "bad sha256")
		return
	}
	owned, _, err := s.store.UserHasBlob(userID(r), sha)
	if err != nil {
		httpErr(w, 500, "internal error")
		return
	}
	if !owned {
		httpErr(w, 404, "not found")
		return
	}
	path := s.thumbnailPath(sha)
	if r.Method == http.MethodGet || r.Method == http.MethodHead {
		f, err := os.Open(path)
		if err != nil {
			httpErr(w, 404, "thumbnail not found")
			return
		}
		defer f.Close()
		st, err := f.Stat()
		if err != nil {
			httpErr(w, 500, "internal error")
			return
		}
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Cache-Control", "private, max-age=86400")
		http.ServeContent(w, r, "", st.ModTime(), f)
		return
	}
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxThumbnailBytes))
	if err != nil {
		httpErr(w, 413, "thumbnail too large")
		return
	}
	cfg, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil || cfg.Width < 1 || cfg.Height < 1 || cfg.Width > 512 || cfg.Height > 768 {
		httpErr(w, 400, "expected PNG up to 512x768")
		return
	}
	if _, err := png.Decode(bytes.NewReader(data)); err != nil {
		httpErr(w, 400, "invalid PNG")
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		httpErr(w, 500, "internal error")
		return
	}
	f, err := os.CreateTemp(filepath.Dir(path), "thumbnail-*")
	if err != nil {
		httpErr(w, 500, "internal error")
		return
	}
	defer os.Remove(f.Name())
	_, err = f.Write(data)
	closeErr := f.Close()
	if err != nil || closeErr != nil {
		httpErr(w, 500, "internal error")
		return
	}
	if err := os.Rename(f.Name(), path); err != nil {
		httpErr(w, 500, "internal error")
		return
	}
	if s.hub != nil {
		s.hub.ThumbnailReady(userID(r), r.Header.Get("X-Device-Id"), sha)
	}
	w.WriteHeader(http.StatusNoContent)
}
