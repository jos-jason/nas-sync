import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A failed request to the server.
class PbException implements Exception {
  final int status;
  final String message;
  final Map<String, dynamic> data;

  PbException(this.status, this.message, [this.data = const {}]);

  /// The server rejected a value as a duplicate (e.g. the same item key twice).
  bool get isNotUnique => data.values.any((v) => v is Map && v['code'] == 'validation_not_unique');

  /// The login is missing, expired or revoked.
  bool get isAuth => status == 401 || status == 403;

  @override
  String toString() => 'PbException($status): $message${data.isEmpty ? '' : ' $data'}';
}

/// Who is signed in.
class PbAuth {
  final String token;
  final String userId;
  final String email;

  const PbAuth({required this.token, required this.userId, required this.email});

  Map<String, dynamic> toJson() => {'token': token, 'userId': userId, 'email': email};

  factory PbAuth.fromJson(Map<String, dynamic> j) =>
      PbAuth(token: j['token'] as String, userId: j['userId'] as String, email: j['email'] as String? ?? '');
}

/// The few PocketBase calls the sync engine needs, on the `sync_items`
/// collection made by `server/pb_migrations`.
class PbClient {
  static const collection = 'sync_items';
  static const pageSize = 200;

  final Uri base;
  final http.Client _http;
  PbAuth? auth;

  /// How long one request may take before giving up (large files count).
  final Duration timeout;

  PbClient(String baseUrl, {http.Client? httpClient, this.auth, this.timeout = const Duration(minutes: 2)})
      : base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'),
        _http = httpClient ?? http.Client();

  void close() => _http.close();

  Uri _url(String path, [Map<String, String>? query]) => base.resolve(path).replace(queryParameters: query);

  Map<String, String> get _headers => {if (auth != null) 'Authorization': auth!.token};

  Future<dynamic> _send(http.BaseRequest req) async {
    req.headers.addAll(_headers);
    final res = await http.Response.fromStream(await _http.send(req).timeout(timeout)).timeout(timeout);
    final body = res.body.isEmpty ? null : _tryJson(res.body);
    if (res.statusCode >= 200 && res.statusCode < 300) return body;
    final map = body is Map<String, dynamic> ? body : const <String, dynamic>{};
    throw PbException(
      res.statusCode,
      map['message'] as String? ?? res.reasonPhrase ?? 'HTTP ${res.statusCode}',
      (map['data'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  static dynamic _tryJson(String s) {
    try {
      return jsonDecode(s);
    } on FormatException {
      return s;
    }
  }

  Future<dynamic> _json(String method, String path, [Object? body, Map<String, String>? query]) {
    final req = http.Request(method, _url(path, query));
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    return _send(req);
  }

  PbAuth _authFrom(Map<String, dynamic> j) {
    final rec = j['record'] as Map<String, dynamic>;
    return auth = PbAuth(token: j['token'] as String, userId: rec['id'] as String, email: rec['email'] as String? ?? '');
  }

  /// Signs in with an account made in the admin page.
  Future<PbAuth> signIn(String email, String password) async => _authFrom(
      await _json('POST', 'api/collections/users/auth-with-password', {'identity': email, 'password': password}));

  /// Swaps the current token for a fresh one (keeps a device signed in).
  Future<PbAuth> refresh() async => _authFrom(await _json('POST', 'api/collections/users/auth-refresh'));

  /// Items of [app] changed at or after [since] (a server `updated` stamp), oldest first.
  Future<List<Map<String, dynamic>>> listSince(String app, String? since) async {
    var filter = 'app = ${_quote(app)}';
    if (since != null) filter += ' && updated >= ${_quote(since)}';
    final out = <Map<String, dynamic>>[];
    for (var page = 1;; page++) {
      final res = await _json('GET', 'api/collections/$collection/records', null, {
        'filter': filter,
        'sort': 'updated,id',
        'page': '$page',
        'perPage': '$pageSize',
        'skipTotal': '1',
      }) as Map<String, dynamic>;
      final items = (res['items'] as List).cast<Map<String, dynamic>>();
      out.addAll(items);
      if (items.length < pageSize) return out;
    }
  }

  /// One item, or null if it no longer exists.
  Future<Map<String, dynamic>?> getRecord(String id) async {
    try {
      return await _json('GET', 'api/collections/$collection/records/$id') as Map<String, dynamic>;
    } on PbException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// Creates (no [id]) or updates an item. [blob] replaces the file;
  /// [clearBlob] removes it.
  Future<Map<String, dynamic>> saveRecord({
    String? id,
    required Map<String, dynamic> fields,
    Uint8List? blob,
    bool clearBlob = false,
  }) async {
    final path = 'api/collections/$collection/records${id == null ? '' : '/$id'}';
    final method = id == null ? 'POST' : 'PATCH';
    if (blob == null) {
      return await _json(method, path, {...fields, if (clearBlob) 'blob': null}) as Map<String, dynamic>;
    }
    final req = http.MultipartRequest(method, _url(path));
    fields.forEach((k, v) => req.fields[k] = v is String ? v : jsonEncode(v));
    req.files.add(http.MultipartFile.fromBytes('blob', blob, filename: 'item.bin'));
    return await _send(req) as Map<String, dynamic>;
  }

  /// A short-lived token that lets this user download protected files.
  Future<String> fileToken() async => (await _json('POST', 'api/files/token') as Map<String, dynamic>)['token'] as String;

  Future<Uint8List> download(String recordId, String filename, String fileToken) async {
    final req = http.Request('GET', _url('api/files/$collection/$recordId/$filename', {'token': fileToken}));
    final res = await _http.send(req).timeout(timeout);
    final bytes = await res.stream.toBytes().timeout(timeout);
    if (res.statusCode != 200) throw PbException(res.statusCode, 'Could not download $filename');
    return bytes;
  }

  static String _quote(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}
