import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../annotations.dart';
import '../sync/record.dart';
import '../sync/sync_engine.dart';
import 'reader_page.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key, required this.engine, required this.email, required this.onLogout});
  final SyncEngine engine;
  final String email;
  final VoidCallback onLogout;

  Future<void> _addPdf(BuildContext context) async {
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
        if (context.mounted) {
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

  Future<void> _rename(BuildContext context, SyncRecord doc) async {
    final ctl = TextEditingController(text: doc.data['title'] as String? ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: ctl, autofocus: true),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          StreamBuilder<int>(
            stream: engine.store.watchPendingCount(),
            builder: (context, s) => (s.data ?? 0) > 0
                ? Center(child: Text('${s.data} pending', style: Theme.of(context).textTheme.labelSmall))
                : const SizedBox.shrink(),
          ),
          SyncIndicator(engine: engine),
          PopupMenuButton<String>(
            onSelected: (v) => v == 'logout' ? onLogout() : null,
            itemBuilder: (_) => [
              PopupMenuItem(enabled: false, child: Text(email)),
              const PopupMenuItem(value: 'logout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addPdf(context),
        icon: const Icon(Icons.add),
        label: const Text('Add PDF'),
      ),
      body: StreamBuilder<List<SyncRecord>>(
        stream: engine.store.watchDocuments(),
        builder: (context, snap) {
          final docs = snap.data ?? const [];
          if (docs.isEmpty) {
            return const Center(child: Text('No PDFs yet. Add one – it will appear on all your devices.'));
          }
          return RefreshIndicator(
            onRefresh: engine.syncNow,
            child: ListView.separated(
              itemCount: docs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final d = docs[i];
                final size = (d.data['size'] as int? ?? 0) / (1024 * 1024);
                return ListTile(
                  leading: Icon(Icons.picture_as_pdf, color: d.dirty ? Colors.orange : Colors.red),
                  title: Text(d.data['title'] as String? ?? 'Untitled'),
                  subtitle: Text('${_pages(d.data['pageCount'])} · ${size.toStringAsFixed(1)} MB'
                      '${d.dirty ? ' · not synced yet' : ''}'),
                  onTap: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => ReaderPage(engine: engine, doc: d))),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'rename') await _rename(context, d);
                      if (v == 'delete') {
                        await engine.store.delete('document', d.id, docId: d.id);
                        await engine.blobs.remove(d.data['sha256'] as String);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(value: 'delete', child: Text('Delete everywhere')),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

String _pages(Object? n) => n is int ? (n == 1 ? '1 page' : '$n pages') : '? pages';
