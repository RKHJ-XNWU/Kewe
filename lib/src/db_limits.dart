// ============================================================
// db_limits.dart —— 强制能力上限表（用户级硬约束，优先级最高）
//
// 所有者指定的硬性上限（不可被推理等级 / 长文模式 / 快速模式覆盖）：
//   · 所有模型一律 上下文窗口 1024K ・ 最大输出 256K
//     —— 预设模型、自定义模型（用户手动添加的 value）、中转站模型、DeepSeek 维度
//        全部统一，不再有例外，也不再按模型族/版本号区分。
//   · 推理等级固定 Lv.999，且等级不再参与 max_tokens 计算
//
// 历史沿革：
//   2026-11 之前本表只约束 Doubao-Seed-Evolving / 2.1 Pro 260915 / 2.1 lite 三族；
//   2026-11-23 按所有者要求改为「全模型统一」，族识别函数仅保留作兼容与说明用途，
//   不再作为是否施加限制的闸门。
//
// 设计原则：
//   1) 本文件是唯一可信来源。聊天入口、续写入口、前端模型目录接口
//      全部从这里取上限，任何调用方都不得把上限调低。
//   2) 只有模型标识为空（尚未选择模型）时才返回 0，表示「无从判断」。
//   3) 表外 / 自定义模型的 max_tokens 也会被抬到 256K；若上游服务商不接受
//      这个值（部分轻量模型上限更小），以上游返回为准，可在 DB_FORCED_OUTPUT_TOKENS
//      按模型下调，这是唯一允许的例外。
// ============================================================

/// 1K = 1024 tokens（本文件所有 K 均按 1024 计）
const int DB_NUM_1K = 1024;

/// 强制最大输出：256K tokens（全模型统一）
const int DB_FORCED_OUTPUT_TOKENS = 256 * DB_NUM_1K;

/// 强制上下文窗口：1024K tokens（全模型统一，固定，不再动态扩展）
const int DB_FORCED_CTX_TOKENS = 1024 * DB_NUM_1K;

/// 推理等级下限 / 上限 / 强制值
const int DB_REASONING_LEVEL_MIN = 1;
const int DB_REASONING_LEVEL_MAX = 999;
const int DB_REASONING_LEVEL_FORCED = 999;

/// 2.1 Pro 模型族根（不含版本号）
const String DB_PRO_MODEL_ROOT = 'doubao-seed-2-1-pro';

/// 2.1 Pro 唯一受约束的版本号（只有这个版本才是 1024K / 256K）
const String DB_PRO_FORCED_VERSION = '260915';

/// 模型族前缀：Evolving 整族（上下文 1024K ・ 输出 256K，版本号随官方变化自动跟随）
const List<String> dbCodingModelPrefixes = <String>[
  'doubao-seed-evolving',
];

/// 模型族前缀：lite 档（上下文 1024K 固定 ・ 输出 256K）
const List<String> dbLiteForcedModelPrefixes = <String>[
  'doubao-seed-2-1-lite',
];

/// 旧版本号 → 当前版本号（保证历史配置、历史会话继续可用）
const Map<String, String> dbModelValueAliases = <String, String>{
  'doubao-seed-2-1-pro-260628': 'doubao-seed-2-1-pro-260915',
  'doubao-seed-2-1-pro': 'doubao-seed-2-1-pro-260915',
  'doubao-seed-2-1-lite': 'doubao-seed-2-1-lite-260915',
};

/// 把历史模型值统一到当前版本号；未命中的值原样返回。
String dbCanonicalModelValue(String model) {
  final m = model.trim().toLowerCase();
  if (m.isEmpty) return model;
  final hit = dbModelValueAliases[m];
  if (hit != null) return hit;
  return model.trim();
}

/// 该模型是否属于「2.1 Pro 260915」——按版本段精确判断，其它版本号一律不算。
///
///   doubao-seed-2-1-pro                 → 无版本号 = 当前版本（别名统一为 260915）→ true
///   doubao-seed-2-1-pro-260915          → true
///   doubao-seed-2-1-pro-260915-vision   → true（同版本的派生标识）
///   doubao-seed-2-1-pro-260628          → false（旧版本号本身不算；但会被别名改成 260915）
///   doubao-seed-2-1-pro-261001          → false（将来的新版本默认不受约束）
bool dbIsPro260915(String model) {
  final m = dbCanonicalModelValue(model).toLowerCase();
  if (m.isEmpty) return false;
  if (!m.startsWith(DB_PRO_MODEL_ROOT)) return false;
  var rest = m.substring(DB_PRO_MODEL_ROOT.length);
  if (rest.isEmpty) return true;
  if (!rest.startsWith('-')) return false; // 如 doubao-seed-2-1-proxxx
  rest = rest.substring(1);
  if (rest.isEmpty) return false;
  final seg = rest.split('-').first;
  return seg == DB_PRO_FORCED_VERSION;
}

/// 该模型是否属于「编程模型」族（Evolving / 2.1 Pro 260915）
///   ① Evolving：整族命中；
///   ② 2.1 Pro：只有 260915 版本命中；
///   ③ 其它模型不命中。
/// 注意：族识别结果已不再影响上限——所有模型统一强制，本函数仅作说明/兼容用途。
bool dbIsForcedCodingModel(String model) {
  final m = dbCanonicalModelValue(model).toLowerCase();
  if (m.isEmpty) return false;
  for (final p in dbCodingModelPrefixes) {
    if (m.startsWith(p)) return true;
  }
  return dbIsPro260915(m);
}

/// 该模型是否属于「lite」族（上下文 1024K 固定 ・ 输出 256K）
/// 注意：族识别结果已不再影响上限——所有模型统一强制，本函数仅作说明/兼容用途。
bool dbIsForcedLiteModel(String model) {
  final m = dbCanonicalModelValue(model).toLowerCase();
  if (m.isEmpty) return false;
  for (final p in dbLiteForcedModelPrefixes) {
    if (m.startsWith(p)) return true;
  }
  return false;
}

/// 该模型是否受统一强制上限约束。
/// ★ 2026-11-23 起：只要模型标识非空就生效——预设、自定义、中转站、DeepSeek 维度一视同仁，
///   不再按模型族 / 版本号区分；只有「尚未选择模型」（空标识）返回 false。
bool dbHasForcedLimits(String model) => model.trim().isNotEmpty;

/// 强制最大输出（tokens）。返回 0 表示「模型标识为空，无从判断」。
int dbForcedMaxOutput(String model) =>
    dbHasForcedLimits(model) ? DB_FORCED_OUTPUT_TOKENS : 0;

/// 强制上下文窗口（tokens）。返回 0 表示「模型标识为空，无从判断」。
int dbForcedContextWindow(String model) =>
    dbHasForcedLimits(model) ? DB_FORCED_CTX_TOKENS : 0;

/// 推理等级收敛到 [DB_REASONING_LEVEL_MIN, DB_REASONING_LEVEL_MAX]。
/// 注意：等级不再参与 max_tokens 计算（强制输出由本表决定）。
int dbClampReasoningLevel(int level) {
  var l = level;
  if (l < DB_REASONING_LEVEL_MIN) l = DB_REASONING_LEVEL_MIN;
  if (l > DB_REASONING_LEVEL_MAX) l = DB_REASONING_LEVEL_MAX;
  return l;
}

/// 千位计数格式化，例如 262144 → "256K"
String dbTokensLabel(int tokens) {
  if (tokens >= DB_NUM_1K && tokens % DB_NUM_1K == 0) {
    return '${tokens ~/ DB_NUM_1K}K';
  }
  return '$tokens';
}
