# Input model: desktop vs. touch

The reader behaves differently depending on how you interact with it. Desktop
means Linux, Windows and macOS (and web running on them), detected with
`kDesktop` in `client/lib/ui/input_policy.dart`.

## Who draws, who navigates (`InputPolicy`)

With a drawing tool selected (highlight, pen, note, eraser), every pointer gets
a role when it goes down:

| Pointer | Role |
|---|---|
| Mouse, left button | draws |
| Mouse, middle button | navigates (pdfrx pans on a middle drag) |
| Mouse, right button | navigates; on an annotation it opens the context menu |
| Stylus | draws (the back end of a stylus erases, whatever tool is selected) |
| Finger, once a stylus has been used | navigates (scroll / pinch) |
| Finger while the stylus is down | ignored (palm rejection) |
| Finger, no stylus seen yet | one finger draws; a second finger turns both into navigation and discards the stroke |

"Stylus seen" is per reader session (it resets when a document is opened). The
viewer's `panEnabled` is on only while a navigating pointer is down and nothing
draws; `scaleEnabled` is on whenever nothing draws, so Ctrl+wheel and trackpad
pinch zoom also work with a drawing tool selected.

Pointer bookkeeping uses a **global pointer route**
(`GestureBinding.instance.pointerRouter.addGlobalRoute`), not a `Listener` around
the `PdfViewer`. A `Listener` there got no events at all with pdfrx 2.12 (on
Android and Linux). Missed "up" events had left a stylus registered as down, so
every later finger was ignored as a palm.

## Desktop only
- The bars stay visible. Clicking the page never hides them (on touch devices a
  tap with the hand tool still toggles immersive mode).
- Mouse wheel: 3.0× pdfrx's step (~159 px per notch on Linux), smooth glide,
  accelerates when spun (see `client/lib/ui/scroll_feel.dart`).
- Cursors: one system cursor per tool – pen: crosshair (`precise`),
  highlight: gapped crosshair (`cell`), note: arrow with a plus (`copy`),
  eraser: arrow with ⊘ (`noDrop`), hand: the viewer's own (I-beam over text).
  Only system cursors are used. Anything the app draws at the pointer
  trails it by a frame or two; an eraser ring tried before felt laggy and was
  removed.
- Tooltips show the keyboard shortcut.

## Everywhere (hinted on desktop)
- Right-click (desktop) on an annotation: recolour, edit note, delete.
- Keyboard: Ctrl/⌘+Z undo, Ctrl/⌘+Shift+Z or Ctrl/⌘+Y redo, V or Esc navigate,
  H highlight, P pen, N note, E eraser, Ctrl/⌘+G go to page, Ctrl/⌘+0 fit
  width. pdfrx already handles Ctrl/⌘+= and -, arrows, PgUp/PgDn, Space,
  Home/End.

## Testing notes
- Desktop: `xdotool` (`mousedown 2` = middle, `click 3` = right, `click 4/5` =
  wheel, `keydown ctrl`) plus `maim -i <win>` screenshots, against a separate
  copy of the app (`XDG_DATA_HOME` pointed at a scratch dir, test account).
  Wait for the window size to settle before clicking: the window manager can
  maximise it after it appears, and early clicks then miss.
- Android: `adb shell input stylus swipe …` sends real stylus events, while
  `input swipe` is a finger. Multi-finger gestures can't be sent through adb.
