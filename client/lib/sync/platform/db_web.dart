import 'dart:convert';
import 'dart:typed_data';

import 'package:sembast_web/sembast_web.dart';

Future<Database> openDb(String name) => databaseFactoryWeb.openDatabase(name);

/// Web: PDFs are kept in IndexedDB (via sembast) so the library works offline.
class BlobCache {
  BlobCache({this.namespace = 'blobs', this.extension = 'pdf'});
  final String namespace;
  final String extension;
  Database? _db;
  final _store = StoreRef<String, String>('blobs');

  Future<Database> _open() async => _db ??= await databaseFactoryWeb.openDatabase('pdfsync_$namespace');

  Future<bool> has(String sha) async => await _store.record(sha).exists(await _open());

  Future<Uint8List?> get(String sha) async {
    final v = await _store.record(sha).get(await _open());
    return v == null ? null : base64Decode(v);
  }

  Future<void> put(String sha, Uint8List bytes) async =>
      _store.record(sha).put(await _open(), base64Encode(bytes));

  Future<void> remove(String sha) async => _store.record(sha).delete(await _open());
}
