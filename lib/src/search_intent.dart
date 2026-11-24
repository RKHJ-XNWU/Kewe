// ============================================================
// search_intent.dart —— 智能搜索判定（不是“每条消息都搜”）
//
// 用户点开「联网搜索」只代表允许联网，不代表强制每条消息都烧额度。
// 这里在服务端统一判定：只有消息确实需要实时 / 外部信息时才检索。
// 纯问候、定义、闲聊、代码解释、创作等内部知识可答的内容一律跳过。
// ============================================================

/// 返回是否需要联网，以及判定原因（用于日志审计，避免“无脑乱搜”悄悄回退）。
({bool need, String reason}) dbWebSearchIntent(String raw,
    {bool forced = false}) {
  final text = raw.trim();
  if (forced) {
    return (need: true, reason: '用户显式指定信源/插件，必须检索');
  }
  if (text.isEmpty) {
    return (need: false, reason: '空消息');
  }
  final low = text.toLowerCase();

  // 1) 链接：用户给了 URL，默认需要抓取/核对。
  if (RegExp(r'https?://|www\.').hasMatch(low)) {
    return (need: true, reason: '包含 URL，需要读取外部页面');
  }

  // 2) 用户明确要求来源 / 依据 / 搜索：这是“被用户要求”的搜索，
  //    即使问题本身是“你好是什么意思”，只要问了依据来源就必须查。
  final sourceRe = RegExp(
      r'来源|依据|出处|引用|证据|原文|报道|参考(资料|文献)?|资料|文献|链接|'
      r'根拠|出典|情報源|引用|証拠|ソース|'
      r'출처|근거|원문|'
      r'источник|ссылка|доказательств|'
      r'source|citation|reference|evidence|proof|link',
      caseSensitive: false);
  if (sourceRe.hasMatch(low)) {
    return (need: true, reason: '用户要求来源/依据/引用');
  }
  final explicitSearchRe = RegExp(
      r'搜索(一下|一搜)?|搜一下|搜一搜|搜搜|联网|上网查|帮我查|查一下|查查|检索|'
      r'search|look\s*up|google|'
      r'検索|調べ|'
      r'검색|찾아|'
      r'поиск|найди|'
      r'recherche|chercher',
      caseSensitive: false);
  if (explicitSearchRe.hasMatch(low)) {
    return (need: true, reason: '用户明确要求搜索/查询');
  }

  // 3) 明确时效性：最新、实时、今天几号、现在几点、新闻/天气/行情等。
  //    注意不能只匹配“今天”，否则“今天写一篇作文”也会误搜。
  final timeSensitiveRe = RegExp(
      r'最新|实时|即时|快讯|刚刚|今天几号|今天星期|今日日期|现在几点|当前时间|'
      r'今日新闻|今天(的)?(天气|新闻|股价|汇率|比分|价格|政策|发布|上映|开售|情况)|'
      r'现在(的)?(天气|时间|汇率|股价|比分|情况)|当前(价格|汇率|股价|政策|版本|情况)|'
      r'目前(价格|汇率|股价|政策|版本|情况)|今年(的)?(政策|新闻|发布|版本|价格)|'
      r"latest|breaking|real[- ]?time|today(?:'s)?\s+(?:news|weather|price|score)|"
      r'what\s+time|current\s+(?:price|version|policy|status)|'
      r'最新|今日|現在|リアルタイム|'
      r'최신|실시간|오늘\s*(뉴스|날씨|주가|환율)|'
      r'последн|сегодня|сейчас|'
      r"dernières|actualité|aujourd'hui",
      caseSensitive: false);
  if (timeSensitiveRe.hasMatch(low)) {
    return (need: true, reason: '问题具有时效性，需要实时信息');
  }

  // 4) 纯定义 / 语言问题：内部知识足够，不搜。
  final definitionRe = RegExp(
      r'是什么意思|什么意思|是什么|什么是|定义|含义|怎么读|读音|发音|翻译|'
      r'语法|区别|解释一下|举个例子|'
      r'what\s+(?:is|does|means?)|meaning|definition|pronounce|translate|'
      r'とは|意味|読み方|'
      r'뜻|무슨\s*의미|'
      r'значение|перевод|'
      r'signifie|définition|traduction',
      caseSensitive: false);
  if (definitionRe.hasMatch(low)) {
    return (need: false, reason: '定义/语言类问题，内部知识可答');
  }

  // 5) 问候、寒暄、自我介绍、简单情绪表达：不搜。
  final smallTalkRe = RegExp(
      r'^(你好|您好|嗨|哈喽|在吗|在么|早上好|中午好|晚上好|晚安|谢谢|多谢|辛苦了|哈哈|'
      r'hi|hello|hey|good\s+(?:morning|evening)|thanks|thank\s+you|'
      r'こんにちは|おはよう|こんばんは|ありがとう|おやすみ|'
      r'안녕|안녕하세요|고마워|'
      r'привет|здравствуйте|спасибо|'
      r'bonjour|salut|merci)'
      r'[\s!！。,.，?？~～]*$',
      caseSensitive: false);
  final identityRe = RegExp(
      r'你是谁|你叫什么|你叫什么名字|你能做什么|介绍一下你自己|'
      r'who\s+are\s+you|what\s+can\s+you\s+do|'
      r'あなたは誰|自己紹介|'
      r'너는\s*누구|'
      r'кто\s+ты|'
      r'qui\s+es-tu',
      caseSensitive: false);
  if (smallTalkRe.hasMatch(low) || identityRe.hasMatch(low)) {
    return (need: false, reason: '问候/寒暄/自我介绍，不需要联网');
  }

  // 6) 创作、代码、翻译、总结等任务：默认内部完成，不搜。
  //    但如果前面命中“最新/实时”等时效性，已经在第 3 步返回 true。
  final creativeRe = RegExp(
      r'写一(篇|份|段|首|个|套)|帮我写|写个|写一段|生成一(篇|份|段|首|个|套)|'
      r'创作|作文|诗歌|小说|故事|文案|剧本|代码|函数|算法|'
      r'翻译|润色|改写|续写|扩写|总结一下|解释一下|'
      r'write|compose|create|story|poem|novel|essay|code|function|script|'
      r'translate|rewrite|summarize|'
      r'書いて|作成|小説|物語|コード|翻訳|要約|'
      r'작성|소설|코드|번역|요약|'
      r'напиши|создай|код|перевод|'
      r'écris|crée|code|traduction',
      caseSensitive: false);
  if (creativeRe.hasMatch(low)) {
    return (need: false, reason: '创作/代码/翻译类任务，内部知识可完成');
  }

  // 7) 明确的外部事实域：价格、天气、新闻、行情、政策、地址、交通等。
  final factualRe = RegExp(
      r'新闻|头条|时事|天气|气温|下雨|台风|预报|'
      r'股价|股票|汇率|金价|油价|币价|行情|市值|财报|'
      r'比分|赛果|赛程|冠军|排名|积分榜|'
      r'价格|多少钱|报价|售价|优惠|折扣|促销|'
      r'政策|法规|条例|通知|公告|发布会|上映|开售|预售|版本更新|'
      r'航班|机票|高铁|火车|公交|地铁|路况|堵车|'
      r'附近|营业时间|官网|门票|地址|电话|'
      r'news|weather|temperature|stock\s+price|exchange\s+rate|market\s+price|'
      r'score|ranking|price|cost|how\s+much|policy|regulation|release\s+date|'
      r'flight|train|traffic|nearby|opening\s+hours|official\s+site|address|phone|'
      r'ニュース|天気|株価|為替|値段|価格|政策|発表|'
      r'뉴스|날씨|주가|환율|가격|정책|발표|'
      r'новост|погод|курс|цен|политик|'
      r'actualité|météo|prix|politique',
      caseSensitive: false);
  if (factualRe.hasMatch(low)) {
    return (need: true, reason: '问题涉及外部实时事实，需要联网核对');
  }

  return (need: false, reason: '内部知识可回答，跳过联网以节省额度');
}
