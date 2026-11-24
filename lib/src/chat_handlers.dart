// ============================================================
// chat_handlers.dart —— 聊天基础接口
//   config / sessions / messages / reasoning / test / image / tts / stt
//   abort-save / continue
// 100% 对齐 Go 版 deepseek-chat.go 对应 handler
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'db_limits.dart';
import 'deepseek_api.dart';
import 'doubao.dart';
import 'ds_crypto.dart';
import 'ds_usage.dart';
import 'files.dart';
import 'globals.dart';
import 'knowledge.dart';
import 'httpsrv.dart';
import 'relay.dart';
import 'sessions.dart';
import 'tools.dart' show runProcess;
import 'tts_edge.dart';

// ------------------------------------------------------------
// /api/ds-chat/config
// ------------------------------------------------------------
Future<void> handleDsChatConfig(HttpRequest req) async {
  final res = req.response;
  switch (req.method) {
    case 'GET':
      final cfg = getDsConfig();
      var masked = '';
      if (cfg.apiKey.length > 8) {
        masked =
            '${cfg.apiKey.substring(0, 4)}••••${cfg.apiKey.substring(cfg.apiKey.length - 4)}';
      } else if (cfg.apiKey.isNotEmpty) {
        masked = '••••••••';
      }
      var imgMasked = '';
      if (cfg.imgKey.length > 8) {
        imgMasked =
            '${cfg.imgKey.substring(0, 4)}••••${cfg.imgKey.substring(cfg.imgKey.length - 4)}';
      } else if (cfg.imgKey.isNotEmpty) {
        imgMasked = '••••••••';
      }
      await dsJSONOk(res, 200, {
        'hasKey': cfg.apiKey.isNotEmpty,
        'maskedKey': masked,
        'model': cfg.model,
        'hasImgKey': cfg.imgKey.isNotEmpty,
        'maskedImgKey': imgMasked,
        'maxOutput': dbCurrentOutputLimit(),
        'maxOutputLabel': dbTokensLabel(dbCurrentOutputLimit()),
        'contextWindow': DB_FORCED_CTX_TOKENS,
        'outputOptions': DB_ALLOWED_OUTPUT_TOKENS,
      });
      return;

    case 'POST':
      Map<String, dynamic> body;
      try {
        body = await readJsonBody(req);
      } catch (_) {
        await dsJSONErr(res, 400, '无效的请求体');
        return;
      }
      final old = getDsConfig();
      final nk = trimOr(mStr(body, 'apiKey'), old.apiKey);
      final nm = trimOr(mStr(body, 'model'), old.model);
      final nik = trimOr(mStr(body, 'imgKey'), old.imgKey);
      if (!saveDsConfig(nk, nm, nik)) {
        await dsJSONErr(res, 500, '保存失败');
        return;
      }
      await dsJSONOk(res, 200, {'success': true});
      return;

    default:
      await dsJSONErr(res, 405, 'Method not allowed');
  }
}

// ------------------------------------------------------------
// /api/ds-chat/output-limit —— 全模型共享的最大输出档位
// ------------------------------------------------------------
Future<void> handleDsChatOutputLimit(HttpRequest req) async {
  final res = req.response;
  if (req.method == 'GET') {
    await dsJSONOk(res, 200, dbOutputLimitInfo());
    return;
  }
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req, limit: 4096);
  } catch (_) {
    await dsJSONErr(res, 400, '無効なリクエスト本文です');
    return;
  }
  final raw = body.containsKey('tokens') ? body['tokens'] : body['maxOutput'];
  final tokens = dbParseOutputLimit(raw);
  if (tokens == null) {
    await dsJSONErr(
        res, 400, '最大出力は 64K / 128K / 256K / 384K から選択してください');
    return;
  }
  if (!saveDbOutputLimit(tokens)) {
    await dsJSONErr(res, 500, '最大出力レベルの保存に失敗しました');
    return;
  }
  await dsJSONOk(res, 200, <String, dynamic>{
    'success': true,
    ...dbOutputLimitInfo(),
  });
}

// ------------------------------------------------------------
// /api/ds-chat/context —— 当前会话的实时上下文统计
// ------------------------------------------------------------
int _dsEstimateTextTokens(String text) {
  if (text.isEmpty) return 0;
  var cjk = 0;
  var other = 0;
  for (final r in text.runes) {
    final isCjk = (r >= 0x3000 && r <= 0x30ff) ||
        (r >= 0x3400 && r <= 0x4dbf) ||
        (r >= 0x4e00 && r <= 0x9fff) ||
        (r >= 0xac00 && r <= 0xd7af) ||
        (r >= 0xf900 && r <= 0xfaff);
    if (isCjk) {
      cjk++;
    } else {
      other++;
    }
  }
  return cjk + ((other + 3) ~/ 4);
}

/// 上下文快照缓存：只要「消息条数 / 末条 id / 末条内容长度 / usage」没变，
/// 就直接返回上一次统计结果，避免 1 秒轮询反复遍历全部正文。
final Map<String, Map<String, dynamic>> _dsCtxSnapshotCache = <String, Map<String, dynamic>>{};

Future<void> handleDsChatContext(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'GET') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  final sessionID = qp(req, 'sessionId');
  if (sessionID.trim().isEmpty) {
    await dsJSONOk(res, 200, <String, dynamic>{
      'sessionId': '',
      'messages': 0,
      'characters': 0,
      'estimatedTokens': 0,
      'reportedTokens': 0,
      'billedTokens': 0,
      ...dbOutputLimitInfo(),
    });
    return;
  }
  final dim = dsDimFromReq(req);
  final messages = getDsMessages(sessionID, dim: dim);
  final sig = '${messages.length}|'
      '${messages.isEmpty ? '' : messages.last.id}|'
      '${messages.isEmpty ? 0 : messages.last.content.length}|'
      '${messages.isEmpty ? 0 : (messages.last.usage?.totalTokens ?? 0)}';
  final cacheKey = '$dim|$sessionID';
  final cached = _dsCtxSnapshotCache[cacheKey];
  if (cached != null && cached['sig'] == sig) {
    final hit = Map<String, dynamic>.from(cached['data'] as Map);
    hit.addAll(dbOutputLimitInfo());
    await dsJSONOk(res, 200, hit);
    return;
  }
  var characters = 0;
  var estimated = 0;
  var billed = 0;
  var latestPrompt = 0;
  var latestCompletion = 0;
  for (final m in messages) {
    characters += m.content.runes.length;
    // 每条消息预留少量角色与分隔开销；该值明确作为估算，而非计费数据。
    estimated += 4 + _dsEstimateTextTokens(m.content);
    final usage = m.usage;
    if (usage != null) {
      billed += usage.totalTokens;
      if (usage.promptTokens > 0) {
        latestPrompt = usage.promptTokens;
        latestCompletion = usage.completionTokens;
      }
    }
  }
  if (estimated > DB_FORCED_CTX_TOKENS) estimated = DB_FORCED_CTX_TOKENS;
  final payload = <String, dynamic>{
    'sessionId': sessionID,
    'dimension': dim,
    'messages': messages.length,
    'characters': characters,
    'estimatedTokens': estimated,
    'reportedTokens': latestPrompt + latestCompletion,
    'promptTokens': latestPrompt,
    'completionTokens': latestCompletion,
    'billedTokens': billed,
    'updatedAt': rfc3339(DateTime.now()),
    ...dbOutputLimitInfo(),
  };
  _dsCtxSnapshotCache[cacheKey] = <String, dynamic>{'sig': sig, 'data': payload};
  // 只保留最近 64 个会话快照，防止长期运行后内存膨胀。
  if (_dsCtxSnapshotCache.length > 64) {
    final firstKey = _dsCtxSnapshotCache.keys.first;
    _dsCtxSnapshotCache.remove(firstKey);
  }
  await dsJSONOk(res, 200, payload);
}

// ------------------------------------------------------------
// /api/ds-chat/sessions
// ------------------------------------------------------------
Future<void> handleDsChatSessions(HttpRequest req) async {
  final res = req.response;
  switch (req.method) {
    case 'GET':
      final sessions = getAllDsSessions();
      final etag = '"ds'
          '${sessions.length}-'
          '${sessions.isEmpty ? '0' : sessions.first.updatedAt}"';
      res.headers.set('etag', etag);
      res.headers.set('cache-control', 'no-cache');
      final inm = req.headers.value(HttpHeaders.ifNoneMatchHeader);
      if (inm != null && inm == etag) {
        res.statusCode = 304;
        await res.close();
        return;
      }
      await dsJSONOk(res, 200, {
        'sessions': sessions.map((s) => s.toJson()).toList(),
      });
      return;

    case 'POST':
      Map<String, dynamic> body;
      try {
        body = await readJsonBody(req);
      } catch (_) {
        body = <String, dynamic>{};
      }
      var id = mStr(body, 'id');
      final title = trimOr(mStr(body, 'title'), '新对话');
      if (id.trim().isNotEmpty) {
        final sess = getDsSession(id);
        if (sess == null) {
          await dsJSONErr(res, 404, '会话不存在');
          return;
        }
        if (!updateDsSession(id, title, rfc3339(DateTime.now()))) {
          await dsJSONErr(res, 500, '重命名失败');
          return;
        }
        await dsJSONOk(res, 200, {'success': true, 'id': id, 'title': title});
        return;
      }
      final now = DateTime.now();
      id = 'dsc_${fmtStamp14(now)}_${randomHex(6)}';
      final sess = DsSession(
        id: id,
        title: title,
        createdAt: rfc3339(now),
        updatedAt: rfc3339(now),
      );
      if (!saveDsSession(sess)) {
        await dsJSONErr(res, 500, '创建失败');
        return;
      }
      await dsJSONOk(res, 200, {'success': true, 'session': sess.toJson()});
      return;

    case 'DELETE':
      final id = qp(req, 'id');
      if (id.isEmpty) {
        await dsJSONErr(res, 400, '缺少id');
        return;
      }
      deleteDsSession(id);
      await dsJSONOk(res, 200, {'success': true});
      return;

    default:
      await dsJSONErr(res, 405, 'Method not allowed');
  }
}

Future<void> handleDsChatSessionsBatchDelete(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await dsJSONErr(res, 400, '无效的请求体');
    return;
  }
  final ids = asList(body['ids']).map((e) => '$e').toList();
  final all = mBool(body, 'all');

  if (all) {
    final allAttachments = <String>{};
    for (final f in Directory(dsSessionsDir).listSync()) {
      if (f is! File || !f.path.endsWith('.sts')) continue;
      allAttachments.addAll(collectSessionAttachments(f.path));
    }
    for (final f in Directory(dsSessionsDir).listSync()) {
      if (f is File && f.path.endsWith('.sts')) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    for (final fid in allAttachments) {
      deleteDsFileMeta(fid);
    }
    cleanupOrphanFiles();
    await dsJSONOk(res, 200, {'success': true, 'deleted': -1});
    return;
  }

  if (ids.isEmpty) {
    await dsJSONErr(res, 400, '缺少 ids');
    return;
  }

  final allAttachments = <String>{};
  for (final id in ids) {
    if (id.isEmpty) continue;
    allAttachments.addAll(collectSessionAttachments(dsSessionPath(id)));
  }
  var count = 0;
  for (final id in ids) {
    if (id.isEmpty) continue;
    if (deleteDsSessionRaw(id)) count++;
  }
  final stillUsed = collectAttachmentsInUse();
  for (final fid in allAttachments) {
    if (!stillUsed.contains(fid)) deleteDsFileMeta(fid);
  }
  cleanupOrphanFiles();
  await dsJSONOk(res, 200, {'success': true, 'deleted': count});
}

/// ★ 从请求中解析「维度」。
///   优先 dim 参数；否则用 model 参数判断（豆包目录 -> db，其余 -> ds）。
///   都不传时回退 DS_DIM_DS，与历史数据的语义保持一致。
String dsDimFromReq(HttpRequest req, [String bodyModel = '']) {
  final d = qp(req, 'dim').trim();
  if (d == DS_DIM_DB || d == DS_DIM_DS || d == DS_DIM_ST) return d;
  var m = bodyModel.trim();
  if (m.isEmpty) m = qp(req, 'model').trim();
  if (m.isEmpty) return DS_DIM_DS;
  return dbIsChatModel(m) ? DS_DIM_DB : DS_DIM_DS;
}

/// 生成「推理已截断」的消息副本：绝不修改缓存中的原始消息对象，
/// 否则后续把历史发给模型时会拿到被截断的 reasoning。
DsMessage _msgWithReasoningPreview(DsMessage m, String sessionID) {
  final r = truncateReasoning(m.reasoning, DS_REASONING_PREVIEW);
  return DsMessage(
    id: m.id,
    sessionId: sessionID,
    role: m.role,
    content: m.content,
    createdAt: m.createdAt,
    attachments: m.attachments,
    reasoning: r.$1,
    // ★ 解析层若已按预览上限截断，这里必须一并保留标记，
    //   否则前端会误判「思考链已完整」而不给展开入口。
    reasoningTruncated: r.$2 || m.reasoningTruncated,
    usage: m.usage,
    dim: m.dim,
  );
}

// ------------------------------------------------------------
// /api/ds-chat/messages（尾部优先 + beforeId 分页）
// ------------------------------------------------------------
Future<void> handleDsChatMessages(HttpRequest req) async {
  final res = req.response;
  final sessionID = qp(req, 'sessionId');
  if (sessionID.isEmpty) {
    await dsJSONErr(res, 400, '缺少 sessionId');
    return;
  }
  var limit = DS_MSG_PAGE_SIZE;
  final limitStr = qp(req, 'limit');
  if (limitStr.isNotEmpty) {
    final n = int.tryParse(limitStr);
    if (n != null && n > 0 && n <= 200) limit = n;
  }
  final beforeID = qp(req, 'beforeId');
  final path = dsSessionPath(sessionID);
  // ★ 维度：同一个会话窗口内，豆包与 DeepSeek 的消息流互相隔离
  final dim = dsDimFromReq(req);

  if (beforeID.isEmpty) {
    final tail = readDsSessionTailMsgs(path, limit, dim: dim);
    final msgs = tail.messages
        .map((m) => _msgWithReasoningPreview(m, sessionID))
        .toList();
    await dsJSONOk(res, 200, {
      'messages': msgs.map((m) => m.toJson()).toList(),
      'hasMore': tail.hasMore,
      'sessionId': sessionID,
    });
    return;
  }

  final all = getDsMessages(sessionID, dim: dim);
  var idx = -1;
  for (var i = 0; i < all.length; i++) {
    if (all[i].id == beforeID) {
      idx = i;
      break;
    }
  }
  var hasMore = false;
  var page = <DsMessage>[];
  if (idx > 0) {
    var start = 0;
    if (idx > limit) {
      start = idx - limit;
      hasMore = true;
    }
    page = all.sublist(start, idx);
  }
  final pageOut = page
      .map((m) => _msgWithReasoningPreview(m, sessionID))
      .toList();
  await dsJSONOk(res, 200, {
    'messages': pageOut.map((m) => m.toJson()).toList(),
    'hasMore': hasMore,
    'sessionId': sessionID,
  });
}

Future<void> handleDsChatReasoning(HttpRequest req) async {
  final res = req.response;
  final sessionID = qp(req, 'sessionId');
  final id = qp(req, 'id');
  if (sessionID.isEmpty || id.isEmpty) {
    await dsJSONErr(res, 400, '缺少 sessionId 或 id');
    return;
  }
  // ★ 维度：只读当前维度的消息，防止读到另一维度的思考内容
  final dim = dsDimFromReq(req);
  for (final m in getDsMessages(sessionID, dim: dim)) {
    if (m.id == id) {
      await dsJSONOk(res, 200, {'reasoning': m.reasoning});
      return;
    }
  }
  await dsJSONOk(res, 200, {'reasoning': ''});
}

// ------------------------------------------------------------
// /api/ds-chat/test
// ------------------------------------------------------------
Future<void> handleDsChatTest(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    body = <String, dynamic>{};
  }
  var apiKey = mStr(body, 'apiKey').trim();
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
  final relayCfg = getRelayConfig();
  final useRelay = isRelayModel(model);
  var callUrl = DS_API_URL;
  if (apiKey.isEmpty) {
    if (useRelay) {
      apiKey = relayCfg.apiKey;
      callUrl = relayChatEndpoint();
    } else {
      apiKey = cfg.apiKey;
    }
  }
  if (apiKey.isEmpty) {
    await dsJSONErr(res, 400, '缺少 API Key');
    return;
  }
  try {
    final r = await callDsChatAPI(apiKey, model, [
      {'role': 'user', 'content': '你好'}
    ], 8192, 1.0, null, apiUrl: callUrl);
    await dsJSONOk(
        res, 200, {'success': true, 'reply': r.content, 'model': model});
  } catch (e) {
    await dsJSONErr(res, 500, '$e');
  }
}

// ------------------------------------------------------------
// /api/ds-chat/generate-image（pollinations）
// ------------------------------------------------------------
String urlEncodeComponent(String s) {
  final sb = StringBuffer();
  for (final b in utf8.encode(s)) {
    final c = String.fromCharCode(b);
    if (RegExp(r'[A-Za-z0-9\-_.~]').hasMatch(c)) {
      sb.write(c);
    } else {
      sb.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return sb.toString();
}

Future<void> handleDsGenerateImage(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await dsJSONErr(res, 400, '无效的请求体');
    return;
  }
  final prompt = mStr(body, 'prompt').trim();
  if (prompt.isEmpty) {
    await dsJSONErr(res, 400, '提示词为必填项');
    return;
  }
  var width = intArgDefault(body, 'width', 1024);
  var height = intArgDefault(body, 'height', 1024);
  if (width <= 0) width = 1024;
  if (height <= 0) height = 1024;

  final seed = DateTime.now().microsecondsSinceEpoch % 999999;
  final imgURL = 'https://image.pollinations.ai/prompt/${urlEncodeComponent(prompt)}'
      '?width=$width&height=$height&nologo=true&seed=$seed';

  List<int> imgData;
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    final r = await client.getUrl(Uri.parse(imgURL));
    final resp = await r.close();
    if (resp.statusCode != 200) {
      await dsJSONErr(res, 500, '生成服务返回了 ${resp.statusCode}');
      return;
    }
    imgData = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
  } catch (e) {
    await dsJSONErr(res, 500, '图片生成失败: $e');
    return;
  }

  final filename = 'gen_${fmtStamp14(DateTime.now())}_${randomHex(6)}.jpg';
  final relPath = 'generated/$filename';
  final absPath = '$DSFilesBlobDir/$relPath';
  ensureDir('$DSFilesBlobDir/generated');
  try {
    File(absPath).writeAsBytesSync(imgData);
    if (currentUserId.isNotEmpty && !encryptDsFileAtRest(absPath)) {
      await dsJSONErr(res, 500, '图片加密保存失败');
      return;
    }
  } catch (_) {
    await dsJSONErr(res, 500, '保存失败');
    return;
  }

  final meta = DsFileMeta(
    id: 'f_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
    name: filename,
    size: imgData.length,
    mimeType: 'image/jpeg',
    category: 'image',
    createdAt: rfc3339(DateTime.now()),
    relPath: relPath,
    source: 'ai_generated',
    prompt: prompt,
  );
  saveDsFileMeta(meta);

  await dsJSONOk(res, 200, {
    'success': true,
    'fileId': meta.id,
    'filename': filename,
    'url': '/api/ds-files/download?id=${meta.id}',
  });
}

// ------------------------------------------------------------
// /api/ds-chat/tts（Edge TTS 流式 mp3）
// ------------------------------------------------------------
Future<void> handleDsChatTTS(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await dsJSONErr(res, 400, '无效的请求体');
    return;
  }
  final text = mStr(body, 'text').trim();
  if (text.isEmpty) {
    await dsJSONErr(res, 400, '文本为必填项');
    return;
  }
  var voice = mStr(body, 'voice');
  // 为了能接受 'fr' / 'fr-FR' / 'ru-RU' 等，归一化为前 2 个字符
  final ttsLangRaw = mStr(body, 'lang').toLowerCase();
  final ttsLang = ttsLangRaw.length >= 2 ? ttsLangRaw.substring(0, 2) : ttsLangRaw;
  if (voice.isEmpty) {
    const defVoice = <String, String>{
      'ja': 'ja-JP-NanamiNeural',
      'en': 'en-US-AriaNeural',
      'fr': 'fr-FR-DeniseNeural',
      'ru': 'ru-RU-SvetlanaNeural',
      'ko': 'ko-KR-SunHiNeural',
      'zh': 'zh-CN-XiaoxiaoNeural',
    };
    voice = defVoice[ttsLang] ?? defVoice['zh']!;
  }
  // prosody 白名单校验（防止 SSML 注入 / 非法值）
  String safeProsody(String raw, String unit, String def) {
    final v = raw.trim();
    if (!v.endsWith(unit)) return def;
    final numPart = v.substring(0, v.length - unit.length);
    if (!RegExp(r'^[+-]\d{1,3}$').hasMatch(numPart)) return def;
    return v;
  }

  final pitch = safeProsody(mStr(body, 'pitch'), 'Hz', '+0Hz');
  final rate = safeProsody(mStr(body, 'rate'), '%', '+0%');

  final chunks = splitTextForTTS(text, DS_TTS_CHUNK_RUNES, DS_TTS_CHUNK_HARD_MAX);
  if (chunks.isEmpty) {
    await dsJSONErr(res, 400, '文本为空');
    return;
  }
  final cleaned = <String>[];
  for (final c in chunks) {
    final cc = cleanTTSText(c, ttsLang);
    if (cc.trim().isNotEmpty) cleaned.add(cc);
  }
  if (cleaned.isEmpty) {
    await dsJSONErr(res, 400, '文本为空（清理后）');
    return;
  }

  final totalRunes = runeLen(text);
  logp('🔊 TTS 请求: $totalRunes 字、${cleaned.length} 块、音色=$voice pitch=$pitch rate=$rate');

  res.statusCode = 200;
  res.headers.contentType = ContentType('audio', 'mpeg');
  res.headers.set('Cache-Control', 'no-cache');
  res.bufferOutput = false;

  var okChunks = 0;
  for (var i = 0; i < cleaned.length; i++) {
    logp('🎙️ TTS 第 ${i + 1}/${cleaned.length} 块（${runeLen(cleaned[i])} 字）');
    final ok = await synthesizeEdgeTts(cleaned[i], voice, (audio) async {
      try {
        res.add(audio);
        await res.flush();
      } catch (_) {}
    }, pitch: pitch, rate: rate);
    if (ok) {
      okChunks++;
    } else {
      logp('❌ TTS 第 ${i + 1} 块合成失败');
    }
  }
  logp('✅ TTS 完成: $okChunks/${cleaned.length} 块成功');
  try {
    await res.close();
  } catch (_) {}
}

// ------------------------------------------------------------
// /api/ds-chat/stt（本地 ffmpeg + whisper.cpp）
// ------------------------------------------------------------
String cleanWhisperText(String s) {
  var out = s.replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*\)|（[^）]*）'), '');
  final clean = <String>[];
  for (var ln in out.split('\n')) {
    ln = ln.trim();
    if (ln.isEmpty) continue;
    if (ln.startsWith('output_txt:') ||
        ln.startsWith('output_') ||
        ln.startsWith('whisper_')) {
      continue;
    }
    clean.add(ln);
  }
  return clean.join(' ').trim();
}

Future<void> handleDsChatSTT(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  List<int> audioData;
  try {
    audioData = await readBodyBytes(req, limit: 20 * 1024 * 1024);
  } catch (_) {
    await dsJSONErr(res, 400, '音频读取失败');
    return;
  }
  // multipart 包装：提取二进制主体（保持 Go 的宽松行为）
  if (audioData.length < 500) {
    await dsJSONErr(res, 400, '音频过短');
    return;
  }

  final tmpDir = Directory.systemTemp.path;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final inFile = '$tmpDir/stt_in_$stamp.bin';
  final wavFile = '$tmpDir/stt_$stamp.wav';
  try {
    File(inFile).writeAsBytesSync(audioData);
    final ff = await runProcess(
        'ffmpeg', ['-y', '-loglevel', 'error', '-i', inFile, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', wavFile],
        timeout: const Duration(seconds: 120));
    if (ff.code != 0) {
      logp('❌ STT 音频转换失败: ${ff.out}');
      await dsJSONErr(res, 500, '音频转换失败');
      return;
    }
    final modelPath = '$BASE_DIR/models/ggml-base-q5_1.bin';
    final mainBin = '$BASE_DIR/whisper.cpp/build/bin/whisper-cli';
    final wh = await runProcess(
        mainBin, ['-m', modelPath, '-f', wavFile, '-l', 'zh', '-nt', '-np'],
        timeout: const Duration(seconds: 300));
    if (wh.code != 0) {
      logp('❌ STT 识别失败: ${wh.out}');
      await dsJSONErr(res, 500, '语音识别失败');
      return;
    }
    final text = cleanWhisperText(wh.out);
    logp('🎤 STT 認識結果: $text');
    await dsJSONOk(res, 200, {'text': text});
  } finally {
    try {
      final f = File(inFile);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    try {
      final f = File(wavFile);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

// ------------------------------------------------------------
// /api/ds-chat/abort-save
// ------------------------------------------------------------
Future<void> handleDsChatAbortSave(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await dsJSONErr(res, 400, '无效的请求体');
    return;
  }
  final sessionID = mStr(body, 'sessionId');
  final content = mStr(body, 'content');
  final fileIDs = asList(body['fileIds']).map((e) => '$e').toList();
  final aiContent = mStr(body, 'aiContent');
  final reasoning = mStr(body, 'reasoning');
  final messageID = mStr(body, 'messageId');
  // ★ 维度：由前端随请求带上当前模型，决定这条消息归属哪个维度
  final abortModel = mStr(body, 'model');
  // ★ 优先采用前端在「发送时」冻结的维度：
  //   用户中途切换模式后才触发 abort-save 时，model 已不代表原维度。
  final abortDimReq = mStr(body, 'dim').trim();
  final abortDim = (abortDimReq == DS_DIM_DB ||
          abortDimReq == DS_DIM_DS ||
          abortDimReq == DS_DIM_ST)
      ? abortDimReq
      : (dbIsChatModel(abortModel) ? DS_DIM_DB : DS_DIM_DS);

  if (sessionID.trim().isEmpty) {
    await dsJSONErr(res, 400, '缺少会话 ID');
    return;
  }
  if (!File(dsSessionPath(sessionID)).existsSync()) {
    await dsJSONErr(res, 404, '会话不存在');
    return;
  }

  DsMessage? userMsg;
  DsMessage? aiMsg;

  if (messageID.trim().isNotEmpty) {
    if (aiContent.trim().isEmpty) {
      await dsJSONErr(res, 400, '内容为空');
      return;
    }
    final upd = updateDsMessageContent(
        sessionID, messageID, aiContent, reasoning, null,
        dim: abortDim);
    if (upd == null) {
      await dsJSONErr(res, 500, '未找到要更新的消息');
      return;
    }
    aiMsg = upd;
  } else {
    if (content.trim().isEmpty && fileIDs.isEmpty) {
      await dsJSONErr(res, 400, '内容为必填项');
      return;
    }
    final now = DateTime.now();
    final savedContent = content.isEmpty ? '[已上传文件]' : content;
    final u = DsMessage(
      id: 'dsm_${fmtStamp14(now)}_${randomHex(6)}',
      sessionId: sessionID,
      role: 'user',
      content: savedContent,
      createdAt: rfc3339(now),
      attachments: fileIDs.join(','),
      dim: abortDim,
    );
    if (!appendDsMessage(u)) {
      await dsJSONErr(res, 500, '用户消息保存失败');
      return;
    }
    userMsg = u;

    if (aiContent.trim().isNotEmpty) {
      final a = DsMessage(
        id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
        sessionId: sessionID,
        role: 'assistant',
        content: aiContent,
        createdAt: rfc3339(DateTime.now()),
        reasoning: reasoning,
        dim: abortDim,
      );
      if (!appendDsMessage(a)) {
        await dsJSONErr(res, 500, '回答保存失败');
        return;
      }
      aiMsg = a;
    }

    final sess = getDsSession(sessionID);
    if (sess != null) {
      var title = sess.title;
      if (title.isEmpty || title == '新对话') {
        final runes = content.runes.toList();
        if (runes.length > 18) {
          title = '${String.fromCharCodes(runes.sublist(0, 18))}…';
        } else if (runes.isNotEmpty) {
          title = content;
        }
      }
      if (title.trim().isNotEmpty) {
        updateDsSession(sessionID, title, rfc3339(DateTime.now()));
      }
    }
  }

  logp('⏹ 已停止：session=$sessionID ai=${runeLen(aiContent)} 字（messageId=$messageID）');
  await dsJSONOk(res, 200, {
    'stopped': true,
    'userMessage': userMsg?.toJson(),
    'aiMessage': aiMsg?.toJson(),
  });
}

// ------------------------------------------------------------
// /api/ds-chat/continue（续写）
// ------------------------------------------------------------
Future<void> handleDsChatContinue(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await dsJSONErr(res, 400, '无效的请求体');
    return;
  }
  final sessionID = mStr(body, 'sessionId');
  final messageID = mStr(body, 'messageId');
  var base = mStr(body, 'baseContent');
  final deepThink = mBool(body, 'deepThink');
  var level = intArgDefault(body, 'reasoningLevel', 1);

  if (sessionID.trim().isEmpty) {
    await dsJSONErr(res, 400, '缺少会话 ID');
    return;
  }
  final cfg = getDsConfig();
  // 历史值（如 doubao-seed-2-1-pro-260628）统一到当前版本号，避免 404
  final model = dbCanonicalModelValue(
      trimOr(mStr(body, 'model'), cfg.model.isEmpty ? DS_DEFAULT_MODEL : cfg.model));

  // ★★★ 停用整改：中转站（st 维度）聊天入口硬拦截 ★★★
  //   无论前端如何传参，只要显式 dim=st 或模型命中中转站目录，一律 403 拒绝，
  //   绝不发起任何对第三方中转站的请求，杜绝聊天内容外泄。
  if (RELAY_DISABLED &&
      (mStr(body, 'dim').trim() == DS_DIM_ST || isRelayModel(model))) {
    await dsJSONErr(res, 403, RELAY_DISABLED_MSG);
    return;
  }

  // ★ 维度：连 ST 也从请求中确定（模型名无法区分）
  final contDim = dsDimFromReq(req, model);

  // 通道判定：中转站 > 豆包（方舟）> DeepSeek。
  // 豆包模型的继续生成发给方舟（完全不碰 DeepSeek 的 Key 与用量）
  final dbCfg = getDbConfig();
  final relayCfg = getRelayConfig();
  final useRelay = isRelayModel(model);
  final useDoubao = !useRelay && dbIsChatModel(model);
  if (useDoubao) {
    if (dbCfg.apiKey.trim().isEmpty) {
      await dsJSONErr(
          res,
          400,
          dbLocalized(dsRequestLang(req, body), 'keyMissingForModel'));
      return;
    }
  } else if (useRelay) {
    if (relayCfg.apiKey.trim().isEmpty) {
      await dsJSONErr(res, 400, '已选择中转站模型，但中转站 API Key 未填写');
      return;
    }
  } else if (cfg.apiKey.isEmpty) {
    await dsJSONErr(res, 400, '请先设置 DeepSeek API Key');
    return;
  }
  final callKey = useDoubao
      ? dbCfg.apiKey
      : (useRelay ? relayCfg.apiKey : cfg.apiKey);
  final callUrl = useDoubao
      ? dbChatEndpoint()
      : (useRelay ? relayChatEndpoint() : DS_API_URL);
  // 豆包模型继续生成时也保持"先想再写"
  final extraBody = useDoubao ? dbThinkingEnableParam(model) : null;

  // ★ 只把「同一维度」的历史发给模型，豆包与 DeepSeek 互不可见
  final history = getDsMessages(sessionID,
      dim: contDim);
  var oldReasoning = '';
  if (messageID.isNotEmpty) {
    for (final m in history) {
      if (m.id == messageID) {
        if (runeLen(m.content) >= runeLen(base)) base = m.content;
        oldReasoning = m.reasoning;
        break;
      }
    }
  }
  if (base.trim().isEmpty) {
    await dsJSONErr(res, 400, '没有可继续生成的内容');
    return;
  }
  // ★ 推理等级上限 999；所有模型的最大输出统一读取全局档位（默认 256K）。
  level = dbClampReasoningLevel(level);
  final params = levelToParams(level);
  var maxTokens = params.maxTokens;
  // Kimi 系列强制温度 1.0；其它模型沿用推理等级给出的原值。
  final contTemp = dbIsKimiModel(model) ? DB_KIMI_TEMPERATURE : params.temperature;
  final contForcedOut = dbForcedMaxOutput(model);
  if (contForcedOut > 0) {
    if (maxTokens != contForcedOut) {
      logp('🔒 续写输出上限: $model → $contForcedOut tokens（原 $maxTokens）');
    }
    maxTokens = contForcedOut;
  }

  // i18n：继续生成时也注入与 UI 语言一致的语言固定提示词
  final uiLang = dsRequestLang(req, body);
  final sysParts = <String>[
    dsLangSystemPrompt(uiLang),
    '你正在接着写同一个回答的剩余部分。请承接上一条 assistant 消息的最后一个字符继续输出。禁止重复、改写已有内容，禁止输出说明、标题、总结。'
  ];
  if (deepThink) sysParts.add('你能进行深入的多步推理。请充分展示思考过程。');
  sysParts.add(knowledgeSystemPromptForChat(uiLang));

  final apiMessages = <Map<String, dynamic>>[
    {'role': 'system', 'content': sysParts.join('\n')},
  ];
  for (final m in history) {
    if (messageID.isNotEmpty && m.id == messageID) break;
    if (m.role == 'user' || m.role == 'assistant' || m.role == 'system') {
      apiMessages.add({'role': m.role, 'content': m.content});
    }
  }
  apiMessages.add({'role': 'assistant', 'content': base});
  apiMessages.add({
    'role': 'user',
    'content': '（继续指令）请从中断处接着写。承接上一个最后的字符，不要重复或重说开头。',
  });

  final sse = Sse(res);
  logp('▶️ 继续生成: session=$sessionID 原文本=${runeLen(base)} 字 model=$model');

  final addBuf = StringBuffer();
  final reasoningBuf = StringBuffer();
  final usageAcc = DsUsageAcc();
  try {
    await callDsMultiRoundStream(
      callKey,
      model,
      apiMessages,
      maxTokens,
      contTemp,
      1,
      (round, total, stage) {},
      (s) {
        reasoningBuf.write(s);
        sse.send('reasoning', {'delta': s});
      },
      (s) {
        addBuf.write(s);
        sse.send('content', {'delta': s});
      },
      usageAcc,
      apiUrl: callUrl,
      extraBody: extraBody,
    );
  } catch (e) {
    logp('⚠️ 继续生成被中断: $e');
    await sse.send('error', {'message': '$e'});
    await sse.done();
    return;
  }

  final merged = mergeContinuation(base, addBuf.toString());
  var finalReasoning = oldReasoning;
  final rsn = reasoningBuf.toString();
  if (rsn.isNotEmpty) {
    if (finalReasoning.trim().isEmpty) {
      finalReasoning = rsn;
    } else {
      finalReasoning = '${finalReasoning.replaceAll(RegExp(r'\n+$'), '')}\n$rsn';
    }
  }

  DsMessage? aiMsg;
  if (messageID.isNotEmpty) {
    final upd = updateDsMessageContent(sessionID, messageID, merged,
        finalReasoning, usageAcc.snapshot(),
        dim: contDim);
    if (upd != null) {
      aiMsg = upd;
      final sess = getDsSession(sessionID);
      if (sess != null && sess.title.trim().isNotEmpty) {
        updateDsSession(sessionID, sess.title, rfc3339(DateTime.now()));
      }
    }
  } else {
    final a = DsMessage(
      id: 'dsm_${fmtStamp14(DateTime.now())}_${randomHex(6)}',
      sessionId: sessionID,
      role: 'assistant',
      content: merged,
      createdAt: rfc3339(DateTime.now()),
      reasoning: finalReasoning,
      usage: usageAcc.snapshot(),
      dim: contDim,
    );
    appendDsMessage(a);
    aiMsg = a;
  }

  logp('✅ 継続生成完了: 追加 ${runeLen(addBuf.toString())} 文字、結合後 ${runeLen(merged)} 文字');
  await sse.send('done', {
    'aiMessage': aiMsg?.toJson(),
    'content': merged,
    'charCount': runeLen(merged),
    'model': model,
    'continued': true,
    'usage': aiMsg?.usage?.toJson(),
  });
  await sse.done();
}

// ------------------------------------------------------------
// /api/ds-chat/translate（把 AI 回复翻译成简体中文／不保存到历史）
// ------------------------------------------------------------
/// 用于不破坏翻译结果 Markdown 的后处理。
/// - 去除模型加的"译文："等标签
/// - 剥除包裹整个输出的 ```lang ... ```（因为不是正文）
/// - 代码围栏为奇数个则补闭合
/// - 统一 CRLF・去除零宽字符・去除行尾空白・压缩空行
String dsSanitizeTranslatedMarkdown(String raw) {
  var s = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  s = s.replaceAll('\u200B', '').replaceAll('\uFEFF', '');
  s = s.trim();

  // 去除开头标签（"翻译："、"译文："、"訳文："…）
  final label = RegExp(
      r'^(?:翻訳|翻譯|訳文|译文|譯文|中文翻译|中文翻譯|翻訳結果|译文如下)\s*[:：]\s*');
  s = s.replaceFirst(label, '').trim();

  // 仅当整个输出被 1 个代码围栏包裹时才剥除
  final wrapped = RegExp(r'^```[a-zA-Z0-9_+\-]*[ \t]*\n([\s\S]*?)\n?```$');
  final m = wrapped.firstMatch(s);
  if (m != null) {
    final inner = (m.group(1) ?? '').trim();
    if (inner.isNotEmpty && !inner.contains('```')) {
      // 若内容含 Markdown 结构，判定为"被重新包裹的正文"并剥除
      final mdLike = RegExp(
              r'(^#{1,6}\s)|(^\s*[-*+]\s)|(^\s*\d+\.\s)|(^\s*\|)|(^>)',
              multiLine: true)
          .hasMatch(inner);
      if (mdLike) s = inner;
    }
  }

  // 代码围栏为奇数个则补闭合（防止渲染器漏闭合）
  final fences = RegExp(r'```').allMatches(s).length;
  if (fences.isOdd) s = '$s\n```';

  // 去除行尾空白，把 3 个以上连续空行压缩为 2 个
  s = s
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t]+$'), ''))
      .join('\n');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}

Future<void> handleDsChatTranslate(HttpRequest req) async {
  final res = req.response;
  if (req.method != 'POST') {
    await dsJSONErr(res, 405, 'Method not allowed');
    return;
  }
  Map<String, dynamic> body;
  try {
    body = await readJsonBody(req);
  } catch (_) {
    await dsJSONErr(res, 400, '无效的请求体');
    return;
  }
  final text = mStr(body, 'text');
  final target = trimOr(mStr(body, 'target'), '簡体字中国語（简体中文）');
  if (text.trim().isEmpty) {
    await dsJSONErr(res, 400, '要翻译的文本为空');
    return;
  }
  // ★ 翻译按钮走火山引擎（方舟）上的 DeepSeek Flash 模型：deepseek-v4-1-flash-261017
  //   通过 doubao.dart 的 dbChatText 调用方舟 /chat/completions，不再使用 DeepSeek 官方通道。
  const String translateModel = 'deepseek-v4-1-flash-261017';
  final dbCfg = getDbConfig();
  if (dbCfg.apiKey.trim().isEmpty) {
    await dsJSONErr(res, 400, '请先设置火山方舟 API Key');
    return;
  }
  var model = translateModel;

  // ★ 一个字符也不破坏 Markdown 的严格提示词
  const systemPrompt = '你是精通 Markdown 的优秀翻译者。将输入文本翻译成指定语言。\n'
      '【厳守事項】\n'
      '1. 只输出翻译后的正文。禁止任何前言、解说、注释、"译文："等标签以及原文重复。\n'
      '2. 一个字符也不破坏 Markdown 语法：标题的 #、无序列表的 - / * / +、有序列表的 1.、'
      '引用的 >、表格的 | 与分隔行 |---|、强调的 ** / * / ~~、链接 [text](url) 全部保留。\n'
      '3. 表格的列数、行数与原文完全保持一致。分隔行（|---|）不翻译，原样保留。'
      '也禁止增删单元格内的换行或竖线。\n'
      '4. 保持段落间的空行，不把多个块连接成一行。不要把列表项压成段落。\n'
      '5. 保持嵌套列表的缩进（以 2 个半角空格为单位）。\n'
      '6. 代码块、行内代码、命令、URL、文件路径、API 名、包名、'
      '变量名、公式（\$...\$ / \$\$...\$\$）不翻译，原样保留。\n'
      '7. 不要用 ``` 包裹整个输出（不加代码围栏）。不添加 HTML 标签。\n'
      '8. 若原文是非 Markdown 的纯文本，则按纯文本翻译。';

  final messages = <Map<String, dynamic>>[
    {'role': 'system', 'content': systemPrompt},
    {
      'role': 'user',
      'content': '请把以下内容翻译成$target。'
          '请保持 Markdown 语法、行结构、空行和缩进与原文一致，只返回翻译后的正文。\n\n$text'
    },
  ];

  // ★ 汇总实际 usage（用于费用显示・不持久化）
  final usageAcc = DsUsageAcc();
  try {
    final resp = await dbChatTextWithUsage(
      '',
      messages,
      model: model,
      maxTokens: 8192,
      temperature: 0.2,
      timeout: const Duration(seconds: 300),
    );
    final out = resp.text;
    usageAcc.addRaw(RawDsUsage.fromJson(resp.usage));
    usageAcc.model = model;
    const bool streamed = false;
    final clean = dsSanitizeTranslatedMarkdown(out);
    if (clean.isEmpty) {
      // ★ 不返回日语：由 UI 侧用 error 码渲染成本地语言
      await dsJSONOk(res, 502, {'error': 'translate_empty', 'detail': ''});
      return;
    }
    // 破坏检测：结构计数不一致则记日志（显示侧不破坏原文）
    try {
      int cnt(String s, String pat) =>
          RegExp(pat, multiLine: true).allMatches(s).length;
      final srcH = cnt(text, r'^#{1,6}\s');
      final dstH = cnt(clean, r'^#{1,6}\s');
      final srcF = cnt(text, r'```');
      final dstF = cnt(clean, r'```');
      final srcT = cnt(text, r'^\s*\|');
      final dstT = cnt(clean, r'^\s*\|');
      if (srcH != dstH || srcF != dstF || srcT != dstT) {
        logp('⚠️ 翻译后 Markdown 结构差异: 标题 $srcH→$dstH / 围栏 $srcF→$dstF / 表行 $srcT→$dstT');
      }
    } catch (_) {}
    final usage = usageAcc.snapshot();
    logp('🌐 翻訳完了: ${runeLen(text)} → ${runeLen(clean)} 文字 (model=$model, stream=$streamed)');
    await dsJSONOk(res, 200, {
      'translation': clean,
      'model': model,
      'target': target,
      'streamed': streamed,
      'usage': usage?.toJson(),
    });
  } catch (e) {
    logp('❌ 翻訳失敗: $e');
    // ★ 不返回日语：只传详情（HTTP 402 等），文案由 UI 侧决定
    await dsJSONOk(res, 502, {'error': 'translate_failed', 'detail': e.toString()});
  }
}
