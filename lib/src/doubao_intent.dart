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
    '5. 信源前缀已由系统剥离；禁止说用户只发了某个词、没写前缀或要求补充前缀。',
    '6. 必须基于本次联网内容插件返回的结果组织答案；若结果为空，明确说明抖音百科检索无结果。',
    '7. 本次是独立百科检索：禁止把它当作旧任务（人设卡、剧本、设定表）的续写，'
        '禁止复述或改写上一轮回答，也不使用角色扮演人设与口吻。',
  ].join('\n');
  final c = (lang).trim().toLowerCase();
  if (c.isEmpty || c == 'zh') return zh;
  if (c == 'ja') {
    return <String>[
      '【強制検索ルール】',
      'ユーザーメッセージに「抖音百科」の出典接頭辞（${intent.hits.join('、')}）があります。今回は以下を必ず実行してください:',
      '1. 回答前にウェブコンテンツプラグインで必ず検索してください。記憶だけで回答することを禁止します。',
      '2. 回答に情報出典を明記してください。',
      '3. 検索結果が空または失敗した場合は、実際の原因とともに「検索結果なし／検索失敗」を明確に伝えてください。'
          '「検索できない」と言い換えてはいけません。',
      '4. ユーザーにリンクや手動検索を要求してはいけません。',
      '5. 出典接頭辞はシステムが除去済みです。ユーザーが単語だけを送った、接頭辞がない、補足が必要などと言ってはいけません。',
      '6. 今回のウェブコンテンツプラグインの検索結果に基づいて回答してください。結果が空なら抖音百科に検索結果がない旨を明記してください。',
      '7. 今回は独立した百科検索です。過去のタスク（キャラ設定カード・脚本・設定表）の続きとして扱わず、'
          '前回の回答を復唱・改変せず、ロールプレイの人設や口調も使用しないでください。',
    ].join('\n');
  }
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
      '5. The source prefix was removed by the system; never say the user sent only a word, omitted the prefix, or needs to add it.',
      '6. Base the answer on this web-content plugin result; if it is empty, explicitly say Douyin Wiki returned no result.',
      '7. This is a standalone wiki lookup: never treat it as a continuation of an earlier task '
          '(persona card, script, setting sheet), never repeat or rewrite the previous answer, '
          'and do not use any role-play persona or voice.',
    ].join('\n');
  }
  if (c == 'ko') {
    return <String>[
      '[강제 검색 규칙]',
      '사용자 메시지에 「抖音百科」 출처 접두사(${intent.hits.join(', ')})가 있습니다. '
          '이번 요청은 반드시 다음을 지켜야 합니다:',
      '1. 답변 전에 웹 콘텐츠 플러그인을 먼저 호출해 검색한다. 기억만으로 답변하는 것은 금지.',
      '2. 답변에 정보 출처를 표시한다.',
      '3. 검색 결과가 없거나 실패하면 실제 원인과 함께 「검색 결과 없음/실패」를 명확히 밝힌다. '
          '「검색할 수 없다」고 말하지 않는다.',
      '4. 사용자에게 링크나 직접 검색을 요구하지 않는다.',
      '5. 출처 접두사는 시스템이 이미 제거했다. 사용자가 단어만 보냈다거나 접두사가 없다고 말하거나 보완을 요구하지 않는다.',
      '6. 이번 웹 콘텐츠 플러그인 결과를 기반으로 답변하고, 결과가 비어 있으면 Douyin Wiki 검색 결과가 없다고 명확히 밝힌다.',
      '7. 이번은 독립적인 백과 검색이다. 이전 작업(캐릭터 설정 카드·대본·설정표)의 이어쓰기로 취급하지 말고, '
          '지난 답변을 복창하거나 바꿔 쓰지 말며, 역할극 인물 설정이나 말투도 사용하지 않는다.',
    ].join('\n');
  }
  if (c == 'fr') {
    return <String>[
      '[RÈGLE DE RECHERCHE OBLIGATOIRE]',
      'Le message utilisateur contient le préfixe source « Douyin Wiki » '
          '(${intent.hits.join(', ')}). Pour cette requête, vous DEVEZ :',
      '1. Appeler le plugin de contenu web AVANT de répondre ; '
          'répondre de mémoire est interdit.',
      '2. Indiquer la source des informations dans la réponse.',
      '3. Si la recherche ne renvoie rien ou échoue, signaler le résultat vide '
          'ou l’échec avec sa cause réelle. Ne jamais dire que vous ne pouvez pas rechercher.',
      '4. Ne jamais demander des liens ni demander à l’utilisateur de chercher lui-même.',
      '5. Le préfixe source a été supprimé par le système ; ne dites jamais que l’utilisateur a envoyé seulement un mot, omis le préfixe ou doit l’ajouter.',
      '6. Fonder la réponse sur le résultat de ce plugin de contenu web ; s’il est vide, indiquer explicitement que Douyin Wiki n’a renvoyé aucun résultat.',
      '7. Il s’agit d’une recherche wiki autonome : ne la traitez pas comme la suite d’une tâche '
          'précédente (fiche de personnage, script, fiche de réglages), ne répétez ni ne réécrivez '
          'la réponse précédente, et n’utilisez aucune identité ni voix de jeu de rôle.',
    ].join('\n');
  }
  if (c == 'ru') {
    return <String>[
      '[ОБЯЗАТЕЛЬНОЕ ПРАВИЛО ПОИСКА]',
      'В сообщении пользователя есть префикс источника «Douyin Wiki» '
          '(${intent.hits.join(', ')}). Для этого запроса вы ОБЯЗАНЫ:',
      '1. Вызвать плагин веб-контента ДО ответа; отвечать по памяти запрещено.',
      '2. Указать источник информации в ответе.',
      '3. Если поиск ничего не вернул или завершился ошибкой, сообщить об этом '
          'и указать фактическую причину. Нельзя утверждать, что вы не можете искать.',
      '4. Не просить у пользователя ссылки и не предлагать ему искать самостоятельно.',
      '5. Префикс источника уже удалён системой; никогда не говорите, что пользователь отправил только слово, не указал префикс или должен его добавить.',
      '6. Стройте ответ на результате этого плагина веб-контента; если результат пуст, явно укажите, что Douyin Wiki не вернул результатов.',
      '7. Это самостоятельный поиск в вики: не считайте его продолжением прежней задачи '
          '(карточка персонажа, сценарий, таблица настроек), не повторяйте и не переписывайте '
          'предыдущий ответ и не используйте ролевую личность или её голос.',
    ].join('\n');
  }
  return zh;
}

/// 非豆包通道（DeepSeek / 中转站）使用的前缀检索约束。
///
/// 抖音百科内容插件只存在于火山方舟 Responses API；DeepSeek 通道无法调用它。
/// 但「用户写了前缀」这件事不能被静默丢弃，因此明确要求模型使用当前通道
/// 真正可用的联网搜索，并如实注明来源，禁止假装成抖音百科插件。
String dbIntentFallbackSearchRule(DbIntent intent, String lang) {
  if (!intent.forced) return '';
  final zh = <String>[
    '【强制检索规则】',
    '用户消息中出现了「抖音百科」信源前缀（${intent.hits.join('、')}），'
        '但当前模型通道不是豆包/方舟，无法调用抖音百科联网内容插件。',
    '本次必须执行以下条款：',
    '1. 必须使用当前通道可用的联网搜索先检索，再作答；禁止跳过检索直接凭记忆回答。',
    '2. 回答中必须标明实际使用的搜索来源，并明确说明本次不是抖音百科插件检索。',
    '3. 若检索返回为空或失败，必须如实说明「检索无结果／检索失败」及具体原因。',
    '4. 禁止向用户索要链接或要求用户自行搜索。',
    '5. 信源前缀已由系统剥离；禁止说用户只发了某个词、没写前缀或要求补充前缀。',
    '6. 必须基于当前通道实际可用的搜索结果组织答案；若结果为空，明确说明检索无结果。',
    '7. 本次是独立检索：禁止当作旧任务（人设卡、剧本、设定表）的续写，'
        '禁止复述上一轮回答，也不使用角色扮演人设与口吻。',
  ].join('\n');
  final c = lang.trim().toLowerCase();
  if (c.isEmpty || c == 'zh') return zh;
  if (c == 'ja') {
    return <String>[
      '【強制検索ルール】',
      'ユーザーメッセージに「抖音百科」の出典接頭辞（${intent.hits.join(', ')}）がありますが、'
          '現在のチャネルはDoubao/Arkではないため、抖音百科ウェブコンテンツプラグインは利用できません。',
      '今回は以下を必ず実行してください:',
      '1. 回答前に現在のチャネルで利用可能なウェブ検索を実行してください。記憶だけで回答することを禁止します。',
      '2. 実際の検索出典を明記し、今回は抖音百科プラグインではないことを明確に伝えてください。',
      '3. 検索結果が空または失敗した場合は、実際の原因とともに「検索結果なし／検索失敗」を明確に伝えてください。',
      '4. ユーザーにリンクや手動検索を要求してはいけません。',
      '5. 出典接頭辞はシステムが除去済みです。ユーザーが単語だけを送った、接頭辞がない、補足が必要などと言ってはいけません。',
      '6. 現在のチャネルで取得した検索結果に基づいて回答し、結果が空なら検索結果がない旨を明記してください。',
      '7. 今回は独立した検索です。過去のタスク（キャラ設定カード・脚本・設定表）の続きとして扱わず、'
          '前回の回答を復唱せず、ロールプレイの人設や口調も使用しないでください。',
    ].join('\n');
  }
  if (c == 'en') {
    return <String>[
      '[MANDATORY RETRIEVAL RULE]',
      'The user message carried a Douyin Wiki source prefix '
          '(${intent.hits.join(', ')}), but this channel is not Doubao/Ark, '
          'so the Douyin Wiki web-content plugin is unavailable.',
      'For this request you MUST:',
      '1. Use the web search available on the current channel BEFORE answering; '
          'answering from memory is forbidden.',
      '2. State the actual search source and clearly say this is not the '
          'Douyin Wiki plugin.',
      '3. If retrieval returns nothing or fails, report the empty result or '
          'failure with its actual cause.',
      '4. Never ask the user for links or ask the user to search manually.',
      '5. The source prefix was removed by the system; never say the user sent only a word, omitted the prefix, or needs to add it.',
      '6. Base the answer on the search result available in the current channel; if it is empty, explicitly say retrieval returned no result.',
      '7. This is a standalone search: never treat it as a continuation of an earlier task '
          '(persona card, script, setting sheet), never repeat the previous answer, '
          'and do not use any role-play persona or voice.',
    ].join('\n');
  }
  if (c == 'ko') {
    return <String>[
      '[강제 검색 규칙]',
      '사용자 메시지에 「抖音百科」 출처 접두사(${intent.hits.join(', ')})가 있지만, '
          '현재 채널은 Doubao/Ark가 아니므로 抖音百科 웹 콘텐츠 플러그인을 사용할 수 없습니다.',
      '이번 요청은 반드시 다음을 지켜야 합니다:',
      '1. 답변 전에 현재 채널에서 사용 가능한 웹 검색을 먼저 실행한다. 기억만으로 답변하는 것은 금지.',
      '2. 실제 검색 출처를 표시하고, 이번 검색이 抖音百科 플러그인이 아님을 분명히 밝힌다.',
      '3. 검색 결과가 없거나 실패하면 실제 원인과 함께 「검색 결과 없음/실패」를 명확히 밝힌다.',
      '4. 사용자에게 링크나 직접 검색을 요구하지 않는다.',
      '5. 출처 접두사는 시스템이 이미 제거했다. 사용자가 단어만 보냈다거나 접두사가 없다고 말하거나 보완을 요구하지 않는다.',
      '6. 현재 채널에서 가져온 검색 결과를 기반으로 답변하고, 결과가 비어 있으면 검색 결과가 없다고 명확히 밝힌다.',
      '7. 이번은 독립적인 검색이다. 이전 작업(캐릭터 설정 카드·대본·설정표)의 이어쓰기로 취급하지 말고, '
          '지난 답변을 복창하지 말며, 역할극 인물 설정이나 말투도 사용하지 않는다.',
    ].join('\n');
  }
  if (c == 'fr') {
    return <String>[
      '[RÈGLE DE RECHERCHE OBLIGATOIRE]',
      'Le message utilisateur contient le préfixe source « Douyin Wiki » '
          '(${intent.hits.join(', ')}), mais ce canal n’est pas Doubao/Ark : '
          'le plugin de contenu web Douyin Wiki est indisponible.',
      'Pour cette requête, vous DEVEZ :',
      '1. Utiliser la recherche web disponible sur le canal actuel AVANT de répondre ; '
          'répondre de mémoire est interdit.',
      '2. Indiquer la source réelle et préciser clairement que ce n’est pas '
          'le plugin Douyin Wiki.',
      '3. Si la recherche ne renvoie rien ou échoue, signaler le résultat vide '
          'ou l’échec avec sa cause réelle.',
      '4. Ne jamais demander des liens ni demander à l’utilisateur de chercher lui-même.',
      '5. Le préfixe source a été supprimé par le système ; ne dites jamais que l’utilisateur a envoyé seulement un mot, omis le préfixe ou doit l’ajouter.',
      '6. Fonder la réponse sur le résultat de recherche disponible dans le canal actuel ; s’il est vide, indiquer explicitement qu’aucun résultat n’a été trouvé.',
      '7. Il s’agit d’une recherche autonome : ne la traitez pas comme la suite d’une tâche '
          'précédente (fiche de personnage, script, fiche de réglages), ne répétez pas la réponse '
          'précédente et n’utilisez aucune identité ni voix de jeu de rôle.',
    ].join('\n');
  }
  if (c == 'ru') {
    return <String>[
      '[ОБЯЗАТЕЛЬНОЕ ПРАВИЛО ПОИСКА]',
      'В сообщении пользователя есть префикс источника «Douyin Wiki» '
          '(${intent.hits.join(', ')}), но текущий канал — не Doubao/Ark, '
          'поэтому плагин веб-контента Douyin Wiki недоступен.',
      'Для этого запроса вы ОБЯЗАНЫ:',
      '1. Использовать доступный веб-поиск текущего канала ДО ответа; '
          'отвечать по памяти запрещено.',
      '2. Указать фактический источник поиска и ясно сказать, что это не '
          'плагин Douyin Wiki.',
      '3. Если поиск ничего не вернул или завершился ошибкой, сообщить об этом '
          'и указать фактическую причину.',
      '4. Не просить у пользователя ссылки и не предлагать ему искать самостоятельно.',
      '5. Префикс источника уже удалён системой; никогда не говорите, что пользователь отправил только слово, не указал префикс или должен его добавить.',
      '6. Стройте ответ на результате поиска, доступном в текущем канале; если результат пуст, явно укажите, что результаты не найдены.',
      '7. Это самостоятельный поиск: не считайте его продолжением прежней задачи '
          '(карточка персонажа, сценарий, таблица настроек), не повторяйте предыдущий ответ '
          'и не используйте ролевую личность или её голос.',
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
