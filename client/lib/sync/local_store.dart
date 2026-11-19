import 'dart:async';
import 'dart:math';

import 'package:sembast/sembast.dart';

import 'hlc.dart';
import 'platform/db_io.dart' if (dart.library.js_interop) 'platform/db_web.dart' as platform;
import 'record.dart';

/// Offline-first local database. The UI reads and writes only here; the sync
/// engine moves dirty records to the server in the background. Every screen
/// works without a network connection.
class LocalStore {
  LocalStore._(this._db, this.hlc, this.nodeId);

  final Database _db;
  final Hlc hlc;
  final String nodeId;
  final _records = stringMapStoreFactory.store('records');
  final _meta = StoreRef<String, Object?>('meta');

  /// Called after every local write so the sync engine can schedule a push.
  void Function()? onLocalChange;

  static Future<LocalStore> open(String accountKey) async =>
      fromDatabase(await platform.openDb('pdfsync_$accountKey.db'));

  static Future<LocalStore> fromDatabase(Database db) async {
    final meta = StoreRef<String, Object?>('meta');
    var node = await meta.record('nodeId').get(db) as String?;
    if (node == null) {
      final r = Random.secure();
      const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
      node = List.generate(10, (_) => chars[r.nextInt(chars.length)]).join();
      await meta.record('nodeId').put(db, node);
    }
    final lastHlc = await meta.record('hlc').get(db) as String?;
    return LocalStore._(db, Hlc(node, last: lastHlc), node);
  }

  Future<void> close() => _db.close();

  // ---------- meta ----------

  Future<T?> getMeta<T>(String key) async => await _meta.record(key).get(_db) as T?;
  Future<void> setMeta(String key, Object? value) => _meta.record(key).put(_db, value);

  Future<int> get cursor async => (await getMeta<int>('cursor')) ?? 0;

  // ---------- local edits ----------

  /// Create or update a record from a user action on this device.
  Future<SyncRecord> put(String kind, String id, Map<String, dynamic> data, {String docId = ''}) async {
    final r = SyncRecord(kind: kind, id: id, docId: docId, hlc: hlc.now(), data: data, dirty: true);
    await _records.record(r.key).put(_db, r.toDb());
    onLocalChange?.call();
    return r;
  }

  /// Delete = tombstone, so the deletion itself can sync and win over older edits.
  Future<void> delete(String kind, String id, {String docId = ''}) async {
    await _db.transaction((txn) async {
      await _tombstone(txn, kind, id, docId);
      if (kind == 'document') {
        // Cascade: a document's annotations and reading position go with it.
        final children = await _records.find(txn,
            finder: Finder(filter: Filter.and([Filter.equals('docId', id), Filter.equals('deleted', false)])));
        for (final c in children) {
          final r = SyncRecord.fromDb(c.value);
          await _tombstone(txn, r.kind, r.id, r.docId);
        }
      }
    });
    onLocalChange?.call();
  }

  Future<void> _tombstone(Transaction txn, String kind, String id, String docId) async {
    final r = SyncRecord(kind: kind, id: id, docId: docId, hlc: hlc.now(), deleted: true, dirty: true);
    await _records.record(r.key).put(txn, r.toDb());
  }

  // ---------- queries (live) ----------

  Stream<List<SyncRecord>> watchDocuments() => _records
      .query(
          finder: Finder(
              filter: Filter.and([Filter.equals('kind', 'document'), Filter.equals('deleted', false)]),
              sortOrders: [SortOrder('data.title')]))
      .onSnapshots(_db)
      .map((s) => s.map((e) => SyncRecord.fromDb(e.value)).toList());

  Stream<List<SyncRecord>> watchAnnotations(String docId) => _records
      .query(
          finder: Finder(
              filter: Filter.and([
        Filter.equals('kind', 'annotation'),
        Filter.equals('docId', docId),
        Filter.equals('deleted', false),
      ])))
      .onSnapshots(_db)
      .map((s) => s.map((e) => SyncRecord.fromDb(e.value)).toList());

  Stream<int> watchPendingCount() => _records
      .query(finder: Finder(filter: Filter.equals('dirty', true)))
      .onSnapshots(_db)
      .map((s) => s.length);

  Future<SyncRecord?> get(String kind, String id) async {
    final v = await _records.record('$kind/$id').get(_db);
    return v == null ? null : SyncRecord.fromDb(v);
  }

  // ---------- used by the sync engine ----------

  Future<List<SyncRecord>> dirty({int limit = 500}) async {
    final rows = await _records.find(_db,
        finder: Finder(
            filter: Filter.equals('dirty', true),
            // Documents first so their blob check happens before annotations reference them.
            sortOrders: [SortOrder('kind', false)],
            limit: limit));
    return rows.map((e) => SyncRecord.fromDb(e.value)).toList();
  }

  /// Clear the dirty flag – but only if the record wasn't edited again while
  /// the request was in flight (otherwise that newer edit must still be pushed).
  Future<void> markClean(Iterable<SyncRecord> sent) => _db.transaction((txn) async {
        for (final s in sent) {
          final ref = _records.record(s.key);
          final cur = await ref.get(txn);
          if (cur != null && cur['hlc'] == s.hlc) {
            await ref.update(txn, {'dirty': false});
          }
        }
      });

  /// Apply server changes with last-writer-wins. Returns the records that
  /// actually changed locally.
  Future<List<SyncRecord>> applyRemote(List<SyncRecord> incoming, int newCursor) async {
    final changed = <SyncRecord>[];
    await _db.transaction((txn) async {
      for (final r in incoming) {
        hlc.receive(r.hlc);
        final ref = _records.record(r.key);
        final cur = await ref.get(txn);
        if (cur == null || (cur['hlc'] as String).compareTo(r.hlc) < 0) {
          await ref.put(txn, r.toDb()); // dirty=false
          changed.add(r);
        }
        // else: local version is newer (pending push) – keep it.
      }
      await _meta.record('cursor').put(txn, newCursor);
      await _meta.record('hlc').put(txn, hlc.toString());
    });
    return changed;
  }
}
