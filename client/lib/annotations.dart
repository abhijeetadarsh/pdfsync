import 'dart:math';
import 'dart:ui';

import 'sync/record.dart';

/// Annotation geometry is stored in *normalized page coordinates*
/// (0..1, origin top-left), so it lands in the same spot on a phone, a 4K
/// monitor, or a zoomed-in tablet, independent of render resolution.
///
/// data schemas:
///   highlight: {page, type:'highlight', color, rects:[[x,y,w,h], ...]}
///   ink:       {page, type:'ink', color, width, points:[x0,y0,x1,y1,...]}
///   note:      {page, type:'note', color, pos:[x,y], text}
enum Tool { pan, highlight, ink, note, eraser }

class Ann {
  Ann(this.rec);
  final SyncRecord rec;
  Map<String, dynamic> get d => rec.data;
  String get id => rec.id;
  int get page => d['page'] as int;
  String get type => d['type'] as String;
  Color get color => Color(d['color'] as int);

  List<Rect> get rects => ((d['rects'] as List?) ?? const [])
      .map((r) => (r as List).map((v) => (v as num).toDouble()).toList())
      .map((r) => Rect.fromLTWH(r[0], r[1], r[2], r[3]))
      .toList();

  List<Offset> get points {
    final p = ((d['points'] as List?) ?? const []).map((v) => (v as num).toDouble()).toList();
    return [for (var i = 0; i + 1 < p.length; i += 2) Offset(p[i], p[i + 1])];
  }

  double get width => (d['width'] as num?)?.toDouble() ?? 0.003;
  Offset get pos {
    final p = (d['pos'] as List).map((v) => (v as num).toDouble()).toList();
    return Offset(p[0], p[1]);
  }

  String get text => (d['text'] as String?) ?? '';

  /// Hit test in normalized coordinates (used by the eraser and note taps).
  bool hit(Offset p, {double tol = 0.015}) {
    switch (type) {
      case 'highlight':
        return rects.any((r) => r.inflate(tol).contains(p));
      case 'ink':
        final pts = points;
        for (var i = 0; i + 1 < pts.length; i++) {
          if (_distToSegment(p, pts[i], pts[i + 1]) < tol + width) return true;
        }
        return pts.length == 1 && (pts.first - p).distance < tol;
      case 'note':
        return (pos - p).distance < tol * 2.5;
    }
    return false;
  }
}

double _distToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// Ramer–Douglas–Peucker: a 300-point finger stroke typically compresses to
/// 20–40 points with no visible change – that's ~10x less data to store and sync.
List<Offset> simplify(List<Offset> pts, {double epsilon = 0.0008}) {
  if (pts.length < 3) return pts;
  var maxD = 0.0;
  var idx = 0;
  for (var i = 1; i < pts.length - 1; i++) {
    final d = _distToSegment(pts[i], pts.first, pts.last);
    if (d > maxD) {
      maxD = d;
      idx = i;
    }
  }
  if (maxD <= epsilon) return [pts.first, pts.last];
  final left = simplify(pts.sublist(0, idx + 1), epsilon: epsilon);
  final right = simplify(pts.sublist(idx), epsilon: epsilon);
  return [...left.sublist(0, left.length - 1), ...right];
}

/// 4 decimals ≈ 0.06 px on an A4 page at 150 dpi – plenty, and keeps JSON small.
double q(double v) => (v * 10000).roundToDouble() / 10000;

List<double> flatten(List<Offset> pts) => [for (final p in pts) ...[q(p.dx), q(p.dy)]];

String newId() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
