// ============================================================
// knowledge.dart —— 账号级知识库 / 数据库 / 模型长期记忆
//
// 设计目标：
//   · 每个账号一个独立知识库，路径 data/users/<userId>/knowledge/
//   · db.json 是可读的索引数据库，entries/<id>.md 是正文
//   · 不使用加密，便于后端直接编辑；不得跨账号读取
//   · 模型通过 knowledge_* 工具随时检索，同时每次聊天注入知识索引
// ============================================================

import 'dart:convert';
import 'dart:io';

import 'globals.dart';
import 'httpsrv.dart';

const int KEWE_KNOWLEDGE_MAX_TITLE = 160;
const int KEWE_KNOWLEDGE_MAX_CONTENT = 200000;
const int KEWE_KNOWLEDGE_MAX_ENTRIES = 5000;
const int KEWE_KNOWLEDGE_DB_VERSION = 2;
const String KEWE_KNOWLEDGE_DEFAULT_COLLECTION = 'general';

String get keweSharedKnowledgeRoot => '$BASE_DIR/knowledge';
String get keweAccountKnowledgeRoot => '$DATA_DIR/knowledge';
String get _keweKnowledgeDbPath => '${keweAccountKnowledgeRoot}/db.json';
String get _keweKnowledgeEntriesDir => '${keweAccountKnowledgeRoot}/entries';
String get _keweCollectionsPath => '$keweSharedKnowledgeRoot/db/collections.json';


/// ------------------------------------------------------------
/// 【降级诚实】知识库索引最近一次读取失败的原因。
///
/// 空串 = 读取正常（含「文件尚不存在」这种首次使用的正常情况）。
/// 非空 = 索引损坏 / 结构异常 / 无权限，**检索根本没有成功执行**。
///
/// 为什么必须单独记这个：旧实现在 catch 之后直接 return 空库，
/// 于是 searchKnowledge 返回空列表，上层把「没能检索」输出成
/// 「知识库中没有找到」，模型据此认为账号里没有这条事实，
/// 进而用通用知识编造 —— 空结果与失败混为一谈是幻觉的源头。
/// ------------------------------------------------------------
String knowledgeDbLastError = '';

/// 索引是否处于降级状态（不可信）。
bool get knowledgeDbDegraded => knowledgeDbLastError.isNotEmpty;

/// 最近一次检索中「条目存在但正文文件读不出来」的条数。
/// 单条静默丢失会让检索结果看起来像「内容为空」，同样必须可观测。
int knowledgeEntryReadFailures = 0;

/// 检索口径：空结果（查到了，但没有匹配）与失败（没能查）文案必须不同。
const String KEWE_KB_STATE_OK = 'ok';
const String KEWE_KB_STATE_EMPTY = 'empty';
const String KEWE_KB_STATE_DEGRADED = 'degraded';

String _keweNow() => rfc3339(DateTime.now());

/// ------------------------------------------------------------
/// 【敏感字段过滤 · 注入侧】把凭据类内容掩码，避免写进模型上下文。
///
/// 边界很明确：只处理「一旦泄露就能被直接滥用」的凭据
/// （sk- 密钥、Bearer 令牌、私钥块、password/apiKey 赋值）。
/// 刻意不掩码手机号与普通数字：紧急联系人号码是救人刚需，
/// 掩掉它等于在关键时刻让模型答不出号码。
/// 身份证号按 18 位严格格式掩码 —— 它是身份凭证而非联络数据。
/// ------------------------------------------------------------
String keweRedactSecrets(String text) {
  if (text.isEmpty) return text;
  var out = text;
  // OpenAI / DeepSeek 风格密钥：sk-xxxx
  out = out.replaceAllMapped(
      RegExp(r'sk-[A-Za-z0-9_\-]{8,}'),
      (m) => 'sk-***REDACTED***');
  // 其他常见前缀令牌
  out = out.replaceAllMapped(
      RegExp(r'(xox[baprs]-|ghp_|gho_|github_pat_|AIza)[A-Za-z0-9_\-]{8,}'),
      (m) => '${m.group(1)}***REDACTED***');
  // Authorization: Bearer xxx
  out = out.replaceAllMapped(
      RegExp(r'(Bearer\s+)[A-Za-z0-9._\-]{12,}'),
      (m) => '${m.group(1)}***REDACTED***');
  // password / apiKey / secret / token 赋值
  // 注意：Dart 的 RegExp 不支持 (?i) 内联标志，必须用 caseSensitive: false，
  // 否则构造 RegExp 时直接抛 FormatException，把整条保存路径打成异常。
  out = out.replaceAllMapped(
      RegExp(
          r'((?:password|passwd|api[_-]?key|secret|access[_-]?token|refresh[_-]?token)\s*[:=]\s*)([^\s,;，；]{6,})',
          caseSensitive: false),
      (m) => '${m.group(1)}***REDACTED***');
  // PEM 私钥块
  out = out.replaceAllMapped(
      RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----'),
      (m) => '-----BEGIN PRIVATE KEY-----***REDACTED***-----END PRIVATE KEY-----');
  // 18 位身份证号（严格校验末位可为 X）
  out = out.replaceAllMapped(
      RegExp(r'(?<![0-9])[1-9][0-9]{5}(?:19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx](?![0-9])'),
      (m) => '***ID-REDACTED***');
  return out;
}

/// ------------------------------------------------------------
/// 【敏感字段过滤 · 写入侧】检测凭据明文，命中则返回原因供上层拒绝写入。
///
/// 选择「拒绝」而不是「掩码后保存」：掩码会永久破坏用户原本的内容，
/// 且用户以为存进去了真实值、实际存的是星号，属于静默数据损坏。
/// 明确拒绝并说明原因，用户可以自行决定改成引用方式再存。
/// ------------------------------------------------------------
String keweDetectSecret(String text) {
  if (text.isEmpty) return '';
  if (RegExp(r'sk-[A-Za-z0-9_\-]{16,}').hasMatch(text)) {
    return '包含疑似 API 密钥（sk- 开头），拒绝写入知识库';
  }
  if (RegExp(r'(xox[baprs]-|ghp_|github_pat_|AIza)[A-Za-z0-9_\-]{16,}')
      .hasMatch(text)) {
    return '包含疑似访问令牌，拒绝写入知识库';
  }
  if (RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----').hasMatch(text)) {
    return '包含私钥块，拒绝写入知识库';
  }
  if (RegExp(r'(?:password|passwd|api[_-]?key|secret)\s*[:=]\s*\S{16,}',
          caseSensitive: false)
      .hasMatch(text)) {
    return '包含明文口令/密钥赋值，拒绝写入知识库';
  }
  return '';
}

String _keweSafeId(String raw) {
  final s = raw.trim().toLowerCase();
  if (RegExp(r'^[a-z0-9_-]{2,64}$').hasMatch(s)) return s;
  return 'k_${DateTime.now().millisecondsSinceEpoch}_${randomHex(5)}';
}

bool _keweSafeRelative(String path) {
  final p = path.replaceAll('\\', '/').trim();
  if (p.isEmpty || p.startsWith('/') || p.contains('..')) return false;
  return p.startsWith('skill.md') || p.startsWith('base/');
}

Map<String, dynamic> _emptyDb() => {
      'version': KEWE_KNOWLEDGE_DB_VERSION,
      'seedVersion': 0,
      'updatedAt': _keweNow(),
      'entries': <Map<String, dynamic>>[],
    };

String _normalizeCollection(String raw) {
  final s = raw.trim().toLowerCase();
  if (RegExp(r'^[a-z0-9_-]{2,32}$').hasMatch(s)) return s;
  return KEWE_KNOWLEDGE_DEFAULT_COLLECTION;
}

const Map<String, String> _keweCollectionAliases = {
  'core': 'core',
  'empire': 'core',
  'protocol': 'core',
  'emergency': 'emergency',
  'sos': 'emergency',
  'safety': 'emergency',
  'phone': 'phone',
  'adb': 'phone',
  'automation': 'phone',
  'site': 'site',
  'architecture': 'site',
  'data': 'site',
  'knowledge': 'knowledge',
  'memory': 'knowledge',
  'language': 'language',
  'i18n': 'language',
  'security': 'security',
  'execution': 'execution',
};

String _inferCollection(Map<String, dynamic> meta) {
  final explicit = '${meta['collection'] ?? ''}'.trim().toLowerCase();
  if (explicit.isNotEmpty) return _normalizeCollection(explicit);
  final tags = meta['tags'];
  if (tags is List) {
    for (final t in tags) {
      final v = _keweCollectionAliases['${t}'.trim().toLowerCase()];
      if (v != null) return v;
    }
  }
  return KEWE_KNOWLEDGE_DEFAULT_COLLECTION;
}

Map<String, String> _collectionTitles() {
  final out = <String, String>{
    'core': '核心协议',
    'emergency': '保命与应急',
    'phone': '手机自动化',
    'site': '站点与数据',
    'knowledge': '知识库运维',
    'language': '多语言',
    'security': '安全边界',
    'execution': '执行与交付',
  };
  try {
    final f = File(_keweCollectionsPath);
    if (f.existsSync()) {
      final decoded = jsonDecode(f.readAsStringSync());
      final list = decoded is Map ? decoded['collections'] : null;
      if (list is List) {
        for (final c in list) {
          if (c is Map) {
            final id = _normalizeCollection('${c['id'] ?? ''}');
            final title = '${c['title'] ?? ''}'.trim();
            if (id.isNotEmpty && title.isNotEmpty) out[id] = title;
          }
        }
      }
    }
  } catch (e) {
    logp('⚠️ 知识域元数据读取失败: $e');
  }
  return out;
}


Map<String, dynamic> _readDb() {
  // 每次读取都重置降级状态：调用方通过 knowledgeDbLastError 判断本次是否可信。
  knowledgeDbLastError = '';
  try {
    final f = File(_keweKnowledgeDbPath);
    // 文件不存在是「首次使用」的正常状态，不是故障 —— 不能标降级，
    // 否则新账号第一次提问就会收到「知识库不可用」的错误提示。
    if (!f.existsSync()) return _emptyDb();
    final decoded = jsonDecode(f.readAsStringSync());
    if (decoded is Map<String, dynamic>) {
      final entries = decoded['entries'];
      if (entries is List) {
        return {
          'version': (decoded['version'] is num)
              ? (decoded['version'] as num).toInt()
              : KEWE_KNOWLEDGE_DB_VERSION,
          'seedVersion': (decoded['seedVersion'] is num)
              ? (decoded['seedVersion'] as num).toInt()
              : 0,
          'updatedAt': decoded['updatedAt']?.toString() ?? _keweNow(),
          'entries': entries.whereType<Map>().map((e) {
            final m = Map<String, dynamic>.from(e);
            m['collection'] = _inferCollection(m);
            return m;
          }).toList(),
        };
      }
      // 结构异常：能解析但不是预期形状，同样属「不可信」，必须可上报。
      knowledgeDbLastError = 'db.json 结构异常：entries 不是数组';
      logp('⚠️ 知识库索引结构异常：entries 不是数组');
      return _emptyDb();
    }
    knowledgeDbLastError = 'db.json 顶层不是对象';
    logp('⚠️ 知识库索引结构异常：顶层不是对象');
    return _emptyDb();
  } catch (e) {
    // 这里保留「返回空库」以保证聊天不因知识库损坏而整体 500，
    // 但必须同时留下失败标志，让检索层如实说明「没能检索」。
    knowledgeDbLastError = '$e';
    logp('⚠️ 知识库索引损坏，将重建: $e');
  }
  return _emptyDb();
}

bool _writeDb(Map<String, dynamic> db) {
  db['version'] = KEWE_KNOWLEDGE_DB_VERSION;
  db['updatedAt'] = _keweNow();
  return writeTextFile(_keweKnowledgeDbPath,
      '${const JsonEncoder.withIndent('  ').convert(db)}\n',
      mode: 0x1A4 /* 0644 ~ readable for backend edits */);
}

Map<String, dynamic>? _findEntry(Map<String, dynamic> db, String id) {
  for (final e in (db['entries'] as List)) {
    if (e is Map && '${e['id']}' == id) return Map<String, dynamic>.from(e);
  }
  return null;
}

String _entryPath(Map<String, dynamic> meta) => '$keweAccountKnowledgeRoot/${meta['file']}';

void _ensureSeed() {
  ensureDir(keweAccountKnowledgeRoot);
  ensureDir(_keweKnowledgeEntriesDir);
  var seedVersion = 2;
  List<dynamic> seedEntries = const [];
  try {
    final seedFile = File('$keweSharedKnowledgeRoot/db/seed.json');
    if (seedFile.existsSync()) {
      final decoded = jsonDecode(seedFile.readAsStringSync());
      if (decoded is Map) {
        if (decoded['seedVersion'] is num) {
          seedVersion = (decoded['seedVersion'] as num).toInt();
        }
        if (decoded['entries'] is List) seedEntries = decoded['entries'] as List;
      }
    }
  } catch (e) {
    logp('⚠️ 知识库种子读取失败: $e');
  }

  final dbFile = File(_keweKnowledgeDbPath);
  final db = dbFile.existsSync() ? _readDb() : _emptyDb();
  // ★ 索引不可信时绝不写回：_emptyDb 的 seedVersion 是 0，一定会走到下面的
  //   「补齐种子 + _writeDb」，等于用空库覆盖掉用户原有的全部条目。
  //   那不只是数据丢失，还会把「读取失败」洗成「空库」，
  //   让上层把「没能检索」误报成「没有相关条目」。
  if (knowledgeDbDegraded) {
    logp('⛔ 知识库索引不可信，跳过种子写入以保留原始文件: $knowledgeDbLastError');
    return;
  }
  final currentSeedVersion =
      (db['seedVersion'] is num) ? (db['seedVersion'] as num).toInt() : 0;
  if (dbFile.existsSync() && currentSeedVersion >= seedVersion) return;

  final entries = db['entries'] as List;
  final existingIds = <String>{
    for (final e in entries.whereType<Map>()) '${e['id']}'
  };
  var added = 0;
  for (var i = 0; i < seedEntries.length; i++) {
    final raw = seedEntries[i];
    if (raw is! Map) continue;
    final id = _keweSafeId('${raw['id'] ?? 'seed_$i'}');
    if (existingIds.contains(id)) continue;
    final title = (raw['title'] ?? '知识 $i').toString().trim();
    final tagsRaw = raw['tags'];
    final tags = tagsRaw is List
        ? tagsRaw.map((t) => t.toString()).where((t) => t.isNotEmpty).toList()
        : <String>[];
    final collection = _normalizeCollection('${raw['collection'] ?? ''}');
    final content = (raw['content'] ?? '').toString();
    final rel = 'entries/$id.md';
    ensureDir('$keweAccountKnowledgeRoot/entries');
    writeTextFile(
        '$keweAccountKnowledgeRoot/$rel',
        '# $title\n\n${content.trim()}\n\n<!-- collection: $collection · tags: ${tags.join(', ')} -->\n',
        mode: 0x1A4);
    entries.add({
      'id': id,
      'collection': collection,
      'title': title,
      'tags': tags,
      'file': rel,
      'createdAt': _keweNow(),
      'updatedAt': _keweNow(),
    });
    existingIds.add(id);
    added++;
  }
  db['seedVersion'] = seedVersion;
  _writeDb(db);
  if (added > 0) {
    logp('📚 知识库已初始化/升级: 新增 $added 条种子，共 ${entries.length} 条');
  }
}

Future<void> initKnowledgeDir() async {
  ensureDir(keweAccountKnowledgeRoot);
  ensureDir(_keweKnowledgeEntriesDir);
  // 未登录的启动期只建目录；账号的种子在第一次 API / 聊天时懒加载。
}

List<Map<String, dynamic>> _baseDocs() {
  final out = <Map<String, dynamic>>[];
  void add(String rel, String title) {
    final f = File('$keweSharedKnowledgeRoot/$rel');
    if (!f.existsSync()) return;
    String content;
    try { content = f.readAsStringSync(); } catch (_) { return; }
    out.add({
      'id': 'base:$rel',
      'title': title,
      'collection': 'base',
      'tags': ['base', 'skill'],
      'file': rel,
      'kind': 'base',
      'chars': content.length,
      'preview': content.replaceAll(RegExp(r'\s+'), ' ').trim().substring(0,
          content.replaceAll(RegExp(r'\s+'), ' ').trim().length > 400
              ? 400
              : content.replaceAll(RegExp(r'\s+'), ' ').trim().length),
    });
  }

  add('skill.md', 'KEWE SOVEREIGN SKILL · 模型行动手册');
  final baseDir = Directory('$keweSharedKnowledgeRoot/base');
  if (baseDir.existsSync()) {
    for (final entity in baseDir.listSync()) {
      if (entity is File && entity.path.endsWith('.md')) {
        final name = entity.uri.pathSegments.last;
        add('base/$name', name.replaceAll('.md', ''));
      }
    }
  }
  return out;
}

String _snippet(String content, String q) {
  final clean = content.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.isEmpty) return '';
  if (q.isEmpty) return clean.length > 240 ? '${clean.substring(0, 240)}…' : clean;
  final at = clean.toLowerCase().indexOf(q.toLowerCase());
  if (at < 0) return clean.length > 240 ? '${clean.substring(0, 240)}…' : clean;
  final start = at > 80 ? at - 80 : 0;
  final end = at + q.length + 180 > clean.length ? clean.length : at + q.length + 180;
  return '${start > 0 ? '…' : ''}${clean.substring(start, end)}${end < clean.length ? '…' : ''}';
}

List<Map<String, dynamic>> searchKnowledge(String query,
    {int limit = 20, String collection = ''}) {
  ensureDir(keweAccountKnowledgeRoot);
  ensureDir(_keweKnowledgeEntriesDir);
  final q = query.trim().toLowerCase();
  final filter = collection.trim().toLowerCase();
  knowledgeEntryReadFailures = 0;
  final db = _readDb();
  final entries = (db['entries'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  final out = <Map<String, dynamic>>[];

  int scoreOf(String title, List<String> tags, String content) {
    if (q.isEmpty) return 1;
    var score = 0;
    if (title.toLowerCase().contains(q)) score += 50;
    for (final t in tags) {
      if (t.toLowerCase().contains(q)) score += 30;
    }
    final lower = content.toLowerCase();
    var at = lower.indexOf(q);
    while (at >= 0 && score < 220) {
      score += 10;
      at = lower.indexOf(q, at + q.length);
    }
    // 中文不分词时按单字兜底，避免「查不到」。
    //
    // 【必须设比例门槛】旧实现只要命中任意一个单字就 +1，而 +1 已经足够
    // 让 score > 0 从而被判定为「相关」。结果是几乎任何中文查询都会
    // 假命中（命中一个「的」「在」即可），"没有相关条目"这种诚实空结果
    // 几乎不可能出现，模型会拿到一堆不相关条目并误以为匹配。
    // 现在要求命中字数过半才计入，且得分封顶 6，只作弱信号，
    // 不会挤进 knowledgeContextForQuery 的 score >= 10 注入门槛。
    if (score == 0 && q.length >= 2) {
      final chars = q.runes
          .map(String.fromCharCode)
          .where((c) => c.trim().isNotEmpty)
          .toList();
      if (chars.isNotEmpty) {
        var hitChars = 0;
        for (final ch in chars) {
          if (content.contains(ch)) hitChars++;
        }
        if (hitChars * 2 >= chars.length) {
          score += hitChars.clamp(1, 6);
        }
      }
    }
    return score;
  }

  for (final meta in entries) {
    final col = _inferCollection(meta);
    if (filter.isNotEmpty && filter != 'base' && col != filter) continue;
    if (filter == 'base') continue;
    String content = '';
    try {
      content = File(_entryPath(meta)).readAsStringSync();
    } catch (e) {
      // 正文文件缺失/不可读：旧实现完全静默，导致该条以空内容参与打分，
      // 表现成「条目在但没内容」。必须可观测，否则又是一处沉默失败。
      knowledgeEntryReadFailures++;
      logp('⚠️ 知识正文读取失败（该条按空内容处理）: '
          '${meta['id']} ← $e');
    }
    final tags = meta['tags'] is List
        ? (meta['tags'] as List).map((t) => t.toString()).toList()
        : <String>[];
    final title = '${meta['title'] ?? ''}';
    final score = scoreOf(title, tags, content);
    if (q.isNotEmpty && score <= 0) continue;
    out.add({
      'id': '${meta['id']}',
      'title': title,
      'collection': col,
      'tags': tags,
      'kind': 'account',
      'updatedAt': '${meta['updatedAt'] ?? ''}',
      'chars': content.length,
      'score': score,
      'preview': _snippet(content, q),
    });
  }

  if (filter.isEmpty || filter == 'base') {
    for (final doc in _baseDocs()) {
      final content = readTextFileOr('$keweSharedKnowledgeRoot/${doc['file']}', '');
      final score = scoreOf(doc['title'].toString(), ['base', 'skill'], content);
      if (q.isNotEmpty && score <= 0) continue;
      out.add({...doc, 'score': score, 'preview': _snippet(content, q)});
    }
  }

  out.sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));
  return out.take(limit.clamp(1, 100)).toList();
}

Map<String, dynamic>? readKnowledgeEntry(String id) {
  if (id.startsWith('base:')) {
    final rel = id.substring(5);
    if (!_keweSafeRelative(rel)) return null;
    final f = File('$keweSharedKnowledgeRoot/$rel');
    if (!f.existsSync()) return null;
    return {
      'id': id,
      'title': rel == 'skill.md' ? 'KEWE SOVEREIGN SKILL' : rel.replaceAll('.md', ''),
      'tags': ['base', 'skill'],
      'kind': 'base',
      'content': f.readAsStringSync(),
    };
  }
  final db = _readDb();
  final meta = _findEntry(db, id);
  if (meta == null) return null;
  final f = File(_entryPath(meta));
  if (!f.existsSync()) return null;
  return {
    ...meta,
    'collection': _inferCollection(meta),
    'kind': 'account',
    'content': f.readAsStringSync(),
  };
}

Map<String, dynamic> saveKnowledgeEntry({
  String? id,
  required String title,
  required String content,
  List<String> tags = const [],
  String? collection,
}) {
  ensureDir(keweAccountKnowledgeRoot);
  ensureDir(_keweKnowledgeEntriesDir);
  final cleanTitle = title.trim();
  final cleanContent = content.trim();
  if (cleanTitle.isEmpty) throw const FormatException('标题不能为空');
  if (cleanContent.isEmpty) throw const FormatException('内容不能为空');
  if (cleanTitle.length > KEWE_KNOWLEDGE_MAX_TITLE) {
    throw FormatException('标题不能超过 $KEWE_KNOWLEDGE_MAX_TITLE 字符');
  }
  if (cleanContent.length > KEWE_KNOWLEDGE_MAX_CONTENT) {
    throw FormatException('内容不能超过 $KEWE_KNOWLEDGE_MAX_CONTENT 字符');
  }
  // 写入侧凭据过滤：密钥/令牌/私钥一律拒绝入库，从源头避免敏感字段
  // 后续被注入到模型上下文。拒绝而不是掩码保存 —— 掩码会让用户
  // 以为存了真值、实际存了星号，属于静默数据损坏。
  final secretReason = keweDetectSecret(cleanContent);
  if (secretReason.isNotEmpty) throw FormatException(secretReason);
  final db = _readDb();
  if ((db['entries'] as List).length >= KEWE_KNOWLEDGE_MAX_ENTRIES && _findEntry(db, id ?? '') == null) {
    throw const FormatException('知识库条目已达上限');
  }
  final finalId = _keweSafeId(id ?? 'k_${DateTime.now().millisecondsSinceEpoch}_${randomHex(5)}');
  final tagsClean = tags.map((t) => t.trim()).where((t) => t.isNotEmpty).take(12).toList();
  final existing = _findEntry(db, finalId);
  final cleanCollection = _normalizeCollection(collection ??
      (existing != null ? '${existing['collection'] ?? ''}' : ''));
  final meta = existing ??
      {
        'id': finalId,
        'collection': cleanCollection,
        'title': cleanTitle,
        'tags': tagsClean,
        'file': 'entries/$finalId.md',
        'createdAt': _keweNow(),
        'updatedAt': _keweNow(),
      };
  meta['title'] = cleanTitle;
  meta['collection'] = cleanCollection;
  meta['tags'] = tagsClean;
  meta['updatedAt'] = _keweNow();
  final rel = meta['file']?.toString() ?? 'entries/$finalId.md';
  if (!rel.startsWith('entries/') || rel.contains('..')) {
    throw const FormatException('非法知识文件路径');
  }
  ensureDir('$keweAccountKnowledgeRoot/entries');
  if (!writeTextFile('$keweAccountKnowledgeRoot/$rel',
      '# $cleanTitle\n\n$cleanContent\n\n<!-- collection: $cleanCollection · tags: ${tagsClean.join(', ')} -->\n')) {
    throw const FormatException('知识正文写入失败');
  }
  if (existing == null) {
    (db['entries'] as List).add(meta);
  } else {
    final list = db['entries'] as List;
    for (var i = 0; i < list.length; i++) {
      final e = list[i];
      if (e is Map && '${e['id']}' == finalId) list[i] = meta;
    }
  }
  if (!_writeDb(db)) throw const FormatException('知识库索引写入失败');
  return meta;
}

bool deleteKnowledgeEntry(String id) {
  final db = _readDb();
  final meta = _findEntry(db, id);
  if (meta == null) return false;
  final f = File(_entryPath(meta));
  try { if (f.existsSync()) f.deleteSync(); } catch (_) {}
  final list = db['entries'] as List;
  list.removeWhere((e) => e is Map && '${e['id']}' == id);
  _writeDb(db);
  return true;
}

Map<String, dynamic> knowledgeStatus() {
  ensureDir(keweAccountKnowledgeRoot);
  ensureDir(_keweKnowledgeEntriesDir);
  final db = _readDb();
  final entries = (db['entries'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  final topics = <String, int>{};
  final collections = <String, int>{};
  var chars = 0;
  for (final e in entries) {
    final tags = e['tags'] is List ? (e['tags'] as List).map((t) => t.toString()) : <String>[];
    for (final t in tags) {
      topics[t] = (topics[t] ?? 0) + 1;
    }
    final col = _inferCollection(e);
    collections[col] = (collections[col] ?? 0) + 1;
    try { chars += File(_entryPath(e)).readAsStringSync().length; } catch (_) {}
  }
  final base = _baseDocs();
  final titles = _collectionTitles();
  return {
    'ok': true,
    'title': 'Kewe Sovereign Knowledge OS',
    'entries': entries.length,
    'baseDocs': base.length,
    'totalChars': chars,
    'topics': topics,
    'collections': collections,
    'collectionInfo': collections.keys.map((id) => {
          'id': id,
          'title': titles[id] ?? id,
          'entries': collections[id] ?? 0,
        }).toList(),
    'seedVersion': db['seedVersion'],
    'updatedAt': db['updatedAt'],
    'accountRoot': 'data/users/${currentUserId}/knowledge',
    'entriesDir': 'data/users/${currentUserId}/knowledge/entries',
    'dbFile': 'data/users/${currentUserId}/knowledge/db.json',
    'entriesPreview': entries.take(12).map((e) => {
          'id': e['id'],
          'title': e['title'],
          'collection': _inferCollection(e),
          'tags': e['tags'],
          'updatedAt': e['updatedAt'],
        }).toList(),
  };
}

/// 生成每次聊天都注入的系统提示。要求短、稳定、能让模型知道
/// 自己有一个可随时检索的账号知识库，而不是把全部正文塞进上下文。

/// ------------------------------------------------------------
/// 【六语提示词词条】新增文案必须六语齐全，不得只补中文、不得留英文占位。
/// 语言代码沿用 DS_OUTPUT_LANGUAGE_NAMES：ja / zh / en / ko / ru / fr，
/// 未知代码回退简体中文（与本项目默认 UI 语言一致）。
/// ------------------------------------------------------------
class KeweKnowledgePromptStrings {
  final String title;
  final String intro;
  final String knowledgeTools;
  final String deviceTools;
  final String deviceToolsOff;
  final String domains;
  final String knownEntries;
  final String emptyDomains;
  final String emptyEntries;
  final String rules;
  final String dbDegraded;
  const KeweKnowledgePromptStrings({
    required this.title,
    required this.intro,
    required this.knowledgeTools,
    required this.deviceTools,
    required this.deviceToolsOff,
    required this.domains,
    required this.knownEntries,
    required this.emptyDomains,
    required this.emptyEntries,
    required this.rules,
    required this.dbDegraded,
  });
}

const Map<String, KeweKnowledgePromptStrings> _kewePromptByLang =
    <String, KeweKnowledgePromptStrings>{
  'zh': KeweKnowledgePromptStrings(
    title: '【KEWE SOVEREIGN · 知识与行动协议】',
    intro: '你是当前账号的私人行动中枢。用户说一句话时，先判断目标，再检索账号知识库，再执行。',
    knowledgeTools: '知识工具（始终可用，不受工具模式开关影响）：knowledge_status、knowledge_search、knowledge_read、knowledge_save、knowledge_delete。',
    deviceTools: '设备操作工具（受工具模式开关控制）：adb_status、adb_shell、ocr_screen、get_screen_text、wait_for_element、batch_tap。',
    deviceToolsOff: '本次请求的工具模式已关闭：上面那批设备操作工具**没有下发**。不要输出任何函数调用文本，也不要声称已经操作设备；确实需要操作设备时，如实告知用户需要开启工具模式。',
    domains: '知识域（检索时可传 collection 参数）：',
    knownEntries: '账号知识库你现在知道这些条目：',
    emptyDomains: '（尚未建立知识域）',
    emptyEntries: '（尚未建立知识条目，可用 knowledge_save 保存长期事实）',
    rules: '规则：\n1) 不得编造用户数据；细节必须用 knowledge_search / knowledge_read 读取；优先按对应知识域检索。\n2) 删除、付款、发消息、改权限、安装应用前必须让用户明确确认。\n3) 紧急危险：先建议离开危险源并拨打 110/120/119；网站不能保证救援，不能冒充救援机构。\n4) 不提供绕过锁屏、验证码、平台风控、隐蔽监控或伤害他人的方法。\n5) 聊天正文是账号目录中的明文数据，前端不允许编辑；不要声称用户可以前端改消息。\n6) 多语言：跟随用户语言；新增界面必须六语齐全。\n7) 用户说「记住／以后按这个来／这是规则」时，优先 knowledge_save 到最匹配的知识域，并在回复里报告 id。',
    dbDegraded: '⚠️ 当前无法访问账号知识库索引，本轮检索**没能执行**（这与「没有相关条目」不是一回事）。请如实说明这一点，严禁用通用知识冒充账号私有数据，也不要编造条目名称、编号或日期。',
  ),
  'en': KeweKnowledgePromptStrings(
    title: '[KEWE SOVEREIGN · Knowledge & Action Protocol]',
    intro: 'You are the private action hub for this account. For every user message: identify the goal, retrieve from the account knowledge base, then act.',
    knowledgeTools: 'Knowledge tools (always available, NOT gated by tool mode): knowledge_status, knowledge_search, knowledge_read, knowledge_save, knowledge_delete.',
    deviceTools: 'Device-control tools (gated by tool mode): adb_status, adb_shell, ocr_screen, get_screen_text, wait_for_element, batch_tap.',
    deviceToolsOff: 'Tool mode is OFF for this request: the device-control tools above were **not provided**. Output no function-call text and never claim the device was operated. If device control is genuinely needed, state honestly that the user must enable tool mode.',
    domains: 'Knowledge domains (pass as collection): ',
    knownEntries: 'Entries currently known in this account:',
    emptyDomains: '(no domain yet)',
    emptyEntries: '(no entry yet; use knowledge_save for durable facts)',
    rules: 'Rules:\n1) Never fabricate user data; read details via knowledge_search / knowledge_read.\n2) Ask for explicit user confirmation before delete / payment / messaging / permission change / app install.\n3) Emergency: advise leaving the danger source and calling local emergency numbers first; this app cannot guarantee rescue.\n4) Do not help bypass lock screens, CAPTCHAs, platform risk control, covert surveillance, or harm others.\n5) Chat bodies are plaintext account data and are read-only in the UI; never claim the user can edit messages there.\n6) Follow the user language; new UI strings must ship in all six languages.\n7) When the user says remember / from now on / this is a rule, prefer knowledge_save into the best-matching domain and report the id.',
    dbDegraded: 'WARNING: the account knowledge index cannot be read right now. Retrieval did NOT run this turn - that is NOT the same as no matching entry. Say so plainly, never substitute generic knowledge for account data, and never invent entry ids or dates.',
  ),
  'ja': KeweKnowledgePromptStrings(
    title: '【KEWE SOVEREIGN · 知識と行動のプロトコル】',
    intro: 'あなたはこのアカウントの私的行動ハブです。ユーザーの一言に対して、まず目的を判断し、次にアカウント知識ベースを検索し、それから実行します。',
    knowledgeTools: '知識ツール（常時利用可能・ツールモードの影響を受けません）: knowledge_status、knowledge_search、knowledge_read、knowledge_save、knowledge_delete。',
    deviceTools: 'デバイス操作ツール（ツールモードで制御）: adb_status、adb_shell、ocr_screen、get_screen_text、wait_for_element、batch_tap。',
    deviceToolsOff: 'このリクエストではツールモードが OFF です。上記のデバイス操作ツールは**送信されていません**。関数呼び出しのテキストを出力せず、デバイスを操作したと主張しないでください。デバイス操作が必要な場合は、ツールモードを有効にする必要があると正直に伝えてください。',
    domains: '知識ドメイン（collection 引数で指定可）: ',
    knownEntries: 'このアカウントで現在把握している条目:',
    emptyDomains: '（ドメイン未作成）',
    emptyEntries: '（条目未作成。長期事実は knowledge_save で保存）',
    rules: 'ルール:\n1) ユーザーデータを捏造しない。詳細は knowledge_search / knowledge_read で読む。\n2) 削除・支払い・メッセージ送信・権限変更・アプリ導入の前に必ずユーザーの明示確認を取る。\n3) 緊急時は危険源から離れ、110/120/119 に通報するよう先に伝える。本アプリは救助を保証しない。\n4) ロック画面・認証コード・プラットフォームのリスク制御の回避、秘密監視、他者への危害を助けない。\n5) チャット本文はアカウント内の平文データで、UI からは編集不可。ユーザーが編集できると述べない。\n6) ユーザーの言語に従う。新しい UI 文言は六言語すべて揃える。\n7) 「覚えて」「今後はこの通り」「これはルール」と言われたら knowledge_save を優先し、id を報告する。',
    dbDegraded: '⚠️ 現在アカウント知識インデックスを読み取れません。このターンは知識検索が**実行できていません**（「該当条目なし」とは異なります）。その旨を明示し、一般知識でアカウントデータを装わないでください。',
  ),
  'ko': KeweKnowledgePromptStrings(
    title: '[KEWE SOVEREIGN · 지식 및 행동 프로토콜]',
    intro: '당신은 이 계정의 개인 행동 허브입니다. 사용자의 한마디에 대해 먼저 목표를 판단하고, 계정 지식베이스를 검색한 뒤 실행합니다.',
    knowledgeTools: '지식 도구(항상 사용 가능, 도구 모드의 영향을 받지 않음): knowledge_status, knowledge_search, knowledge_read, knowledge_save, knowledge_delete.',
    deviceTools: '기기 조작 도구(도구 모드로 제어): adb_status, adb_shell, ocr_screen, get_screen_text, wait_for_element, batch_tap.',
    deviceToolsOff: '이번 요청은 도구 모드가 OFF입니다. 위 기기 조작 도구는 **전달되지 않았습니다**. 함수 호출 텍스트를 출력하지 말고 기기를 조작했다고 말하지 마세요. 기기 조작이 필요하면 도구 모드를 켜야 한다고 솔직히 알리세요.',
    domains: '지식 도메인(collection 인수로 지정 가능): ',
    knownEntries: '이 계정에서 현재 알고 있는 항목:',
    emptyDomains: '(아직 도메인 없음)',
    emptyEntries: '(아직 항목 없음. 장기 사실은 knowledge_save로 저장)',
    rules: '규칙:\n1) 사용자 데이터를 조작하지 말 것. 세부 내용은 knowledge_search / knowledge_read로 읽는다.\n2) 삭제·결제·메시지 전송·권한 변경·앱 설치 전에 반드시 사용자의 명시적 확인을 받는다.\n3) 긴급 상황에서는 위험 원인에서 벗어나 110/120/119에 신고하도록 먼저 안내한다. 이 앱은 구조를 보장하지 않는다.\n4) 잠금 화면·인증번호·플랫폼 리스크 제어 우회, 은밀한 감시, 타인 해악을 돕지 않는다.\n5) 채팅 본문은 계정 내 평문 데이터이며 UI에서 편집할 수 없다.\n6) 사용자 언어를 따른다. 새 UI 문구는 여섯 언어를 모두 갖춘다.\n7) 기억해 달라거나 앞으로 이 규칙을 따르라고 하면 knowledge_save를 우선하고 id를 보고한다.',
    dbDegraded: '⚠️ 현재 계정 지식 인덱스를 읽을 수 없습니다. 이번 턴은 지식 검색이 **실행되지 못했습니다**(해당 항목 없음과 다름). 그대로 밝히고 일반 지식으로 계정 데이터를 가장하지 마세요.',
  ),
  'ru': KeweKnowledgePromptStrings(
    title: '[KEWE SOVEREIGN · протокол знаний и действий]',
    intro: 'Вы личный центр действий этого аккаунта. На каждую реплику пользователя: сначала определите цель, затем обратитесь к базе знаний аккаунта, затем действуйте.',
    knowledgeTools: 'Инструменты знаний (доступны всегда, не зависят от режима инструментов): knowledge_status, knowledge_search, knowledge_read, knowledge_save, knowledge_delete.',
    deviceTools: 'Инструменты управления устройством (зависят от режима инструментов): adb_status, adb_shell, ocr_screen, get_screen_text, wait_for_element, batch_tap.',
    deviceToolsOff: 'Режим инструментов для этого запроса ВЫКЛЮЧЕН: перечисленные инструменты устройства **не переданы**. Не выводите текст вызова функций и не утверждайте, что устройство использовалось. Если управление устройством действительно нужно, честно сообщите, что пользователь должен включить режим инструментов.',
    domains: 'Домены знаний (передаются в collection): ',
    knownEntries: 'Записи, известные в этом аккаунте:',
    emptyDomains: '(домены ещё не созданы)',
    emptyEntries: '(записей нет; долгосрочные факты сохраняйте через knowledge_save)',
    rules: 'Правила:\n1) Не выдумывайте данные пользователя; детали читайте через knowledge_search / knowledge_read.\n2) Перед удалением, оплатой, отправкой сообщения, изменением прав или установкой приложения требуйте явного подтверждения.\n3) При опасности сначала советуйте покинуть источник угрозы и звонить 110/120/119; приложение не гарантирует спасение.\n4) Не помогайте обходить блокировку экрана, коды подтверждения, риск-контроль платформ, вести скрытую слежку или вредить людям.\n5) Тексты чата открытые данные аккаунта, редактирование в интерфейсе недоступно.\n6) Следуйте языку пользователя; новые строки интерфейса на всех шести языках.\n7) На просьбу запомнить или сделать правилом используйте knowledge_save и сообщайте id.',
    dbDegraded: 'ВНИМАНИЕ: индекс знаний аккаунта сейчас недоступен для чтения. Поиск в этом ходе **не выполнялся** (это не записей нет). Скажите об этом прямо и не подменяйте данные аккаунта общими знаниями.',
  ),
  'fr': KeweKnowledgePromptStrings(
    title: '[KEWE SOVEREIGN · protocole connaissances et actions]',
    intro: 'Vous êtes le hub d’action privé de ce compte. Pour chaque message : identifiez l’objectif, interrogez la base de connaissances du compte, puis agissez.',
    knowledgeTools: 'Outils de connaissances (toujours disponibles, indépendants du mode outils) : knowledge_status, knowledge_search, knowledge_read, knowledge_save, knowledge_delete.',
    deviceTools: 'Outils de contrôle de l’appareil (soumis au mode outils) : adb_status, adb_shell, ocr_screen, get_screen_text, wait_for_element, batch_tap.',
    deviceToolsOff: 'Le mode outils est DÉSACTIVÉ pour cette requête : les outils ci-dessus ne sont **pas fournis**. N’émettez aucun texte d’appel de fonction et n’affirmez pas avoir agi sur l’appareil. Si une action est réellement nécessaire, dites honnêtement que l’utilisateur doit activer le mode outils.',
    domains: 'Domaines de connaissances (paramètre collection) : ',
    knownEntries: 'Entrées connues dans ce compte :',
    emptyDomains: '(aucun domaine pour l’instant)',
    emptyEntries: '(aucune entrée ; utilisez knowledge_save pour les faits durables)',
    rules: 'Règles :\n1) Ne fabriquez jamais de données utilisateur ; lisez les détails via knowledge_search / knowledge_read.\n2) Exigez une confirmation explicite avant suppression, paiement, envoi de message, changement de permission ou installation.\n3) En cas de danger, conseillez d’abord de quitter la source et d’appeler les numéros d’urgence locaux ; l’application ne garantit pas les secours.\n4) N’aidez pas à contourner verrouillage, codes de vérification, contrôle des risques, ni à surveiller autrui ou nuire.\n5) Les corps de chat sont des données en clair en lecture seule dans l’interface.\n6) Suivez la langue de l’utilisateur ; les nouveaux libellés doivent exister dans les six langues.\n7) Sur une demande de mémorisation ou de règle durable, privilégiez knowledge_save et rapportez l’id.',
    dbDegraded: 'ATTENTION : l’index des connaissances du compte est illisible pour l’instant. La recherche **n’a pas pu s’exécuter** pour ce tour (ce n’est pas aucune entrée). Dites-le clairement et ne remplacez jamais les données du compte par des connaissances génériques.',
  ),
};

KeweKnowledgePromptStrings keweKnowledgePromptStrings(String lang) {
  final c = lang.trim().toLowerCase();
  return _kewePromptByLang[c] ?? _kewePromptByLang['zh']!;
}

/// 生成每次聊天都注入的系统提示。要求短、稳定、能让模型知道
/// 自己有一个可随时检索的账号知识库，而不是把全部正文塞进上下文。
///
/// [deviceToolsAvailable] 必须由调用方按「本次请求到底有没有下发设备工具」
/// 传入。旧实现无条件下宣称 adb_* / batch_tap 可用，工具模式关闭时
/// 这些 schema 根本没有下发，等于主动诱导模型输出无效的函数调用文本 ——
/// 那是典型的负向修复，本次一并纠正。
String knowledgeSystemPromptForChat(
    [String lang = 'zh', bool deviceToolsAvailable = true]) {
  ensureDir(keweAccountKnowledgeRoot);
  ensureDir(_keweKnowledgeEntriesDir);
  _ensureSeed();
  final db = _readDb();
  final degraded = knowledgeDbDegraded;
  final rawEntries = (db['entries'] as List).whereType<Map>().toList();
  final counts = <String, int>{};
  final titles = _collectionTitles();
  for (final e in rawEntries) {
    final c = _inferCollection(Map<String, dynamic>.from(e));
    counts[c] = (counts[c] ?? 0) + 1;
  }
  final domains = counts.keys
      .map((id) => '${id}(${titles[id] ?? id}): ${counts[id]}')
      .join(' · ');
  final t = keweKnowledgePromptStrings(lang);
  final entries = rawEntries.take(40).map((e) {
    final m = Map<String, dynamic>.from(e);
    final tags = m['tags'] is List ? (m['tags'] as List).join(',') : '';
    // 标题也过一遍掩码：目录行同样会进入模型上下文。
    final titleText = keweRedactSecrets('${m['title'] ?? ''}');
    return '- [${_inferCollection(m)}] ${m['id']}: $titleText${tags.isNotEmpty ? ' [$tags]' : ''}';
  }).join('\n');
  final degradeNote = degraded ? '\n${t.dbDegraded}\n' : '';
  return '''
${t.title}
${t.intro}
${t.knowledgeTools}
${deviceToolsAvailable ? t.deviceTools : t.deviceToolsOff}
${t.domains}${domains.isEmpty ? t.emptyDomains : domains}
${t.knownEntries}
${entries.isEmpty ? t.emptyEntries : entries}
${t.rules}$degradeNote
''';
}

/// 当前消息命中的账号知识，用于在没有工具模式时也能读到正文。
/// 只注入高相关条目，避免污染上下文。

/// 【六语短文案】注入区块标题、空结果、降级三种口径。
/// 三者必须分开：空结果是「检索成功但无匹配」，降级是「检索根本没跑」。
const Map<String, String> _keweAutoHitHeader = <String, String>{
  'zh': '【自动命中的账号知识（来自当前账号知识库）】',
  'en': '[Auto-matched account knowledge (from this account knowledge base)]',
  'ja': '【自動一致したアカウント知識（現在のアカウント知識ベース由来）】',
  'ko': '[자동 매칭된 계정 지식(현재 계정 지식베이스에서 가져옴)]',
  'ru': '[Автоматически найденные знания аккаунта (из базы знаний этого аккаунта)]',
  'fr': '[Connaissances du compte trouvées automatiquement (issues de la base de connaissances du compte)]',
};

const Map<String, String> _keweSearchEmptyText = <String, String>{
  'zh': '知识库中没有找到「%Q%」相关条目。（检索已成功执行，确实无匹配）',
  'en': 'No entry matching "%Q%" in the knowledge base. (The search DID run; there is genuinely no match.)',
  'ja': '知識ベースに「%Q%」に一致する条目はありません。（検索は正常に実行され、一致なしでした）',
  'ko': '지식베이스에서 "%Q%"와 일치하는 항목이 없습니다. (검색은 정상 실행되었고 실제로 일치 항목이 없습니다)',
  'ru': 'В базе знаний нет записей по запросу «%Q%». (Поиск действительно выполнялся, совпадений нет.)',
  'fr': 'Aucune entrée correspondant à « %Q% » dans la base de connaissances. (La recherche a bien été exécutée, il n’y a réellement aucune correspondance.)',
};

const Map<String, String> _keweSearchDegradedText = <String, String>{
  'zh': '⚠️ 当前无法访问账号知识库，本次检索**未能执行**（不是「没有相关条目」）。原因：%E%。请如实告知用户，不要用通用知识冒充账号数据。',
  'en': 'WARNING: the account knowledge base is currently unreachable, so this search did NOT run (this is NOT "no matching entry"). Reason: %E%. Tell the user honestly and never substitute generic knowledge for account data.',
  'ja': '⚠️ 現在アカウント知識ベースにアクセスできず、今回の検索は**実行できていません**（「該当なし」ではありません）。理由: %E%。ユーザーに正直に伝え、一般知識でアカウントデータを装わないでください。',
  'ko': '⚠️ 현재 계정 지식베이스에 접근할 수 없어 이번 검색은 **실행되지 못했습니다**(「일치 항목 없음」이 아님). 사유: %E%. 사용자에게 그대로 알리고 일반 지식으로 계정 데이터를 가장하지 마세요.',
  'ru': 'ВНИМАНИЕ: база знаний аккаунта сейчас недоступна, поэтому поиск **не выполнялся** (это не «нет совпадений»). Причина: %E%. Честно сообщите пользователю и не подменяйте данные аккаунта общими знаниями.',
  'fr': 'ATTENTION : la base de connaissances du compte est inaccessible, donc cette recherche **n’a pas pu s’exécuter** (ce n’est pas « aucune correspondance »). Raison : %E%. Dites-le honnêtement et ne remplacez jamais les données du compte par des connaissances génériques.',
};

String _keweL10n(Map<String, String> table, String lang) =>
    table[lang.trim().toLowerCase()] ?? table['zh']!;

/// 当前消息命中的账号知识，用于在没有工具模式时也能读到正文。
/// 只注入高相关条目，避免污染上下文。
///
/// 【本次改造要点】
///   1) 整体 try/catch：旧实现没有兜底，_ensureSeed / 文件读取一旦抛异常
///      会顺着 chat_send 冒泡，直接把整条聊天请求打成 500。
///   2) 失败时返回**明确的降级段落**而不是空串。空串会让模型以为
///      「账号里没有这条事实」，随后用通用知识编造 —— 这是最危险的路径。
///   3) 正文与标题都过 keweRedactSecrets，密钥/令牌不进模型上下文。
///   4) 真正的空结果仍然返回空串，保持「宁缺勿滥、不注入」的原设计。
String knowledgeContextForQuery(String query,
    {int limit = 4, int maxChars = 6000, String lang = 'zh'}) {
  final q = query.trim();
  if (q.length < 2) return '';
  try {
    _ensureSeed();
    // 【多词分解】searchKnowledge 的打分以整串 q 为准，用户写成
    // 「工具模式 知识库 解耦」这种带空格的短语时整串几乎不可能出现，
    // 实测命中为 0，预注入直接失效。这里按分隔符拆成若干词分别检索，
    // 再按 id 合并取最高分。词数封顶 5，避免长句造成大量文件读取。
    final terms = <String>[];
    for (final w in q.split(RegExp(r'[\s,，。;；、/|]+'))) {
      final t = w.trim();
      if (t.length >= 2 && !terms.contains(t)) terms.add(t);
      if (terms.length >= 5) break;
    }
    if (terms.isEmpty) terms.add(q);
    final merged = <String, Map<String, dynamic>>{};
    for (final t in terms) {
      for (final h in searchKnowledge(t, limit: limit * 3)) {
        final id = '${h['id']}';
        final prev = merged[id];
        final cur = (h['score'] is num) ? (h['score'] as num).toInt() : 0;
        final old = (prev?['score'] is num)
            ? (prev!['score'] as num).toInt()
            : -1;
        if (prev == null || cur > old) merged[id] = h;
      }
    }
    final hits = merged.values.toList()
      ..sort((a, b) =>
          ((b['score'] as num?)?.toInt() ?? 0)
              .compareTo((a['score'] as num?)?.toInt() ?? 0));
    if (knowledgeDbDegraded) {
      logp('⛔ 知识库检索降级（未执行成功）: $knowledgeDbLastError');
      return _keweL10n(_keweSearchDegradedText, lang)
          .replaceAll('%E%', knowledgeDbLastError);
    }
    final buf = StringBuffer();
    var used = 0;
    for (final h in hits) {
      if ('${h['kind']}' != 'account') continue;
      final score = (h['score'] is num) ? (h['score'] as num).toInt() : 0;
      if (score < 10) continue;
      final entry = readKnowledgeEntry('${h['id']}');
      if (entry == null) continue;
      var content = keweRedactSecrets('${entry['content'] ?? ''}'.trim());
      if (content.isEmpty) continue;
      if (content.length > 1600) content = '${content.substring(0, 1600)}…';
      final titleText = keweRedactSecrets('${entry['title'] ?? ''}');
      final block = '\n### [${entry['collection'] ?? KEWE_KNOWLEDGE_DEFAULT_COLLECTION}] '
          '$titleText\n$content\n';
      if (used + block.length > maxChars) break;
      buf.write(block);
      used += block.length;
    }
    if (buf.isEmpty) return '';
    return '${_keweL10n(_keweAutoHitHeader, lang)}\n$buf';
  } catch (e) {
    // 任何异常都走诚实降级：说明「读不到」，而不是伪装成「没有」。
    knowledgeDbLastError = '$e';
    logp('❌ 知识库检索异常 → 降级: $e');
    return _keweL10n(_keweSearchDegradedText, lang).replaceAll('%E%', '$e');
  }
}

// ------------------------------------------------------------
// HTTP API
// ------------------------------------------------------------
Future<void> handleKnowledgeApi(HttpRequest req) async {
  final path = req.uri.path;
  final method = req.method;
  try {
    if (path == '/api/knowledge/status' && method == 'GET') {
      _ensureSeed();
      await jsonResponse(req.response, 200, knowledgeStatus());
      return;
    }
    if (path == '/api/knowledge/search' && method == 'GET') {
      _ensureSeed();
      final q = qp(req, 'q');
      final limit = int.tryParse(qp(req, 'limit')) ?? 20;
      final collection = qp(req, 'collection');
      final items = searchKnowledge(q, limit: limit, collection: collection);
      await jsonResponse(req.response, 200, {
        'ok': true,
        'query': q,
        'collection': collection,
        'count': items.length,
        'items': items,
      });
      return;
    }
    if (path == '/api/knowledge/collections' && method == 'GET') {
      _ensureSeed();
      final st = knowledgeStatus();
      await jsonResponse(req.response, 200, {
        'ok': true,
        'seedVersion': st['seedVersion'],
        'collections': st['collectionInfo'],
      });
      return;
    }
    if (path == '/api/knowledge/entry' && method == 'GET') {
      _ensureSeed();
      final id = qp(req, 'id');
      final entry = readKnowledgeEntry(id);
      if (entry == null) {
        await errJson(req.response, 404, '知识条目不存在');
        return;
      }
      await jsonResponse(req.response, 200, {'ok': true, 'entry': entry});
      return;
    }
    if (path == '/api/knowledge/skill' && method == 'GET') {
      final f = File('$keweSharedKnowledgeRoot/skill.md');
      if (!f.existsSync()) {
        await errJson(req.response, 404, 'skill.md 不存在');
        return;
      }
      await jsonResponse(req.response, 200, {
        'ok': true,
        'skill': f.readAsStringSync(),
      });
      return;
    }
    if (path == '/api/knowledge/save' && method == 'POST') {
      _ensureSeed();
      final body = await readJsonBody(req, limit: 2 * 1024 * 1024);
      final title = mStr(body, 'title');
      final content = mStr(body, 'content');
      final id = mStr(body, 'id');
      final tagsRaw = body['tags'];
      final tags = tagsRaw is List
          ? tagsRaw.map((t) => t.toString()).toList()
          : <String>[];
      final meta = saveKnowledgeEntry(
        id: id.isEmpty ? null : id,
        title: title,
        content: content,
        tags: tags,
        collection: mStr(body, 'collection').isEmpty ? null : mStr(body, 'collection'),
      );
      await jsonResponse(req.response, 200, {
        'ok': true,
        'entry': meta,
      });
      return;
    }
    if (path == '/api/knowledge/delete' && method == 'POST') {
      final body = await readJsonBody(req);
      final id = mStr(body, 'id');
      if (id.isEmpty || !deleteKnowledgeEntry(id)) {
        await errJson(req.response, 404, '知识条目不存在');
        return;
      }
      await jsonResponse(req.response, 200, {'ok': true, 'deleted': id});
      return;
    }
    await errJson(req.response, 404, 'Not Found');
  } catch (e) {
    logp('❌ 知识库 API 失败: $e');
    await errJson(req.response, 500, '知识库操作失败: $e');
  }
}

// 给工具调用用的文本结果
String knowledgeSearchToolText(Map<String, dynamic> args) {
  final q = mStr(args, 'query').isEmpty ? mStr(args, 'q') : mStr(args, 'query');
  final limit = intArgDefault(args, 'limit', 12);
  final collection = mStr(args, 'collection');
  final lang = mStr(args, 'lang');
  final items = searchKnowledge(q, limit: limit, collection: collection);
  // ★ 先判失败，再判空。顺序反了就会把「读不到库」说成「没有条目」，
  //   模型会因此认定账号里没有这条事实，进而编造 —— 这正是要修的东西。
  if (knowledgeDbDegraded) {
    logp('⛔ 知识检索失败（不是空结果）: $knowledgeDbLastError');
    return _keweL10n(_keweSearchDegradedText, lang)
        .replaceAll('%E%', knowledgeDbLastError);
  }
  if (items.isEmpty) {
    return _keweL10n(_keweSearchEmptyText, lang).replaceAll('%Q%', q);
  }
  final b = StringBuffer('知识库检索「$q」${collection.isEmpty ? '' : '（域: $collection）'}：\n');
  if (knowledgeEntryReadFailures > 0) {
    // 有条目正文读不出来时必须显式提示：否则这些条目在结果里
    // 看起来就像「存在但没有内容」，模型容易自行补全。
    b.writeln('（注意：有 $knowledgeEntryReadFailures 条正文文件读取失败，'
        '对应内容的 preview 为空，不代表条目内容为空）');
  }
  for (final x in items) {
    b.writeln('- ${x['id']} | [${x['collection'] ?? '-'}] '
        '${keweRedactSecrets('${x['title']}')} | ${x['kind']} | '
        '${keweRedactSecrets('${x['preview']}')}');
  }
  return b.toString();
}
