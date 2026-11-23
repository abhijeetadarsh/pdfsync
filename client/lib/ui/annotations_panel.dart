import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../annotations.dart';

/// Shared live annotation browser: a sheet on phone, a side panel on tablet.
class AnnotationsPanel extends StatefulWidget {
  const AnnotationsPanel(
      {super.key,
      required this.annotations,
      required this.documentTitle,
      required this.onGoTo,
      required this.onEdit,
      required this.onDelete,
      required this.onClose});
  final ValueListenable<Map<int, List<Ann>>> annotations;
  final String documentTitle;
  final ValueChanged<Ann> onGoTo;
  final ValueChanged<Ann> onEdit;
  final ValueChanged<Ann> onDelete;
  final VoidCallback onClose;
  @override
  State<AnnotationsPanel> createState() => _AnnotationsPanelState();
}

class _AnnotationsPanelState extends State<AnnotationsPanel> {
  String _filter = 'all';
  String _query = '';

  Future<void> _export(List<Ann> anns) async {
    final text = StringBuffer('# ${widget.documentTitle}\n');
    for (final ann in anns) {
      text.writeln('\n## Page ${ann.page} · ${_label(ann.type)}\n');
      text.writeln(ann.text.isNotEmpty
          ? ann.text
          : ann.type == 'ink'
              ? '[Ink annotation]'
              : '[Area highlight]');
    }
    await Clipboard.setData(ClipboardData(text: text.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Annotations copied as Markdown.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    return Material(
        color: scheme.surfaceContainer,
        child: SafeArea(
            top: false,
            child: ValueListenableBuilder<Map<int, List<Ann>>>(
              valueListenable: widget.annotations,
              builder: (context, pages, _) {
                final all = pages.values.expand((a) => a).toList()
                  ..sort((a, b) {
                    final page = a.page.compareTo(b.page);
                    return page == 0 ? a.id.compareTo(b.id) : page;
                  });
                final visible = all
                    .where((a) =>
                        (_filter == 'all' || a.type == _filter) &&
                        (a.text.toLowerCase().contains(_query) ||
                            '${a.page}'.contains(_query)))
                    .toList();
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
                          child: Row(children: [
                            Expanded(
                                child: Text('Annotations · ${all.length}',
                                    style: theme.textTheme.titleMedium)),
                            IconButton(
                                tooltip: 'Close annotations',
                                onPressed: widget.onClose,
                                icon: const Icon(Icons.close)),
                          ])),
                      Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          child: TextField(
                            onChanged: (s) =>
                                setState(() => _query = s.toLowerCase().trim()),
                            decoration: const InputDecoration(
                                hintText: 'Search text or page',
                                prefixIcon: Icon(Icons.search, size: 18)),
                          )),
                      SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(children: [
                            for (final type in [
                              'all',
                              'highlight',
                              'note',
                              'ink'
                            ])
                              TextButton(
                                onPressed: () => setState(() => _filter = type),
                                style: TextButton.styleFrom(
                                    foregroundColor: _filter == type
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                    backgroundColor: _filter == type
                                        ? scheme.surfaceContainerHighest
                                        : null),
                                child: Text(
                                    switch (type) {
                                      'all' => 'All',
                                      'highlight' => 'Highlights',
                                      'note' => 'Notes',
                                      _ => 'Ink'
                                    },
                                    style: const TextStyle(fontSize: 11)),
                              ),
                          ])),
                      const SizedBox(height: 8),
                      const Divider(),
                      Expanded(
                          child: visible.isEmpty
                              ? Center(
                                  child: Padding(
                                      padding: const EdgeInsets.all(24),
                                      child: Text(
                                          all.isEmpty
                                              ? 'Your highlights, notes and drawings will appear here.'
                                              : 'No matching annotations.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                              color: scheme.onSurfaceVariant))))
                              : ListView.separated(
                                  itemCount: visible.length,
                                  separatorBuilder: (_, __) => const Divider(),
                                  itemBuilder: (context, i) {
                                    final a = visible[i];
                                    return InkWell(
                                        onTap: () => widget.onGoTo(a),
                                        child: Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                                16, 14, 8, 10),
                                            child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                children: [
                                                  Row(children: [
                                                    Container(
                                                        width: 8,
                                                        height: 8,
                                                        color: a.color),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                        child: Text(
                                                            _label(a.type),
                                                            style: theme
                                                                .textTheme
                                                                .bodySmall
                                                                ?.copyWith(
                                                                    color: scheme
                                                                        .onSurfaceVariant))),
                                                    Text('p.${a.page}',
                                                        style: theme.textTheme
                                                            .bodySmall)
                                                  ]),
                                                  const SizedBox(height: 8),
                                                  if (a.type == 'ink')
                                                    SizedBox(
                                                        height: 56,
                                                        child: CustomPaint(
                                                            painter:
                                                                _InkPreview(a)))
                                                  else
                                                    Text(
                                                        a.text.isEmpty
                                                            ? 'Area highlight'
                                                            : a.text,
                                                        maxLines: 5,
                                                        overflow: TextOverflow
                                                            .ellipsis),
                                                  Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment.end,
                                                      children: [
                                                        if (a.type == 'note')
                                                          IconButton(
                                                              tooltip:
                                                                  'Edit note',
                                                              onPressed: () =>
                                                                  widget.onEdit(
                                                                      a),
                                                              icon: const Icon(
                                                                  Icons
                                                                      .edit_outlined,
                                                                  size: 18)),
                                                        IconButton(
                                                            tooltip:
                                                                'Delete annotation',
                                                            onPressed: () =>
                                                                widget.onDelete(
                                                                    a),
                                                            icon: const Icon(
                                                                Icons
                                                                    .delete_outline,
                                                                size: 18)),
                                                      ]),
                                                ])));
                                  },
                                )),
                      const Divider(),
                      Padding(
                          padding: const EdgeInsets.all(12),
                          child: OutlinedButton.icon(
                              onPressed:
                                  all.isEmpty ? null : () => _export(all),
                              icon: const Icon(Icons.copy_outlined, size: 18),
                              label: const Text('Copy as Markdown'))),
                    ]);
              },
            )));
  }
}

String _label(String type) => switch (type) {
      'highlight' => 'Highlight',
      'note' => 'Note',
      'ink' => 'Ink',
      _ => type
    };

class _InkPreview extends CustomPainter {
  _InkPreview(this.annotation);
  final Ann annotation;
  @override
  void paint(Canvas canvas, Size size) {
    final points = annotation.points;
    if (points.isEmpty) return;
    var bounds = points.first & Size.zero;
    for (final p in points) {
      bounds = bounds.expandToInclude(p & Size.zero);
    }
    final scale = ((size.width - 16) / bounds.width.clamp(.001, 1))
        .clamp(0.0, (size.height - 16) / bounds.height.clamp(.001, 1));
    Offset map(Offset p) => Offset(
        8 + (p.dx - bounds.left) * scale, 8 + (p.dy - bounds.top) * scale);
    final paint = Paint()
      ..color = annotation.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    if (points.length == 1) {
      canvas.drawCircle(map(points.first), 2, paint);
      return;
    }
    final path = Path()..moveTo(map(points.first).dx, map(points.first).dy);
    for (final p in points.skip(1)) {
      final point = map(p);
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_InkPreview oldDelegate) =>
      oldDelegate.annotation != annotation;
}
