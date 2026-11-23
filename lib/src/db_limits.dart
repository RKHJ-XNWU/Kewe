// ============================================================
// db_limits.dart —— 全模型统一能力限制与全局输出档位
//
// · 上下文窗口：1024K（1K = 1024 tokens）。
// · 最大输出：64K / 128K / 256K / 384K，默认 384K。
// · 档位保存在 data/output_limit.txt；预设、自定义、DeepSeek、豆包、
//   聊天、续写及模型能力目录都读取同一个值。
// · 推理等级不再参与最终 max_tokens 的计算。
// ============================================================

import 'dart:io';

import 'globals.dart';

const int DB_NUM_1K = 1024;
const int DB_DEFAULT_OUTPUT_TOKENS = 384 * DB_NUM_1K;
const List<int> DB_ALLOWED_OUTPUT_TOKENS = <int>[
  64 * DB_NUM_1K,
  128 * DB_NUM_1K,
  256 * DB_NUM_1K,
  384 * DB_NUM_1K,
];
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
      if (k != null) tokens = k * DB_NUM_1K;
    } else {
      tokens = int.tryParse(raw);
    }
  }
  if (tokens == null || !DB_ALLOWED_OUTPUT_TOKENS.contains(tokens)) {
    return null;
  }
  return tokens;
}

/// 当前全局输出上限。文件不存在、损坏或含非法值时安全回退到 384K。
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
  if (tokens >= DB_NUM_1K && tokens % DB_NUM_1K == 0) {
    return '${tokens ~/ DB_NUM_1K}K';
  }
  return '$tokens';
}
