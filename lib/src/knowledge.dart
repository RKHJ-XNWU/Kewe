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

String _keweNow() => rfc3339(DateTime.now());

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
  try {
    final f = File(_keweKnowledgeDbPath);
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
    }
  } catch (e) {
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
    if (score == 0 && q.length >= 2) {
      for (final ch in q.runes.map(String.fromCharCode)) {
        if (ch.trim().isNotEmpty && content.contains(ch)) score += 1;
      }
    }
    return score;
  }

  for (final meta in entries) {
    final col = _inferCollection(meta);
    if (filter.isNotEmpty && filter != 'base' && col != filter) continue;
    if (filter == 'base') continue;
    String content = '';
    try { content = File(_entryPath(meta)).readAsStringSync(); } catch (_) {}
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
String knowledgeSystemPromptForChat([String lang = 'zh']) {
  ensureDir(keweAccountKnowledgeRoot);
  ensureDir(_keweKnowledgeEntriesDir);
  _ensureSeed();
  final db = _readDb();
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
  final entries = rawEntries.take(40).map((e) {
    final m = Map<String, dynamic>.from(e);
    final tags = m['tags'] is List ? (m['tags'] as List).join(',') : '';
    return '- [${_inferCollection(m)}] ${m['id']}: ${m['title']}${tags.isNotEmpty ? ' [$tags]' : ''}';
  }).join('\n');
  return '''
【KEWE SOVEREIGN · 知识与行动协议】
你是当前账号的私人行动中枢。用户说一句话时，先判断目标，再检索账号知识库，再执行。
可用工具：knowledge_status、knowledge_search、knowledge_read、knowledge_save、knowledge_delete；
手机操作工具：adb_status、adb_shell、ocr_screen、get_screen_text、wait_for_element、batch_tap。
知识域（检索时可传 collection 参数）：${domains.isEmpty ? '（尚未建立知识域）' : domains}
账号知识库你现在知道这些条目：
${entries.isEmpty ? '（尚未建立知识条目，可用 knowledge_save 保存长期事实）' : entries}
规则：
1) 不得编造用户数据；细节必须用 knowledge_search / knowledge_read 读取；优先按对应知识域检索。
2) 删除、付款、发消息、改权限、安装应用前必须让用户明确确认。
3) 紧急危险：先建议离开危险源并拨打 110/120/119；网站不能保证救援，不能冒充救援机构。
4) 不提供绕过锁屏、验证码、平台风控、隐蔽监控或伤害他人的方法。
5) 聊天正文是账号目录中的明文数据，前端不允许编辑；不要声称用户可以前端改消息。
6) 多语言：跟随用户语言；新增界面必须六语齐全。
7) 用户说“记住/以后按这个来/这是规则”时，优先 knowledge_save 到最匹配的知识域，并在回复里报告 id。
''';
}

/// 当前消息命中的账号知识，用于在没有工具模式时也能读到正文。
/// 只注入高相关条目，避免污染上下文。
String knowledgeContextForQuery(String query, {int limit = 4, int maxChars = 6000}) {
  final q = query.trim();
  if (q.length < 2) return '';
  _ensureSeed();
  final hits = searchKnowledge(q, limit: limit * 3);
  final buf = StringBuffer();
  var used = 0;
  for (final h in hits) {
    if ('${h['kind']}' != 'account') continue;
    final score = (h['score'] is num) ? (h['score'] as num).toInt() : 0;
    if (score < 10) continue;
    final entry = readKnowledgeEntry('${h['id']}');
    if (entry == null) continue;
    var content = '${entry['content'] ?? ''}'.trim();
    if (content.isEmpty) continue;
    if (content.length > 1600) content = '${content.substring(0, 1600)}…';
    final block = '\n### [${entry['collection'] ?? KEWE_KNOWLEDGE_DEFAULT_COLLECTION}] ${entry['title']}\n$content\n';
    if (used + block.length > maxChars) break;
    buf.write(block);
    used += block.length;
  }
  if (buf.isEmpty) return '';
  return '【自动命中的账号知识（来自当前账号知识库）】\n$buf';
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
  final items = searchKnowledge(q, limit: limit, collection: collection);
  if (items.isEmpty) return '知识库中没有找到「$q」相关条目。';
  final b = StringBuffer('知识库检索「$q」${collection.isEmpty ? '' : '（域: $collection）'}：\n');
  for (final x in items) {
    b.writeln('- ${x['id']} | [${x['collection'] ?? '-'}] ${x['title']} | ${x['kind']} | ${x['preview']}');
  }
  return b.toString();
}
