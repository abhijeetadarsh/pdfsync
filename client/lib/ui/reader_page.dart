import 'dart:async';

import 'package:flutter/services.dart';
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
  final _controller = PdfViewerController();

  // Immersive reading: a single tap with the hand tool hides the app bar,
  // toolbar and system bars; another tap brings them back. The bars float over
  // the page (they never resize the viewer), so toggling never re-zooms.
  bool _chrome = true;

  void _setChrome(bool visible) {
    if (_chrome == visible) return;
    setState(() => _chrome = visible);
    SystemChrome.setEnabledSystemUIMode(visible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
  }

  /// Current zoom in percent (1.0 = 1 PDF point per logical pixel), rounded so
  /// the chip only rebuilds when the number it shows changes.
  final _zoomPct = ValueNotifier<int>(100);
  final _page = ValueNotifier<int>(1);
  void _onControllerChanged() {
    final c = _controller;
    if (c.isReady) {
      _zoomPct.value = (c.currentZoom * 100).round();
      _page.value = c.pageNumber ?? _page.value;
    }
  }

  Future<void> _applyZoom(_ZoomPreset z) async {
    final c = _controller;
    if (!c.isReady) return;
    final page = c.pageNumber ?? 1;
    final Matrix4? m = switch (z.kind) {
      _ZoomKind.fitWidth => c.calcMatrixFitWidthForPage(pageNumber: page),
      _ZoomKind.fitPage => c.calcMatrixForFit(pageNumber: page),
      _ZoomKind.percent => null,
    };
    if (m != null) {
      await c.goTo(m);
    } else {
      await c.setZoom(c.centerPosition, (z.percent! / 100).clamp(c.minScale, c.maxScale));
    }
  }
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
      // Opening counts as reading: refresh the readstate so the library sorts
      // this document first on every device.
      widget.engine.store.put('readstate', _docId, {'page': _initialPage ?? 1}, docId: _docId);
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
    _controller.removeListener(_onControllerChanged);
    _zoomPct.dispose();
    _page.dispose();
    if (!_chrome) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
    final appBar = AppBar(
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
      );
    final body = _error != null
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
                  controller: _controller,
                  params: PdfViewerParams(
                    // The bars float over the page; let the first/last page be
                    // scrolled out from under them.
                    boundaryMargin: EdgeInsets.only(top: _topInset(context), bottom: _bottomInset(context)),
                    // Single tap with the hand tool toggles the bars. Double
                    // tap keeps pdfrx's zoom.
                    onGeneralTap: (context, controller, details) {
                      if (details.type != PdfViewerGeneralTapType.tap || _tool != Tool.pan) return false;
                      _setChrome(!_chrome);
                      return true;
                    },
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
                      controller.addListener(_onControllerChanged);
                      _onControllerChanged();
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
                ));

    const dur = Duration(milliseconds: 220);
    final ready = _bytes != null && _error == null;
    return Scaffold(
      // Nothing resizes the viewer: not the keyboard (the note dialog's
      // keyboard made pdfrx re-fit the page) and not the bars, which float.
      resizeToAvoidBottomInset: false,
      body: Stack(children: [
        Positioned.fill(child: ready ? body : SafeArea(child: body)),
        if (ready)
          // Draggable scrollbar thumb with the page number. It lives outside
          // the viewer so its track can stay between the floating bars.
          Positioned.fill(
            child: _PageThumb(
              controller: _controller,
              top: _chrome ? _topInset(context) + 8 : MediaQuery.paddingOf(context).top + 8,
              bottom: _chrome ? _bottomInset(context) + 8 : MediaQuery.paddingOf(context).bottom + 8,
            ),
          ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: !_chrome,
            child: AnimatedSlide(
              duration: dur,
              curve: Curves.easeOut,
              offset: _chrome ? Offset.zero : const Offset(0, -1),
              child: appBar,
            ),
          ),
        ),
        if (ready)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: !_chrome,
              child: AnimatedSlide(
                duration: dur,
                curve: Curves.easeOut,
                offset: _chrome ? Offset.zero : const Offset(0, 1),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(padding: const EdgeInsets.only(bottom: 8), child: _statusPill()),
                  Material(color: Theme.of(context).colorScheme.surfaceContainer, child: _toolbar()),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  double _topInset(BuildContext context) => MediaQuery.paddingOf(context).top + kToolbarHeight;
  double _bottomInset(BuildContext context) => MediaQuery.paddingOf(context).bottom + 56 + 48;

  /// "3 / 12 · 86%": tap the page part to jump to a page, the zoom part for
  /// zoom presets.
  Widget _statusPill() {
    final scheme = Theme.of(context).colorScheme;
    final total = _document?.pages.length ?? (widget.doc.data['pageCount'] as int? ?? 0);
    final style = TextStyle(color: scheme.onInverseSurface, fontSize: 13, fontWeight: FontWeight.w600);
    return Material(
      color: scheme.inverseSurface.withValues(alpha: 0.85),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: _goToPageDialog,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
            child: ValueListenableBuilder<int>(
              valueListenable: _page,
              builder: (_, p, __) => Text('$p / $total', style: style),
            ),
          ),
        ),
        Container(width: 1, height: 16, color: scheme.onInverseSurface.withValues(alpha: 0.3)),
        PopupMenuButton<_ZoomPreset>(
          tooltip: 'Zoom',
          onSelected: _applyZoom,
          itemBuilder: (_) => [for (final z in _ZoomPreset.all) PopupMenuItem(value: z, child: Text(z.label))],
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
            child: ValueListenableBuilder<int>(
              valueListenable: _zoomPct,
              builder: (_, z, __) => Text('$z%', style: style),
            ),
          ),
        ),
      ]),
    );
  }

  Future<void> _goToPageDialog() async {
    final total = _document?.pages.length ?? 0;
    if (total == 0) return;
    final ctl = TextEditingController();
    final n = await showDialog<int>(
      context: context,
      builder: (ctx) {
        void submit() => Navigator.pop(ctx, int.tryParse(ctl.text.trim()));
        return AlertDialog(
          title: const Text('Go to page'),
          content: TextField(
            controller: ctl,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(hintText: '1 – $total'),
            onSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: submit, child: const Text('Go')),
          ],
        );
      },
    );
    if (n == null) return;
    await _controller.goToPage(pageNumber: n.clamp(1, total));
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

enum _ZoomKind { fitWidth, fitPage, percent }

class _ZoomPreset {
  const _ZoomPreset(this.label, this.kind, [this.percent]);
  final String label;
  final _ZoomKind kind;
  final int? percent;

  static const all = [
    _ZoomPreset('Fit width', _ZoomKind.fitWidth),
    _ZoomPreset('Fit page', _ZoomKind.fitPage),
    _ZoomPreset('50%', _ZoomKind.percent, 50),
    _ZoomPreset('60%', _ZoomKind.percent, 60),
    _ZoomPreset('75%', _ZoomKind.percent, 75),
    _ZoomPreset('100%', _ZoomKind.percent, 100),
    _ZoomPreset('125%', _ZoomKind.percent, 125),
    _ZoomPreset('150%', _ZoomKind.percent, 150),
    _ZoomPreset('200%', _ZoomKind.percent, 200),
    _ZoomPreset('300%', _ZoomKind.percent, 300),
  ];
}

/// Scrollbar thumb on the right edge that shows the current page number and
/// can be dragged to scroll through the document.
class _PageThumb extends StatefulWidget {
  const _PageThumb({required this.controller, required this.top, required this.bottom});
  final PdfViewerController controller;
  final double top;
  final double bottom;

  @override
  State<_PageThumb> createState() => _PageThumbState();
}

class _PageThumbState extends State<_PageThumb> {
  static const _size = Size(46, 30);
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Scroll fraction 0..1 of the current view, and the range it maps to (in
  /// document coordinates). Null when the document fits on screen.
  ({double fraction, double minY, double range})? _metrics() {
    final c = widget.controller;
    if (!c.isReady) return null;
    final view = c.visibleRect;
    final margin = c.params.boundaryMargin;
    final hasMargin = margin != null && !margin.vertical.isInfinite;
    final docH = c.documentSize.height + (hasMargin ? margin.vertical : 0);
    if (docH <= view.height) return null;
    final minY = hasMargin ? -margin.top : 0.0;
    final range = docH - view.height;
    return (fraction: ((view.top - minY) / range).clamp(0.0, 1.0), minY: minY, range: range);
  }

  void _dragTo(double localY, double track) {
    final m = _metrics();
    if (m == null) return;
    final c = widget.controller;
    final f = ((localY - widget.top - _size.height / 2) / track).clamp(0.0, 1.0);
    final view = c.visibleRect;
    final target = Offset(view.center.dx, m.minY + f * m.range + view.height / 2);
    c.goTo(c.calcMatrixFor(target), duration: Duration.zero);
  }

  @override
  Widget build(BuildContext context) {
    final m = _metrics();
    if (m == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      final track = (box.maxHeight - widget.top - widget.bottom - _size.height).clamp(0.0, double.infinity);
      final y = widget.top + m.fraction * track;
      return Stack(children: [
        Positioned(
          right: 0,
          top: y,
          width: _size.width,
          height: _size.height,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) => setState(() => _dragging = true),
            onVerticalDragUpdate: (d) {
              final local = (context.findRenderObject() as RenderBox).globalToLocal(d.globalPosition);
              _dragTo(local.dy, track);
            },
            onVerticalDragEnd: (_) => setState(() => _dragging = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                color: (_dragging ? scheme.primary : scheme.inverseSurface).withValues(alpha: 0.85),
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(15)),
              ),
              alignment: Alignment.center,
              child: Text('${widget.controller.pageNumber ?? ''}',
                  style: TextStyle(
                    color: _dragging ? scheme.onPrimary : scheme.onInverseSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  )),
            ),
          ),
        ),
      ]);
    });
  }
}
