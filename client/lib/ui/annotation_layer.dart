import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../annotations.dart';
import 'input_policy.dart';

/// Overlay drawn on top of one PDF page. Renders that page's annotations and,
/// depending on the active tool, captures pointer input to create new ones.
class AnnotationLayer extends StatefulWidget {
  const AnnotationLayer({
    super.key,
    required this.pageNumber,
    required this.annotations,
    required this.tool,
    required this.color,
    required this.policy,
    required this.onCreate,
    required this.onDelete,
    required this.onNoteTap,
    required this.onNewNote,
    required this.onContextMenu,
  });

  final int pageNumber;
  final ValueNotifier<Map<int, List<Ann>>> annotations;
  final Tool tool;
  final Color color;
  final InputPolicy policy;
  final void Function(Map<String, dynamic> data) onCreate;
  final void Function(Ann a) onDelete;
  final void Function(Ann a) onNoteTap;
  final void Function(Offset normalizedPos) onNewNote;

  /// Right-click on an annotation (any tool). [globalPosition] places the menu.
  final void Function(Ann a, Offset globalPosition) onContextMenu;

  @override
  State<AnnotationLayer> createState() => _AnnotationLayerState();
}

/// Hit tolerance (screen pixels) of the eraser.
const double kEraserRadius = 12;

/// The in-progress gesture (stroke, highlight box, eraser ring). Kept out of
/// widget state: a pointer move only repaints the small live layer, it doesn't
/// rebuild widgets or repaint the page's saved annotations.
class _Live extends ChangeNotifier {
  List<Offset> stroke = []; // normalized 0–1 page coordinates
  Offset? dragStart;
  Offset? dragEnd;

  // Stroke path in pixels, extended incrementally while drawing.
  Path? path;
  Size pathSize = Size.zero;
  int pathPoints = 0;

  bool get isEmpty => stroke.isEmpty && dragStart == null;

  void clearGesture() {
    stroke = [];
    dragStart = dragEnd = null;
    path = null;
    pathPoints = 0;
    notifyListeners();
  }

  void changed() => notifyListeners();
}

class _AnnotationLayerState extends State<AnnotationLayer> {
  final _live = _Live();
  Size _size = Size.zero;

  // The one pointer currently drawing on this page, and the tool it uses (the
  // back end of a stylus erases whatever tool is selected).
  int? _drawPointer;
  Tool _gestureTool = Tool.pan;
  final Set<String> _erasedThisGesture = {};

  Offset _norm(Offset local) =>
      Offset((local.dx / _size.width).clamp(0.0, 1.0), (local.dy / _size.height).clamp(0.0, 1.0));

  void _cancelLive() {
    _drawPointer = null;
    if (!_live.isEmpty) _live.clearGesture();
  }

  void _onDown(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) {
      final hit = _hit(_norm(e.localPosition));
      if (hit != null) widget.onContextMenu(hit, e.position);
      return;
    }
    if (widget.tool == Tool.pan) return;
    final role = widget.policy.down(e);
    if (role != PointerRole.draw) {
      // E.g. a second finger: the stroke in progress becomes a scroll/pinch.
      final d = _drawPointer;
      if (d != null && widget.policy.roleOf(d) != PointerRole.draw) _cancelLive();
      return;
    }
    if (_drawPointer != null) return;
    _drawPointer = e.pointer;
    _gestureTool = e.kind == PointerDeviceKind.invertedStylus ? Tool.eraser : widget.tool;
    _erasedThisGesture.clear();
    _down(_norm(e.localPosition));
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _drawPointer) return;
    if (widget.policy.roleOf(e.pointer) != PointerRole.draw) return _cancelLive();
    _move(_norm(e.localPosition));
  }

  void _onUp(PointerEvent e) {
    if (e.pointer != _drawPointer) return;
    // The reader unregisters the pointer after this (its global route runs last).
    if (e is PointerCancelEvent || widget.policy.roleOf(e.pointer) != PointerRole.draw) return _cancelLive();
    _drawPointer = null;
    _up();
  }

  void _down(Offset p) {
    switch (_gestureTool) {
      case Tool.ink:
        _live.stroke = [p];
        _live.changed();
      case Tool.highlight:
        _live.dragStart = _live.dragEnd = p;
        _live.changed();
      case Tool.eraser:
        _erase(p);
      case Tool.note:
        final hit = _hit(p);
        if (hit != null && hit.type == 'note') {
          widget.onNoteTap(hit);
        } else {
          widget.onNewNote(p);
        }
      case Tool.pan:
        break;
    }
  }

  void _move(Offset p) {
    switch (_gestureTool) {
      case Tool.ink:
        // Skip sub-pixel moves: they add points (and work) but nothing visible.
        final last = _live.stroke.last;
        if ((last.dx - p.dx).abs() * _size.width < 0.5 && (last.dy - p.dy).abs() * _size.height < 0.5) return;
        _live.stroke.add(p);
        _live.changed();
      case Tool.highlight:
        _live.dragEnd = p;
        _live.changed();
      case Tool.eraser:
        _erase(p);
      default:
        break;
    }
  }

  void _up() {
    final base = {'page': widget.pageNumber, 'color': widget.color.toARGB32()};
    final stroke = _live.stroke, start = _live.dragStart, end = _live.dragEnd;
    if (_gestureTool == Tool.ink && stroke.isNotEmpty) {
      widget.onCreate({...base, 'type': 'ink', 'width': 0.003, 'points': flatten(simplify(stroke))});
    } else if (_gestureTool == Tool.highlight && start != null && end != null) {
      final r = Rect.fromPoints(start, end);
      // Minimum size in page pixels, not normalized units: on a very tall
      // page a normal drag is a tiny fraction of the height.
      if (r.width * _size.width > 8 && r.height * _size.height > 6) {
        widget.onCreate({
          ...base,
          'type': 'highlight',
          'rects': [
            [q(r.left), q(r.top), q(r.width), q(r.height)]
          ],
        });
      }
    }
    _live.clearGesture();
  }

  Ann? _hit(Offset p) {
    final list = widget.annotations.value[widget.pageNumber] ?? const [];
    for (final a in list.reversed) {
      if (_erasedThisGesture.contains(a.id)) continue;
      if (a.hit(p, _size, tolPx: kEraserRadius)) return a;
    }
    return null;
  }

  void _erase(Offset p) {
    final a = _hit(p);
    // Each annotation is deleted once per gesture, not once per move event.
    if (a != null && _erasedThisGesture.add(a.id)) widget.onDelete(a);
  }

  /// One system cursor per tool, so the tool in use shows at a glance. Only
  /// system cursors: they move with no delay, whereas anything the app draws
  /// at the pointer (the old eraser ring) trails it by a frame or two.
  MouseCursor get _cursor => switch (widget.tool) {
        // Hand tool: let the viewer choose (I-beam over text, for selecting).
        Tool.pan => MouseCursor.defer,
        Tool.ink => SystemMouseCursors.precise, // crosshair
        Tool.highlight => SystemMouseCursors.cell, // gapped crosshair (Adwaita)
        Tool.note => SystemMouseCursors.copy, // arrow with a plus: add here
        Tool.eraser => SystemMouseCursors.noDrop, // arrow with a ⊘
      };

  @override
  void dispose() {
    _live.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      _size = size;
      return ValueListenableBuilder<Map<int, List<Ann>>>(
        valueListenable: widget.annotations,
        builder: (context, map, _) {
          final anns = map[widget.pageNumber] ?? const <Ann>[];
          final layer = Stack(children: [
            // Saved annotations: cached in their own layer. Scrolling only
            // moves it; it is repainted when they change or the zoom does.
            if (anns.isNotEmpty)
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(painter: _AnnPainter(anns), isComplex: anns.length > 3),
                ),
              ),
            // The gesture in progress: repaints on its own, per pointer move.
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _LivePainter(_live, color: widget.color),
                ),
              ),
            ),
            for (final a in anns.where((a) => a.type == 'note'))
              Positioned(
                left: a.pos.dx * size.width - 14,
                top: a.pos.dy * size.height - 14,
                // Page overlays sit *above* the viewer in pdfrx, so a normal
                // GestureDetector here would swallow pans/pinches that start on
                // the icon. The interaction region reports taps without being
                // a hit-test target.
                child: PdfOverlayInteractionRegion(
                  // With the note tool active, the tool's own tap handling
                  // opens existing notes; don't open them twice.
                  onTap: widget.tool == Tool.note
                      ? null
                      : (_) {
                          widget.onNoteTap(a);
                          return true;
                        },
                  child: Icon(Icons.sticky_note_2, size: 28, color: a.color),
                ),
              ),
          ]);
          // pdfrx stacks page overlays on top of the viewer (they are not its
          // children), so anything here that is a hit-test target blocks
          // panning and zooming. The painted annotations therefore never take
          // pointers; the *translucent* Listener / MouseRegion see the raw
          // pointers but let them through to the viewer underneath. Whether a
          // pointer draws or navigates is decided by [InputPolicy].
          return MouseRegion(
            opaque: false,
            cursor: _cursor,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onDown,
              onPointerMove: _onMove,
              onPointerUp: _onUp,
              onPointerCancel: _onUp,
              child: IgnorePointer(child: layer),
            ),
          );
        },
      );
    });
  }
}

Rect _den(Rect r, Size size) =>
    Rect.fromLTWH(r.left * size.width, r.top * size.height, r.width * size.width, r.height * size.height);

Paint _strokePaint(Color c, double width, Size size) => Paint()
  ..color = c
  ..strokeWidth = width * size.width
  ..style = PaintingStyle.stroke
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

/// The page's saved annotations.
class _AnnPainter extends CustomPainter {
  _AnnPainter(this.anns);
  final List<Ann> anns;

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in anns) {
      switch (a.type) {
        case 'highlight':
          final paint = Paint()
            // Plain alpha blending: `multiply` made highlights invisible on
            // dark pages (anything multiplied with near-black stays black).
            ..color = a.color.withValues(alpha: 0.4);
          for (final r in a.rects) {
            canvas.drawRect(_den(r, size), paint);
          }
        case 'ink':
          final pts = a.points;
          if (pts.isEmpty) continue;
          final paint = _strokePaint(a.color, a.width, size);
          if (pts.length == 1) {
            canvas.drawCircle(Offset(pts.first.dx * size.width, pts.first.dy * size.height), paint.strokeWidth / 2,
                paint..style = PaintingStyle.fill);
            continue;
          }
          final path = Path()..moveTo(pts.first.dx * size.width, pts.first.dy * size.height);
          for (var i = 1; i < pts.length; i++) {
            path.lineTo(pts[i].dx * size.width, pts[i].dy * size.height);
          }
          canvas.drawPath(path, paint);
      }
    }
  }

  // The annotations map is rebuilt only when the store changes, so identity
  // is enough. (A size change repaints regardless.)
  @override
  bool shouldRepaint(_AnnPainter old) => !identical(old.anns, anns);
}

/// The gesture in progress; repaints itself whenever [_Live] notifies.
class _LivePainter extends CustomPainter {
  _LivePainter(this.live, {required this.color}) : super(repaint: live);
  final _Live live;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = live.stroke;
    if (stroke.isNotEmpty) {
      final paint = _strokePaint(color, 0.003, size);
      if (stroke.length == 1) {
        canvas.drawCircle(Offset(stroke.first.dx * size.width, stroke.first.dy * size.height), paint.strokeWidth / 2,
            paint..style = PaintingStyle.fill);
      } else {
        // Extend the cached path with the points added since the last frame
        // instead of rebuilding it (long strokes stay cheap).
        if (live.path == null || live.pathSize != size) {
          live.path = Path()..moveTo(stroke.first.dx * size.width, stroke.first.dy * size.height);
          live.pathSize = size;
          live.pathPoints = 1;
        }
        for (var i = live.pathPoints; i < stroke.length; i++) {
          live.path!.lineTo(stroke[i].dx * size.width, stroke[i].dy * size.height);
        }
        live.pathPoints = stroke.length;
        canvas.drawPath(live.path!, paint);
      }
    }
    final start = live.dragStart, end = live.dragEnd;
    if (start != null && end != null) {
      canvas.drawRect(_den(Rect.fromPoints(start, end), size), Paint()..color = color.withValues(alpha: 0.4));
    }
  }

  @override
  bool shouldRepaint(_LivePainter old) => old.color != color || !identical(old.live, live);
}
