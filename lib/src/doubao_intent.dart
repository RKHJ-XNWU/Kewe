// ============================================================
// doubao_intent.dart —— 抖音百科前缀强制信源
//
// 2026-11-24 修复（严重）：
//   用户输入「抖音百科：」「抖音百科搜索：」「百科：」时，必须真的
//   走火山方舟 Responses API 的联网内容插件（sources:["douyin"]），
//   不能因为智能搜索判定“不需要联网”而被拦截。
//
//   本文件恢复「抖音百科」前缀解析；「墨迹天气」前缀仍保持停用，
//   避免扩大改动范围。
//
// 说明：
//   · 前缀可在消息任意位置，命中后从正文剥离，不送进模型与标题；
//   · 前缀只负责产生 forcedSources，真正的插件调用由 chat_send.dart
//     与 doubao_wiki.dart 完成；
//   · 插件总开关启用时，chat_send.dart 也会强制联网，不依赖本前缀。
// ============================================================

/// 一次请求被识别出的强制意图。
class DbIntent {
  /// 是否被前缀强制（true 时忽略用户对信源开关的关闭状态）
  final bool forced;

  /// 本次必须启用的信源（已按 dbWikiAllowedSources 口径给出）
  final List<String> sources;

  /// 剥掉前缀后的正文（送模型的 content）
  final String cleaned;

  /// 命中的触发词，便于日志与前端提示（如「抖音百科：」）
  final List<String> hits;

  const DbIntent({
    required this.forced,
    required this.sources,
    required this.cleaned,
    required this.hits,
  });

  static const DbIntent none = DbIntent(
    forced: false,
    sources: <String>[],
    cleaned: '',
    hits: <String>[],
  );

  bool get hasWiki => sources.contains('douyin');
  bool get hasWeather => sources.contains('moji');

  /// 是否只要求百科（不含天气）
  bool get wikiOnly => hasWiki && !hasWeather;

  /// 是否只要求天气
  bool get weatherOnly => hasWeather && !hasWiki;

  @override
  String toString() => forced
      ? 'DbIntent(forced, sources=$sources, hits=$hits)'
      : 'DbIntent(none)';
}

/// 抖音百科触发词表。
///
/// 顺序即优先级：长词必须排在短词前面，否则「抖音百科搜索：」会被
/// 「百科：」先命中，导致只剥离一部分前缀、正文里残留「抖音百科搜索」。
const List<({String prefix, String label})> _dbWikiPrefixes =
    <({String prefix, String label})>[
  (prefix: '抖音百科搜索：', label: '抖音百科搜索：'),
  (prefix: '抖音百科搜索:', label: '抖音百科搜索:'),
  (prefix: '抖音百科：', label: '抖音百科：'),
  (prefix: '抖音百科:', label: '抖音百科:'),
  (prefix: '百科：', label: '百科：'),
  (prefix: '百科:', label: '百科:'),
];

/// 解析用户正文，得出强制意图。
///
/// 不修改入参；不抛异常；任何异常路径都退化为「无强制意图」，
/// 保证聊天主链路不因前缀解析失败而中断。
DbIntent dbParseIntent(String raw) {
  try {
    final text = raw;
    if (text.trim().isEmpty) {
      return DbIntent(
        forced: false,
        sources: const <String>[],
        cleaned: text,
        hits: const <String>[],
      );
    }

    var cleaned = text;
    final hits = <String>[];

    // 逐个触发词扫描「任意位置」，命中即剥离。
    for (final p in _dbWikiPrefixes) {
      if (!cleaned.contains(p.prefix)) continue;
      hits.add(p.label);
      cleaned = cleaned.replaceAll(p.prefix, '');
    }

    if (hits.isEmpty) {
      return DbIntent(
        forced: false,
        sources: const <String>[],
        cleaned: text,
        hits: const <String>[],
      );
    }

    // 剥离后可能留下首尾空白与多余空行，做一次温和清理。
    cleaned = cleaned
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();

    // 正文被前缀吃空：说明用户只打了触发词。此时不能让空正文进模型，
    // 否则方舟会直接 400（messages 内容为空）。补一句「默认查询」意图。
    if (cleaned.isEmpty) cleaned = '帮我查一下相关资料。';

    return DbIntent(
      forced: true,
      sources: const <String>['douyin'],
      cleaned: cleaned,
      hits: List<String>.unmodifiable(hits),
    );
  } catch (_) {
    return DbIntent(
      forced: false,
      sources: const <String>[],
      cleaned: raw,
      hits: const <String>[],
    );
  }
}

/// 本次请求生效的信源。
///
/// [forcedSources] 非空时直接采用（前缀强制优先）；
/// 否则回落到豆包设置里的「总闸 × 信源」串联结果。
List<String> dbResolveSources({
  required List<String> forcedSources,
  required List<String> configSources,
}) {
  if (forcedSources.isNotEmpty) return forcedSources;
  return configSources;
}

/// 前缀强制的系统约束：写给模型的「必须执行」条款。
String dbIntentSystemRule(DbIntent intent, String lang) {
  if (!intent.forced) return '';
  final zh = <String>[
    '【强制检索规则】',
    '用户消息中出现了「抖音百科」信源前缀（${intent.hits.join('、')}），本次必须执行以下条款：',
    '1. 必须先使用联网内容插件检索，再作答；禁止跳过检索直接凭记忆回答。',
    '2. 回答中必须标明信息来源。',
    '3. 若检索返回为空或失败，必须如实说明「检索无结果／检索失败」及具体原因，'
        '禁止改口为「我无法查询」或「我无法联网」。',
    '4. 禁止向用户索要链接或要求用户自行搜索。',
  ].join('\n');
  final c = (lang).trim().toLowerCase();
  if (c.isEmpty || c == 'ja' || c == 'zh') return zh;
  if (c == 'en') {
    return <String>[
      '[MANDATORY RETRIEVAL RULE]',
      'The user message carried a Douyin Wiki source prefix '
          '(${intent.hits.join(', ')}). For this request you MUST:',
      '1. Call the web content plugin BEFORE answering; '
          'answering from memory is forbidden.',
      '2. State the information source in the answer.',
      '3. If retrieval returns nothing or fails, report the empty result or '
          'failure with its actual cause. Never claim you cannot search.',
      '4. Never ask the user for links or ask the user to search manually.',
    ].join('\n');
  }
  return zh;
}

/// 前端提示用文案键（保留给已有调用方，当前聊天主链路不使用）。
String dbIntentToastKey(DbIntent intent) {
  if (!intent.forced) return '';
  if (intent.hasWiki) return '抖音百科を強制適用しました';
  return '';
}
