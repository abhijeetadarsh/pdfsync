import 'package:material_ui/material_ui.dart';

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

  Offset _norm(Offset local, Size s) =>
      Offset((local.dx / s.width).clamp(0.0, 1.0), (local.dy / s.height).clamp(0.0, 1.0));

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

  void _up() {
    final base = {'page': widget.pageNumber, 'color': widget.color.toARGB32()};
    if (widget.tool == Tool.ink && _stroke.isNotEmpty) {
      widget.onCreate({...base, 'type': 'ink', 'width': 0.003, 'points': flatten(simplify(_stroke))});
    } else if (widget.tool == Tool.highlight && _dragStart != null && _dragEnd != null) {
      final r = Rect.fromPoints(_dragStart!, _dragEnd!);
      if (r.width > 0.005 && r.height > 0.003) {
        widget.onCreate({
          ...base,
          'type': 'highlight',
          'rects': [
            [q(r.left), q(r.top), q(r.width), q(r.height)]
          ],
        });
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
      if (a.hit(p)) return a;
    }
    return null;
  }

  void _erase(Offset p) {
    final a = _hit(p);
    if (a != null) widget.onDelete(a);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
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
                left: a.pos.dx * size.width - 12,
                top: a.pos.dy * size.height - 12,
                child: GestureDetector(
                  onTap: () => widget.onNoteTap(a),
                  child: Tooltip(
                    message: a.text,
                    child: Icon(Icons.sticky_note_2, size: 24, color: a.color),
                  ),
                ),
              ),
          ]);
          if (widget.tool == Tool.pan) return layer;
          // Listener sees raw pointers (no gesture-arena fight with the viewer,
          // whose pan/zoom is disabled while a drawing tool is active).
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => _down(_norm(e.localPosition, size)),
            onPointerMove: (e) => _move(_norm(e.localPosition, size)),
            onPointerUp: (_) => _up(),
            onPointerCancel: (_) => _up(),
            child: layer,
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
            ..color = a.color.withValues(alpha: 0.35)
            ..blendMode = BlendMode.multiply;
          for (final r in a.rects) {
            canvas.drawRect(den(r), paint);
          }
        case 'ink':
          drawStroke(a.points, a.color, a.width);
      }
    }
    if (liveStroke.isNotEmpty) drawStroke(liveStroke, color, 0.003);
    if (liveRect != null) {
      canvas.drawRect(den(liveRect!), Paint()..color = color.withValues(alpha: 0.35));
    }
  }

  @override
  bool shouldRepaint(_AnnPainter old) => true;
}
