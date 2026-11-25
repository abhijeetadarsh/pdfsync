import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfsync/annotations.dart';
import 'package:pdfsync/sync/api_client.dart';
import 'package:pdfsync/sync/local_store.dart';
import 'package:pdfsync/sync/platform/db_io.dart';
import 'package:pdfsync/sync/record.dart';
import 'package:pdfsync/sync/sync_engine.dart';
import 'package:pdfsync/ui/annotations_panel.dart';
import 'package:pdfsync/ui/app_theme.dart';
import 'package:pdfsync/ui/library_page.dart';
import 'package:pdfsync/ui/login_page.dart';
import 'package:sembast/sembast_memory.dart';

class _MissingBlobs extends BlobCache {
  @override
  Future<bool> has(String sha) async => false;
  @override
  Future<Uint8List?> get(String sha) async => null;
}

void main() {
  testWidgets('sign-in validation, registration and server configuration',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.build(Brightness.dark),
        home: LoginPage(onSignedIn: (_, __, ___, ____) async {
          calls++;
        })));
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    expect(calls, 0);
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'reader@lan');
    await tester.enterText(find.byType(TextFormField).last, 'short');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pumpAndSettle();
    expect(find.text('Use at least 8 characters.'), findsOneWidget);
    expect(find.text('Enter your email address.'), findsNothing);
    await tester.ensureVisible(find.text('Change server'));
    await tester.tap(find.text('Change server'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, 'invalid');
    await tester.tap(find.text('Use server'));
    await tester.pumpAndSettle();
    expect(find.text('Enter an http or https server address.'), findsOneWidget);
    await tester.enterText(
        find.byType(TextFormField).last, 'https://sync.example.com');
    await tester.tap(find.text('Use server'));
    await tester.pumpAndSettle();
    expect(find.text('https://sync.example.com'), findsOneWidget);
    await tester.tap(find.text('Already have an account? Sign in'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, 'long-password');
    String? submittedEmail;
    await http.runWithClient(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();
    },
        () => MockClient((request) async {
              submittedEmail =
                  (jsonDecode(request.body) as Map)['email'] as String;
              return http.Response(
                  jsonEncode({'token': 'test-token', 'userId': 'test-user'}),
                  200);
            }));
    expect(submittedEmail, 'reader@lan');
    expect(calls, 1);
  });

  testWidgets('library breakpoints, real reading filters, search and recovery',
      (tester) async {
    late LocalStore store;
    late SyncEngine engine;
    await tester.runAsync(() async {
      store = await LocalStore.fromDatabase(
          await databaseFactoryMemory.openDatabase('ui-library'));
      engine = SyncEngine(store, ApiClient('http://localhost:1'),
          blobs: _MissingBlobs());
      await store.put('document', 'reading', {
        'title': 'Reading book with a long descriptive title',
        'sha256': 'a',
        'pageCount': 100
      });
      await store.put('document', 'finished',
          {'title': 'Finished book', 'sha256': 'b', 'pageCount': 20});
      await store.put('document', 'new',
          {'title': 'New book', 'sha256': 'c', 'pageCount': 50});
      await store.put('readstate', 'reading', {'page': 23});
      await store.put('readstate', 'finished', {'page': 20});
    });
    addTearDown(() async {
      engine.dispose();
      await tester.runAsync(store.close);
    });
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    for (final size in [
      const Size(390, 844),
      const Size(844, 390),
      const Size(768, 1024),
      const Size(1024, 768),
      const Size(1440, 900),
      const Size(1440, 390)
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.build(Brightness.dark),
          home: LibraryPage(
              engine: engine, email: 'reader@example.com', onLogout: () {})));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'layout at $size');
    }
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finished · 1'));
    await tester.pumpAndSettle();
    expect(find.text('Finished book'), findsOneWidget);
    expect(find.text('New book'), findsNothing);
    await tester.tap(find.text('All · 3'));
    await tester.enterText(find.byType(TextField), 'no-such-document');
    await tester.pumpAndSettle();
    expect(find.text('No documents found.'), findsOneWidget);
    await tester.tap(find.text('Show all documents'));
    await tester.pumpAndSettle();
    expect(find.text('Continue reading'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'live annotations support filtering, page navigation and Markdown',
      (tester) async {
    final note = Ann(SyncRecord(kind: 'annotation', id: 'note', hlc: '', data: {
      'type': 'note',
      'page': 12,
      'color': 0xFFA6E3A1,
      'text': 'Remember this',
      'pos': [.2, .3]
    }));
    final highlight =
        Ann(SyncRecord(kind: 'annotation', id: 'hl', hlc: '', data: {
      'type': 'highlight',
      'page': 19,
      'color': 0xFFF9E2AF,
      'text': 'Selected words',
      'rects': [
        [.1, .1, .4, .02]
      ]
    }));
    final anns = ValueNotifier<Map<int, List<Ann>>>({
      12: [note],
      19: [highlight]
    });
    Ann? visited;
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.build(Brightness.dark),
        home: Scaffold(
            body: SizedBox(
                width: 320,
                child: AnnotationsPanel(
                    annotations: anns,
                    documentTitle: 'Test PDF',
                    onGoTo: (a) => visited = a,
                    onEdit: (_) {},
                    onDelete: (_) {},
                    onClose: () {})))));
    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(find.text('Selected words'), findsNothing);
    await tester.tap(find.text('Remember this'));
    expect(visited?.page, 12);
    await tester.tap(find.text('Copy as Markdown'));
    await tester.pumpAndSettle();
    expect(copied, contains('Selected words'));
    expect(copied, contains('Page 12'));
    anns.value = {};
    await tester.pumpAndSettle();
    expect(find.text('Your highlights, notes and drawings will appear here.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    anns.dispose();
  });
}
