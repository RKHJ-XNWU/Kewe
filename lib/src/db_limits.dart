// ============================================================
// db_limits.dart —— 全模型统一能力限制与全局输出档位
//
// · 全站 K 统一为自定义十进制：1K = 1000 tokens。
// · 上下文窗口：1024K = 1,024,000 tokens。
// · 最大输出：64K=64,000、128K=128,000、256K=256,000、
//   384K=384,000，默认 384K（十进制 384,000，不使用二进制 393,216）。
// · 模型特例（用户规则优先于上游二进制）：
//   Seed-Character / charter 角色扮演模型 → 固定 32K=32,000；
//   Doubao-Seed-2.0-lite → 固定 128K=128,000；
//   Doubao-Seed-2.1 lite / Pro / turbo / Evolving → 固定 256K=256,000。
// · 档位保存在 data/output_limit.txt；预设、自定义、DeepSeek、豆包、
//   聊天、续写及模型能力目录都读取同一个值。
// · 推理等级不再参与最终 max_tokens 的计算。
// ============================================================

import 'dart:io';

import 'globals.dart';

const int DB_TOKEN_K = 1000; // 全站十进制 K
const int DB_DEFAULT_OUTPUT_TOKENS = 384 * DB_TOKEN_K;
const List<int> DB_ALLOWED_OUTPUT_TOKENS = <int>[
  64 * DB_TOKEN_K,
  128 * DB_TOKEN_K,
  256 * DB_TOKEN_K,
  384 * DB_TOKEN_K,
];
const Map<int, int> DB_LEGACY_OUTPUT_TOKENS = <int, int>{
  65536: 64000,
  131072: 128000,
  262144: 256000,
  393216: 384000,
};
const int DB_FORCED_CTX_TOKENS = 1024 * DB_TOKEN_K;
const int DB_CHARACTER_OUTPUT_TOKENS = 32 * DB_TOKEN_K;
const int DB_DOUBAO_20_LITE_OUTPUT_TOKENS = 128 * DB_TOKEN_K;
const int DB_DOUBAO_21_OUTPUT_TOKENS = 256 * DB_TOKEN_K;

const int DB_REASONING_LEVEL_MIN = 1;
const int DB_REASONING_LEVEL_MAX = 999;
const int DB_REASONING_LEVEL_FORCED = 999;

const String DB_PRO_MODEL_ROOT = 'doubao-seed-2-1-pro';
const String DB_PRO_FORCED_VERSION = '260915';
const List<String> dbCodingModelPrefixes = <String>[
  'doubao-seed-evolving',
];
const List<String> dbLiteForcedModelPrefixes = <String>[
  'doubao-seed-2-1-lite',
];
// 用户指定：角色扮演（charter / character）模型固定 32K（十进制 32000）。
const List<String> dbCharacterModelPrefixes = <String>[
  'doubao-seed-character',
  'doubao-seed-charter',
  'doubao-charter',
  'charter',
];
// 用户指定：Doubao-Seed-2.0-lite 固定 128K（十进制 128000）。
const List<String> dbDoubao20LiteModelPrefixes = <String>[
  'doubao-seed-2-0-lite',
  'doubao-seed-2.0-lite',
  'doubao-2-0-lite',
  'doubao-2.0-lite',
  'doubao-lite-2-0',
  'doubao-lite-2.0',
];
// 用户指定：Doubao-Seed-2.1 lite / Pro / turbo 与 Evolving 固定 256K（十进制 256000）。
const List<String> dbDoubao21ModelPrefixes = <String>[
  'doubao-seed-2-1-lite',
  'doubao-seed-2.1-lite',
  'doubao-seed-2-1-pro',
  'doubao-seed-2.1-pro',
  'doubao-seed-2-1-turbo',
  'doubao-seed-2.1-turbo',
  'doubao-seed-evolving',
  'doubao-seed-evo',
];
const Map<String, String> dbModelValueAliases = <String, String>{
  'doubao-seed-2-1-pro-260628': 'doubao-seed-2-1-pro-260915',
  'doubao-seed-2-1-pro': 'doubao-seed-2-1-pro-260915',
  'doubao-seed-2-1-lite': 'doubao-seed-2-1-lite-260915',
};

String get _dbOutputLimitPath => '$DATA_DIR/output_limit.txt';

/// 仅接受四个明确档位；其它输入返回 null，绝不静默放大或缩小。
int? dbParseOutputLimit(dynamic value) {
  int? tokens;
  if (value is int) {
    tokens = value;
  } else if (value is num) {
    tokens = value.toInt();
  } else if (value is String) {
    final raw = value.trim().toUpperCase();
    if (raw.endsWith('K')) {
      final k = int.tryParse(raw.substring(0, raw.length - 1));
      if (k != null) tokens = k * DB_TOKEN_K;
    } else {
      tokens = int.tryParse(raw);
    }
  }
  if (tokens == null) return null;
  // 兼容旧版二进制档位保存值，首次读取时无缝迁移到十进制档位。
  final migrated = DB_LEGACY_OUTPUT_TOKENS[tokens] ?? tokens;
  if (!DB_ALLOWED_OUTPUT_TOKENS.contains(migrated)) {
    return null;
  }
  return migrated;
}

/// 当前全局输出上限。文件不存在、损坏或含非法值时安全回退到 384K。
int dbCurrentOutputLimit() {
  try {
    final parsed =
        dbParseOutputLimit(File(_dbOutputLimitPath).readAsStringSync().trim());
    return parsed ?? DB_DEFAULT_OUTPUT_TOKENS;
  } catch (_) {
    return DB_DEFAULT_OUTPUT_TOKENS;
  }
}

/// 原子保存全局档位，避免应用中断时留下半个文件。
bool saveDbOutputLimit(dynamic value) {
  final tokens = dbParseOutputLimit(value);
  if (tokens == null) return false;
  try {
    ensureDir(DATA_DIR);
    final tmp = File('$_dbOutputLimitPath.tmp');
    tmp.writeAsStringSync('$tokens\n', flush: true);
    tmp.renameSync(_dbOutputLimitPath);
    return true;
  } catch (e) {
    logp('❌ 最大出力档位の保存に失敗: $e');
    return false;
  }
}

Map<String, dynamic> dbOutputLimitInfo() => <String, dynamic>{
      'maxOutput': dbCurrentOutputLimit(),
      'maxOutputLabel': dbTokensLabel(dbCurrentOutputLimit()),
      'defaultOutput': DB_DEFAULT_OUTPUT_TOKENS,
      'contextWindow': DB_FORCED_CTX_TOKENS,
      'options': DB_ALLOWED_OUTPUT_TOKENS
          .map((n) => <String, dynamic>{
                'tokens': n,
                'label': dbTokensLabel(n),
              })
          .toList(),
    };

String dbCanonicalModelValue(String model) {
  final m = model.trim().toLowerCase();
  if (m.isEmpty) return model;
  final hit = dbModelValueAliases[m];
  if (hit != null) return hit;
  return model.trim();
}

bool dbIsPro260915(String model) {
  final m = dbCanonicalModelValue(model).toLowerCase();
  if (m.isEmpty) return false;
  if (!m.startsWith(DB_PRO_MODEL_ROOT)) return false;
  var rest = m.substring(DB_PRO_MODEL_ROOT.length);
  if (rest.isEmpty) return true;
  if (!rest.startsWith('-')) return false;
  rest = rest.substring(1);
  if (rest.isEmpty) return false;
  return rest.split('-').first == DB_PRO_FORCED_VERSION;
}

bool dbIsForcedCodingModel(String model) {
  final m = dbCanonicalModelValue(model).toLowerCase();
  if (m.isEmpty) return false;
  for (final p in dbCodingModelPrefixes) {
    if (m.startsWith(p)) return true;
  }
  return dbIsPro260915(m);
}

bool dbIsForcedLiteModel(String model) {
  final m = dbCanonicalModelValue(model).toLowerCase();
  if (m.isEmpty) return false;
  for (final p in dbLiteForcedModelPrefixes) {
    if (m.startsWith(p)) return true;
  }
  return false;
}

bool dbIsCharacterModel(String model) {
  final m = dbCanonicalModelValue(model).toLowerCase();
  if (m.isEmpty) return false;
  for (final p in dbCharacterModelPrefixes) {
    if (m.startsWith(p) || m.contains(p)) return true;
  }
  return false;
}

bool dbIsDoubao20LiteModel(String model) {
  final m = dbCanonicalModelValue(model).toLowerCase();
  if (m.isEmpty) return false;
  for (final p in dbDoubao20LiteModelPrefixes) {
    if (m.startsWith(p) || m.contains(p)) return true;
  }
  return false;
}

bool dbIsDoubao21Model(String model) {
  final m = dbCanonicalModelValue(model).toLowerCase();
  if (m.isEmpty) return false;
  for (final p in dbDoubao21ModelPrefixes) {
    if (m.startsWith(p)) return true;
  }
  return false;
}

bool dbHasForcedLimits(String model) => model.trim().isNotEmpty;

/// 仅返回「模型固定特例」：角色扮演 32,000；2.0-lite 128,000；
/// 2.1 lite/Pro/turbo 与 Evolving 256,000；其它 0。
/// 用于 API 边界兜底，确保任何调用路径都不会把特例模型放大。
int dbSpecialModelMaxOutput(String model) {
  if (dbIsCharacterModel(model)) return DB_CHARACTER_OUTPUT_TOKENS;
  if (dbIsDoubao20LiteModel(model)) return DB_DOUBAO_20_LITE_OUTPUT_TOKENS;
  if (dbIsDoubao21Model(model)) return DB_DOUBAO_21_OUTPUT_TOKENS;
  return 0;
}

/// 解析一次请求真正要发送的 max_tokens。
/// 用户规则优先：角色扮演 32,000；2.0-lite 128,000；
/// 2.1 lite/Pro/turbo 与 Evolving 256,000；其余使用当前全局档位。
int dbForcedMaxOutput(String model) {
  if (!dbHasForcedLimits(model)) return 0;
  final special = dbSpecialModelMaxOutput(model);
  return special > 0 ? special : dbCurrentOutputLimit();
}

int dbForcedContextWindow(String model) =>
    dbHasForcedLimits(model) ? DB_FORCED_CTX_TOKENS : 0;

int dbClampReasoningLevel(int level) {
  var l = level;
  if (l < DB_REASONING_LEVEL_MIN) l = DB_REASONING_LEVEL_MIN;
  if (l > DB_REASONING_LEVEL_MAX) l = DB_REASONING_LEVEL_MAX;
  return l;
}

String dbTokensLabel(int tokens) {
  if (tokens >= DB_TOKEN_K && tokens % DB_TOKEN_K == 0) {
    return '${tokens ~/ DB_TOKEN_K}K';
  }
  return '$tokens';
}
