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

/// Home: a calm grid of covers. Recently read first, reading progress under
/// each cover, everything else (rename, delete) behind a long-press so the
/// page stays uncluttered.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.engine, required this.email, required this.onLogout});
  final SyncEngine engine;
  final String email;
  final VoidCallback onLogout;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  SyncEngine get engine => widget.engine;
  final _search = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _addPdf() async {
    final res = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['pdf'], withData: true, allowMultiple: true);
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
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${f.name} is not a readable PDF')));
        }
        continue;
      }
      // Cache locally first: the doc is usable immediately, even offline. The
      // engine uploads the bytes (once, deduplicated by hash) on the next sync.
      await engine.blobs.put(sha, bytes);
      final id = newId();
      await engine.store.put('document', id, {
        'title': f.name.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), ''),
        'sha256': sha,
        'size': bytes.length,
        'pageCount': pages,
        'addedAt': DateTime.now().toUtc().toIso8601String(),
      }, docId: id);
    }
  }

  Future<void> _rename(SyncRecord doc) async {
    final ctl = TextEditingController(text: doc.data['title'] as String? ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: ctl, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await engine.store.put('document', doc.id, {...doc.data, 'title': name.trim()}, docId: doc.id);
    }
  }

  Future<void> _delete(SyncRecord doc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete everywhere?'),
        content: Text('“${doc.data['title']}” and its annotations will be removed from all your devices.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
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
                maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(ctx).textTheme.titleMedium),
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
            leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
            title: Text('Delete everywhere', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            onTap: () {
              Navigator.pop(ctx);
              _delete(doc);
            },
          ),
        ]),
      ),
    );
  }

  void _open(SyncRecord doc) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderPage(engine: engine, doc: doc)));

  PreferredSizeWidget _appBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppBar(
      titleSpacing: 20,
      title: _searching
          ? TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Search your library', border: InputBorder.none),
              onChanged: (_) => setState(() {}),
            )
          : const Text('Library', style: TextStyle(fontWeight: FontWeight.w600)),
      actions: [
        IconButton(
          tooltip: _searching ? 'Close search' : 'Search',
          icon: Icon(_searching ? Icons.close : Icons.search),
          onPressed: () => setState(() {
            _searching = !_searching;
            if (!_searching) _search.clear();
          }),
        ),
        StreamBuilder<int>(
          stream: engine.store.watchPendingCount(),
          builder: (context, s) => (s.data ?? 0) > 0
              ? Center(child: Text('${s.data} pending', style: Theme.of(context).textTheme.labelSmall))
              : const SizedBox.shrink(),
        ),
        SyncIndicator(engine: engine),
        PopupMenuButton<String>(
          tooltip: 'Account',
          onSelected: (v) => v == 'logout' ? widget.onLogout() : null,
          icon: CircleAvatar(
            radius: 15,
            backgroundColor: scheme.primaryContainer,
            child: Text(widget.email.isEmpty ? '?' : widget.email[0].toUpperCase(),
                style: TextStyle(fontSize: 14, color: scheme.onPrimaryContainer)),
          ),
          itemBuilder: (_) => [
            PopupMenuItem(enabled: false, child: Text(widget.email)),
            const PopupMenuItem(value: 'logout', child: Text('Sign out')),
          ],
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBar(context),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPdf,
        icon: const Icon(Icons.add),
        label: const Text('Add PDF'),
      ),
      body: StreamBuilder<List<SyncRecord>>(
        stream: engine.store.watchDocuments(),
        builder: (context, docsSnap) => StreamBuilder<List<SyncRecord>>(
          stream: engine.store.watchReadStates(),
          builder: (context, rsSnap) {
            if (!docsSnap.hasData) return const SizedBox.shrink();
            final reads = {for (final r in rsSnap.data ?? const <SyncRecord>[]) r.id: r};
            var docs = [...docsSnap.data!];
            if (docs.isEmpty) return _Empty(onAdd: _addPdf);

            final q = _search.text.trim().toLowerCase();
            if (q.isNotEmpty) {
              docs = docs.where((d) => (d.data['title'] as String? ?? '').toLowerCase().contains(q)).toList();
            }
            // Recently read first (the readstate's HLC starts with a ms
            // timestamp, so string order = time order), then newest added.
            docs.sort((a, b) {
              final ra = reads[a.id]?.hlc ?? '', rb = reads[b.id]?.hlc ?? '';
              if (ra != rb) return rb.compareTo(ra);
              return (b.data['addedAt'] as String? ?? '').compareTo(a.data['addedAt'] as String? ?? '');
            });

            return RefreshIndicator(
              onRefresh: engine.syncNow,
              child: GridView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 190,
                  mainAxisSpacing: 24,
                  crossAxisSpacing: 20,
                  childAspectRatio: 0.56,
                ),
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final d = docs[i];
                  return _DocCard(
                    key: ValueKey(d.id),
                    engine: engine,
                    doc: d,
                    page: reads[d.id]?.data['page'] as int?,
                    onTap: () => _open(d),
                    onMore: () => _actions(d),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

String _size(SyncRecord d) {
  final mb = (d.data['size'] as int? ?? 0) / (1024 * 1024);
  return mb >= 1 ? '${mb.toStringAsFixed(1)} MB' : '${(mb * 1024).round()} KB';
}

class _DocCard extends StatelessWidget {
  const _DocCard({
    super.key,
    required this.engine,
    required this.doc,
    required this.page,
    required this.onTap,
    required this.onMore,
  });
  final SyncEngine engine;
  final SyncRecord doc;
  final int? page;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = doc.data['pageCount'] as int? ?? 0;
    final p = page;
    final progress = (p != null && total > 0) ? (p / total).clamp(0.0, 1.0) : 0.0;
    final status = doc.dirty
        ? 'Not synced yet'
        : p == null
            ? (total == 1 ? '1 page' : '$total pages')
            : 'Page $p of $total';

    return InkWell(
      onTap: onTap,
      onLongPress: onMore,
      borderRadius: BorderRadius.circular(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 10, offset: const Offset(0, 4)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _Cover(engine: engine, sha: doc.data['sha256'] as String),
            ),
          ),
        ),
        const SizedBox(height: 10),
        // Reading progress: a hairline, only once the document has been opened.
        SizedBox(
          height: 3,
          child: p == null
              ? null
              : ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(value: progress, backgroundColor: scheme.surfaceContainerHighest),
                ),
        ),
        const SizedBox(height: 8),
        Text(
          doc.data['title'] as String? ?? 'Untitled',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.25),
        ),
        const SizedBox(height: 2),
        Text(status,
            maxLines: 1,
            style: theme.textTheme.bodySmall?.copyWith(color: doc.dirty ? scheme.tertiary : scheme.onSurfaceVariant)),
      ]),
    );
  }
}

/// First page of the PDF, rendered from the local blob cache. Documents not
/// downloaded on this device yet (they download on first open) show a
/// placeholder instead of pulling megabytes just for a thumbnail.
class _Cover extends StatefulWidget {
  const _Cover({required this.engine, required this.sha});
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

  /// Renders the *top* of page 1 at the card's width. Very tall pages (web
  /// exports) would otherwise shrink to a sliver; normal pages fill the card.
  Future<void> _load() async {
    final bytes = await widget.engine.blobs.get(widget.sha);
    if (bytes == null) {
      if (mounted) setState(() => _missing = true);
      return;
    }
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openData(bytes, sourceName: 'cover:${widget.sha}');
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
      _cache[widget.sha] = img;
      if (mounted) setState(() => _image = img);
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
        child: RawImage(image: img, fit: BoxFit.cover, alignment: Alignment.topCenter),
      );
    }
    return Container(
      color: scheme.surfaceContainerHigh,
      alignment: Alignment.center,
      child: Icon(_missing ? Icons.cloud_download_outlined : Icons.picture_as_pdf_outlined,
          size: 36, color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
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
          Icon(Icons.auto_stories_outlined, size: 72, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('Your library is empty', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text('Add a PDF and it will appear on all your devices, with your highlights and notes.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 24),
          FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Add PDF')),
        ]),
      ),
    );
  }
}
