// ============================================================
// kewe_secrets.dart —— Kewe 账号体系与用户数据密钥
//
// 设计目标：
//   1. 密码/会话令牌只以密文落盘；注册与登录只接收客户端派生出的
//      密码 verifier，服务器永远见不到明文密码。
//   2. 账号主密钥独立保存在 data/auth/，不随某位用户的数据迁移或删除而丢失。
//   3. 每位用户的数据密钥 = HMAC(authMasterKey, userId)，AES-256-GCM 加密
//      聊天正文与文件；注销时连同密钥与密文一起销毁。
// ============================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'aes_gcm.dart';
import 'globals.dart';
import 'sha256.dart';

String get keweAuthDir => '$BASE_DIR/data/auth';
String get keweAuthKeyFile => '$keweAuthDir/master.key';
String get keweUsersRoot => '$BASE_DIR/data/users';

const String KEWE_TEXT_ENC_PREFIX = 'KWENC1:';

final math.Random _secureRandom = math.Random.secure();

Uint8List keweRandomBytes(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _secureRandom.nextInt(256);
  }
  return out;
}

String keweRandomHex(int n) {
  final b = keweRandomBytes(n);
  return b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
}

String keweHex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

List<int>? _authKeyCache;

/// 账号主密钥。只创建一次，权限 0600。
List<int> getOrCreateKeweAuthKey() {
  final hit = _authKeyCache;
  if (hit != null) return hit;
  ensureDir(keweAuthDir);
  final f = File(keweAuthKeyFile);
  if (f.existsSync()) {
    try {
      final raw = f.readAsBytesSync();
      if (raw.length == 32) {
        _authKeyCache = raw;
        return raw;
      }
    } catch (_) {}
  }
  final key = keweRandomBytes(32);
  final tmp = File('$keweAuthKeyFile.tmp');
  tmp.writeAsBytesSync(key, flush: true);
  try {
    tmp.renameSync(keweAuthKeyFile);
  } on FileSystemException {
    if (f.existsSync()) f.deleteSync();
    tmp.renameSync(keweAuthKeyFile);
  }
  try {
    Process.runSync('chmod', ['600', keweAuthKeyFile]);
  } catch (_) {}
  _authKeyCache = key;
  return key;
}

List<int> keweUserDataKey(String userId) {
  final normalized = userId.trim();
  if (normalized.isEmpty) {
    throw StateError('用户数据密钥需要 userId');
  }
  return hmacSha256(
    getOrCreateKeweAuthKey(),
    utf8.encode('Kewe.UserData.v1|$normalized'),
  );
}

String keweDataDirForUser(String userId) => '$keweUsersRoot/${userId.trim()}';

// ------------------------------------------------------------
// 账号主密钥保护的字符串（用户表、会话令牌表）
// ------------------------------------------------------------
String keweAuthEncrypt(String plain) {
  final nonce = keweRandomBytes(12);
  final sealed = AesGcm(getOrCreateKeweAuthKey()).encrypt(nonce, utf8.encode(plain));
  return 'KEWEAUTH1:${base64.encode([...nonce, ...sealed])}';
}

String keweAuthDecrypt(String stored) {
  final s = stored.trim();
  if (!s.startsWith('KEWEAUTH1:')) return s;
  final raw = base64.decode(s.substring(10));
  if (raw.length < 12 + 16) throw const FormatException('账号密文损坏');
  final nonce = raw.sublist(0, 12);
  final sealed = raw.sublist(12);
  return utf8.decode(AesGcm(getOrCreateKeweAuthKey()).decrypt(nonce, sealed));
}

// ------------------------------------------------------------
// 用户数据：聊天正文 / 文件分块
// ------------------------------------------------------------
String keweEncryptTextForUser(String userId, String plain) {
  final nonce = keweRandomBytes(12);
  final sealed = _gcmForUser(userId).encrypt(nonce, utf8.encode(plain));
  return '$KEWE_TEXT_ENC_PREFIX${base64.encode([...nonce, ...sealed])}';
}

String keweDecryptTextForUser(String userId, String stored) {
  if (!stored.startsWith(KEWE_TEXT_ENC_PREFIX)) return stored;
  final raw = base64.decode(stored.substring(KEWE_TEXT_ENC_PREFIX.length));
  if (raw.length < 28) throw const FormatException('聊天密文损坏');
  final nonce = raw.sublist(0, 12);
  final sealed = raw.sublist(12);
  return utf8.decode(_gcmForUser(userId).decrypt(nonce, sealed));
}

bool keweIsEncryptedText(String value) =>
    value.startsWith(KEWE_TEXT_ENC_PREFIX);

/// 每位用户复用同一个 AesGcm 实例。
///
/// AES-GCM 的 GHASH 查表要在构造时预计算 4096 个位置贡献；
/// 下载 8MB 文件会按 512KB 分 16 块调用，如果每块都重新建实例，
/// 预计算本身就会把下载拖慢。缓存后只算一次。
final Map<String, AesGcm> _userGcmCache = <String, AesGcm>{};

AesGcm _gcmForUser(String userId) {
  final key = userId.trim();
  return _userGcmCache.putIfAbsent(key, () => AesGcm(keweUserDataKey(key)));
}

Uint8List keweEncryptBytesForUser(String userId, List<int> plain) {
  final nonce = keweRandomBytes(12);
  final sealed = _gcmForUser(userId).encrypt(nonce, plain);
  return Uint8List.fromList([...nonce, ...sealed]);
}

Uint8List keweDecryptBytesForUser(String userId, List<int> blob) {
  if (blob.length < 12 + 16) throw const FormatException('文件密文损坏');
  final nonce = blob.sublist(0, 12);
  final sealed = blob.sublist(12);
  return _gcmForUser(userId).decrypt(nonce, sealed);
}

// ------------------------------------------------------------
// 密码 verifier：服务器只保存 HMAC(salt, verifier)，永不接触明文密码
// ------------------------------------------------------------
String keweHashVerifier(String salt, String verifier) {
  return keweHex(hmacSha256(utf8.encode(salt), utf8.encode(verifier)));
}

bool keweConstantTimeEquals(String a, String b) {
  final x = a.toLowerCase();
  final y = b.toLowerCase();
  var diff = x.length ^ y.length;
  final n = x.length < y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    diff |= x.codeUnitAt(i) ^ y.codeUnitAt(i);
  }
  return diff == 0;
}
