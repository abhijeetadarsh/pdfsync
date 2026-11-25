import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'record.dart';

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => 'HTTP $status: $message';
}

class SyncResponse {
  SyncResponse(this.json);
  final Map<String, dynamic> json;
  List<String> get accepted => (json['accepted'] as List).cast<String>();
  List<Map<String, dynamic>> get rejected => (json['rejected'] as List).cast<Map<String, dynamic>>();
  List<SyncRecord> get changes =>
      (json['changes'] as List).map((e) => SyncRecord.fromWire(e as Map<String, dynamic>)).toList();
  int get cursor => json['cursor'] as int;
  bool get hasMore => json['hasMore'] as bool;
  int get serverTime => json['serverTime'] as int;
}

class ApiClient {
  ApiClient(String baseUrl, {this.token, this.deviceId = ''})
      : base = Uri.parse(baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl);

  final Uri base;
  String? token;
  String deviceId;
  final _http = http.Client();

  Uri _u(String path) => base.replace(path: '${base.path}$path');

  Map<String, String> get _headers => {
        if (token != null) 'Authorization': 'Bearer $token',
        if (deviceId.isNotEmpty) 'X-Device-Id': deviceId,
      };

  Future<Map<String, dynamic>> _auth(String path, String email, String password) async {
    final res = await _http.post(_u(path),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, body['error'] as String? ?? 'error');
    }
    token = body['token'] as String;
    return body;
  }

  Future<Map<String, dynamic>> login(String email, String pw) => _auth('/api/auth/login', email, pw);
  Future<Map<String, dynamic>> register(String email, String pw) => _auth('/api/auth/register', email, pw);

  Future<void> logout() async {
    await _http.post(_u('/api/auth/logout'), headers: _headers);
  }

  Future<bool> hasBlob(String sha) async {
    final res = await _http.head(_u('/api/blobs/$sha'), headers: _headers);
    if (res.statusCode == 200) return true;
    if (res.statusCode == 404) return false;
    throw ApiException(res.statusCode, 'blob head failed');
  }

  Future<void> putBlob(String sha, Uint8List bytes) async {
    final res = await _http.put(_u('/api/blobs/$sha'),
        headers: {..._headers, 'Content-Type': 'application/pdf'}, body: bytes);
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw ApiException(res.statusCode, res.body);
    }
  }

  /// Streams the download so the UI can show progress for big PDFs.
  Future<Uint8List> getBlob(String sha, {void Function(int received, int? total)? onProgress}) async {
    final req = http.Request('GET', _u('/api/blobs/$sha'))..headers.addAll(_headers);
    final res = await _http.send(req);
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'download failed');
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in res.stream) {
      out.add(chunk);
      onProgress?.call(out.length, res.contentLength);
    }
    return out.takeBytes();
  }

  Future<Uint8List?> getThumbnail(String sha) async {
    final res =
        await _http.get(_u('/api/thumbnails/$sha'), headers: _headers).timeout(const Duration(seconds: 15));
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'thumbnail download failed');
    }
    return res.bodyBytes;
  }

  Future<void> putThumbnail(String sha, Uint8List bytes) async {
    final res = await _http
        .put(_u('/api/thumbnails/$sha'), headers: {..._headers, 'Content-Type': 'image/png'}, body: bytes)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 204) {
      throw ApiException(res.statusCode, 'thumbnail upload failed');
    }
  }

  Future<SyncResponse> sync(int cursor, List<SyncRecord> changes) async {
    final res = await _http.post(_u('/api/sync'),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'cursor': cursor, 'changes': changes.map((c) => c.toWire()).toList()}));
    if (res.statusCode != 200) throw ApiException(res.statusCode, res.body);
    return SyncResponse(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Uri wsUri() {
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return base.replace(
        scheme: scheme,
        path: '${base.path}/api/ws',
        queryParameters: {'token': token ?? '', 'device': deviceId});
  }
}
