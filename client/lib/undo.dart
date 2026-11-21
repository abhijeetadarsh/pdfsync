import 'package:flutter/foundation.dart';

/// One reversible change to a single annotation record.
/// `before == null` means the record did not exist (a create);
/// `after == null` means it was deleted.
class AnnEdit {
  AnnEdit(this.id, this.before, this.after);
  final String id;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;
}

/// Per-document, per-session undo/redo for annotation edits.
///
/// Undo and redo are ordinary synced writes (a put or a delete with a fresh
/// timestamp), so they propagate to other devices like any other edit, and
/// restoring a deleted annotation under its old id wins over the tombstone.
class AnnotationHistory extends ChangeNotifier {
  AnnotationHistory(this._apply, {this.limit = 200});

  /// Writes [data] for annotation [id], or deletes it when [data] is null.
  final Future<void> Function(String id, Map<String, dynamic>? data) _apply;
  final int limit;

  final List<AnnEdit> _undo = [];
  final List<AnnEdit> _redo = [];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Applies [edit] and records it. A new edit clears the redo stack.
  Future<void> run(AnnEdit edit) async {
    await _apply(edit.id, edit.after);
    _undo.add(edit);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
    notifyListeners();
  }

  Future<void> undo() async {
    if (_undo.isEmpty) return;
    final e = _undo.removeLast();
    _redo.add(e);
    notifyListeners();
    await _apply(e.id, e.before);
  }

  Future<void> redo() async {
    if (_redo.isEmpty) return;
    final e = _redo.removeLast();
    _undo.add(e);
    notifyListeners();
    await _apply(e.id, e.after);
  }
}
