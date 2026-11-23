import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sembast/sembast.dart';

import 'perf.dart';
import 'sync/api_client.dart';
import 'sync/local_store.dart';
import 'sync/platform/db_io.dart'
    if (dart.library.js_interop) 'sync/platform/db_web.dart' as platform;
import 'sync/sync_engine.dart';
import 'ui/library_page.dart';
import 'ui/app_theme.dart';
import 'ui/login_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  startPerfLog();
  pdfrxFlutterInitialize(); // we open PdfDocument directly (page counts) before any viewer exists
  runApp(const PdfSyncApp());
}

class PdfSyncApp extends StatefulWidget {
  const PdfSyncApp({super.key});
  @override
  State<PdfSyncApp> createState() => _PdfSyncAppState();
}

class _PdfSyncAppState extends State<PdfSyncApp> with WidgetsBindingObserver {
  final _session = StoreRef<String, Object?>('session');
  Database? _sessionDb;
  SyncEngine? _engine;
  String? _email;
  String? _lastServer;
  bool _loading = true;
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restore();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _engine?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the foreground: catch up immediately (sockets are often
    // killed in the background on mobile).
    if (state == AppLifecycleState.resumed) _engine?.syncNow();
  }

  Future<void> _restore() async {
    _sessionDb = await platform.openDb('pdfsync_session.db');
    final appearance =
        await _session.record('appearance').get(_sessionDb!) as String?;
    _themeMode = ThemeMode.values
        .firstWhere((m) => m.name == appearance, orElse: () => ThemeMode.dark);
    final s = await _session.record('current').get(_sessionDb!) as Map?;
    _lastServer =
        await _session.record('lastServer').get(_sessionDb!) as String?;
    if (s != null) {
      await _startEngine(s['server'] as String, s['email'] as String,
          s['token'] as String, s['userId'] as String);
    }
    setState(() => _loading = false);
  }

  Future<void> _startEngine(
      String server, String email, String token, String userId) async {
    // One local DB per account+server, so switching accounts never mixes data.
    final key =
        '${userId}_${sha1.convert(utf8.encode(server)).toString().substring(0, 8)}';
    final store = await LocalStore.open(key);
    final engine = SyncEngine(store, ApiClient(server, token: token))..start();
    setState(() {
      _engine = engine;
      _email = email;
    });
  }

  Future<void> _signedIn(
      String server, String email, String token, String userId) async {
    await _session.record('current').put(_sessionDb!,
        {'server': server, 'email': email, 'token': token, 'userId': userId});
    await _session.record('lastServer').put(_sessionDb!, server);
    _lastServer = server;
    await _startEngine(server, email, token, userId);
  }

  Future<void> _logout() async {
    final e = _engine;
    setState(() => _engine = null);
    if (e != null) {
      try {
        await e.api.logout();
      } catch (_) {}
      e.dispose();
      await e.store.close();
    }
    await _session.record('current').delete(_sessionDb!);
  }

  void _setTheme(ThemeMode mode) {
    setState(() => _themeMode = mode);
    _session.record('appearance').put(_sessionDb!, mode.name);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF Sync',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(Brightness.light),
      darkTheme: AppTheme.build(Brightness.dark),
      themeMode: _themeMode,
      home: _loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _engine == null
              ? LoginPage(onSignedIn: _signedIn, initialServer: _lastServer)
              : LibraryPage(
                  engine: _engine!,
                  email: _email ?? '',
                  onLogout: _logout,
                  themeMode: _themeMode,
                  onThemeChanged: _setTheme),
    );
  }
}
