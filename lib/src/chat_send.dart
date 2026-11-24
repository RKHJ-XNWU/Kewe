// ============================================================
// chat_send.dart —— /api/ds-chat/send（发送）、SSE 流式、小说模式
// 100% 对齐 Go 版 handleDsChatSend / handleDsChatSendStream /
//        handleDsNovelGeneration(Stream)
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cosplay.dart';
import 'db_limits.dart';
import 'deepseek_api.dart';
import 'doubao.dart';
import 'doubao_video_ark.dart';
import 'doubao_wiki.dart';
import 'doubao_intent.dart';
import 'doubao_thinking.dart';
import 'doubao_tools.dart';
import 'ds_crypto.dart';
import 'ds_usage.dart';
import 'files.dart';
import 'globals.dart';
import 'knowledge.dart';
import 'httpsrv.dart';
import 'model_router.dart';
import 'relay.dart';
import 'search_intent.dart';
import 'sessions.dart';
import 'session_ref.dart';
import 'tool_gate.dart';

// ------------------------------------------------------------
// 工具模式系统提示 / 轮次上限：按通道分流
//   · 豆包通道 → doubao_tools.dart 的专属提示词与档位轮次
//   · DeepSeek 通道 → 原有全量提示词与 DS_TOOL_MAX_ITERATIONS
//   专项适配的好处：lite 档不会被灌进 85 条工具约定的长提示，
//   首包更快；pro/evolving 档则拿到「可长程编排」的更强约束。
// ------------------------------------------------------------
/// 本次请求真正生效的插件信源。
///
/// 【为什么还要在这里合并】
///   doubao_intent.dart 只负责识别「抖音百科：」等显式前缀并给出 forcedSources；
///   插件总开关与单信源配置仍由 dbWikiEffectiveSources() 管理。
///   这里把「前缀强制源」放最前，再与配置源去重合并，任何一方启用都不会丢。
List<String> dbEffectiveSources(List<String> forcedSources) {
  final cfg = dbWikiEffectiveSources();
  if (forcedSources.isEmpty) return cfg;
  final forced = dbWikiNormalizeSources(forcedSources);
  if (forced.isEmpty) return cfg;
  final out = <String>[...forced];
  for (final s in cfg) {
    if (!out.contains(s)) out.add(s);
  }
  return out;
}

String dbToolSystemPromptFor(String model, String apiUrl, String lang) {
  if (apiUrl != DS_API_URL) {
    final p = dbToolAgentPrompt(model, lang);
    if (p.trim().isNotEmpty) return p;
  }
  return dsToolAgentPrompt(lang, DS_TOOL_AGENT_SYSTEM_PROMPT);
}

/// ★ 维度解析：优先用显式的 dim。没有则按模型归属判定。
///   豆包模型 → db ／ 其他（DeepSeek / ST）→ ds。
///   ST 维度无法通过模型名区分，必须由调用方传入 dim='st'。
String dsDimOf(String model, [String dim = '']) {
  final d = dim.trim();
  if (d == DS_DIM_ST || d == DS_DIM_DB || d == DS_DIM_DS) return d;
  // ★ 中转站模型 → 独立 ST 维度（与 DeepSeek ds / 豆包 db 完全隔离）
  if (isRelayModel(model)) return DS_DIM_ST;
  return dbIsChatModel(model) ? DS_DIM_DB : DS_DIM_DS;
}

int dbToolMaxIterFor(String model, String apiUrl, int rounds) {
  var maxIter =
      apiUrl != DS_API_URL ? dbToolMaxRounds(model) : DS_TOOL_MAX_ITERATIONS;
  if (maxIter <= 0) maxIter = DS_TOOL_MAX_ITERATIONS;
  if (rounds > maxIter) maxIter = rounds;
  return maxIter;
}

// ------------------------------------------------------------
// SSE：流式发送
// ------------------------------------------------------------
Future<void> handleDsChatSendStream(
  HttpRequest req,
  String apiKey,
  String model,
  List<Map<String, dynamic>> apiMessages,
  int maxTokens,
  double temperature,
  int rounds,
  String sessionID,
  String content,
  List<String> fileIDs,
  bool enableTools, {
  /// ★ 维度（'ds' / 'db' / 'st'）。空串 → 照旧从模型判定。
  String dim = '',

  /// 用户是否在 UI 上开启了「联网搜索」。
  /// 抖音百科（方舟联网内容插件）只在确实要联网时才启用：
  /// 否则每一句普通聊天都会先跑一轮检索，首包被拖到数秒之后，
  /// 表现就是「豆包模式不是流式、非常慢」。
  bool webSearch = false,
  ModelRouteDecision? route,
  String apiUrl = DS_API_URL,

  /// UI 语言（用于选择拒绝禁令）
  String lang = '',

  /// 方舟专用附加字段（如 thinking）。DeepSeek 通道保持为 null。
  Map<String, dynamic>? extraBody,

  /// 待与媒体片段一起提交的 user 文本（含视频时才使用）
  String userPrompt = '',

  /// 已就绪的媒体片段（图片 / 音频）
  List<Map<String, dynamic>> mediaParts = const <Map<String, dynamic>>[],

  /// 尚未准备的大视频 id（在 SSE 建连后走 Files API 上传）
  List<String> pendingVideoIds = const <String>[],

  /// 前缀强制信源（doubao_intent.dart）。
  /// 非空时无视「抖音百科总闸」与「信源开关」的当前状态：
  /// 用户在有消息里写了「抖音百科：/百科：/墨迹天气：/天气：」，
  /// 就必须真的去检索，不允许因为开关关着而静默跳过。
  List<String> forcedSources = const <String>[],
}) async {
  final sse = Sse(req.response);

  // ★ 豆包思考链泵（见 doubao_thinking.dart）
  //   summary 型模型的 reasoning 是「大块突发 + 长空档」，
  //   这里在服务端就重排成一字级 micro-delta，前端每帧都有新字进来。
  //   DeepSeek 通道 isArk=false，pump 退化为直通，行为零变化。
  final reasoningPump = DbReasoningPump(
    model: model,
    isArkChannel: apiUrl != DS_API_URL,
    emit: (String d) {
      sse.send('reasoning', {'delta': d});
    },
  );

  // ---------- 大视频：SSE 已建连，后续上传期间由心跳保活 ----------
  if (pendingVideoIds.isNotEmpty) {
    try {
      await sse.send('media_progress', {
        'stage': 'begin',
        'count': pendingVideoIds.length,
      });
      final vid = await dbVideoContentForChat(
        videoFileIds: pendingVideoIds,
        model: model,
        apiKey: apiKey,
        onProgress: (info) {
          sse.send('media_progress', info);
        },
      );
      final promptOut =
          vid.text.isEmpty ? userPrompt : '$userPrompt\n\n${vid.text}';
      apiMessages.add({
        'role': 'user',
        'content': <Map<String, dynamic>>[
          {'type': 'text', 'text': promptOut},
          ...mediaParts,
          ...vid.parts,
        ],
      });
      await sse.send('media_progress', {
        'stage': 'ready',
        'parts': vid.parts.length,
        'segments': vid.text.isEmpty ? 0 : 1,
      });
    } on DbVideoArkException catch (e) {
      logp('❌ 视频准备失败（流式）: ${e.message}');
      await sse.send('error', {'message': e.message});
      await sse.done();
      return;
    } catch (e) {
      logp('❌ 视频准备失败（流式·意外）: $e');
      await sse.send('error', {'message': '视频准备失败：$e'});
      await sse.done();
      return;
    }
  }

  final contentBuf = StringBuffer();
  final reasoningBuf = StringBuffer();
  final usageAcc = DsUsageAcc();
  final streamStart = DateTime.now();
  DateTime? firstContentAt;

  // ---------- 工具模式 ----------
  if (enableTools) {
    // 工具模式 × 联网内容插件：方舟客服确认 Responses API 的 tools
    // 数组可同时放置 web_search 与 function，由模型自动选择调用，故不再互斥。
    // 仅在豆包通道 + 已开信源 + 无音视频时混用，其余退回原有工具链。
    final toolWikiSources =
        (apiUrl != DS_API_URL && (webSearch || forcedSources.isNotEmpty))
            ? dbEffectiveSources(forcedSources)
            : const <String>[];
    final useWikiTools = toolWikiSources.isNotEmpty &&
        pendingVideoIds.isEmpty &&
        dbWikiMediaSupported(mediaParts);
    if (!useWikiTools && apiUrl != DS_API_URL && toolWikiSources.isNotEmpty) {
      logp('ℹ️ 因含音频、视频输入，工具模式下不并用联网内容插件');
      await sse.send('notice', {
        'message': '当前输入含音频/视频，联网内容插件通道不支持，本次未启用百科检索',
      });
    }
    await sse.send('rounds', {'total': 0});
    await sse.send('tool_mode_start', {'start': true});

    final agentMsgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': dbToolSystemPromptFor(model, apiUrl, lang)},
      ...apiMessages,
    ];
    final maxIter = dbToolMaxIterFor(model, apiUrl, rounds);
    if (apiUrl != DS_API_URL) {
      logp('🫘 豆包专用工具模式: ${dbToolProfileOf(model)} '
          '／工具 ${dbToolCountOf(model)} 个');
    }
    logp('🔧 工具模式启动: 最多 $maxIter 次迭代（已注入 Agent 系统提示词）');

    final toolReasoningBuf = StringBuffer();

    ToolStreamOutcome outcome;
    try {
      if (useWikiTools) {
        final w = await callDbWikiWithToolsStream(
          apiKey,
          model,
          agentMsgs,
          maxTokens,
          toolWikiSources,
          maxIter,
          (s) {
            firstContentAt ??= DateTime.now();
            reasoningPump.hurry();
            contentBuf.write(s);
            sse.send('content', {'delta': s});
          },
          (phase, name, args, result) async {
            await sse.send('tool_call', {
              'phase': phase,
              'name': name,
              'args': args,
              'result': result,
            });
          },
          (s) {
            toolReasoningBuf.write(s);
            reasoningPump.push(s);
          },
          usageAcc,
          mediaParts: mediaParts,
          onSources: (list) {
            sse.send('sources', {'items': list, 'channel': 'wiki'});
          },
        );
        outcome = ToolStreamOutcome(w.content, w.reasoning, w.toolLogs);
      } else {
        outcome = await callDsWithToolsStream(
          apiKey,
          model,
          agentMsgs,
          maxTokens,
          temperature,
          maxIter,
          (s) {
            firstContentAt ??= DateTime.now();
            reasoningPump.hurry();
            contentBuf.write(s);
            sse.send('content', {'delta': s});
          },
          (phase, name, args, result) async {
            await sse.send('tool_call', {
              'phase': phase,
              'name': name,
              'args': args,
              'result': result,
            });
          },
          (s) {
            toolReasoningBuf.write(s);
            reasoningPump.push(s);
          },
          usageAcc,
          apiUrl: apiUrl,
          extraBody: extraBody,
          allowSearchTools: webSearch,
        );
      }
    } catch (e) {
      await sse.send('error', {'message': '$e'});
      await sse.done();
      return;
    }
    final toolLogs = outcome.toolLogs;

    // content 为空时回退使用纯 reasoning（剔除工具日志）
    if (contentBuf.toString().trim().isEmpty) {
      final cleaned = StringBuffer();
      for (final line in toolReasoningBuf.toString().split('\n')) {
        final t = line.trim();
        if (t.startsWith('🔧') ||
            t.startsWith('参数:') ||
            t.startsWith('結果:') ||
            t.startsWith('✅')) {
          continue;
        }
        cleaned.write(line);
        cleaned.write('\n');
      }
      final r = cleaned.toString().trim();
      if (r.isNotEmpty) {
        logp('⚠️ 工具模式的 content 为空。回退到纯 reasoning（${runeLen(r)} 字）');
        firstContentAt ??= DateTime.now();
        contentBuf.clear();
        contentBuf.write(r);
        await sse.send('content', {'delta': r});
      }
    }

    logp('🔧 工具模式完成: content=${runeLen(contentBuf.toString())} 字, '
        'reasoning=${runeLen(toolReasoningBuf.toString())} 字, toolLogs=${toolLogs.length} 条');

    if (toolLogs.isEmpty && contentBuf.toString().trim().isEmpty) {
      reasoningPump.push('AI 判断该问题无需调用工具，也没有返回正文。\n');
    }

    final now = DateTime.now();
    final savedContent = content.isEmpty ? '[工具模式]' : content;
    final userMsg = DsMessage(
      id: 'dsm_${fmtStamp14(now)}_${randomHex(6)}',
      sessionId: sessionID,
      role: 'user',
      content: savedContent,
      createdAt: rfc3339(now),
      attachments: fileIDs.join(','),
    );
    userMsg.dim = dsDimOf(model, dim);
    appendDsMessage(userMsg);

    final aiMsg = DsMessage(
      id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
      sessionId: sessionID,
      role: 'assistant',
      content: contentBuf.toString(),
      createdAt: rfc3339(DateTime.now()),
      reasoning: outcome.reasoning,
      // 经由豆包时不保存 usage（因为无法精确获取方舟的消耗量）
      usage: usageAcc.snapshot(),
    );
    aiMsg.dim = dsDimOf(model, dim);
    appendDsMessage(aiMsg);

    final sess = getDsSession(sessionID);
    var title = '新对话';
    if (sess != null) {
      title = sess.title;
      if (title.isEmpty || title == '新对话') {
        final runes = content.runes.toList();
        if (runes.isEmpty) {
          title = '[工具对话]';
        } else if (runes.length > 18) {
          title = '${String.fromCharCodes(runes.sublist(0, 18))}…';
        } else {
          title = content;
        }
      }
    }
    updateDsSession(sessionID, title, rfc3339(DateTime.now()));

    var thinkingTimeMs = 0;
    if (firstContentAt != null) {
      thinkingTimeMs = firstContentAt!.difference(streamStart).inMilliseconds;
    }
    await sse.send('done', {
      'userMessage': userMsg.toJson(),
      'aiMessage': aiMsg.toJson(),
      'title': title,
      'charCount': runeLen(contentBuf.toString()),
      'model': model,
      'modelRoute': route?.toJson(),
      'toolMode': true,
      'thinkingTimeMs': thinkingTimeMs,
      'totalTimeMs': DateTime.now().difference(streamStart).inMilliseconds,
      'usage': aiMsg.usage?.toJson(),
    });
    await sse.done();
    return;
  }

  // ---------- 普通 / 多轮反思 ----------
  await sse.send('rounds', {'total': rounds});
  DateTime? reasoningStart;
  var reasoningTotalMs = 0;

  // ---------- 豆包联网内容插件（抖音百科等）----------
  // 方舟文档硬约束：sources=[douyin] 等属于「联网内容插件」，
  // 仅 Responses API 支持，Chat Completions 无法指定；因此这里分流。
  // 仅豆包通道 + 用户显式开启信源 + 纯文本输入时启用。
  final wikiSources = apiUrl != DS_API_URL
      ? dbEffectiveSources(forcedSources)
      : const <String>[];
  // 图片（image_url）可随 input_image 一起提交，与 web_search 并存；
  // 音频 / 视频在插件通道不保证可用，出现时回退原生多模态。
  final canUseWiki = (webSearch || forcedSources.isNotEmpty) &&
      wikiSources.isNotEmpty &&
      pendingVideoIds.isEmpty &&
      dbWikiMediaSupported(mediaParts);

  if (canUseWiki) {
    logp('豆包联网内容插件模式: 信源=${wikiSources.join(",")}');
    try {
      await callDbWikiResponsesStream(
        apiKey,
        model,
        apiMessages,
        maxTokens,
        wikiSources,
        (s) {
          reasoningBuf.write(s);
          reasoningStart ??= DateTime.now();
          reasoningPump.push(s);
        },
        (s) {
          if (reasoningStart != null) {
            reasoningTotalMs +=
                DateTime.now().difference(reasoningStart!).inMilliseconds;
            reasoningStart = null;
          }
          firstContentAt ??= DateTime.now();
          contentBuf.write(s);
          sse.send('content', {'delta': s});
        },
        usageAcc: usageAcc,
        baseUrl: dbBaseUrl(null),
        mediaParts: mediaParts,
        onSources: (list) {
          sse.send('sources', {'items': list, 'channel': 'wiki'});
        },
      );
    } catch (e) {
      logp('豆包联网内容插件调用失败: $e');
      await sse.send('error', {'message': '$e'});
      await sse.done();
      return;
    }
  } else if (dbVideoMessagesNeedResponses(model, apiMessages)) {
    logp('视频理解：DeepSeek V4 系列走 Responses API');
    try {
      await callDbVideoResponsesStream(
        apiKey,
        model,
        apiMessages,
        maxTokens,
        (s) {
          reasoningBuf.write(s);
          reasoningStart ??= DateTime.now();
          reasoningPump.push(s);
        },
        (s) {
          if (reasoningStart != null) {
            reasoningTotalMs +=
                DateTime.now().difference(reasoningStart!).inMilliseconds;
            reasoningStart = null;
          }
          firstContentAt ??= DateTime.now();
          contentBuf.write(s);
          sse.send('content', {'delta': s});
        },
        usageAcc,
      );
    } catch (e) {
      await sse.send('error', {'message': '$e'});
      await sse.done();
      return;
    }
  } else {
    try {
      await callDsMultiRoundStream(
        apiKey,
        model,
        apiMessages,
        maxTokens,
        temperature,
        rounds,
        (round, total, stage) {
          sse.send('round', {'round': round, 'total': total, 'stage': stage});
        },
        (s) {
          reasoningBuf.write(s);
          reasoningStart ??= DateTime.now();
          reasoningPump.push(s);
        },
        (s) {
          if (s == '\x00__NEW_ROUND__\x00') {
            contentBuf.clear();
            sse.send('new_round', {'reset': true});
            return;
          }
          if (reasoningStart != null) {
            reasoningTotalMs +=
                DateTime.now().difference(reasoningStart!).inMilliseconds;
            reasoningStart = null;
          }
          firstContentAt ??= DateTime.now();
          contentBuf.write(s);
          sse.send('content', {'delta': s});
        },
        usageAcc,
        apiUrl: apiUrl,
        extraBody: extraBody,
        onReferences: (list) {
          // 豆包自带联网搜索的信源：仅在方舟通道出现，DeepSeek 恒为空。
          sse.send('sources', {'items': list, 'channel': 'doubao'});
        },
      );
    } catch (e) {
      await sse.send('error', {'message': '$e'});
      await sse.done();
      return;
    }
  }

  if (reasoningStart != null) {
    reasoningTotalMs +=
        DateTime.now().difference(reasoningStart!).inMilliseconds;
    reasoningStart = null;
  }

  final now = DateTime.now();
  final savedContent = content.isEmpty ? '[已上传文件]' : content;
  final userMsg = DsMessage(
    id: 'dsm_${fmtStamp14(now)}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'user',
    content: savedContent,
    createdAt: rfc3339(now),
    attachments: fileIDs.join(','),
  );
  userMsg.dim = dsDimOf(model, dim);
  appendDsMessage(userMsg);

  final aiMsg = DsMessage(
    id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'assistant',
    content: contentBuf.toString(),
    createdAt: rfc3339(DateTime.now()),
    reasoning: reasoningBuf.toString(),
    usage: usageAcc.snapshot(),
  );
  aiMsg.dim = dsDimOf(model, dim);
  appendDsMessage(aiMsg);

  final sess = getDsSession(sessionID);
  var title = '新对话';
  if (sess != null) {
    title = sess.title;
    if (title.isEmpty || title == '新对话') {
      final runes = content.runes.toList();
      if (runes.isEmpty) {
        title = '[文件对话]';
      } else if (runes.length > 18) {
        title = '${String.fromCharCodes(runes.sublist(0, 18))}…';
      } else {
        title = content;
      }
    }
  }
  updateDsSession(sessionID, title, rfc3339(DateTime.now()));

  var thinkingTimeMs = 0;
  if (reasoningTotalMs > 0) {
    thinkingTimeMs = reasoningTotalMs;
  } else if (firstContentAt != null) {
    thinkingTimeMs = firstContentAt!.difference(streamStart).inMilliseconds;
  }

  // ★ 收尾：先把思考链泵里剩余的字全部吐完，再发 done。
  //   否则最后一段思考会被 done 截断，前端表现为「思考链少了一截」。
  await reasoningPump.finish();
  if (reasoningPump.smoothed) {
    logp('🧠 思考链平滑: ${reasoningPump.chars} 字已按 micro-delta 重排下发');
  }

  await sse.send('done', {
    'userMessage': userMsg.toJson(),
    'aiMessage': aiMsg.toJson(),
    'title': title,
    'charCount': runeLen(contentBuf.toString()),
    'model': model,
    'modelRoute': route?.toJson(),
    'thinkingTimeMs': thinkingTimeMs,
    'totalTimeMs': DateTime.now().difference(streamStart).inMilliseconds,
    'usage': aiMsg.usage?.toJson(),
  });
  await sse.done();
}

// ------------------------------------------------------------
// 小说模式（非流式）
// ------------------------------------------------------------
Future<void> handleDsNovelGeneration(
  HttpRequest req,
  String sessionID,
  String apiKey,
  String model,
  String theme,
  String tags,
  String genre,
  String story,
  int targetChars, {
  String dim = '',
}) async {
  final res = req.response;
  var target = targetChars;
  if (target <= 0) target = DS_NOVEL_DEFAULT_CHARS;
  if (target < DS_NOVEL_MIN_CHARS) target = DS_NOVEL_MIN_CHARS;
  if (target > DS_NOVEL_MAX_CHARS) target = DS_NOVEL_MAX_CHARS;
  var g = genre.trim();
  if (g.isEmpty) g = '都市';
  final th = theme.trim();
  final tg = tags.trim();
  final st = story.trim();

  logp('📖 小说模式启动: 分类=$g 主题=$th 标签=$tg 目标=$target 字');

  var userContent = '📖 小说创作\n分类: $g\n主题: $th\n标签: $tg\n目标字数: $target';
  if (st.isNotEmpty) userContent += '\n故事设定: $st';

  final userMsg = DsMessage(
    id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'user',
    content: userContent,
    createdAt: rfc3339(DateTime.now()),
  );
  userMsg.dim = dsDimOf(model, dim);
  appendDsMessage(userMsg);

  final basePrompt = buildNovelBasePrompt(th, tg, g, st, target);
  final usageAcc = DsUsageAcc();
  final gen = await generateNovel(apiKey, model, basePrompt, target, usageAcc);
  if (gen.error != null && gen.text.trim().isEmpty) {
    await dsJSONErr(res, 500, '小说生成失败: ${gen.error}');
    return;
  }

  final aiMsg = DsMessage(
    id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'assistant',
    content: gen.text,
    createdAt: rfc3339(DateTime.now()),
    usage: usageAcc.snapshot(),
  );
  aiMsg.dim = dsDimOf(model, dim);
  appendDsMessage(aiMsg);

  var title = '小説創作';
  if (th.isNotEmpty) {
    final runes = th.runes.toList();
    title = runes.length > 15
        ? '${String.fromCharCodes(runes.sublist(0, 15))}…'
        : th;
  }
  final sess = getDsSession(sessionID);
  if (sess != null &&
      sess.title.isNotEmpty &&
      sess.title != '新对话' &&
      sess.title != '小説創作') {
    title = sess.title;
  }
  updateDsSession(sessionID, title, rfc3339(DateTime.now()));

  logp('✅ 小说生成完成。共 ${runeLen(gen.text)} 字');
  await dsJSONOk(res, 200, {
    'success': true,
    'userMessage': userMsg.toJson(),
    'aiMessage': aiMsg.toJson(),
    'title': title,
    'charCount': runeLen(gen.text),
    'model': model,
    'novelMode': true,
    'usage': aiMsg.usage?.toJson(),
  });
}

// ------------------------------------------------------------
// 小说模式（流式）
// ------------------------------------------------------------
Future<void> handleDsNovelGenerationStream(
  HttpRequest req,
  String sessionID,
  String apiKey,
  String model,
  String theme,
  String tags,
  String genre,
  String story,
  int targetChars, {
  String dim = '',
}) async {
  var target = targetChars;
  if (target <= 0) target = DS_NOVEL_DEFAULT_CHARS;
  if (target < DS_NOVEL_MIN_CHARS) target = DS_NOVEL_MIN_CHARS;
  if (target > DS_NOVEL_MAX_CHARS) target = DS_NOVEL_MAX_CHARS;
  var g = genre.trim();
  if (g.isEmpty) g = '都市';
  final th = theme.trim();
  final tg = tags.trim();
  final st = story.trim();

  final sse = Sse(req.response);

  var userContent = '📖 小说创作\n分类: $g\n主题: $th\n标签: $tg\n目标字数: $target';
  if (st.isNotEmpty) userContent += '\n故事设定: $st';
  final userMsg = DsMessage(
    id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'user',
    content: userContent,
    createdAt: rfc3339(DateTime.now()),
  );
  userMsg.dim = dsDimOf(model, dim);
  appendDsMessage(userMsg);
  await sse.send('user_message', userMsg.toJson());

  logp('📖 小说模式（流式）启动: 分类=$g 主题=$th 标签=$tg 目标=$target 字');

  final basePrompt = buildNovelBasePrompt(th, tg, g, st, target);
  final usageAcc = DsUsageAcc();

  final gen = await generateNovelStream(
    apiKey,
    model,
    basePrompt,
    target,
    (delta) async => sse.send('content', {'delta': delta}),
    (segIdx) async => sse.send('novel_segment', {'index': segIdx}),
    (done, tgt) => sse.send('novel_progress', {'done': done, 'target': tgt}),
    usageAcc,
  );
  if (gen.error != null && gen.text.trim().isEmpty) {
    await sse.send('error', {'message': gen.error});
    await sse.done();
    return;
  }

  final aiMsg = DsMessage(
    id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'assistant',
    content: gen.text,
    createdAt: rfc3339(DateTime.now()),
    usage: usageAcc.snapshot(),
  );
  aiMsg.dim = dsDimOf(model, dim);
  appendDsMessage(aiMsg);

  var title = '小説創作';
  if (th.isNotEmpty) {
    final runes = th.runes.toList();
    title = runes.length > 15
        ? '${String.fromCharCodes(runes.sublist(0, 15))}…'
        : th;
  }
  final sess = getDsSession(sessionID);
  if (sess != null &&
      sess.title.isNotEmpty &&
      sess.title != '新对话' &&
      sess.title != '小説創作') {
    title = sess.title;
  }
  updateDsSession(sessionID, title, rfc3339(DateTime.now()));

  await sse.send('done', {
    'userMessage': userMsg.toJson(),
    'aiMessage': aiMsg.toJson(),
    'title': title,
    'charCount': runeLen(gen.text),
    'model': model,
    'novelMode': true,
    'usage': aiMsg.usage?.toJson(),
  });
  await sse.done();
}

// ------------------------------------------------------------
// /api/ds-chat/send
// ------------------------------------------------------------
Future<void> handleDsChatSend(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await dsJSONErr(res, 400, '无效请求体');
    return;
  }

  final sessionID = mStr(body, 'sessionId');
  var content = mStr(body, 'content').trim();
  final fileIDs = asList(body['fileIds']).map((e) => '$e').toList();
  final webSearch = mBool(body, 'webSearch');
  final deepThink = mBool(body, 'deepThink');
  var level = intArgDefault(body, 'reasoningLevel', 1);
  // ★ 多轮反思独立开关：0=关闭（默认），1~10=反思次数。
  //   推理等级只影响温度/初始输出上限，任何等级都不再自动触发反思。
  var reflectionRounds = intArgDefault(body, 'reflectionRounds', 0);
  if (reflectionRounds < 0) reflectionRounds = 0;
  if (reflectionRounds > 10) reflectionRounds = 10;
  final longTextMode = mBool(body, 'longTextMode');
  final targetChars = intArgDefault(body, 'targetChars', 0);
  final novelMode = mBool(body, 'novelMode');
  final novelTheme = mStr(body, 'novelTheme');
  final novelTags = mStr(body, 'novelTags');
  final novelGenre = mStr(body, 'novelGenre');
  final novelStory = mStr(body, 'novelStory');
  final novelChars = intArgDefault(body, 'novelChars', 0);
  var enableTools = mBool(body, 'enableTools');
  // ★ 双保险（严重 Bug 修复）：前端 UI 的真实开关状态随请求一起上报。
  //   enableTools 与 toolModeUI 必须同时为 true 才算开启；
  //   只要前端明确表示「UI 上工具模式是关的」，服务端就不下发 tools 定义，
  //   DsToolGate 也会同步为 OFF —— 从根上避免「UI 关着但模型照跑工具」。
  if (body.containsKey('toolModeUI') && !mBool(body, 'toolModeUI')) {
    enableTools = false;
  }
  // ★ 显式按钮（墨迹天气 / 头条图文）触发的插件调用。
  //   白名单制：只认下面这两种，其它值一律视为无效，避免变成通用绕过开关。
  var explicitPlugin = mStr(body, 'explicitPlugin').trim().toLowerCase();
  if (!const <String>['moji', 'toutiao'].contains(explicitPlugin)) {
    explicitPlugin = '';
  }
  final injectedPrompts =
      asList(body['injectedPrompts']).map((e) => '$e').toList();
  final stream = mBool(body, 'stream');

  if (content.isEmpty && fileIDs.isEmpty && !novelMode) {
    await dsJSONErr(res, 400, '内容不能为空');
    return;
  }
  if (sessionID.isEmpty) {
    await dsJSONErr(res, 400, '缺少会话ID');
    return;
  }

  final cfg = getDsConfig();
  var model = mStr(body, 'model').trim();

  // ★★★ 停用整改：中转站（st 维度）聊天入口硬拦截 ★★★
  //   无论前端如何传参，只要显式 dim=st 或模型命中中转站目录，一律 403 拒绝，
  //   绝不发起任何对第三方中转站的请求，杜绝聊天内容外泄。
  if (RELAY_DISABLED &&
      (mStr(body, 'dim').trim() == DS_DIM_ST || isRelayModel(model))) {
    await dsJSONErr(res, 403, RELAY_DISABLED_MSG);
    return;
  }
  if (model.isEmpty) model = cfg.model;
  if (model.isEmpty) model = DS_DEFAULT_MODEL;
  // 历史模型值（如 doubao-seed-2-1-pro-260628）统一到当前版本号 260915，
  // 否则方舟侧会因未知模型返回 404。别名表见 db_limits.dart。
  model = dbCanonicalModelValue(model);

  // ========== 通道判定：中转站 > 豆包（火山方舟）> DeepSeek ==========
  // ① 中转站模型（sta1n.ai 等 OpenAI 兼容）→ 独立鉴权与终点；
  // ② 豆包目录模型 → 鉴权与终点全部切到方舟，绝不把豆包模型名发往 DeepSeek；
  // ③ 其余 → DeepSeek。
  final dbCfg = getDbConfig();
  final relayCfg = getRelayConfig();
  final useRelay = isRelayModel(model);
  final useDoubao = !useRelay && dbIsChatModel(model);
  // ★ 维度：ST 维度由前端用 body.dim='st' 明示
  final dimReq = mStr(body, 'dim').trim();
  final dimOverride =
      (dimReq == DS_DIM_ST || dimReq == DS_DIM_DB || dimReq == DS_DIM_DS)
          ? dimReq
          : '';
  final chatDim = dsDimOf(model, dimOverride);
  // ★ 维度与通道硬校验：搜索工具绝不允许跨维度串联。
  //   豆包维度只走豆包搜索，DeepSeek 维度只走 DeepSeek 搜索；
  //   若前端维度与模型路由不一致，直接拒绝，避免把搜索额度花到错误通道。
  if (dimOverride == DS_DIM_DB && !useDoubao) {
    await dsJSONErr(res, 400,
        dbLocalized(dsRequestLang(req, body), 'dimModelMismatchDb'));
    return;
  }
  if (dimOverride == DS_DIM_DS && useDoubao) {
    await dsJSONErr(res, 400,
        dbLocalized(dsRequestLang(req, body), 'dimModelMismatchDs'));
    return;
  }
  if (useDoubao) {
    if (dbCfg.apiKey.isEmpty) {
      await dsJSONErr(res, 400, '已选择豆包模型，但豆包 API Key 未填写（设置 → 豆包设定）');
      return;
    }
  } else if (useRelay) {
    if (relayCfg.apiKey.isEmpty) {
      await dsJSONErr(res, 400, '已选择中转站模型，但中转站 API Key 未填写（设置 → 中转站设定）');
      return;
    }
  } else if (cfg.apiKey.isEmpty) {
    await dsJSONErr(res, 400, '请先配置 DeepSeek API Key');
    return;
  }
  final callKey =
      useDoubao ? dbCfg.apiKey : (useRelay ? relayCfg.apiKey : cfg.apiKey);
  final callUrl = useDoubao
      ? dbChatEndpoint()
      : (useRelay ? relayChatEndpoint() : DS_API_URL);
  logp('🚀 使用模型: $model (请求=${mStr(body, 'model')}, 配置=${cfg.model}, '
      '経路=${useDoubao ? '豆包/方舟' : (useRelay ? '中转站' : 'DeepSeek')})');

  // ★★ 显式插件按钮通道（墨迹天气 / 头条图文）
  //   用户需求：
  //     ① 点击按钮后「关闭工具模式」——function calling 全部禁用；
  //     ② 但「必须真的调用该联网内容插件」，并把结果按 Markdown 返回。
  //   实现要点：
  //     · explicitPlugin 只用于「强制信源」，绝不开启工具模式；
  //     · 本请求 enableTools 被硬性置为 false，并同步 DsToolGate 为 OFF；
  //     · 插件走 Responses API 的 web_search(sources=[moji|toutiao])，
  //       与 function calling 是两条完全独立的通道。
  final List<String> explicitSources =
      explicitPlugin.isEmpty ? const <String>[] : <String>[explicitPlugin];
  if (explicitPlugin.isNotEmpty) {
    if (!useDoubao) {
      await dsJSONErr(res, 400, '墨迹天气 / 头条图文插件仅支持豆包模型，请先切换到豆包模式');
      return;
    }
    enableTools = false;
    DsToolGate.syncMode(sessionID, false);
    logp('🎯 显式插件: $explicitPlugin（工具模式强制 OFF，只调用该插件）');
  }

  // ★★ 前缀强制信源（doubao_intent.dart）
  //   「抖音百科：」「抖音百科搜索：」「百科：」→ 强制 douyin
  //   「墨迹天气：」「天气：」            → 强制 moji
  //   判定范围是消息任意位置；前缀本身从正文里剥掉，不进入模型与标题。
  //   DeepSeek 通道不解析（那套插件只存在于方舟），行为零变化。
  var dbIntent = useDoubao ? dbParseIntent(content) : DbIntent.none;
  final List<String> forcedSources = explicitSources.isNotEmpty
      ? explicitSources
      : (dbIntent.forced ? dbIntent.sources : const <String>[]);
  if (explicitSources.isNotEmpty) {
    logp('📌 显式插件的强制信源: ' + explicitSources.join(','));
  }
  if (dbIntent.forced) {
    content = dbIntent.cleaned;
    logp('📌 检测到信源前缀: ${dbIntent.hits.join(' / ')} '
        '→ 強制 sources=${forcedSources.join(',')}');
  }

  // ★★ 抖音百科插件的有效信源：总开关 / 单信源 / 显式前缀三者统一口径。
  //    只要这里非空，就说明用户确实启用了百科插件，本次必须联网。
  //    不能再让「智能搜索判定不需要联网」把它拦掉。
  final dbWikiSourcesNow =
      useDoubao ? dbEffectiveSources(forcedSources) : const <String>[];
  final dbWikiActiveNow = useDoubao && dbWikiSourcesNow.isNotEmpty;

  // ★★ 智能搜索总闸：联网按钮只代表“允许搜索”，不代表每条消息都必须搜。
  //    纯问候 / 定义 / 闲聊 / 创作 / 代码等内部知识可答的内容一律跳过，
  //    只有明确要求来源、时效性事实或外部信息时才真正调用搜索。
  //    显式信源前缀 / 插件视为用户已明确要求，必须检索。
  //    ★ 2026-11-24 严重修复：抖音百科信源非空时，无条件强制联网。
  //      否则「百科总开关开着、联网按钮开着，但插件仍被判定不联网」。
  final searchIntent =
      dbWebSearchIntent(content, forced: forcedSources.isNotEmpty);
  final effectiveWebSearch = content.isNotEmpty &&
      (forcedSources.isNotEmpty ||
          dbWikiSourcesNow.isNotEmpty ||
          (webSearch && searchIntent.need));
  if (dbWikiSourcesNow.isNotEmpty) {
    logp('🧭 智能搜索：抖音百科插件启用，强制联网'
        '（信源=${dbWikiSourcesNow.join(",")}）');
  } else if (webSearch && !effectiveWebSearch) {
    logp('🧭 智能搜索：跳过联网（${searchIntent.reason}）');
  } else if (effectiveWebSearch) {
    logp('🧭 智能搜索：允许联网（${searchIntent.reason}）');
  }

  // ========== 小说模式分流 ==========
  if (novelMode) {
    if (stream) {
      await handleDsNovelGenerationStream(req, sessionID, cfg.apiKey, model,
          novelTheme, novelTags, novelGenre, novelStory, novelChars,
          dim: chatDim);
      return;
    }
    await handleDsNovelGeneration(req, sessionID, cfg.apiKey, model, novelTheme,
        novelTags, novelGenre, novelStory, novelChars,
        dim: chatDim);
    return;
  }

  // ★ 推理等级：上限 999（前端 dscLevelRange 同步），等级不再决定 max_tokens，
  //   也不再决定反思轮数（1~999 全部单轮直接回答）。
  level = dbClampReasoningLevel(level);
  var params = levelToParams(level);
  var maxTokens = params.maxTokens;
  var temperature = params.temperature;
  // rounds = 1 表示单轮直接回答；>1 表示初稿 + (rounds-1) 次反思。
  var rounds = reflectionRounds > 0 ? reflectionRounds + 1 : 1;

  if (longTextMode) {
    maxTokens = DS_MAX_OUTPUT_TOKENS;
    rounds = 1;
    // 超长文默认 1.0，但 Lv.900–999 仍必须按 0.0 采样。
    temperature = level >= 900 ? 0.0 : 1.0;
    logp('📚 超长文模式启用: maxTokens=$maxTokens, 目标字数=$targetChars');
  }
  // ★★★ 统一能力上限（db_limits.dart，优先级高于推理等级／超长文模式）★★★
  //   · 上下文 1024K（1K=1000，固定 1,024,000）；
  //   · 角色扮演固定 32K；其它特例模型（2.0-lite / 2.0-mini / 2.0-turbo / GLM-5.2 /
  //     2.1 lite・Pro・turbo / Evolving）只设最大上限，实际取全局档位与该上限的较小值。
  final cappedOut = dbForcedMaxOutput(model);
  if (cappedOut > 0) {
    if (maxTokens != cappedOut) {
      logp('🔒 输出上限: $model → $cappedOut tokens（原 $maxTokens，按模型上限与全局档位取小）');
    }
    maxTokens = cappedOut;
  }
  if (enableTools) {
    // 工具模式走独立 function-calling 分支，绝不叠加多轮反思。
    temperature = 0.0;
    rounds = 1;
  }
  // Kimi 系列（kimi-k3 / kimi-k3.1-pro 等）接口要求温度 1.0；
  // 但 Lv.900–999 的「0.0 采样」是全局硬规则，此时不再强制 1.0。
  if (dbIsKimiModel(model) && level < 900) {
    if (temperature != DB_KIMI_TEMPERATURE) {
      logp('🌡️ Kimi 强制温度: $model → $DB_KIMI_TEMPERATURE（原 $temperature）');
    }
    temperature = DB_KIMI_TEMPERATURE;
  }

  // ========== 多轮反思 × 抖音百科：职责单一，绝不叠加 ==========
  // 1) 反思只由前端「多轮反思」开关的 reflectionRounds(1~10) 触发；
  //    工具模式独立走 function-calling 分支、不进入反思循环；长文模式保持单轮。
  // 2) 抖音百科（联网内容插件，仅 Responses API）启用期间强制暂停工具模式：
  //    混用通道里内置 web_search 与 function web_search 同名，会互相抢占，
  //    模型被闸门拒绝后反复重试，表现为「调用超时」。插件必须独占本轮。
  if (!longTextMode) {
    if (reflectionRounds > 0 && rounds > 1) {
      logp(
          '🔁 多轮反思已开启: $reflectionRounds 轮（rounds=$rounds, model=$model, Lv.$level 仅影响温度）');
    } else {
      logp('➡️ 单轮直接回答: model=$model, Lv.$level（等级不触发反思）');
    }
  }
  // ★★★ 2026-11-24 严重修复：抖音百科启用期间，工具模式必须让路。
  //   原因：Responses API 混用通道里，内置插件也叫 web_search，而豆包工具集
  //   里还有一个同名 function web_search。两者同时下发会造成同名冲突，
  //   模型可能反复调用 function web_search，被搜索闸门拒绝后表现为
  //   「调用超时 / 请稍后再试」，百科插件却从未真正执行。
  //   因此百科可用时只走 Responses API 插件通道（callDbWikiResponsesStream），
  //   不再混用 function tools。
  //   音视频输入插件不保证可用，此时保留工具模式，由工具链自行处理。
  //   （文件上下文在下方构建，故本次判定与工具闸门绑定也移到 fileCtx 之后。）

  // 注入提示词（system 角色）
  // 本机开发者工具（devtools）功能，按所有者要求恢复启用。
  final injected = injectedPrompts
      .map((e) => '$e'.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (injected.isNotEmpty) {
    logp('🧩 应用外部注入提示词: ${injected.length} 条（system 角色）');
  }

  final fileCtx = buildFileContext(fileIDs);

  // ★ 抖音百科插件可用性判定：插件不支持音频/视频输入，此类请求保留工具模式。
  //   纯文本 / 图片可以走插件，此时暂停工具模式，避免 web_search 同名冲突。
  final dbWikiPluginUsableNow = dbWikiActiveNow &&
      fileCtx.audioFileIds.isEmpty &&
      fileCtx.videoFileIds.isEmpty;
  if (useDoubao && enableTools && dbWikiPluginUsableNow) {
    enableTools = false;
    logp('🛑 抖音百科已启用：本次暂停工具模式，'
        '只走 Responses API 联网内容插件（避免 web_search 同名冲突）');
  }
  // ★ 单一可信来源：本请求最终的 enableTools 就是服务端闸门的模式状态。
  //   之后所有工具执行（含插件混用通道）都以这里为准，前端状态不再能「带私货」。
  DsToolGate.bind(sessionID);
  // ★ 请求租约：只有处在正在处理的聊天请求里，工具才可能被执行。
  //   请求外 / 租约过期后，任何残留绑定一律 fail-closed。
  //   searchOn 对豆包同样放行：豆包工具模式通过 DeepSeek 官方搜索/抓取工具
  //   联网，搜索按钮与工具按钮可以同时打开。
  DsToolGate.beginRequest(sessionID, enableTools,
      searchOn: effectiveWebSearch);
  DsToolGate.syncMode(sessionID, enableTools);

  // ========== 豆包通道：音频 / 视频理解能力校验 ==========
  // 豆包模式下媒体附件必须由具备对应能力的豆包模型直接理解：
  //   · 绝不把音视频降级成「文件名」文本偷偷送去 DeepSeek（会消耗 DeepSeek 用量）
  //   · 模型不具备该能力时如实报错，并列出可切换的模型
  final mediaLang = dsRequestLang(req, body);
  if (useDoubao) {
    if (fileCtx.audioFileIds.isNotEmpty && !dbSupportsAudioInput(model)) {
      await dsJSONErr(
          res,
          400,
          dbLocalized(mediaLang, 'audioUnsupported',
              [model, dbAudioCapableModels.join(' / ')]));
      return;
    }
    if (fileCtx.videoFileIds.isNotEmpty && !dbSupportsVideoInput(model)) {
      await dsJSONErr(
          res,
          400,
          dbLocalized(mediaLang, 'videoUnsupported',
              [model, dbVideoCapableModels.join(' / ')]));
      return;
    }
  }

  // ============ 模型自动路由（本轮含图片 → 视觉模型）============
  // 改造前：图片提取直接传 model，选 pro 就等于用纯文本模型读图，
  // 结果是「图片内容提取失败」这种静默降级。现在统一由 model_router 判定：
  //   - 所选模型本身支持图片 → 原样使用；
  //   - 所选模型不支持（如 deepseek-v4-pro）→ 路由到视觉兜底模型。
  final routeSettings = getModelRouteSettings();
  // 豆包模型不参与 DeepSeek 的视觉路由（否则会被改名为 deepseek-flash）
  final route = useDoubao
      ? ModelRouteDecision(
          requested: model,
          effective: model,
          visionModel: model,
          reason: 'doubao-direct',
          routed: false,
          hasImage: fileCtx.imageFileIds.isNotEmpty,
          requestedSupportsVision: fileCtx.imageFileIds.isNotEmpty,
        )
      : resolveModelRoute(model,
          hasImage: fileCtx.imageFileIds.isNotEmpty, settings: routeSettings);
  if (route.hasImage || route.routed || route.reason == 'router-disabled') {
    recordModelRoute(route);
    logp('🔀 模型路由: ${route.summary} · 视觉提取模型=${route.visionModel}');
  }
  if (route.routed) {
    logp('🔀 主请求的模型切换为 ${route.effective}（原选择 ${route.requested}）');
    model = route.effective;
  }

  var userPrompt = content;
  if (fileCtx.text.isNotEmpty) {
    if (userPrompt.isNotEmpty) userPrompt += '\n\n';
    userPrompt += fileCtx.text;
  }

  // ★ 联网检索的归属：
  //   ① 抖音百科（联网内容插件）开启 → Responses API 自带检索；
  //   ② 工具模式开启 → 不附加 web_search_options，由模型调用
  //      web_search / fetch（两者均为 DeepSeek 官方实现，豆包模式同样复用）；
  //   ③ 纯搜索模式（工具关闭）→ 豆包走 web_search_options，DeepSeek 走官方搜索。
  //   这样「工具模式」和「联网搜索」两个按钮可以同时打开，不会互相强制关闭。
  var dbNativeSearch = false;
  if (effectiveWebSearch) {
    final wikiOn = dbWikiPluginUsableNow;
    if (wikiOn) {
      // 插件负责搜索；工具模式已在上面暂停，避免 web_search 同名冲突。
      logp('🔍 豆包模式：联网内容插件负责搜索，工具模式暂停');
    } else if (useDoubao) {
      dbNativeSearch = true;
      logp('🔍 豆包模式：启用联网搜索（工具模式时改走 web_search/fetch 工具）');
    } else {
      final ctx = await buildWebSearchContext(content);
      if (ctx.isNotEmpty) userPrompt += ctx;
    }
  }
  if (userPrompt.trim().isEmpty) userPrompt = '请查看上传的文件。';

  if (longTextMode) {
    final target = targetChars <= 0 ? DS_TARGET_CHARS_5M : targetChars;
    userPrompt +=
        '''\n\n【重要指令 · 超长文模式】\n请原样输出完整长文。目标字数为 $target 字（约 $target 字相当）。\n要求:\n1. 不写"接下来..."、"以下是..."、"总结"之类的前言或结语\n2. 从正文直接开始，章节划分清晰，内容充实\n3. 不以长度限制为由提前结束，尽可能写完\n4. 保持内容质量，避免重复注水''';
  }

  // 图片内容提取（仅 DeepSeek 通道需要：先让视觉模型转述，再交给文本模型）
  // 豆包通道不转述：原图直接交给模型本人看，由它自己回答并思考。
  if (!useDoubao && fileCtx.imageFileIds.isNotEmpty) {
    final visionDescs = <String>[];
    for (var i = 0; i < fileCtx.imageFileIds.length; i++) {
      final imgID = fileCtx.imageFileIds[i];
      final b64 = dsFileToBase64(imgID);
      if (b64.error == null && b64.b64.isNotEmpty) {
        logp('🖼️ 检测到第 ${i + 1}/${fileCtx.imageFileIds.length} 张图片。提取内容中...');
        final visionPrompt = '请详细说明第 ${i + 1} 张图片的内容，提取其中包含的所有文字，并归纳要点。';
        try {
          final desc = await callDsVisionAPI(
              callKey, visionPrompt, b64.b64, b64.mime, 4096, 1.0,
              model: route.visionModel, apiUrl: callUrl);
          if (desc.trim().isNotEmpty) {
            visionDescs.add('【第 ${i + 1} 张图片内容提取结果】\n$desc');
            logp('✅ 第 ${i + 1} 张图片内容提取成功');
          } else {
            visionDescs.add('【第 ${i + 1} 张图片内容提取结果为空】');
          }
        } catch (e) {
          logp('⚠️ 第 ${i + 1} 张图片提取失败: $e');
          visionDescs.add('【第 ${i + 1} 张图片内容提取失败】');
        }
      } else {
        logp('⚠️ 第 ${i + 1} 张图片读取失败: ${b64.error}');
        visionDescs.add('【第 ${i + 1} 张图片无法读取】');
      }
    }
    if (visionDescs.isNotEmpty) {
      userPrompt += '\n\n【图片内容的提取结果（视觉模型生成）】\n'
          '${visionDescs.join('\n\n')}';
      logp('✅ 所有图片内容提取完成，已合并到提示词');
    }
  }

  // ========== 豆包通道：媒体附件以原生多模态形式提交 ==========
  // 图片 → image_url、音频 → input_audio、视频 → video_url，
  // 全部原样交给豆包本人理解；同时开启深度思考（thinking）。
  var useTools = enableTools;
  // ★ 修复严重 Bug：这里原先在检测到「设备操作意图」时直接把 useTools 置为 true，
  //   等于在用户看不见的服务端绕过工具模式开关（UI 显示已关闭，实际照跑）。
  //   现在不再自动开启：开关关着就是关着，模型拿不到 tools 定义，
  //   即使它自己写出 function call，执行层（DsToolGate）也会直接拒绝。
  if (!useTools && dsIsDeviceIntent(content)) {
    logp('⛔ 检测到设备操作意图，但工具模式为 OFF，不自动启用');
  }
  Map<String, dynamic>? dbExtraBody;
  // ★ 深度思考开关 = 真正的上游 thinking 开关，不能只改前端 Lv.999。
  //   豆包/方舟：thinking enabled/disabled + reasoning_effort；
  //   DeepSeek：同样下发 thinking，官方接口不支持时由 API 层 400 回退自动摘除。
  //   关掉深度思考时必须显式 disabled，绝不允许模型按默认值继续思考。
  dbExtraBody =
      deepThink ? dbThinkingEnableParam(model) : dbThinkingDisableParam(model);
  if (dbExtraBody == null) {
    // 能力表未识别的模型：无论开或关都显式下发，交给上游 400 回退判定。
    // 关掉时必须显式 disabled，绝不允许模型按默认值继续思考。
    dbExtraBody = <String, dynamic>{
      'thinking': <String, dynamic>{'type': deepThink ? 'enabled' : 'disabled'},
    };
  }
  // ★ 思考长度旋钮：只在用户明确开启深度思考时下发。
  //   关闭时连 reasoning_effort 都不能留，否则部分上游会按 effort 重新思考。
  if (deepThink) {
    final effort = dbReasoningEffortParam(model, level: level, mode: 'on');
    if (effort != null) {
      dbExtraBody = <String, dynamic>{
        ...dbExtraBody,
        'reasoning_effort': effort,
      };
      logp('🧠 调整思考长度: reasoning_effort=$effort'
          '（推理级别 $level / ${dbThinkingProfileOf(model)}）');
    }
  }
  if (useDoubao) {
    logp('🧠 豆包思考开关: ${deepThink ? 'enabled' : 'disabled'} / model=$model');
  } else {
    logp(
        '🧠 DeepSeek 思考开关: ${deepThink ? 'enabled' : 'disabled'} / model=$model');
  }
  final dbMediaParts = <Map<String, dynamic>>[];
  // 视频统一由 doubao_video_ark 处理：≤45MB 直接作为 video_url 片段，
  // >45MB 用 ffmpeg 无损切片后逐段理解（2GB 也能看完）。
  // 切片 + 逐段理解可能持续几分钟到几十分钟，而本机 HttpServer 的
  // idleTimeout 是 120 秒：流式模式下若等到主函数末尾才建立 SSE，
  // 等待期间连接会被掐断。因此「流式 + 含视频」时把媒体准备挪到 SSE 建连之后
  // （SSE 自带 15 秒心跳负责保活）。
  final deferVideoPrepare =
      useDoubao && stream && !longTextMode && fileCtx.videoFileIds.isNotEmpty;
  if (useDoubao && fileCtx.hasMedia) {
    for (final id in fileCtx.imageFileIds) {
      final b64 = dsFileToBase64(id);
      if (b64.error == null && b64.b64.isNotEmpty) {
        dbMediaParts.add(dbImagePart(b64.mime, b64.b64));
      } else {
        logp('⚠️ 图片读取失败（不发送给豆包）: ${b64.error}');
      }
    }
    for (final id in fileCtx.audioFileIds) {
      final meta = getDsFileMeta(id);
      if (meta == null) continue;
      final absPath = '$DSFilesBlobDir/${meta.relPath}';
      if (!File(absPath).existsSync()) continue;
      final raw = dsReadPlainFileBytes(absPath);
      if (raw.length > 40 * 1024 * 1024) {
        await dsJSONErr(
            res, 400, dbLocalized(mediaLang, 'audioTooLarge', [meta.name]));
        return;
      }
      final prepared = await dbPrepareAudioForArk(raw, meta.name);
      dbMediaParts
          .add(dbAudioPart(prepared.format, base64Encode(prepared.bytes)));
      logp('🎧 将音频直接发送给豆包语音理解: ${meta.name} (${prepared.format})');
    }
    // 视频：不再 readAsBytesSync + base64（2GB 走那条路必然 OOM）。
    // 现在交给 doubao_video_ark：≤45MB 直接作为 video_url 片段，
    // >45MB 用 ffmpeg 无损切片后逐段理解，结论并入 userPrompt。
    if (!deferVideoPrepare) {
      try {
        final vid = await dbVideoContentForChat(
          videoFileIds: fileCtx.videoFileIds,
          model: model,
          apiKey: callKey,
        );
        dbMediaParts.addAll(vid.parts);
        if (vid.text.isNotEmpty) {
          // 大视频：分段理解结果以文本形式并入用户提示词
          userPrompt = '$userPrompt\n\n${vid.text}';
          logp('🧾 把视频分段理解结果合并到提示词（${runeLen(vid.text)} 字）');
        }
      } on DbVideoArkException catch (e) {
        logp('❌ 视频准备失败: ${e.message}');
        await dsJSONErr(res, 400, e.message);
        return;
      }
    } else {
      logp('🎬 ${fileCtx.videoFileIds.length} 个视频将在 SSE 连接后 '
          '分割并准备');
    }
    // 看过图片 / 音频 / 视频后是否先思考，完全服从用户的深度思考开关。
    // 旧实现无条件 enabled，导致用户明明关掉深度思考，一发图片又开始思考。
    dbExtraBody = deepThink
        ? dbThinkingEnableParam(model)
        : dbThinkingDisableParam(model);
    dbExtraBody ??= <String, dynamic>{
      'thinking': <String, dynamic>{'type': deepThink ? 'enabled' : 'disabled'},
    };
    logp('🧠 媒体输入后的思考状态: ${deepThink ? 'enabled' : 'disabled'}');
    // 工具模式的请求形式无法与 thinking 并用，因此
    // 仅在附带媒体时自动关闭（不默默忽略）。
    if (useTools) {
      useTools = false;
      // 工具模式曾把 temperature 压到 0，这里恢复默认采样温度；
      // Lv.900–999 仍保持全局零温度。
      temperature = level >= 900 ? 0.0 : 1.0;
      logp('ℹ️ 因附带媒体，已自动关闭工具模式（优先思考）');
    }
  }
  // ★ 最终决定联网方式：工具模式与 web_search_options 互斥。
  //   工具模式开着时不附加 web_search_options（避免方舟拒绝），
  //   改由模型通过 web_search / fetch 工具联网；工具模式关闭时才用原生搜索。
  if (dbNativeSearch && useTools) {
    dbNativeSearch = false;
    logp('🌐 工具模式 + 联网搜索并存：通过 web_search/fetch 工具联网（不附加 web_search_options）');
  }
  if (dbNativeSearch) {
    dbExtraBody = <String, dynamic>{
      ...dbExtraBody,
      'web_search_options': dbWebSearchOptions(searchType: 'mandatory'),
    };
    logp('🌐 启用豆包原生搜索（web_search_options=mandatory，无需工具模式，每月 2 万次免费额度）');
  }

  // DeepSeek 通道不具备音视频理解能力，如实告知而不是假装已读
  if (!useDoubao &&
      (fileCtx.audioFileIds.isNotEmpty || fileCtx.videoFileIds.isNotEmpty)) {
    final names = <String>[
      ...fileCtx.audioFileIds.map((id) => getDsFileMeta(id)?.name ?? id),
      ...fileCtx.videoFileIds.map((id) => getDsFileMeta(id)?.name ?? id),
    ];
    logp('⚠️ DeepSeek 通道不支持音频、视频理解: ${names.join('、')}');
    userPrompt +=
        '\n\n' + dbLocalized(mediaLang, 'noMediaNote', [names.join('、')]);
  }

  // 跨会话引用
  final refs = resolveCrossSessionRefs(userPrompt, sessionID);
  if (refs.injected) userPrompt = refs.rewritten;

  // ★ 维度隔离：只把"同一维度"的历史传给模型。
  //   豆包(dim=db) 与 DeepSeek(dim=ds) 完全不看彼此的消息。
  // ★ chatDim 已在本函数开头（useDoubao 之后）确定
  logp('🧭 送信维度=$chatDim (model=$model)');
  var history = getDsMessages(sessionID, dim: chatDim);
  history = pickHistoryWindow(history);

  final apiMessages = <Map<String, dynamic>>[];
  // i18n：注入与 UI 语言一致的语言固定提示词
  final uiLang = dsRequestLang(req, body);
  final sysParts = <String>[];
  sysParts.add(dsLangSystemPrompt(uiLang));
  sysParts.add(knowledgeSystemPromptForChat(uiLang));
  final autoKnowledge = knowledgeContextForQuery(content);
  if (autoKnowledge.isNotEmpty) sysParts.add(autoKnowledge);
  if (deepThink) {
    sysParts.add('你能进行深入的多步推理。请充分展示思考过程。');
  }
  if (longTextMode) {
    sysParts.add('你是擅长长文写作的专业作家。不要加任何前言或总结，直接输出完成的长文。');
  }
  // ★ 显式插件按钮（墨迹天气 / 头条图文）：强制模型真的调用插件 + Markdown 结构化输出。
  //   工具模式在这条请求里恒为 OFF，因此这里只做「信源使用」与「输出格式」约束。
  if (explicitPlugin == 'moji') {
    sysParts.add('【插件强制指令 · 墨迹天气】本次回答必须基于「墨迹天气」联网内容插件返回的真实数据。'
        '禁止凭记忆编造天气。请给出：当前实况（天气现象、气温、体感、湿度、风力风向）、'
        '未来 24 小时趋势、以及出行/穿衣建议。信息不足时明确说明，不要虚构。');
  } else if (explicitPlugin == 'toutiao') {
    sysParts.add('【插件强制指令 · 头条图文】本次回答必须基于「头条图文」联网内容插件返回的真实图文内容，'
        '禁止编造新闻事实。请严格按 Markdown 结构输出：# 标题、## 要点速览（无序列表）、'
        '## 正文综述（分段，可用 **加粗** 强调关键信息）、## 信息来源（列表附链接）。'
        '代码 / 命令 / 数据片段必须放进 ``` 围栏代码块，长内容可用 '
        '<details><summary>展开查看</summary>…</details> 折叠，绝不直接裸露 Markdown 标记。');
  }

  sysParts.addAll(injected);
  final cp = renderActiveCosplayPersona();
  if (cp.isNotEmpty) sysParts.add(cp);
  if (sysParts.isNotEmpty) {
    apiMessages.add({'role': 'system', 'content': sysParts.join('\n')});
  }
  for (final m in history) {
    if (m.role == 'user' || m.role == 'assistant' || m.role == 'system') {
      apiMessages.add({'role': m.role, 'content': m.content});
    }
  }
  if (refs.injected) {
    for (final snap in refs.snapshots) {
      apiMessages.add({'role': 'user', 'content': snap});
    }
  }
  if (deferVideoPrepare) {
    // 含视频的流式请求：本条 user message 由 handleDsChatSendStream 在
    // SSE 建连、且视频 file_id 准备好之后追加（避免 120 秒空闲断连）。
    logp('⏸️ 带视频的请求: 把 user 消息的追加委托给 SSE 侧');
  } else if (dbMediaParts.isNotEmpty) {
    apiMessages.add({
      'role': 'user',
      'content': <Map<String, dynamic>>[
        {'type': 'text', 'text': userPrompt},
        ...dbMediaParts,
      ],
    });
  } else {
    apiMessages.add({'role': 'user', 'content': userPrompt});
  }

  // ============ 流式分支 ============
  if (stream && !longTextMode) {
    await handleDsChatSendStream(req, callKey, model, apiMessages, maxTokens,
        temperature, rounds, sessionID, content, fileIDs, useTools,
        webSearch: effectiveWebSearch,
        route: route,
        apiUrl: callUrl,
        extraBody: dbExtraBody,
        lang: uiLang,
        dim: chatDim,
        forcedSources: forcedSources,
        userPrompt: deferVideoPrepare ? userPrompt : '',
        mediaParts: dbMediaParts,
        pendingVideoIds:
            deferVideoPrepare ? fileCtx.videoFileIds : const <String>[]);
    return;
  }

  // ============ 工具模式（非流式） ============
  if (useTools) {
    logp('🔧 启用工具模式，开始多轮 function calling（最多 $DS_TOOL_MAX_ITERATIONS 轮）');
    final usageAcc = DsUsageAcc();
    final agentMsgs = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': dbToolSystemPromptFor(model, callUrl, uiLang)
      },
      ...apiMessages,
    ];
    ToolStreamOutcome outcome;
    try {
      outcome = await callDsWithTools(callKey, model, agentMsgs, maxTokens,
          temperature, dbToolMaxIterFor(model, callUrl, rounds), usageAcc,
          apiUrl: callUrl,
          extraBody: dbExtraBody,
          allowSearchTools: effectiveWebSearch);
    } catch (e) {
      await dsJSONErr(res, 500, '工具调用失败: $e');
      return;
    }

    final now = DateTime.now();
    final savedContent = content.isEmpty ? '[工具模式]' : content;
    final userMsg = DsMessage(
      id: 'dsm_${fmtStamp14(now)}_${randomHex(6)}',
      sessionId: sessionID,
      role: 'user',
      content: savedContent,
      createdAt: rfc3339(now),
      attachments: fileIDs.join(','),
    );
    userMsg.dim = dsDimOf(model, chatDim);
    appendDsMessage(userMsg);

    var fullReasoning = outcome.reasoning;
    if (outcome.toolLogs.isNotEmpty) {
      fullReasoning =
          '【工具调用记录】\n${outcome.toolLogs.join('\n\n───────────────\n\n')}';
      if (outcome.reasoning.isNotEmpty) {
        fullReasoning += '\n\n【模型的思考过程】\n${outcome.reasoning}';
      }
    }

    final aiMsg = DsMessage(
      id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
      sessionId: sessionID,
      role: 'assistant',
      content: outcome.content,
      createdAt: rfc3339(DateTime.now()),
      reasoning: fullReasoning,
      // 豆包额度无法从方舟精确取得，故不落库 usage，避免误导
      usage: usageAcc.snapshot(),
    );
    aiMsg.dim = dsDimOf(model, chatDim);
    appendDsMessage(aiMsg);

    final sess = getDsSession(sessionID);
    var title = '新对话';
    if (sess != null) {
      title = sess.title;
      if (title.isEmpty || title == '新对话') {
        final runes = content.runes.toList();
        if (runes.length > 18) {
          title = '${String.fromCharCodes(runes.sublist(0, 18))}…';
        } else if (runes.isNotEmpty) {
          title = content;
        }
      }
    }
    updateDsSession(sessionID, title, rfc3339(DateTime.now()));

    await dsJSONOk(res, 200, {
      'success': true,
      'userMessage': userMsg.toJson(),
      'aiMessage': aiMsg.toJson(),
      'title': title,
      'charCount': runeLen(outcome.content),
      'model': model,
      'modelRoute': route.toJson(),
      'toolLogs': outcome.toolLogs,
      'toolRounds': outcome.toolLogs.length,
      'usage': aiMsg.usage?.toJson(),
    });
    return;
  }

  // ============ 非流式兜底 ============
  // 豆包联网内容插件（抖音百科等）在非流式路径同样生效：
  // Responses API 本身仍是流式，这里把增量累积成完整文本后返回。
  final usageAcc = DsUsageAcc();
  String reply;
  String reasoning;
  final wikiSrcFallback =
      useDoubao ? dbEffectiveSources(forcedSources) : const <String>[];
  final wikiOkFallback = effectiveWebSearch &&
      wikiSrcFallback.isNotEmpty &&
      fileCtx.videoFileIds.isEmpty &&
      dbWikiMediaSupported(dbMediaParts);
  try {
    if (wikiOkFallback) {
      final rb = StringBuffer();
      final cb = StringBuffer();
      await callDbWikiResponsesStream(
        callKey,
        model,
        apiMessages,
        maxTokens,
        wikiSrcFallback,
        (s) => rb.write(s),
        (s) => cb.write(s),
        usageAcc: usageAcc,
        baseUrl: dbBaseUrl(null),
        mediaParts: dbMediaParts,
      );
      reply = cb.toString();
      reasoning = rb.toString();
    } else if (dbVideoMessagesNeedResponses(model, apiMessages)) {
      final rb = StringBuffer();
      final cb = StringBuffer();
      await callDbVideoResponsesStream(
        callKey,
        model,
        apiMessages,
        maxTokens,
        (s) => rb.write(s),
        (s) => cb.write(s),
        usageAcc,
      );
      reply = cb.toString();
      reasoning = rb.toString();
    } else {
      final r = await callDsMultiRound(callKey, model, apiMessages, maxTokens,
          temperature, rounds, null, usageAcc,
          apiUrl: callUrl, extraBody: dbExtraBody);
      reply = r.content;
      reasoning = r.reasoning;
    }
  } catch (e) {
    await dsJSONErr(res, 500, 'API 调用失败: $e');
    return;
  }

  final now = DateTime.now();
  final savedContent = content.isEmpty ? '[已上传文件]' : content;
  final userMsg = DsMessage(
    id: 'dsm_${fmtStamp14(now)}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'user',
    content: savedContent,
    createdAt: rfc3339(now),
    attachments: fileIDs.join(','),
  );
  userMsg.dim = dsDimOf(model, chatDim);
  appendDsMessage(userMsg);

  final aiMsg = DsMessage(
    id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    sessionId: sessionID,
    role: 'assistant',
    content: reply,
    createdAt: rfc3339(DateTime.now()),
    reasoning: reasoning,
    usage: usageAcc.snapshot(),
  );
  aiMsg.dim = dsDimOf(model, chatDim);
  appendDsMessage(aiMsg);

  final sess = getDsSession(sessionID);
  var title = '新对话';
  if (sess != null) {
    title = sess.title;
    if (title.isEmpty || title == '新对话') {
      final runes = content.runes.toList();
      if (runes.isEmpty) {
        title = '[文件对话]';
      } else if (runes.length > 18) {
        title = '${String.fromCharCodes(runes.sublist(0, 18))}…';
      } else {
        title = content;
      }
    }
  }
  updateDsSession(sessionID, title, rfc3339(DateTime.now()));

  await dsJSONOk(res, 200, {
    'success': true,
    'userMessage': userMsg.toJson(),
    'aiMessage': aiMsg.toJson(),
    'title': title,
    'level': level,
    'rounds': rounds,
    'maxTokens': maxTokens,
    'charCount': runeLen(reply),
    'model': model,
    'modelRoute': route.toJson(),
    'usage': aiMsg.usage?.toJson(),
  });
}
