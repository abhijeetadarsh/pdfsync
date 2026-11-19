package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/coder/websocket"
)

var shaRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Server struct {
	store       *Store
	hub         *Hub
	blobDir     string
	maxBlobSize int64
	corsOrigins string
}

type ctxKey int

const userKey ctxKey = 0

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("POST /api/auth/register", s.handleRegister)
	mux.HandleFunc("POST /api/auth/login", s.handleLogin)
	mux.Handle("POST /api/auth/logout", s.auth(http.HandlerFunc(s.handleLogout)))
	mux.Handle("HEAD /api/blobs/{sha}", s.auth(http.HandlerFunc(s.handleBlobHead)))
	mux.Handle("GET /api/blobs/{sha}", s.auth(http.HandlerFunc(s.handleBlobGet)))
	mux.Handle("PUT /api/blobs/{sha}", s.auth(http.HandlerFunc(s.handleBlobPut)))
	mux.Handle("POST /api/sync", s.auth(http.HandlerFunc(s.handleSync)))
	mux.Handle("GET /api/ws", s.auth(http.HandlerFunc(s.handleWS)))
	return s.cors(mux)
}

func (s *Server) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.corsOrigins != "" {
			w.Header().Set("Access-Control-Allow-Origin", s.corsOrigins)
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Device-Id, Range")
			w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, POST, PUT, OPTIONS")
			w.Header().Set("Access-Control-Expose-Headers", "Content-Length, Content-Range, ETag")
			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if tok == "" {
			tok = r.URL.Query().Get("token") // browsers can't set headers on WebSocket
		}
		uid, err := s.store.UserForToken(tok)
		if err != nil {
			httpErr(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), userKey, uid)))
	})
}

func userID(r *http.Request) string { return r.Context().Value(userKey).(string) }

func httpErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

type credentials struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

func readCreds(w http.ResponseWriter, r *http.Request) (credentials, bool) {
	var c credentials
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&c); err != nil {
		httpErr(w, 400, "bad json")
		return c, false
	}
	if !strings.Contains(c.Email, "@") || len(c.Password) < 8 {
		httpErr(w, 400, "valid email and password of 8+ chars required")
		return c, false
	}
	return c, true
}

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	c, ok := readCreds(w, r)
	if !ok {
		return
	}
	uid, tok, err := s.store.Register(c.Email, c.Password)
	if errors.Is(err, ErrEmailTaken) {
		httpErr(w, 409, err.Error())
		return
	} else if err != nil {
		log.Println("register:", err)
		httpErr(w, 500, "internal error")
		return
	}
	writeJSON(w, 200, map[string]string{"userId": uid, "token": tok})
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	c, ok := readCreds(w, r)
	if !ok {
		return
	}
	uid, tok, err := s.store.Login(c.Email, c.Password)
	if errors.Is(err, ErrBadLogin) {
		httpErr(w, 401, err.Error())
		return
	} else if err != nil {
		log.Println("login:", err)
		httpErr(w, 500, "internal error")
		return
	}
	writeJSON(w, 200, map[string]string{"userId": uid, "token": tok})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	s.store.Logout(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	w.WriteHeader(204)
}

// ---- blobs: content-addressed, immutable, deduplicated ----

func (s *Server) blobPath(sha string) string {
	return filepath.Join(s.blobDir, sha[:2], sha)
}

func (s *Server) handleBlobHead(w http.ResponseWriter, r *http.Request) {
	sha := r.PathValue("sha")
	if !shaRe.MatchString(sha) {
		w.WriteHeader(400)
		return
	}
	ok, _, err := s.store.UserHasBlob(userID(r), sha)
	if err != nil {
		w.WriteHeader(500)
		return
	}
	if !ok {
		w.WriteHeader(404)
		return
	}
	w.WriteHeader(200)
}

func (s *Server) handleBlobGet(w http.ResponseWriter, r *http.Request) {
	sha := r.PathValue("sha")
	if !shaRe.MatchString(sha) {
		httpErr(w, 400, "bad sha256")
		return
	}
	ok, _, err := s.store.UserHasBlob(userID(r), sha)
	if err != nil || !ok {
		httpErr(w, 404, "not found")
		return
	}
	f, err := os.Open(s.blobPath(sha))
	if err != nil {
		httpErr(w, 404, "not found")
		return
	}
	defer f.Close()
	st, _ := f.Stat()
	// Content never changes for a given hash: cache forever, and ServeContent
	// gives us Range requests (resume, progressive loading) and ETag for free.
	w.Header().Set("Content-Type", "application/pdf")
	w.Header().Set("ETag", `"`+sha+`"`)
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	http.ServeContent(w, r, "", st.ModTime(), f)
}

func (s *Server) handleBlobPut(w http.ResponseWriter, r *http.Request) {
	sha := r.PathValue("sha")
	if !shaRe.MatchString(sha) {
		httpErr(w, 400, "bad sha256")
		return
	}
	uid := userID(r)
	if ok, _, _ := s.store.UserHasBlob(uid, sha); ok {
		io.Copy(io.Discard, io.LimitReader(r.Body, 1)) // nothing to do
		writeJSON(w, 200, map[string]any{"sha256": sha, "dedup": true})
		return
	}
	body := http.MaxBytesReader(w, r.Body, s.maxBlobSize)
	tmp, err := os.CreateTemp(s.blobDir, "upload-*")
	if err != nil {
		httpErr(w, 500, "internal error")
		return
	}
	defer os.Remove(tmp.Name()) // no-op after successful rename
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(tmp, h), body)
	tmp.Close()
	if err != nil {
		httpErr(w, 413, "upload failed or too large")
		return
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != sha {
		httpErr(w, 400, "sha256 mismatch: got "+got)
		return
	}
	// Even when another user already stored these bytes we require the upload
	// (proof of possession) – then just keep the one existing copy on disk.
	exists, _ := s.store.BlobExists(sha)
	if !exists {
		dst := s.blobPath(sha)
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			httpErr(w, 500, "internal error")
			return
		}
		if err := os.Rename(tmp.Name(), dst); err != nil {
			httpErr(w, 500, "internal error")
			return
		}
	}
	if err := s.store.LinkBlob(uid, sha, n); err != nil {
		httpErr(w, 500, "internal error")
		return
	}
	writeJSON(w, 201, map[string]any{"sha256": sha, "size": n, "dedup": exists})
}

// ---- sync ----

func (s *Server) handleSync(w http.ResponseWriter, r *http.Request) {
	uid := userID(r)
	var req SyncRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<20)).Decode(&req); err != nil {
		httpErr(w, 400, "bad json: "+err.Error())
		return
	}
	resp, changed, err := s.store.Sync(uid, req)
	if err != nil {
		log.Println("sync:", err)
		httpErr(w, 400, err.Error())
		return
	}
	if changed {
		seq, _ := s.store.CurrentSeq(uid)
		s.hub.Poke(uid, r.Header.Get("X-Device-Id"), seq)
	}
	writeJSON(w, 200, resp)
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	uid := userID(r)
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: s.corsOrigins == "*"})
	if err != nil {
		return
	}
	seq, _ := s.store.CurrentSeq(uid)
	s.hub.Serve(r.Context(), conn, uid, r.URL.Query().Get("device"), seq)
}

func (s *Server) gcLoop(ctx context.Context) {
	t := time.NewTicker(6 * time.Hour)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			// Grace period so a doc record arriving just after its blob isn't raced.
			shas, err := s.store.CollectGarbageBlobs(24 * time.Hour)
			if err != nil {
				log.Println("gc:", err)
				continue
			}
			for _, sha := range shas {
				os.Remove(s.blobPath(sha))
			}
			if len(shas) > 0 {
				log.Printf("gc: removed %d unreferenced blobs", len(shas))
			}
		}
	}
}
