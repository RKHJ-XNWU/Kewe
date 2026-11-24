// ============================================================
// kewe_auth.dart —— Kewe 账号 / 会话 / 登录门禁
//
//   注册：用户名唯一；密码可重复；密码只以客户端派生 verifier 抵达服务器。
//   登录：HttpOnly + SameSite=Strict Cookie，服务端只保存加密令牌表。
//   注销：数据目录、聊天密文、文件密文、密钥派生身份全部销毁，不做匿名化。
//   门禁：未登录访问任何 /api 均返回 404（并带 X-Kewe-Auth: required）。
// ============================================================

import 'dart:convert';
import 'dart:io';

import 'files.dart';
import 'globals.dart';
import 'httpsrv.dart';
import 'kewe_secrets.dart';
import 'sessions.dart';

const String KEWE_AUTH_COOKIE = 'kewe_session';
const int KEWE_SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;

class KeweUser {
  final String id;
  final String username;
  final String usernameLower;
  final String salt;
  final String verifierHash;
  final int createdAt;

  KeweUser({
    required this.id,
    required this.username,
    required this.usernameLower,
    required this.salt,
    required this.verifierHash,
    required this.createdAt,
  });

  String get dataDir => keweDataDirForUser(id);

  Map<String, dynamic> toStore() => {
        'id': id,
        'username': username,
        'usernameLower': usernameLower,
        'salt': salt,
        'verifierHash': verifierHash,
        'createdAt': createdAt,
      };

  Map<String, dynamic> toPublic() => {
        'id': id,
        'username': username,
        'createdAt': createdAt,
      };

  static KeweUser? fromStore(Object? raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString();
    final username = (raw['username'] ?? '').toString();
    final salt = (raw['salt'] ?? '').toString();
    final hash = (raw['verifierHash'] ?? '').toString();
    if (id.isEmpty || username.isEmpty || salt.isEmpty || hash.isEmpty) {
      return null;
    }
    return KeweUser(
      id: id,
      username: username,
      usernameLower: (raw['usernameLower'] ?? username.toLowerCase()).toString(),
      salt: salt,
      verifierHash: hash,
      createdAt: int.tryParse((raw['createdAt'] ?? 0).toString()) ?? 0,
    );
  }
}

class _AuthStore {
  final List<KeweUser> users;
  final Map<String, Map<String, dynamic>> sessions;

  _AuthStore(this.users, this.sessions);
}

// ------------------------------------------------------------
// 加密存储
// ------------------------------------------------------------
String get _usersFile => '$keweAuthDir/users.sts';
String get _tokensFile => '$keweAuthDir/sessions.sts';

void _writeSecretFile(String path, String plainJson) {
  ensureDir(keweAuthDir);
  final encrypted = keweAuthEncrypt(plainJson);
  final tmp = File('$path.tmp');
  tmp.writeAsStringSync(encrypted, flush: true);
  try {
    tmp.renameSync(path);
  } on FileSystemException {
    final old = File(path);
    if (old.existsSync()) old.deleteSync();
    tmp.renameSync(path);
  }
  try {
    Process.runSync('chmod', ['600', path]);
  } catch (_) {}
}

String? _readSecretFile(String path) {
  final f = File(path);
  if (!f.existsSync()) return null;
  try {
    return keweAuthDecrypt(f.readAsStringSync());
  } catch (e) {
    logp('❌ 账号存储解密失败: $path ($e)');
    return null;
  }
}

_AuthStore _loadStore() {
  final users = <KeweUser>[];
  try {
    final raw = _readSecretFile(_usersFile);
    if (raw != null && raw.trim().isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['users'] is List) {
        for (final item in decoded['users'] as List) {
          final u = KeweUser.fromStore(item);
          if (u != null) users.add(u);
        }
      }
    }
  } catch (e) {
    logp('❌ 读取用户表失败: $e');
  }

  final sessions = <String, Map<String, dynamic>>{};
  try {
    final raw = _readSecretFile(_tokensFile);
    if (raw != null && raw.trim().isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['sessions'] is Map) {
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final e in (decoded['sessions'] as Map).entries) {
          if (e.value is! Map) continue;
          final rec = Map<String, dynamic>.from(e.value as Map);
          final expires = int.tryParse('${rec['expiresAt'] ?? 0}') ?? 0;
          if (expires > now) sessions['${e.key}'] = rec;
        }
      }
    }
  } catch (e) {
    logp('❌ 读取会话表失败: $e');
  }
  return _AuthStore(users, sessions);
}

void _saveStore(List<KeweUser> users, Map<String, Map<String, dynamic>> sessions) {
  final now = DateTime.now().millisecondsSinceEpoch;
  sessions.removeWhere((_, v) {
    final exp = int.tryParse('${v['expiresAt'] ?? 0}') ?? 0;
    return exp <= now;
  });
  _writeSecretFile(
    _usersFile,
    jsonEncode({'version': 1, 'users': users.map((u) => u.toStore()).toList()}),
  );
  _writeSecretFile(
    _tokensFile,
    jsonEncode({'version': 1, 'sessions': sessions}),
  );
}

// ------------------------------------------------------------
// Cookie
// ------------------------------------------------------------
String? _cookieValue(HttpRequest req, String name) {
  final raw = req.headers.value('cookie');
  if (raw == null || raw.isEmpty) return null;
  for (final piece in raw.split(';')) {
    final idx = piece.indexOf('=');
    if (idx < 0) continue;
    if (piece.substring(0, idx).trim() == name) {
      return Uri.decodeComponent(piece.substring(idx + 1).trim());
    }
  }
  return null;
}

void _setAuthCookie(HttpResponse res, String token) {
  res.headers.set(
    'Set-Cookie',
    '$KEWE_AUTH_COOKIE=$token; Path=/; HttpOnly; SameSite=Strict; '
    'Max-Age=${KEWE_SESSION_TTL_MS ~/ 1000}',
  );
}

void _clearAuthCookie(HttpResponse res) {
  res.headers.set(
    'Set-Cookie',
    '$KEWE_AUTH_COOKIE=; Path=/; HttpOnly; SameSite=Strict; '
    'Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
  );
}

// ------------------------------------------------------------
// 查询当前请求身份
// ------------------------------------------------------------
KeweUser? keweUserFromRequest(HttpRequest req) {
  final token = _cookieValue(req, KEWE_AUTH_COOKIE);
  if (token == null || token.isEmpty || token.length < 40) return null;
  final store = _loadStore();
  final rec = store.sessions[token];
  if (rec == null) return null;
  final expires = int.tryParse('${rec['expiresAt'] ?? 0}') ?? 0;
  if (expires <= DateTime.now().millisecondsSinceEpoch) return null;
  final uid = '${rec['userId'] ?? ''}';
  if (uid.isEmpty) return null;
  for (final u in store.users) {
    if (u.id == uid) return u;
  }
  return null;
}

KeweUser? _findUser(List<KeweUser> users, String username) {
  final lower = username.toLowerCase();
  for (final u in users) {
    if (u.usernameLower == lower) return u;
  }
  return null;
}

Map<String, dynamic>? _bodyMap(Object? body) {
  if (body is Map) return Map<String, dynamic>.from(body);
  return null;
}

String _str(Map<String, dynamic> body, String key) =>
    (body[key] ?? '').toString().trim();

bool _validUsername(String name) {
  final len = name.runes.length;
  if (len < 3 || len > 32) return false;
  if (RegExp(r'[\s|\\/\x00-\x1F\x7F]').hasMatch(name)) return false;
  return true;
}

bool _validVerifier(String verifier) {
  try {
    final raw = base64.decode(verifier);
    return raw.length == 32;
  } catch (_) {
    return false;
  }
}

String _newToken() => keweRandomHex(32);

Map<String, dynamic> _newSession(String userId) => {
      'userId': userId,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'expiresAt': DateTime.now().millisecondsSinceEpoch + KEWE_SESSION_TTL_MS,
    };

Future<void> _jsonErr(HttpResponse res, int code, String message,
    {String? errorCode}) async {
  await jsonResponse(res, code, {
    'ok': false,
    'error': message,
    if (errorCode != null) 'code': errorCode,
  });
}

void _adoptLegacyData(String userDir) {
  // 首次注册时，把旧版单用户 data/ 迁入新账号，避免历史聊天丢失。
  ensureDir(userDir);
  final root = Directory('$BASE_DIR/data');
  if (!root.existsSync()) return;
  for (final entity in root.listSync()) {
    final name = entity.path.split(Platform.pathSeparator).last;
    if (name == 'auth' || name == 'users') continue;
    final dest = '$userDir/$name';
    if (FileSystemEntity.typeSync(dest) != FileSystemEntityType.notFound) {
      continue;
    }
    try {
      entity.renameSync(dest);
      logp('📦 旧数据已迁入账号目录: $name');
    } catch (e) {
      logp('⚠️ 旧数据迁移失败: $name ($e)');
    }
  }
}

void _relocateLegacyFilesIfAny(String userDir) {
  // 兼容：首次账号已注册但旧文件因占用未迁移，第二次登录时补偿。
  final root = Directory('$BASE_DIR/data');
  if (!root.existsSync()) return;
  for (final entity in root.listSync()) {
    final name = entity.path.split(Platform.pathSeparator).last;
    if (name == 'auth' || name == 'users') continue;
    final dest = '$userDir/$name';
    if (FileSystemEntity.typeSync(dest) != FileSystemEntityType.notFound) continue;
    try {
      entity.renameSync(dest);
    } catch (_) {}
  }
}


// ------------------------------------------------------------
// 注册 / 登录 / 注销 / 状态
// ------------------------------------------------------------
Future<void> handleKeweAuthApi(HttpRequest req) async {
  final path = req.uri.path;
  final method = req.method;

  if (path == '/api/auth/status' && method == 'GET') {
    final user = keweUserFromRequest(req);
    if (user == null) {
      req.response.headers.set('X-Kewe-Auth', 'required');
      req.response.headers.set('Cache-Control', 'no-store');
      await jsonResponse(req.response, 404, {
        'ok': false,
        'authenticated': false,
        'error': 'Not Found',
      });
      return;
    }
    req.response.headers.set('Cache-Control', 'no-store');
    await jsonResponse(req.response, 200, {
      'ok': true,
      'authenticated': true,
      'user': user.toPublic(),
    });
    return;
  }

  if (path == '/api/auth/register' && method == 'POST') {
    dynamic parsed;
    try {
      parsed = await readJsonBody(req, limit: 1024 * 1024);
    } catch (_) {
      await _jsonErr(req.response, 400, '请求体无效');
      return;
    }
    final body = _bodyMap(parsed) ?? const <String, dynamic>{};
    final username = _str(body, 'username');
    final verifier = _str(body, 'verifier');

    if (!_validUsername(username)) {
      await _jsonErr(req.response, 400, '用户名需为 3–32 个字符，且不能包含空白或路径符号');
      return;
    }
    if (!_validVerifier(verifier)) {
      await _jsonErr(req.response, 400, '密码凭据格式无效');
      return;
    }

    final store = _loadStore();
    if (_findUser(store.users, username) != null) {
      await _jsonErr(req.response, 409, '用户名已被占用', errorCode: 'username_taken');
      return;
    }

    ensureDir(keweAuthDir);
    final userId = 'u_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}_${keweRandomHex(8)}';
    final salt = keweRandomHex(16);
    final user = KeweUser(
      id: userId,
      username: username,
      usernameLower: username.toLowerCase(),
      salt: salt,
      verifierHash: keweHashVerifier(salt, verifier),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final userDir = user.dataDir;
    _adoptLegacyData(userDir);
    store.users.add(user);

    final token = _newToken();
    store.sessions[token] = _newSession(user.id);
    _saveStore(store.users, store.sessions);

    _setAuthCookie(req.response, token);
    req.response.headers.set('Cache-Control', 'no-store');
    await runWithUserScope(user.id, userDir, () async {
      encryptLegacyUserDataForCurrentUser();
      invalidateAllDsSessionCaches();
      invalidateDsFileMetaCache();
    });

    logp('👤 新账号注册: ${user.username} (${user.id})');
    await jsonResponse(req.response, 200, {
      'ok': true,
      'authenticated': true,
      'user': user.toPublic(),
    });
    return;
  }

  if (path == '/api/auth/login' && method == 'POST') {
    dynamic parsed;
    try {
      parsed = await readJsonBody(req, limit: 1024 * 1024);
    } catch (_) {
      await _jsonErr(req.response, 400, '请求体无效');
      return;
    }
    final body = _bodyMap(parsed) ?? const <String, dynamic>{};
    final username = _str(body, 'username');
    final verifier = _str(body, 'verifier');
    if (username.isEmpty || !_validVerifier(verifier)) {
      await _jsonErr(req.response, 400, '用户名或密码凭据无效');
      return;
    }

    final store = _loadStore();
    final user = _findUser(store.users, username);
    if (user == null ||
        !keweConstantTimeEquals(keweHashVerifier(user.salt, verifier), user.verifierHash)) {
      await _jsonErr(req.response, 401, '用户名或密码不正确', errorCode: 'bad_credentials');
      return;
    }

    ensureDir(user.dataDir);
    _relocateLegacyFilesIfAny(user.dataDir);
    final token = _newToken();
    store.sessions[token] = _newSession(user.id);
    _saveStore(store.users, store.sessions);

    _setAuthCookie(req.response, token);
    req.response.headers.set('Cache-Control', 'no-store');
    await runWithUserScope(user.id, user.dataDir, () async {
      encryptLegacyUserDataForCurrentUser();
      invalidateAllDsSessionCaches();
      invalidateDsFileMetaCache();
    });

    logp('🔐 账号登录: ${user.username} (${user.id})');
    await jsonResponse(req.response, 200, {
      'ok': true,
      'authenticated': true,
      'user': user.toPublic(),
    });
    return;
  }

  // 退出登录：只结束当前设备的会话（清除 Cookie + 删除该 token），
  // 账号记录、聊天、知识库、文件等数据全部保留，重新登录即可恢复。
  if (path == '/api/auth/logout' && method == 'POST') {
    final user = keweUserFromRequest(req);
    final token = _cookieValue(req, KEWE_AUTH_COOKIE);
    _clearAuthCookie(req.response);
    req.response.headers.set('Cache-Control', 'no-store');
    if (token != null) {
      final store = _loadStore();
      store.sessions.remove(token);
      _saveStore(store.users, store.sessions);
    }
    logp('👋 退出登录（数据保留）: ${user?.username ?? '-'} (${user?.id ?? '-'})');
    await jsonResponse(req.response, 200, {
      'ok': true,
      'loggedOut': true,
      'purged': false,
      'dataKept': true,
    });
    return;
  }

  // 注销账号：销毁该账号的数据目录与账号记录，不可恢复。
  if (path == '/api/auth/delete' && method == 'POST') {
    final user = keweUserFromRequest(req);
    final token = _cookieValue(req, KEWE_AUTH_COOKIE);
    _clearAuthCookie(req.response);
    req.response.headers.set('Cache-Control', 'no-store');
    if (user == null) {
      await jsonResponse(req.response, 200, {'ok': true, 'loggedOut': true});
      return;
    }

    try {
      if (Directory(user.dataDir).existsSync()) {
        Directory(user.dataDir).deleteSync(recursive: true);
      }
    } catch (e) {
      logp('❌ 注销时删除数据失败: ${user.id} ($e)');
      await _jsonErr(req.response, 500, '账号数据删除失败，注销未完成');
      return;
    }

    final store = _loadStore();
    store.users.removeWhere((u) => u.id == user.id);
    store.sessions.removeWhere((_, rec) => '${rec['userId'] ?? ''}' == user.id);
    if (token != null) store.sessions.remove(token);
    _saveStore(store.users, store.sessions);

    runWithUserScope(user.id, user.dataDir, () async {
      invalidateAllDsSessionCaches();
      invalidateDsFileMetaCache();
    });

    logp('🗑️ 账号注销并销毁数据: ${user.username} (${user.id})');
    await jsonResponse(req.response, 200, {'ok': true, 'loggedOut': true, 'purged': true});
    return;
  }

  if (path == '/api/auth/me' && method == 'GET') {
    final user = keweUserFromRequest(req);
    if (user == null) {
      req.response.headers.set('X-Kewe-Auth', 'required');
      await jsonResponse(req.response, 404, {'ok': false, 'error': 'Not Found'});
      return;
    }
    await jsonResponse(req.response, 200, {'ok': true, 'user': user.toPublic()});
    return;
  }

  await jsonResponse(req.response, 404, {'ok': false, 'error': 'Not Found'});
}

/// 未登录的 API/私人静态资源统一 404。
Future<void> keweReplyUnauthorized(HttpRequest req) async {
  req.response.headers.set('X-Kewe-Auth', 'required');
  req.response.headers.set('Cache-Control', 'no-store');
  await jsonResponse(req.response, 404, {
    'ok': false,
    'error': 'Not Found',
    'code': 'not_found',
    'auth': true,
  });
}
