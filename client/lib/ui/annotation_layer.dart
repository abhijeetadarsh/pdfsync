import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../annotations.dart';

/// Overlay drawn on top of one PDF page. Renders that page's annotations and,
/// depending on the active tool, captures pointer input to create new ones.
class AnnotationLayer extends StatefulWidget {
  const AnnotationLayer({
    super.key,
    required this.pageNumber,
    required this.annotations,
    required this.tool,
    required this.color,
    required this.onCreate,
    required this.onDelete,
    required this.onNoteTap,
    required this.onNewNote,
  });

  final int pageNumber;
  final ValueNotifier<Map<int, List<Ann>>> annotations;
  final Tool tool;
  final Color color;
  final void Function(Map<String, dynamic> data) onCreate;
  final void Function(Ann a) onDelete;
  final void Function(Ann a) onNoteTap;
  final void Function(Offset normalizedPos) onNewNote;

  @override
  State<AnnotationLayer> createState() => _AnnotationLayerState();
}

class _AnnotationLayerState extends State<AnnotationLayer> {
  List<Offset> _stroke = [];
  Offset? _dragStart;
  Offset? _dragEnd;
  Size _size = Size.zero;

  // Pointers currently down on this page. One finger draws; as soon as a
  // second finger lands the gesture belongs to the viewer (scroll / pinch
  // zoom), so whatever was being drawn is discarded.
  final Set<int> _pointers = {};
  bool _multi = false;
  final Set<String> _erasedThisGesture = {};

  Offset _norm(Offset local) => Offset(
      (local.dx / _size.width).clamp(0.0, 1.0), (local.dy / _size.height).clamp(0.0, 1.0));

  void _cancelLive() {
    if (_stroke.isEmpty && _dragStart == null) return;
    setState(() {
      _stroke = [];
      _dragStart = _dragEnd = null;
    });
  }

  void _onDown(PointerDownEvent e) {
    _pointers.add(e.pointer);
    if (_pointers.length > 1) {
      _multi = true;
      _cancelLive();
      return;
    }
    _erasedThisGesture.clear();
    _down(_norm(e.localPosition));
  }

  void _onMove(PointerMoveEvent e) {
    if (_multi || !_pointers.contains(e.pointer)) return;
    _move(_norm(e.localPosition));
  }

  void _onUp(PointerEvent e) {
    final wasTracked = _pointers.remove(e.pointer);
    if (wasTracked && !_multi) _up(cancelled: e is PointerCancelEvent);
    if (_pointers.isEmpty) _multi = false;
  }

  void _down(Offset p) {
    switch (widget.tool) {
      case Tool.ink:
        setState(() => _stroke = [p]);
      case Tool.highlight:
        setState(() => _dragStart = _dragEnd = p);
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
    switch (widget.tool) {
      case Tool.ink:
        setState(() => _stroke.add(p));
      case Tool.highlight:
        setState(() => _dragEnd = p);
      case Tool.eraser:
        _erase(p);
      default:
        break;
    }
  }

  void _up({bool cancelled = false}) {
    if (!cancelled) {
      final base = {'page': widget.pageNumber, 'color': widget.color.toARGB32()};
      if (widget.tool == Tool.ink && _stroke.isNotEmpty) {
        widget.onCreate({...base, 'type': 'ink', 'width': 0.003, 'points': flatten(simplify(_stroke))});
      } else if (widget.tool == Tool.highlight && _dragStart != null && _dragEnd != null) {
        final r = Rect.fromPoints(_dragStart!, _dragEnd!);
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
    }
    setState(() {
      _stroke = [];
      _dragStart = _dragEnd = null;
    });
  }

  Ann? _hit(Offset p) {
    final list = widget.annotations.value[widget.pageNumber] ?? const [];
    for (final a in list.reversed) {
      if (_erasedThisGesture.contains(a.id)) continue;
      if (a.hit(p, _size)) return a;
    }
    return null;
  }

  void _erase(Offset p) {
    final a = _hit(p);
    // Each annotation is deleted once per gesture, not once per move event.
    if (a != null && _erasedThisGesture.add(a.id)) widget.onDelete(a);
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
            Positioned.fill(
              child: CustomPaint(
                painter: _AnnPainter(
                  anns,
                  liveStroke: _stroke,
                  liveRect: (_dragStart != null && _dragEnd != null)
                      ? Rect.fromPoints(_dragStart!, _dragEnd!)
                      : null,
                  color: widget.color,
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
          // pointers.
          final passive = IgnorePointer(child: layer);
          if (widget.tool == Tool.pan) return passive;
          // Drawing tools: a *translucent* Listener sees the raw pointers but
          // still lets them through to the viewer underneath. The reader keeps
          // the viewer's pan/zoom disabled for one finger and enables it while
          // 2+ fingers are down, so one finger draws and two fingers navigate.
          return Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerUp: _onUp,
            onPointerCancel: _onUp,
            child: passive,
          );
        },
      );
    });
  }
}

class _AnnPainter extends CustomPainter {
  _AnnPainter(this.anns, {required this.liveStroke, required this.liveRect, required this.color});
  final List<Ann> anns;
  final List<Offset> liveStroke;
  final Rect? liveRect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    Rect den(Rect r) => Rect.fromLTWH(r.left * size.width, r.top * size.height, r.width * size.width, r.height * size.height);
    Offset dp(Offset p) => Offset(p.dx * size.width, p.dy * size.height);

    void drawStroke(List<Offset> pts, Color c, double w) {
      final paint = Paint()
        ..color = c
        ..strokeWidth = w * size.width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (pts.length == 1) {
        canvas.drawCircle(dp(pts.first), paint.strokeWidth / 2, paint..style = PaintingStyle.fill);
        return;
      }
      final path = Path()..moveTo(dp(pts.first).dx, dp(pts.first).dy);
      for (final p in pts.skip(1)) {
        path.lineTo(dp(p).dx, dp(p).dy);
      }
      canvas.drawPath(path, paint);
    }

    for (final a in anns) {
      switch (a.type) {
        case 'highlight':
          final paint = Paint()
            // Plain alpha blending: `multiply` made highlights invisible on
            // dark pages (anything multiplied with near-black stays black).
            ..color = a.color.withValues(alpha: 0.4);
          for (final r in a.rects) {
            canvas.drawRect(den(r), paint);
          }
        case 'ink':
          drawStroke(a.points, a.color, a.width);
      }
    }
    if (liveStroke.isNotEmpty) drawStroke(liveStroke, color, 0.003);
    if (liveRect != null) {
      canvas.drawRect(den(liveRect!), Paint()..color = color.withValues(alpha: 0.4));
    }
  }

  @override
  bool shouldRepaint(_AnnPainter old) => true;
}
