// ============================================================
// backup.dart —— 备份（tar.gz 打包下载）/ 恢复（multipart 上传解压）
// 100% 对齐 Go 版 main.go 的 handleBackup / handleRestore
//   tar 写入/解析与 Go archive/tar 兼容（ustar 格式）
// ============================================================

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'globals.dart';
import 'httpsrv.dart';
import 'kewe_auth.dart';
import 'kewe_secrets.dart';
import 'files.dart';
import 'sessions.dart';
import 'search.dart';

// ------------------------------------------------------------
// tar 写入
// ------------------------------------------------------------
Uint8List _header({
  required String name,
  required int mode,
  required int size,
  required int mtime,
  required String typeflag,
}) {
  final h = Uint8List(512);
  void writeStr(int off, String s, int len) {
    final b = utf8.encode(s);
    for (var i = 0; i < len && i < b.length; i++) {
      h[off + i] = b[i];
    }
  }

  void writeOctal(int off, int value, int len) {
    final s = value.toRadixString(8).padLeft(len - 1, '0');
    writeStr(off, s, len - 1);
    h[off + len - 1] = 0;
  }

  writeStr(0, name, 100);
  writeOctal(100, mode, 8);
  writeOctal(108, 0, 8); // uid
  writeOctal(116, 0, 8); // gid
  writeOctal(124, size, 12);
  writeOctal(136, mtime, 12);
  writeStr(148, '        ', 8); // checksum 占位
  writeStr(156, typeflag, 1);
  writeStr(257, 'ustar', 5);
  h[262] = 0;
  writeStr(263, '00', 2);
  writeStr(265, 'root', 32);
  writeStr(297, 'root', 32);

  var sum = 0;
  for (final b in h) {
    sum += b;
  }
  final chk = sum.toRadixString(8).padLeft(6, '0');
  writeStr(148, chk, 6);
  h[154] = 0;
  h[155] = 0x20;
  return h;
}

class TarWriter {
  final Sink<List<int>> _sink;
  TarWriter(this._sink);

  Future<void> addDir(String name, DateTime mtime) async {
    _sink.add(_header(
      name: name.endsWith('/') ? name : '$name/',
      mode: 0x1ED, // 0755
      size: 0,
      mtime: mtime.millisecondsSinceEpoch ~/ 1000,
      typeflag: '5',
    ));
  }

  Future<void> addFile(String name, List<int> data, DateTime mtime) async {
    _sink.add(_header(
      name: name,
      mode: 0x1A4, // 0644
      size: data.length,
      mtime: mtime.millisecondsSinceEpoch ~/ 1000,
      typeflag: '0',
    ));
    _sink.add(data);
    final pad = (512 - (data.length % 512)) % 512;
    if (pad > 0) _sink.add(Uint8List(pad));
  }

  Future<void> close() async {
    _sink.add(Uint8List(1024)); // 两个全零块
    _sink.close();
  }
}

// ------------------------------------------------------------
// tar 解析
// ------------------------------------------------------------
class TarEntry {
  final String name;
  final String typeflag;
  final Uint8List data;
  TarEntry(this.name, this.typeflag, this.data);
}

List<TarEntry> parseTar(Uint8List buf) {
  final out = <TarEntry>[];
  var off = 0;
  String readStr(int start, int len) {
    var end = start;
    while (end < start + len && buf[end] != 0) {
      end++;
    }
    return utf8.decode(buf.sublist(start, end), allowMalformed: true);
  }

  int readOctal(int start, int len) {
    final s = readStr(start, len).trim();
    if (s.isEmpty) return 0;
    return int.tryParse(s, radix: 8) ?? 0;
  }

  while (off + 512 <= buf.length) {
    final name = readStr(off, 100);
    if (name.isEmpty) break; // 结束块
    final typeflag = readStr(off + 156, 1);
    final size = readOctal(off + 124, 12);
    var fullName = name;
    final prefix = readStr(off + 345, 155);
    if (prefix.isNotEmpty) fullName = '$prefix/$name';
    off += 512;
    final dataLen = size > 0 ? size : 0;
    if (off + dataLen > buf.length) break;
    final data = Uint8List.sublistView(buf, off, off + dataLen);
    out.add(TarEntry(fullName, typeflag.isEmpty ? '0' : typeflag, data));
    off += dataLen;
    final pad = (512 - (dataLen % 512)) % 512;
    off += pad;
  }
  return out;
}

// ------------------------------------------------------------
// 备份
// ------------------------------------------------------------

/// 归一化 tar 路径；拒绝绝对路径、`..` 与空路径。
List<String>? _safeTarParts(String raw) {
  if (raw.isEmpty || raw.startsWith('/') || raw.startsWith('\\')) return null;
  final parts = <String>[];
  for (final seg in raw.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') return null;
    parts.add(seg);
  }
  return parts.isEmpty ? null : parts;
}

Future<void> handleBackup(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'GET') {
    await errJson(res, 405, 'Method not allowed');
    return;
  }
  final timestamp = fmtFileStamp(DateTime.now());
  final type = qp(req, 'type');

  // 备份仍然要求登录，避免未登录者直接拉走整个 data。
  final user = keweUserFromRequest(req);
  final uid = (user?.id ?? currentUserId).trim();
  if (uid.isEmpty) {
    await errJson(res, 401, '请先登录后再备份');
    return;
  }
  final requestedAccount = qp(req, 'account').trim();
  if (requestedAccount.isNotEmpty && requestedAccount != uid) {
    await errJson(res, 403, '只能由当前登录账号发起备份');
    return;
  }
  final safeUser = (user?.username ?? uid).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  List<String> roots;
  String namePrefix;
  switch (type) {
    case 'config':
      roots = ['models', 'whisper.cpp'];
      namePrefix = 'config_backup';
      break;
    case 'data':
      // ★ 核心修复：备份整个 data/，不是当前账号的 data/users/<userId>/。
      //   data/auth/users.sts、sessions.sts、master.key 必须一起备份，
      //   否则恢复后用户表缺失，会出现找不到用户名/密码、登录失效。
      roots = ['data'];
      namePrefix = 'data_backup';
      break;
    default:
      roots = ['data', 'models', 'whisper.cpp'];
      namePrefix = 'wordbook_backup';
  }
  final filename = '${namePrefix}_${safeUser}_$timestamp.tar.gz';

  if (roots.contains('data') && !Directory('$BASE_DIR/data').existsSync()) {
    await errJson(res, 500, 'data 目录不存在，无法备份');
    return;
  }

  ensureDir(BACKUP_TMP_DIR);
  final tmpPath =
      '$BACKUP_TMP_DIR/backup_${DateTime.now().microsecondsSinceEpoch}.tar.gz';

  try {
    final file = File(tmpPath).openSync(mode: FileMode.write);
    final gz = gzip.encoder.startChunkedConversion(_FileSink(file));
    final tar = TarWriter(gz);

    final dataRoot = '$BASE_DIR/data';
    for (final rootName in roots) {
      final isData = rootName == 'data';
      final rootPath = isData ? dataRoot : '$BASE_DIR/$rootName';
      final dir = Directory(rootPath);
      if (!dir.existsSync()) continue;
      final rootPrefix = rootPath.endsWith('/') ? rootPath : '$rootPath/';
      final entries = dir.listSync(recursive: true);
      // 先父后子，保证解压顺序合理
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final e in entries) {
        final rel = '$rootName/${e.path.substring(rootPrefix.length)}';
        final stat = FileStat.statSync(e.path);
        if (e is Directory) {
          await tar.addDir(rel, stat.modified);
        } else if (e is File) {
          try {
            await tar.addFile(rel, e.readAsBytesSync(), stat.modified);
          } catch (err) {
            logp('⚠️ 已跳过备份 ${e.path}: $err');
          }
        }
      }
    }
    await tar.close();
    try {
      file.flushSync();
      file.closeSync();
    } catch (_) {}
  } catch (e) {
    try {
      final f = File(tmpPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    await errJson(res, 500, '归档创建失败: $e');
    return;
  }

  final f = File(tmpPath);
  if (!f.existsSync()) {
    await errJson(res, 500, '无法打开临时文件');
    return;
  }
  logp('✅ 备份完成: $filename (${f.lengthSync()} 字节)');
  await serveFile(req, f, downloadName: filename, attachment: true);
  try {
    f.deleteSync();
  } catch (_) {}
}

class _FileSink implements Sink<List<int>> {
  final RandomAccessFile raf;
  _FileSink(this.raf);

  @override
  void add(List<int> data) => raf.writeFromSync(data);

  @override
  void close() {
    try {
      raf.flushSync();
    } catch (_) {}
  }
}

// ------------------------------------------------------------
// 恢复
// ------------------------------------------------------------
/// 从 multipart/form-data body 中提取第一个文件 part 的字节
Uint8List? extractMultipartFile(Uint8List body, String boundary) {
  final delim = utf8.encode('--$boundary');
  final indexes = <int>[];
  for (var i = 0; i + delim.length <= body.length; i++) {
    var match = true;
    for (var j = 0; j < delim.length; j++) {
      if (body[i + j] != delim[j]) {
        match = false;
        break;
      }
    }
    if (match) indexes.add(i);
  }
  if (indexes.length < 2) return null;
  for (var k = 0; k + 1 < indexes.length; k++) {
    final start = indexes[k] + delim.length;
    final end = indexes[k + 1];
    if (start >= end) continue;
    // 跳过 CRLF
    var p = start;
    while (p < end && (body[p] == 0x0D || body[p] == 0x0A)) {
      p++;
    }
    // 找 header 结束（\r\n\r\n）
    var headerEnd = -1;
    for (var i = p; i + 3 < end; i++) {
      if (body[i] == 0x0D &&
          body[i + 1] == 0x0A &&
          body[i + 2] == 0x0D &&
          body[i + 3] == 0x0A) {
        headerEnd = i + 4;
        break;
      }
    }
    if (headerEnd < 0) continue;
    final headers =
        utf8.decode(body.sublist(p, headerEnd), allowMalformed: true);
    if (!headers.toLowerCase().contains('filename')) continue;
    var dataEnd = end;
    // 去掉尾部 CRLF
    while (dataEnd > headerEnd &&
        (body[dataEnd - 1] == 0x0A || body[dataEnd - 1] == 0x0D)) {
      dataEnd--;
    }
    return Uint8List.sublistView(body, headerEnd, dataEnd);
  }
  return null;
}

Future<void> handleRestore(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await errJson(res, 405, 'Method not allowed');
    return;
  }

  final user = keweUserFromRequest(req);
  final uid = (user?.id ?? currentUserId).trim();
  if (uid.isEmpty) {
    await errJson(res, 401, '请先登录后再恢复');
    return;
  }

  Uint8List body;
  try {
    body = Uint8List.fromList(await readBodyBytes(req, limit: MAX_UPLOAD_SIZE));
  } catch (_) {
    await errJson(res, 400, '文件过大或解析失败');
    return;
  }

  Uint8List? archive;
  final contentType = req.headers.contentType;
  if (contentType != null &&
      contentType.mimeType == 'multipart/form-data' &&
      contentType.parameters['boundary'] != null) {
    archive = extractMultipartFile(body, contentType.parameters['boundary']!);
  } else {
    archive = body;
  }
  if (archive == null || archive.isEmpty) {
    await errJson(res, 400, '请上传备份文件');
    return;
  }

  // 先校验归档，确认是合法 gzip/tar 后才动现有数据。
  List<TarEntry> entries;
  try {
    final raw = gzip.decoder.convert(archive);
    entries = parseTar(Uint8List.fromList(raw));
  } catch (e) {
    await errJson(res, 400, '无效的gzip文件: $e');
    return;
  }

  // 判断是「整库备份」还是「旧版单账号备份」。
  // 整库备份必须带 data/auth/users.sts + data/auth/master.key；只恢复单账号的
  // 旧备份不能拿来覆盖整个 data，否则会把其他账号的登录数据清空。
  var hasAuthUsers = false;
  var hasAuthKey = false;
  var hasAuthRoot = false;
  var hasUsersRoot = false;
  for (final e in entries) {
    final parts = _safeTarParts(e.name);
    if (parts == null || parts.isEmpty || parts[0] != 'data') continue;
    if (parts.length >= 3 && parts[1] == 'auth' && parts[2] == 'users.sts') {
      hasAuthUsers = true;
    }
    if (parts.length >= 3 && parts[1] == 'auth' && parts[2] == 'master.key') {
      hasAuthKey = true;
    }
    if (parts.length >= 2 && parts[1] == 'auth') hasAuthRoot = true;
    if (parts.length >= 2 && parts[1] == 'users') hasUsersRoot = true;
  }
  final isFullBackup = hasAuthUsers && hasAuthKey;
  if (!isFullBackup && (hasAuthRoot || hasUsersRoot)) {
    await errJson(res, 400,
        '这是旧版/不完整的单账号备份，缺少 data/auth/users.sts 或 master.key；'
        '为避免清空其他账号，拒绝按整库恢复');
    return;
  }

  final stamp = DateTime.now().microsecondsSinceEpoch;
  final stagingRoot = Directory('$BACKUP_TMP_DIR/restore_$stamp');
  final stagingData = Directory('${stagingRoot.path}/data');
  var extracted = 0;
  var oldPath = '';
  try {
    if (stagingRoot.existsSync()) stagingRoot.deleteSync(recursive: true);
    stagingData.createSync(recursive: true);

    // 先完整解压到 staging，任何写入失败都不会提前删除现有 data。
    for (final e in entries) {
      final parts = _safeTarParts(e.name);
      if (parts == null) {
        logp('⚠️ 已跳过非法路径: ${e.name}');
        continue;
      }
      if (parts[0] != 'data') {
        logp('⚠️ 已跳过非 data 条目: ${e.name}');
        continue;
      }
      if (parts.length == 1) {
        if (e.typeflag == '5') stagingData.createSync(recursive: true);
        continue;
      }
      final rel = parts.sublist(1).join('/');
      final target = '${stagingData.path}/$rel';
      if (e.typeflag == '5') {
        Directory(target).createSync(recursive: true);
      } else if (e.typeflag == '0' || e.typeflag == '') {
        final idx = target.lastIndexOf('/');
        if (idx > 0) ensureDir(target.substring(0, idx));
        File(target).writeAsBytesSync(e.data);
        extracted++;
      }
    }

    if (isFullBackup) {
      final usersFile = File('${stagingData.path}/auth/users.sts');
      final keyFile = File('${stagingData.path}/auth/master.key');
      if (!usersFile.existsSync() || usersFile.lengthSync() == 0) {
        throw const FormatException('备份缺少 data/auth/users.sts，恢复后会登录失败，已拒绝');
      }
      if (!keyFile.existsSync() || keyFile.lengthSync() != 32) {
        throw const FormatException('备份缺少有效的 32 字节 data/auth/master.key，已拒绝');
      }
    } else {
      if (extracted == 0) {
        throw const FormatException('备份中没有可恢复的 data/ 内容');
      }
      final legacyRoot = user?.dataDir ?? '';
      if (legacyRoot.isEmpty || legacyRoot == '$BASE_DIR/data') {
        throw const FormatException('当前账号数据目录无效');
      }
    }

    final String targetRoot;
    if (isFullBackup) {
      targetRoot = '$BASE_DIR/data';
    } else {
      targetRoot = user?.dataDir ?? '';
    }

    // 关键：先改名保留旧数据，再换新目录；失败回滚，不做不可逆删除。
    oldPath = '$targetRoot.restore-old-$stamp';
    final current = Directory(targetRoot);
    try {
      if (current.existsSync()) current.renameSync(oldPath);
      stagingData.renameSync(targetRoot);
    } catch (e) {
      if (!Directory(targetRoot).existsSync() && Directory(oldPath).existsSync()) {
        try {
          Directory(oldPath).renameSync(targetRoot);
          logp('⚠️ 恢复失败，已回滚旧数据: $targetRoot');
        } catch (rollbackErr) {
          logp('❌ 恢复失败且回滚失败: $targetRoot ($rollbackErr)；旧数据保留在 $oldPath');
        }
      }
      rethrow;
    }

    if (isFullBackup) {
      // 备份里的 master.key 已经替换 data/auth/master.key；必须丢掉旧 key 缓存。
      resetKeweSecretCaches();
      final token = keweSessionTokenFromRequest(req);
      if (token != null && token.isNotEmpty) {
        try {
          kewePreserveSessionForUser(token, uid);
        } catch (e) {
          logp('⚠️ 恢复后保留当前登录 token 失败: $e');
        }
      }
    }
    invalidateDsFileMetaCache();
    invalidateAllDsSessionCaches();
    invalidateDsSearchCache();

    logp('✅ ${isFullBackup ? '整库' : '单账号'}恢复完成: 已展开 $extracted 个文件；旧数据保留在 $oldPath');
    await dsJSONOk(res, 200, {
      'success': true,
      'message': isFullBackup ? '整库恢复成功' : '当前账号恢复成功',
      'mode': isFullBackup ? 'full' : 'account',
      'extracted': extracted,
      'oldDataDir': oldPath,
    });
  } on FormatException catch (e) {
    await errJson(res, 400, e.message);
  } catch (e) {
    await errJson(res, 500, '恢复失败: $e');
  } finally {
    try {
      if (stagingRoot.existsSync()) stagingRoot.deleteSync(recursive: true);
    } catch (_) {}
  }
}
