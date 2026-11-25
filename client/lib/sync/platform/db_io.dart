import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_io.dart';

Future<Database> openDb(String name) async {
  final dir = await getApplicationSupportDirectory();
  return databaseFactoryIo.openDatabase('${dir.path}/$name');
}

/// Content-addressed PDF cache on disk: `support/blobs/SHA256.pdf`
class BlobCache {
  BlobCache({this.namespace = 'blobs', this.extension = 'pdf'});
  final String namespace;
  final String extension;
  Directory? _dir;

  Future<Directory> _root() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    _dir = await Directory('${base.path}/$namespace').create(recursive: true);
    return _dir!;
  }

  Future<File> _file(String sha) async => File('${(await _root()).path}/$sha.$extension');

  Future<bool> has(String sha) async => (await _file(sha)).exists();

  Future<Uint8List?> get(String sha) async {
    final f = await _file(sha);
    return await f.exists() ? f.readAsBytes() : null;
  }

  Future<void> put(String sha, Uint8List bytes) async {
    final f = await _file(sha);
    final tmp = File('${f.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path); // atomic: never a half-written PDF in the cache
  }

  Future<void> remove(String sha) async {
    final f = await _file(sha);
    if (await f.exists()) await f.delete();
  }
}
