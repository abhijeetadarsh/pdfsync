import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../annotations.dart';

/// Turns a text selection into highlight annotation data, one record per page.
///
/// Each selected character's box is converted to normalized page coordinates
/// (0..1, origin top-left – the same space every annotation uses), then
/// characters on the same line are merged into one rectangle, so a 3-line
/// selection becomes 3 small rects instead of hundreds.
List<Map<String, dynamic>> highlightsFromSelection(
  List<PdfPageTextRange> ranges,
  List<PdfPage> pages, {
  required int color,
}) {
  final byPage = <int, List<Rect>>{};
  final textByPage = <int, StringBuffer>{};
  for (final range in ranges) {
    final pageNumber = range.pageNumber;
    if (pageNumber < 1 || pageNumber > pages.length) continue;
    final page = pages[pageNumber - 1];
    final chars = range.pageText.charRects;
    final lines = byPage.putIfAbsent(pageNumber, () => []);
    textByPage.putIfAbsent(pageNumber, StringBuffer.new).write(range.text);
    Rect? line;
    for (var i = range.start; i < range.end && i < chars.length; i++) {
      // toRect() scales x and y by the same factor (height-based), so convert
      // to page points first and normalize each axis by its own extent.
      final pt = chars[i].toRect(page: page);
      final r = Rect.fromLTRB(
          pt.left / page.width, pt.top / page.height, pt.right / page.width, pt.bottom / page.height);
      if (r.width <= 0 || r.height <= 0) continue; // spaces, line breaks
      if (line != null && _sameLine(line, r)) {
        line = line.expandToInclude(r);
      } else {
        if (line != null) lines.add(line);
        line = r;
      }
    }
    if (line != null) lines.add(line);
  }
  return [
    for (final e in byPage.entries)
      if (e.value.isNotEmpty)
        {
          'page': e.key,
          'type': 'highlight',
          'color': color,
          'rects': [
            for (final r in e.value) [q(r.left), q(r.top), q(r.width), q(r.height)]
          ],
          // Handy for search/export later; capped to keep records small.
          'text': _cap(textByPage[e.key].toString().trim(), 1000),
        }
  ];
}

bool _sameLine(Rect line, Rect r) {
  final overlap = (line.bottom < r.bottom ? line.bottom : r.bottom) - (line.top > r.top ? line.top : r.top);
  final minH = line.height < r.height ? line.height : r.height;
  // Same line if the boxes overlap vertically by at least half a character
  // height and the new char doesn't jump back to the left (a wrapped line).
  return overlap > minH * 0.5 && r.left >= line.left - minH;
}

String _cap(String s, int n) => s.length <= n ? s : s.substring(0, n);
