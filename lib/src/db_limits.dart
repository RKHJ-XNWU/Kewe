// ============================================================
// db_limits.dart —— 强制能力上限表（用户级硬约束，优先级最高）
//
// 所有者指定的硬性上限（不可被推理等级 / 长文模式 / 快速模式覆盖）：
//   · Doubao-Seed-Evolving         上下文窗口 1024K ・ 最大输出 256K
//   · 豆包 2.1 Pro（仅 260915 版本） 上下文窗口 1024K ・ 最大输出 256K
//   · 豆包 2.1 lite（260915）       上下文窗口 1024K（运行时动态扩展）・ 最大输出 256K
//   · 推理等级固定 Lv.999，且等级不再参与 max_tokens 计算
//   · 其余模型（2.1 turbo / 2.0 mini / 2.0 lite / GLM / DeepSeek / 中转站 …）
//     一律不受本表约束，行为与以前完全一致（maxOutput / contextWindow 返回 0）
//
// 设计原则：
//   1) 本文件是唯一可信来源。聊天入口、续写入口、前端模型目录接口
//      全部从这里取上限，任何调用方都不得把上限调低。
//   2) 2.1 Pro 按「版本号」精确匹配：只有 260915 这一个版本享受 1024K / 256K。
//      历史值（260628、无版本号）会先被别名统一到 260915，再按 260915 判定——
//      因为实际送给方舟的模型标识就是 260915，声明的上限必须与真实模型一致。
//      将来若新增其它 pro 版本号（如 -261001），默认不受约束，除非显式加进本表。
//   3) Evolving / lite 按模型族前缀匹配，版本号变化（260628 → 260915）不受影响。
//   4) 表外模型行为完全不变。
// ============================================================

/// 1K = 1024 tokens（本文件所有 K 均按 1024 计）
const int DB_NUM_1K = 1024;

/// 强制最大输出：256K tokens
const int DB_FORCED_OUTPUT_TOKENS = 256 * DB_NUM_1K;

/// 编程模型强制上下文窗口：1024K tokens
const int DB_FORCED_CTX_TOKENS_CODING = 1024 * DB_NUM_1K;

/// lite 档上下文窗口上限：1024K tokens（运行时按用量动态扩展，永不超过此值）
const int DB_FORCED_CTX_TOKENS_LITE = 1024 * DB_NUM_1K;

/// lite 档动态上下文窗口的下限（最小可用窗口）
const int DB_LITE_CTX_MIN_TOKENS = 64 * DB_NUM_1K;

/// lite 档动态上下文窗口的扩展步长（每次按 32K 阶梯向上扩展）
const int DB_LITE_CTX_STEP_TOKENS = 32 * DB_NUM_1K;

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

/// 模型族前缀：lite 档（上下文 1024K 动态 ・ 输出 256K）
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

/// 该模型是否属于「编程模型」强制档（上下文 1024K ・ 输出 256K）
///   ① Evolving：整族命中；
///   ② 2.1 Pro：只有 260915 版本命中，别的版本号一律不受约束；
///   ③ 其它模型（turbo / mini / lite(2.0) / GLM / DeepSeek …）：一律不命中。
bool dbIsForcedCodingModel(String model) {
  final m = dbCanonicalModelValue(model).toLowerCase();
  if (m.isEmpty) return false;
  for (final p in dbCodingModelPrefixes) {
    if (m.startsWith(p)) return true;
  }
  return dbIsPro260915(m);
}

/// 该模型是否属于「lite」强制档（上下文 1024K 动态 ・ 输出 256K）
bool dbIsForcedLiteModel(String model) {
  final m = dbCanonicalModelValue(model).toLowerCase();
  if (m.isEmpty) return false;
  for (final p in dbLiteForcedModelPrefixes) {
    if (m.startsWith(p)) return true;
  }
  return false;
}

/// 强制最大输出（tokens）。返回 0 表示「该模型不受本表约束」。
int dbForcedMaxOutput(String model) {
  if (dbIsForcedCodingModel(model) || dbIsForcedLiteModel(model)) {
    return DB_FORCED_OUTPUT_TOKENS;
  }
  return 0;
}

/// 强制上下文窗口（tokens）。返回 0 表示「该模型不受本表约束」。
int dbForcedContextWindow(String model) {
  if (dbIsForcedCodingModel(model)) return DB_FORCED_CTX_TOKENS_CODING;
  if (dbIsForcedLiteModel(model)) return DB_FORCED_CTX_TOKENS_LITE;
  return 0;
}

/// 上下文窗口是否「动态」——lite 档按实际用量阶梯式扩展，上限 1024K。
bool dbContextIsDynamic(String model) => dbIsForcedLiteModel(model);

/// lite 档的当前动态上下文窗口：
///   已经开始使用的量（[usedTokens]）向上取整到 32K 阶梯，
///   下限 64K、上限 1024K。未列入 lite 档时直接返回强制窗口值。
int dbDynamicContextWindow(String model, int usedTokens) {
  final cap = dbForcedContextWindow(model);
  if (cap <= 0) return cap;
  if (!dbContextIsDynamic(model)) return cap;
  var used = usedTokens;
  if (used < 0) used = 0;
  // 向上取整到步长
  var win = (used + DB_LITE_CTX_STEP_TOKENS - 1) ~/ DB_LITE_CTX_STEP_TOKENS *
      DB_LITE_CTX_STEP_TOKENS;
  if (win < DB_LITE_CTX_MIN_TOKENS) win = DB_LITE_CTX_MIN_TOKENS;
  if (win > cap) win = cap;
  return win;
}

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
