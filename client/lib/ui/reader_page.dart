import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../annotations.dart';
import '../sync/record.dart';
import '../sync/sync_engine.dart';
import 'annotation_layer.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.engine, required this.doc});
  final SyncEngine engine;
  final SyncRecord doc;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  static const palette = [
    Color(0xFFFFEB3B), Color(0xFF4CAF50), Color(0xFF2196F3), Color(0xFFE91E63), Color(0xFF212121),
  ];

  Uint8List? _bytes;
  double _progress = 0;
  Object? _error;
  Tool _tool = Tool.pan;
  Color _color = palette.first;
  final _anns = ValueNotifier<Map<int, List<Ann>>>({});
  StreamSubscription? _sub;
  Timer? _pageSave;
  int? _initialPage;

  String get _docId => widget.doc.id;

  @override
  void initState() {
    super.initState();
    // Live query: annotations made on another device appear here within ~1 s
    // (server poke -> delta sync -> local DB -> this stream).
    _sub = widget.engine.store.watchAnnotations(_docId).listen((list) {
      final m = <int, List<Ann>>{};
      for (final r in list) {
        final a = Ann(r);
        (m[a.page] ??= []).add(a);
      }
      _anns.value = m;
    });
    _load();
  }

  Future<void> _load() async {
    try {
      final rs = await widget.engine.store.get('readstate', _docId);
      _initialPage = rs?.data['page'] as int?;
      final bytes = await widget.engine.loadPdf(widget.doc.data['sha256'] as String,
          onProgress: (p) => mounted ? setState(() => _progress = p) : null);
      if (mounted) setState(() => _bytes = bytes);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pageSave?.cancel();
    _anns.dispose();
    super.dispose();
  }

  void _onPageChanged(int? page) {
    if (page == null) return;
    _pageSave?.cancel();
    // Reading position syncs too ("continue where you left off" on any device),
    // but debounced so scrolling doesn't spam records.
    _pageSave = Timer(const Duration(seconds: 2), () {
      widget.engine.store.put('readstate', _docId, {'page': page}, docId: _docId);
    });
  }

  Future<void> _noteDialog({Ann? existing, Offset? pos, required int page}) async {
    final ctl = TextEditingController(text: existing?.text ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'New note' : 'Note'),
        content: TextField(controller: ctl, autofocus: true, maxLines: 6, minLines: 3),
        actions: [
          if (existing != null)
            TextButton(onPressed: () => Navigator.pop(ctx, '\u0000delete'), child: const Text('Delete')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    if (result == null) return;
    final store = widget.engine.store;
    if (result == '\u0000delete') {
      await store.delete('annotation', existing!.id, docId: _docId);
    } else if (existing != null) {
      await store.put('annotation', existing.id, {...existing.d, 'text': result}, docId: _docId);
    } else if (result.trim().isNotEmpty) {
      await store.put('annotation', newId(), {
        'page': page,
        'type': 'note',
        'color': _color.toARGB32(),
        'pos': [q(pos!.dx), q(pos.dy)],
        'text': result,
      }, docId: _docId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final drawing = _tool != Tool.pan;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.doc.data['title'] as String? ?? 'Document', overflow: TextOverflow.ellipsis),
        actions: [
          SyncIndicator(engine: widget.engine),
          const SizedBox(width: 8),
        ],
      ),
      body: _error != null
          ? Center(child: Text('Could not open PDF:\n$_error', textAlign: TextAlign.center))
          : _bytes == null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(width: 200, child: LinearProgressIndicator(value: _progress > 0 ? _progress : null)),
                  const SizedBox(height: 12),
                  const Text('Downloading…'),
                ]))
              : PdfViewer.data(
                  _bytes!,
                  sourceName: widget.doc.data['sha256'] as String,
                  params: PdfViewerParams(
                    panEnabled: !drawing,
                    scaleEnabled: !drawing,
                    onPageChanged: _onPageChanged,
                    onViewerReady: (document, controller) {
                      final p = _initialPage;
                      if (p != null && p > 1 && p <= document.pages.length) {
                        controller.goToPage(pageNumber: p);
                      }
                    },
                    pageOverlaysBuilder: (context, pageRect, page) => [
                      AnnotationLayer(
                        key: ValueKey('ann-${page.pageNumber}'),
                        pageNumber: page.pageNumber,
                        annotations: _anns,
                        tool: _tool,
                        color: _color,
                        onCreate: (data) =>
                            widget.engine.store.put('annotation', newId(), data, docId: _docId),
                        onDelete: (a) => widget.engine.store.delete('annotation', a.id, docId: _docId),
                        onNoteTap: (a) => _noteDialog(existing: a, page: a.page),
                        onNewNote: (pos) => _noteDialog(pos: pos, page: page.pageNumber),
                      ),
                    ],
                  ),
                ),
      bottomNavigationBar: _bytes == null ? null : _toolbar(),
    );
  }

  Widget _toolbar() {
    Widget toolBtn(Tool t, IconData icon, String tip) => IconButton(
          tooltip: tip,
          isSelected: _tool == t,
          icon: Icon(icon),
          style: IconButton.styleFrom(
            backgroundColor: _tool == t ? Theme.of(context).colorScheme.primaryContainer : null,
          ),
          onPressed: () => setState(() => _tool = t),
        );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [
          toolBtn(Tool.pan, Icons.pan_tool_outlined, 'Navigate'),
          toolBtn(Tool.highlight, Icons.highlight, 'Highlight (drag)'),
          toolBtn(Tool.ink, Icons.draw_outlined, 'Pen'),
          toolBtn(Tool.note, Icons.sticky_note_2_outlined, 'Note (tap)'),
          toolBtn(Tool.eraser, Icons.auto_fix_normal_outlined, 'Eraser'),
          const Spacer(),
          for (final c in palette)
            GestureDetector(
              onTap: () => setState(() => _color = c),
              child: Container(
                width: 26,
                height: 26,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    width: _color == c ? 3 : 1,
                    color: _color == c ? Theme.of(context).colorScheme.primary : Colors.black26,
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

class SyncIndicator extends StatelessWidget {
  const SyncIndicator({super.key, required this.engine});
  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final (icon, tip) = switch (engine.status) {
          SyncStatus.idle => (Icons.cloud_done_outlined, 'Synced'),
          SyncStatus.syncing => (Icons.cloud_sync_outlined, 'Syncing…'),
          SyncStatus.offline => (Icons.cloud_off_outlined, 'Offline – changes are saved and will sync'),
          SyncStatus.error => (Icons.error_outline, engine.lastError ?? 'Sync error'),
        };
        return IconButton(icon: Icon(icon), tooltip: tip, onPressed: engine.syncNow);
      },
    );
  }
}
