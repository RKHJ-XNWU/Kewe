// ============================================================
// aes_gcm.dart —— 纯 Dart 的 AES-256-GCM
//
// 对应 Go 版：ds_crypto.go 使用 crypto/aes + cipher.NewGCM
//   密文格式：base64( nonce(12B) || ciphertext || tag(16B) )
//
// 之所以自己实现：
//   1. 项目要求零第三方依赖（不引入 cryptography / pointycastle）；
//   2. 必须与 Go 版已落盘的 DSENC1| 配置密文**二进制兼容**，
//      因此严格按 NIST SP 800-38D 实现（GHASH 用 BigInt 计算，
//      仅为少量配置字段加解密，性能足够）。
//
// S-box 由 GF(2^8) 乘法逆 + 仿射变换现场生成，避免手抄常量表出错，
// 并在编译期自检（见 verifySelfTest()）。
// ============================================================

import 'dart:typed_data';

// ------------------------------------------------------------
// GF(2^8) 基础
// ------------------------------------------------------------
int _xtime(int a) {
  final hi = a & 0x80;
  var r = (a << 1) & 0xFF;
  if (hi != 0) r ^= 0x1B;
  return r;
}

int _gmul8(int a, int b) {
  var p = 0;
  var aa = a;
  var bb = b;
  for (var i = 0; i < 8; i++) {
    if (bb & 1 != 0) p ^= aa;
    aa = _xtime(aa);
    bb >>= 1;
  }
  return p & 0xFF;
}

int _gInv(int a) {
  if (a == 0) return 0;
  for (var b = 1; b < 256; b++) {
    if (_gmul8(a, b) == 1) return b;
  }
  return 0;
}

int _rotl8(int x, int n) => ((x << n) | (x >> (8 - n))) & 0xFF;

int _sboxOf(int x) {
  final y = _gInv(x);
  return (_rotl8(y, 1) ^
          _rotl8(y, 2) ^
          _rotl8(y, 3) ^
          _rotl8(y, 4) ^
          y ^
          0x63) &
      0xFF;
}

List<int>? _sboxCache;

List<int> get _SBOX {
  final c = _sboxCache;
  if (c != null) return c;
  final t = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    t[i] = _sboxOf(i);
  }
  _sboxCache = t;
  return t;
}

List<int>? _invSboxCache;

List<int> get _INV_SBOX {
  final c = _invSboxCache;
  if (c != null) return c;
  final t = List<int>.filled(256, 0);
  final s = _SBOX;
  for (var i = 0; i < 256; i++) {
    t[s[i]] = i;
  }
  _invSboxCache = t;
  return t;
}

const List<int> _RCON = [
  0x01,
  0x02,
  0x04,
  0x08,
  0x10,
  0x20,
  0x40,
  0x80,
  0x1B,
  0x36,
];

// AES 加密的 T 表：把 SubBytes + MixColumns 合并成 4 次查表。
// 纯 Dart 逐字节实现每块要 14 轮 × 16 字节运算；文件下载按 512KB 分块，
// 8MB 文件会调用几十万次，T 表能把 AES 部分再提速数倍。
List<int>? _te0Cache, _te1Cache, _te2Cache, _te3Cache;

void _initTeTables() {
  if (_te0Cache != null) return;
  final sbox = _SBOX;
  final t0 = List<int>.filled(256, 0);
  final t1 = List<int>.filled(256, 0);
  final t2 = List<int>.filled(256, 0);
  final t3 = List<int>.filled(256, 0);
  for (var x = 0; x < 256; x++) {
    final s = sbox[x];
    final s2 = _xtime(s);
    final s3 = s2 ^ s;
    t0[x] = (s2 << 24) | (s << 16) | (s << 8) | s3;
    t1[x] = (s3 << 24) | (s2 << 16) | (s << 8) | s;
    t2[x] = (s << 24) | (s3 << 16) | (s2 << 8) | s;
    t3[x] = (s << 24) | (s << 16) | (s3 << 8) | s2;
  }
  _te0Cache = t0;
  _te1Cache = t1;
  _te2Cache = t2;
  _te3Cache = t3;
}

// ------------------------------------------------------------
// AES-256（只做单块加/解密，GCM 用 CTR 模式自行串联）
// ------------------------------------------------------------
class Aes256 {
  final List<int> _rk; // 60 words * 4 bytes
  late final List<int> _rk32;
  late final List<int> _te0 = _te0Cache!;
  late final List<int> _te1 = _te1Cache!;
  late final List<int> _te2 = _te2Cache!;
  late final List<int> _te3 = _te3Cache!;

  Aes256(List<int> key) : _rk = _expandKey(key) {
    _initTeTables();
    _rk32 = List<int>.generate(60, (i) {
      final o = i * 4;
      return (_rk[o] << 24) |
          (_rk[o + 1] << 16) |
          (_rk[o + 2] << 8) |
          _rk[o + 3];
    });
  }

  static List<int> _expandKey(List<int> key) {
    if (key.length != 32) {
      throw ArgumentError('AES-256 需要 32 字节的密钥（实际 ${key.length}）');
    }
    final nk = 8;
    final nr = 14;
    final w = List<int>.filled(4 * (nr + 1) * 4, 0); // 每个 word 4 字节平铺
    for (var i = 0; i < nk * 4; i++) {
      w[i] = key[i];
    }
    final sbox = _SBOX;
    for (var i = nk; i < 4 * (nr + 1); i++) {
      var t0 = w[i * 4 - 4];
      var t1 = w[i * 4 - 3];
      var t2 = w[i * 4 - 2];
      var t3 = w[i * 4 - 1];
      if (i % nk == 0) {
        // RotWord + SubWord + Rcon
        final tmp = t0;
        t0 = sbox[t1] ^ _RCON[i ~/ nk - 1];
        t1 = sbox[t2];
        t2 = sbox[t3];
        t3 = sbox[tmp];
      } else if (i % nk == 4) {
        t0 = sbox[t0];
        t1 = sbox[t1];
        t2 = sbox[t2];
        t3 = sbox[t3];
      }
      w[i * 4] = w[(i - nk) * 4] ^ t0;
      w[i * 4 + 1] = w[(i - nk) * 4 + 1] ^ t1;
      w[i * 4 + 2] = w[(i - nk) * 4 + 2] ^ t2;
      w[i * 4 + 3] = w[(i - nk) * 4 + 3] ^ t3;
    }
    return w;
  }

  void _addRoundKey(Uint8List s, int round) {
    final base = round * 16;
    for (var i = 0; i < 16; i++) {
      s[i] ^= _rk[base + i];
    }
  }

  void _invSubBytes(Uint8List s) {
    final inv = _INV_SBOX;
    for (var i = 0; i < 16; i++) {
      s[i] = inv[s[i]];
    }
  }

  void _invShiftRows(Uint8List s) {
    var t = s[13];
    s[13] = s[9];
    s[9] = s[5];
    s[5] = s[1];
    s[1] = t;

    t = s[2];
    s[2] = s[10];
    s[10] = t;
    t = s[6];
    s[6] = s[14];
    s[14] = t;

    t = s[3];
    s[3] = s[7];
    s[7] = s[11];
    s[11] = s[15];
    s[15] = t;
  }

  void _invMixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final i = c * 4;
      final a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      s[i] = _gmul8(a0, 0x0E) ^
          _gmul8(a1, 0x0B) ^
          _gmul8(a2, 0x0D) ^
          _gmul8(a3, 0x09);
      s[i + 1] = _gmul8(a0, 0x09) ^
          _gmul8(a1, 0x0E) ^
          _gmul8(a2, 0x0B) ^
          _gmul8(a3, 0x0D);
      s[i + 2] = _gmul8(a0, 0x0D) ^
          _gmul8(a1, 0x09) ^
          _gmul8(a2, 0x0E) ^
          _gmul8(a3, 0x0B);
      s[i + 3] = _gmul8(a0, 0x0B) ^
          _gmul8(a1, 0x0D) ^
          _gmul8(a2, 0x09) ^
          _gmul8(a3, 0x0E);
    }
  }

  Uint8List encryptBlock(List<int> input) {
    var s0 =
        ((input[0] << 24) | (input[1] << 16) | (input[2] << 8) | input[3]) ^
            _rk32[0];
    var s1 =
        ((input[4] << 24) | (input[5] << 16) | (input[6] << 8) | input[7]) ^
            _rk32[1];
    var s2 =
        ((input[8] << 24) | (input[9] << 16) | (input[10] << 8) | input[11]) ^
            _rk32[2];
    var s3 =
        ((input[12] << 24) | (input[13] << 16) | (input[14] << 8) | input[15]) ^
            _rk32[3];

    var rk = 4;
    for (var round = 1; round < 14; round++) {
      final t0 = _te0[s0 >> 24] ^
          _te1[(s1 >> 16) & 0xFF] ^
          _te2[(s2 >> 8) & 0xFF] ^
          _te3[s3 & 0xFF] ^
          _rk32[rk++];
      final t1 = _te0[s1 >> 24] ^
          _te1[(s2 >> 16) & 0xFF] ^
          _te2[(s3 >> 8) & 0xFF] ^
          _te3[s0 & 0xFF] ^
          _rk32[rk++];
      final t2 = _te0[s2 >> 24] ^
          _te1[(s3 >> 16) & 0xFF] ^
          _te2[(s0 >> 8) & 0xFF] ^
          _te3[s1 & 0xFF] ^
          _rk32[rk++];
      final t3 = _te0[s3 >> 24] ^
          _te1[(s0 >> 16) & 0xFF] ^
          _te2[(s1 >> 8) & 0xFF] ^
          _te3[s2 & 0xFF] ^
          _rk32[rk++];
      s0 = t0;
      s1 = t1;
      s2 = t2;
      s3 = t3;
    }
    return _finalRound(s0, s1, s2, s3, rk);
  }

  Uint8List _finalRound(int s0, int s1, int s2, int s3, int rk) {
    final sbox = _SBOX;
    final t0 = ((sbox[s0 >> 24] << 24) |
            (sbox[(s1 >> 16) & 0xFF] << 16) |
            (sbox[(s2 >> 8) & 0xFF] << 8) |
            sbox[s3 & 0xFF]) ^
        _rk32[rk];
    final t1 = ((sbox[s1 >> 24] << 24) |
            (sbox[(s2 >> 16) & 0xFF] << 16) |
            (sbox[(s3 >> 8) & 0xFF] << 8) |
            sbox[s0 & 0xFF]) ^
        _rk32[rk + 1];
    final t2 = ((sbox[s2 >> 24] << 24) |
            (sbox[(s3 >> 16) & 0xFF] << 16) |
            (sbox[(s0 >> 8) & 0xFF] << 8) |
            sbox[s1 & 0xFF]) ^
        _rk32[rk + 2];
    final t3 = ((sbox[s3 >> 24] << 24) |
            (sbox[(s0 >> 16) & 0xFF] << 16) |
            (sbox[(s1 >> 8) & 0xFF] << 8) |
            sbox[s2 & 0xFF]) ^
        _rk32[rk + 3];
    return Uint8List.fromList(<int>[
      (t0 >> 24) & 0xFF,
      (t0 >> 16) & 0xFF,
      (t0 >> 8) & 0xFF,
      t0 & 0xFF,
      (t1 >> 24) & 0xFF,
      (t1 >> 16) & 0xFF,
      (t1 >> 8) & 0xFF,
      t1 & 0xFF,
      (t2 >> 24) & 0xFF,
      (t2 >> 16) & 0xFF,
      (t2 >> 8) & 0xFF,
      t2 & 0xFF,
      (t3 >> 24) & 0xFF,
      (t3 >> 16) & 0xFF,
      (t3 >> 8) & 0xFF,
      t3 & 0xFF,
    ]);
  }

  Uint8List decryptBlock(List<int> input) {
    final s = Uint8List.fromList(input.sublist(0, 16));
    _addRoundKey(s, 14);
    for (var round = 13; round >= 1; round--) {
      _invShiftRows(s);
      _invSubBytes(s);
      _addRoundKey(s, round);
      _invMixColumns(s);
    }
    _invShiftRows(s);
    _invSubBytes(s);
    _addRoundKey(s, 0);
    return s;
  }
}

// ------------------------------------------------------------
// GHASH / GCM（NIST SP 800-38D）
// ------------------------------------------------------------
final BigInt _R = BigInt.parse('E1000000000000000000000000000000', radix: 16);

BigInt _bytesToBig(List<int> b) {
  var r = BigInt.zero;
  for (final x in b) {
    r = (r << 8) | BigInt.from(x & 0xFF);
  }
  return r;
}

List<int> _bigToBytes(BigInt v, int len) {
  final out = List<int>.filled(len, 0);
  var x = v;
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xFF)).toInt();
    x = x >> 8;
  }
  return out;
}

BigInt _gfMul(BigInt x, BigInt y) {
  var z = BigInt.zero;
  var v = y;
  for (var i = 0; i < 128; i++) {
    final bit = (x >> (127 - i)) & BigInt.one;
    if (bit == BigInt.one) z ^= v;
    if ((v & BigInt.one) == BigInt.one) {
      v = (v >> 1) ^ _R;
    } else {
      v = v >> 1;
    }
  }
  return z;
}

/// BigInt ⇄ 128-bit (4×Uint32) 互转。
/// GHASH 是逐块 128-bit 运算，纯 BigInt 每块都要做 128 次大整数移位；
/// 下载大文件时这是唯一的性能瓶颈。这里换成 32-bit 字运算 + 查表。
BigInt _wordsToBig(int w0, int w1, int w2, int w3) {
  var v = BigInt.from(w0 & 0xFFFFFFFF);
  v = (v << 32) | BigInt.from(w1 & 0xFFFFFFFF);
  v = (v << 32) | BigInt.from(w2 & 0xFFFFFFFF);
  v = (v << 32) | BigInt.from(w3 & 0xFFFFFFFF);
  return v;
}

List<int> _bigToWords(BigInt v) {
  final out = List<int>.filled(4, 0);
  var x = v;
  for (var i = 3; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xFFFFFFFF)).toInt();
    x = x >> 32;
  }
  return out;
}

/// GHASH 的 16×256 位置查表。
///
/// GCM 的 GF(2^128) 乘法对输入是线性的：一个 128-bit 块 X 乘 H，
/// 等于 X 的每一个字节按其所在位置贡献的异或。这里预计算
/// `U[p][b] = (b << (8*(15-p))) * H`，每个块只需 16 次查表异或，
/// 不再逐位循环 128 次 BigInt 移位。结果与 [_gfMul] 逐位定义完全一致。
class _GHashTables {
  final List<int> u0 = List<int>.filled(4096, 0);
  final List<int> u1 = List<int>.filled(4096, 0);
  final List<int> u2 = List<int>.filled(4096, 0);
  final List<int> u3 = List<int>.filled(4096, 0);

  _GHashTables(BigInt h) {
    for (var p = 0; p < 16; p++) {
      final shift = 8 * (15 - p);
      for (var b = 0; b < 256; b++) {
        final v = _bigToWords(_gfMul(BigInt.from(b) << shift, h));
        final idx = p * 256 + b;
        u0[idx] = v[0];
        u1[idx] = v[1];
        u2[idx] = v[2];
        u3[idx] = v[3];
      }
    }
  }
}

/// 快速 GHASH；输入按 GCM 规范补齐 AAD、密文与长度块。
BigInt _ghashFast(_GHashTables tab, List<int> aad, List<int> ct) {
  final data = <int>[];
  data.addAll(aad);
  final padA = (16 - (aad.length % 16)) % 16;
  data.addAll(List<int>.filled(padA, 0));
  data.addAll(ct);
  final padC = (16 - (ct.length % 16)) % 16;
  data.addAll(List<int>.filled(padC, 0));
  // 长度块：AAD 位数(64) || 密文位数(64)
  data.addAll(_bigToBytes(BigInt.from(aad.length * 8), 8));
  data.addAll(_bigToBytes(BigInt.from(ct.length * 8), 8));

  var y0 = 0, y1 = 0, y2 = 0, y3 = 0;
  for (var i = 0; i < data.length; i += 16) {
    var z0 = 0, z1 = 0, z2 = 0, z3 = 0;
    for (var p = 0; p < 16; p++) {
      final word = p < 4 ? y0 : (p < 8 ? y1 : (p < 12 ? y2 : y3));
      final shift = 24 - (p % 4) * 8;
      final xb = data[i + p] ^ ((word >> shift) & 0xFF);
      final idx = p * 256 + xb;
      z0 ^= tab.u0[idx];
      z1 ^= tab.u1[idx];
      z2 ^= tab.u2[idx];
      z3 ^= tab.u3[idx];
    }
    y0 = z0 & 0xFFFFFFFF;
    y1 = z1 & 0xFFFFFFFF;
    y2 = z2 & 0xFFFFFFFF;
    y3 = z3 & 0xFFFFFFFF;
  }
  return _wordsToBig(y0, y1, y2, y3);
}

class AesGcm {
  final Aes256 _aes;
  late final Uint8List _hashKey;
  _GHashTables? _ghashTablesCache;

  AesGcm(List<int> key) : _aes = Aes256(key) {
    // H = E(K, 0^128)
    _hashKey = _aes.encryptBlock(List<int>.filled(16, 0));
  }

  _GHashTables get _tables {
    final cached = _ghashTablesCache;
    if (cached != null) return cached;
    final tables = _GHashTables(_bytesToBig(_hashKey));
    _ghashTablesCache = tables;
    return tables;
  }

  /// 递增 32-bit 计数器（J0 的最后 4 字节）
  static List<int> _inc32(List<int> block) {
    final b = List<int>.from(block);
    var c = ((b[12] << 24) | (b[13] << 16) | (b[14] << 8) | b[15]);
    c = (c + 1) & 0xFFFFFFFF;
    b[12] = (c >> 24) & 0xFF;
    b[13] = (c >> 16) & 0xFF;
    b[14] = (c >> 8) & 0xFF;
    b[15] = c & 0xFF;
    return b;
  }

  static Uint8List _ctr(List<int> j0, List<int> input, Aes256 aes) {
    final out = Uint8List(input.length);
    var counter = List<int>.from(j0);
    var offset = 0;
    while (offset < input.length) {
      counter = _inc32(counter);
      final ks = aes.encryptBlock(counter);
      final n = (input.length - offset) < 16 ? (input.length - offset) : 16;
      for (var i = 0; i < n; i++) {
        out[offset + i] = input[offset + i] ^ ks[i];
      }
      offset += n;
    }
    return out;
  }

  /// 加密：返回 ciphertext || tag(16)
  Uint8List encrypt(List<int> nonce, List<int> plain,
      {List<int> aad = const []}) {
    final j0 = <int>[...nonce, 0, 0, 0, 1];
    final ct = _ctr(j0, plain, _aes);
    final s = _ghashFast(_tables, aad, ct);
    final ek = _bytesToBig(_aes.encryptBlock(j0));
    final tag = _bigToBytes(ek ^ s, 16);
    return Uint8List.fromList([...ct, ...tag]);
  }

  /// 解密：输入 ciphertext || tag(16)
  Uint8List decrypt(List<int> nonce, List<int> cipherWithTag,
      {List<int> aad = const []}) {
    if (cipherWithTag.length < 16) {
      throw const FormatException('密文长度不足');
    }
    final ct = cipherWithTag.sublist(0, cipherWithTag.length - 16);
    final tag = cipherWithTag.sublist(cipherWithTag.length - 16);
    final j0 = <int>[...nonce, 0, 0, 0, 1];
    final s = _ghashFast(_tables, aad, ct);
    final ek = _bytesToBig(_aes.encryptBlock(j0));
    final expect = _bigToBytes(ek ^ s, 16);
    for (var i = 0; i < 16; i++) {
      if (expect[i] != tag[i]) {
        throw const FormatException('GCM 标签校验失败');
      }
    }
    return _ctr(j0, ct, _aes);
  }
}

// ------------------------------------------------------------
// 自检（NIST 测试向量，供 verify 使用）
// ------------------------------------------------------------
bool aesSelfTest() {
  // FIPS-197 AES-256 单块向量
  final key = List<int>.generate(32, (i) => i);
  final pt = List<int>.generate(16, (i) => i * 0x11);
  final expect = [
    0x8e,
    0xa2,
    0xb7,
    0xca,
    0x51,
    0x67,
    0x45,
    0xbf,
    0xea,
    0xfc,
    0x49,
    0x90,
    0x4b,
    0x49,
    0x60,
    0x89,
  ];
  final aes = Aes256(key);
  final ct = aes.encryptBlock(pt);
  for (var i = 0; i < 16; i++) {
    if (ct[i] != expect[i]) return false;
  }
  final back = aes.decryptBlock(ct);
  for (var i = 0; i < 16; i++) {
    if (back[i] != pt[i]) return false;
  }
  // S-box 首尾抽样
  if (_SBOX[0] != 0x63 || _SBOX[1] != 0x7C || _SBOX[255] != 0x16) return false;
  return true;
}
