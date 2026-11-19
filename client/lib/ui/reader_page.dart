import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../annotations.dart';
import '../sync/record.dart';
import '../sync/sync_engine.dart';
import '../undo.dart';
import 'annotation_layer.dart';
import 'reading_mode.dart';
import 'text_highlight.dart';

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
  // Fingers currently on the viewer. While a drawing tool is active the viewer
  // only pans/zooms when 2+ fingers are down; one finger draws.
  final Set<int> _touches = {};
  bool get _multiTouch => _touches.length > 1;
  PdfDocument? _document;
  ReadingMode _mode = ReadingMode.original;

  // Reading mode is a per-device preference (a phone at night and a desktop
  // by day want different things), kept in the local store's meta table.
  Future<void> _setMode(ReadingMode m) async {
    setState(() => _mode = m);
    await widget.engine.store.setMeta('readingMode', m.name);
  }
  late final AnnotationHistory _history = AnnotationHistory((id, data) => data == null
      ? widget.engine.store.delete('annotation', id, docId: _docId)
      : widget.engine.store.put('annotation', id, data, docId: _docId));

  // All annotation edits go through the undo history.
  Future<void> _create(Map<String, dynamic> data) => _history.run(AnnEdit(newId(), null, data));
  Future<void> _remove(Ann a) => _history.run(AnnEdit(a.id, Map.of(a.d), null));
  Future<void> _update(Ann a, Map<String, dynamic> data) => _history.run(AnnEdit(a.id, Map.of(a.d), data));

  /// Context-menu action for a text selection: highlight it in the current colour.
  Future<void> _highlightSelection(PdfTextSelectionDelegate sel) async {
    final doc = _document;
    if (doc == null || !sel.hasSelectedText) return;
    final ranges = await sel.getSelectedTextRanges();
    for (final data in highlightsFromSelection(ranges, doc.pages, color: _color.toARGB32())) {
      await _create(data);
    }
    await sel.clearTextSelection();
  }

  void _touch(int pointer, bool down) {
    final before = _multiTouch;
    down ? _touches.add(pointer) : _touches.remove(pointer);
    if (before != _multiTouch && _tool != Tool.pan) setState(() {});
  }

  /// Keep the same part of the document in view across rotation / window
  /// resizes, scaling the zoom with the view width, so a page that fit the
  /// width in portrait still fits it in landscape (and vice versa).
  void _onViewSizeChanged(Size viewSize, Size? oldViewSize, PdfViewerController controller) {
    if (oldViewSize == null || oldViewSize.width <= 0) return;
    if ((viewSize.width - oldViewSize.width).abs() < 1) return;
    final center = controller.value.calcPosition(oldViewSize);
    final zoom = (controller.currentZoom * viewSize.width / oldViewSize.width)
        .clamp(controller.minScale, controller.maxScale);
    // Not synchronously: this can be called during build.
    Future.delayed(const Duration(milliseconds: 50), () {
      if (!mounted || !controller.isReady) return;
      controller.goTo(controller.makeMatrixInSafeRange(controller.calcMatrixFor(center, zoom: zoom)),
          duration: Duration.zero);
    });
  }

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
      _mode = ReadingMode.byName(await widget.engine.store.getMeta<String>('readingMode'));
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
    _history.dispose();
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
    if (result == '\u0000delete') {
      await _remove(existing!);
    } else if (existing != null) {
      if (result != existing.text) await _update(existing, {...existing.d, 'text': result});
    } else if (result.trim().isNotEmpty) {
      await _create({
        'page': page,
        'type': 'note',
        'color': _color.toARGB32(),
        'pos': [q(pos!.dx), q(pos.dy)],
        'text': result,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final drawing = _tool != Tool.pan;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.doc.data['title'] as String? ?? 'Document', overflow: TextOverflow.ellipsis),
        actions: [
          // Undo/redo live in the app bar: the bottom toolbar is already full
          // on a phone in portrait.
          ListenableBuilder(
            listenable: _history,
            builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: 'Undo',
                icon: const Icon(Icons.undo),
                onPressed: _history.canUndo ? _history.undo : null,
              ),
              IconButton(
                tooltip: 'Redo',
                icon: const Icon(Icons.redo),
                onPressed: _history.canRedo ? _history.redo : null,
              ),
            ]),
          ),
          PopupMenuButton<ReadingMode>(
            tooltip: 'Reading mode',
            icon: const Icon(Icons.contrast),
            initialValue: _mode,
            onSelected: _setMode,
            itemBuilder: (_) => [
              for (final m in ReadingMode.values)
                PopupMenuItem(
                  value: m,
                  child: Row(children: [
                    Container(
                      width: 36,
                      height: 26,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: m.paperColor,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Theme.of(context).colorScheme.outline),
                      ),
                      child: Text('Aa', style: TextStyle(color: m.inkColor, fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 12),
                    Text(m.label),
                    if (m == _mode) ...[const Spacer(), const Icon(Icons.check, size: 18)],
                  ]),
                ),
            ],
          ),
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
              : Listener(
                  onPointerDown: (e) => _touch(e.pointer, true),
                  onPointerUp: (e) => _touch(e.pointer, false),
                  onPointerCancel: (e) => _touch(e.pointer, false),
                  child: PdfViewer.data(
                  _bytes!,
                  sourceName: widget.doc.data['sha256'] as String,
                  params: PdfViewerParams(
                    panEnabled: !drawing || _multiTouch,
                    scaleEnabled: !drawing || _multiTouch,
                    onPageChanged: _onPageChanged,
                    onViewSizeChanged: _onViewSizeChanged,
                    pageImageColorFilter: _mode.colorFilter,
                    // The gutter around pages follows the app theme instead of
                    // pdfrx's default mid-grey.
                    backgroundColor: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF26262B)
                        : const Color(0xFFDADADF),
                    // Long-press (touch) or drag (mouse) selects text with the
                    // hand tool; the menu gets a "Highlight" action next to
                    // Copy. Off while drawing so a pen stroke never selects.
                    textSelectionParams: PdfTextSelectionParams(enabled: !drawing),
                    customizeContextMenuItems: (params, items) {
                      if (!params.textSelectionDelegate.hasSelectedText) return;
                      items.insert(
                        0,
                        ContextMenuButtonItem(
                          label: 'Highlight',
                          onPressed: () {
                            params.dismissContextMenu();
                            _highlightSelection(params.textSelectionDelegate);
                          },
                        ),
                      );
                    },
                    onViewerReady: (document, controller) {
                      _document = document;
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
                        onCreate: _create,
                        onDelete: _remove,
                        onNoteTap: (a) => _noteDialog(existing: a, page: a.page),
                        onNewNote: (pos) => _noteDialog(pos: pos, page: page.pageNumber),
                      ),
                    ],
                  ),
                )),
      bottomNavigationBar: _bytes == null ? null : _toolbar(),
    );
  }

  Widget _swatch(Color c, {double size = 28}) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _color == c;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        // A visible outline even for the dark swatch on a dark toolbar.
        border: Border.all(width: selected ? 3 : 1.5, color: selected ? scheme.primary : scheme.outline),
      ),
    );
  }

  Widget _toolbar() {
    final scheme = Theme.of(context).colorScheme;
    Widget toolBtn(Tool t, IconData icon, String tip) => IconButton(
          tooltip: tip,
          isSelected: _tool == t,
          icon: Icon(icon),
          style: IconButton.styleFrom(backgroundColor: _tool == t ? scheme.primaryContainer : null),
          onPressed: () => setState(() => _tool = t),
        );
    final tools = [
      toolBtn(Tool.pan, Icons.pan_tool_outlined, 'Navigate'),
      toolBtn(Tool.highlight, Icons.highlight, 'Highlight (drag)'),
      toolBtn(Tool.ink, Icons.draw_outlined, 'Pen'),
      toolBtn(Tool.note, Icons.sticky_note_2_outlined, 'Note (tap)'),
      toolBtn(Tool.eraser, Icons.auto_fix_normal_outlined, 'Eraser'),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: LayoutBuilder(builder: (context, c) {
          // 5 tools (48 each) + 5 swatches (34 each) need ~420 dp. On narrower
          // screens (phones in portrait) the colours collapse into one button.
          final wide = c.maxWidth >= 440;
          return Row(children: [
            ...tools,
            const Spacer(),
            if (wide)
              for (final col in palette)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: InkResponse(
                    onTap: () => setState(() => _color = col),
                    radius: 20,
                    child: _swatch(col),
                  ),
                )
            else
              PopupMenuButton<Color>(
                tooltip: 'Colour',
                onSelected: (col) => setState(() => _color = col),
                itemBuilder: (_) => [
                  for (final col in palette) PopupMenuItem(value: col, child: Center(child: _swatch(col, size: 32))),
                ],
                child: Padding(padding: const EdgeInsets.all(8), child: _swatch(_color)),
              ),
          ]);
        }),
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
