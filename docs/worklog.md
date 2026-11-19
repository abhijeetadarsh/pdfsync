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
