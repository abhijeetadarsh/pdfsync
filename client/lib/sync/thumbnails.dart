import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import 'api_client.dart';
import 'local_store.dart';
import 'platform/db_io.dart' if (dart.library.js_interop) 'platform/db_web.dart'
    as platform;

/// A small PNG preview, independent of the PDF's offline availability.
Future<Uint8List?> renderThumbnail(Uint8List bytes) async {
  final doc = await PdfDocument.openData(bytes);
  try {
    return await renderDocumentThumbnail(doc);
  } finally {
    await doc.dispose();
  }
}

Future<Uint8List?> renderDocumentThumbnail(PdfDocument doc) async {
  if (doc.pages.isEmpty) return null;
  final page = doc.pages.first;
  const width = 360;
  final fullHeight = width * page.height / page.width;
  final image = await page.renderForDisplay(
    width: width,
    height: fullHeight.clamp(1, width * 1.45).round(),
    fullWidth: width.toDouble(),
    fullHeight: fullHeight,
    backgroundColor: 0xFFFFFFFF,
  );
  if (image == null) return null;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

class ThumbnailService {
  ThumbnailService(
    this.store,
    this.api,
    this.pdfs, {
    platform.BlobCache? cache,
    this.render = renderThumbnail,
  }) : cache = cache ??
            platform.BlobCache(namespace: 'thumbnails', extension: 'png');

  final LocalStore store;
  final ApiClient api;
  final platform.BlobCache pdfs;
  final platform.BlobCache cache;
  final Future<Uint8List?> Function(Uint8List) render;
  final _inflight = <String, Future<Uint8List?>>{};
  final _slots = List<Future<void>>.generate(3, (_) => Future.value());
  final _missingUntil = <String, DateTime>{};
  int _retryVersion = 0;
  void retryMissing([String? sha]) {
    _retryVersion++;
    if (sha == null) {
      _missingUntil.clear();
    } else {
      _missingUntil.remove(sha);
    }
  }

  int _nextSlot = 0;
  bool _disposed = false;
  void dispose() => _disposed = true;

  /// Coalesce repeated cards and cap both network and rendering work at three.
  Future<Uint8List?> load(String sha, {bool localFirst = false}) {
    if (_disposed) return Future.value();
    return _inflight.putIfAbsent(sha, () {
      final slot = _nextSlot++ % _slots.length;
      final task = _slots[slot]
          .then((_) => _disposed ? null : _load(sha, localFirst: localFirst));
      _slots[slot] =
          task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
      return task.whenComplete(() {
        _inflight.remove(sha);
      });
    });
  }

  Future<Uint8List?> _load(String sha, {required bool localFirst}) async {
    final retryVersion = _retryVersion;
    final local = await cache.get(sha);
    if (local != null) return local;
    if (localFirst) {
      final generated = await _generate(sha);
      if (generated != null) return generated;
    }
    final retryAt = _missingUntil[sha];
    if (retryAt != null && DateTime.now().isBefore(retryAt)) return null;
    Uint8List? remote;
    try {
      remote = await api.getThumbnail(sha);
    } catch (_) {
      // Offline/older server: a locally cached PDF can still supply a preview.
    }
    if (_disposed) return null;
    if (remote != null) {
      await cache.put(sha, remote);
      await store.setMeta('thumbnailUploaded:$sha', true);
      return remote;
    }
    final generated = await _generate(sha);
    if (generated == null && retryVersion == _retryVersion) {
      // Scroll notifications must not repeatedly request an absent preview.
      if (_missingUntil.length >= 256) {
        _missingUntil.remove(_missingUntil.keys.first);
      }
      _missingUntil[sha] = DateTime.now().add(const Duration(seconds: 30));
    }
    return generated;
  }

  Future<Uint8List?> _generate(String sha) async {
    final pdf = await pdfs.get(sha); // Never download a PDF for its thumbnail.
    if (pdf == null || _disposed) return null;
    try {
      final image = await render(pdf);
      if (image == null || _disposed) return null;
      await saveGenerated(sha, image);
      return image;
    } catch (_) {
      return null; // Password-protected/unreadable PDFs keep their placeholder.
    }
  }

  /// Called at import/open. Prefer rendering local bytes without a network wait.
  Future<void> prepare(String sha) async {
    try {
      if (_disposed || await cache.has(sha)) return;
      // Share the same queue and per-hash coalescing as library requests.
      await load(sha, localFirst: true);
    } catch (_) {
      // A preview failure must not affect opening/importing a PDF.
    }
  }

  Future<void> saveGenerated(String sha, Uint8List image) async {
    if (_disposed) return;
    retryMissing(sha);
    await cache.put(sha, image);
    if (_disposed) return;
    await store.setMeta('thumbnailUploaded:$sha', false);
    store.onLocalChange?.call();
  }

  Future<void>? _uploadRun;
  Future<void> uploadPending() =>
      _uploadRun ??= _uploadSafely().whenComplete(() => _uploadRun = null);

  Future<void> _uploadSafely() async {
    try {
      if (!_disposed) await _uploadPending();
    } catch (_) {
      // Account disposal/cache failures must not escape a background task.
    }
  }

  /// Optional previews must never prevent document/annotation synchronization.
  Future<void> _uploadPending() async {
    final docs = await store.watchDocuments().first;
    final hashes =
        docs.map((d) => d.data['sha256']).whereType<String>().toSet();
    for (final sha in hashes) {
      if (_disposed) return;
      if (await store.getMeta<bool>('thumbnailUploaded:$sha') == true) continue;
      final bytes = await cache.get(sha);
      if (bytes == null) continue;
      try {
        if (await store.getMeta<bool>('uploaded:$sha') != true &&
            !await api.hasBlob(sha).timeout(const Duration(seconds: 15))) {
          continue;
        }
        await api.putThumbnail(sha, bytes);
        if (!_disposed) await store.setMeta('thumbnailUploaded:$sha', true);
      } catch (_) {
        // Retry on the next ordinary sync, including reconnect and app resume.
      }
    }
  }
}
