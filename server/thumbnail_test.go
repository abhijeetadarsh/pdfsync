package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"github.com/coder/websocket"
	"image"
	"image/png"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestThumbnails(t *testing.T) {
	ts := newTestServer(t)
	owner := register(t, ts.URL, "owner@thumb.io", "one")
	other := register(t, ts.URL, "other@thumb.io", "two")
	pdf := []byte("test PDF bytes")
	hash := sha256.Sum256(pdf)
	sha := hex.EncodeToString(hash[:])
	path := "/api/thumbnails/" + sha
	var imageData bytes.Buffer
	if err := png.Encode(&imageData, image.NewRGBA(image.Rect(0, 0, 360, 522))); err != nil {
		t.Fatal(err)
	}
	data := imageData.Bytes()
	if code := owner.do("PUT", path, data, nil); code != 404 {
		t.Fatalf("unowned upload: %d", code)
	}
	if code := owner.do("PUT", "/api/blobs/"+sha, pdf, nil); code != 201 {
		t.Fatal(code)
	}
	if code := owner.do("GET", path, nil, nil); code != 404 {
		t.Fatalf("missing: %d", code)
	}
	for _, bad := range [][]byte{[]byte("not an image"), data[:len(data)/2]} {
		if code := owner.do("PUT", path, bad, nil); code != 400 {
			t.Fatalf("invalid image: %d", code)
		}
	}
	var big bytes.Buffer
	png.Encode(&big, image.NewRGBA(image.Rect(0, 0, 513, 1)))
	if code := owner.do("PUT", path, big.Bytes(), nil); code != 400 {
		t.Fatalf("dimensions: %d", code)
	}
	if code := owner.do("PUT", path, []byte(strings.Repeat("x", maxThumbnailBytes+1)), nil); code != 413 {
		t.Fatalf("size: %d", code)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/api/ws?token=" + owner.token + "&device=listener"
	ws, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.CloseNow()
	if _, _, err := ws.Read(ctx); err != nil {
		t.Fatal(err)
	}
	if code := owner.do("PUT", path, data, nil); code != 204 {
		t.Fatalf("upload: %d", code)
	}
	_, message, err := ws.Read(ctx)
	if err != nil || !strings.Contains(string(message), `"type":"thumbnail"`) || !strings.Contains(string(message), sha) {
		t.Fatalf("thumbnail notification: %s %v", message, err)
	}

	if code := owner.do("PUT", path, data, nil); code != 204 {
		t.Fatalf("retry: %d", code)
	}
	if code := owner.do("HEAD", path, nil, nil); code != 200 {
		t.Fatalf("head: %d", code)
	}
	req, _ := http.NewRequest("GET", ts.URL+path, nil)
	req.Header.Set("Authorization", "Bearer "+owner.token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	got, _ := io.ReadAll(res.Body)
	if res.StatusCode != 200 || res.Header.Get("Content-Type") != "image/png" || !bytes.Equal(got, data) {
		t.Fatalf("download: %d, %d bytes", res.StatusCode, len(got))
	}
	if code := other.do("GET", path, nil, nil); code != 404 {
		t.Fatalf("other user read: %d", code)
	}
	if code := other.do("PUT", path, data, nil); code != 404 {
		t.Fatalf("other user write: %d", code)
	}
	anon := &api{t: t, base: ts.URL}
	if code := anon.do("GET", path, nil, nil); code != 401 {
		t.Fatalf("anonymous: %d", code)
	}
	if code := owner.do("GET", "/api/thumbnails/bad", nil, nil); code != 400 {
		t.Fatalf("hash: %d", code)
	}
}
