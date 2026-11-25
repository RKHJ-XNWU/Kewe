// ============================================================
// doubao_video_ark.dart —— 豆包（火山方舟）大视频理解通道（最大 2GB）
//
// 背景（全部为实测结论，不含推测）
//   1) Chat API 的 video_url 支持两种传法：
//        · 公网 URL / base64  —— 官方限制：文件 ≤ 50MB、请求体 ≤ 64MB
//        · file_id（Files API）—— 官方限制：托管存储 512MB、TOS 2GB
//   2) 本项目的旧实现是 readAsBytesSync + base64，并在 40MB 处硬拦截，
//      2GB 视频走这条路必然 OOM（base64 膨胀 33%，JSON 再复制一份）。
//   3) 实测本机这把豆包 API Key：
//        · POST /files 上传成功（不带 preprocess_configs[video][model] 时 200）
//        · 上传带 model 字段 → 400 "Project is invalid / param: project_name"
//        · 上传拿到的 file_id 在 /chat/completions 与 /responses 中引用
//          → 404 "The specified resource file is not found"
//      也就是说：Files API 与推理通道在当前账号下不互通（需要 project 级
//      Key / TOS 授权）。因此不能把 file_id 作为主路径。
//   4) 实测 base64 video_url 通道在本账号完全可用（视频内容被正确描述）。
//
// 因此当前主路径（2026-11-25 定稿）是「整片直传 + 单次预处理」：
//   · 每个视频原样整片上传到用户 TOS（单文件上限 2GB），
//     由方舟完成预处理，再以 file_id 作为 video_url 输入送给模型。
//   · fps 一律用配置值（默认 5.0），不自动降帧；不重试；不切片、不分段。
//   · 本地绝不改写视频内容，也不把长视频拆成几十段再汇总 ——
//     分段汇总得到的是二手描述，细节必然与原片偏离，这正是
//     「模型理解内容跟原片差很多」的根因。
//
// 已实测的服务端行为（本账号 ark-c94a…，桶 large-video-understand-000）：
//   · 1.7MB HEVC / 10.1MB x264 / 25.7MB HEVC(5s) → status=active（4~13 秒）
//   · 93.6MB HEVC 1080p 23分42秒（fps=5 与 fps=2.5）→
//     InvalidArgumentError("Timeout occurred while processing video")
//   · 226.8MB 长视频同样失败（fps=0.5 也一样失败）
//   · 同片 5 / 10 / 15 分钟（25.7MB / 46.6MB / 65.4MB，fps=5）→ 全部 active
//   · 同片 20 分钟 81.5MB（fps=5）→ failed（同样那条 Timeout）
//   · 23 分 42 秒那条加上 max_video_tokens=128000 → 依然 failed
//   → 结论：方舟对「单视频时长」有硬上限，约 15 分钟。超过就一律报
//     "Timeout occurred while processing video"，与体积、fps、token 预算
//     都无关；降帧重试对这类失败毫无帮助，只会让用户多等一轮。
//     整片预处理能否完成由方舟服务端判定，客户端只负责原样送达并等足够久
//     （见 dbArkPreprocessTimeoutFor），失败时如实报错、不降级改写。
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ds_crypto.dart';
import 'doubao.dart';
import 'files.dart';
import 'globals.dart';
import 'net.dart';
import 'ds_usage.dart';

/// 对外承诺的最大视频体积：2GB
const int dbVideoMaxBytes = 2 * 1024 * 1024 * 1024;

/// base64 通道的硬限制（官方：文件 ≤50MB、请求体 ≤64MB）
const int dbVideoBase64HardMaxBytes = 50 * 1024 * 1024;

/// 单片默认上限：留 5MB 余量给 JSON / 文本
const int dbVideoDefaultSegmentBytes = 45 * 1024 * 1024;

/// 方舟「平台托管存储」的单文件上限：512MB（仅 Files API 路径使用）
const int dbArkStorageMaxBytes = 512 * 1024 * 1024;

/// 火山引擎 TOS 通道的单文件上限：2GB（仅 Files API 路径使用）
const int dbArkTosMaxBytes = 2 * 1024 * 1024 * 1024;

/// 方舟文件默认保留 7 天，本地缓存按 6 天失效
const int _dbArkFileTtlMs = 6 * 24 * 3600 * 1000;

/// 单文件预处理超时/被拒的「失败记忆」有效期。
/// 命中后同一文件不再白传一次大文件，直接走无损切片通道。
const int _dbArkSlowPathTtlMs = 6 * 24 * 3600 * 1000;

/// 单文件预处理的抽帧预算（默认 24000 帧）。
///
/// 为什么需要它：方舟把「预处理处理不过来」统一报成
/// InvalidArgumentError("Timeout occurred while processing video …")。
/// 抽帧总量 = 时长 × fps，fps=5 时一条 20 分钟的视频就是 6000 帧，
/// 一条 1 小时的是 18000 帧，服务端预处理时窗被抽帧拖爆。
/// 所以真正要压的是「帧数」，不是「字节数」——同样 100MB，
/// 高码率短视频抽帧少、超时概率低；低码率长视频抽帧多、必超时。
/// 这是本项目自己的保守预算（非官方硬性数值），可在
/// doubao_video_ark.json 里改 frameBudget，0 表示不限制。
const int dbArkFrameBudgetDefault = 24000;

/// frameBudget 归一化：负数/0 视为不限制，过小的值没有意义。
int _dbArkNormalizeFrameBudget(int v) {
  if (v <= 0) return 0;
  if (v < 100) return 100;
  if (v > 200000) return 200000;
  return v;
}

/// 单文件预处理等待上限：按体积自适应。
/// 小文件不必白等 40 分钟；2GB 级文件也不该被固定超时提前掐断。
Duration dbArkPreprocessTimeoutFor(int bytes) {
  // 整片直传时服务端要把全片解码并抽帧，等待窗口必须给足。
  // 45 分钟基础 + 每 GB 60 分钟，上限 6 小时（客户端等待上限；
  // 方舟自身的预处理超时会先返回 failed，这里只负责不提前放弃）。
  var sec = 45 * 60;
  final gb = bytes <= 0 ? 0.0 : bytes / (1024 * 1024 * 1024);
  sec += (gb * 60 * 60).round();
  if (sec > 6 * 3600) sec = 6 * 3600;
  return Duration(seconds: sec);
}


// ------------------------------------------------------------
// 异常
// ------------------------------------------------------------
class DbVideoArkException implements Exception {
  final String message;
  final String code;
  DbVideoArkException(this.message, {this.code = 'failed'});

  @override
  String toString() => message;
}

// ------------------------------------------------------------
// 配置：data/deepseek_chat/doubao_video_ark.json
// ------------------------------------------------------------
String get dbVideoArkConfigPath => '$dsChatDir/doubao_video_ark.json';

class DbVideoArkConfig {
  /// 允许的最大视频体积（默认 2GB）
  int maxBytes;

  /// 抽帧密度（0.2 ~ 5）。分段描述时用小值可显著省 token。
  double fps;

  /// 单片上限（MB 级概念，默认 45MB，必须 < 50MB）
  int segmentMaxBytes;

  /// 是否优先尝试 Files API（file_id）通道。
  /// 默认 false：实测当前 Key 的 file_id 无法被推理端引用（404）。
  bool useFilesApi;

  /// Files API 通道：火山 TOS Bucket（填了才启用 2GB 直传）
  String tosBucket;

  /// Files API 通道：TOS 对象前缀
  String tosPrefix;

  /// Files API 通道：超过 512MB 且无 TOS 时用 ffmpeg 压缩后再上传
  bool autoCompact;

  /// Files API 通道：preprocess_configs[video][model]
  /// 默认留空（实测未绑定 project 的 Key 传了会 400）
  String preprocessModel;

  /// 视频抽帧上限(透传 preprocess_configs[video][max_video_tokens];0=不传)
  int maxVideoTokens;

  /// 最少抽帧数(透传 preprocess_configs[video][min_frames];0=不传)
  int minFrames;

  /// 单文件/单段预处理的抽帧预算（帧）。0 = 不限制。
  /// 旧版会自动下调 fps；当前策略禁止降帧，该字段仅为兼容保留。
  int frameBudget;

  /// 是否把「视频理解输出规范」注入提示词（默认 true）。
  ///
  /// ★ 这才是「模型理解视频细节不全、跟原片差很多」的直接原因：
  ///   旧实现只把用户那一句原话发给模型，从未要求它按时间轴穷举细节，
  ///   模型自然只给一段概括。规范要求：按时间轴逐段、画面文字原样抄录、
  ///   台词原样抄录、数字专名准确、不设字数上限、禁止概括跳过。
  bool promptEnabled;

  /// 旧版 TOS 自动上传字段，保留兼容；当前 TOS 通道走 Files API
  /// 的二进制上传 + tos[bucket]/tos[prefix]，不需要 TOS AK/SK。
  String tosAccessKey;

  /// 旧版 TOS SecretKey，保留兼容
  String tosSecretKey;

  /// 旧版 TOS Endpoint（保留兼容；当前不使用）
  String tosEndpoint;

  /// 旧版 TOS Region（保留兼容；当前不使用）
  String tosRegion;

  DbVideoArkConfig({
    this.maxBytes = dbVideoMaxBytes,
    this.fps = 1.0,
    this.segmentMaxBytes = dbVideoDefaultSegmentBytes,
    this.useFilesApi = false,
    this.tosBucket = '',
    this.tosPrefix = '',
    this.autoCompact = true,
    this.preprocessModel = '',
    this.maxVideoTokens = 0,
    this.minFrames = 0,
    this.frameBudget = dbArkFrameBudgetDefault,
    this.promptEnabled = true,
    this.tosAccessKey = '',
    this.tosSecretKey = '',
    this.tosEndpoint = 'tos-cn-beijing.volces.com',
    this.tosRegion = 'cn-beijing',
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        '_comment': '豆包大视频理解配置。maxBytes 为对外上限（≤2GB）；'
            'fps 为抽帧密度（0.2~5，分段描述建议 0.5~1）；'
            'segmentMaxBytes 为单片上限（必须 <50MB，默认 45MB）；'
            'useFilesApi=true 时会优先尝试 Files API（需要 project 级 Key / TOS）；'
            'tosBucket/tosPrefix 仅 Files API 通道使用。',
        'maxBytes': maxBytes,
        'fps': fps,
        'segmentMaxBytes': segmentMaxBytes,
        'useFilesApi': useFilesApi,
        'tosBucket': tosBucket,
        'tosPrefix': tosPrefix,
        'autoCompact': autoCompact,
        'preprocessModel': preprocessModel,
        'maxVideoTokens': maxVideoTokens,
        'minFrames': minFrames,
        'frameBudget': frameBudget,
        'promptEnabled': promptEnabled,
        'tosAccessKey': tosAccessKey,
        'tosSecretKey': tosSecretKey,
        'tosEndpoint': tosEndpoint,
        'tosRegion': tosRegion,
      };

  static DbVideoArkConfig fromJson(Map<String, dynamic> j) {
    var maxBytes = intArgDefault(j, 'maxBytes', dbVideoMaxBytes);
    if (maxBytes <= 0 || maxBytes > dbVideoMaxBytes) maxBytes = dbVideoMaxBytes;

    var fps = 1.0;
    final rawFps = j['fps'];
    if (rawFps is num) {
      fps = rawFps.toDouble();
    } else if (rawFps is String) {
      fps = double.tryParse(rawFps.trim()) ?? 1.0;
    }
    if (fps < 0.2) fps = 0.2;
    if (fps > 5) fps = 5;

    var seg = intArgDefault(j, 'segmentMaxBytes', dbVideoDefaultSegmentBytes);
    // 必须小于 base64 硬上限，且不能小到切出太多段。
    // 注意：segmentMaxBytes 只管「分段后每段多大」，与「单文件能不能走
    // TOS 2GB 直传」无关；写 2GB 在这里会被无损钳制回 45MB（base64 上限
    // 是 50MB 请求体，物理上不可能一段 2GB）。钳制时明确打日志，避免
    // 配置看起来生效、实际没生效。
    if (seg > dbVideoBase64HardMaxBytes - 1024 * 1024) {
      logp('⚠️ segmentMaxBytes=$seg 超过分段上限，已回退为 '
          '${dbFmtSize(dbVideoDefaultSegmentBytes)}'
          '（该值只管分段大小，单文件 TOS 上限由 maxBytes 决定）');
      seg = dbVideoDefaultSegmentBytes;
    }
    if (seg < 5 * 1024 * 1024) seg = dbVideoDefaultSegmentBytes;

    return DbVideoArkConfig(
      maxBytes: maxBytes,
      fps: fps,
      segmentMaxBytes: seg,
      useFilesApi: mBool(j, 'useFilesApi', false),
      tosBucket: mStr(j, 'tosBucket').trim(),
      tosPrefix: mStr(j, 'tosPrefix').trim(),
      autoCompact: mBool(j, 'autoCompact', true),
      preprocessModel: mStr(j, 'preprocessModel').trim(),
      maxVideoTokens: intArgDefault(j, 'maxVideoTokens', 0),
      minFrames: intArgDefault(j, 'minFrames', 0),
      frameBudget: _dbArkNormalizeFrameBudget(
          intArgDefault(j, 'frameBudget', dbArkFrameBudgetDefault)),
      promptEnabled: mBool(j, 'promptEnabled', true),
      tosAccessKey: mStr(j, 'tosAccessKey').trim(),
      tosSecretKey: mStr(j, 'tosSecretKey').trim(),
      tosEndpoint: trimOr(mStr(j, 'tosEndpoint'), 'tos-cn-beijing.volces.com'),
      tosRegion: trimOr(mStr(j, 'tosRegion'), 'cn-beijing'),
    );
  }
}

DbVideoArkConfig? _cfgCache;
int _cfgCacheStamp = -1;

/// 读取配置；文件不存在时自动落一份模板
DbVideoArkConfig dbVideoArkConfig() {
  final f = File(dbVideoArkConfigPath);
  var stamp = 0;
  if (f.existsSync()) {
    try {
      stamp = f.lastModifiedSync().millisecondsSinceEpoch;
    } catch (_) {}
  }
  final cached = _cfgCache;
  if (cached != null && stamp == _cfgCacheStamp && stamp != 0) return cached;

  if (!f.existsSync()) {
    final def = DbVideoArkConfig();
    try {
      ensureDir(dsChatDir);
      f.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(def.toJson()));
      logp('🧩 已创建豆包大视频配置: $dbVideoArkConfigPath');
    } catch (e) {
      logp('⚠️ 无法创建豆包大视频配置文件: $e');
    }
    _cfgCache = def;
    _cfgCacheStamp = 0;
    return def;
  }

  try {
    final j = asMap(jsonDecode(f.readAsStringSync()));
    final cfg = DbVideoArkConfig.fromJson(j);
    _cfgCache = cfg;
    _cfgCacheStamp = stamp;
    return cfg;
  } catch (e) {
    logp('⚠️ 豆包大视频配置解析失败（使用默认值）: $e');
    final def = DbVideoArkConfig();
    _cfgCache = def;
    _cfgCacheStamp = stamp;
    return def;
  }
}

/// 体积格式化
String dbFmtSize(num bytes) {
  final b = bytes.toDouble();
  if (b >= 1024 * 1024 * 1024) {
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
  if (b >= 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${b.toInt()} B';
}


// ------------------------------------------------------------
// 单文件预处理失败判定 + 失败记忆
// ------------------------------------------------------------

/// 方舟把「源文件体量超出预处理能力」统一报成
/// InvalidArgumentError("Timeout occurred while processing video. ...")。
///
/// 实测（2026-11-25，本账号 ark-c94a…，桶 large-video-understand-000）：
///   · studio_video_1795563651880.mp4 = 237,871,791 字节（226.8MB）
///     fps=5   → status=failed，Timeout occurred while processing video
///     fps=0.5 → 同一文件同样 failed（抽帧密度降到 1/10 也没用）
///   · share_5ac575….mp4 = 5,727,114 字节，同桶同模型同 fps=5 → status=active
/// 结论：TOS 授权正常、文件本身也正常；卡住的只是「单文件体量」。
/// 这类失败必须降级成无损切片，而不是甩给用户去查授权。
/// 严格判定：只认「服务端处理超时」这一种。
///
/// ★ 2026-11-25 二次修复：旧实现把 invalidarg / invalidparam 也算超时，
///   于是任何 400 InvalidParameter（模型没绑 project、桶权限不足、参数拼错）
///   都会被写成「体量超时」的失败记忆，进而把所有大文件永久判死。
///   参数错误与体量问题必须分开：参数错误该修配置，体量问题该降抽帧。
bool dbArkIsPreprocessTimeout(Object e) {
  final s = e.toString().toLowerCase();
  return s.contains('timeout') || s.contains('超时') || s.contains('timed out');
}


String get _dbArkSlowPathFile => '$dsChatDir/doubao_ark_slowpath.sts';

Map<String, dynamic> _dbArkSlowPathLoad() {
  final f = File(_dbArkSlowPathFile);
  if (!f.existsSync()) return <String, dynamic>{};
  try {
    return asMap(jsonDecode(f.readAsStringSync()));
  } catch (_) {
    return <String, dynamic>{};
  }
}


void _dbArkSlowPathRemember(String key, String reason,
    {int bytes = 0, double fps = 0}) {
  final all = _dbArkSlowPathLoad();
  all[key] = <String, dynamic>{
    'at': DateTime.now().millisecondsSinceEpoch,
    'bytes': bytes,
    'fps': fps,
    'reason': reason.length > 300 ? reason.substring(0, 300) : reason,
  };
  final now = DateTime.now().millisecondsSinceEpoch;
  all.removeWhere((_, v) {
    final e = asMap(v);
    return now - intArgDefault(e, 'at', 0) >= _dbArkSlowPathTtlMs;
  });
  try {
    ensureDir(dsChatDir);
    File(_dbArkSlowPathFile).writeAsStringSync(jsonEncode(all));
  } catch (e) {
    logp('⚠️ 预处理失败记忆写入失败: $e');
  }
}

// ★ 2026-11-25 二次修复：这里原本有一个 _dbArkSlowPathMinFailBytes()，
//   把「历史失败样本的最小体积」当成全局阈值：只要某个文件曾经失败，
//   之后任何 ≥ 该体积的文件都会被直接判成「必然超时」，连上传都不试，
//   直接走切片 —— 这就是「明明 TOS 支持 2GB，却报单文件预处理失败」的
//   关键原因之一。用「一次失败」推「同体积全失败」在统计上也不成立：
//   真正决定预处理耗时的是抽帧总量与编码复杂度，不是字节数。
//   现已删除：大文件照样先试单文件 TOS，失败再降抽帧重试，仍失败才切片。


String _dbVideoMime(String name) {
  final e = name.toLowerCase();
  if (e.endsWith('.avi')) return 'video/x-msvideo';
  if (e.endsWith('.mov')) return 'video/quicktime';
  return 'video/mp4';
}

String _dbFpsStr(double fps) {
  if (fps == fps.roundToDouble()) return '${fps.toInt()}';
  final s = fps.toStringAsFixed(2);
  return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}


String _dbErrText(List<int> bytes) {
  final t = utf8.decode(bytes, allowMalformed: true).trim();
  if (t.length <= 600) return t;
  return '${t.substring(0, 600)}…';
}

// ============================================================
// 主入口：为聊天准备视频内容
//   返回 parts（要随主请求发送的视频片段，小视频才有）
//      + text（大视频的分段理解结果，拼进 user prompt）
// ============================================================
Future<({List<Map<String, dynamic>> parts, String text})>
    dbVideoContentForChat({
  required List<String> videoFileIds,
  required String model,
  required String apiKey,
  void Function(Map<String, dynamic> info)? onProgress,
}) async {
  final parts = <Map<String, dynamic>>[];
  final blocks = <String>[];
  if (videoFileIds.isEmpty) return (parts: parts, text: '');

  final cfg = dbVideoArkConfig();
  var index = 0;
  for (final id in videoFileIds) {
    final meta = getDsFileMeta(id);
    if (meta == null) {
      logp('⚠️ 未找到视频元数据（不发送）: $id');
      continue;
    }
    var absPath = '$DSFilesBlobDir/${meta.relPath}';
    var f = File(absPath);
    if (!f.existsSync()) {
      logp('⚠️ 视频文件不存在（不发送）: ${meta.name}');
      continue;
    }
    final size = meta.size > 0 ? meta.size : f.lengthSync();
    Directory? decryptedTempDir;
    try {
      if (dsIsEncryptedFile(absPath)) {
        f = await dsDecryptFileToTemp(absPath, hintName: meta.name);
        decryptedTempDir = f.parent;
        absPath = f.path;
      }
    } catch (e) {
      logp('⚠️ 视频解密失败（不发送）: ${meta.name} ($e)');
      continue;
    }
    if (size > cfg.maxBytes) {
      throw DbVideoArkException(
          '视频超过上限 ${dbFmtSize(cfg.maxBytes)}（当前 ${dbFmtSize(size)}）：${meta.name}',
          code: 'too_large');
    }
    if (size <= 0) {
      throw DbVideoArkException('视频文件为空：${meta.name}', code: 'empty');
    }
    final tag = <String, dynamic>{
      'index': index,
      'count': videoFileIds.length,
      'fileName': meta.name,
    };

    // ---------- 按「帧上限」决策 ----------
    //
    // ★ 2026-11-25 四次修复。旧版是「整片直传、绝不分段」，结果 20 分钟
    //   以上的片子一律撞方舟预处理超时，用户只能看到失败；而当时代码为
    //   了"避免丢细节"完全不提供任何兜底，于是「视频理解不成功」成了必然。
    //
    //   本机现场实测（账号 ark-c94a…、桶 large-video-understand-000、
    //   模型 doubao-seed-2-1-lite-260915、fps=5、同一源片 HEVC 1080p）：
    //     · 30 秒   → active   4 秒
    //     · 5 分钟  → active  13 秒
    //     · 12 分钟 → active  17 秒   （3600 帧）
    //     · 20 分钟 → failed  21 秒   Timeout occurred while processing video
    //     · 20 分钟 + max_video_tokens=131072 → 仍然 failed（参数救不了）
    //     · 一次请求装 5 段（合计 6169 帧）→
    //       "number of the input image (6169) exceeds the limit (3600)"
    //
    //   两条硬边界因此确定：
    //     A. 单文件预处理：12 分钟（3600 帧）能过，20 分钟必超时；
    //     B. chat 单请求：输入帧数上限 3600（官方限制，与体积/授权/编码无关）。
    //   两者同一个数：3600 帧。所以 fps=5 时，12 分钟以内的视频可以
    //   真正「整片一次看完」；超过 12 分钟的视频，帧数总量已经超过模型
    //   单次能接收的上限，物理上无法塞进一次请求。
    //
    //   于是策略变成：≤3600 帧 → 整片直传（不分段、不降帧、不重试）；
    //   >3600 帧 → 等分切段，但每段仍是 fps=5 的完整转写（不是摘要），
    //   按全片时间轴拼接成一份连续记录。这样既守住 fps=5，也守住细节。
    if (cfg.tosBucket.trim().isEmpty) {
      throw DbVideoArkException(
          '未配置 tosBucket：视频直传需要 TOS Bucket（≥50MB 的视频无法走 '
          'base64）：${meta.name}（${dbFmtSize(size)}）',
          code: 'tos_not_configured');
    }
    final dur = await _dbProbeDurationSec(f);
    final segCount = dbArkPlanSegCount(dur, cfg.fps);
    if (segCount <= 1) {
      onProgress?.call({...tag, 'stage': 'tos_reference', 'size': size});
      final part = await dbArkVideoPartForLocalFile(
        absPath: absPath,
        fileName: meta.name,
        model: model,
        apiKey: apiKey,
        onProgress: (info) => onProgress?.call({...tag, ...info}),
      );
      parts.add(part);
      logp('🎬 整片直传（未分段）: ${meta.name}（${dbFmtSize(size)}，'
          '${_dbClock(dur)} × ${_dbFpsStr(cfg.fps)} fps'
          ' = ${(dur * cfg.fps).round()} 帧）');
      index++;
      if (decryptedTempDir != null) {
        try { decryptedTempDir.deleteSync(recursive: true); } catch (_) {}
      }
      continue;
    }
    logp('🎬 ${meta.name}: ${_dbClock(dur)} × ${_dbFpsStr(cfg.fps)} fps'
        ' = ${(dur * cfg.fps).round()} 帧 > 方舟单请求上限 '
        '$dbArkFrameLimitPerRequest 帧 → 等分 $segCount 段，'
        '每段 ${_dbClock(dur / segCount)}（fps 仍为 ${_dbFpsStr(cfg.fps)}）');
    onProgress?.call({...tag, 'stage': 'seg_split', 'size': size,
        'segments': segCount});
    final desc = await dbDescribeVideoInSegments(
      file: f,
      fileName: meta.name,
      cfg: cfg,
      apiKey: apiKey,
      segCount: segCount,
      duration: dur,
      onProgress: (info) => onProgress?.call({...tag, ...info}),
    );
    blocks.add(desc);
    index++;
    if (decryptedTempDir != null) {
      try { decryptedTempDir.deleteSync(recursive: true); } catch (_) {}
    }
  }
  return (parts: parts, text: blocks.join('\n\n'));
}


// ============================================================
// 以下为 Files API（file_id / TOS）通道：配置了 TOS Bucket 后强制使用，不回退本地
// ============================================================
Map<String, dynamic> dbArkVideoPartByFileId(String fileId, {double? fps}) {
  // ★ 方舟 Chat API 引用 Files API 视频 file_id 的正确类型是 video_url：
  //   {"type":"video_url","video_url":{"file_id":"..."}}
  //   video_url 对象里只放 file_id，不能放 fps（fps 已在 Files API 预处理阶段
  //   通过 preprocess_configs[video][fps] 设置）。
  //   此前误用 file 类型（file 仅用于 pdf 文档抽取），触发
  //   "The provided file ... type is not pdf"；更早误带 fps 触发 400。
  return <String, dynamic>{
    'type': 'video_url',
    'video_url': <String, dynamic>{'file_id': fileId},
  };
}

String get _dbArkCachePath => '$dsChatDir/doubao_ark_files.sts';

Map<String, dynamic> _dbArkCacheLoad() {
  final f = File(_dbArkCachePath);
  if (!f.existsSync()) return <String, dynamic>{};
  try {
    return asMap(jsonDecode(f.readAsStringSync()));
  } catch (_) {
    return <String, dynamic>{};
  }
}

void _dbArkCacheSave(Map<String, dynamic> m) {
  try {
    ensureDir(dsChatDir);
    File(_dbArkCachePath).writeAsStringSync(jsonEncode(m));
  } catch (e) {
    logp('⚠️ 豆包 ark file_id 缓存保存失败: $e');
  }
}

String _dbArkCacheKey(File f, int size) {
  var mt = 0;
  try {
    mt = f.lastModifiedSync().millisecondsSinceEpoch;
  } catch (_) {}
  return '${f.path}|$size|$mt';
}

String? _dbArkCacheLookup(String key, double fps) {
  final raw = _dbArkCacheLoad()[key];
  if (raw is Map) {
    final e = asMap(raw);
    final id = mStr(e, 'arkFileId');
    final at = intArgDefault(e, 'at', 0);
    final sameFps =
        ((e['fps'] is num) ? (e['fps'] as num).toDouble() : -1) == fps;
    final fresh =
        DateTime.now().millisecondsSinceEpoch - at < _dbArkFileTtlMs;
    if (id.isNotEmpty && fresh && sameFps) return id;
  }
  return null;
}

void _dbArkCacheStore(String key, String arkFileId, String model, double fps) {
  final all = _dbArkCacheLoad();
  all[key] = <String, dynamic>{
    'arkFileId': arkFileId,
    'model': model,
    'fps': fps,
    'at': DateTime.now().millisecondsSinceEpoch,
  };
  final now = DateTime.now().millisecondsSinceEpoch;
  all.removeWhere((_, v) {
    final e = asMap(v);
    return now - intArgDefault(e, 'at', 0) >= _dbArkFileTtlMs;
  });
  _dbArkCacheSave(all);
}

/// 直接以二进制方式上传到方舟 Files API，同时传 tos[bucket]/tos[prefix]：
/// 文件落在用户 TOS 桶，预处理也在方舟侧完成。
/// 这是用户要求的「TOS 预处理」路径，不需要 TOS AK/SK，也不走本地理解。
Future<String> _dbArkUploadToTosBucket({
  required File file,
  required String fileName,
  required String bucket,
  required String prefix,
  required String model,
  required String apiKey,
  required double fps,
  int maxVideoTokens = 0,
  int minFrames = 0,
  void Function(int sent, int total)? onProgress,
}) async {
  final total = await file.length();
  if (total <= 0) {
    throw DbVideoArkException('视频文件为空：$fileName', code: 'empty');
  }
  var destPrefix = prefix.trim();
  if (destPrefix.isEmpty) destPrefix = 'arkfiles/';
  if (!destPrefix.endsWith('/')) destPrefix = '$destPrefix/';

  final boundary =
      '----keweTosUpload${DateTime.now().microsecondsSinceEpoch}${randomHex(8)}';
  final head = StringBuffer();
  void field(String n, String v) {
    head.write('--$boundary\r\n');
    head.write('Content-Disposition: form-data; name="$n"\r\n\r\n');
    head.write('$v\r\n');
  }

  field('purpose', 'user_data');
  field('tos[bucket]', bucket);
  // 官方文档：TOS 目标路径；预处理产物会落在 <prefix>/ark_processed/<file_id>/
  field('tos[prefix]', destPrefix);
  if (model.trim().isNotEmpty) {
    field('preprocess_configs[video][model]', model.trim());
  }
  field('preprocess_configs[video][fps]', _dbFpsStr(fps));
  if (maxVideoTokens > 0) {
    field('preprocess_configs[video][max_video_tokens]', '$maxVideoTokens');
  }
  if (minFrames > 0) {
    field('preprocess_configs[video][min_frames]', '$minFrames');
  }

  final safeName = fileName
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
      .replaceAll(RegExp(r'^_+'), '');
  final uploadName = safeName.isEmpty ? 'video.mp4' : safeName;
  head.write('--$boundary\r\n');
  head.write('Content-Disposition: form-data; name="file"; '
      'filename="$uploadName"\r\n');
  head.write('Content-Type: ${_dbVideoMime(fileName)}\r\n\r\n');

  final headBytes = utf8.encode(head.toString());
  final tailBytes = utf8.encode('\r\n--$boundary--\r\n');

  final client = globalHTTPClient;
  HttpClientRequest req;
  try {
    req = await client.openUrl('POST', Uri.parse('${dbBaseUrl(null)}/files'));
  } catch (e) {
    throw DbVideoArkException('连接方舟 Files API 失败：$e');
  }
  req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
  req.headers.set(HttpHeaders.contentTypeHeader,
      'multipart/form-data; boundary=$boundary');
  req.headers.contentLength = headBytes.length + total + tailBytes.length;

  logp('☁️ 开始上传到方舟 TOS: $uploadName '
      '(${dbFmtSize(total)}, fps=${_dbFpsStr(fps)}, prefix=$destPrefix)');

  final raf = await file.open();
  var sent = 0;
  try {
    req.add(headBytes);
    const block = 4 * 1024 * 1024;
    while (sent < total) {
      final chunk = await raf.read(block);
      if (chunk.isEmpty) break;
      req.add(chunk);
      // 手机弱网 + 2GB 大视频本来就慢，所以给足时间；但「给足」不等于
      // 「无限等」：连接被中间设备悄悄掐断时 flush 会永久挂住 ——
      // SSE 心跳还在跳，任务却永远不会结束。单块 4MB 给 10 分钟，
      // 超时即判定断流，抛 upload_failed 让上层如实报错（不再切片/重试）。
      await req.flush().timeout(const Duration(minutes: 10));
      sent += chunk.length;
      onProgress?.call(sent, total);
    }
  } catch (e) {
    try { await raf.close(); } catch (_) {}
    try { req.abort(); } catch (_) {}
    throw DbVideoArkException('TOS/方舟上传中断：$e', code: 'upload_failed');
  }
  try { await raf.close(); } catch (_) {}

  req.add(tailBytes);
  // 与 server.idleTimeout 一致：4 小时总超时，避免大文件被客户端提前掐断。
  const timeoutSec = 14400;
  HttpClientResponse resp;
  try {
    resp = await req.close().timeout(Duration(seconds: timeoutSec));
  } catch (e) {
    throw DbVideoArkException(
        'TOS/方舟上传超时或网络中断（${dbFmtSize(total)}）：$e',
        code: 'upload_failed');
  }
  final body = <int>[];
  await for (final c in resp) {
    body.addAll(c);
  }
  if (resp.statusCode != 200) {
    throw DbVideoArkException(
        '方舟 TOS 上传失败（HTTP ${resp.statusCode}）：${_dbErrText(body)}',
        code: 'upload_failed');
  }
  final j = asMap(jsonDecode(utf8.decode(body, allowMalformed: true)));
  final id = mStr(j, 'id');
  if (id.isEmpty) {
    throw DbVideoArkException('方舟未返回 file id：${_dbErrText(body)}');
  }
  logp('✅ 方舟 TOS 文件创建: $id (status=${mStr(j, 'status')})');
  return id;
}

Future<Map<String, dynamic>> dbArkFileInfo(
    {required String apiKey, required String fileId}) async {
  final req = await globalHTTPClient.openUrl('GET',
      Uri.parse('${dbBaseUrl(null)}/files/${Uri.encodeComponent(fileId)}'));
  req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
  final resp = await req.close().timeout(const Duration(seconds: 120));
  final out = <int>[];
  await for (final c in resp) {
    out.addAll(c);
  }
  if (resp.statusCode != 200) {
    throw DbVideoArkException(
        '查询方舟文件失败（HTTP ${resp.statusCode}）：${_dbErrText(out)}');
  }
  return asMap(jsonDecode(utf8.decode(out, allowMalformed: true)));
}

Future<void> dbArkWaitFileActive({
  required String apiKey,
  required String fileId,
  void Function(String status, int waitedSec)? onTick,
  Duration timeout = const Duration(minutes: 40),
}) async {
  final start = DateTime.now();
  var intervalMs = 2000;
  while (true) {
    final waited = DateTime.now().difference(start);
    if (waited > timeout) {
      throw DbVideoArkException(
          '方舟视频预处理超时（${waited.inMinutes} 分钟未完成，file=$fileId）');
    }
    Map<String, dynamic> info;
    try {
      info = await dbArkFileInfo(apiKey: apiKey, fileId: fileId);
    } catch (e) {
      onTick?.call('retry', waited.inSeconds);
      logp('⚠️ 查询文件状态失败（将重试）: $e');
      await Future<void>.delayed(const Duration(seconds: 3));
      continue;
    }
    final status = mStr(info, 'status').toLowerCase();
    onTick?.call(status, waited.inSeconds);
    if (status == 'active' || status == 'processed') {
      logp('✅ 方舟视频预处理完成: $fileId （${waited.inSeconds} 秒）');
      return;
    }
    if (status == 'failed' || status == 'error') {
      final err = info['error'] ?? info['error_message'] ?? info['message'];
      final isTimeout = dbArkIsPreprocessTimeout('$err');
      throw DbVideoArkException(
          '方舟视频预处理失败（file=$fileId）：${err ?? '未知原因'}',
          code: isTimeout ? 'preprocess_timeout' : 'preprocess_failed');
    }
    await Future<void>.delayed(Duration(milliseconds: intervalMs));
    if (intervalMs < 5000) intervalMs += 500;
  }
}

/// Files API 单文件通道：整片直传方舟 TOS 预处理，再以 file_id 作为视频输入。
///
/// ★ 2026-11-25 三次修复（用户明确要求，行为已固定）：
///   1) 不降帧：fps 一律用配置值（默认 5.0），不做任何自动下调；
///   2) 不重试：一次上传、一次等待，失败如实抛出，不偷偷再来一轮；
///   3) 不分段：失败就是失败，绝不切成若干段再逐段理解。
/// 方舟 TOS 通道本身支持单文件 2GB；真正的约束在服务端预处理，
/// 客户端只负责把整片原样送达，并把等待窗口给足。
Future<Map<String, dynamic>> dbArkVideoPartForLocalFile({
  required String absPath,
  required String fileName,
  required String model,
  required String apiKey,
  void Function(Map<String, dynamic> info)? onProgress,
}) async {
  final cfg = dbVideoArkConfig();
  final f = File(absPath);
  if (!f.existsSync()) {
    throw DbVideoArkException('视频文件不存在：$fileName', code: 'missing');
  }
  final stat = f.statSync();
  final size = stat.size;
  if (size > cfg.maxBytes) {
    throw DbVideoArkException(
        '视频超过上限 ${dbFmtSize(cfg.maxBytes)}（当前 ${dbFmtSize(size)}）：$fileName',
        code: 'too_large');
  }
  if (size <= 0) {
    throw DbVideoArkException('视频文件为空：$fileName', code: 'empty');
  }

  // 配置里的 fps 原样透传，绝不自动降帧。
  final fps = cfg.fps <= 0 ? 1.0 : cfg.fps;
  final key = _dbArkCacheKey(f, size);

  final cached = _dbArkCacheLookup(key, fps);
  if (cached != null) {
    onProgress?.call({'stage': 'cache_hit', 'arkFileId': cached});
    return dbArkVideoPartByFileId(cached, fps: fps);
  }

  if (cfg.tosBucket.trim().isEmpty) {
    throw DbVideoArkException(
        'TOS Bucket 未配置，已按「只走 TOS 整片直传」策略停止，不回退本地。',
        code: 'tos_not_configured');
  }

  onProgress?.call({
    'stage': 'tos_upload_start',
    'size': size,
    'attempt': 1,
    'fps': fps,
  });
  final arkId = await _dbArkUploadToTosBucket(
    file: f,
    fileName: fileName,
    bucket: cfg.tosBucket,
    prefix: cfg.tosPrefix,
    model: cfg.preprocessModel,
    apiKey: apiKey,
    fps: fps,
    maxVideoTokens: cfg.maxVideoTokens,
    minFrames: cfg.minFrames,
    onProgress: (sent, total) {
      onProgress?.call({
        'stage': 'tos_upload',
        'sent': sent,
        'total': total,
        'percent': total <= 0 ? 0 : ((sent * 100) ~/ total),
        'attempt': 1,
      });
    },
  );
  onProgress?.call({'stage': 'tos_upload_done', 'size': size});
  onProgress?.call({'stage': 'tos_reference', 'size': size});

  // 「预处理停在 0 秒」的显示 bug 修复点：等待开始即下发 waited=0，
  // 每个 tick 用本地经过时间与轮询秒数取大值，保证进度条真的会走。
  onProgress?.call({
    'stage': 'preprocess_wait',
    'arkFileId': arkId,
    'waited': 0,
    'attempt': 1,
  });
  final waitStartedAt = DateTime.now();
  try {
    await dbArkWaitFileActive(
      apiKey: apiKey,
      fileId: arkId,
      timeout: dbArkPreprocessTimeoutFor(size),
      onTick: (status, waitedSec) {
        final local = DateTime.now().difference(waitStartedAt).inSeconds;
        onProgress?.call({
          'stage': 'preprocess',
          'arkFileId': arkId,
          'status': status,
          'waited': waitedSec > local ? waitedSec : local,
          'attempt': 1,
        });
      },
    );
  } catch (e) {
    final msg = '$e';
    // 失败记忆只用于事后诊断，绝不用于拒绝后续请求：
    // 用「某个文件失败过」去判死别的文件，是错误的因果推断。
    if (dbArkIsPreprocessTimeout(msg)) {
      _dbArkSlowPathRemember(key, msg, bytes: size, fps: fps);
    }
    throw DbVideoArkException(
        '方舟整片预处理失败（源文件 ${dbFmtSize(size)}，'
        'fps=${_dbFpsStr(fps)}，file=$arkId）：$msg\n'
        '说明：本机实测方舟单文件预处理的上限在 12~20 分钟之间 —— '
        '同一源片 12 分钟（3600 帧）active 用 17 秒，20 分钟（6000 帧）'
        '21 秒即报 "Timeout occurred while processing video"，加 '
        'max_video_tokens=131072 也无法救。这与授权、桶权限、编码、'
        '体积都无关（30 秒 HEVC 与 5 分钟 HEVC 都正常 active）。',
        code: 'preprocess_failed');
  }
  _dbArkCacheStore(key, arkId, cfg.preprocessModel, fps);
  return dbArkVideoPartByFileId(arkId, fps: fps);
}

/// 该模型做视频理解时是否必须走 Responses API（而非 Chat API）。
bool dbVideoNeedsResponsesApi(String model) {
  final m = model.trim().toLowerCase();
  return m.startsWith('deepseek-v4');
}

/// 把 Chat 风格 content 数组转成 Responses API 的 content 数组。
/// 视频 video_url -> input_video；图片 image_url -> input_image；
/// 文本 text -> input_text；其余（input_audio / input_video 等）原样保留。
List<Map<String, dynamic>> dbVideoResponsesContent(
    List<Map<String, dynamic>> parts) {
  final out = <Map<String, dynamic>>[];
  for (final p in parts) {
    final t = (p['type'] ?? '').toString();
    if (t == 'video_url') {
      final v = p['video_url'];
      String fileId = '';
      if (v is Map) fileId = '${v['file_id'] ?? ''}';
      if (fileId.isNotEmpty) {
        // 官方「视频理解」文档（Responses API 示例）原文：
        //   {"type":"input_video","file_id":"file-20251018****"}
        // 之前两轮分别试过 input_file 与嵌套 file，都会被方舟按 pdf 文档校验
        // （报 "The provided file: xxx type is not pdf"），现恢复官方 input_video。
        out.add({'type': 'input_video', 'file_id': fileId});
      }
    } else if (t == 'image_url') {
      final img = p['image_url'];
      String url = '';
      if (img is Map) {
        url = '${img['url'] ?? ''}';
      } else if (img is String) {
        url = img;
      }
      if (url.isNotEmpty) {
        out.add({'type': 'input_image', 'image_url': url});
      }
    } else if (t == 'text') {
      out.add({'type': 'input_text', 'text': '${p['text'] ?? ''}'});
    } else {
      out.add(p);
    }
  }
  return out;
}

/// 把 Chat Completions 风格 messages 转成 Responses API 的 instructions + input，
/// 保留视频 / 图片 / 文本等全部模态（dbWikiBuildInput 只保留文本，此处不同）。
({String instructions, List<Map<String, dynamic>> input})
    dbVideoResponsesBuildInput(List<Map<String, dynamic>> messages) {
  final sys = <String>[];
  final input = <Map<String, dynamic>>[];
  for (final m in messages) {
    final role = (m['role'] ?? '').toString();
    final raw = m['content'];
    var parts = <Map<String, dynamic>>[];
    if (raw is String) {
      parts = [
        {'type': 'text', 'text': raw}
      ];
    } else if (raw is List) {
      parts = raw.whereType<Map<String, dynamic>>().toList();
    }
    final conv = dbVideoResponsesContent(parts);
    if (role == 'system') {
      final buf = <String>[];
      for (final c in conv) {
        if ((c['type'] ?? '').toString() == 'input_text') {
          buf.add('${c['text'] ?? ''}');
        }
      }
      if (buf.isNotEmpty) sys.add(buf.join('\n'));
      continue;
    }
    if (role == 'assistant') {
      final abuf = <String>[];
      if (raw is String) {
        abuf.add(raw);
      } else if (raw is List) {
        for (final p in raw) {
          if (p is Map && (p['type'] == 'text' || p['type'] == 'output_text')) {
            abuf.add('${p['text'] ?? ''}');
          }
        }
      }
      input.add({
        'type': 'message',
        'role': 'assistant',
        // Responses 的 input 里 assistant 历史同样必须用 input_text：
        // output_text 不在方舟 content 白名单内（白名单对应 text / image_url /
        // file 三种块），用它会让多轮请求报
        // "content must be text or an array of text, image_url, or file content blocks"。
        'content': <Map<String, dynamic>>[
          {'type': 'input_text', 'text': abuf.join('\n')},
        ],
      });
      continue;
    }
    input.add({
      'type': 'message',
      'role': 'user',
      'content': conv.isEmpty
          ? <Map<String, dynamic>>[
              {'type': 'input_text', 'text': ''}
            ]
          : conv,
    });
  }
  return (instructions: sys.join('\n\n'), input: input);
}

/// 通过 Responses API 流式发起视频理解（DeepSeek V4 系列）。
/// 回调语义与 callDbWikiResponsesStream 保持一致。
Future<void> callDbVideoResponsesStream(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  void Function(String s) onReasoning,
  void Function(String s) onContent,
  DsUsageAcc? usageAcc,
) async {
  final built = dbVideoResponsesBuildInput(messages);
  if (built.input.isEmpty) {
    throw Exception('输入内容为空');
  }

  var mt = maxTokens;
  if (mt <= 0) mt = 8192;
  if (mt > 120000) mt = 120000;

  final body = <String, dynamic>{
    'model': model,
    'stream': true,
    'input': built.input,
    'max_output_tokens': mt,
  };
  if (built.instructions.isNotEmpty) {
    body['instructions'] = built.instructions;
  }

  var b = dbBaseUrl(null).trim();
  if (b.isEmpty) b = 'https://ark.cn-beijing.volces.com/api/v3';
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  final url = '$b/responses';
  logp('视频理解走 Responses API: $url (model=$model)');

  final client = globalHTTPClient;
  final req = await client.postUrl(Uri.parse(url));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.headers.set('Accept', 'text/event-stream');
  req.headers.set('Accept-Encoding', 'identity');
  req.add(utf8.encode(jsonEncode(body)));

  final resp = await req.close();
  if (resp.statusCode != 200) {
    final txt =
        utf8.decode(await resp.fold<List<int>>([], (a, b) => a..addAll(b)));
    logp('Responses API HTTP ${resp.statusCode}: $txt');
    String msg = txt;
    try {
      final j = jsonDecode(txt);
      if (j is Map && j['error'] is Map) {
        final e = j['error'] as Map;
        final mm = '${e['message'] ?? ''}';
        if (mm.isNotEmpty) msg = mm;
      }
    } catch (_) {}
    throw Exception('视频理解请求失败（HTTP ${resp.statusCode}）：$msg');
  }

  final errBuf = StringBuffer();
  var lastEvent = '';
  var gotDelta = false;

  await for (final line
      in resp.transform(utf8.decoder).transform(const LineSplitter())) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (t.startsWith(':')) continue;
    if (t.startsWith('event:')) {
      lastEvent = t.substring(6).trim();
      continue;
    }
    if (!t.startsWith('data:')) continue;
    final payload = t.substring(5).trim();
    if (payload.isEmpty) continue;
    if (payload == '[DONE]') break;

    Map<String, dynamic> ev;
    try {
      final j = jsonDecode(payload);
      if (j is! Map<String, dynamic>) continue;
      ev = j;
    } catch (_) {
      continue;
    }

    var type = (ev['type'] ?? '').toString();
    if (type.isEmpty) type = lastEvent;

    if (type == 'response.output_text.delta' ||
        type == 'response.output_text.done') {
      final d = (ev['delta'] ?? '').toString();
      if (type.endsWith('.delta') && d.isNotEmpty) {
        gotDelta = true;
        onContent(d);
      }
      continue;
    }

    if (type == 'response.reasoning_summary_text.delta' ||
        type == 'response.reasoning_text.delta') {
      final d = (ev['delta'] ?? '').toString();
      if (d.isNotEmpty) onReasoning(d);
      continue;
    }

    if (type == 'response.completed' || type == 'response.incomplete') {
      final r = ev['response'];
      if (r is Map && usageAcc != null) {
        final u = r['usage'];
        if (u is Map) {
          final inTok = _dbVideoAsInt(u['input_tokens']);
          final outTok = _dbVideoAsInt(u['output_tokens']);
          final total = _dbVideoAsInt(u['total_tokens']);
          var cached = 0;
          final det = u['input_tokens_details'];
          if (det is Map) cached = _dbVideoAsInt(det['cached_tokens']);
          usageAcc.model = model;
          usageAcc.addRaw(RawDsUsage(
            promptTokens: inTok,
            completionTokens: outTok,
            totalTokens: total < inTok + outTok ? inTok + outTok : total,
            cachedTokens: cached,
          ));
        }
      }
      if (!gotDelta && r is Map) {
        final out = r['output'];
        if (out is List) {
          final buf = StringBuffer();
          for (final item in out) {
            if (item is! Map) continue;
            if ((item['type'] ?? '').toString() != 'message') continue;
            final cs = item['content'];
            if (cs is! List) continue;
            for (final c in cs) {
              if (c is! Map) continue;
              final ct = (c['type'] ?? '').toString();
              if (ct == 'output_text' || ct == 'text') {
                buf.write('${c['text'] ?? ''}');
              }
            }
          }
          if (buf.isNotEmpty) {
            gotDelta = true;
            onContent(buf.toString());
          }
        }
      }
      continue;
    }

    if (type == 'response.failed' || type == 'error') {
      final r = ev['response'];
      String msg = '';
      if (r is Map && r['error'] is Map) {
        msg = '${(r['error'] as Map)['message'] ?? ''}';
      }
      if (msg.isEmpty && ev['error'] is Map) {
        msg = '${(ev['error'] as Map)['message'] ?? ''}';
      }
      if (msg.isEmpty) msg = '${ev['message'] ?? ''}';
      if (msg.isEmpty) msg = '视频理解返回失败';
      errBuf.write(msg);
      continue;
    }
  }

  if (errBuf.isNotEmpty) throw Exception(errBuf.toString());
}

int _dbVideoAsInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}


/// 判断这组 Chat 风格 messages 里是否包含视频（video_url）块，
/// 且目标模型必须走 Responses API 做视频理解（DeepSeek V4 系列）。
bool dbVideoMessagesNeedResponses(
    String model, List<Map<String, dynamic>> messages) {
  if (!dbVideoNeedsResponsesApi(model)) return false;
  for (final m in messages) {
    final c = m['content'];
    if (c is List) {
      for (final p in c) {
        if (p is Map && (p['type'] ?? '').toString() == 'video_url') {
          return true;
        }
      }
    }
  }
  return false;
}


// ============================================================
// 视频理解输出规范
// ------------------------------------------------------------
// ★ 这是「模型理解视频细节不全、跟原片差很多」的根因修复。
//
//   旧实现：用户发一个视频 + 一句话，代码把这句话原样当 prompt 送进去，
//   从未告诉模型「要按时间轴穷举细节」。模型只给一段概括，用户看到的就是
//   「细节严重不对」「发生了什么说不清」。这不是模型看不懂视频，
//   是没有任何一条指令要求它说全。
//
//   本规范对模型提出可验收的要求：
//     1) 时间轴逐段，标时间点；
//     2) 画面文字、台词原样抄录，不确定标注，禁止编造；
//     3) 人物/场景/动作/转场/数字/专名逐项穷尽；
//     4) 不设字数上限，禁止概括代替内容，禁止重复注水。
// ============================================================

/// 视频理解输出规范（跟随 UI 语言；未覆盖的语言回退英文）。
String dbVideoUnderstandPrompt(String lang) {
  final l = lang.trim().toLowerCase();
  if (l.startsWith('ja')) return _dbVideoPromptJa;
  if (l.startsWith('zh') || l.startsWith('cmn') || l.startsWith('yue')) {
    return _dbVideoPromptZh;
  }
  return _dbVideoPromptEn;
}

const String _dbVideoPromptZh = '''【视频理解输出规范 · 必须遵守】

本次请求附带视频。你必须真正看完整个视频再回答，并按下列要求输出。这是一份可被逐条核对的交付物，不是观后感。

一、时间轴全记录（最优先）
1. 从 00:00 开始，按视频真实时间推进逐段记录，每段以时间点开头，格式为 00:00、03:12。
2. 每一段都要写清：画面正在发生什么、出现了谁、说了什么、画面上有什么文字、镜头如何变化。
3. 视频有多长就写多长，不设字数上限。禁止用「之后」「随后」「中间」「接下来」这类模糊词跳过任何一段内容。
4. 事件较多时按阶段分组，但组内仍须逐条标出时间点，不得合并。

二、细节必须穷尽（逐项写清，缺一项就补上）
1. 人物：出现几个人、各自外观、衣着、发型、身份线索、表情变化、具体动作。
2. 场景：地点、环境、光线、天气、时间、道具、背景里的元素。
3. 画面文字：字幕、标题、弹幕、界面元素、招牌、包装、屏幕上的数字，一律原样抄录，不得改写、不得翻译（可另附说明）。
4. 对话与声音：能听清的台词、旁白、音效、背景音乐变化，原样抄录并标时间点；听不清的地方写「此处无法确认」，严禁编造。
5. 动作与事件：谁做了什么、先后顺序、彼此因果、结果如何。
6. 转场与镜头：切换方式、剪辑点、视角变化、加速减速、特效、重复画面。
7. 数字与专名：出现的所有数字、价格、日期、时长、人名、地名、品牌、型号、链接，必须准确抄录，一个不许漏、一个不许猜。

三、绝对禁止
1. 禁止只给概括、主题思想、观后感，或用「内容很丰富」「值得一看」代替实际内容。
2. 禁止写出没看到的内容。无法确认必须标注（不确定）。
3. 禁止因为视频长就压缩：宁可写更多段，也不许合并省略。
4. 禁止重复同一信息凑字数，也不许注水。

四、输出结构
1. 开头一句话给结论：主题 + 主线 + 结局。
2. 然后按时间轴展开全部细节，遵守上面第一、二节。
3. 最后单列「关键信息清单」：视频里出现的所有数字、专名、结论、待办事项。

五、与用户问题的关系
用户的问题如果只针对其中某一点，你仍然要先给出完整时间轴与细节记录，然后再回答问题。不得因为用户问得简单就只答那一句。''';

const String _dbVideoPromptEn = '''[Video Understanding Output Contract — mandatory]

A video is attached. You must actually watch the whole video before answering, and follow the rules below. This is a verifiable deliverable, not an impression.

1. Full timeline
1.1 Start at 00:00 and proceed chronologically; begin each entry with a timestamp formatted as 00:00 or 03:12.
1.2 Each entry must state what is happening on screen, who appears, what is said, what text is visible, and how the camera changes.
1.3 Write as long as the video requires. No length limit. Never skip sections with vague words such as "then", "later", "in the middle".
1.4 For dense content, group by phase, but keep per-entry timestamps and never merge.

2. Exhaustive detail (cover every item)
2.1 People: count, appearance, clothing, hair, identity cues, facial expression changes, concrete actions.
2.2 Scene: location, environment, lighting, weather, time of day, props, background elements.
2.3 On-screen text: subtitles, titles, comments, UI elements, signage, packaging, numbers. Transcribe verbatim; do not paraphrase or translate away the original.
2.4 Dialogue and sound: transcribe audible lines, narration, sound effects and music changes verbatim with timestamps. Where inaudible, write "cannot be confirmed here". Never invent.
2.5 Actions and events: who did what, in what order, with what cause and result.
2.6 Transitions and camera: cuts, edit points, angle changes, speed changes, effects, repeated frames.
2.7 Numbers and proper nouns: every number, price, date, duration, person name, place, brand, model number and link must be transcribed exactly. Omit none, guess none.

3. Hard prohibitions
3.1 No summary-only answers, no thematic essays, no "rich content" / "worth watching" filler.
3.2 Never describe what you did not see. Mark uncertainty as (uncertain).
3.3 Never compress because the video is long; add more entries instead.
3.4 Never pad with repeated information.

4. Structure
4.1 Open with one-sentence conclusion: topic + throughline + outcome.
4.2 Then the full timeline with all required detail.
4.3 End with a "Key facts" list: all numbers, proper nouns, conclusions, action items.

5. Relation to the user question
Even if the user asks about only one point, you must first deliver the full timeline and detail record, then answer the question. Do not answer only that one point.''';

const String _dbVideoPromptJa = '''【動画理解の出力規約 · 必須】

本リクエストには動画が添付されています。動画全体を実際に視聴したうえで回答し、以下の規約に従ってください。これは検証可能な成果物であり、感想文ではありません。

一、タイムラインの全記録
1. 00:00 から時系列に進み、各項目の先頭に 00:00、03:12 の形式で時刻を付けます。
2. 各項目には、画面で何が起きているか、誰が現れるか、何が話されるか、画面にどんな文字があるか、カメラがどう動くかを書きます。
3. 動画の長さに応じて書きます。字数制限はありません。「その後」「続いて」「途中で」などの曖昧な語で区間を飛ばすことは禁止です。
4. 内容が多い場合は段階ごとにまとめてよいですが、各項目の時刻は保持し、統合してはいけません。

二、細部の網羅（項目ごとに記述）
1. 人物：人数、外見、服装、髪型、身元の手がかり、表情の変化、具体的な動作。
2. 場景：場所、環境、光、天気、時間帯、小道具、背景の要素。
3. 画面内の文字：字幕、タイトル、コメント、UI 要素、看板、パッケージ、数字。原文のまま転記し、言い換えない。
4. 会話と音：聞き取れる台詞、ナレーション、効果音、音楽の変化を時刻付きで原文のまま転記。聞き取れない箇所は「ここは確認できない」と明記し、創作してはいけません。
5. 動作と出来事：誰が何をしたか、順序、因果、結果。
6. トランジションとカメラ：カット、編集点、視点の変化、速度変化、エフェクト、繰り返し。
7. 数字と固有名詞：数字、価格、日付、時間、人名、地名、ブランド、型番、リンクを正確に転記。省略も推測も禁止。

三、禁止事項
1. 要約のみ、主題の感想、「内容が豊富」「一見の価値あり」などの埋め草は禁止。
2. 見ていない内容を書くことは禁止。不確実な点は（不確実）と明記。
3. 長いからといって圧縮しない。項目を増やすこと。
4. 同じ情報の繰り返しで字数を稼ぐことは禁止。

四、構成
1. 冒頭に一文で結論：主題＋筋＋結末。
2. その後、タイムラインに沿って全細部を展開。
3. 最後に「重要情報一覧」：登場した数字、固有名詞、結論、TODO。

五、ユーザーの質問との関係
質問が一点だけを尋ねていても、まず完全なタイムラインと細部を提示し、その後に回答します。''';


// ============================================================
// 2026-11-25 四次修复：帧上限决策 + 等分完整转写
// ------------------------------------------------------------
// 全部数值来自本机现场实测，不是推测：
//   · 30 秒  HEVC 1080p fps=5 → active 4 秒
//   · 5 分钟 HEVC 1080p fps=5 → active 13 秒
//   · 12 分钟 HEVC 1080p fps=5 → active 17 秒（3600 帧）
//   · 20 分钟 HEVC 1080p fps=5 → failed 21 秒（Timeout ...）
//   · 一次请求 5 段合计 6169 帧 → exceeds the limit (3600)
//   · -c copy 切片的 AAC 音频被方舟判成 3.6ms →
//     "duration of the input audio (3.625ms) is shorter than the limit (10ms)"
//     改成 -c:v copy -c:a aac 后同一片段请求成功，输出 4876 字，
//     含逐秒时间点、日语台词原文与中文字幕抄录。
// ============================================================

/// 方舟 chat 单请求的输入帧数上限（实测硬限制：3600）。
const int dbArkFrameLimitPerRequest = 3600;

/// 秒 → 分:秒 / 时:分:秒
String _dbClock(num sec) {
  final s = sec < 0 ? 0 : sec.round();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final ss = s % 60;
  String p2(int v) => v < 10 ? '0$v' : '$v';
  if (h > 0) return '$h:${p2(m)}:${p2(ss)}';
  return '${p2(m)}:${p2(ss)}';
}

/// ffprobe 读时长（秒）；失败返回 0，绝不猜。
Future<double> _dbProbeDurationSec(File f) async {
  try {
    final r = await Process.run('ffprobe', [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=nw=1:nk=1',
      f.path,
    ]);
    if (r.exitCode == 0) {
      final d = double.tryParse('${r.stdout}'.trim());
      if (d != null && d > 0) return d;
    }
  } catch (_) {}
  return 0;
}

/// 按帧总数规划段数：≤3600 帧就是 1 段（整片直传，不分段）。
int dbArkPlanSegCount(double durationSec, double fps) {
  if (durationSec <= 0) return 1;
  final f = fps <= 0 ? 1.0 : fps;
  final frames = durationSec * f;
  if (frames <= dbArkFrameLimitPerRequest) return 1;
  var n = (frames / dbArkFrameLimitPerRequest).ceil();
  if (n < 2) n = 2;
  if (n > 200) n = 200;
  return n;
}

/// 等分切段：视频流 -c copy（不重编码、不改分辨率/帧率、不失真），
/// 音频重编码为 AAC。
///
/// 为什么音频必须重编码：实测 -c copy 切出的片段，AAC 的时长元数据会被
/// 方舟解析成 3.625ms，直接拒收：
///   "The request failed because the duration of the input audio (3.625ms)
///    is shorter than the limit (10ms)"（param: audio_url duration）。
/// 同一片段把音频用 -c:a aac 重编码后立刻成功。视频流不受影响。
Future<List<File>> _dbSplitByTime({
  required File src,
  required int segCount,
  required double duration,
  void Function(int index, int total)? onSeg,
}) async {
  final tmpDir = Directory(
      '${Directory.systemTemp.path}/kewe_vseg_${DateTime.now().microsecondsSinceEpoch}');
  tmpDir.createSync(recursive: true);
  final segSec = duration / segCount;
  final out = <File>[];
  for (var i = 0; i < segCount; i++) {
    final start = segSec * i;
    final len = (i == segCount - 1) ? (duration - start) : segSec;
    if (len <= 0.5) continue;
    final path = '${tmpDir.path}/seg_${i.toString().padLeft(3, '0')}.mp4';
    onSeg?.call(i, segCount);
    final r = await Process.run('ffmpeg', [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-ss', start.toStringAsFixed(3),
      '-t', len.toStringAsFixed(3),
      '-i', src.path,
      '-map', '0:v:0',
      '-map', '0:a?',
      '-c:v', 'copy',
      '-c:a', 'aac',
      '-b:a', '128k',
      '-avoid_negative_ts', 'make_zero',
      '-movflags', '+faststart',
      path,
    ]);
    if (r.exitCode != 0) {
      throw DbVideoArkException(
          '视频等分切段失败（第 ${i + 1}/$segCount 段，'
          'ffmpeg exit=${r.exitCode}）：${'${r.stderr}'.trim()}');
    }
    final f = File(path);
    if (!f.existsSync() || f.lengthSync() <= 0) {
      throw DbVideoArkException('视频等分切段失败（第 ${i + 1}/$segCount 段无输出）');
    }
    out.add(f);
  }
  if (out.isEmpty) {
    throw DbVideoArkException('视频等分切段后没有得到任何片段');
  }
  return out;
}

/// 用 file_id 做一次非流式视频理解，返回模型文本。
Future<String> _dbArkChatByFileId({
  required String apiKey,
  required String model,
  required String fileId,
  required String prompt,
  int maxTokens = 8000,
}) async {
  final body = <String, dynamic>{
    'model': model,
    'messages': <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'user',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'video_url',
            'video_url': <String, dynamic>{'file_id': fileId},
          },
          <String, dynamic>{'type': 'text', 'text': prompt},
        ],
      },
    ],
    'max_tokens': maxTokens,
    'temperature': 0.2,
  };
  final url = '${dbBaseUrl(null)}/chat/completions';
  final client = globalHTTPClient;
  final req = await client.postUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
  req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
  final bytes = utf8.encode(jsonEncode(body));
  req.headers.contentLength = bytes.length;
  req.add(bytes);
  final resp = await req.close().timeout(const Duration(minutes: 30));
  final out = <int>[];
  await for (final c in resp) {
    out.addAll(c);
  }
  if (resp.statusCode != 200) {
    throw DbVideoArkException(
        '视频分段理解失败（HTTP ${resp.statusCode}）：${_dbErrText(out)}');
  }
  final j = asMap(jsonDecode(utf8.decode(out, allowMalformed: true)));
  final choices = asList(j['choices']);
  if (choices.isEmpty) {
    throw DbVideoArkException('视频分段理解返回空响应');
  }
  final msg = asMap(asMap(choices[0])['message']);
  var text = mStr(msg, 'content').trim();
  if (text.isEmpty) text = mStr(msg, 'reasoning_content').trim();
  if (text.isEmpty) {
    throw DbVideoArkException('视频分段理解返回空内容');
  }
  return text;
}

/// 段级提示词：要求按全片时间轴穷举细节，禁止概括、禁止跨段猜测。
String _dbSegFullPrompt({
  required String videoName,
  required int index,
  required int total,
  required double startSec,
  required double endSec,
}) {
  final a = _dbClock(startSec);
  final b = _dbClock(endSec);
  return '这是一条完整视频《$videoName》的第 ${index + 1}/$total 段，'
      '覆盖全片时间轴 $a - $b（视频被等分只为绕过单次输入帧数上限，'
      '内容本身连续，不要当成独立短片）。\n'
      '请真正看完这一段，然后按下面的要求输出，这是一份可逐条核对的记录：\n'
      '1. 从 $a 开始按时间推进，每个事件以时间点开头（格式 分:秒，'
      '沿用全片时间轴，不要从 0 重新计时）；\n'
      '2. 逐项写清：场景与环境、人物外观与动作、表情变化、'
      '对话与旁白（能听清的写原文）、画面文字与字幕（原样抄录）、'
      '镜头与转场；\n'
      '3. 数字、专名、日期、价格、人名、地名必须准确抄录，不许猜；\n'
      '4. 不设字数上限，视频有多长就写多长，禁止用「随后」「接下来」'
      '跳过任何片段；\n'
      '5. 只写你真实看到的内容，看不清听不清就标注（不确定），严禁编造，'
      '严禁猜测其他段落的内容。';
}

/// 分段完整理解：逐段上传（fps 严格等于配置值，不降帧、不重试）、
/// 逐段做完整转写，最后按全片时间轴拼接成一份连续记录。
Future<String> dbDescribeVideoInSegments({
  required File file,
  required String fileName,
  required DbVideoArkConfig cfg,
  required String apiKey,
  required int segCount,
  required double duration,
  void Function(Map<String, dynamic> info)? onProgress,
}) async {
  final fps = cfg.fps <= 0 ? 1.0 : cfg.fps;
  final model = cfg.preprocessModel.trim().isNotEmpty
      ? cfg.preprocessModel.trim()
      : 'doubao-seed-2-1-lite-260915';
  Directory? tmpDir;
  try {
    onProgress?.call({'stage': 'seg_split', 'segments': segCount});
    final segs = await _dbSplitByTime(
      src: file,
      segCount: segCount,
      duration: duration,
      onSeg: (i, total) {
        onProgress?.call({
          'stage': 'seg_split',
          'segment': i + 1,
          'segments': total,
          'percent': ((i + 1) * 100) ~/ total,
        });
      },
    );
    tmpDir = segs.first.parent;

    // 用实测时长重建时间轴（-ss 按关键帧对齐，理论等分会有微小偏差）
    final durs = <double>[];
    var total = 0.0;
    for (final s in segs) {
      final d = await _dbProbeDurationSec(s);
      durs.add(d > 0 ? d : 0);
      total += d > 0 ? d : 0;
    }
    if (total <= 0) total = duration;

    final blocks = <String>[];
    var cursor = 0.0;
    for (var i = 0; i < segs.length; i++) {
      final start = cursor;
      final end = cursor + durs[i];
      onProgress?.call({
        'stage': 'segment_start',
        'segment': i + 1,
        'segments': segs.length,
        'start': start.round(),
        'end': end.round(),
      });
      final segSize = segs[i].lengthSync();
      final fileId = await _dbArkUploadToTosBucket(
        file: segs[i],
        fileName: _dbSegFileName(fileName, i, segs.length),
        bucket: cfg.tosBucket,
        prefix: cfg.tosPrefix,
        model: cfg.preprocessModel,
        apiKey: apiKey,
        fps: fps,
        maxVideoTokens: cfg.maxVideoTokens,
        minFrames: cfg.minFrames,
      );
      await dbArkWaitFileActive(
        apiKey: apiKey,
        fileId: fileId,
        timeout: dbArkPreprocessTimeoutFor(segSize),
        onTick: (status, waitedSec) {
          onProgress?.call({
            'stage': 'preprocess',
            'segment': i + 1,
            'segments': segs.length,
            'status': status,
            'waited': waitedSec,
          });
        },
      );
      final text = await _dbArkChatByFileId(
        apiKey: apiKey,
        model: model,
        fileId: fileId,
        prompt: _dbSegFullPrompt(
          videoName: fileName,
          index: i,
          total: segs.length,
          startSec: start,
          endSec: end,
        ),
      );
      logp('🎬 第 ${i + 1}/${segs.length} 段完整理解完成'
          '（${_dbClock(start)}-${_dbClock(end)}，${runeLen(text)} 字）');
      if (segs.length > 1) {
        blocks.add('【${_dbClock(start)} - ${_dbClock(end)}】\n$text');
      } else {
        blocks.add(text);
      }
      onProgress?.call({
        'stage': 'segment_done',
        'segment': i + 1,
        'segments': segs.length,
        'percent': ((i + 1) * 100) ~/ segs.length,
      });
      cursor = end;
    }

    if (blocks.length == 1) return blocks.first;
    return '''【《$fileName》完整理解 · 全片 ${_dbClock(total)} · ${_dbFpsStr(fps)} fps · 等分 ${blocks.length} 段】
（下面按全片时间轴顺序连续记录；分段只为绕过方舟「单次请求 3600 帧」的上限，内容本身是一整条视频，段与段自然衔接。）

${blocks.join('\n\n')}''';
  } finally {
    if (tmpDir != null) {
      try {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      } catch (e) {
        logp('⚠️ 分段临时文件删除失败: $e');
      }
    }
  }
}

/// 段文件名：ASCII、带段号，避免 TOS 上同名覆盖。
String _dbSegFileName(String videoName, int index, int total) {
  var base = videoName.trim();
  final dot = base.lastIndexOf('.');
  var stem = dot > 0 ? base.substring(0, dot) : base;
  final ext = dot > 0 ? base.substring(dot).toLowerCase() : '.mp4';
  if (stem.length > 50) stem = stem.substring(0, 50);
  stem = stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (stem.isEmpty) stem = 'video';
  final no = (index + 1).toString().padLeft(2, '0');
  final all = total.toString().padLeft(2, '0');
  return '${stem}_s${no}of$all$ext';
}
