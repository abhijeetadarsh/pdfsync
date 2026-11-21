# Performance

## Measuring

- **Frame log:** build with `--dart-define=PDFSYNC_PERF=true`
  (`client/lib/perf.dart`). Every ~2 s of activity the app prints
  `PERF frames=N build avg/p90/max raster avg/p90/max janky=J` (ms;
  janky = build or raster > 16 ms). It goes to stdout on desktop and to
  `adb logcat` (`grep 'flutter.*PERF'`) on Android. Off by default, and
  compiled out unless the define is set.
- **Never judge smoothness on a debug build.** Debug Flutter is JIT-compiled
  and many times slower. `scripts/install-android.sh` installs the **profile**
  APK by default (`flutter build apk --profile`). It runs at release speed and,
  like debug, may reach a plain `http://` dev server.
- **Desktop bench (Linux, i3):** a separate copy of the app (`XDG_DATA_HOME` in
  a scratch dir, test account) with the 1556-page book. The window is made
  floating at 1600×1000 (`i3-msg "[id=…] floating enable, resize set 1600 1000"`)
  so runs are comparable. Before each run: `Ctrl+0` (fit width), `Home`. Then
  xdotool drives fixed scenarios: 90 wheel notches, middle-drag, a 150-move pen
  stroke, wheel with the pen tool, Ctrl+wheel zoom, 25× Page Down.
  Run every variant ≥2× because results vary a lot between runs.

## What was slow and what changed (2026-11-21)

Machine: i5-1035G1, Intel Iris Plus G1 (Ice Lake) iGPU, Impeller/OpenGL.

| Cause | Fix |
|---|---|
| Above `onePassRenderingScaleThreshold` (default 200 dpi = 2.78×), pdfrx re-renders a sharp image of *just the visible area* after every scroll and uploads it to the GPU. Fit-width is 3.1–3.7× on a laptop window and on the tablet, so normal reading always took that path. | `PdfViewerSizeDelegateProviderLegacy(onePassRenderingScaleThreshold: 4.0)` renders each page once (cached, just moved while scrolling). `maxImageBytesCachedOnMemory: 256 MB` (~10 pages at ~21 MB). |
| pdfrx's default page drop shadow is a blur mask filter, drawn for every page in the cache extent on every frame. | `pageDropShadow: null` (the themed gutter already separates pages). |
| The reader rebuilt on every pointer down and up. Each rebuild hands pdfrx new params, which makes it re-lay out every page (1556 here). | Rebuild only when the viewer's pan/zoom permission actually changes (`_navPan` / `_navScale`). |
| Annotation layer: every pointer move did `setState` and repainted all saved annotations of the page plus the stroke (`shouldRepaint => true`), with no repaint boundary. So every scroll frame also re-recorded every annotation. | Saved annotations in a `RepaintBoundary` with `shouldRepaint` by identity. The gesture in progress is in a separate painter driven by a `ChangeNotifier` (no widget rebuilds), with the stroke path extended incrementally. Sub-pixel moves are skipped. |
| `Ann.points` / `rects` / `pos` re-parsed the JSON lists on every access (every paint, every eraser move × every annotation). | `late final`, parsed once per `Ann`. |
| Page thumb / bars repainting together with the viewer. | `RepaintBoundary` around the viewer and around the page thumb. |

### Results (Linux, 1600×1000, release, ms: raster p90 / janky frames per ~120)

| Scenario | before | after |
|---|---|---|
| wheel scroll | 16.9–18.3 / 14–27 | 6.7–7.9 / 0–3 |
| wheel scroll, pen tool | 12.6–18.4 / 8–15 | 5.8–6.9 / 0–2 |
| middle-drag | 10.9–11.5 / 1–3 | 7.4–8.3 / 0 |
| pen stroke (build avg) | 0.4–0.5 ms | 0.2–0.4 ms |
| 25× Page Down | 9.2–9.6 / 0–3 | 8.9–11.1 / 1–8 |

Frame rate is steady 60 fps (~121 frames per 2 s). What remains:
- About a 6 ms raster floor per frame on this iGPU.
- Single 20–40 ms frames when a freshly rendered page (~2000×2700 px) is
  uploaded to the GPU, mostly when jumping pages quickly. That's inside pdfrx.

Tablet (`HA2891X3`, profile build): finger drags and flings were 0 janky frames,
raster p90 1.5–4.5 ms, ~120 fps. The lag seen there before was the debug build.

## Scroll feel (2026-11-21)
The user asked for "continuous scrolling, virtualized tile-based rendering and
momentum / smooth-scroll interpolation" because scrolling still felt slow.
Settings are in `client/lib/ui/scroll_feel.dart`.

What pdfrx already does, and what was changed:

| Piece | Before | Now |
|---|---|---|
| Continuous scrolling | pdfrx lays all pages out in one scrolling column | unchanged |
| Virtualised rendering | only pages within 1 viewport of the screen are rendered; the rest are placeholders | 2 viewports ahead/behind (`verticalCacheExtent`/`horizontalCacheExtent` = 2.0) so fast scrolling reaches pages that are already rendered |
| Wheel interpolation | 106 px per notch, exponential glide (friction 18) | 159 px per notch, snappier glide (friction 22), **acceleration** from the recent wheel rate: slow notches 1×, ~2.5× when spun steadily, up to 3× when spun fast. Trackpad deltas (< 40 px) are not accelerated |
| Finger / middle-drag momentum | InteractiveViewer friction 0.0000135: a fling travels v / 11, so a 3000 px/s flick stopped after ~270 px | `interactionEndFrictionCoefficient` 0.07: travels v / 2.66 (~1130 px, ~1.2 s glide), close to a native Android list |

`scrollPhysics` (pdfrx's other way to get native flings) was not used: setting
it turns off `normalizeMatrix`, which the reader uses to keep pages from
scrolling past the edges and under the bars.

Tile-based rendering: pdfrx renders each page as one image (here up to 4×
scale) and, when zoomed in beyond that, a single image of the visible part of
the page, not a grid of tiles. A real tile grid would need a fork of pdfrx.
It isn't worth it now: frame times are 6–9 ms (p90) on the laptop iGPU and
~2 ms on the tablet, well under the 16 ms budget. The remaining cost is
uploading freshly rendered pages, which the larger pre-render window now
mostly moves off-screen.

Measured (Linux, same benchmark; tablet, profile build):
- One notch: 159 px. Three notches 250 ms apart: 477 px; 80 ms apart: 524 px;
  40 ms apart: 551 px (the glide also accelerates further on longer spins).
  Unit tests: `client/test/wheel_accel_test.dart`.
- Middle-button flick (90 px drag): glides ~700 px.
- Tablet: a 150 px flick glides ~1045 px; six fast flicks moved 10 pages;
  0 janky frames at ~140 fps (raster p90 ~2 ms).
- Linux benchmark (2 runs): every scenario 0–1 janky frames per ~120; page-down
  ×25 went from 3–5 janky to 0 thanks to the larger pre-render window.

## Tried and not used
- Skia instead of Impeller on Linux: the engine-switch env vars
  (`FLUTTER_ENGINE_SWITCHES`) are ignored in release builds, so it stays Impeller.
