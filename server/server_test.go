package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	dir := t.TempDir()
	store, err := OpenStore(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	s := &Server{store: store, hub: NewHub(), blobDir: dir, maxBlobSize: 10 << 20, corsOrigins: "*"}
	ts := httptest.NewServer(s.Routes())
	t.Cleanup(ts.Close)
	return ts
}

type api struct {
	t      *testing.T
	base   string
	token  string
	device string
}

func (a *api) do(method, path string, body []byte, out any) int {
	a.t.Helper()
	req, _ := http.NewRequest(method, a.base+path, bytes.NewReader(body))
	if a.token != "" {
		req.Header.Set("Authorization", "Bearer "+a.token)
	}
	req.Header.Set("X-Device-Id", a.device)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		a.t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	if out != nil && len(b) > 0 {
		if err := json.Unmarshal(b, out); err != nil {
			a.t.Fatalf("%s %s: %v: %s", method, path, err, b)
		}
	}
	return res.StatusCode
}

func (a *api) sync(cursor int64, changes ...Record) SyncResponse {
	a.t.Helper()
	body, _ := json.Marshal(SyncRequest{Cursor: cursor, Changes: changes})
	var r SyncResponse
	if code := a.do("POST", "/api/sync", body, &r); code != 200 {
		a.t.Fatalf("sync status %d", code)
	}
	return r
}

func hlc(ms int64, c int, node string) string { return fmt.Sprintf("%013d-%04x-%s", ms, c, node) }

func register(t *testing.T, base, email, device string) *api {
	a := &api{t: t, base: base, device: device}
	var out map[string]string
	body, _ := json.Marshal(credentials{email, "password123"})
	code := a.do("POST", "/api/auth/register", body, &out)
	if code == 409 {
		code = a.do("POST", "/api/auth/login", body, &out)
	}
	if code != 200 {
		t.Fatalf("auth: %d", code)
	}
	a.token = out["token"]
	return a
}

func TestEndToEnd(t *testing.T) {
	ts := newTestServer(t)
	laptop := register(t, ts.URL, "a@x.io", "laptop")
	phone := register(t, ts.URL, "a@x.io", "phone") // same user, second device
	now := time.Now().UnixMilli()

	pdf := []byte("%PDF-1.4 fake pdf bytes")
	sum := sha256.Sum256(pdf)
	sha := hex.EncodeToString(sum[:])

	// Document referencing a blob that isn't uploaded is rejected.
	doc := Record{Kind: "document", ID: "doc1", HLC: hlc(now, 0, "laptop"),
		Data: json.RawMessage(fmt.Sprintf(`{"title":"Paper","sha256":%q,"size":%d}`, sha, len(pdf)))}
	r := laptop.sync(0, doc)
	if len(r.Rejected) != 1 || r.Rejected[0].Reason != "blob not uploaded" {
		t.Fatalf("expected blob rejection, got %+v", r)
	}

	// Upload: wrong hash rejected, right hash stored, second upload deduped.
	if code := laptop.do("PUT", "/api/blobs/"+strings.Repeat("0", 64), pdf, nil); code != 400 {
		t.Fatalf("mismatch upload: %d", code)
	}
	if code := laptop.do("HEAD", "/api/blobs/"+sha, nil, nil); code != 404 {
		t.Fatalf("head before upload: %d", code)
	}
	if code := laptop.do("PUT", "/api/blobs/"+sha, pdf, nil); code != 201 {
		t.Fatalf("upload: %d", code)
	}
	if code := phone.do("HEAD", "/api/blobs/"+sha, nil, nil); code != 200 {
		t.Fatalf("head after upload: %d", code)
	}

	// A different user can't read the blob without proving possession.
	eve := register(t, ts.URL, "eve@x.io", "eve")
	if code := eve.do("GET", "/api/blobs/"+sha, nil, nil); code != 404 {
		t.Fatalf("eve read other user's blob: %d", code)
	}

	// Phone opens a WebSocket and should get poked when the laptop syncs.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/api/ws?device=phone&token=" + phone.token
	ws, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.CloseNow()
	_, hello, err := ws.Read(ctx)
	if err != nil || !strings.Contains(string(hello), `"hello"`) {
		t.Fatalf("hello: %s %v", hello, err)
	}

	ann := Record{Kind: "annotation", ID: "a1", DocID: "doc1", HLC: hlc(now, 1, "laptop"),
		Data: json.RawMessage(`{"page":1,"type":"highlight","color":"#ffeb3b","rects":[[0.1,0.2,0.5,0.03]]}`)}
	r = laptop.sync(0, doc, ann)
	if len(r.Accepted) != 2 || len(r.Changes) != 0 {
		t.Fatalf("push: want 2 accepted and no echo, got %+v", r)
	}
	laptopCursor := r.Cursor

	_, poke, err := ws.Read(ctx)
	if err != nil || !strings.Contains(string(poke), `"changed"`) {
		t.Fatalf("poke: %s %v", poke, err)
	}

	// Phone pulls everything.
	pr := phone.sync(0)
	if len(pr.Changes) != 2 || pr.Cursor != 2 {
		t.Fatalf("phone pull: %+v", pr)
	}
	phoneCursor := pr.Cursor
	if code := phone.do("GET", "/api/blobs/"+sha, nil, nil); code != 200 {
		t.Fatalf("phone download: %d", code)
	}

	// Range request support for progressive loading.
	req, _ := http.NewRequest("GET", ts.URL+"/api/blobs/"+sha, nil)
	req.Header.Set("Authorization", "Bearer "+phone.token)
	req.Header.Set("Range", "bytes=0-3")
	res, _ := http.DefaultClient.Do(req)
	b, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != 206 || string(b) != "%PDF" {
		t.Fatalf("range: %d %q", res.StatusCode, b)
	}

	// Conflict: both devices edit a1 offline. Phone's edit has the later HLC.
	laptopEdit := ann
	laptopEdit.HLC = hlc(now+1000, 0, "laptop")
	laptopEdit.Data = json.RawMessage(`{"page":1,"type":"highlight","color":"#ff0000","rects":[[0.1,0.2,0.5,0.03]]}`)
	phoneEdit := ann
	phoneEdit.HLC = hlc(now+2000, 0, "phone")
	phoneEdit.Data = json.RawMessage(`{"page":1,"type":"highlight","color":"#00ff00","rects":[[0.1,0.2,0.5,0.03]]}`)

	pr = phone.sync(phoneCursor, phoneEdit)
	if len(pr.Accepted) != 1 {
		t.Fatalf("phone edit: %+v", pr)
	}
	r = laptop.sync(laptopCursor, laptopEdit) // older -> silently loses, gets winner back
	if len(r.Accepted) != 0 || len(r.Changes) != 1 || !strings.Contains(string(r.Changes[0].Data), "00ff00") {
		t.Fatalf("conflict resolution: %+v", r)
	}
	laptopCursor = r.Cursor

	// Delete wins over an older edit; tombstone propagates.
	del := Record{Kind: "annotation", ID: "a1", DocID: "doc1", HLC: hlc(now+3000, 0, "laptop"), Deleted: true}
	laptop.sync(laptopCursor, del)
	pr = phone.sync(pr.Cursor)
	if len(pr.Changes) != 1 || !pr.Changes[0].Deleted {
		t.Fatalf("tombstone: %+v", pr)
	}

	// Clock-skew guard.
	future := Record{Kind: "annotation", ID: "a2", DocID: "doc1", HLC: hlc(now+3600_000, 0, "phone"), Data: json.RawMessage(`{}`)}
	pr = phone.sync(pr.Cursor, future)
	if len(pr.Rejected) != 1 {
		t.Fatalf("future hlc should be rejected: %+v", pr)
	}

	// Isolation: eve sees nothing.
	if er := eve.sync(0); len(er.Changes) != 0 {
		t.Fatalf("eve sees data: %+v", er)
	}
}

func TestPagination(t *testing.T) {
	ts := newTestServer(t)
	a := register(t, ts.URL, "p@x.io", "d1")
	b := register(t, ts.URL, "p@x.io", "d2")
	now := time.Now().UnixMilli()
	var batch []Record
	for i := 0; i < 1234; i++ {
		batch = append(batch, Record{Kind: "annotation", ID: fmt.Sprintf("a%d", i), DocID: "d",
			HLC: hlc(now, i%65535, "d1"), Data: json.RawMessage(`{"page":1}`)})
	}
	a.sync(0, batch...)
	var cursor int64
	total, pages := 0, 0
	for {
		r := b.sync(cursor)
		total += len(r.Changes)
		cursor = r.Cursor
		pages++
		if !r.HasMore {
			break
		}
	}
	if total != 1234 || pages != 3 || cursor != 1234 {
		t.Fatalf("total=%d pages=%d cursor=%d", total, pages, cursor)
	}
}

func TestAuth(t *testing.T) {
	ts := newTestServer(t)
	a := &api{t: t, base: ts.URL, token: "nope"}
	if code := a.do("POST", "/api/sync", []byte(`{}`), nil); code != 401 {
		t.Fatalf("want 401, got %d", code)
	}
	var out map[string]string
	body, _ := json.Marshal(credentials{"z@x.io", "short"})
	if code := a.do("POST", "/api/auth/register", body, &out); code != 400 {
		t.Fatalf("weak password: %d", code)
	}
}
