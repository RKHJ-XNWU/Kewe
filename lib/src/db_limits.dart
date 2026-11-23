// ============================================================
// db_limits.dart —— 全模型统一能力限制与全局输出档位
//
// · 上下文窗口：1024K（1K = 1024 tokens，固定 1,048,576）。
// · 最大输出使用自定义十进制 K（1K = 1000 tokens）：64K=64,000、
//   128K=128,000、256K=256,000、384K=384,000，默认 256K。
// · 档位保存在 data/output_limit.txt；预设、自定义、DeepSeek、豆包、
//   聊天、续写及模型能力目录都读取同一个值。
// · 推理等级不再参与最终 max_tokens 的计算。
// ============================================================

import 'dart:io';

import 'globals.dart';

const int DB_NUM_1K = 1024; // 上下文窗口仍使用二进制 K
const int DB_OUTPUT_K = 1000; // 输出档位使用十进制 K
const int DB_DEFAULT_OUTPUT_TOKENS = 256 * DB_OUTPUT_K;
const List<int> DB_ALLOWED_OUTPUT_TOKENS = <int>[
  64 * DB_OUTPUT_K,
  128 * DB_OUTPUT_K,
  256 * DB_OUTPUT_K,
  384 * DB_OUTPUT_K,
];
const Map<int, int> DB_LEGACY_OUTPUT_TOKENS = <int, int>{
  65536: 64000,
  131072: 128000,
  262144: 256000,
  393216: 384000,
};
const int DB_FORCED_CTX_TOKENS = 1024 * DB_NUM_1K;

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
      if (k != null) tokens = k * DB_OUTPUT_K;
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

/// 当前全局输出上限。文件不存在、损坏或含非法值时安全回退到 256K。
int dbCurrentOutputLimit() {
  try {
    final parsed = dbParseOutputLimit(
        File(_dbOutputLimitPath).readAsStringSync().trim());
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

bool dbHasForcedLimits(String model) => model.trim().isNotEmpty;

int dbForcedMaxOutput(String model) =>
    dbHasForcedLimits(model) ? dbCurrentOutputLimit() : 0;

int dbForcedContextWindow(String model) =>
    dbHasForcedLimits(model) ? DB_FORCED_CTX_TOKENS : 0;

int dbClampReasoningLevel(int level) {
  var l = level;
  if (l < DB_REASONING_LEVEL_MIN) l = DB_REASONING_LEVEL_MIN;
  if (l > DB_REASONING_LEVEL_MAX) l = DB_REASONING_LEVEL_MAX;
  return l;
}

String dbTokensLabel(int tokens) {
  if (tokens >= DB_OUTPUT_K && tokens % DB_OUTPUT_K == 0) {
    return '${tokens ~/ DB_OUTPUT_K}K';
  }
  return '$tokens';
}
