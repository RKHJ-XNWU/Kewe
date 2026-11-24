// ============================================================
// files.dart —— DeepSeek 文件管理（分片上传 / 下载 / 元数据 .sts）
// 100% 对齐 Go 版 ds-files.go，元数据格式保持不变：
//   metadata: data/ds_files/meta/ds_file_YYYY-MM.sts
//   line: id|name|size|mime|category|createdAt|relPath|source|prompt
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'globals.dart';
import 'httpsrv.dart';
import 'kewe_secrets.dart';

String get DSFilesDir => '$DATA_DIR/ds_files';
String get DSFilesMetaDir => '$DSFilesDir/meta';
String get DSFilesBlobDir => '$DSFilesDir/blob';
String get DSFilesChunksDir => '$DSFilesDir/chunks';

const int DS_MAX_FILE_SIZE = 5 * 1024 * 1024 * 1024; // 5GB
const int DS_CHUNK_SIZE = 64 * 1024 * 1024; // 64MB (OOM fix)
const Duration DS_UPLOAD_SESSION_TTL = Duration(hours: 1);
const Duration DS_ORPHAN_GRACE_PERIOD = Duration(minutes: 30);

Timer? _uploadCleaner;

void initDsFilesDir() {
  for (final d in [DSFilesDir, DSFilesMetaDir, DSFilesBlobDir, DSFilesChunksDir]) {
    ensureDir(d);
  }
  cleanupStaleUploadSessions();
  _uploadCleaner ??= Timer.periodic(
      const Duration(minutes: 10), (_) => cleanupStaleUploadSessions());
}

void cleanupStaleUploadSessions() {
  List<FileSystemEntity> entries;
  try {
    entries = Directory(DSFilesChunksDir).listSync();
  } catch (_) {
    return;
  }
  final cutoff = DateTime.now().subtract(DS_UPLOAD_SESSION_TTL);
  var cleaned = 0;
  for (final e in entries) {
    try {
      final st = FileStat.statSync(e.path);
      if (st.modified.isBefore(cutoff)) {
        if (e is Directory) {
          e.deleteSync(recursive: true);
        } else {
          e.deleteSync();
        }
        cleaned++;
      }
    } catch (_) {}
  }
  if (cleaned > 0) logp('🧹 已清理 $cleaned 个过期的上传会话');
}

String sanitizeFileName(String name) {
  var n = name.split('/').last.split('\\').last;
  n = n
      .replaceAll('..', '_')
      .replaceAll('/', '_')
      .replaceAll('\\', '_')
      .replaceAll('|', '_')
      .replaceAll('\x00', '_');
  if (n.isEmpty || n == '.') n = 'file';
  if (n.length > 200) n = n.substring(0, 200);
  return n;
}

/// 递归删除空父目录（不越过 rootDir）
void removeEmptyParentDirs(String startPath, String rootDir) {
  String norm(String p) {
    var parts = p.split('/').where((s) => s.isNotEmpty).toList();
    return '/${parts.join('/')}';
  }

  final cleanRoot = norm(rootDir);
  var dir = norm(startPath);
  if (dir == cleanRoot || !dir.startsWith('$cleanRoot/')) return;
  while (dir != cleanRoot && dir.startsWith(cleanRoot)) {
    try {
      Directory(dir).deleteSync(); // 非空会抛异常
      logp('🗑️ 已删除空目录: $dir');
    } catch (_) {
      break;
    }
    final idx = dir.lastIndexOf('/');
    if (idx <= 0) break;
    dir = dir.substring(0, idx);
  }
}

// ------------------------------------------------------------
// 元数据
// ------------------------------------------------------------
class DsFileMeta {
  String id;
  String name;
  int size;
  String mimeType;
  String category;
  String createdAt;
  String relPath;
  String source;
  String prompt;

  DsFileMeta({
    required this.id,
    required this.name,
    required this.size,
    required this.mimeType,
    required this.category,
    required this.createdAt,
    required this.relPath,
    required this.source,
    this.prompt = '',
  });

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'name': name,
      'size': size,
      'mimeType': mimeType,
      'category': category,
      'createdAt': createdAt,
      'relPath': relPath,
      'source': source,
    };
    if (prompt.isNotEmpty) m['prompt'] = prompt;
    return m;
  }
}

String dsFileMetaFile(DateTime t) => 'ds_file_${fmtYearMonth(t)}.sts';

bool saveDsFileMeta(DsFileMeta m) {
  var t = DateTime.tryParse(m.createdAt);
  if (t == null) t = DateTime.now();
  final fp = '$DSFilesMetaDir/${dsFileMetaFile(t)}';
  final line = '${m.id}|${escF(m.name)}|${m.size}|${m.mimeType}|${m.category}|'
      '${m.createdAt}|${escF(m.relPath)}|${m.source}|${escF(m.prompt)}\n';
  try {
    ensureDir(DSFilesMetaDir);
    File(fp).writeAsStringSync(line, mode: FileMode.append);
    invalidateDsFileMetaCache();
    return true;
  } catch (e) {
    logp('❌ 文件元数据保存失败: $e');
    return false;
  }
}

List<DsFileMeta> getAllDsFiles() {
  List<FileSystemEntity> files;
  try {
    files = Directory(DSFilesMetaDir).listSync();
  } catch (_) {
    return [];
  }
  final all = <DsFileMeta>[];
  for (final f in files) {
    if (f is! File) continue;
    final name = f.uri.pathSegments.last;
    if (!name.startsWith('ds_file_') || !name.endsWith('.sts')) continue;
    String data;
    try {
      data = f.readAsStringSync();
    } catch (_) {
      continue;
    }
    for (var line in data.split('\n')) {
      line = line.trim();
      if (line.isEmpty) continue;
      final parts = line.split('|');
      if (parts.length < 8) continue;
      all.add(DsFileMeta(
        id: parts[0],
        name: unescF(parts[1]),
        size: int.tryParse(parts[2]) ?? 0,
        mimeType: parts[3],
        category: parts[4],
        createdAt: parts[5],
        relPath: unescF(parts[6]),
        source: parts[7],
        prompt: parts.length >= 9 ? unescF(parts[8]) : '',
      ));
    }
  }
  all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return all;
}

Map<String, DsFileMeta>? _metaCache;
DateTime _metaCacheTime = DateTime.fromMillisecondsSinceEpoch(0);
const Duration _META_CACHE_TTL = Duration(seconds: 3);

void invalidateDsFileMetaCache() {
  _metaCache = null;
  _metaCacheTime = DateTime.fromMillisecondsSinceEpoch(0);
}

DsFileMeta? getDsFileMeta(String id) {
  if (id.isEmpty) return null;
  final now = DateTime.now();
  if (_metaCache == null || now.difference(_metaCacheTime) > _META_CACHE_TTL) {
    final all = getAllDsFiles();
    final m = <String, DsFileMeta>{};
    for (final f in all) {
      m[f.id] = f;
    }
    _metaCache = m;
    _metaCacheTime = now;
  }
  return _metaCache![id];
}

/// 删除元数据 + 物理文件 + 递归清理空目录
void deleteDsFileMeta(String id) {
  if (id.isEmpty) return;
  List<FileSystemEntity> files;
  try {
    files = Directory(DSFilesMetaDir).listSync();
  } catch (_) {
    return;
  }
  var anyDeleted = false;
  for (final f in files) {
    if (f is! File) continue;
    final name = f.uri.pathSegments.last;
    if (!name.startsWith('ds_file_') || !name.endsWith('.sts')) continue;
    String data;
    try {
      data = f.readAsStringSync();
    } catch (_) {
      continue;
    }
    final lines = data.split('\n');
    final newLines = <String>[];
    var found = false;
    for (var line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('|');
      if (parts.isNotEmpty && parts[0] == id) {
        found = true;
        if (parts.length >= 7) {
          final relPath = unescF(parts[6]);
          if (relPath.isNotEmpty) {
            final absPath = '$DSFilesBlobDir/$relPath';
            try {
              final file = File(absPath);
              if (file.existsSync()) {
                file.deleteSync();
                logp('🗑️ 已删除文件: $relPath');
              }
            } catch (e) {
              logp('❌ 文件删除失败: $e');
            }
            final dir = absPath.substring(0, absPath.lastIndexOf('/'));
            removeEmptyParentDirs(dir, DSFilesBlobDir);
          }
        }
        continue;
      }
      newLines.add(trimmed);
    }
    if (found) {
      anyDeleted = true;
      try {
        if (newLines.isEmpty) {
          f.deleteSync();
        } else {
          f.writeAsStringSync('${newLines.join('\n')}\n');
        }
      } catch (_) {}
    }
  }
  if (anyDeleted) invalidateDsFileMetaCache();
}

// ------------------------------------------------------------
// 分类
// ------------------------------------------------------------
const Set<String> _codeExts = {
  '.go', '.js', '.ts', '.py', '.java', '.c', '.cpp', '.h', '.hpp', '.cs',
  '.rb', '.php', '.swift', '.kt', '.rs', '.html', '.css', '.scss', '.less',
  '.xml', '.yaml', '.yml', '.toml', '.sh', '.bat', '.ps1', '.sql',
  '.clang', '.cxx', '.cc', '.m', '.mm', '.dart',
};

const Set<String> _docExts = {
  '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.md',
  '.csv', '.json', '.rtf', '.odt', '.epub', '.ini', '.conf', '.cfg', '.log',
};

const Set<String> _mcExts = {
  '.litematic', '.nbt', '.schematic', '.mcstructure',
};

String _extOf(String filename) {
  final i = filename.lastIndexOf('.');
  if (i < 0) return '';
  return filename.substring(i).toLowerCase();
}

String categorizeFile(String mimeType, String filename) {
  final ext = _extOf(filename);
  if (mimeType.startsWith('image/')) return 'image';
  if (mimeType.startsWith('video/')) return 'video';
  if (mimeType.startsWith('audio/')) return 'audio';
  if (_codeExts.contains(ext)) return 'code';
  if (_docExts.contains(ext)) return 'document';
  if (_mcExts.contains(ext)) return 'minecraft';
  return 'other';
}

// ------------------------------------------------------------
// HTTP：分片上传
// ------------------------------------------------------------
Future<void> handleDsFileUploadStart(HttpRequest req) async {
  if (req.method != 'POST') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await errJson(req.response, 400, '无效的请求体');
    return;
  }
  final fileName = sanitizeFileName(mStr(body, 'fileName'));
  final fileSize = intArgDefault(body, 'fileSize', 0);
  final mimeType = mStr(body, 'mimeType');
  if (fileName.isEmpty) {
    await errJson(req.response, 400, '文件名为必填项');
    return;
  }
  if (fileSize <= 0) {
    await errJson(req.response, 400, '文件大小无效');
    return;
  }
  if (fileSize > DS_MAX_FILE_SIZE) {
    await errJson(req.response, 413,
        '文件超过 5GB 上限（当前 ${(fileSize / (1 << 30)).toStringAsFixed(2)} GB）');
    return;
  }

  final uploadID = 'up_${fmtStamp14(DateTime.now())}_${randomHex(6)}';
  var totalChunks = (fileSize + DS_CHUNK_SIZE - 1) ~/ DS_CHUNK_SIZE;
  if (totalChunks < 1) totalChunks = 1;

  final chunkDir = '$DSFilesChunksDir/$uploadID';
  ensureDir(chunkDir);
  final sess = {
    'uploadId': uploadID,
    'fileName': fileName,
    'fileSize': fileSize,
    'mimeType': mimeType,
    'totalChunks': totalChunks,
    'createdAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  };
  if (!writeTextFile('$DSFilesChunksDir/$uploadID.json', jsonEncode(sess))) {
    try {
      Directory(chunkDir).deleteSync(recursive: true);
    } catch (_) {}
    await errJson(req.response, 500, '会话写入失败');
    return;
  }
  await jsonResponse(req.response, 200, {
    'success': true,
    'uploadId': uploadID,
    'totalChunks': totalChunks,
    'chunkSize': DS_CHUNK_SIZE,
  });
}

Future<void> handleDsFileUploadChunk(HttpRequest req) async {
  if (req.method != 'POST') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  final uploadID = qp(req, 'uploadId');
  final chunkIdxStr = qp(req, 'chunkIndex');
  if (uploadID.isEmpty || chunkIdxStr.isEmpty) {
    await errJson(req.response, 400, '缺少参数');
    return;
  }
  if (uploadID.contains('/') ||
      uploadID.contains('\\') ||
      uploadID.contains('..') ||
      uploadID.contains('|')) {
    await errJson(req.response, 400, '参数非法');
    return;
  }
  final chunkIdx = int.tryParse(chunkIdxStr);
  if (chunkIdx == null || chunkIdx < 0) {
    await errJson(req.response, 400, '分片索引无效');
    return;
  }

  final sessPath = '$DSFilesChunksDir/$uploadID.json';
  if (!File(sessPath).existsSync()) {
    await errJson(req.response, 404, '上传会话不存在');
    return;
  }
  Map<String, dynamic> sess;
  try {
    sess = asMap(jsonDecode(File(sessPath).readAsStringSync()));
  } catch (_) {
    await errJson(req.response, 500, '会话已损坏');
    return;
  }
  final totalChunks = intArgDefault(sess, 'totalChunks', 0);
  if (chunkIdx >= totalChunks) {
    await errJson(req.response, 400, '分片索引越界');
    return;
  }

  List<int> chunkData;
  try {
    chunkData = await readBodyBytes(req, limit: DS_CHUNK_SIZE + (1 << 16));
  } catch (_) {
    try {
      Directory('$DSFilesChunksDir/$uploadID').deleteSync(recursive: true);
      File(sessPath).deleteSync();
    } catch (_) {}
    await errJson(req.response, 500, '分块读取失败（可能超过大小上限）');
    return;
  }
  if (chunkData.isEmpty) {
    await errJson(req.response, 400, '分块为空');
    return;
  }

  final chunkDir = '$DSFilesChunksDir/$uploadID';
  ensureDir(chunkDir);
  final chunkPath = '$chunkDir/${chunkIdx.toString().padLeft(6, '0')}.part';
  try {
    File(chunkPath).writeAsBytesSync(chunkData);
  } catch (_) {
    await errJson(req.response, 500, '分块写入失败');
    return;
  }
  await jsonResponse(req.response, 200, {
    'success': true,
    'index': chunkIdx,
    'size': chunkData.length,
  });
}

bool mergeChunks(String absPath, String chunkDir, int totalChunks) {
  // OOM fix: 1MB/chunk streaming copy instead of readAsBytesSync whole file
  RandomAccessFile? outRaf;
  try {
    ensureDir(absPath.substring(0, absPath.lastIndexOf('/')));
    final out = File(absPath).openSync(mode: FileMode.write);
    outRaf = out;
    const blockSize = 1024 * 1024;
    for (var i = 0; i < totalChunks; i++) {
      final partPath = '$chunkDir/${i.toString().padLeft(6, '0')}.part';
      final pf = File(partPath);
      if (!pf.existsSync()) {
        logp('❌ 分片 $i 缺失');
        return false;
      }
      final input = pf.openSync();
      try {
        while (true) {
          final buf = input.readSync(blockSize);
          if (buf.isEmpty) break;
          out.writeFromSync(buf);
        }
      } finally {
        input.closeSync();
      }
    }
    out.flushSync();
    return true;
  } catch (e) {
    logp('❌ 分块合并失败: $e');
    return false;
  } finally {
    try {
      outRaf?.closeSync();
    } catch (_) {}
  }
}

Future<void> handleDsFileUploadComplete(HttpRequest req) async {
  if (req.method != 'POST') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await errJson(req.response, 400, '无效的请求体');
    return;
  }
  final uploadID = mStr(body, 'uploadId');
  if (uploadID.isEmpty ||
      uploadID.contains('/') ||
      uploadID.contains('\\') ||
      uploadID.contains('..') ||
      uploadID.contains('|')) {
    await errJson(req.response, 400, '参数非法');
    return;
  }

  final sessPath = '$DSFilesChunksDir/$uploadID.json';
  if (!File(sessPath).existsSync()) {
    await errJson(req.response, 404, '上传会话不存在');
    return;
  }
  Map<String, dynamic> sess;
  try {
    sess = asMap(jsonDecode(File(sessPath).readAsStringSync()));
  } catch (_) {
    try {
      Directory('$DSFilesChunksDir/$uploadID').deleteSync(recursive: true);
      File(sessPath).deleteSync();
    } catch (_) {}
    await errJson(req.response, 400, '上传会话已损坏');
    return;
  }

  final chunkDir = '$DSFilesChunksDir/$uploadID';
  final fileName = sanitizeFileName(mStr(sess, 'fileName'));
  final fileSize = intArgDefault(sess, 'fileSize', 0);
  final mimeType = mStr(sess, 'mimeType');
  final totalChunks = intArgDefault(sess, 'totalChunks', 0);

  for (var i = 0; i < totalChunks; i++) {
    final partPath = '$chunkDir/${i.toString().padLeft(6, '0')}.part';
    final pf = File(partPath);
    if (!pf.existsSync()) {
      try {
        Directory(chunkDir).deleteSync(recursive: true);
        File(sessPath).deleteSync();
      } catch (_) {}
      await errJson(req.response, 500, '分片 $i 缺失');
      return;
    }
    if (pf.lengthSync() == 0) {
      try {
        Directory(chunkDir).deleteSync(recursive: true);
        File(sessPath).deleteSync();
      } catch (_) {}
      await errJson(req.response, 500, '分块 $i 为空');
      return;
    }
  }

  final fileID = 'f_${fmtStamp14(DateTime.now())}_${randomHex(6)}';
  final relDir = '${fileID.substring(0, 2)}/$fileID';
  final relPath = '$relDir/$fileName';
  final absPath = '$DSFilesBlobDir/$relPath';

  void cleanup() {
    try {
      final f = File(absPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    try {
      Directory(chunkDir).deleteSync(recursive: true);
    } catch (_) {}
    try {
      final f = File(sessPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  if (!mergeChunks(absPath, chunkDir, totalChunks)) {
    cleanup();
    await errJson(req.response, 500, '分块合并失败');
    return;
  }

  final stat = FileStat.statSync(absPath);
  if (stat.size != fileSize) {
    cleanup();
    await errJson(req.response, 500, '大小不一致: 期望 $fileSize、实际 ${stat.size}');
    return;
  }

  // 合并校验通过后立即加密落盘；原始路径从此只存密文。
  if (currentUserId.isNotEmpty && !encryptDsFileAtRest(absPath)) {
    cleanup();
    await errJson(req.response, 500, '文件加密失败');
    return;
  }

  final category = categorizeFile(mimeType, fileName);
  final meta = DsFileMeta(
    id: fileID,
    name: fileName,
    size: fileSize,
    mimeType: mimeType,
    category: category,
    createdAt: rfc3339(DateTime.now()),
    relPath: relPath,
    source: 'upload',
  );
  if (!saveDsFileMeta(meta)) {
    cleanup();
    await errJson(req.response, 500, '元数据保存失败');
    return;
  }

  try {
    Directory(chunkDir).deleteSync(recursive: true);
    File(sessPath).deleteSync();
  } catch (_) {}
  invalidateDsFileMetaCache();

  await jsonResponse(req.response, 200, {
    'success': true,
    'fileId': fileID,
    'name': fileName,
    'size': fileSize,
    'category': category,
    'mimeType': mimeType,
    'url': '/api/ds-files/download?id=$fileID',
  });
}

// ------------------------------------------------------------
// HTTP：下载 / 列表 / 删除
// ------------------------------------------------------------
Future<void> handleDsFileDownload(HttpRequest req) async {
  final id = qp(req, 'id');
  if (id.isEmpty) {
    await errJson(req.response, 400, '缺少 id');
    return;
  }
  final meta = getDsFileMeta(id);
  if (meta == null) {
    await errJson(req.response, 404, '文件不存在');
    return;
  }
  await serveDsFile(req, meta);
}

Future<void> handleDsFileList(HttpRequest req) async {
  if (req.method != 'GET') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  final res = req.response;
  res.headers.set('Cache-Control', 'no-cache, no-store, must-revalidate');
  res.headers.set('Pragma', 'no-cache');
  res.headers.set('Expires', '0');

  var files = getAllDsFiles();
  final cat = qp(req, 'category');
  if (cat.isNotEmpty && cat != 'all') {
    files = files.where((f) => f.category == cat).toList();
  }
  await jsonResponse(res, 200, {
    'files': files.map((f) => f.toJson()).toList(),
  });
}

Future<void> handleDsFileDelete(HttpRequest req) async {
  if (req.method != 'DELETE') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  final id = qp(req, 'id');
  if (id.isEmpty) {
    await errJson(req.response, 400, '缺少 id');
    return;
  }
  deleteDsFileMeta(id);
  await jsonResponse(req.response, 200, {'success': true});
}

Future<void> handleDsFileClearAll(HttpRequest req) async {
  if (req.method != 'DELETE') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  // ★ 修复：原先清空接口完全没有日志，前端点了「清空」后端一片沉默，
  //   用户无法判断到底有没有真的清掉。现在清空前统计、清空后逐项回显。
  final sw = Stopwatch()..start();
  final beforeFiles = getAllDsFiles().length;
  logp('🗑️ 受信：清空全部文件（清空前 $beforeFiles 个文件）');
  var removedDirs = 0;
  for (final d in [DSFilesMetaDir, DSFilesBlobDir, DSFilesChunksDir]) {
    try {
      final dir = Directory(d);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
        removedDirs++;
        logp('   ✅ 已删除目録: $d');
      } else {
        logp('   · 目録不存在、跳过: $d');
      }
    } catch (e) {
      logp('   ❌ 删除失败: $d（$e）');
    }
  }
  initDsFilesDir();
  invalidateDsFileMetaCache();
  final afterFiles = getAllDsFiles().length;
  logp('✅ 清空完成：删除 $removedDirs 个目録、$beforeFiles → $afterFiles 个文件、耗时 ${sw.elapsedMilliseconds}ms');
  await jsonResponse(req.response, 200, {
    'success': true,
    'removed': beforeFiles,
    'remaining': afterFiles,
  });
}

// ------------------------------------------------------------
// 落盘加密（KEWEFILE1 分块容器）
//   · 每个分块使用当前账号的 AES-256-GCM 密钥独立封装；
//   · 原始 blob 文件本身只保存密文行，文件管理器直接打开必然是乱码；
//   · 下载/视觉读取/转写时再按账号密钥还原明文，前端拿到的仍是原始内容。
// ------------------------------------------------------------
const String KEWE_FILE_MAGIC = 'KEWEFILE1';
const int KEWE_FILE_CHUNK = 512 * 1024;

bool dsIsEncryptedFile(String absPath) {
  final f = File(absPath);
  if (!f.existsSync()) return false;
  RandomAccessFile? raf;
  try {
    raf = f.openSync();
    final head = raf.readSync(10);
    if (head.length < KEWE_FILE_MAGIC.length) return false;
    final text = utf8.decode(head, allowMalformed: true);
    return text.startsWith(KEWE_FILE_MAGIC);
  } catch (_) {
    return false;
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {}
  }
}

bool encryptDsFileAtRest(String absPath) {
  if (currentUserId.isEmpty) return false;
  final src = File(absPath);
  if (!src.existsSync()) return false;
  if (dsIsEncryptedFile(absPath)) return true;
  final tmpPath = '$absPath.kewe-tmp';
  final out = File(tmpPath).openSync(mode: FileMode.write);
  RandomAccessFile? input;
  try {
    out.writeStringSync('$KEWE_FILE_MAGIC\n');
    input = src.openSync();
    while (true) {
      final chunk = input.readSync(KEWE_FILE_CHUNK);
      if (chunk.isEmpty) break;
      final sealed = keweEncryptBytesForUser(currentUserId, chunk);
      out.writeStringSync('${base64.encode(sealed)}\n');
    }
    out.flushSync();
  } catch (e) {
    logp('❌ 文件加密失败: $absPath ($e)');
    return false;
  } finally {
    try {
      input?.closeSync();
    } catch (_) {}
    try {
      out.closeSync();
    } catch (_) {}
  }
  try {
    File(tmpPath).renameSync(absPath);
    return true;
  } catch (e) {
    try {
      File(tmpPath).deleteSync();
    } catch (_) {}
    logp('❌ 加密文件替换失败: $absPath ($e)');
    return false;
  }
}

/// 读取明文（可选前缀上限，用于大文本抽取）。
Uint8List dsReadPlainFileBytes(String absPath, {int? maxBytes}) {
  final f = File(absPath);
  if (!f.existsSync()) return Uint8List(0);
  if (!dsIsEncryptedFile(absPath)) {
    final raw = f.readAsBytesSync();
    if (maxBytes != null && raw.length > maxBytes) {
      return Uint8List.sublistView(raw, 0, maxBytes);
    }
    return raw;
  }
  if (currentUserId.isEmpty) {
    throw StateError('加密文件需要登录账号密钥');
  }
  final builder = BytesBuilder(copy: false);
  final lines = f.readAsLinesSync();
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final plain = keweDecryptBytesForUser(currentUserId, base64.decode(line));
    if (maxBytes != null && builder.length + plain.length > maxBytes) {
      final need = maxBytes - builder.length;
      if (need > 0) builder.add(Uint8List.sublistView(plain, 0, need));
      break;
    }
    builder.add(plain);
  }
  return builder.takeBytes();
}

/// 解密到临时文件，供支持 Range 的 serveFile 使用。
/// 返回的文件位于系统临时目录，调用方发送完必须删除。
Future<File> dsDecryptFileToTemp(String absPath, {String? hintName}) async {
  if (!dsIsEncryptedFile(absPath)) return File(absPath);
  if (currentUserId.isEmpty) {
    throw StateError('加密文件需要登录账号密钥');
  }
  final dir = Directory.systemTemp.createTempSync('kewe-file-');
  var safe = (hintName ?? 'file.bin')
      .replaceAll('/', '_')
      .replaceAll('\\', '_')
      .replaceAll('\x00', '_');
  if (safe.length > 120) safe = safe.substring(0, 120);
  final out = File('${dir.path}/$safe');
  final sink = out.openWrite();
  try {
    var first = true;
    await for (final line in File(absPath)
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (first) {
        first = false;
        if (line.startsWith(KEWE_FILE_MAGIC)) continue;
      }
      final t = line.trim();
      if (t.isEmpty) continue;
      sink.add(keweDecryptBytesForUser(currentUserId, base64.decode(t)));
    }
    await sink.flush();
    await sink.close();
    return out;
  } catch (e) {
    try {
      await sink.close();
    } catch (_) {}
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
    throw StateError('文件解密失败: $e');
  }
}

Future<void> serveDsFile(HttpRequest req, DsFileMeta meta) async {
  final absPath = '$DSFilesBlobDir/${meta.relPath}';
  if (!File(absPath).existsSync()) {
    await errJson(req.response, 404, '文件不存在');
    return;
  }
  if (!dsIsEncryptedFile(absPath)) {
    await serveFile(req, File(absPath),
        downloadName: meta.name,
        attachment: req.uri.queryParameters['download'] == '1');
    return;
  }
  // 加密文件直接流式解密到 HTTP 响应，不再先落临时文件。
  // 这样 HEAD / 图片预览 / 附件下载都能立即收到响应头，不会一直“加载中”。
  await serveEncryptedDsFile(req, meta, absPath);
}

/// 加密文件流式下载：边解密边发送，支持 Range，且不产生明文临时文件。
Future<void> serveEncryptedDsFile(
    HttpRequest req, DsFileMeta meta, String absPath) async {
  final res = req.response;
  final total = meta.size;
  final attachment = req.uri.queryParameters['download'] == '1';
  final mime = meta.mimeType.isNotEmpty ? meta.mimeType : mimeByExt(meta.name);

  res.headers.set(
      HttpHeaders.contentTypeHeader,
      attachment ? 'application/octet-stream' : mime);
  res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  res.headers.set('content-disposition',
      contentDispositionValue(meta.name, attachment));
  res.headers.set('cache-control',
      attachment ? 'no-store' : 'private, max-age=60, must-revalidate');

  var start = 0;
  var end = total - 1;
  final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
  if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
    final spec = rangeHeader.substring(6).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash >= 0) {
      final a = spec.substring(0, dash);
      final b = spec.substring(dash + 1);
      if (a.isEmpty) {
        final suffix = int.tryParse(b);
        if (suffix != null && suffix > 0) {
          start = total - suffix;
          if (start < 0) start = 0;
        }
      } else {
        final s = int.tryParse(a);
        if (s != null) start = s;
        if (b.isNotEmpty) {
          final e = int.tryParse(b);
          if (e != null) end = e;
        }
      }
      if (start < 0) start = 0;
      if (end >= total) end = total - 1;
      if (start > end || total == 0) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await res.close();
        return;
      }
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
      res.headers.contentLength = end - start + 1;
    }
  } else {
    res.headers.contentLength = total;
  }

  if (req.method == 'HEAD' || total == 0) {
    await res.close();
    return;
  }

  final want = end - start + 1;
  var pos = 0;
  var sent = 0;
  var firstLine = true;
  try {
    if (currentUserId.isEmpty) throw StateError('加密文件需要登录账号密钥');
    final lines = File(absPath)
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final raw in lines) {
      var line = raw.trim();
      if (firstLine) {
        firstLine = false;
        if (line.startsWith(KEWE_FILE_MAGIC)) continue;
      }
      if (line.isEmpty) continue;
      Uint8List plain;
      try {
        plain = keweDecryptBytesForUser(currentUserId, base64.decode(line));
      } catch (e) {
        throw StateError('文件密文损坏: $e');
      }
      final chunkStart = pos;
      final chunkEnd = pos + plain.length - 1;
      pos += plain.length;
      if (chunkEnd < start) continue;
      final from = start > chunkStart ? start - chunkStart : 0;
      final to = end < chunkEnd ? end - chunkStart + 1 : plain.length;
      if (from < to) {
        res.add(Uint8List.sublistView(plain, from, to));
        sent += to - from;
      }
      if (sent >= want) break;
    }
    if (sent < want) {
      logp('⚠️ 加密文件解密输出不足: ${meta.id} ($sent/$want)');
    }
    await res.flush();
  } catch (e) {
    logp('❌ 加密文件流式发送失败: ${meta.id} ($e)');
  } finally {
    try {
      await res.close();
    } catch (_) {}
  }
}

// ------------------------------------------------------------
// 转 base64（视觉模型用，32MiB 上限）
// ------------------------------------------------------------
({String b64, String mime, String? error}) dsFileToBase64(String fileID) {
  final meta = getDsFileMeta(fileID);
  if (meta == null) return (b64: '', mime: '', error: '文件不存在');
  if (meta.size > 32 * 1024 * 1024) {
    return (b64: '', mime: '', error: '图片超过 32MiB 上限（DeepSeek API 的限制）');
  }
  final absPath = '$DSFilesBlobDir/${meta.relPath}';
  Uint8List data;
  try {
    data = dsReadPlainFileBytes(absPath, maxBytes: 32 * 1024 * 1024);
  } catch (e) {
    return (b64: '', mime: '', error: '$e');
  }
  if (data.length > 32 * 1024 * 1024) {
    return (b64: '', mime: '', error: '图片超过 32MiB 上限（DeepSeek API 的限制）');
  }
  final mime = meta.mimeType.isEmpty ? 'image/jpeg' : meta.mimeType;
  return (b64: base64.encode(data), mime: mime, error: null);
}
