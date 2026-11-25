# Issue #11: thumbnail implementation and phone verification

Tested on 2026-11-25 on the connected OnePlus CPH2661 phone (`adea1d8a`),
1240 × 2772 pixels, 560 dpi. Installed the native Android profile APK in place,
version code 14, built with Flutter 3.50.0. No application data was cleared.
A disposable local server/account and adb reverse on port 18081 isolated the
checks from the user's server. An HTTP reverse proxy recorded method, path,
and device ID, without authorization headers or request bodies.

## Implementation

- Import renders a PNG from the already-open first page, 360 pixels wide,
  capped at 522 pixels tall. The image has its own disk/IndexedDB cache.
- PDF upload and document/annotation sync complete independently of thumbnail
  upload. Failed preview uploads retry during later normal syncs.
- Authenticated GET/PUT `/api/thumbnails/{sha256}` endpoints require PDF
  ownership. The server validates PNG decoding, a 1 MiB payload limit, and
  dimensions up to 512 × 768. It performs no PDF rendering. Blob garbage
  collection removes the matching thumbnail too.
- Visible library covers request small previews with per-hash deduplication
  and at most three concurrent loads/renders. Flutter's image cache bounds
  decoded memory. Missing previews are briefly throttled during scrolling;
  sync and thumbnail WebSocket notifications permit immediate retries.
- A missing remote preview is generated only from PDF bytes already present
  locally, including after opening/downloading the document. Browsing never
  downloads a full PDF merely to create a preview. Annotation sync is unchanged.

## Automated checks

- `cd server && go test -race ./...`: passed, including thumbnail ownership,
  unauthenticated access, invalid hashes, invalid/truncated PNGs, excessive
  dimensions/payload, retry/download fidelity, and WebSocket notification.
- `PDFSYNC_SERVER_BIN=/tmp/pdfsync-issue11/server flutter test`: all 34 tests
  passed. Includes two devices exchanging a preview while the receiver's PDF
  cache stays empty, existing annotation convergence, offline cache controls,
  persistent preview reuse, upload retry, concurrency/coalescing, visibility
  and scrolling, and notification timing during a missing-preview response.
- `flutter analyze`: no issues.
- `flutter build web`: passed, including the Wasm compatibility dry run.
- `flutter build apk --profile --build-number=14`: passed. The existing
  file_picker Kotlin Gradle migration notice remains informational.

## Native phone results

1. Seeded 12 remote two-page PDFs, 11 PNG fixtures, and one note. After fresh
   sign-in, metadata appeared automatically. Six visible document hashes were
   requested, five preview files were cached, and the missing preview retained
   its placeholder. No test PDF was in the device's PDF cache. The HTTP trace
   contained **zero GET requests to `/api/blobs/`**.
2. Scrolled the library: the number of distinct preview hashes requested grew
   to 11; PDF downloads remained zero. Verified the note was already in the
   local account DB before opening any PDF.
3. Opened the missing-preview document. Only then did its PDF download. The
   phone generated and uploaded a 6,042-byte PNG, independently confirmed by
   downloading it from the thumbnail API.
4. Imported `Issue11-Client-Import.pdf` through the Android document picker.
   The trace showed PDF upload, document sync, then thumbnail upload. The
   server returned the phone-generated 6,167-byte PNG.
5. Added another document remotely while the library was open, initially
   without a preview. Its metadata and placeholder appeared automatically.
   Uploading its thumbnail triggered a WebSocket notification; the phone
   fetched the image without downloading the PDF or requiring manual refresh.
6. Removed the repaired document's offline PDF. Its preview file remained.
   Disconnected the test server route and force-stopped/restarted the app:
   cached previews still rendered, and the removed PDF remained unavailable
   offline. Opening it displayed the existing recoverable download error.
7. Reconnected and retried. Re-downloaded PDF bytes matched their SHA-256.
   The annotations panel still displayed the original note, and reading
   position was preserved.
8. Inspected actual native captures in dark portrait and light landscape,
   including 1.3× text. Covers rendered in list and grid layouts; landscape's
   short viewport requires scrolling, particularly with larger text. No
   Flutter exceptions were logged. Tablet hardware was not connected;
   automated widget coverage includes tablet sizes and larger text.

## Evidence

The plain blue remote images are intentional PNG test fixtures; the imported
and repaired images are actual first-page renders made on the phone.

- [Initial library, thumbnails without PDF downloads](screenshots/issue-11-phone/library-initial.png)
- [Original note after removal and successful re-download](screenshots/issue-11-phone/reader-note.png)
- [Offline restart retaining thumbnails after PDF removal](screenshots/issue-11-phone/library-offline.png)
- [Native landscape grid, normal text](screenshots/issue-11-phone/library-landscape-normal.png)
- [Native landscape grid, larger text](screenshots/issue-11-phone/library-landscape-grid.png)

## Cleanup

The original app files and session were backed up before testing. Test-account
records, generated previews, test PDF copies, the picker fixture, and test adb
routes were removed afterward. Original app files were compared byte-for-byte
with the backup. Font scale, automatic rotation, and the original session/theme
were restored. The updated profile APK remains installed; the app is stopped
so opening it resumes the user's original session.
