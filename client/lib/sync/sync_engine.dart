import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'local_store.dart';
import 'platform/db_io.dart' if (dart.library.js_interop) 'platform/db_web.dart' as platform;
import 'record.dart';

class PdfDownloadException implements Exception {
  @override
  String toString() => 'This PDF is not available offline. Connect to the server and try again.';
}

enum SyncStatus { idle, syncing, offline, error }

/// Moves changes between the local store and the server.
///
/// When it syncs:
///  * ~400 ms after any local edit (debounced, so a pen stroke burst = 1 request)
///  * when the server pokes us over the WebSocket (another device changed something)
///  * on start, on reconnect, and every 2 minutes as a safety net
///
/// What goes over the wire:
///  * metadata: only records changed since our cursor (delta), batched, both ways in one round trip
///  * PDFs: content-addressed by SHA-256, uploaded once (HEAD check first), downloaded lazily on open
class SyncEngine extends ChangeNotifier {
  SyncEngine(this.store, this.api, {platform.BlobCache? blobs}) : blobs = blobs ?? platform.BlobCache() {
    api.deviceId = store.nodeId;
    store.onLocalChange = _schedule;
  }

  final LocalStore store;
  final ApiClient api;
  final platform.BlobCache blobs;

  SyncStatus status = SyncStatus.idle;
  String? lastError;
  DateTime? lastSynced;

  bool _running = false;
  bool _again = false;
  bool _disposed = false;
  Timer? _debounce;
  Timer? _periodic;
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  int _wsAttempt = 0;
  Timer? _wsRetry;

  void start() {
    _connectWs();
    _periodic = Timer.periodic(const Duration(minutes: 2), (_) => syncNow());
    syncNow();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _periodic?.cancel();
    _wsRetry?.cancel();
    _wsSub?.cancel();
    _ws?.sink.close();
    store.onLocalChange = null;
    super.dispose();
  }

  void _set(SyncStatus s, [String? err]) {
    if (_disposed) return;
    status = s;
    lastError = err;
    notifyListeners();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), syncNow);
  }

  /// Coalescing: concurrent callers share one run; a call during a run causes
  /// exactly one follow-up run.
  Future<void> syncNow() async {
    if (_disposed) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        await _syncOnce();
      } while (_again && !_disposed);
      lastSynced = DateTime.now();
      _set(SyncStatus.idle);
    } on ApiException catch (e) {
      _set(SyncStatus.error, e.toString());
    } catch (e) {
      _set(SyncStatus.offline, e.toString());
    } finally {
      _running = false;
    }
  }

  Future<void> _syncOnce() async {
    _set(SyncStatus.syncing);
    // Loop until both directions are drained (handles pagination and big backlogs).
    for (var round = 0; round < 1000; round++) {
      final pending = await store.dirty(limit: 500);
      final toSend = <SyncRecord>[];
      for (final r in pending) {
        if (r.kind == 'document' && !r.deleted) {
          final ok = await _ensureBlobUploaded(r.data['sha256'] as String);
          if (!ok) continue; // retry next time; annotations can still sync
        }
        toSend.add(r);
      }
      final cursor = await store.cursor;
      final res = await api.sync(cursor, toSend);
      store.hlc.observeServerTime(res.serverTime);

      final retry =
          res.rejected.where((r) => r['reason'] == 'blob not uploaded').map((r) => '${r['kind']}/${r['id']}').toSet();
      for (final r in res.rejected) {
        debugPrint('pdfsync: server rejected ${r['kind']}/${r['id']}: ${r['reason']}');
      }
      // Accepted, stale (server had newer – it comes back in `changes`), and
      // permanently invalid records are all done from our side.
      await store.markClean(toSend.where((r) => !retry.contains(r.key)));
      await store.applyRemote(res.changes, res.cursor);

      final sentAll = toSend.length == pending.length && pending.length < 500;
      if (!res.hasMore && sentAll) return;
      if (toSend.isEmpty && !res.hasMore) return; // only blocked records left
    }
  }

  Future<bool> _ensureBlobUploaded(String sha) async {
    final key = 'uploaded:$sha';
    if (await store.getMeta<bool>(key) == true) return true;
    if (!await api.hasBlob(sha)) {
      final bytes = await blobs.get(sha);
      if (bytes == null) return false;
      await api.putBlob(sha, bytes);
    }
    await store.setMeta(key, true);
    return true;
  }

  /// Cache state belongs to this device, keyed by content hash so duplicate
  /// documents always report the same offline availability.
  Future<Map<String, bool>> cachedPdfs(Iterable<String> hashes) async {
    final entries = await Future.wait(hashes.toSet().map((sha) async => MapEntry(sha, await blobs.has(sha))));
    return Map.fromEntries(entries);
  }

  Future<void> cachePdf(String sha, Uint8List bytes) async {
    await blobs.put(sha, bytes);
    if (!_disposed) notifyListeners();
  }

  Future<bool> canRemoveCachedPdf(String sha) async => await store.getMeta<bool>('uploaded:$sha') == true;

  /// Never discard an imported PDF's only copy while it awaits upload.
  /// This removes no document, annotation, or reading-position records.
  Future<void> removeCachedPdf(String sha) async {
    if (!await canRemoveCachedPdf(sha)) {
      throw StateError('Waiting for upload. Sync this PDF before removing it from this device.');
    }
    await blobs.remove(sha);
    if (!_disposed) notifyListeners();
  }

  /// PDF bytes for a document: local cache first, otherwise download once.
  Future<Uint8List> loadPdf(String sha, {void Function(double)? onProgress}) async {
    final cached = await blobs.get(sha);
    if (cached != null) return cached;
    final Uint8List bytes;
    try {
      bytes = await api.getBlob(sha, onProgress: (got, total) {
        if (total != null && total > 0) onProgress?.call(got / total);
      });
    } catch (_) {
      throw PdfDownloadException();
    }
    await blobs.put(sha, bytes);
    await store.setMeta('uploaded:$sha', true); // server has it, obviously
    if (!_disposed) notifyListeners();
    return bytes;
  }

  // ---------- realtime ----------

  void _connectWs() {
    if (_disposed) return;
    try {
      final ch = WebSocketChannel.connect(api.wsUri());
      _ws = ch;
      // A failed handshake rejects ready as well as emitting a stream error.
      // The stream listener below schedules reconnect; consume the companion
      // Future error so going offline never creates an unhandled exception.
      unawaited(ch.ready.catchError((Object _) {}));
      _wsSub = ch.stream.listen((msg) async {
        _wsAttempt = 0;
        final m = jsonDecode(msg as String) as Map<String, dynamic>;
        final serverCursor = m['cursor'] as int? ?? 0;
        if (serverCursor > await store.cursor) syncNow();
      }, onDone: _reconnectLater, onError: (_) => _reconnectLater(), cancelOnError: true);
    } catch (_) {
      _reconnectLater();
    }
  }

  void _reconnectLater() {
    if (_disposed) return;
    _wsSub?.cancel();
    _ws = null;
    // Exponential backoff with jitter, capped at 60 s.
    final secs = min(60, pow(2, _wsAttempt++).toInt());
    _wsRetry?.cancel();
    _wsRetry = Timer(Duration(milliseconds: secs * 1000 + Random().nextInt(1000)), () {
      _connectWs();
      syncNow();
    });
  }
}
