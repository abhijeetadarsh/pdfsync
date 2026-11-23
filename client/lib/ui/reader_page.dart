import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../annotations.dart';
import '../sync/record.dart';
import '../sync/sync_engine.dart';
import '../undo.dart';
import 'annotation_layer.dart';
import 'annotations_panel.dart';
import 'app_theme.dart';
import 'input_policy.dart';
import 'reading_mode.dart';
import 'responsive_pdf_sizing.dart';
import 'scroll_feel.dart';
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
    AppTheme.yellow,
    AppTheme.green,
    AppTheme.blue,
    AppTheme.pink,
    AppTheme.lavender,
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
  // Which pointers draw and which scroll/zoom (mouse, stylus, finger rules –
  // see InputPolicy). While a drawing tool is active the viewer only pans when
  // a navigating pointer is down and nothing is drawing.
  final _input = InputPolicy();
  PdfDocument? _document;
  final _controller = PdfViewerController();
  bool _positioned = false; // initial page placed (see onViewerReady)

  // Immersive reading: a single tap with the hand tool hides the app bar,
  // toolbar and system bars; another tap brings them back. The bars float over
  // the page (they never resize the viewer), so toggling never re-zooms.
  bool _chrome = true;
  bool _annotationsVisible = true;

  void _setChrome(bool visible) {
    // Desktop: the bars stay put – clicking around with a mouse shouldn't hide them.
    if (kDesktop || _chrome == visible) return;
    setState(() => _chrome = visible);
    SystemChrome.setEnabledSystemUIMode(
        visible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
    // The viewer itself never resizes (a resize makes pdfrx re-clamp and
    // re-zoom with its own rules). Instead, the scroll limits in _normalize
    // keep the page clear of the bars at the document's edges, in both states,
    // so toggling the bars never moves the page.
  }

  /// Scroll limits (replaces pdfrx's default clamping). Page 1's top stops at
  /// the top bar's bottom edge and the last page's bottom stops at the
  /// toolbar's top edge – no overscroll, nothing tucked under a bar at the
  /// document's edges, and identical whether the bars are shown or hidden.
  /// Documents narrower/shorter than the view stay centred.
  Matrix4 _normalize(
      Matrix4 m, Size view, PdfPageLayout layout, PdfViewerController? c) {
    final z = (c != null && c.isReady)
        ? m.zoom.clamp(c.minScale, c.maxScale)
        : m.zoom;
    final docW = layout.documentSize.width * z,
        docH = layout.documentSize.height * z;
    var tx = m.storage[12] * (z / m.zoom), ty = m.storage[13] * (z / m.zoom);
    final top = _barTop ?? 0, bottom = _barBottom ?? 0;

    tx = docW <= view.width
        ? (view.width - docW) / 2
        : tx.clamp(view.width - docW, 0.0);
    final usable = view.height - top - bottom;
    ty = docH <= usable
        ? top + (usable - docH) / 2
        : ty.clamp(view.height - docH - bottom, top);

    return Matrix4.identity()
      ..setEntry(0, 0, z)
      ..setEntry(1, 1, z)
      ..setEntry(0, 3, tx)
      ..setEntry(1, 3, ty);
  }

  /// Go to the top of a page, just below the top bar.
  Future<void> _goToPage(int pageNumber) async {
    final c = _controller;
    if (!c.isReady) return;
    // Computed directly: page top (document units) × zoom, offset by the bar.
    final z = c.currentZoom;
    // Include the gap pdfrx keeps around pages, so page 1 lands exactly on
    // the scroll limit (nothing left to pull down).
    final pageTop = c.layout.pageLayouts[pageNumber - 1].top - c.params.margin;
    final m = Matrix4.identity()
      ..setEntry(0, 0, z)
      ..setEntry(1, 1, z)
      ..setEntry(0, 3, c.value.storage[12])
      ..setEntry(1, 3, -pageTop * z + (_barTop ?? 0));
    await c.goTo(c.makeMatrixInSafeRange(m), duration: Duration.zero);
    // pdfrx updates its page number after our listener ran; refresh the pill
    // once it has, or it keeps showing the old page until the next scroll.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onControllerChanged();
    });
  }

  // Heights of the top and bottom bars, measured once while they are shown.
  // They must not follow MediaQuery afterwards: hiding the status bar changes
  // the padding, which would resize the viewer and make the page jump.
  double? _barTop;
  double? _barBottom;

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
      await c.setZoom(
          c.centerPosition, (z.percent! / 100).clamp(c.minScale, c.maxScale));
    }
  }

  ReadingMode _mode = ReadingMode.original;

  // Reading mode is a per-device preference (a phone at night and a desktop
  // by day want different things), kept in the local store's meta table.
  Future<void> _setMode(ReadingMode m) async {
    setState(() => _mode = m);
    await widget.engine.store.setMeta('readingMode', m.name);
  }

  late final AnnotationHistory _history = AnnotationHistory((id, data) =>
      data == null
          ? widget.engine.store.delete('annotation', id, docId: _docId)
          : widget.engine.store.put('annotation', id, data, docId: _docId));

  // All annotation edits go through the undo history.
  Future<void> _create(Map<String, dynamic> data) =>
      _history.run(AnnEdit(newId(), null, data));
  Future<void> _remove(Ann a) => _history.run(AnnEdit(a.id, Map.of(a.d), null));
  Future<void> _update(Ann a, Map<String, dynamic> data) =>
      _history.run(AnnEdit(a.id, Map.of(a.d), data));

  /// Context-menu action for a text selection: highlight it in the current colour.
  Future<void> _highlightSelection(PdfTextSelectionDelegate sel) async {
    final doc = _document;
    if (doc == null || !sel.hasSelectedText) return;
    final ranges = await sel.getSelectedTextRanges();
    for (final data in highlightsFromSelection(ranges, doc.pages,
        color: _color.toARGB32())) {
      await _create(data);
    }
    await sel.clearTextSelection();
  }

  // What the viewer may do right now while a drawing tool is selected. Only a
  // change of these rebuilds the reader: every rebuild hands pdfrx new params,
  // which makes it re-lay out every page of the document.
  bool _navPan = false;
  bool _navScale = true;

  void _onInputChanged() {
    final pan = _input.hasNavigatePointer && !_input.hasDrawPointer;
    final scale = !_input.hasDrawPointer;
    if (pan == _navPan && scale == _navScale) return;
    _navPan = pan;
    _navScale = scale;
    if (_tool != Tool.pan && mounted) setState(() {});
  }

  /// Every pointer in the app, whatever widget it lands on. A Listener
  /// wrapped around the PdfViewer received no events at all (seen on Android
  /// and Linux with pdfrx 2.12; cause inside pdfrx not pinned down), so the
  /// bookkeeping can't rely on one: a missed "up" left a stylus registered as
  /// down and every later finger was ignored as a palm. Global routes run
  /// after the widgets' own handlers.
  void _onGlobalPointer(PointerEvent e) {
    if (e is PointerDownEvent) {
      _input.down(e); // pointers that didn't land on a page (gutter, ...)
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      _input.up(e.pointer);
    }
  }

  void _setTool(Tool t) => setState(() => _tool = t);

  Future<void> _fitWidth() => _applyZoom(_ZoomPreset.all.first);

  /// Right-click menu on an annotation: recolour, edit (notes), delete.
  Future<void> _annotationMenu(Ann a, Offset global) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<Object>(
      context: context,
      position:
          RelativeRect.fromRect(global & Size.zero, Offset.zero & overlay.size),
      items: [
        PopupMenuItem<Object>(
          enabled: false,
          child: Builder(
            builder: (ctx) => Row(mainAxisSize: MainAxisSize.min, children: [
              for (final col in palette)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: InkResponse(
                    onTap: () => Navigator.pop(ctx, col),
                    radius: 18,
                    child: _swatch(col,
                        size: 24,
                        selected: a.color.toARGB32() == col.toARGB32()),
                  ),
                ),
            ]),
          ),
        ),
        if (a.type == 'note')
          const PopupMenuItem(value: 'edit', child: Text('Edit note…')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'edit':
        await _noteDialog(existing: a, page: a.page);
      case 'delete':
        await _remove(a);
      case Color col when col.toARGB32() != a.color.toARGB32():
        await _update(a, {...a.d, 'color': col.toARGB32()});
    }
  }

  /// Keyboard shortcuts (any device with a keyboard; hinted in tooltips on desktop).
  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    final cmd = defaultTargetPlatform == TargetPlatform.macOS;
    SingleActivator k(LogicalKeyboardKey key, {bool shift = false}) =>
        SingleActivator(key, control: !cmd, meta: cmd, shift: shift);
    return {
      k(LogicalKeyboardKey.keyZ): () =>
          _history.canUndo ? _history.undo() : null,
      k(LogicalKeyboardKey.keyZ, shift: true): () =>
          _history.canRedo ? _history.redo() : null,
      k(LogicalKeyboardKey.keyY): () =>
          _history.canRedo ? _history.redo() : null,
      k(LogicalKeyboardKey.keyG): _goToPageDialog,
      k(LogicalKeyboardKey.digit0): _fitWidth,
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          _setTool(Tool.pan),
      const SingleActivator(LogicalKeyboardKey.keyV): () => _setTool(Tool.pan),
      const SingleActivator(LogicalKeyboardKey.keyH): () =>
          _setTool(Tool.highlight),
      const SingleActivator(LogicalKeyboardKey.keyP): () => _setTool(Tool.ink),
      const SingleActivator(LogicalKeyboardKey.keyN): () => _setTool(Tool.note),
      const SingleActivator(LogicalKeyboardKey.keyE): () =>
          _setTool(Tool.eraser),
    };
  }

  /// Keep the same part of the document in view across rotation / window
  /// resizes, scaling the zoom with the view width, so a page that fit the
  /// width in portrait still fits it in landscape (and vice versa).
  void _onViewSizeChanged(
      Size viewSize, Size? oldViewSize, PdfViewerController controller) {
    if (oldViewSize == null || oldViewSize.width <= 0) return;
    if ((viewSize.width - oldViewSize.width).abs() < 1) return;
    // Zoom/position are handled once by ResponsivePdfSizing from the old
    // layout snapshot. Refresh only chrome bounds here; no delayed transform
    // may overwrite a more recent resize or a user gesture.
    final pad = MediaQuery.paddingOf(context);
    final expanded = MediaQuery.sizeOf(context).width >= 900;
    _barTop = pad.top + kToolbarHeight + (expanded ? 56 : 0);
    _barBottom = pad.bottom + (expanded ? 56 : 100);
  }

  String get _docId => widget.doc.id;

  @override
  void initState() {
    super.initState();
    // Live query: annotations made on another device appear here within ~1 s
    // (server poke -> delta sync -> local DB -> this stream).
    _input.addListener(_onInputChanged);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
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
      widget.engine.store
          .put('readstate', _docId, {'page': _initialPage ?? 1}, docId: _docId);
      _mode = ReadingMode.byName(
          await widget.engine.store.getMeta<String>('readingMode'));
      final bytes = await widget.engine.loadPdf(
          widget.doc.data['sha256'] as String,
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
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    _input.dispose();
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
      widget.engine.store
          .put('readstate', _docId, {'page': page}, docId: _docId);
    });
  }

  Future<void> _noteDialog(
      {Ann? existing, Offset? pos, required int page}) async {
    final ctl = TextEditingController(text: existing?.text ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'New note' : 'Note'),
        content: TextField(
            controller: ctl, autofocus: true, maxLines: 6, minLines: 3),
        actions: [
          if (existing != null)
            TextButton(
                onPressed: () => Navigator.pop(ctx, '\u0000delete'),
                child: const Text('Delete')),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (result == null) return;
    if (result == '\u0000delete') {
      await _remove(existing!);
    } else if (existing != null) {
      if (result != existing.text) {
        await _update(existing, {...existing.d, 'text': result});
      }
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
    final expanded = MediaQuery.sizeOf(context).width >= 900;
    if (_chrome) {
      final pad = MediaQuery.paddingOf(context);
      _barTop ??= pad.top + kToolbarHeight + (expanded ? 56 : 0);
      // Toolbar (48 + 2*4 padding) plus the page/zoom pill above it.
      _barBottom ??= pad.bottom + (expanded ? 56 : 100);
    }
    final appBar = AppBar(
      title: Text(widget.doc.data['title'] as String? ?? 'Document',
          maxLines: 2, overflow: TextOverflow.ellipsis),
      actions: [
        // Undo/redo live in the app bar: the bottom toolbar is already full
        // on a phone in portrait.
        ListenableBuilder(
          listenable: _history,
          builder: (context, _) =>
              Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: _tip('Undo', '${_cmdLabel}Z'),
              icon: const Icon(Icons.undo),
              onPressed: _history.canUndo ? _history.undo : null,
            ),
            IconButton(
              tooltip: _tip('Redo', '${_cmdLabel}Shift+Z'),
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
                      border: Border.all(
                          color: Theme.of(context).colorScheme.outline),
                    ),
                    child: Text('Aa',
                        style: TextStyle(
                            color: m.inkColor, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 12),
                  Text(m.label),
                  if (m == _mode) ...[
                    const Spacer(),
                    const Icon(Icons.check, size: 18)
                  ],
                ]),
              ),
          ],
        ),
        IconButton(
          tooltip: 'Annotations',
          isSelected: expanded && _annotationsVisible,
          icon: const Icon(Icons.notes_outlined),
          onPressed: _bytes == null ? null : () => _showAnnotations(expanded),
        ),
        const SizedBox(width: 8),
      ],
    );
    final body = _error != null
        ? Center(
            child: Text('Could not open PDF:\n$_error',
                textAlign: TextAlign.center))
        : _bytes == null
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                    width: 200,
                    child: LinearProgressIndicator(
                        value: _progress > 0 ? _progress : null)),
                const SizedBox(height: 12),
                const Text('Downloading…'),
              ]))
            : PdfViewer.data(
                _bytes!,
                sourceName: widget.doc.data['sha256'] as String,
                controller: _controller,
                params: PdfViewerParams(
                  // Single tap with the hand tool toggles the bars (touch
                  // only; on desktop they stay). Double tap keeps pdfrx's zoom.
                  onGeneralTap: (context, controller, details) {
                    if (kDesktop ||
                        details.type != PdfViewerGeneralTapType.tap ||
                        _tool != Tool.pan) {
                      return false;
                    }
                    _setChrome(!_chrome);
                    return true;
                  },
                  panEnabled: !drawing || _navPan,
                  // Also on with nothing down, so Ctrl+wheel / trackpad pinch
                  // zoom while a drawing tool is selected.
                  scaleEnabled: !drawing || _navScale,
                  onPageChanged: _onPageChanged,
                  onViewSizeChanged: _onViewSizeChanged,
                  normalizeMatrix: _normalize,
                  // Pinch zoom felt too twitchy at the default 1.0: zoom
                  // follows (finger spread ratio)^0.6, so spreading the
                  // fingers to twice the distance zooms ~1.5x, not 2x.
                  scaleGestureSensitivity: 0.6,
                  // Mouse wheel: bigger steps that glide and accelerate when
                  // the wheel is spun; finger / middle-drag flings that carry
                  // like native scrolling; pages pre-rendered two screens
                  // ahead. Values and reasoning in scroll_feel.dart.
                  scrollByMouseWheel: kWheelStep,
                  interactionDelegateProvider:
                      const AcceleratedWheelScrollProvider(),
                  interactionEndFrictionCoefficient: kFlingDrag,
                  verticalCacheExtent: kCacheExtent,
                  horizontalCacheExtent: kCacheExtent,
                  // Render whole pages in one pass up to 4x (≈288 dpi) instead of
                  // pdfrx's 200 dpi. Above the threshold pdfrx re-renders a sharp
                  // image of just the visible area after every scroll and uploads it
                  // to the GPU – at fit-width (3.1–3.7x on a laptop or the tablet)
                  // that was the main cause of scroll jank. One full image per page is
                  // cached and simply moved instead. See docs/performance.md.
                  sizeDelegateProvider: const ResponsivePdfSizing(),
                  // Room for ~10 such pages (~21 MB each) so scrolling back and
                  // forth doesn't evict and re-render them.
                  maxImageBytesCachedOnMemory: 256 * 1024 * 1024,
                  // No blurred drop shadow: pdfrx paints it under every page in the
                  // cache extent on every frame (blur mask filter). See docs/performance.md.
                  pageDropShadow: null,
                  pageImageColorFilter: _mode.colorFilter,
                  // The gutter around pages follows the app theme instead of
                  // pdfrx's default mid-grey.
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  // Long-press (touch) or drag (mouse) selects text with the
                  // hand tool; the menu gets a "Highlight" action next to
                  // Copy. Off while drawing so a pen stroke never selects.
                  textSelectionParams: PdfTextSelectionParams(
                    enabled: !drawing,
                  ),
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
                    // pdfrx runs its own initial page jump after this
                    // callback (placing the page under the top bar). Position
                    // once that has settled, keeping the page invisible
                    // until then so it never visibly jumps.
                    Future.delayed(const Duration(milliseconds: 150), () async {
                      if (!mounted) return;
                      await _goToPage(
                          p != null && p >= 1 && p <= document.pages.length
                              ? p
                              : 1);
                      if (mounted) setState(() => _positioned = true);
                    });
                  },
                  pageOverlaysBuilder: (context, pageRect, page) => [
                    AnnotationLayer(
                      key: ValueKey('ann-${page.pageNumber}'),
                      pageNumber: page.pageNumber,
                      annotations: _anns,
                      tool: _tool,
                      color: _color,
                      policy: _input,
                      onCreate: _create,
                      onDelete: _remove,
                      onNoteTap: (a) => _noteDialog(existing: a, page: a.page),
                      onNewNote: (pos) =>
                          _noteDialog(pos: pos, page: page.pageNumber),
                      onContextMenu: _annotationMenu,
                    ),
                  ],
                ),
              );

    final dur = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    final ready = _bytes != null && _error == null;
    return CallbackShortcuts(
        bindings: _shortcuts,
        child: Focus(
            autofocus: true,
            child: Scaffold(
              // Nothing resizes the viewer – not the keyboard (the note dialog's
              // keyboard made pdfrx re-fit the page) and not the bars.
              resizeToAvoidBottomInset: false,
              body: Row(children: [
                Expanded(
                    child: Stack(children: [
                  Positioned.fill(
                    // Own layer: the bars, pill and page thumb update while scrolling
                    // and must not make the viewer repaint (and vice versa).
                    child: RepaintBoundary(
                      child: ready
                          ? Opacity(opacity: _positioned ? 1 : 0, child: body)
                          : SafeArea(child: body),
                    ),
                  ),
                  if (ready)
                    // Draggable scrollbar thumb with the page number. It lives outside
                    // the viewer so its track can stay between the floating bars.
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: _PageThumb(
                          controller: _controller,
                          top: (_chrome
                                  ? _barTop ?? 0
                                  : MediaQuery.paddingOf(context).top) +
                              8,
                          bottom: (_chrome
                                  ? _barBottom ?? 0
                                  : MediaQuery.paddingOf(context).bottom) +
                              8,
                        ),
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
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          appBar,
                          if (expanded && ready)
                            Material(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainer,
                                child: _toolbar(expanded: true)),
                        ]),
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
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _statusPill()),
                            if (!expanded)
                              Material(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainer,
                                  child: _toolbar()),
                          ]),
                        ),
                      ),
                    ),
                ])),
                if (expanded && _annotationsVisible && ready)
                  Container(
                    width: 320,
                    decoration: BoxDecoration(
                        border: Border(
                            left: BorderSide(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant))),
                    child: SafeArea(
                        child: _annotationPanel(
                            onClose: () =>
                                setState(() => _annotationsVisible = false))),
                  ),
              ]),
            )));
  }

  Widget _annotationPanel(
          {required VoidCallback onClose, bool sheet = false}) =>
      AnnotationsPanel(
        annotations: _anns,
        documentTitle: widget.doc.data['title'] as String? ?? 'Document',
        onClose: onClose,
        onGoTo: (ann) {
          if (sheet) Navigator.pop(context);
          _goToPage(ann.page);
        },
        onEdit: (ann) => _noteDialog(existing: ann, page: ann.page),
        onDelete: _remove,
      );

  void _showAnnotations(bool expanded) {
    if (expanded) {
      setState(() => _annotationsVisible = !_annotationsVisible);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => FractionallySizedBox(
          heightFactor: .85,
          child:
              _annotationPanel(sheet: true, onClose: () => Navigator.pop(ctx))),
    );
  }

  /// "3 / 12 · 86%": tap the page part to jump to a page, the zoom part for
  /// zoom presets.
  Widget _statusPill() {
    final scheme = Theme.of(context).colorScheme;
    final total =
        _document?.pages.length ?? (widget.doc.data['pageCount'] as int? ?? 0);
    final style = TextStyle(
        color: scheme.onSurface, fontSize: 13, fontWeight: FontWeight.w600);
    return Material(
      color: scheme.surfaceContainerHighest,
      shape: AppTheme.square,
      clipBehavior: Clip.antiAlias,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: _goToPageDialog,
          mouseCursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
            child: ValueListenableBuilder<int>(
              valueListenable: _page,
              builder: (_, p, __) => Text('$p / $total', style: style),
            ),
          ),
        ),
        Container(width: 1, height: 16, color: scheme.outline),
        PopupMenuButton<_ZoomPreset>(
          tooltip: 'Zoom',
          onSelected: _applyZoom,
          itemBuilder: (_) => [
            for (final z in _ZoomPreset.all)
              PopupMenuItem(value: z, child: Text(z.label))
          ],
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
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(onPressed: submit, child: const Text('Go')),
          ],
        );
      },
    );
    if (n == null) return;
    await _goToPage(n.clamp(1, total));
  }

  /// Tooltip with the keyboard shortcut appended on desktop.
  String _tip(String label, String keys) => kDesktop ? '$label ($keys)' : label;
  String get _cmdLabel =>
      defaultTargetPlatform == TargetPlatform.macOS ? '⌘' : 'Ctrl+';

  Widget _swatch(Color c, {double size = 28, bool? selected}) {
    final scheme = Theme.of(context).colorScheme;
    selected ??= _color == c;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.rectangle,
        // A visible outline even for the dark swatch on a dark toolbar.
        border: Border.all(
            width: selected ? 3 : 1.5,
            color: selected ? scheme.primary : scheme.outline),
      ),
    );
  }

  Widget _toolbar({bool expanded = false}) {
    final scheme = Theme.of(context).colorScheme;
    Widget toolBtn(Tool t, IconData icon, String tip, String key) => IconButton(
          tooltip: _tip(tip, key),
          isSelected: _tool == t,
          icon: Icon(icon),
          style: IconButton.styleFrom(
              backgroundColor: _tool == t ? scheme.primaryContainer : null),
          onPressed: () => _setTool(t),
        );
    final tools = [
      toolBtn(Tool.pan, Icons.pan_tool_outlined, 'Navigate', 'V'),
      toolBtn(Tool.highlight, Icons.highlight, 'Highlight – drag a box', 'H'),
      toolBtn(Tool.ink, Icons.draw_outlined, 'Pen', 'P'),
      toolBtn(Tool.note, Icons.sticky_note_2_outlined,
          kDesktop ? 'Note – click' : 'Note – tap', 'N'),
      toolBtn(Tool.eraser, Icons.auto_fix_normal_outlined, 'Eraser', 'E'),
    ];
    return SafeArea(
      top: false,
      bottom: !expanded,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: LayoutBuilder(builder: (context, c) {
          // 5 tools (48 each) + 5 swatches (34 each) need ~420 dp. On narrower
          // screens (phones in portrait) the colours collapse into one button.
          final wide = c.maxWidth >= 600;
          return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                  width: c.maxWidth < 300 ? 300 : c.maxWidth,
                  child: Row(children: [
                    ...tools,
                    const Spacer(),
                    if (wide)
                      for (final col in palette)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: InkResponse(
                            onTap: () => setState(() => _color = col),
                            radius: 20,
                            child: Semantics(
                                label:
                                    'Annotation color ${palette.indexOf(col) + 1}',
                                button: true,
                                selected: _color == col,
                                child: SizedBox(
                                    width: 42,
                                    height: 48,
                                    child: Center(child: _swatch(col)))),
                          ),
                        )
                    else
                      PopupMenuButton<Color>(
                        tooltip: 'Colour',
                        onSelected: (col) => setState(() => _color = col),
                        itemBuilder: (_) => [
                          for (final col in palette)
                            PopupMenuItem(
                                value: col,
                                child: Center(child: _swatch(col, size: 32))),
                        ],
                        child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: _swatch(_color)),
                      ),
                  ])));
        }),
      ),
    );
  }
}

class SyncIndicator extends StatelessWidget {
  const SyncIndicator(
      {super.key, required this.engine, this.showLabel = false});
  final SyncEngine engine;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final (icon, tip) = switch (engine.status) {
          SyncStatus.idle => (Icons.cloud_done_outlined, 'Synced'),
          SyncStatus.syncing => (Icons.cloud_sync_outlined, 'Syncing…'),
          SyncStatus.offline => (
              Icons.cloud_off_outlined,
              'Offline – changes are saved and will sync'
            ),
          SyncStatus.error => (
              Icons.error_outline,
              engine.lastError ?? 'Sync error'
            ),
        };
        final scheme = Theme.of(context).colorScheme;
        final color = engine.status == SyncStatus.error
            ? scheme.error
            : engine.status == SyncStatus.offline
                ? scheme.tertiary
                : scheme.onSurfaceVariant;
        if (!showLabel) {
          return IconButton(
              icon: Icon(icon, color: color),
              tooltip: tip,
              onPressed: engine.syncNow);
        }
        return Tooltip(
            message: tip,
            child: InkWell(
                onTap: engine.syncNow,
                child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(icon, size: 16, color: color),
                      const SizedBox(width: 6),
                      Flexible(
                          child: Text(
                              switch (engine.status) {
                                SyncStatus.idle =>
                                  engine.lastSynced == null ? 'Sync' : 'Synced',
                                SyncStatus.syncing => 'Syncing…',
                                SyncStatus.offline => 'Offline',
                                SyncStatus.error => 'Sync error'
                              },
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: color))),
                    ]))));
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
  const _PageThumb(
      {required this.controller, required this.top, required this.bottom});
  final PdfViewerController controller;
  final double top;
  final double bottom;

  @override
  State<_PageThumb> createState() => _PageThumbState();
}

class _PageThumbState extends State<_PageThumb> {
  static const _size = Size(46, 30);
  static const _hideDelay = Duration(milliseconds: 600);
  bool _dragging = false;

  // Only shown while the page is moving (scroll, fling, zoom) or the thumb is
  // being dragged; fades out shortly after movement stops.
  bool _visible = false;
  Timer? _hideTimer;
  Matrix4? _lastMatrix;

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideDelay, () {
      if (mounted && !_dragging) setState(() => _visible = false);
    });
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final c = widget.controller;
    // Ignore notifications that don't actually move the page.
    final m = c.isReady ? c.value : null;
    final moved = m != null && _lastMatrix != null && m != _lastMatrix;
    _lastMatrix = m?.clone();
    setState(() {
      if (moved) _visible = true;
    });
    if (moved) _scheduleHide();
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
    return (
      fraction: ((view.top - minY) / range).clamp(0.0, 1.0),
      minY: minY,
      range: range
    );
  }

  void _dragTo(double localY, double track) {
    final m = _metrics();
    if (m == null) return;
    final c = widget.controller;
    final f =
        ((localY - widget.top - _size.height / 2) / track).clamp(0.0, 1.0);
    final view = c.visibleRect;
    final target =
        Offset(view.center.dx, m.minY + f * m.range + view.height / 2);
    c.goTo(c.calcMatrixFor(target), duration: Duration.zero);
  }

  @override
  Widget build(BuildContext context) {
    final m = _metrics();
    if (m == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      final track = (box.maxHeight - widget.top - widget.bottom - _size.height)
          .clamp(0.0, double.infinity);
      final y = widget.top + m.fraction * track;
      return Stack(children: [
        Positioned(
          right: 0,
          top: y,
          width: _size.width,
          height: _size.height,
          child: IgnorePointer(
            // Hidden thumb must not swallow taps meant for the page.
            ignoring: !_visible,
            child: AnimatedOpacity(
              opacity: _visible ? 1 : 0,
              duration: Duration(milliseconds: _visible ? 100 : 200),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (_) => setState(() {
                  _dragging = true;
                  _visible = true;
                  _hideTimer?.cancel();
                }),
                onVerticalDragUpdate: (d) {
                  final local = (context.findRenderObject() as RenderBox)
                      .globalToLocal(d.globalPosition);
                  _dragTo(local.dy, track);
                },
                onVerticalDragEnd: (_) {
                  setState(() => _dragging = false);
                  _scheduleHide();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    color: (_dragging ? scheme.primary : scheme.inverseSurface)
                        .withValues(alpha: 0.85),
                    borderRadius: const BorderRadius.horizontal(
                        left: Radius.circular(15)),
                  ),
                  alignment: Alignment.center,
                  child: Text('${widget.controller.pageNumber ?? ''}',
                      style: TextStyle(
                        color: _dragging
                            ? scheme.onPrimary
                            : scheme.onInverseSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      )),
                ),
              ),
            ),
          ),
        ),
      ]);
    });
  }
}
