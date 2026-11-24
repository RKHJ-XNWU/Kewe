// ============================================================
// doubao_realtime.dart —— 豆包端到端实时语音（Seeduplex）与 RTC 接入层
//
//   1) Seeduplex 全双工实时语音
//      浏览器 ⇄ 本地 Dart 服务（WebSocket 代理）⇄ 火山引擎
//      wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue
//
//      为什么必须做代理：
//        · 浏览器的 WebSocket 构造器无法设置自定义请求头，X-Api-Key 发不出去；
//        · API Key 绝不能被前端脚本读到；
//        · 协议要求的固定参数（model 1.2.6.1、采样率 16k/24k）由服务端统一补齐，
//          避免前端漏填导致 400。
//
//   2) RTC AI 音视频互动（StartVoiceChat / StopVoiceChat）
//      服务端按火山引擎 V4 签名调用 RTC OpenAPI，把端到端语音模型挂到 RTC 房间。
//      注意：浏览器侧要真正收发 RTC 音视频还需要官方 RTC Web SDK，
//      本文件只负责「服务端任务编排」这一半，前端不得谎称已能通话。
//
//   设计原则与全项目一致：零第三方依赖，失败一律如实上报。
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'doubao.dart';
import 'globals.dart';
import 'httpsrv.dart';
import 'sha256.dart';

// ------------------------------------------------------------
// 常量
// ------------------------------------------------------------
/// Seeduplex 全双工实时语音 WebSocket 端点
const String dbDuplexUrl =
    'wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue';

/// Seeduplex 协议要求固定的 model 值
const String dbDuplexModel = '1.2.6.1';

/// Doubao-Seed-Realtime-1.0（实时音视频）WebSocket 端点与模型
const String dbRealtimeVideoUrl =
    'wss://openspeech.bytedance.com/api/v3/realtime';
const String dbRealtimeVideoModel = '1.3.0.0';

/// 实时音视频只允许这四种官方 2.0 音色，默认 Vivi 2.0。
const String dbRealtimeDefaultVoice = 'zh_female_vv_uranus_bigtts';
const List<String> dbRealtimeVoices = <String>[
  'zh_female_vv_uranus_bigtts', // Vivi 2.0
  'zh_female_xiaohe_uranus_bigtts', // 小何 2.0
  'zh_male_m191_uranus_bigtts', // 云舟 2.0
  'zh_male_taocheng_uranus_bigtts', // 小天 2.0
];

/// 计费：实时语音 0.2 元/分钟，实时视频 0.4 元/分钟。
const double dbVoiceYuanPerMinute = 0.2;
const double dbVideoYuanPerMinute = 0.4;

/// RTC OpenAPI 配置
const String dbRtcHost = 'rtc.volcengineapi.com';
const String dbRtcRegion = 'cn-north-1';
const String dbRtcService = 'rtc';
const String dbRtcVersion = '2025-06-01';

// ------------------------------------------------------------
// 默认系统提示词
//   语音通话里模型会被逐句朗读，因此必须压制长句、列表与 Markdown。
// ------------------------------------------------------------
/// 各语言的「说话语言」指令：语言自由，跟随用户
const Map<String, String> _dbSpeakLang = <String, String>{
  'ja': '说话语言自由。请与用户使用的语言保持一致。',
  'zh': '说话语言不受限制，请跟随用户使用的语言。',
  'en': 'There is no language restriction; speak in the language the user uses.',
  'ko': '말하는 언어는 자유이며 사용자가 쓰는 언어를 따르세요.',
  'ru': 'Язык не ограничен: говорите на языке пользователя.',
  'fr': "La langue n'est pas imposée : parlez dans la langue de l'utilisateur.",
};

/// 语音通话提示词
///   刻意不复用 dsLangSystemPrompt：那段是给文本聊天用的超长固定指令
///   （含「思考过程/表格/代码注释」等要求），塞进语音场景会让模型倾向长回答，
///   与低延迟全双工的目标直接冲突。
String dbDuplexSystemPrompt(String lang) {
  final say = _dbSpeakLang[lang] ?? _dbSpeakLang['zh']!;
  return '你正在和用户进行实时语音通话。$say\n'
      '语言不受任何限制，任何语言都可以使用，始终跟随用户当前使用的语言。\n'
      '要求：\n'
      '1. 回答最多 1000 字，最少不限，说完就停。\n'
      '2. 不要列表、不要 Markdown、不要念代码、网址或标点符号串。\n'
      '3. 用自然口语，句子短，便于朗读。\n'
      '4. 没听清时只简短追问一次。';
}

/// 实时音视频提示词：在语音版本上增加「看画面」的行为约束。
String dbVideoSystemPrompt(String lang) {
  final say = _dbSpeakLang[lang] ?? _dbSpeakLang['zh']!;
  return '你正在和用户进行实时视频通话，可以通过摄像头看到用户的画面。$say\n'
      '语言不受任何限制，任何语言都可以使用，始终跟随用户当前使用的语言。\n'
      '要求：\n'
      '1. 回答最多 1000 字，最少不限，说完就停。\n'
      '2. 不要列表、不要 Markdown、不要念代码、网址或标点符号串。\n'
      '3. 用自然口语，句子短，便于朗读。\n'
      '4. 结合当前画面回答；画面看不清或没有收到画面时，不要编造看到的内容，可以简短说明。\n'
      '5. 用户关闭摄像头后，仍然可以正常语音交流。\n'
      '6. 没听清时只简短追问一次。';
}

// ------------------------------------------------------------
// 工具：把任意值安全转成 Map<String, dynamic>
// ------------------------------------------------------------
Map<String, dynamic> _asMap(Object? v) => v is Map
    ? v.map((Object? k, Object? e) => MapEntry<String, dynamic>('$k', e))
    : <String, dynamic>{};

String _str(Object? v) => v == null ? '' : '$v'.trim();

// ------------------------------------------------------------
// 上行帧处理：为 session.create 补齐协议默认参数
//   其余事件（音频 / 判停 / 打断 / 上下文 …）原样透传。
// ------------------------------------------------------------
String dbPrepareUpstream(
  String raw,
  DbConfig cfg, {
  String lang = 'zh',
  String voice = '',
  String instructions = '',
  bool skipVoice = false,
}) {  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return raw; // 非 JSON：交给服务端裁决，本地不擅自改写
  }
  final m = _asMap(decoded);
  if (_str(m['type']) != 'session.create') return raw;

  final session = _asMap(m['session']);

  // model 固定 1.2.6.1（Seeduplex 协议要求）
  if (_str(session['model']).isEmpty) session['model'] = dbDuplexModel;

  // ---- 输入音频：仅支持 pcm / speech_opus，采样率仅支持 16000 ----
  final audio = _asMap(session['audio']);
  final input = _asMap(audio['input']);
  final inFmt = _asMap(input['format']);
  if (_str(inFmt['type']).isEmpty) inFmt['type'] = 'pcm';
  inFmt['rate'] = 16000;
  input['format'] = inFmt;
  audio['input'] = input;

  // ---- 输出音频：pcm_s16le / pcm / ogg_opus，采样率仅支持 24000 ----
  final output = _asMap(audio['output']);
  final outFmt = _asMap(output['format']);
  if (_str(outFmt['type']).isEmpty) outFmt['type'] = 'pcm_s16le';
  outFmt['rate'] = 24000;
  output['format'] = outFmt;
  if (skipVoice) {
    // ★ 前端由 Edge TTS 负责出声时，不向服务端索要豆包音色：
    //   账号没有该音色权限时，硬塞音色 id 会让 session.create 直接被拒。
    output.remove('voice');
  } else {
    // 端到端通话音色：只认 duplexVoice / voice，绝不回退到普通 TTS 音色（cfg.voice）。
    // 普通 TTS 音色 ID（*_bigtts 的 mars/moon 系列）端到端链路不认，
    // 硬塞会触发 ClientError:InvalidSpeaker。
    // 空值最终落到 Vivi 2.0（zh_female_vv_uranus_bigtts），这是官方示例默认音色。
    var v = _str(output['voice']);
    if (v.isEmpty) v = _str(voice);
    if (v.isEmpty) v = _str(cfg.duplexVoice);
    if (v.isEmpty) v = 'zh_female_vv_uranus_bigtts';
    v = dbNormalizeDuplexVoice(v); // 旧版 jupiter（仅中文）→ 多语种 uranus
    output['voice'] = v;
  }
  // 语速走官方字段 session.audio.output.speed（-50~100），不再塞 extension
  if (cfg.duplexSpeechRate != 0) {
    output['speed'] = cfg.duplexSpeechRate;
  }
  audio['output'] = output;
  session['audio'] = audio;

  // ---- 系统提示词 ----
  if (_str(session['instructions']).isEmpty) {
    final custom = _str(instructions).isNotEmpty
        ? _str(instructions)
        : _str(cfg.duplexInstructions);
    session['instructions'] =
        custom.isNotEmpty ? custom : dbDuplexSystemPrompt(lang);
  }

  // ---- 专有能力（唱歌 / 联网）通过 extension.dialog.extra 透传 ----
  //   官方字段（Seeduplex 全双工协议）：
  //     · enable_music：唱歌能力
  //     · enable_volc_websearch：开启内置联网搜索
  //     · volc_websearch_type：web_custom_api（豆包搜索 Custom 版）/ web_global_api（Global 版）
  //     · volc_websearch_api_key：融合信息搜索 API Key（开启联网后需配置）
  //   语速不走 extension，已放到 session.audio.output.speed。
  if (cfg.duplexMusic || cfg.duplexWebsearch) {
    final extension = _asMap(session['extension']);
    final dialog = _asMap(extension['dialog']);
    final extra = _asMap(dialog['extra']);
    if (cfg.duplexMusic) {
      extra['enable_music'] = true;
    }
    if (cfg.duplexWebsearch) {
      extra['enable_volc_websearch'] = true;
      extra['volc_websearch_type'] = 'web_custom_api';
      if (cfg.duplexWebsearchApiKey.trim().isNotEmpty) {
        extra['volc_websearch_api_key'] = cfg.duplexWebsearchApiKey.trim();
      }
    }
    dialog['extra'] = extra;
    extension['dialog'] = dialog;
    session['extension'] = extension;
  }

  m['session'] = session;
  return jsonEncode(m);
}

/// 实时音视频版 session.create 补齐：
///   · model 固定 1.3.0.0；
///   · 输入 pcm/16000、输出 pcm_s16le/24000；
///   · extension.video 固定在顶层（与 1.3.0.0 文档和官方 Web Demo 一致）；
///   · 只接受四种 2.0 官方音色，默认 Vivi 2.0。
String dbPrepareVideoUpstream(
  String raw,
  DbConfig cfg, {
  String lang = 'zh',
  String voice = '',
  String instructions = '',
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return raw;
  }
  final m = _asMap(decoded);
  if (_str(m['type']) != 'session.create') return raw;

  final session = _asMap(m['session']);
  session['model'] = dbRealtimeVideoModel;

  final audio = _asMap(session['audio']);
  final input = _asMap(audio['input']);
  final inFmt = _asMap(input['format']);
  inFmt['type'] = 'pcm';
  inFmt['rate'] = 16000;
  input['format'] = inFmt;
  audio['input'] = input;

  final output = _asMap(audio['output']);
  final outFmt = _asMap(output['format']);
  outFmt['type'] = 'pcm_s16le';
  outFmt['rate'] = 24000;
  output['format'] = outFmt;
  var v = _str(output['voice']);
  if (v.isEmpty) v = _str(voice);
  if (v.isEmpty) v = _str(cfg.duplexVoice);
  if (v.isEmpty) v = dbRealtimeDefaultVoice;
  v = dbNormalizeDuplexVoice(v);
  if (!dbRealtimeVoices.contains(v)) v = dbRealtimeDefaultVoice;
  output['voice'] = v;
  if (cfg.duplexSpeechRate != 0) {
    output['speed'] = cfg.duplexSpeechRate;
  }
  audio['output'] = output;
  session['audio'] = audio;

  if (_str(session['instructions']).isEmpty) {
    final custom = _str(instructions).isNotEmpty
        ? _str(instructions)
        : _str(cfg.duplexInstructions);
    session['instructions'] =
        custom.isNotEmpty ? custom : dbVideoSystemPrompt(lang);
  }

  // 旧版前端若误把 extension 塞进 session，这里迁移到顶层，避免 1.3.0.0 忽略视频配置。
  final legacy = _asMap(session.remove('extension'));
  final extension = _asMap(m['extension']);
  final legacyDialog = _asMap(legacy['dialog']);
  final dialog = _asMap(extension['dialog']);
  for (final e in legacyDialog.entries) {
    dialog.putIfAbsent(e.key, () => e.value);
  }
  final extra = _asMap(dialog['extra']);
  if (cfg.duplexMusic) extra['enable_music'] = true;
  if (cfg.duplexWebsearch) {
    extra['enable_volc_websearch'] = true;
    extra['volc_websearch_type'] = 'web_custom_api';
    if (cfg.duplexWebsearchApiKey.trim().isNotEmpty) {
      extra['volc_websearch_api_key'] = cfg.duplexWebsearchApiKey.trim();
    }
  }
  if (extra.isNotEmpty) dialog['extra'] = extra;
  if (dialog.isNotEmpty) extension['dialog'] = dialog;
  extension['video'] = <String, dynamic>{
    'frame_format': 'JPEG',
    'frame_rate': 2,
  };
  m['extension'] = extension;
  m['session'] = session;
  return jsonEncode(m);
}

// ------------------------------------------------------------
// Seeduplex WebSocket 代理
// ------------------------------------------------------------
/// 组装 Seeduplex 的鉴权头
///   优先：duplexApiKey（豆包语音控制台的新版 API Key）→ X-Api-Key
///   回退：s2sAppId + s2sToken（旧版控制台）→ X-App-Id + Authorization
///   最后：方舟 API Key（多数情况下语音服务不认，会如实返回 401）
Map<String, String> dbDuplexAuthHeaders(DbConfig cfg) {
  final duplexKey = cfg.duplexApiKey.trim();
  if (duplexKey.isNotEmpty) {
    return <String, String>{'X-Api-Key': duplexKey};
  }
  final appId = cfg.s2sAppId.trim();
  final token = cfg.s2sToken.trim();
  if (appId.isNotEmpty && token.isNotEmpty) {
    return <String, String>{
      'X-App-Id': appId,
      'Authorization': 'Bearer; $token',
    };
  }
  return <String, String>{};
}

Future<void> handleDbRealtime(HttpRequest req) async {
  final cfg = getDbConfig();
  final auth = dbDuplexAuthHeaders(cfg);
  if (auth.isEmpty) {
    await errJson(req.response, 400,
        '端到端语音服务的认证信息未设置。请在设置界面输入豆包语音 API Key。');
    return;
  }

  final lang = trimOr(qp(req, 'lang'), 'zh');
  final voice = trimOr(qp(req, 'voice'), '');
  final instructions = trimOr(qp(req, 'instructions'), '');
  // edge=1：前端用 Edge TTS 出声，服务端不必也不该指定豆包音色
  final skipVoice = qp(req, 'edge') == '1';

  WebSocket client;
  try {
    client = await WebSocketTransformer.upgrade(req);
  } catch (e) {
    logp('❌ Seeduplex: 升级到 WebSocket 失败: $e');
    return;
  }

  WebSocket remote;
  try {
    remote = await WebSocket.connect(
      dbDuplexUrl,
      headers: auth,
    ).timeout(const Duration(seconds: 20));
  } catch (e) {
    final msg = '无法连接到端到端语音服务：${dbErrText(e)}';
    logp('❌ Seeduplex: $msg');
    try {
      client.add(jsonEncode(<String, dynamic>{
        'type': 'error',
        'code': 'upstream_connect_failed',
        'message': msg,
      }));
      await client.close(1011, 'upstream connect failed');
    } catch (_) {}
    return;
  }

  logp('🔊 Seeduplex 连接已开始（lang=$lang, voice=${voice.isEmpty ? '(默认)' : voice}）');

  var closed = false;
  var framesUp = 0;
  var framesDown = 0;

  Future<void> shutdown(String reason) async {
    if (closed) return;
    closed = true;
    logp('🔊 Seeduplex 结束（$reason・上行 $framesUp 帧 / 下行 $framesDown 帧）');
    try {
      await remote.close();
    } catch (_) {}
    try {
      await client.close();
    } catch (_) {}
  }

  // 下行：服务端 → 浏览器
  remote.listen(
    (Object? data) {
      if (closed) return;
      framesDown++;
      if (data is String) {
        // 只记录关键事件，避免每帧日志刷屏
        if (data.contains('session.created') ||
            data.contains('"error"') ||
            data.contains('response.done')) {
          final t = _str(_asMap(_safeDecode(data))['type']);
          if (t.isNotEmpty) logp('🔊 Seeduplex ↓ $t');
          if (t == 'error') logp('❌ Seeduplex 错误: $data');
        }
      }
      try {
        client.add(data);
      } catch (e) {
        shutdown('写入浏览器侧失败: $e');
      }
    },
    onError: (Object e) => shutdown('上游错误: $e'),
    onDone: () => shutdown('上游已断开'),
    cancelOnError: false,
  );

  // 上行：浏览器 → 服务端
  client.listen(
    (Object? data) {
      if (closed) return;
      framesUp++;
      final out = data is String
          ? dbPrepareUpstream(
              data,
              cfg,
              lang: lang,
              voice: voice,
              instructions: instructions,
              skipVoice: skipVoice,
            )
          : data;
      try {
        remote.add(out);
      } catch (e) {
        shutdown('写入上游失败: $e');
      }
    },
    onError: (Object e) => shutdown('浏览器侧错误: $e'),
    onDone: () => shutdown('浏览器已断开'),
    cancelOnError: false,
  );
}

Object? _safeDecode(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}

// ------------------------------------------------------------
// Doubao-Seed-Realtime-1.0 实时音视频 WebSocket 代理
// ------------------------------------------------------------
Future<void> handleDbRealtimeVideo(HttpRequest req) async {
  final cfg = getDbConfig();
  final auth = dbDuplexAuthHeaders(cfg);
  if (auth.isEmpty) {
    await errJson(req.response, 400,
        '端到端实时音视频服务的认证信息未设置。请在设置界面输入豆包语音 API Key。');
    return;
  }
  auth['X-Api-Connect-Id'] = randomHex(16);

  final lang = trimOr(qp(req, 'lang'), 'zh');
  final voice = trimOr(qp(req, 'voice'), dbRealtimeDefaultVoice);
  final instructions = trimOr(qp(req, 'instructions'), '');

  WebSocket client;
  try {
    client = await WebSocketTransformer.upgrade(req);
  } catch (e) {
    logp('❌ RealtimeVideo: 升级到 WebSocket 失败: $e');
    return;
  }

  WebSocket remote;
  try {
    remote = await WebSocket.connect(
      dbRealtimeVideoUrl,
      headers: auth,
    ).timeout(const Duration(seconds: 20));
  } catch (e) {
    final msg = '无法连接到实时音视频服务：${dbErrText(e)}';
    logp('❌ RealtimeVideo: $msg');
    try {
      client.add(jsonEncode(<String, dynamic>{
        'type': 'error',
        'code': 'upstream_connect_failed',
        'message': msg,
      }));
      await client.close(1011, 'upstream connect failed');
    } catch (_) {}
    return;
  }

  logp('🎥 RealtimeVideo 连接已开始（lang=$lang, voice=$voice）');

  var closed = false;
  var framesUp = 0;
  var framesDown = 0;

  Future<void> shutdown(String reason) async {
    if (closed) return;
    closed = true;
    logp('🎥 RealtimeVideo 结束（$reason・上行 $framesUp 帧 / 下行 $framesDown 帧）');
    try {
      await remote.close();
    } catch (_) {}
    try {
      await client.close();
    } catch (_) {}
  }

  remote.listen(
    (Object? data) {
      if (closed) return;
      framesDown++;
      if (data is String) {
        final t = _str(_asMap(_safeDecode(data))['type']);
        if (t == 'session.created' ||
            t == 'error' ||
            t == 'response.created' ||
            t == 'response.done') {
          if (t.isNotEmpty) logp('🎥 RealtimeVideo ↓ $t');
        }
        if (t == 'error') logp('❌ RealtimeVideo 错误: $data');
      }
      try {
        client.add(data);
      } catch (e) {
        shutdown('写入浏览器侧失败: $e');
      }
    },
    onError: (Object e) => shutdown('上游错误: $e'),
    onDone: () => shutdown('上游已断开'),
    cancelOnError: false,
  );

  client.listen(
    (Object? data) {
      if (closed) return;
      framesUp++;
      final out = data is String
          ? dbPrepareVideoUpstream(
              data,
              cfg,
              lang: lang,
              voice: voice,
              instructions: instructions,
            )
          : data;
      try {
        remote.add(out);
      } catch (e) {
        shutdown('写入上游失败: $e');
      }
    },
    onError: (Object e) => shutdown('浏览器侧错误: $e'),
    onDone: () => shutdown('浏览器已断开'),
    cancelOnError: false,
  );
}

// ------------------------------------------------------------
// 实时音视频通话记录：$DATA_DIR/jilmtshx/*.sts
//   · 仅当前账号目录，禁止跨账号扫描；
//   · 五段格式：时间戳|角色|文本|序号|语言 + 行尾 |；
//   · 通话结束后一次性写入，不支持中途增量保存。
// ------------------------------------------------------------
String _videoRecordDir() => '$DATA_DIR/jilmtshx';

List<String>? _videoRecordLines(Object? raw) {
  if (raw is! List || raw.isEmpty) return null;
  final out = <String>[];
  for (final e in raw) {
    var line = '$e'.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
    if (line.isEmpty) continue;
    if (!line.endsWith('|')) line = '$line|';
    // 文本中的竖线必须由前端替换成全角｜，否则五段格式会被破坏。
    if (line.split('|').length != 6) return null;
    out.add(line);
  }
  return out.isEmpty ? null : out;
}

Future<void> handleDbVideoRecordSave(HttpRequest req) async {
  if (req.method != 'POST') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  final body = await readJsonBody(req);
  final lines = _videoRecordLines(body['lines']);
  if (lines == null) {
    await errJson(req.response, 400, '通话记录格式无效：需要五段并以 | 结尾');
    return;
  }
  final duration = intArgDefault(body, 'durationSec', 0);
  final costFen = intArgDefault(body, 'costFen', 0);
  final safeDur = duration < 0 ? 0 : (duration > 86400 ? 86400 : duration);
  final safeCost = costFen < 0 ? 0 : (costFen > 100000 ? 100000 : costFen);
  try {
    final dir = _videoRecordDir();
    ensureDir(dir);
    final name =
        'video_${fmtStamp14(DateTime.now())}_${safeDur}s_${safeCost}c_${randomHex(4)}.sts';
    final file = File('$dir/$name');
    file.writeAsStringSync('${lines.join('\n')}\n');
    logp('🎥 实时音视频记录已保存: $name（${lines.length} 行）');
    await jsonResponse(req.response, 200, <String, dynamic>{
      'ok': true,
      'file': name,
      'count': lines.length,
      'durationSec': safeDur,
      'costFen': safeCost,
    });
  } catch (e) {
    logp('❌ 实时音视频记录保存失败: $e');
    await errJson(req.response, 500, '通话记录保存失败：$e');
  }
}

Map<String, dynamic>? _parseVideoRecord(String name, File f) {
  try {
    final lines = <String>[];
    for (final raw in f.readAsStringSync().split('\n')) {
      final t = raw.trim();
      if (t.isNotEmpty) lines.add(t);
    }
    final turns = <Map<String, dynamic>>[];
    var preview = '';
    for (final line in lines) {
      final p = line.split('|');
      if (p.length < 5) continue;
      final role = p[1] == 'ai' ? 'assistant' : p[1];
      final text = p[2];
      turns.add(<String, dynamic>{
        'at': int.tryParse(p[0]) ?? 0,
        'role': role,
        'text': text,
        'seq': int.tryParse(p[3]) ?? 0,
        'lang': p[4],
      });
      if (preview.isEmpty && role == 'user' && text.trim().isNotEmpty) {
        preview = text.trim();
      }
    }
    if (preview.length > 48) preview = '${preview.substring(0, 48)}…';
    if (preview.isEmpty && turns.isNotEmpty) {
      preview = _str(turns.first['text']);
      if (preview.length > 48) preview = '${preview.substring(0, 48)}…';
    }
    final m = RegExp(r'video_[0-9]{8}_[0-9]{6}_([0-9]+)s_([0-9]+)c_')
        .firstMatch(name);
    final dur = m == null ? 0 : (int.tryParse(m.group(1) ?? '') ?? 0);
    final fen = m == null ? 0 : (int.tryParse(m.group(2) ?? '') ?? 0);
    return <String, dynamic>{
      'name': name,
      'preview': preview,
      'lineCount': lines.length,
      'lines': lines,
      'turns': turns,
      'mtime': f.statSync().modified.millisecondsSinceEpoch,
      'durationSec': dur,
      'costFen': fen,
      'costYuan': fen / 100.0,
      'mode': 'video',
      'lang': turns.isEmpty ? '' : _str(turns.first['lang']),
    };
  } catch (_) {
    return null;
  }
}

List<Map<String, dynamic>> _listVideoRecords() {
  final dir = Directory(_videoRecordDir());
  final out = <Map<String, dynamic>>[];
  if (!dir.existsSync()) return out;
  try {
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final n = f.uri.pathSegments.isEmpty
              ? f.path
              : f.uri.pathSegments.last.toLowerCase();
          return n.startsWith('video_') && n.endsWith('.sts');
        })
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final f in files) {
      final name = f.uri.pathSegments.isEmpty
          ? f.path
          : f.uri.pathSegments.last;
      final rec = _parseVideoRecord(name, f);
      if (rec != null) out.add(rec);
    }
  } catch (e) {
    logp('⚠️ 读取实时音视频记录失败: $e');
  }
  return out;
}

Future<void> handleDbVideoRecordList(HttpRequest req) async {
  if (req.method != 'GET') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  await jsonResponse(req.response, 200, <String, dynamic>{
    'ok': true,
    'records': _listVideoRecords(),
    'dir': 'jilmtshx',
    'canEdit': false,
  });
}

Future<void> handleDbVideoRecordDelete(HttpRequest req) async {
  if (req.method != 'POST') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  final body = await readJsonBody(req);
  final targets = <String>[];
  final nm = mStr(body, 'name').trim();
  if (nm.isNotEmpty) targets.add(nm);
  final names = body['names'];
  if (names is List) {
    for (final e in names) {
      final v = '$e'.trim();
      if (v.isNotEmpty) targets.add(v);
    }
  }
  final dir = _videoRecordDir();
  var removed = 0;
  final seen = <String>{};
  for (final name in targets) {
    if (!seen.add(name)) continue;
    if (name.contains('/') || name.contains('\\') || name.contains('..')) {
      continue;
    }
    if (!name.startsWith('video_') || !name.toLowerCase().endsWith('.sts')) {
      continue;
    }
    try {
      final f = File('$dir/$name');
      if (f.existsSync()) {
        f.deleteSync();
        removed++;
      }
    } catch (e) {
      logp('⚠️ 删除实时音视频记录失败 $name: $e');
    }
  }
  await jsonResponse(req.response, 200, <String, dynamic>{
    'ok': true,
    'removed': removed,
  });
}

Future<void> handleDbVideoRecordClear(HttpRequest req) async {
  if (req.method != 'POST') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  final dir = Directory(_videoRecordDir());
  var removed = 0;
  if (dir.existsSync()) {
    try {
      for (final f in dir.listSync().whereType<File>()) {
        final n = f.uri.pathSegments.isEmpty
            ? f.path
            : f.uri.pathSegments.last;
        if (!n.startsWith('video_') || !n.toLowerCase().endsWith('.sts')) {
          continue;
        }
        try {
          f.deleteSync();
          removed++;
        } catch (_) {}
      }
    } catch (e) {
      logp('⚠️ 清空实时音视频记录失败: $e');
    }
  }
  await jsonResponse(req.response, 200, <String, dynamic>{
    'ok': true,
    'removed': removed,
  });
}

/// 文字输入兜底：原生会话事件不响应时，用文本模型生成短答，再交给通话 TTS 朗读。
Future<void> handleDbVideoTextAnswer(HttpRequest req) async {
  if (req.method != 'POST') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  final body = await readJsonBody(req);
  final text = mStr(body, 'text').trim();
  if (text.isEmpty) {
    await errJson(req.response, 400, '文字内容为空');
    return;
  }
  final lang = trimOr(mStr(body, 'lang'), 'zh');
  final history = <Map<String, dynamic>>[];
  final rawHist = body['history'];
  if (rawHist is List) {
    for (final e in rawHist) {
      final m = _asMap(e);
      final role = mStr(m, 'role');
      final c = mStr(m, 'text');
      if (c.trim().isEmpty) continue;
      if (role != 'user' && role != 'assistant') continue;
      history.add(<String, dynamic>{
        'role': role,
        'content': c.length > 800 ? c.substring(c.length - 800) : c,
      });
    }
  }
  if (history.length > 8) history.removeRange(0, history.length - 8);
  history.add(<String, dynamic>{'role': 'user', 'content': text});
  try {
    final answer = await dbChatText(
      '${dbVideoSystemPrompt(lang)}\n'
      '当前是文字输入：用户打字，你负责用口语回答。不要提及这条系统说明。',
      history,
      maxTokens: 800,
      temperature: 0.6,
      timeout: const Duration(seconds: 45),
    );
    await jsonResponse(req.response, 200, <String, dynamic>{
      'ok': true,
      'text': answer.trim(),
    });
  } catch (e) {
    logp('❌ 实时音视频文字回答失败: $e');
    await errJson(req.response, 502, '文字回答生成失败：${dbErrText(e)}');
  }
}

Future<void> handleDbRealtimeVideoStatus(HttpRequest req) async {
  final cfg = getDbConfig();
  final hasKey = cfg.duplexApiKey.trim().isNotEmpty ||
      (cfg.s2sAppId.trim().isNotEmpty && cfg.s2sToken.trim().isNotEmpty);
  await jsonResponse(req.response, 200, <String, dynamic>{
    'ok': true,
    'video': <String, dynamic>{
      'available': hasKey,
      'url': dbRealtimeVideoUrl,
      'model': dbRealtimeVideoModel,
      'voices': dbRealtimeVoices,
      'defaultVoice': dbRealtimeDefaultVoice,
      'maxFps': 2,
      'historyDir': 'jilmtshx',
      'rates': <String, dynamic>{
        'voiceYuanPerMinute': dbVoiceYuanPerMinute,
        'videoYuanPerMinute': dbVideoYuanPerMinute,
      },
      'reason': hasKey
          ? ''
          : '实时音视频服务需要豆包语音控制台的 API Key（方舟 API Key 通常会 401）',
    },
  });
}

// ------------------------------------------------------------
// 火山引擎 V4 签名（HMAC-SHA256）
//   RTC OpenAPI 全部走这套签名；实现对齐官方文档的 SigV4 变体。
// ------------------------------------------------------------
String _hex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

String _sha256Hex(List<int> data) => _hex(sha256(data));

List<int> _hmac(List<int> key, List<int> msg) => hmacSha256(key, msg);

/// 生成请求签名头
Map<String, String> dbRtcSignHeaders({
  required String accessKey,
  required String secretKey,
  required String method,
  required String query,
  required String body,
}) {
  final now = DateTime.now().toUtc();
  final xDate =
      '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
      'T${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}Z';
  final date = xDate.substring(0, 8);
  final bodyHash = _sha256Hex(utf8.encode(body));

  const contentType = 'application/json';
  const signedHeaders = 'content-type;host;x-content-sha256;x-date';

  final canonicalHeaders = 'content-type:$contentType\n'
      'host:$dbRtcHost\n'
      'x-content-sha256:$bodyHash\n'
      'x-date:$xDate\n';

  final canonicalRequest =
      '$method\n/\n$query\n$canonicalHeaders\n$signedHeaders\n$bodyHash';

  final credentialScope = '$date/$dbRtcRegion/$dbRtcService/request';
  final stringToSign =
      'HMAC-SHA256\n$xDate\n$credentialScope\n${_sha256Hex(utf8.encode(canonicalRequest))}';

  var k = _hmac(utf8.encode(accessKey), utf8.encode(date));
  k = _hmac(k, utf8.encode(dbRtcRegion));
  k = _hmac(k, utf8.encode(dbRtcService));
  k = _hmac(k, utf8.encode('request'));
  final signature = _hex(_hmac(k, utf8.encode(stringToSign)));

  return <String, String>{
    'Content-Type': contentType,
    'Host': dbRtcHost,
    'X-Date': xDate,
    'X-Content-Sha256': bodyHash,
    'Authorization':
        'HMAC-SHA256 Credential=$accessKey/$credentialScope, '
            'SignedHeaders=$signedHeaders, Signature=$signature',
  };
}

/// 调用 RTC OpenAPI
Future<Map<String, dynamic>> dbRtcCall(String action, Map<String, dynamic> payload) async {
  final cfg = getDbConfig();
  final ak = cfg.rtcAccessKey.trim();
  final sk = cfg.rtcSecretKey.trim();
  if (ak.isEmpty || sk.isEmpty) {
    return <String, dynamic>{
      'ok': false,
      'error': 'RTC 的 AccessKey / SecretKey 未设置。请在设置界面输入。',
    };
  }
  final body = jsonEncode(payload);
  final query = 'Action=$action&Version=$dbRtcVersion';
  final uri = Uri.parse('https://$dbRtcHost/?$query');
  final headers = dbRtcSignHeaders(
    accessKey: ak,
    secretKey: sk,
    method: 'POST',
    query: query,
    body: body,
  );
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    final r = await client.postUrl(uri);
    headers.forEach(r.headers.set);
    r.add(utf8.encode(body));
    final resp = await r.close().timeout(const Duration(seconds: 40));
    final txt = await resp.transform(utf8.decoder).join();
    client.close();
    Object? parsed;
    try {
      parsed = jsonDecode(txt);
    } catch (_) {
      parsed = null;
    }
    final m = _asMap(parsed);
    final meta = _asMap(m['ResponseMetadata']);
    final errObj = meta['Error'];
    if (errObj != null) {
      final em = _asMap(errObj);
      return <String, dynamic>{
        'ok': false,
        'status': resp.statusCode,
        'code': _str(em['Code']),
        'error': '${_str(em['Code'])}: ${_str(em['Message'])}',
        'requestId': _str(meta['RequestId']),
      };
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      return <String, dynamic>{
        'ok': false,
        'status': resp.statusCode,
        'error': txt.length > 800 ? txt.substring(0, 800) : txt,
      };
    }
    return <String, dynamic>{
      'ok': true,
      'status': resp.statusCode,
      'requestId': _str(meta['RequestId']),
      'result': m['Result'] ?? m,
    };
  } catch (e) {
    return <String, dynamic>{'ok': false, 'error': dbErrText(e)};
  }
}

/// 组装 Seeduplex 的 RTC 任务配置（纯端到端 / 混合编排）
Map<String, dynamic> dbRtcTaskPayload(Map<String, dynamic> body) {
  final cfg = getDbConfig();
  final roomId = trimOr(mStr(body, 'roomId'), trimOr(cfg.rtcRoomId, ''));
  final taskId = trimOr(mStr(body, 'taskId'),
      'db_${fmtStamp14(DateTime.now())}_${DateTime.now().millisecondsSinceEpoch % 1000}');
  final userId = trimOr(mStr(body, 'userId'), 'dsc_user');
  final botUserId = trimOr(mStr(body, 'botUserId'), 'dsc_bot');
  // ★ 只消耗豆包语音通话额度：RTC 也强制纯端到端（S2S），禁止混合编成。
  //   混合编成会外挂方舟 LLM（走 cfg.apiKey + cfg.chatModel，消耗 ark 文本额度），
  //   违反「语音通话只能消耗端到端额度」的硬约束，故忽略 body.mixedMode。
  final voice = trimOr(mStr(body, 'voice'),
      trimOr(cfg.duplexVoice, cfg.voice));
  final lang = trimOr(mStr(body, 'lang'), 'zh');
  final instructions = trimOr(
      mStr(body, 'instructions'), trimOr(cfg.duplexInstructions, dbDuplexSystemPrompt(lang)));

  final s2s = <String, dynamic>{
    'Provider': 'volcano_duplex',
    'OutputMode': 0,
    'ProviderParams': <String, dynamic>{
      'app': <String, dynamic>{
        'appid': trimOr(mStr(body, 's2sAppId'), cfg.s2sAppId),
        'token': trimOr(mStr(body, 's2sToken'), cfg.s2sToken),
      },
      'session': <String, dynamic>{
        'instructions': instructions,
        'audio': <String, dynamic>{
          'output': <String, dynamic>{'voice': voice},
        },
      },
    },
  };

  final config = <String, dynamic>{
    'S2SConfig': s2s,
    // 使用字幕时必须为 1（快速字幕）
    'SubtitleConfig': <String, dynamic>{'SubtitleMode': 1},
  };

  return <String, dynamic>{
    'AppId': trimOr(mStr(body, 'rtcAppId'), cfg.rtcAppId),
    'RoomId': roomId,
    'TaskId': taskId,
    'AgentConfig': <String, dynamic>{
      'TargetUserId': <String>[userId],
      'UserId': botUserId,
    },
    'Config': config,
  };
}

// ------------------------------------------------------------
// HTTP 处理器
// ------------------------------------------------------------
/// POST /api/doubao/voice/save —— 保存一次语音通话的纯文本记录
///   请求体：{ "lines": ["时间戳|角色|文本|序号|语言", ...] }
///   写入：data/voice/voice_YYYYMMDD_HHMMSS.sts（一次通话 = 一个文件）
Future<void> handleDbVoiceSave(HttpRequest req) async {
  if (req.method != 'POST') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  final body = await readJsonBody(req);
  final linesRaw = body['lines'];
  if (linesRaw is! List || linesRaw.isEmpty) {
    await errJson(req.response, 400, '没有可保存的通话记录');
    return;
  }
  try {
    final dir = '$DATA_DIR/voice';
    ensureDir(dir);
    // 秒级时间戳 + 随机后缀：避免两次通话在同一秒挂断时文件互相覆盖
    final fileName = 'voice_${fmtStamp14(DateTime.now())}_${randomHex(6)}.sts';
    final file = File('$dir/$fileName');
    final sb = StringBuffer();
    for (final l in linesRaw) {
      // 每行已经是「数据1|数据2|数据3|数据4|数据5」，直接写入
      sb.writeln('$l');
    }
    file.writeAsStringSync(sb.toString());
    await jsonResponse(req.response, 200, <String, dynamic>{
      'ok': true,
      'file': fileName,
      'path': '$dir/$fileName',
      'count': linesRaw.length,
    });
  } catch (e) {
    logp('❌ 通话记录保存失败: $e');
    await errJson(req.response, 500, '通话记录保存失败：$e');
  }
}

/// 读取 data/voice 下所有 .sts 通话记录，返回文件名 + 解析后的行内容
List<Map<String, dynamic>> _listVoiceRecords() {
  final dir = Directory('$DATA_DIR/voice');
  final out = <Map<String, dynamic>>[];
  if (!dir.existsSync()) return out;
  try {
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.sts'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path)); // 新在前
    for (final f in files) {
      try {
        final name = f.uri.pathSegments.isNotEmpty
            ? f.uri.pathSegments.last
            : f.path;
        final lines = <String>[];
        var preview = '';
        for (final raw in f.readAsStringSync().split('\n')) {
          final t = raw.trim();
          if (t.isEmpty) continue;
          lines.add(t);
        }
        // 预览：取第一条 user 文本的前 40 字
        for (final l in lines) {
          final parts = l.split('|');
          if (parts.length >= 3 && parts[1] == 'user') {
            preview = parts[2];
            if (preview.length > 40) preview = preview.substring(0, 40) + '…';
            break;
          }
        }
        if (preview.isEmpty && lines.isNotEmpty) {
          preview = lines.first;
          if (preview.length > 40) preview = preview.substring(0, 40) + '…';
        }
        out.add(<String, dynamic>{
          'name': name,
          'preview': preview,
          'lineCount': lines.length,
          'lines': lines,
          'mtime': f.statSync().modified.millisecondsSinceEpoch,
        });
      } catch (_) {}
    }
  } catch (e) {
    logp('⚠️ 读取通话记录失败: $e');
  }
  return out;
}

/// GET /api/doubao/voice/list —— 列出全部历史通话记录（只读）
Future<void> handleDbVoiceList(HttpRequest req) async {
  if (req.method != 'GET') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  await jsonResponse(req.response, 200, <String, dynamic>{
    'ok': true,
    'records': _listVoiceRecords(),
  });
}

/// POST /api/doubao/voice/delete —— 删除通话记录（单选/批量，真实删除文件）
///   请求体：{ "names": ["a.sts", "b.sts"] } 或 { "name": "a.sts" }
Future<void> handleDbVoiceDelete(HttpRequest req) async {
  if (req.method != 'POST') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  final body = await readJsonBody(req);
  final dir = '$DATA_DIR/voice';
  var removed = 0;
  var targets = <String>[];
  final nm = mStr(body, 'name').trim();
  if (nm.isNotEmpty) targets.add(nm);
  final names = body['names'];
  if (names is List) {
    for (final e in names) {
      final v = '$e'.trim();
      if (v.isNotEmpty) targets.add(v);
    }
  }
  // 去重
  final seen = <String>{};
  final uniq = <String>[];
  for (final t in targets) {
    if (seen.add(t)) uniq.add(t);
  }
  for (final name in uniq) {
    // 防路径穿越：只允许纯文件名
    if (name.contains('/') || name.contains('\\') || name.contains('..')) continue;
    if (!name.toLowerCase().endsWith('.sts')) continue;
    final f = File('$dir/$name');
    try {
      if (f.existsSync()) {
        f.deleteSync();
        removed++;
      }
    } catch (e) {
      logp('⚠️ 删除通话记录失败 $name: $e');
    }
  }
  await jsonResponse(req.response, 200, <String, dynamic>{
    'ok': true,
    'removed': removed,
  });
}

/// POST /api/doubao/voice/clear —— 一键删除全部通话记录（真实删除文件）
Future<void> handleDbVoiceClear(HttpRequest req) async {
  if (req.method != 'POST') {
    await errJson(req.response, 405, 'Method not allowed');
    return;
  }
  final dir = Directory('$DATA_DIR/voice');
  var removed = 0;
  if (dir.existsSync()) {
    try {
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.toLowerCase().endsWith('.sts')) continue;
        try {
          f.deleteSync();
          removed++;
        } catch (_) {}
      }
    } catch (e) {
      logp('⚠️ 清空通话记录失败: $e');
    }
  }
  await jsonResponse(req.response, 200, <String, dynamic>{
    'ok': true,
    'removed': removed,
  });
}

/// GET /api/doubao/realtime/status —— 实时语音配置就绪度
Future<void> handleDbRealtimeStatus(HttpRequest req) async {
  final cfg = getDbConfig();
  await jsonResponse(req.response, 200, <String, dynamic>{
    'ok': true,
    'duplex': <String, dynamic>{
      'available': cfg.duplexApiKey.trim().isNotEmpty,
      'url': dbDuplexUrl,
      'model': dbDuplexModel,
      'voice': trimOr(cfg.duplexVoice, cfg.voice),
      'hasDuplexKey': cfg.duplexApiKey.trim().isNotEmpty,
      'reason': cfg.duplexApiKey.trim().isNotEmpty
          ? ''
          : '端到端语音服务需要另外提供豆包语音控制台的 API Key'
              '（用方舟的 API Key 会返回 401）',
    },
    'rtc': <String, dynamic>{
      'available': cfg.rtcAppId.trim().isNotEmpty &&
          cfg.rtcAccessKey.trim().isNotEmpty &&
          cfg.rtcSecretKey.trim().isNotEmpty &&
          cfg.s2sAppId.trim().isNotEmpty &&
          cfg.s2sToken.trim().isNotEmpty,
      'appId': cfg.rtcAppId,
      'roomId': cfg.rtcRoomId,
      'region': dbRtcRegion,
      'version': dbRtcVersion,
      'reason': _rtcMissing(cfg),
    },
  });
}

String _rtcMissing(DbConfig cfg) {
  final miss = <String>[];
  if (cfg.rtcAppId.trim().isEmpty) miss.add('RTC AppId');
  if (cfg.rtcAccessKey.trim().isEmpty) miss.add('AccessKey');
  if (cfg.rtcSecretKey.trim().isEmpty) miss.add('SecretKey');
  if (cfg.s2sAppId.trim().isEmpty) miss.add('S2S AppId');
  if (cfg.s2sToken.trim().isEmpty) miss.add('S2S Token');
  if (cfg.rtcRoomId.trim().isEmpty) miss.add('RoomId');
  return miss.isEmpty ? '' : '未設定：${miss.join(' / ')}';
}

/// POST /api/doubao/rtc/start —— 启动 RTC 语音智能体任务
Future<void> handleDbRtcStart(HttpRequest req) async {
  final body = await readJsonBody(req);
  final payload = dbRtcTaskPayload(body);
  if ('${payload['AppId']}'.trim().isEmpty) {
    await errJson(req.response, 400, 'RTC AppId 未设置');
    return;
  }
  if ('${payload['RoomId']}'.trim().isEmpty) {
    await errJson(req.response, 400, 'RoomId 未设置（请在设置界面或请求中指定）');
    return;
  }
  final r = await dbRtcCall('StartVoiceChat', payload);
  await jsonResponse(req.response, r['ok'] == true ? 200 : 400, <String, dynamic>{
    'success': r['ok'] == true,
    'taskId': payload['TaskId'],
    'requestId': r['requestId'] ?? '',
    'error': r['error'] ?? '',
    'result': r['result'],
  });
}

/// POST /api/doubao/rtc/stop —— 停止 RTC 语音智能体任务
Future<void> handleDbRtcStop(HttpRequest req) async {
  final body = await readJsonBody(req);
  final cfg = getDbConfig();
  final appId = trimOr(mStr(body, 'rtcAppId'), cfg.rtcAppId);
  final roomId = trimOr(mStr(body, 'roomId'), cfg.rtcRoomId);
  final taskId = mStr(body, 'taskId').trim();
  if (appId.isEmpty || roomId.isEmpty || taskId.isEmpty) {
    await errJson(req.response, 400, '需要 AppId / RoomId / TaskId');
    return;
  }
  final r = await dbRtcCall('StopVoiceChat', <String, dynamic>{
    'AppId': appId,
    'RoomId': roomId,
    'TaskId': taskId,
  });
  await jsonResponse(req.response, r['ok'] == true ? 200 : 400, <String, dynamic>{
    'success': r['ok'] == true,
    'requestId': r['requestId'] ?? '',
    'error': r['error'] ?? '',
    'result': r['result'],
  });
}
