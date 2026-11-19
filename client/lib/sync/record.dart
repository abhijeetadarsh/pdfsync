/// A synced object. Kinds: `document`, `annotation`, `readstate`, `folder`.
class SyncRecord {
  SyncRecord({
    required this.kind,
    required this.id,
    required this.hlc,
    this.docId = '',
    this.deleted = false,
    Map<String, dynamic>? data,
    this.dirty = false,
  }) : data = data ?? const {};

  final String kind;
  final String id;
  final String docId;
  final String hlc;
  final bool deleted;
  final Map<String, dynamic> data;

  /// Local-only: changed on this device and not yet acknowledged by the server.
  final bool dirty;

  String get key => '$kind/$id';

  Map<String, dynamic> toWire() => {
        'kind': kind,
        'id': id,
        if (docId.isNotEmpty) 'docId': docId,
        'hlc': hlc,
        if (deleted) 'deleted': true,
        if (!deleted) 'data': data,
      };

  factory SyncRecord.fromWire(Map<String, dynamic> j) => SyncRecord(
        kind: j['kind'] as String,
        id: j['id'] as String,
        docId: (j['docId'] as String?) ?? '',
        hlc: j['hlc'] as String,
        deleted: (j['deleted'] as bool?) ?? false,
        data: (j['data'] as Map?)?.cast<String, dynamic>() ?? const {},
      );

  Map<String, Object?> toDb() => {
        'kind': kind,
        'id': id,
        'docId': docId,
        'hlc': hlc,
        'deleted': deleted,
        'data': data,
        'dirty': dirty,
      };

  factory SyncRecord.fromDb(Map<String, Object?> m) => SyncRecord(
        kind: m['kind'] as String,
        id: m['id'] as String,
        docId: (m['docId'] as String?) ?? '',
        hlc: m['hlc'] as String,
        deleted: (m['deleted'] as bool?) ?? false,
        data: (m['data'] as Map?)?.cast<String, dynamic>() ?? const {},
        dirty: (m['dirty'] as bool?) ?? false,
      );
}
