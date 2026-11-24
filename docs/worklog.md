# Work log

## 2026-11-20 – Android phone + tablet testing, first round of fixes

Branch: `fix/android-testing` (from `main` @ `66dc750`, the imported zip).

### Setup done
- Repo initialised (`git init`), initial import committed on `main`.
- Debug-only `usesCleartextTraffic` added so devices can reach `http://` dev servers.
- See [android-testing.md](android-testing.md) for the device/adb workflow.

### Tested (phone `adea1d8a`, tablet `HA2891X3`, portrait + landscape)
| Area | Result |
|---|---|
| Sign-in, library sync between devices | ✅ works |
| Open PDF, rendering | ✅ works |
| Pen | ✅ works, syncs |
| Sticky note (create) | ✅ works |
| Highlight | ❌ saved but invisible on dark pages; short drags ignored on tall pages |
| Eraser | ❌ one tap deleted annotations ~100 px away (tall pages) |
| Navigation with a tool selected | ❌ impossible to scroll/zoom without switching to the hand tool |
| Rotation | ❌ page kept its old zoom (portrait→landscape too small, landscape→portrait cut off) |
| Toolbar, phone portrait | ❌ overflowed by 62 px (debug overflow stripes) |
| Colour swatches, dark theme | ❌ black swatch invisible |
| Library subtitle | ❌ "1 pages" |
| Login form | ⚠️ no "Next" key between fields |

### Root causes and fixes
- **Highlight invisible** – painted with `BlendMode.multiply`; multiplying with
  a dark page stays dark. Now normal alpha blending at 40 %.
  (`client/lib/ui/annotation_layer.dart`)
- **Short highlights dropped / eraser too greedy** – size thresholds and hit
  tolerances were in normalized 0–1 page units. On a very tall page 0.015 of
  the height is hundreds of pixels (and a 40 px drag is < 0.003). Thresholds
  and hit tests now run in page pixels (`Ann.hit(p, pageSize, tolPx: 12)`).
  (`client/lib/annotations.dart`, `annotation_layer.dart`)
- **Eraser** also deleted the same annotation once per pointer-move event;
  now once per gesture.
- **Can't navigate while drawing** – the viewer's pan/zoom was disabled for
  every drawing tool. Now one finger draws and two fingers pan/zoom: the
  reader counts pointers and enables the viewer's pan/scale while 2+ are down;
  the annotation layer drops the in-progress stroke when a second finger lands.
  (`client/lib/ui/reader_page.dart`, `annotation_layer.dart`)
- **Rotation** – pdfrx keeps the transform matrix on resize. `onViewSizeChanged`
  now scales the zoom by the width ratio around the same document point.
- **Toolbar overflow** – under 440 dp the five colour swatches collapse into a
  single colour button with a popup.
- **Swatch outline** uses the theme's outline colour, so dark colours show.
- **Plural** "1 page" / "n pages"; login fields get Next/Done keyboard actions.

### Verified after the fixes (tablet)
- Highlight visible on the dark PDF; normal-size drag accepted.
- Portrait → landscape keeps the same section in view, page fills the width.
- "1 page" in the library; black swatch outlined.

### Still open / not verifiable via adb
- Two-finger pan/zoom while a tool is active (adb `input` is single-touch only).

## 2026-11-20 (cont.) – Pan/zoom fix, text selection, undo/redo, reading modes

### Pan & zoom didn't work at all (user report)
- **Cause:** pdfrx 2.12 stacks `pageOverlaysBuilder` widgets *above* the viewer
  (they are not its children). Our full-page annotation layer was a hit-test
  target, so it swallowed every touch – no scrolling or pinch zoom even with the
  hand tool.
- **Fix:** painted annotations are wrapped in `IgnorePointer`; note icons use
  `PdfOverlayInteractionRegion` (taps without blocking the viewer); drawing
  tools use a *translucent* `Listener`, so the viewer still receives pointers
  and its pan/zoom is enabled only while 2+ fingers are down.
- Verified: single-finger scroll works on the phone. Pinch zoom needs a manual
  check (adb is single-touch).

### Text selection → highlight (new)
- pdfrx's built-in selection is enabled with the hand tool (long-press, drag
  handles). The context menu gets **Highlight** next to Copy / Select all.
- `lib/ui/text_highlight.dart` converts the selected characters to normalized
  page rects and merges them per line; the selected text is stored with the
  highlight (`text`, capped at 1000 chars).
- Bug found while testing: `PdfRect.toRect(scaledPageSize: Size(1,1))` scales
  both axes by the page *height*, which squashed x on non-square pages. Now
  converted to points and normalized per axis.
- Disabled while a drawing tool is active, so a pen stroke never selects text.

### Undo / redo (new)
- `lib/undo.dart` (`AnnotationHistory`): every annotation create/update/delete
  goes through it; undo/redo are ordinary synced writes, so they reach other
  devices. Restoring a deleted annotation reuses its id; the newer HLC wins over
  the tombstone on the server.
- Buttons in the reader's app bar (bottom toolbar is full on phones).
- Unit test: `test/undo_test.dart`.

### Reading modes (new)
- App-bar picker: Original, Paper, Sepia, Green, Dim, Night
  (`lib/ui/reading_mode.dart`). Applied with `pageImageColorFilter`, so only the
  PDF page is tinted – annotations keep their real colours.
- Night = hue-rotate 180° + invert, so links stay blue instead of turning yellow.
- Per-device preference (local store meta `readingMode`).
- Viewer gutter now follows the app theme instead of pdfrx's mid-grey.

### Tooling
- `scripts/install-android.sh` installs on every connected device and taps the
  ColorOS "Continue installation" prompt via uiautomator.

### Verified on devices
- Tablet portrait: text select → Highlight lines up with the text; undo removes
  it, redo restores it; synced to the phone.
- Sepia and Night on the white résumé PDF; mode persists after reopening.
- Phone portrait: app bar with undo/redo/mode/sync fits (title truncates).

## 2026-11-20 (cont.) – Home page, immersive reading, zoom presets, page navigation

### Note dialog zoom jump (user report)
- **Cause:** the keyboard shrank the reader's Scaffold body → pdfrx re-fit the
  page to the shorter view, then zoomed back when the keyboard closed.
- **Fix:** `resizeToAvoidBottomInset: false` in the reader. Verified on the
  tablet: page stays put while the dialog + keyboard are open.

### Home page (new design, deliberately minimal)
- Grid of cover thumbnails (top of page 1, rendered once at 360 px with
  `renderForDisplay` and cached; very tall pages no longer become slivers).
  Documents not yet downloaded on this device show a cloud placeholder instead
  of downloading just for a thumbnail.
- Recently read first (readstate HLC), thin progress line + "Page n of N".
- Rename / delete behind a long-press bottom sheet (delete now asks first).
- Search icon in the app bar, account avatar menu (email, sign out).
- Opening a document refreshes its readstate so it moves to the front.

### Reader
- **Tap to hide UI:** single tap (hand tool) slides away app bar, toolbar and
  system bars (immersive sticky); tap again to bring them back. Bars float over
  the viewer so toggling never resizes/re-zooms it. Double-tap stays pdfrx zoom.
- **Page/zoom pill** above the toolbar: "3 / 12 | 86%". Tap the page part →
  "Go to page" dialog; tap the zoom part → Fit width, Fit page, 50–300%.
- **Scrollbar thumb** on the right edge shows the page number and can be
  dragged. Custom widget (`_PageThumb`) because pdfrx's thumb uses the full
  view height and would sit under the floating bars.

### Known / open
- "Go to page" uses pdfrx `goToPage`, which re-fits the zoom (150% → fit).
- Phone flips to landscape after each reinstall (ColorOS resets the rotation
  lock); test scripts must check orientation before tapping.

### Fix: page jumped / got covered when toggling the bars (user report)
- **Jump while hidden:** the viewer's `boundaryMargin` was derived from
  `MediaQuery.padding`, which changes when the status bar hides; pdfrx then
  re-clamped the position. Bar heights are now measured once (re-measured only
  on rotation) and the margin stays constant.
- **Bar covering the page when shown:** the page now moves with the top bar –
  translated down by the bar height when it appears and back up when it hides
  (220 ms, same as the bar animation).
- Verified on the tablet with coordinates: hide → content −166 px (= bar),
  scroll while hidden is smooth, show → content +166 px; nothing covered.
- **Revised per user:** the page must never move when toggling — the bars just
  slide over / away and reveal what is underneath. Removed the page shift; kept
  the fixed insets (which fixed the jump while scrolling with hidden bars).
  Verified: heading at 533 px stays at 533 px on hide; after scrolling, stays
  at 363 px on show.
- **Revised again per user:** the top bar must never cover the page. The viewer
  is now laid out *between* the bars while they are shown; on toggle its top
  edge moves by the bar height and the content is shifted by the same amount
  inside the viewer (`_pendingShift`, applied in `onViewSizeChanged`), so the
  page stays still on screen: hiding reveals more page above, showing tucks
  that strip back behind the bar's edge. On open, page 1 sits flush under the
  bar (boundary-margin gap removed).
  Verified on the tablet: open → page top right under the bar; heading at
  590 px stays at 590 on hide; after scrolling, 420 px stays at 420 on show.

### Fix: could scroll past the top / bottom of the document (user report)
- **Cause:** the `boundaryMargin` added for the floating-bar version still
  allowed overscrolling by the bar heights.
- **Fix:** removed it (pdfrx default `EdgeInsets.zero`); the bar-toggle shift is
  clamped with `makeMatrixInSafeRange`, so at the very top/bottom the page
  snaps to the edge instead of leaving a gap. Removed the open-time gap fix.
- Verified: pull-down on a freshly opened doc doesn't move it; at the end of
  the document the last page stops flush with the toolbar.

### Bars toggle – final behaviour (after several rounds with the user)
Requirement, in the user's words: *"when UI is hidden the margin should be
there so that no slide, and when UI is there no margin (w.r.t. the bar) so that
no slide also."* – i.e. toggling the bars must **never** move the page, page 1
sits right under the top bar, the last page right on the toolbar, and you can't
scroll past either edge.

What did not work and why:
1. Floating bars + `boundaryMargin` → overscroll past the edges, page start
   hidden under the bar.
2. Viewer laid out *between* the bars, resized on toggle, content shifted to
   compensate → pdfrx's size delegate (`PdfViewerSizeDelegateLegacy.
   onLayoutUpdate`) re-clamps with its **own** rules (and may change zoom when
   the zoom equals the old fit scale) on every view-size change, so the page
   jumped by one or both bar heights at the edges.

Final design:
- The viewer is always full screen and **never resizes** (no pdfrx re-clamp).
- `normalizeMatrix: _normalize` replaces pdfrx's clamping: content may scroll
  between `ty ≤ barTop` and `ty ≥ viewH − docH − barBottom` (constant bar
  heights, measured once), narrow/short docs centred.
- `_goToPage` (open + "Go to page") computes the matrix directly
  (`pageTop − margin` × zoom + barTop); pdfrx's `calcMatrixForPage` mixes units.

Verified with `scripts/measure-shift.py` (row-profile alignment between
screenshots): hide / show / pull at top / push at bottom / hide+show mid-doc all
measure **0 px**; only deliberate scrolls move the content.

### Fix: page top under the bar right after opening (user report)
- **Cause:** pdfrx runs its own initial page jump (size delegate +
  `_goToPage`) *after* `onViewerReady`, overwriting our placement, so the page
  opened at `ty = 0` (behind the top bar). Measured: pull-down after open moved
  the page +202 px.
- **Fix:** place the initial page 150 ms after `onViewerReady` (after pdfrx's
  jump has settled) and keep the viewer at opacity 0 until then, so there is no
  visible jump. Verified: pull-down after open = 0 px for both test PDFs.

### Page-number thumb: only while scrolling (user request)
- `_PageThumb` is hidden at rest, fades in when the page actually moves
  (scroll, fling, zoom, or dragging the thumb) and fades out 1.2 s after
  movement stops (shortened on request to 0.6 s + 0.2 s fade). While hidden it
  ignores pointers.
- Verified via right-edge brightness on screenshots: 74 at rest (hidden),
  202 during a scroll (visible), 61 2.5 s later (hidden).

### Pinch-zoom sensitivity (user report: too high)
- `scaleGestureSensitivity: 0.6` (pdfrx default 1.0): zoom follows
  (pinch ratio)^0.6. Needs a hand check – adb cannot pinch.

## 2026-11-21 – Repo health check and status review (no code changes)
- Checked committed files and full history: no build output, DBs, APKs, keys
  or secrets; no blob > 300 KB. `go vet`, `go test ./...` and
  `flutter analyze` are clean.
- `docs/req.md` (untracked) still starts with pasted chat preamble, and it
  describes a folder-sync design (opaque PDFs, Xodo, no built-in viewer) that
  the code no longer follows (reader app + annotation records). Needs a
  decision: update it or mark it superseded.
- `main` holds only the initial import; all work is on `fix/android-testing`.

## 2026-11-21 – First Linux desktop build
- Installed `cmake` and `ninja` (pacman); Flutter's Linux build needs them.
- `flutter build linux --release` → `client/build/linux/x64/release/bundle/pdfsync`
  (33 MB bundle). Starts cleanly (Impeller/OpenGL backend); hand testing by the
  user pending.
- `adb reverse tcp:8080 tcp:8080` set on the tablet (`HA2891X3`) for testing
  alongside the Linux client. The phone (`adea1d8a`) was not connected (not
  on USB, nothing found over wireless adb).

### Mouse-wheel scrolling felt slow (user report, Linux desktop)
- **Cause:** pdfrx's default `scrollByMouseWheel: 0.2`. Measured on Linux
  (X11, `xdotool click 5` + `maim` screenshots of an isolated app instance with
  its own `XDG_DATA_HOME` and a throwaway `wheeltest@local.test` account):
  Flutter reports 53 px per notch, so the page moved ~10 px per notch.
- **Fix** (`client/lib/ui/reader_page.dart`): `scrollByMouseWheel: 2.0`
  (`_kWheelStep`) and `PdfViewerScrollInteractionDelegateProviderPhysics(panFriction: 18)`
  so the wheel glides to the target like browser / Okular smooth scrolling
  instead of jumping. Trackpad two-finger scroll is a separate 1:1 path and is
  unchanged.
- **Verified:** 1 notch = 106 px (twice, residual < 1); frames during one notch
  88 → 96 → 101 → 103 → 106 px (smooth). Keyboard already handled by pdfrx
  (Space, PgUp/PgDn, Home/End, arrows).
- Tablet (`HA2891X3`, portrait): touch drag unaffected (600 px swipe → 556 px).
  Phone not connected; landscape not re-checked (change only touches the
  mouse-wheel path).
- Open: tune `_kWheelStep` by feel; the throwaway `wheeltest` account remains
  in the dev server DB.

## 2026-11-21 (cont.) – Separate desktop and touch behaviour (user request)
Design and rules: [input-model.md](input-model.md). The user picked from these options:
bars always visible, mouse-friendly navigation, keyboard shortcuts and
cursors/tooltips on desktop; on Android "stylus draws, finger scrolls".

### Changes
- New `client/lib/ui/input_policy.dart` (`kDesktop`, `InputPolicy`) plus unit
  tests (`client/test/input_policy_test.dart`, 5 cases).
- `annotation_layer.dart`: drawing goes through `InputPolicy`; one drawing
  pointer per page; inverted stylus = eraser; right-click menu hook; per-tool
  cursors; eraser hover ring. The layer is now always a translucent
  Listener/MouseRegion (it still never blocks the viewer).
- `reader_page.dart`: bars fixed on desktop; `CallbackShortcuts`; shortcut hints in
  tooltips; annotation context menu (colours / edit note / delete);
  `scaleEnabled` on while nothing draws (Ctrl+wheel zoom with a tool selected).
- **Bug found while testing:** the reader's `Listener` around `PdfViewer`
  never received pointer events (Android and Linux), so pointers were never
  unregistered. After one stylus stroke every finger counted as a palm and
  the page couldn't be scrolled. Fixed by tracking pointers through a global
  pointer route. This probably also means the old two-finger-navigate code
  (which relied on that Listener) never worked. That was never verifiable
  through adb.
- Also fixed: the page pill kept the old number after "Go to page" until the
  next scroll (re-read after the next frame).

### Verified
- Linux (isolated instance, test account): click doesn't hide the bars; P →
  crosshair and a mouse stroke; wheel with the pen tool (106 px); Ctrl+wheel with
  the pen tool, also after drawing (313 → 368 %); middle drag with the pen tool (150 px);
  Ctrl+Z / Ctrl+Shift+Z (stroke gone / back); eraser ring with hidden cursor;
  right-click menu → recolour to red, Delete, Ctrl+Z restores; tooltip "Pen (P)";
  Ctrl+G 6 → pill shows 6 / 8 immediately.
- Tablet `HA2891X3`, portrait: tap still toggles the bars; pen tool with no stylus
  seen: a finger draws; `input stylus swipe` draws; a finger afterwards scrolls 658 px and
  doesn't draw; stylus draws again. Test strokes on the user's book (p. 55)
  were erased afterwards (yellow pixels 27,227 → 0).
- `flutter analyze` clean; `flutter test` 7/7.

### Open
- Phone not connected. Landscape not re-checked (no layout changes, only
  input handling and tooltip text).
- Two-finger pinch/pan while drawing on a finger-only device still can't be sent
  through adb and needs a hand check.
- The palm rejection and the stylus's eraser end need a real stylus to check.

## 2026-11-21 (cont.) – Smoothness pass (user: "lags a lot, everything")
Details, method and numbers: [performance.md](performance.md).
- Added an opt-in frame-time log (`--dart-define=PDFSYNC_PERF=true`,
  `client/lib/perf.dart`) and a repeatable xdotool benchmark on a copy of the
  1556-page book in the test account (window pinned at 1600×1000 via i3).
- Fixes: one-pass page rendering up to 4× plus a 256 MB image cache (the main
  cause: pdfrx re-rendered and uploaded a viewport image after every scroll);
  no blurred page shadow; no reader rebuild per pointer event; annotation
  layer split into a cached saved-annotations layer and a cheap live-gesture
  painter; `Ann` geometry parsed once; repaint boundaries for the viewer and
  page thumb.
- Linux wheel scroll: raster p90 ~17 → ~7 ms, janky frames 14–27 → 0–3 per ~120.
- Android: the tablet had a **debug** build; that was most of its lag. The
  install script now installs the profile build by default. The profile
  manifest allows cleartext (dev server). Tablet flings: 0 janky, ~120 fps.
- Re-verified after the refactor (Linux): live stroke and highlight box while
  dragging, saved after release, eraser ring, erase.
- My tablet benchmark moved the user's reading position in the Linux book to
  page 1; reset to page 55 via Go to page.
- The tablet came back in **landscape** after the reinstall (left as is).

### Open
- Single slow frames when a freshly rendered page is uploaded (pdfrx), most
  visible when paging quickly.
- Phone not connected; not measured there.

## 2026-11-21 (cont.) – Scroll feel (user: scrolling still feels slow)
Details: [performance.md § Scroll feel](performance.md#scroll-feel-2026-11-21).
- New `client/lib/ui/scroll_feel.dart`: wheel step 3.0 (159 px per notch),
  smooth glide plus rate-based wheel acceleration (up to 3×), fling friction
  0.07 instead of pdfrx's 0.0000135 (flicks now glide like native Android
  lists, about 4× further), and pages pre-rendered 2 viewports ahead instead
  of 1.
- Added the unit tests `client/test/wheel_accel_test.dart`; all 11 tests pass. The sync
  integration test needs `PDFSYNC_SERVER_BIN` pointing at a built server.
- Measured on Linux and the tablet (portrait), with 0–1 janky frames everywhere.
  The tablet's book was returned to the user's page 268 afterwards.
- My test launcher had left 3 test instances running; it now kills its
  own instances by their `XDG_DATA_HOME`.

### Open
- Landscape and the phone were not re-checked. Only the scroll feel changed,
  not the layout.
- True tile-grid rendering would need a pdfrx fork; not needed at current frame
  times.

## 2026-11-21 (cont.) – Eraser cursor lag (user: "eraser cursor is lagging")
- Two causes. (1) The eraser hid the system pointer and drew only its own ring,
  which is always a frame or two behind the hand. (2) The ring was drawn
  inside each page and moved only on mouse moves, so wheel-scrolling carried
  it away from the pointer (reproduced: the ring left the pointer after 4 notches).
- Fix: the eraser shows the system crosshair (no delay), and the ring is drawn
  once by the reader over the viewer in screen coordinates. It is fed by the
  global pointer route and repainted on pointer moves and scrolling, and hidden
  over the bars and the gutters between pages. The eraser hit tolerance and
  ring radius share `kEraserRadius`.
- Checked on Linux: the ring stays on the pointer after scrolling and is hidden
  over the top bar; erasing a pen stroke still works; hover has 0 janky frames.
  11/11 tests pass. Tablet: profile build installed, but the stylus ring was
  not checked visually (adb can't hover a stylus).

## 2026-11-21 (cont.) – Eraser ring removed; a cursor per tool
- The user still found the ring laggy (anything the app draws trails the system
  pointer) and asked for no ring and a different cursor per tool, like other
  editors. The ring and its reader-level painter are removed. Cursors: pen
  `precise`, highlight `cell`, note `copy`, eraser `noDrop`, hand defers to
  pdfrx. The shapes were checked against the user's Adwaita theme.
- Mistake while editing: removing the ring also deleted the page thumb and the
  top bar from the reader's Stack. Caught by the analyzer (unused `appBar`),
  restored, and confirmed on a screenshot. Also reverted formatting-only
  changes my `dart format lib/ui` had made to library_page.dart and
  text_highlight.dart.
- Verified with Linux screenshots of each tool's cursor; 11/11 tests pass; Linux
  release and tablet profile builds installed.

## 2026-11-21 (cont.) – GitHub repo and CI/CD
- Private GitHub repo; work committed on `fix/android-testing`.
- `.github/workflows/release.yml` (main only): tests → server Docker image to
  GHCR (the user chose "image only", no deploy target), signed APK, Linux and
  Windows bundles → GitHub Release. Details: [ci-cd.md](ci-cd.md).
- Release signing key generated outside the repo (`~/.config/pdfsync-release/`)
  and stored as repo secrets. Verified locally that a release APK is signed with
  it (SHA-256 c80d667f…).
- Fixes needed for that: release builds failed in lint (`lintVital` crash on
  url_launcher_android) → those tasks are skipped; the Dockerfile used Go 1.24,
  but go.mod requires 1.26.
- Not committed: `docs/req.md` (it still starts with pasted chat text).

### Open
- Release APK allows HTTPS only; the server needs TLS in front of it for the
  release app.
- The Windows build has never been run.


## 2026-11-21 (cont.) – First release run failed
- Run 44914062145 (merge of PR #1): every build job passed, but `GitHub Release`
  failed. `download-artifact` downloaded every artifact of the run, including
  the `*.dockerbuild` build record that `docker/build-push-action` uploads, and
  failed to extract it ("Artifact download failed after 5 retries").
- Fix: the release job downloads only the `android`, `linux` and `windows`
  artifacts, and the server job sets `DOCKER_BUILD_RECORD_UPLOAD=false`.

## 2026-11-21 – "Cannot reach server: Failed host lookup" on the phone (branch `fix-android-internet-permission`)

- Symptom (phone, screenshot): signing in against `https://pdfsync.tomiarb.com`
  showed `SocketException: Failed host lookup ... No address associated with
  hostname, errno = 7`.
- Ruled out the server and DNS: on the VM the container is up and Caddy proxies
  `pdfsync.tomiarb.com` → `127.0.0.1:8000`; `/healthz` returns 200 over HTTPS;
  the A record resolves on 1.1.1.1 and 8.8.8.8; `adb shell ping` on the phone
  resolved the name too. So only the app could not resolve it.
- Cause: `android.permission.INTERNET` was declared only in
  `android/app/src/debug` and `profile` manifests (Flutter's template), not in
  `main`. A release build therefore has no network permission, and Android
  reports that as a host-lookup failure (errno 7). The dev builds hid it.
  `dumpsys package` showed no INTERNET in the installed app.
- Fix: added the permission to `client/android/app/src/main/AndroidManifest.xml`.
- Install gotchas: the phone had versionCode 2 from another source, so the
  `+1` build was rejected (`INSTALL_FAILED_VERSION_DOWNGRADE`), and a
  `--build-number 10` build was rejected as well (`UPDATE_INCOMPATIBLE`, different
  signing key). Uninstalled the old app (it was on the login screen, no data)
  and installed the new one.
- Verified on the phone (portrait): `dumpsys` lists INTERNET granted; signing in
  with a bogus account now returns the server's `invalid email or password`
  instead of the lookup error. Nothing was created on the server.
- Open: tablet not connected this session, so not re-tested there; landscape
  not checked (no UI change). Real sign-in with the user's account not done.
  Release builds still need a higher `+N` build number than what is installed.

## 2026-11-24 – Approved UI implementation

- Pulled `origin/main` with fast-forward from `6c95a76` to `e7e3378`, then created `feat/approved-ui-design`. Temporarily stashed and restored the pre-existing worklog changes; preserved all local prototype/context files. `ui-showcase.html` was excluded from the implementation.
- Implemented the approved `ui-design-fixed.html` direction in Flutter: near-black/lavender theme, bundled JetBrains Mono (regular/bold with OFL license), square controls, matching light appearance and persistent Dark/Light/System preference in the account menu.
- Rebuilt sign-in with the approved layout, server configuration, validation, password visibility, registration mode, loading/error feedback, and autofill.
- Rebuilt the library with title search, filters derived from real saved pages, continue-reading, phone rows, tablet grid/list switching, desktop selection/detail, and existing import/rename/delete/account actions. Real sync status replaces the mock status; cached PDF covers stay local-only until the document is downloaded, preserving bandwidth behavior.
- Restyled reader tools and annotation colors, placed tools at the top on expanded windows, and added a live annotations sheet/panel with type/text/page filtering, page navigation, note editing, deletion through undo history, actual ink previews, and Copy as Markdown. Kept existing PDF renderer cache/performance settings, annotation coordinates and input policy.
- Added meaningful widget tests for sign-in/server validation, six library viewport sizes including landscape, filtering/search recovery, and live annotation navigation/export. `flutter analyze`: clean. Full `flutter test` suite: 14 passed, including the real two-device sync integration test with `/tmp/pdfsync-server`.
- Built web release and Android profile APK using Flutter 3.50 and JDK17. APK: `client/build/app/outputs/flutter-apk/app-profile.apk`. Build emitted an existing `file_picker` Kotlin-plugin migration warning, but succeeded.
- Verified Flutter web against an isolated local test server/account and actual generated PDFs: authentication, synced library, resume, PDF rendering, responsive annotations, and light appearance. Captures under `.impeccable/review/*-web-*.png` are browser evidence, not native screenshots. No JavaScript errors observed on the successful walkthrough.
- Ran `scripts/install-android.sh`; no authorized devices were eligible. Phone `adea1d8a` is unauthorized, tablet `HA2891X3` is disconnected, and no emulator is installed. Native phone/tablet portrait/landscape, OS safe areas, gestures, stylus, and performance remain unverified.
- Implementation direction and constraints: [Approved UI implementation](approved-ui-implementation.md). Actual system tokens: [DESIGN.md](../DESIGN.md) and `.impeccable/design.json`. Existing `PRODUCT.md` still contains earlier pre-approval wording; it was not rewritten as a side effect.
- Independent Impeccable visual/source review in progress; final findings and any correction will be recorded below. No commit, push, or merge performed.
- Independent review requested two material corrections: resize zoom/position ownership and compatibility with existing local-domain login addresses. Added `ResponsivePdfSizing`, which applies resize from the pre-resize layout snapshot once, preserving width-relative zoom and the page-relative anchor; removed the competing delayed transform. Login validation now matches the server's `@` requirement. Regression test confirms `reader@lan` reaches successful authentication.
- Rebuilt the corrected web release; repeated real browser sign-in using `reader@lan`, PDF resume, desktop → phone → landscape → tablet → desktop resizing, and annotations-panel close/open. Tablet reader now shows complete document lines at 115%; desktop returns to 183% with the panel, 236% without it; saved page23 remains the reading anchor. No JavaScript errors. Re-ran analysis and the full14 tests successfully.
- Impeccable verdict: **ship at the scope of the two scored fixes**; both resolved. This is not a whole-surface native certification. Documenter rechecked the completed system and recorded the sizing behavior in DESIGN.md. Native phone/tablet testing remains open as noted above.

## 2026-11-24 – Tablet install and web launch

- Tablet `HA2891X3` reconnected and authorized. Opened the running Flutter web release at `http://127.0.0.1:18767` using `xdg-open`; local HTTP returned200.
- Initial profile install was refused because installed version3 exceeded local version1. Rebuilt profile with `--build-number=4`. Android then refused the debug signature: installed app uses the project release certificate.
- Used the existing signing material in `~/.config/pdfsync-release/` to sign the profile APK without copying passwords or keys into the repository. Verified the certificate digest matches the installed APK. Installed with `scripts/install-android.sh client/build/app/outputs/flutter-apk/app-tablet-profile.apk`: Success; package reports versionCode4 and updated installation time. No uninstall or app-data clearing occurred.
- Launched PDF Sync. Existing account, five documents, saved pages and annotation counts remain available. Captured and inspected native tablet library in portrait and landscape under `.impeccable/review/tablet-native-{portrait,landscape}.png`; no Flutter exception/overflow/fatal crash appeared in the inspected logcat window. Restored auto-rotation to its original enabled state.
- This is installation/library smoke coverage, not a complete reader/stylus/performance test. Phone still unauthorized. Existing docs describing both test devices as debug-signed do not match this tablet's current release certificate; future tablet updates must use the same release certificate and a build number above4.

## 2026-11-24 – Android launcher branding and phone install

- Set Android launcher label to `PDF Sync` through `@string/app_name`; replaced Flutter launcher PNGs with the approved lavender PDF mark. Added adaptive foreground/background layers and Android13 monochrome support. Existing app identifier remains `io.pdfsync.pdfsync`.
- Added reproducible `scripts/generate-android-icon.py` and `client/assets/branding/pdf-mark.svg`. Letter outlines come directly from bundled JetBrains Mono Bold under the existing OFL license. Native vector resources carry the foreground; legacy PNGs are rasterized from the SVG at all five densities. No image-generation service used.
- Phone `adea1d8a` became authorized and user explicitly requested installation there. Its installed version was10/debug-signed; tablet was version4/release-signed. Bumped pubspec to `1.0.0+11` to support in-place updates on both.
- Profile build succeeded with Flutter3.50/JDK17 (`--no-pub`; only version/resources changed). APK badging verifies versionCode11 and application-label `PDF Sync`. Validated all new XML and PNG density dimensions; inspected the generated icon.
- Signed the tablet variant with the existing project release key, retaining the debug-signed artifact for the phone. Installed both with `scripts/install-android.sh` targeted through `ANDROID_SERIAL`. Both package managers report versionCode11; both installations succeeded without uninstalling or clearing app data.
- Installer now supports `ANDROID_SERIAL`, propagates install failures, and terminates its prompt watcher after completion instead of leaving it running. `bash -n` passes.
- Opened Android App info on both devices and inspected native captures showing the lavender PDF icon and `PDF Sync` name (`.impeccable/review/{phone,tablet}-native-app-icon.png`). Android applies each device's normal adaptive icon mask. Relaunched the app on both after checking.

## 2026-11-24 – Commit and push preparation

- User requested committing and pushing the approved implementation branch. Included Flutter UI, tests, bundled fonts/license, Android branding, targeted installer support, approved HTML reference, design tokens and implementation documentation. Excluded pre-existing unrelated context, screenshots, skill installations and rejected showcase files.
- Confirmed staged whitespace checks, installer shell syntax, and generated Android resources; retained the earlier clean analysis/full14-test/build/device-install evidence. Private signing material and device captures are excluded.
## 2026-11-24 – Issue #8: local PDF cache controls

- Created `fix/issue-8` from local `main`. Switching required stashing the
  pre-existing `docs/worklog.md` changes; they remain in the named stash
  `Preserve worklog before branching for issue #8`. Untracked user files were
  left in place. Local main was one commit behind origin/main.
- Added an Available offline badge and filter to the library, a visible PDF
  options button, and Remove from this device in the existing action sheet.
  Cache removal keeps document metadata, annotations, and reading position.
- SyncEngine exposes cache status, import caching, and guarded removal. Removal
  requires the existing uploaded:<sha> server-copy marker, protecting imported
  PDFs awaiting upload. Content hashes are deduplicated when checking status,
  so entries sharing PDF bytes update together. Imports, downloads, removals,
  and sync status changes refresh library availability.
- Reopening an evicted PDF downloads it again. Unavailable downloads now explain
  that a server connection is needed and offer Try again. Thumbnail widgets own
  image clones so eviction can release shared rendered covers safely.
- Verification: built a local Go server and ran all 21 Flutter tests, including
  server-backed eviction/re-download, unsynced-copy protection, metadata and
  annotation preservation, duplicate hashes, cache notifications, and download
  failure behavior. Widget checks cover phone/tablet sizes in both orientations,
  light theme and dark theme with 1.3 text scale. The initial landscape sheet
  overflow was fixed with a scrollable sheet. Static analysis and the production
  web build (including the Wasm dry run) pass.
- Inspected rendered widget previews with real Roboto and Material icon fonts;
  optional PNG captures are written to /tmp/pdfsync-cache-*.png using
  PDFSYNC_CAPTURE_WIDGETS=1 and PDFSYNC_TEST_FONT_DIR pointing at Flutter's
  bin/cache/artifacts/material_fonts directory. They use placeholder PDF bytes
  and are widget previews, not device screenshots.
- Open: adb reports no connected phone or tablet, so installation and actual
  Android device checks could not be performed. Bulk clearing and cache storage
  dashboards are outside this fix.

## 2026-11-24 – Issue #8: connected tablet verification

- Tested the native profile build on the connected Motorola tablet in portrait
  and landscape, light/dark themes, and at 1.3× text scale. Verified shared-hash
  offline badges/filter, actual file removal, annotation and page-2 preservation,
  offline failure messaging, successful retry/re-download, and disabled removal
  of a PDF imported before its upload. Removal enabled after successful sync.
- Found an existing unhandled WebSocket readiness error when disconnecting the
  local server. Added a failing regression test, consumed the readiness failure
  (the stream listener still handles reconnect), and verified the fix with all
  22 tests and static analysis. Rebuilt/reinstalled and repeated offline launch,
  reconnect, removal, and SHA-256-verified re-download with no runtime errors.
- Updated the tablet in place to version code 12 using the matching existing
  release key after the default profile signature was rejected. Preserved user
  data: the original account DB checksum and cached-file list are unchanged;
  the original signed-out session and device display settings are restored.
- Full setup, results, cleanup, and direct device screenshots:
  [Cache controls tablet test](cache-controls-tablet-test.md). Phone hardware
  remains untested because only the tablet was connected.

## 2026-11-24 – Issue #8: update branch from latest main

- Corrected the starting base: stashed the in-progress cache work, switched to
  main, ran `git pull --ff-only origin main`, then fast-forwarded fix/issue-8 to
  `02a15a4` (approved UI and Android branding, PR #14). Reapplied the cache work
  and resolved library, reader, and worklog conflicts against the new UI.
- Kept the approved theme, sidebar, list/grid layouts, details pane, reader
  sizing, and annotation panel. Added Offline to the sidebar and Available
  offline to compact filters, with counts, native cache indicators, guarded
  local removal, and download retry. Sidebar navigation scrolls on short
  displays; the short Offline label remains readable at larger text sizes.
- Updated the cache widget tests to exercise the approved theme, list and grid
  actions, filter scrolling, and the desktop details pane. Updated the existing
  missing-blob test double to report `has == false` for availability queries.
- All 25 tests and static analysis pass. The web build and native profile build
  pass. Reinstalled version 13 on the tablet without clearing user data and
  repeated download, shared-file removal, offline filtering, and page-2/note
  preservation on the approved UI. See the follow-up in
  [tablet verification](cache-controls-tablet-test.md).
- Both named stashes remain available: the original user worklog stash and the
  cache-work backup made before updating main. All current feature changes
  remain uncommitted on fix/issue-8.

## 2026-11-24 – Issue #8: commit and push

- Prepared the cache controls, regression tests, tablet verification report, and
  device screenshots for commit on fix/issue-8, based on main at 02a15a4.
- Validation remains: 25 tests passing, clean static analysis, successful web
  and Android profile builds, and native tablet verification. No source changes
  were made after those checks. Unrelated local files and both backup stashes
  are excluded from the commit.
