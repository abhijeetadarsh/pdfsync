import 'dart:async';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../annotations.dart';
import '../sync/record.dart';
import '../sync/sync_engine.dart';
import 'reader_page.dart';
import 'app_theme.dart';

enum LibraryFilter { all, reading, finished }

class LibraryPage extends StatefulWidget {
  const LibraryPage(
      {super.key,
      required this.engine,
      required this.email,
      required this.onLogout,
      this.themeMode = ThemeMode.dark,
      this.onThemeChanged});
  final SyncEngine engine;
  final String email;
  final VoidCallback onLogout;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeChanged;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  SyncEngine get engine => widget.engine;
  final _search = TextEditingController();
  late final _documents = engine.store.watchDocuments();
  late final _readStates = engine.store.watchReadStates();
  LibraryFilter _filter = LibraryFilter.all;
  bool? _grid;
  String? _selected;
  bool _adding = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      await _addPdf();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not add the PDF. Please try again.')));
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _addPdf() async {
    final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        withData: true,
        allowMultiple: true);
    if (res == null) return;
    for (final f in res.files) {
      final bytes = f.bytes;
      if (bytes == null) continue;
      final sha = sha256.convert(bytes).toString();
      int pages = 0;
      try {
        final doc = await PdfDocument.openData(bytes);
        pages = doc.pages.length;
        await doc.dispose();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${f.name} is not a readable PDF')));
        }
        continue;
      }
      // Cache locally first: the doc is usable immediately, even offline. The
      // engine uploads the bytes (once, deduplicated by hash) on the next sync.
      await engine.blobs.put(sha, bytes);
      final id = newId();
      await engine.store.put(
          'document',
          id,
          {
            'title':
                f.name.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), ''),
            'sha256': sha,
            'size': bytes.length,
            'pageCount': pages,
            'addedAt': DateTime.now().toUtc().toIso8601String(),
          },
          docId: id);
    }
  }

  Future<void> _rename(SyncRecord doc) async {
    final ctl = TextEditingController(text: doc.data['title'] as String? ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
            controller: ctl,
            autofocus: true,
            onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await engine.store.put(
          'document', doc.id, {...doc.data, 'title': name.trim()},
          docId: doc.id);
    }
  }

  Future<void> _delete(SyncRecord doc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete everywhere?'),
        content: Text(
            '“${doc.data['title']}” and its annotations will be removed from all your devices.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await engine.store.delete('document', doc.id, docId: doc.id);
    await engine.blobs.remove(doc.data['sha256'] as String);
  }

  void _actions(SyncRecord doc) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(doc.data['title'] as String? ?? 'Untitled',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(ctx).textTheme.titleMedium),
            subtitle: Text(_size(doc)),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Rename'),
            onTap: () {
              Navigator.pop(ctx);
              _rename(doc);
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_outline,
                color: Theme.of(ctx).colorScheme.error),
            title: Text('Delete everywhere',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            onTap: () {
              Navigator.pop(ctx);
              _delete(doc);
            },
          ),
        ]),
      ),
    );
  }

  void _open(SyncRecord doc) => Navigator.push(context,
      MaterialPageRoute(builder: (_) => ReaderPage(engine: engine, doc: doc)));

  bool _matches(
      SyncRecord doc, Map<String, SyncRecord> reads, LibraryFilter filter) {
    final page = reads[doc.id]?.data['page'] as int? ?? 0;
    final total = doc.data['pageCount'] as int? ?? 0;
    return switch (filter) {
      LibraryFilter.all => true,
      LibraryFilter.reading => page > 0 && (total == 0 || page < total),
      LibraryFilter.finished => total > 0 && page >= total,
    };
  }

  Widget _account() => PopupMenuButton<String>(
        tooltip: 'Account and appearance',
        onSelected: (v) {
          if (v == 'logout') {
            widget.onLogout();
            return;
          }
          widget.onThemeChanged?.call(ThemeMode.values.byName(v));
        },
        icon: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Text(
                widget.email.isEmpty ? '?' : widget.email[0].toUpperCase(),
                style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w700))),
        itemBuilder: (_) => [
          PopupMenuItem(enabled: false, child: Text(widget.email)),
          if (widget.onThemeChanged != null) ...[
            const PopupMenuDivider(),
            for (final m in ThemeMode.values)
              CheckedPopupMenuItem(
                  value: m.name,
                  checked: widget.themeMode == m,
                  child: Text(
                      '${m.name[0].toUpperCase()}${m.name.substring(1)} appearance')),
          ],
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'logout', child: Text('Sign out')),
        ],
      );

  Widget _addButton() => FilledButton.icon(
      onPressed: _adding ? null : _import,
      icon: _adding
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.add),
      label: Text(_adding ? 'Adding…' : 'Add PDF'));

  Widget _sidebar(List<SyncRecord> docs, Map<String, SyncRecord> reads) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 224,
      decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          border: Border(right: BorderSide(color: scheme.outlineVariant))),
      child: SafeArea(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(
            padding: EdgeInsets.all(24),
            child: Row(children: [
              PdfMark(size: 32),
              SizedBox(width: 12),
              Text('PDF Sync', style: TextStyle(fontWeight: FontWeight.w700))
            ])),
        const Divider(),
        const SizedBox(height: 12),
        for (final f in LibraryFilter.values)
          Material(
              color: _filter == f
                  ? scheme.surfaceContainerHigh
                  : Colors.transparent,
              child: ListTile(
                selected: _filter == f,
                leading: Icon(switch (f) {
                  LibraryFilter.all => Icons.local_library_outlined,
                  LibraryFilter.reading => Icons.schedule,
                  LibraryFilter.finished => Icons.done
                }),
                title: Text(switch (f) {
                  LibraryFilter.all => 'Library',
                  LibraryFilter.reading => 'Reading',
                  LibraryFilter.finished => 'Finished'
                }),
                trailing: Text(
                    '${docs.where((d) => _matches(d, reads, f)).length}',
                    style: Theme.of(context).textTheme.bodySmall),
                onTap: () => setState(() => _filter = f),
              )),
        const Spacer(),
        const Divider(),
        Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              _account(),
              const SizedBox(width: 8),
              Expanded(child: SyncIndicator(engine: engine, showLabel: true))
            ])),
      ])),
    );
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<SyncRecord>>(
        stream: _documents,
        builder: (context, docsSnap) => StreamBuilder<List<SyncRecord>>(
          stream: _readStates,
          builder: (context, rsSnap) {
            final theme = Theme.of(context), scheme = theme.colorScheme;
            if (docsSnap.hasError || rsSnap.hasError) {
              return const Scaffold(
                  body: Center(
                      child: Text(
                          'Could not load your library. Reopen the app to try again.')));
            }
            if (!docsSnap.hasData) {
              return const Scaffold(
                  body: Center(child: CircularProgressIndicator()));
            }
            final reads = {
              for (final r in rsSnap.data ?? const <SyncRecord>[]) r.id: r
            };
            final all = [...docsSnap.data!]..sort((a, b) {
                final ra = reads[a.id]?.hlc ?? '', rb = reads[b.id]?.hlc ?? '';
                return ra != rb
                    ? rb.compareTo(ra)
                    : (b.data['addedAt'] as String? ?? '')
                        .compareTo(a.data['addedAt'] as String? ?? '');
              });
            final query = _search.text.trim().toLowerCase();
            final docs = all
                .where((d) =>
                    _matches(d, reads, _filter) &&
                    _title(d).toLowerCase().contains(query))
                .toList();
            final recent = all
                .where((d) => _matches(d, reads, LibraryFilter.reading))
                .firstOrNull;
            final selected = docs.where((d) => d.id == _selected).firstOrNull ??
                docs.firstOrNull;
            return LayoutBuilder(builder: (context, box) {
              final expanded = box.maxWidth >= 760,
                  desktop = box.maxWidth >= 1240;
              final grid = _grid ?? expanded && !desktop;
              final showResume = recent != null &&
                  query.isEmpty &&
                  _filter != LibraryFilter.finished;
              return Scaffold(
                floatingActionButton: expanded
                    ? null
                    : FloatingActionButton.extended(
                        onPressed: _adding ? null : _import,
                        icon: const Icon(Icons.add),
                        label: Text(_adding ? 'Adding…' : 'Add PDF')),
                body: Row(children: [
                  if (expanded) _sidebar(all, reads),
                  Expanded(
                      child: SafeArea(
                          child: Column(children: [
                    Padding(
                        padding: EdgeInsets.fromLTRB(
                            expanded ? 28 : 20, 20, expanded ? 28 : 12, 16),
                        child: Row(children: [
                          Text('Library', style: theme.textTheme.titleLarge),
                          const Spacer(),
                          if (!expanded) ...[
                            SyncIndicator(engine: engine, showLabel: true),
                            const SizedBox(width: 8),
                            _account()
                          ],
                          if (expanded) ...[
                            IconButton(
                                tooltip: 'Grid view',
                                isSelected: grid,
                                onPressed: () => setState(() => _grid = true),
                                icon: const Icon(Icons.grid_view_outlined)),
                            IconButton(
                                tooltip: 'List view',
                                isSelected: !grid,
                                onPressed: () => setState(() => _grid = false),
                                icon: const Icon(Icons.view_list_outlined)),
                            const SizedBox(width: 12),
                            _addButton(),
                          ],
                        ])),
                    Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: expanded ? 28 : 20),
                        child: TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                              hintText: 'Search document titles',
                              prefixIcon: const Icon(Icons.search, size: 20),
                              suffixIcon: query.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: 'Clear search',
                                      icon: const Icon(Icons.close),
                                      onPressed: () =>
                                          setState(_search.clear))),
                        )),
                    if (!expanded)
                      Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
                          child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(children: [
                                for (final f in LibraryFilter.values)
                                  _FilterButton(
                                      label:
                                          '${f.name[0].toUpperCase()}${f.name.substring(1)} · ${all.where((d) => _matches(d, reads, f)).length}',
                                      selected: _filter == f,
                                      onTap: () => setState(() => _filter = f)),
                              ]))),
                    const SizedBox(height: 12),
                    Expanded(
                        child: all.isEmpty
                            ? _Empty(onAdd: _import)
                            : RefreshIndicator(
                                onRefresh: engine.syncNow,
                                child: CustomScrollView(
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    slivers: [
                                      if (showResume)
                                        SliverPadding(
                                            padding: EdgeInsets.fromLTRB(
                                                expanded ? 28 : 20,
                                                4,
                                                expanded ? 28 : 20,
                                                24),
                                            sliver: SliverToBoxAdapter(
                                                child: _resume(
                                                    recent, reads[recent.id]))),
                                      SliverPadding(
                                          padding: EdgeInsets.fromLTRB(
                                              expanded ? 28 : 20,
                                              8,
                                              expanded ? 28 : 20,
                                              12),
                                          sliver: SliverToBoxAdapter(
                                              child: Row(children: [
                                            Expanded(
                                                child: Text(
                                                    _filter == LibraryFilter.all
                                                        ? 'All documents'
                                                        : _filter ==
                                                                LibraryFilter
                                                                    .reading
                                                            ? 'Currently reading'
                                                            : 'Finished documents',
                                                    style: theme
                                                        .textTheme.bodySmall
                                                        ?.copyWith(
                                                            color: scheme
                                                                .onSurfaceVariant))),
                                            Text('${docs.length}',
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                        color: scheme
                                                            .onSurfaceVariant)),
                                          ]))),
                                      if (docs.isEmpty)
                                        SliverFillRemaining(
                                            hasScrollBody: false,
                                            child: Center(
                                                child: Padding(
                                                    padding:
                                                        const EdgeInsets.all(
                                                            24),
                                                    child: Column(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          const Icon(
                                                              Icons
                                                                  .search_off_outlined,
                                                              size: 32),
                                                          const SizedBox(
                                                              height: 12),
                                                          Text(
                                                              query.isEmpty
                                                                  ? 'No ${_filter.name} documents yet.'
                                                                  : 'No documents found.',
                                                              textAlign:
                                                                  TextAlign
                                                                      .center),
                                                          const SizedBox(
                                                              height: 8),
                                                          TextButton(
                                                              onPressed: () =>
                                                                  setState(() {
                                                                    _search
                                                                        .clear();
                                                                    _filter =
                                                                        LibraryFilter
                                                                            .all;
                                                                  }),
                                                              child: const Text(
                                                                  'Show all documents')),
                                                        ])))),
                                      if (grid)
                                        SliverPadding(
                                            padding: const EdgeInsets.fromLTRB(
                                                28, 0, 28, 28),
                                            sliver: SliverGrid.builder(
                                              gridDelegate:
                                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                                      maxCrossAxisExtent: 200,
                                                      mainAxisExtent: 290,
                                                      crossAxisSpacing: 20,
                                                      mainAxisSpacing: 20),
                                              itemCount: docs.length,
                                              itemBuilder: (_, i) => _gridItem(
                                                  docs[i], reads[docs[i].id]),
                                            ))
                                      else
                                        SliverList.builder(
                                            itemCount: docs.length,
                                            itemBuilder: (_, i) => _row(
                                                docs[i], reads[docs[i].id],
                                                selected: desktop &&
                                                    docs[i].id == selected?.id,
                                                onTap: () => desktop
                                                    ? setState(() =>
                                                        _selected = docs[i].id)
                                                    : _open(docs[i]))),
                                      SliverToBoxAdapter(
                                          child: SizedBox(
                                              height: expanded ? 20 : 100)),
                                    ]),
                              )),
                    if (expanded)
                      Container(
                          decoration: BoxDecoration(
                              border: Border(
                                  top: BorderSide(
                                      color: scheme.outlineVariant))),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 8),
                          child: Row(children: [
                            Expanded(
                                child: SyncIndicator(
                                    engine: engine, showLabel: true)),
                            Text('${all.length} documents',
                                style: theme.textTheme.bodySmall)
                          ])),
                  ]))),
                  if (desktop && selected != null)
                    _detail(selected, reads[selected.id]),
                ]),
              );
            });
          },
        ),
      );

  Widget _resume(SyncRecord doc, SyncRecord? read) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    return Material(
        color: scheme.surfaceContainerHigh,
        child: InkWell(
            onTap: () => _open(doc),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                    width: 68,
                    height: 96,
                    child: _Cover(
                        engine: engine, sha: doc.data['sha256'] as String)),
                const SizedBox(width: 16),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('Continue reading',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.primary)),
                      const SizedBox(height: 6),
                      Text(_title(doc),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 6),
                      Text(_pageLabel(doc, read),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(value: _progress(doc, read)),
                    ])),
              ]),
            )));
  }

  Widget _row(SyncRecord doc, SyncRecord? read,
      {bool selected = false, required VoidCallback onTap}) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    return Material(
        color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onDoubleTap: () => _open(doc),
          onLongPress: () => _actions(doc),
          child: Container(
            decoration: BoxDecoration(
                border: Border(top: BorderSide(color: scheme.outlineVariant))),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(children: [
              SizedBox(
                  width: 40,
                  height: 56,
                  child: _Cover(
                      engine: engine, sha: doc.data['sha256'] as String)),
              const SizedBox(width: 14),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(_title(doc),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: selected ? scheme.primary : null)),
                    const SizedBox(height: 3),
                    Text(doc.dirty ? 'Waiting to sync' : _pageLabel(doc, read),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: doc.dirty
                                ? scheme.tertiary
                                : scheme.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: _progress(doc, read)),
                  ])),
              const SizedBox(width: 8),
              IconButton(
                  tooltip: 'Document actions',
                  onPressed: () => _actions(doc),
                  icon: const Icon(Icons.more_horiz)),
            ]),
          ),
        ));
  }

  Widget _gridItem(SyncRecord doc, SyncRecord? read) {
    final theme = Theme.of(context);
    return Material(
        color: Colors.transparent,
        child: InkWell(
            onTap: () => _open(doc),
            onLongPress: () => _actions(doc),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                      child: _Cover(
                          engine: engine, sha: doc.data['sha256'] as String)),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _progress(doc, read)),
                  const SizedBox(height: 8),
                  Text(_title(doc),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium),
                  Row(children: [
                    Expanded(
                        child: Text(
                            doc.dirty
                                ? 'Waiting to sync'
                                : _pageLabel(doc, read),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall)),
                    IconButton(
                        tooltip: 'Document actions',
                        onPressed: () => _actions(doc),
                        icon: const Icon(Icons.more_horiz))
                  ]),
                ])));
  }

  Widget _detail(SyncRecord doc, SyncRecord? read) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    return Container(
      width: 288,
      decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          border: Border(left: BorderSide(color: scheme.outlineVariant))),
      child: SafeArea(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: ListView(children: [
                Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                        width: 136,
                        height: 184,
                        child: _Cover(
                            key: ValueKey(doc.id),
                            engine: engine,
                            sha: doc.data['sha256'] as String))),
                const SizedBox(height: 20),
                Text(_title(doc), style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text('${doc.data['pageCount'] ?? 0} pages · ${_size(doc)}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 24),
                LinearProgressIndicator(value: _progress(doc, read)),
                const SizedBox(height: 8),
                Text(_pageLabel(doc, read), style: theme.textTheme.bodySmall),
                const SizedBox(height: 20),
                FilledButton(
                    onPressed: () => _open(doc),
                    child: Text(read == null
                        ? 'Open document'
                        : 'Resume at page ${read.data['page']}')),
                const SizedBox(height: 24),
                const Divider(),
                StreamBuilder<List<SyncRecord>>(
                    key: ValueKey(doc.id),
                    stream: engine.store.watchAnnotations(doc.id),
                    builder: (context, snapshot) => Column(children: [
                          for (final type in ['highlight', 'note', 'ink'])
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                child: Row(children: [
                                  Expanded(
                                      child: Text(
                                          switch (type) {
                                            'highlight' => 'Highlights',
                                            'note' => 'Notes',
                                            _ => 'Ink'
                                          },
                                          style: theme.textTheme.bodySmall)),
                                  Text(
                                      '${snapshot.data?.where((a) => a.data['type'] == type).length ?? 0}',
                                      style: theme.textTheme.bodySmall),
                                ])),
                        ])),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                    onPressed: () => _rename(doc),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Rename')),
                TextButton(
                    onPressed: () => _actions(doc),
                    child: const Text('Document actions')),
              ]))),
    );
  }
}

String _title(SyncRecord d) => d.data['title'] as String? ?? 'Untitled';
double _progress(SyncRecord d, SyncRecord? read) {
  final total = d.data['pageCount'] as int? ?? 0,
      page = read?.data['page'] as int? ?? 0;
  return total > 0 ? (page / total).clamp(0.0, 1.0) : 0;
}

String _pageLabel(SyncRecord d, SyncRecord? read) {
  final total = d.data['pageCount'] as int? ?? 0,
      page = read?.data['page'] as int?;
  return page == null ? '$total pages' : 'Page $page of $total';
}

String _size(SyncRecord d) {
  final mb = (d.data['size'] as int? ?? 0) / (1024 * 1024);
  return mb >= 1 ? '${mb.toStringAsFixed(1)} MB' : '${(mb * 1024).round()} KB';
}

class _FilterButton extends StatelessWidget {
  const _FilterButton(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
            foregroundColor: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
            backgroundColor: selected
                ? Theme.of(context).colorScheme.surfaceContainerHigh
                : null),
        child: Text(label, style: const TextStyle(fontSize: 11)),
      );
}

/// First page of the PDF, rendered from the local blob cache. Documents not
/// downloaded on this device yet (they download on first open) show a
/// placeholder instead of pulling megabytes just for a thumbnail.
class _Cover extends StatefulWidget {
  const _Cover({super.key, required this.engine, required this.sha});
  final SyncEngine engine;
  final String sha;

  @override
  State<_Cover> createState() => _CoverState();
}

class _CoverState extends State<_Cover> {
  // Rendered covers, shared across rebuilds and scrolling (a library is small;
  // each cover is ~360x500 px).
  static final _cache = <String, ui.Image>{};

  ui.Image? _image;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    _image = _cache[widget.sha];
    if (_image == null) _load();
  }

  @override
  void didUpdateWidget(covariant _Cover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sha != widget.sha) {
      _image = _cache[widget.sha];
      _missing = false;
      if (_image == null) _load();
    }
  }

  /// Renders the *top* of page 1 at the card's width. Very tall pages (web
  /// exports) would otherwise shrink to a sliver; normal pages fill the card.
  Future<void> _load() async {
    final sha = widget.sha;
    final bytes = await widget.engine.blobs.get(sha);
    if (!mounted || widget.sha != sha) return;
    if (bytes == null) {
      if (mounted) setState(() => _missing = true);
      return;
    }
    PdfDocument? doc;
    try {
      doc =
          await PdfDocument.openData(bytes, sourceName: 'cover:${widget.sha}');
      final page = doc.pages.first;
      const w = 360;
      final fullH = w * page.height / page.width;
      final img = await page.renderForDisplay(
        width: w,
        height: fullH.clamp(1, w * 1.45).round(),
        fullWidth: w.toDouble(),
        fullHeight: fullH,
        backgroundColor: 0xFFFFFFFF,
      );
      if (img == null) return;
      _cache[sha] = img;
      if (mounted && widget.sha == sha) setState(() => _image = img);
    } catch (_) {
      // Unreadable: keep the placeholder.
    } finally {
      await doc?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final img = _image;
    if (img != null) {
      return Container(
        color: Colors.white,
        child: RawImage(
            image: img, fit: BoxFit.cover, alignment: Alignment.topCenter),
      );
    }
    return Container(
      color: scheme.surfaceContainerHigh,
      alignment: Alignment.center,
      child: Icon(
          _missing
              ? Icons.cloud_download_outlined
              : Icons.picture_as_pdf_outlined,
          size: 36,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.auto_stories_outlined,
              size: 72, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('Your library is empty', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
              'Add a PDF and it will appear on all your devices, with your highlights and notes.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 24),
          FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add PDF')),
        ]),
      ),
    );
  }
}
