// ============================================================
// token_cost.dart —— 真实 token 计费（人民币）
//
// 设计原则（与前端 deepseek-chat.js 的 DSC_PRICE / dscCalcCost 完全同源）：
//   1) 单价必须来自模型 ID 引出的价格表，绝不凭空估算。
//   2) 价格表未收录的模型 → 返回 null（宁可不显示金额，绝不编造数字）。
//   3) 金额用「纳元」整数累加，消除浮点误差。
//   4) DeepSeek 系有高峰/闲时倍率（高峰 2 倍）；豆包 flat 模型终日均价。
//
// ⚠️ 重要：此文件与 deepseek-chat.js 的 DSC_PRICE 必须保持同步。
//   改价格时，两处一起改，避免前后端金额不一致。
// ============================================================

import 'dart:math' as math;

import 'ds_usage.dart';

/// 单个模型的单价（单位：元 / 100 万 tokens）
class TokenPrice {
  final double hit;      // 缓存命中单价
  final double miss;     // 缓存未命中单价
  final double out;      // 输出单价
  final double? audio;   // 音声输入单价（未命中）
  final double? audioHit; // 音声输入单价（命中）
  final bool flat;       // 终日均价（无高峰/闲时倍率）
  final double? perRequest; // 固定价（元/请求），>0 时优先按请求计费

  const TokenPrice({
    required this.hit,
    required this.miss,
    required this.out,
    this.audio,
    this.audioHit,
    this.flat = false,
    this.perRequest,
  });
}

/// 价格表（与 deepseek-chat.js DSC_PRICE 完全一致）
const Map<String, TokenPrice> _PRICE = {
  'deepseek-flash': TokenPrice(hit: 0.02, miss: 1.0, out: 4.0),
  'deepseek-v4-flash': TokenPrice(hit: 0.02, miss: 1.0, out: 4.0),
  'deepseek-v4.1-flash': TokenPrice(hit: 0.02, miss: 1.0, out: 4.0),
  'deepseek-v4.1-flash-1017': TokenPrice(hit: 0.02, miss: 1.0, out: 4.0),
  'deepseek-v4-pro': TokenPrice(hit: 0.15, miss: 4.5, out: 13.5),
  'deepseek-v4-pro-0813': TokenPrice(hit: 0.15, miss: 4.5, out: 13.5),
  'deepseek-chat': TokenPrice(hit: 0.15, miss: 4.5, out: 13.5),
  'deepseek-reasoner': TokenPrice(hit: 0.15, miss: 4.5, out: 13.5),
  // 豆包 Seed-2.1-lite：终日均价（无高峰/闲时倍率）
  //   输入（未命中）0.8 / 输入（命中）0.16 / 输出 2.7
  //   音声输入（未命中）12 / 音声输入（命中）2.4
  // OpenAI 兼容中转站（sta1n.ai）模型：终日均价（无高峰/闲时倍率）
  //   单位：元 / 100 万 tokens；perRequest 为固定价（元/请求）
  '[次][抗截断]gemini-3.8-flash': TokenPrice(hit: 0, miss: 0, out: 0, flat: true, perRequest: 0.025),
  '[kiro]claude-opus-4-8': TokenPrice(hit: 0.35, miss: 3.5, out: 17.5, flat: true),
  '[kiro]claude-haiku-5-5': TokenPrice(hit: 0.021, miss: 0.21, out: 1.05, flat: true),
  '[asp]gemini-3.8-flash': TokenPrice(hit: 0.03, miss: 0.3, out: 1.5, flat: true),
  '[抗截断]gemini-3.8-flash': TokenPrice(hit: 0.03, miss: 0.3, out: 1.5, flat: true),
  // 豆包 2.1-pro / 2.1-turbo / evolving：用户提供的单价（元 / 100 万 tokens）；缓存命中单价未提供，取输入单价
  // 260915 为当前版本号；260628 保留为历史键，旧会话账单仍可复算
  'doubao-seed-2-1-pro-260915': TokenPrice(hit: 1.2, miss: 6, out: 30, flat: true),
  'doubao-seed-2-1-pro-260628': TokenPrice(hit: 1.2, miss: 6, out: 30, flat: true),
  'doubao-seed-2-1-turbo-260628': TokenPrice(hit: 0.6, miss: 3, out: 15, flat: true),
  'doubao-seed-evolving-latest-version': TokenPrice(hit: 1.2, miss: 6, out: 30, flat: true),
  'doubao-seed-2-1-lite-260915': TokenPrice(
    hit: 0.16, miss: 0.8, out: 2.7,
    audio: 12, audioHit: 2.4, flat: true,
  ),
};

/// 前缀解析表（版本后缀变化也能命中同一单价）
const List<List<String>> _PRICE_PREFIX = [
  ['doubao-seed-2-1-lite', 'doubao-seed-2-1-lite-260915'],
  ['doubao-seed-2.1-lite', 'doubao-seed-2-1-lite-260915'],
  ['doubao-seed-2-1-pro', 'doubao-seed-2-1-pro-260915'],
  ['doubao-seed-2-1-turbo', 'doubao-seed-2-1-turbo-260628'],
  ['doubao-seed-evolving', 'doubao-seed-evolving-latest-version'],
];

/// 中国法定节假日（与 deepseek-chat.js DSC_HOLIDAYS 对齐，按需维护）
const Set<String> _HOLIDAYS = {
  '2025-01-01',
  '2025-01-28', '2025-01-29', '2025-01-30', '2025-01-31',
  '2025-02-01', '2025-02-02', '2025-02-03', '2025-02-04',
  '2025-04-04', '2025-04-05', '2025-04-06',
  '2025-05-01', '2025-05-02', '2025-05-03', '2025-05-04', '2025-05-05',
  '2025-05-31', '2025-06-01', '2025-06-02',
  '2025-10-01', '2025-10-02', '2025-10-03', '2025-10-04',
  '2025-10-05', '2025-10-06', '2025-10-07', '2025-10-08',
  '2026-01-01', '2026-01-02', '2026-01-03',
  '2026-02-15', '2026-02-16', '2026-02-17', '2026-02-18',
  '2026-02-19', '2026-02-20', '2026-02-21', '2026-02-22', '2026-02-23',
  '2026-04-04', '2026-04-05', '2026-04-06',
  '2026-05-01', '2026-05-02', '2026-05-03', '2026-05-04', '2026-05-05',
  '2026-06-19', '2026-06-20', '2026-06-21',
  '2026-09-25', '2026-09-26', '2026-09-27',
  '2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04',
  '2026-10-05', '2026-10-06', '2026-10-07',
};

/// 计费结果（与前端 dscCalcCost 返回值对齐）
class TokenCostResult {
  final double cost; // 人民币
  final bool peak;
  final bool flat;
  final int hit;
  final int miss;
  final int out;
  final int audio;
  final int audioMiss;
  final int audioHit;
  final int prompt;
  final int total;

  const TokenCostResult({
    required this.cost,
    required this.peak,
    required this.flat,
    required this.hit,
    required this.miss,
    required this.out,
    required this.audio,
    required this.audioMiss,
    required this.audioHit,
    required this.prompt,
    required this.total,
  });

  Map<String, dynamic> toJson() => {
        'cost': cost,
        'peak': peak,
        'flat': flat,
        'hit': hit,
        'miss': miss,
        'out': out,
        'audio': audio,
        'audioMiss': audioMiss,
        'audioHit': audioHit,
        'prompt': prompt,
        'total': total,
      };
}

class TokenCostCalculator {
  /// 按模型 ID 解析单价；未收录 → null（绝不编造）
  static TokenPrice? priceFor(String model) {
    final m = model.trim().toLowerCase();
    if (m.isEmpty) return null;
    final direct = _PRICE[m];
    if (direct != null) return direct;
    for (final p in _PRICE_PREFIX) {
      if (m.startsWith(p[0])) return _PRICE[p[1]];
    }
    // DeepSeek 系按 pro / flash 归并
    if (m.startsWith('deepseek')) {
      if (m.contains('pro')) return _PRICE['deepseek-v4-pro'];
      return _PRICE['deepseek-flash'];
    }
    return null;
  }

  /// 归一化 usage（与前端 dscNormalizeUsage 完全一致）
  static _Norm _normalize(DsTokenUsage u) {
    var hit = u.promptCacheHitTokens;
    var miss = u.promptCacheMissTokens;
    var prompt = u.promptTokens;
    if (prompt <= 0) prompt = hit + miss;
    if (hit < 0) hit = 0;
    if (miss < 0) miss = 0;
    if (prompt < 0) prompt = 0;
    if (hit > prompt) hit = prompt;
    if (prompt > 0) {
      miss = prompt - hit;
    } else if (miss > 0) {
      prompt = hit + miss;
    }
    var out = u.completionTokens;
    final reasoning = u.reasoningTokens;
    if (out < 0) out = 0;
    if (out < reasoning) out = reasoning;
    return _Norm(hit, miss, out, prompt, prompt + out);
  }

  static bool _isPeakHour(DateTime now) {
    final bj = now.toUtc().add(const Duration(hours: 8)); // 北京时间
    final day = bj.weekday; // 1=周一 .. 7=周日
    if (day == 6 || day == 7) return false; // 周末
    final ymd = _ymd(bj);
    if (_HOLIDAYS.contains(ymd)) return false;
    final mins = bj.hour * 60 + bj.minute;
    final morning = mins >= 9 * 60 && mins < 12 * 60;
    final afternoon = mins >= 14 * 60 && mins < 18 * 60;
    return morning || afternoon;
  }

  static String _ymd(DateTime d) {
    String p(int n) => n < 10 ? '0$n' : '$n';
    return '${d.year}-${p(d.month)}-${p(d.day)}';
  }

  /// 计算一次交互的真实消耗（人民币）。
  /// 单价未收录或 usage 为空时返回 null —— 绝不估算。
  static TokenCostResult? costOf(DsTokenUsage? u) {
    if (u == null) return null;
    final t = _normalize(u);
    var audio = u.audioInputTokens;
    if (audio < 0) audio = 0;
    if (audio > t.prompt) audio = t.prompt;
    final price = priceFor(u.model.isEmpty ? 'deepseek-flash' : u.model);
    if (price == null) return null;

    // ★ 固定价模型（按请求计费）：perRequest > 0 时优先按请求次数计费，
    //   即使 token 全 0 也能正确返回金额。
    final perReq = price.perRequest;
    if (perReq != null && perReq > 0) {
      final calls = u.apiCalls > 0 ? u.apiCalls : 1;
      return TokenCostResult(
        cost: perReq * calls,
        peak: false,
        flat: true,
        hit: t.hit,
        miss: t.miss,
        out: t.out,
        audio: audio,
        audioMiss: 0,
        audioHit: 0,
        prompt: t.prompt,
        total: t.total,
      );
    }

    if (t.hit == 0 && t.miss == 0 && t.out == 0 && audio == 0) return null;

    final audioRate = price.audio ?? price.miss;
    final audioHitRate = price.audioHit ?? price.hit;
    final audioMiss = math.min(audio, t.miss);
    final audioHit = math.min(audio - audioMiss, t.hit);
    final missText = t.miss - audioMiss;
    final hitText = t.hit - audioHit;

    final flat = price.flat;
    final peak = flat ? false : _isPeakHour(DateTime.now());
    final factor = flat ? 1 : (peak ? 2 : 1);

    final nano = (hitText * price.hit * factor * 1000).round() +
        (missText * price.miss * factor * 1000).round() +
        (audioMiss * audioRate * factor * 1000).round() +
        (audioHit * audioHitRate * factor * 1000).round() +
        (t.out * price.out * factor * 1000).round();
    final cost = nano / 1e9;

    return TokenCostResult(
      cost: cost,
      peak: peak,
      flat: flat,
      hit: t.hit,
      miss: t.miss,
      out: t.out,
      audio: audio,
      audioMiss: audioMiss,
      audioHit: audioHit,
      prompt: t.prompt,
      total: t.total,
    );
  }
}

class _Norm {
  final int hit;
  final int miss;
  final int out;
  final int prompt;
  final int total;
  const _Norm(this.hit, this.miss, this.out, this.prompt, this.total);
}
