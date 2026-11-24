import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfsync/sync/api_client.dart';
import 'package:pdfsync/sync/local_store.dart';
import 'package:pdfsync/sync/sync_engine.dart';
import 'package:pdfsync/ui/library_page.dart';
import 'package:pdfsync/ui/app_theme.dart';
import 'package:sembast/sembast_memory.dart';

import 'sync_integration_test.dart' show MemBlobCache;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Optional real fonts make local preview captures useful without adding
  // binary font fixtures to the repository.
  setUpAll(() async {
    final fontDir = Platform.environment['PDFSYNC_TEST_FONT_DIR'];
    if (fontDir != null) {
      for (final entry in {'Roboto': 'Roboto-Regular.ttf', 'MaterialIcons': 'MaterialIcons-Regular.otf'}.entries) {
        final loader = FontLoader(entry.key)
          ..addFont(File('$fontDir/${entry.value}').readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
        await loader.load();
      }
    }
  });
  late SyncEngine engine;
  late LocalStore store;
  var sequence = 0;
  setUp(() async {
    store = await LocalStore.fromDatabase(await databaseFactoryMemory.openDatabase('cache-${sequence++}'));
    engine = SyncEngine(store, ApiClient('http://127.0.0.1:1'), blobs: MemBlobCache());
    store.onLocalChange = null;
  });
  tearDown(() async {
    engine.dispose();
    await store.close();
  });

  Future<void> add(String id, String sha, {bool cached = true, bool uploaded = true}) async {
    await store.put('document', id, {'title': id, 'sha256': sha, 'pageCount': 10, 'size': 100}, docId: id);
    if (cached) await engine.cachePdf(sha, Uint8List(0));
    if (uploaded) await store.setMeta('uploaded:$sha', true);
  }

  test('unsynced copies are protected and cache notifications share content hashes', () async {
    await add('First', 'shared', uploaded: false);
    await add('Duplicate', 'shared', uploaded: false);
    expect(await engine.canRemoveCachedPdf('shared'), isFalse);
    expect(await engine.loadPdf('shared'), isEmpty); // Works offline before upload, too.
    await expectLater(engine.removeCachedPdf('shared'), throwsStateError);
    expect(await engine.cachedPdfs(['shared', 'shared', 'remote']), {'shared': true, 'remote': false});
    await store.put('annotation', 'note', {'page': 1}, docId: 'First');
    await store.put('readstate', 'First', {'page': 3}, docId: 'First');
    await store.setMeta('uploaded:shared', true);
    var changes = 0;
    engine.addListener(() => changes++);
    await engine.removeCachedPdf('shared');
    expect(changes, 1);
    expect(await engine.cachedPdfs(['shared']), {'shared': false});
    expect((await store.watchDocuments().first).length, 2);
    expect((await store.get('annotation', 'note'))!.deleted, isFalse);
    expect((await store.get('readstate', 'First'))!.data['page'], 3);
    await engine.cachePdf('shared', Uint8List(0));
    expect(changes, 2);
  });

  test('failed WebSocket handshakes do not escape as unhandled errors', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final rejected = Completer<void>();
    server.listen((request) async {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      if (request.uri.path == '/api/ws' && !rejected.isCompleted) rejected.complete();
    });
    addTearDown(() => server.close(force: true));
    engine.dispose();
    engine = SyncEngine(store, ApiClient('http://127.0.0.1:${server.port}'), blobs: MemBlobCache());
    engine.start();
    await rejected.future.timeout(const Duration(seconds: 3));
    // Drain both the stream error and the connection's ready Future.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('an uncached PDF gives a recoverable download error', () async {
    await expectLater(engine.loadPdf('remote'), throwsA(isA<PdfDownloadException>()));
    expect(await engine.blobs.has('remote'), isFalse);
  });

  for (final size in [const Size(390, 844), const Size(844, 390), const Size(800, 1280), const Size(1280, 800)]) {
    for (final largeDark in [false, true]) {
      testWidgets('offline controls at ${size.width}x${size.height}, large dark text: $largeDark', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          await add('First PDF', 'shared');
          await add('Duplicate PDF', 'shared');
          await add('Upload pending', 'pending', uploaded: false);
          await add('Remote PDF', 'remote', cached: false);
        });
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
            key: boundaryKey,
            child: MaterialApp(
              theme: AppTheme.build(largeDark ? Brightness.dark : Brightness.light),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(largeDark ? 1.3 : 1)),
                child: child!,
              ),
              home: LibraryPage(engine: engine, email: 'reader@example.com', onLogout: () {}),
            )));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('Available offline'), findsWidgets);
        final offlineFilter =
            size.width >= 760 ? find.text('Offline') : find.textContaining(RegExp(r'^Available offline')).first;
        if (size.width >= 760 && size.height < 500) {
          await tester.drag(find.byType(ListView).first, const Offset(0, -200));
        } else {
          await tester.ensureVisible(offlineFilter);
        }
        await tester.pumpAndSettle();
        await tester.tap(offlineFilter);
        await tester.pumpAndSettle();
        expect(find.text('Remote PDF'), findsNothing);
        await tester.ensureVisible(find.byTooltip('Document actions').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Document actions').first);
        // List rows also recognize double-taps; allow their gesture window to close.
        await tester.pump(const Duration(milliseconds: 350));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pumpAndSettle();
        expect(find.text('Remove from this device'), findsOneWidget);
        expect(find.text('Delete everywhere'), findsOneWidget);
        if (Platform.environment['PDFSYNC_CAPTURE_WIDGETS'] == '1') {
          await tester.runAsync(() async {
            final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
                    '/tmp/pdfsync-cache-${size.width.toInt()}x${size.height.toInt()}-${largeDark ? 'dark-large' : 'light'}.png')
                .writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(find.text('Remove from this device'));
        await tester.pumpAndSettle();
        expect(await engine.blobs.has('shared'), isFalse);
        expect(find.text('First PDF'), findsNothing);
        expect(find.text('Duplicate PDF'), findsNothing);
        expect(find.text('Upload pending'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byTooltip('Document actions').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Document actions').first);
        // List rows also recognize double-taps; allow their gesture window to close.
        await tester.pump(const Duration(milliseconds: 350));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pumpAndSettle();
        expect(find.text('Waiting for upload'), findsOneWidget);
        final action = tester.widget<ListTile>(find.widgetWithText(ListTile, 'Remove from this device'));
        expect(action.enabled, isFalse);
        expect(action.onTap, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
