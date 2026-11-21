# PDF Sync

A PDF reader that keeps your PDFs **and their annotations** (highlights, pen strokes, notes, last-read page) in sync across Android, iOS, Windows, macOS, Linux and the web, through one central server.

```
pdfsync/
├── server/   Go 1.24 · net/http · SQLite (WAL) · WebSocket   — single static binary
└── client/   Flutter 3.47+ · pdfrx (PDFium) · sembast         — one codebase, 6 platforms
```

## Why this stack

| Choice | Why |
|---|---|
| **Flutter** (client) | One codebase compiles natively to all six platforms with identical rendering. |
| **pdfrx** (PDFium) | The same PDF engine Chrome uses, on every platform (WASM on web), so pages lay out identically everywhere and annotations line up. |
| **Go** (server) | A single dependency-free binary with cheap concurrency for many WebSockets. `http.ServeContent` gives Range/resume downloads for free. |
| **SQLite** | No separate database to run. WAL mode handles thousands of users on one box. Swap it for Postgres later if needed. Every query is plain SQL. |

## How the sync works

1. **Annotations are records, not PDF edits.** The PDF bytes never change. Each highlight, stroke or note is its own small JSON record (about 100–400 bytes). Editing one highlight sends one record, not a 40 MB file.
2. **Content-addressed PDFs.** Files are stored by SHA-256. The client sends a `HEAD` request first, so a file already on the server is never uploaded again. Identical files share one copy on disk, but every user still has to upload the bytes once to prove they own them, so nobody can fetch a file just by knowing its hash. Downloads are cached as immutable, support HTTP Range, and only happen when you open a document.
3. **Delta sync with a cursor.** Every accepted write gets a per-user sequence number. One `POST /api/sync` request pushes local changes and pulls everything after the client's cursor in a single round trip, paginated 500 at a time. The server doesn't send the client's own writes back to it.
4. **Conflict-free merging (LWW + Hybrid Logical Clocks).** Each record carries an HLC timestamp such as `1731650000000-0003-k3j9x2pq`. The newest write wins, per annotation. So two devices editing *different* annotations offline never conflict, and edits to the *same* one converge on every device. Deletes are tombstones, so a delete also syncs and can win. Deleting a document also deletes its annotations. The server rejects timestamps more than 10 minutes in the future and tells clients the server time, so a wrong device clock can't win every conflict.
5. **Realtime push.** A WebSocket only signals "something changed". Devices then run the normal delta sync. A missed signal does no harm, because clients also sync on app resume, on reconnect (exponential backoff), and every 2 minutes.
6. **Offline-first.** The UI only reads and writes the local DB through live queries. Edits are batched 400 ms after the last change. An offline device keeps working and catches up later.
7. **Small payloads.** Coordinates are normalized to 0–1 of the page size, so positions don't depend on resolution or zoom. They are rounded to 4 decimals. Pen strokes are simplified with Ramer–Douglas–Peucker, which shrinks them about 10× with no visible change.

## Run the server

```bash
cd server
go run . -addr :8080 -data ./data          # or:
docker build -t pdfsync . && docker run -p 8080:8080 -v pdfsync:/data pdfsync
```
Flags/env: `-addr` (`PDFSYNC_ADDR`), `-data` (`PDFSYNC_DATA`), `-max-upload-mb` (512), `-cors` (`PDFSYNC_CORS`, default `*`; set it to your web app's origin in production).
**Put it behind TLS in production** (Caddy, nginx or a cloud load balancer). Tokens are bearer tokens.

## Run the app

```bash
cd client
flutter pub get
flutter run -d chrome        # or: -d macos / windows / linux / <android/ios device>
flutter build apk | ipa | macos | windows | linux | web
```
Sign in with the server URL, for example `http://<your-LAN-ip>:8080` from a phone. Windows builds need Developer Mode (a pdfrx requirement). Plain `http://` is blocked by default on iOS and Android. Use HTTPS, or allow cleartext traffic for local testing.

**Tools:** navigate · highlight (drag a box) · pen · sticky note (tap) · eraser (tap or drag over an annotation) · 5 colours. The last-read page syncs as well.

**Input:** on desktop the bars stay visible, the mouse wheel scrolls in every tool, Ctrl+wheel zooms, middle-drag pans, right-click edits or deletes an annotation, and keyboard shortcuts are shown in the tooltips. On touch devices a stylus draws and fingers scroll; without a stylus, one finger draws and two navigate. See [docs/input-model.md](docs/input-model.md).

## Tests

```bash
cd server && go test ./...                                    # API: dedup, auth, LWW, tombstones, skew guard, pagination, WS push, isolation
cd server && go build -o /tmp/pdfsync-server . && cd ../client \
  && PDFSYNC_SERVER_BIN=/tmp/pdfsync-server flutter test     # 2–3 simulated devices against the real server
```

## API

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/auth/register`, `/api/auth/login`, `/api/auth/logout` | `{email,password}` → `{userId, token}` |
| HEAD/PUT/GET | `/api/blobs/{sha256}` | check / upload (hash-verified) / download (Range) |
| POST | `/api/sync` | `{cursor, changes[]}` → `{accepted, rejected, changes, cursor, hasMore, serverTime}` |
| GET | `/api/ws?token=…&device=…` | `{"type":"changed","cursor":N}` pokes |

Record kinds: `document`, `annotation`, `readstate`, `folder` (reserved for folders in the UI).

## Natural next steps
- Highlight by text selection (pdfrx has a text-selection API) in addition to drawing a box.
- Export a PDF with the annotations written in as standard PDF annotations, so they show in other readers.
- Resumable chunked uploads for very large files. Postgres and S3 storage for running several servers.
- Sharing documents with other users. The record model supports it: add an ACL on `docId`.

**Releases:** every push to `main` runs the tests, publishes the server image to GHCR and attaches a signed Android APK, a Linux bundle and a Windows bundle to a GitHub Release. Deploy the server on a VM with `deploy/deploy.sh` (Docker Compose, optional HTTPS). See [docs/ci-cd.md](docs/ci-cd.md).
