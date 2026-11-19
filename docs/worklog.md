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
  movement stops. While hidden it ignores pointers.
- Verified via right-edge brightness on screenshots: 74 at rest (hidden),
  202 during a scroll (visible), 61 2.5 s later (hidden).

### Pinch-zoom sensitivity (user report: too high)
- `scaleGestureSensitivity: 0.6` (pdfrx default 1.0): zoom follows
  (pinch ratio)^0.6. Needs a hand check – adb cannot pinch.
