// Runs two client sync engines (two "devices" of one account) against a real
// pdfsync server binary. Build the server first:
//   (cd ../server && go build -o /tmp/pdfsync-server .)
// then: PDFSYNC_SERVER_BIN=/tmp/pdfsync-server flutter test test/sync_integration_test.dart
import 'dart:io';
import 'dart:convert';
import 'package:pdfsync/sync/thumbnails.dart';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfsync/sync/api_client.dart';
import 'package:pdfsync/sync/local_store.dart';
import 'package:pdfsync/sync/platform/db_io.dart';
import 'package:pdfsync/sync/sync_engine.dart';
import 'package:sembast/sembast_memory.dart';

class MemBlobCache extends BlobCache {
  final m = <String, Uint8List>{};
  @override
  Future<bool> has(String sha) async => m.containsKey(sha);
  @override
  Future<Uint8List?> get(String sha) async => m[sha];
  @override
  Future<void> put(String sha, Uint8List bytes) async => m[sha] = bytes;
  @override
  Future<void> remove(String sha) async => m.remove(sha);
}

int _dbn = 0;
Future<SyncEngine> device(String url, String token) async {
  final db = await databaseFactoryMemory.openDatabase('dev${_dbn++}');
  final store = await LocalStore.fromDatabase(db);
  return SyncEngine(store, ApiClient(url, token: token), blobs: MemBlobCache());
}

Future<void> eventually(Future<bool> Function() cond, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (await cond()) return;
    await Future.delayed(const Duration(milliseconds: 50));
  }
  fail('condition not met within $timeout');
}

void main() {
  late Process server;
  late String url;
  late Directory data;

  setUpAll(() async {
    final bin = Platform.environment['PDFSYNC_SERVER_BIN'] ?? '/tmp/pdfsync-server';
    data = await Directory.systemTemp.createTemp('pdfsync');
    const port = 18765;
    url = 'http://127.0.0.1:$port';
    server = await Process.start(bin, ['-addr', '127.0.0.1:$port', '-data', data.path]);
    server.stderr.listen((_) {});
    await eventually(() async {
      try {
        final c = HttpClient();
        final r = await (await c.getUrl(Uri.parse('$url/healthz'))).close();
        c.close();
        return r.statusCode == 200;
      } catch (_) {
        return false;
      }
    });
  });

  tearDownAll(() async {
    server.kill();
    await data.delete(recursive: true);
  });

  test('two devices converge: docs, blobs, annotations, conflicts, deletes, realtime', () async {
    final auth = await ApiClient(url).register('dev@x.io', 'password123');
    final token = auth['token'] as String;
    final laptop = await device(url, token);
    final phone = await device(url, token);

    // --- laptop adds a PDF and a highlight while "offline" (no sync yet)
    final pdf = Uint8List.fromList('%PDF-1.7 pretend this is a real pdf'.codeUnits);
    final sha = sha256.convert(pdf).toString();
    await laptop.blobs.put(sha, pdf);
    await laptop.store.put('document', 'doc1', {'title': 'Thesis', 'sha256': sha, 'size': pdf.length}, docId: 'doc1');
    await laptop.store.put('annotation', 'h1', {'page': 1, 'type': 'highlight', 'color': 0xFFFFEB3B, 'rects': [[0.1, 0.1, 0.3, 0.02]]}, docId: 'doc1');
    // The only copy cannot be removed until its upload is confirmed.
    await expectLater(laptop.removeCachedPdf(sha), throwsStateError);
    expect(await laptop.blobs.has(sha), isTrue);
    await laptop.syncNow();
    expect(laptop.status, SyncStatus.idle, reason: laptop.lastError);
    expect(await laptop.store.dirty(), isEmpty);

    // --- phone pulls metadata, then lazily downloads the PDF bytes on open
    await phone.syncNow();
    expect((await phone.store.get('document', 'doc1'))!.data['title'], 'Thesis');
    expect((await phone.store.get('annotation', 'h1'))!.data['page'], 1);
    expect(await phone.loadPdf(sha), pdf);

    // Eviction changes only this device's PDF bytes. Metadata and annotations
    // remain, and reopening downloads the server copy again.
    await phone.store.put('readstate', 'doc1', {'page': 2}, docId: 'doc1');
    await phone.removeCachedPdf(sha);
    expect(await phone.blobs.has(sha), isFalse);
    expect(await laptop.blobs.has(sha), isTrue);
    expect((await phone.store.get('document', 'doc1'))!.deleted, isFalse);
    expect((await phone.store.get('annotation', 'h1'))!.deleted, isFalse);
    expect((await phone.store.get('readstate', 'doc1'))!.data['page'], 2);
    expect(await phone.loadPdf(sha), pdf);
    expect(await phone.blobs.has(sha), isTrue);

    // --- realtime: phone listens on the WebSocket; laptop draws; phone gets it with no manual sync
    phone.start();
    await Future.delayed(const Duration(milliseconds: 300));
    await laptop.store.put('annotation', 'ink1', {'page': 2, 'type': 'ink', 'color': 0xFF000000, 'points': [0.1, 0.1, 0.2, 0.2]}, docId: 'doc1');
    await laptop.syncNow();
    await eventually(() async => await phone.store.get('annotation', 'ink1') != null);

    // --- conflict: both edit h1; the later edit wins on BOTH devices
    await laptop.store.put('annotation', 'h1', {'page': 1, 'type': 'highlight', 'color': 0xFFFF0000, 'rects': [[0.1, 0.1, 0.3, 0.02]]}, docId: 'doc1');
    await Future.delayed(const Duration(milliseconds: 5));
    await phone.store.put('annotation', 'h1', {'page': 1, 'type': 'highlight', 'color': 0xFF00FF00, 'rects': [[0.1, 0.1, 0.3, 0.02]]}, docId: 'doc1');
    await phone.syncNow();
    await laptop.syncNow(); // laptop's older edit loses; it receives the phone's
    await phone.syncNow();
    expect((await laptop.store.get('annotation', 'h1'))!.data['color'], 0xFF00FF00);
    expect((await phone.store.get('annotation', 'h1'))!.data['color'], 0xFF00FF00);

    // --- delete the document on the phone: cascades to its annotations on the laptop
    await phone.store.delete('document', 'doc1', docId: 'doc1');
    await phone.syncNow();
    await laptop.syncNow();
    expect((await laptop.store.get('document', 'doc1'))!.deleted, isTrue);
    expect((await laptop.store.get('annotation', 'h1'))!.deleted, isTrue);
    expect((await laptop.store.get('annotation', 'ink1'))!.deleted, isTrue);

    // --- a third device starting from zero gets the same final state
    final tablet = await device(url, token);
    await tablet.syncNow();
    expect(await tablet.store.watchDocuments().first, isEmpty);

    phone.dispose();
  });
  test('two devices transfer a thumbnail without downloading its PDF', () async {
    final auth = await ApiClient(url).register('thumbnail@x.io', 'password123');
    final laptop = await device(url, auth['token'] as String);
    final phone = await device(url, auth['token'] as String);
    final pdf = Uint8List.fromList('thumbnail test PDF'.codeUnits);
    final sha = sha256.convert(pdf).toString();
    final image = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNocDjwHwAFRAKAb2WvNQAAAABJRU5ErkJggg==');
    // Use an isolated preview cache as a second simulated device would.
    final upload = ThumbnailService(laptop.store, laptop.api, laptop.blobs, cache: MemBlobCache());
    final download = ThumbnailService(phone.store, phone.api, phone.blobs, cache: MemBlobCache());
    await laptop.cachePdf(sha, pdf);
    await laptop.store.put('document', 'preview-doc', {'title': 'Preview', 'sha256': sha}, docId: 'preview-doc');
    await laptop.store.put('annotation', 'preview-note', {'page': 1, 'type': 'note'}, docId: 'preview-doc');
    await laptop.syncNow();
    await upload.saveGenerated(sha, image);
    await upload.uploadPending();
    expect(await laptop.store.getMeta<bool>('thumbnailUploaded:$sha'), isTrue);
    await phone.syncNow();
    expect(await phone.store.get('document', 'preview-doc'), isNotNull);
    expect(await phone.store.get('annotation', 'preview-note'), isNotNull);
    expect(await download.load(sha), image);
    expect(await phone.blobs.has(sha), isFalse);
    upload.dispose();
    download.dispose();
    laptop.dispose();
    phone.dispose();
  });

}
