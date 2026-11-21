import 'package:flutter_test/flutter_test.dart';
import 'package:pdfsync/undo.dart';

void main() {
  test('undo/redo replays create, update and delete', () async {
    final store = <String, Map<String, dynamic>>{};
    final h = AnnotationHistory((id, data) async => data == null ? store.remove(id) : store[id] = data);

    await h.run(AnnEdit('a', null, {'v': 1})); // create
    await h.run(AnnEdit('a', {'v': 1}, {'v': 2})); // update
    await h.run(AnnEdit('a', {'v': 2}, null)); // delete
    expect(store, isEmpty);

    await h.undo();
    expect(store['a'], {'v': 2});
    await h.undo();
    expect(store['a'], {'v': 1});
    await h.undo();
    expect(store, isEmpty);
    expect(h.canUndo, isFalse);

    await h.redo();
    await h.redo();
    expect(store['a'], {'v': 2});

    // A new edit drops the redo branch.
    await h.run(AnnEdit('b', null, {'v': 9}));
    expect(h.canRedo, isFalse);
  });
}
