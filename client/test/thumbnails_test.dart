import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfsync/sync/api_client.dart';
import 'package:pdfsync/sync/local_store.dart';
import 'package:pdfsync/sync/sync_engine.dart';
import 'package:pdfsync/sync/thumbnails.dart';
import 'package:pdfsync/ui/app_theme.dart';
import 'package:pdfsync/ui/library_page.dart';
import 'package:sembast/sembast_memory.dart';

import 'sync_integration_test.dart' show MemBlobCache;

final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNocDjwHwAFRAKAb2WvNQAAAABJRU5ErkJggg==');

class ThumbnailApi extends ApiClient {
  ThumbnailApi() : super('http://127.0.0.1:1');
  final gets = <String>[];
  final puts = <String>[];
  Uint8List? remote;
  bool failUpload = false;
  int active = 0;
  int peak = 0;
  Completer<void>? gate;
  @override
  Future<Uint8List?> getThumbnail(String sha) async {
    gets.add(sha);
    active++;
    if (active > peak) peak = active;
    await gate?.future;
    active--;
    return remote;
  }

  @override
  Future<void> putThumbnail(String sha, Uint8List bytes) async {
    puts.add(sha);
    if (failUpload) throw ApiException(503, 'retry');
  }

  @override
  Future<bool> hasBlob(String sha) async => true;
  @override
  Future<Uint8List> getBlob(String sha,
          {void Function(int, int?)? onProgress}) async =>
      throw StateError('Thumbnails must never download PDFs');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late MemBlobCache pdfs;
  late MemBlobCache cache;
  late ThumbnailApi api;
  late ThumbnailService thumbnails;
  var sequence = 0;
  var rendered = 0;
  setUp(() async {
    store = await LocalStore.fromDatabase(
        await databaseFactoryMemory.openDatabase('thumb-${sequence++}'));
    pdfs = MemBlobCache();
    cache = MemBlobCache();
    api = ThumbnailApi();
    rendered = 0;
    thumbnails =
        ThumbnailService(store, api, pdfs, cache: cache, render: (_) async {
      rendered++;
      return png;
    });
  });
  tearDown(() async {
    thumbnails.dispose();
    await store.close();
  });

  test('remote thumbnail persists independently of PDF bytes', () async {
    api.remote = png;
    expect(await thumbnails.load('sha'), png);
    expect(await thumbnails.load('sha'), png);
    expect(api.gets, ['sha']);
    expect(pdfs.m, isEmpty);
    expect(rendered, 0);
    final reopened = ThumbnailService(store, api, pdfs, cache: cache);
    expect(await reopened.load('sha'), png);
    expect(api.gets, ['sha']);
    reopened.dispose();
  });

  test('missing thumbnail without local PDF stays a placeholder', () async {
    expect(await thumbnails.load('old'), isNull);
    expect(await thumbnails.load('old'), isNull);
    expect(api.gets, ['old']);
    thumbnails.retryMissing('old');
    expect(await thumbnails.load('old'), isNull);
    expect(api.gets, ['old', 'old']);
    expect(rendered, 0);
    expect(pdfs.m, isEmpty);
    expect(cache.m, isEmpty);
  });

  test('legacy cached PDF repairs and retries upload without blocking sync',
      () async {
    await store.put('document', 'doc', {'sha256': 'old'});
    await pdfs.put('old', Uint8List(10));
    expect(await thumbnails.load('old'), png);
    expect(rendered, 1);
    expect(await store.getMeta<bool>('thumbnailUploaded:old'), isFalse);
    api.failUpload = true;
    await thumbnails.uploadPending();
    expect(await store.getMeta<bool>('thumbnailUploaded:old'), isFalse);
    api.failUpload = false;
    await thumbnails.uploadPending();
    expect(await store.getMeta<bool>('thumbnailUploaded:old'), isTrue);
    await thumbnails.uploadPending();
    expect(api.puts, ['old', 'old']);
  });

  test('prepare renders local bytes without a thumbnail network request',
      () async {
    await pdfs.put('imported', Uint8List(10));
    await thumbnails.prepare('imported');
    expect(rendered, 1);
    expect(api.gets, isEmpty);
    expect(await cache.get('imported'), png);
  });

  test('concurrent loads are coalesced and limited to three', () async {
    api.remote = png;
    api.gate = Completer<void>();
    final first = thumbnails.load('same');
    final duplicate = thumbnails.load('same');
    final tasks = [for (var i = 0; i < 10; i++) thumbnails.load('$i')];
    await Future<void>.delayed(Duration.zero);
    expect(api.peak, 3);
    expect(api.gets.where((s) => s == 'same').length, 1);
    api.gate!.complete();
    await Future.wait([first, duplicate, ...tasks]);
    expect(api.peak, 3);
    expect(api.gets.length, 11);
  });

  test(
      'a thumbnail notification during a missing response permits immediate retry',
      () async {
    api.gate = Completer<void>();
    final missing = thumbnails.load('late');
    await Future<void>.delayed(Duration.zero);
    thumbnails.retryMissing('late');
    api.gate!.complete();
    expect(await missing, isNull);
    api.remote = png;
    expect(await thumbnails.load('late'), png);
    expect(api.gets, ['late', 'late']);
  });

  test('removing an offline PDF preserves the thumbnail and annotations',
      () async {
    api.remote = png;
    await thumbnails.load('sha');
    await pdfs.put('sha', Uint8List(10));
    await store.setMeta('uploaded:sha', true);
    await store.put('annotation', 'note', {'page': 1}, docId: 'doc');
    final engine = SyncEngine(store, api, blobs: pdfs, thumbnails: thumbnails);
    store.onLocalChange = null;
    await engine.removeCachedPdf('sha');
    expect(await pdfs.has('sha'), isFalse);
    expect(await thumbnails.load('sha'), png);
    expect((await store.get('annotation', 'note'))!.deleted, isFalse);
    engine.dispose();
  });

  testWidgets(
      'only visible library covers fetch previews, scrolling loads more',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      for (var i = 0; i < 30; i++) {
        await store.put('document', 'doc$i', {
          'title': 'Document ${i.toString().padLeft(2, '0')}',
          'sha256': 'sha$i'
        });
      }
    });
    api.remote = png;
    final engine = SyncEngine(store, api, blobs: pdfs, thumbnails: thumbnails);
    store.onLocalChange = null;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.build(Brightness.light),
        home: LibraryPage(
            engine: engine, email: 'test@example.com', onLogout: () async {})));
    await tester.pumpAndSettle();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
    final before = api.gets.toSet();
    expect(before, isNotEmpty);
    expect(find.byType(Image), findsWidgets);
    expect(before.length, lessThan(30));
    expect(before.contains('sha29'), isFalse);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -650));
    await tester.pumpAndSettle();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
    expect(api.gets.toSet().difference(before), isNotEmpty);
    expect(pdfs.m, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    engine.dispose();
  });
}
