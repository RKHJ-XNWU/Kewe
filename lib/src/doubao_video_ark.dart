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
import 'db_limits.dart';
import 'doubao.dart';
import 'files.dart';
import 'globals.dart';
import 'net.dart';
import 'ds_usage.dart';

/// 对外承诺的最大视频体积：2GB
const int dbVideoMaxBytes = 2 * 1024 * 1024 * 1024;

/// 单片默认上限：留 5MB 余量给 JSON / 文本（仅兼容旧配置，内核不读取）
const int dbVideoDefaultSegmentBytes = 45 * 1024 * 1024;

/// ★ 路由层限制，绝不下沉到切片内核。
///
/// 只有目标推理模型明确要求「单分片 ≤50MB」时，路由层才把它作为参数传进
/// 规划函数；切片内核本身不读这个常数、不按体积主动缩片，否则长视频会被
/// 切成大量碎段（帧预算与音频边界都会被打乱，正是 8ms 碎片的高发来源）。
const int dbDeepSeek1017SegmentMaxBytes = 48 * 1024 * 1024;

/// 目标模型对应的「路由层单分片体积上限」；0 = 不限制（保留长分片）。
///
/// 火山方舟上的 DeepSeek-V4.1-Flash（短视频理解）单次请求有 50MB 上限，
/// 因此路由层在规划分片数时叠加体积维度；豆包音视频模型没有这条限制。
int dbRouteSegmentMaxBytes(String model) {
  final m = model.trim().toLowerCase();
  if (m == 'deepseek-v4-1-flash-261017') return dbDeepSeek1017SegmentMaxBytes;
  return 0;
}

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

    // 兼容旧配置字段：切片内核不再按体积切分。体积维度只在路由层按目标
    // 模型决定（见 dbRouteSegmentMaxBytes），内核只负责帧预算与音频帧边界。
    final seg = intArgDefault(j, 'segmentMaxBytes', dbVideoDefaultSegmentBytes);

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
    // ★ 路由层与切片内核解耦：只有目标模型（DeepSeek 1017）要求 50MB 时，
    //   才在「段数规划」里叠加体积维度；切片内核本身不读 50MB、不主动缩片。
    final routeSegMax = dbRouteSegmentMaxBytes(model);
    final segCount = dbArkPlanSegCount(
      dur,
      cfg.fps,
      fileBytes: size,
      maxSegmentBytes: routeSegMax,
    );
    if (routeSegMax > 0) {
      logp('🧩 路由层：$model 单分片 ≤${dbFmtSize(routeSegMax)}，'
          '段数按体积叠加为 $segCount（内核仍按帧/音频帧边界裁切）');
    }
    if (segCount <= 1) {
      // ★ 整片直传前的音频前置拦截（根治 audio_url duration 400）：
      //   源视频若带「8ms 级」坏音频轨（元数据塌缩 / 只剩一两个包 /
      //   PTS 未归零），方舟在 chat 阶段会按 audio_url duration 直接 400。
      //   命中风险时先生成一份修好的副本上传（原文件绝不改动），用完即清。
      //   分段路径不在这里做：分段后由 dbArkEnsureSegmentAudioSafe 逐段拦截，
      //   避免为整片重编码一条几十分钟的音频。
      Directory? audioFixTempDir;
      var wholeHasAudio = true; // 拦截失败时按「有音频」处理，强制音频预处理模型
      String wholeNote = '';
      try {
        final safe = await dbArkPrepareWholeVideoSafe(f);
        wholeHasAudio = safe.hasAudio;
        wholeNote = safe.note;
        if (safe.file.path != f.path) {
          f = safe.file;
          absPath = f.path;
          audioFixTempDir = safe.tempDir;
        }
      } catch (e) {
        // 音频无法修复到 ≥10ms：如实报错，绝不剥离音频后假装成功。
        if (e is DbVideoArkException && e.code == dbArkAudioTooShortCode) {
          _dbCleanupDirs([decryptedTempDir]);
          rethrow;
        }
        logp('⚠️ 整片音频前置拦截失败（按原样继续）: $e');
      }
      if (wholeNote.isNotEmpty && wholeNote != '音频正常' && wholeNote != '无音频轨') {
        logp('🎚️ 整片音频处理：$wholeNote（音频保留，不剥离）');
      }
      try {
        onProgress?.call({...tag, 'stage': 'tos_reference', 'size': size});
        final part = await dbArkVideoPartForLocalFile(
          absPath: absPath,
          fileName: meta.name,
          model: model,
          apiKey: apiKey,
          preprocessModel: dbArkVideoPreprocessModel(
            configured: cfg.preprocessModel,
            hasAudio: wholeHasAudio,
            inference: model,
          ),
          onProgress: (info) => onProgress?.call({...tag, ...info}),
        );
        parts.add(part);
        logp('🎬 整片直传（未分段）: ${meta.name}（${dbFmtSize(size)}，'
            '${_dbClock(dur)} × ${_dbFpsStr(cfg.fps)} fps'
            ' = ${(dur * cfg.fps).round()} 帧）');
        index++;
      } finally {
        // 上传（成功或失败）后立刻清掉解密目录与音频修复副本目录。
        _dbCleanupDirs([decryptedTempDir, audioFixTempDir]);
      }
      continue;
    }
    logp('🎬 ${meta.name}: ${_dbClock(dur)} × ${_dbFpsStr(cfg.fps)} fps'
        ' = ${(dur * cfg.fps).round()} 帧 > 安全帧上限 '
        '$dbArkFrameSafePerRequest 帧 → 等分 $segCount 段，'
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
      model: model,
      onProgress: (info) => onProgress?.call({...tag, ...info}),
    );
    blocks.add(desc);
    index++;
    _dbCleanupDirs([decryptedTempDir]);
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

String? _dbArkCacheLookup(String key, double fps, String model) {
  final raw = _dbArkCacheLoad()[key];
  if (raw is Map) {
    final e = asMap(raw);
    final id = mStr(e, 'arkFileId');
    final at = intArgDefault(e, 'at', 0);
    final sameFps =
        ((e['fps'] is num) ? (e['fps'] as num).toDouble() : -1) == fps;
    // ★ 预处理模型必须参与命中判定：旧缓存可能是「无音频模型」预处理出来的
    //   产物（音频没被处理，只剩 8ms 占位），复用它等于把修好的代码又走回 400。
    final sameModel = mStr(e, 'model') == model;
    final fresh =
        DateTime.now().millisecondsSinceEpoch - at < _dbArkFileTtlMs;
    if (id.isNotEmpty && fresh && sameFps && sameModel) return id;
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

/// 判断异常是不是「带 preprocess_configs[video][model] 上传被服务端拒绝」。
///
/// 本账号历史上出现过：上传带 model → 400 "Project is invalid / param:
/// project_name"。音频能力模型必须带 model 才能生效，但账号没绑 project 时
/// 会整条上传失败，所以这种情况要退回不带 model 的老通道，而不是让视频挂掉。
bool dbArkIsPreprocessModelRejected(Object err) {
  final s = '$err'.toLowerCase();
  if (s.contains('project is invalid') || s.contains('project_name')) return true;
  if (s.contains('preprocess_configs') && s.contains('model')) return true;
  if (s.contains('invalid') && s.contains('project')) return true;
  return false;
}

/// 带音频预处理模型上传；模型被拒时自动退回「不指定模型」的老通道重试一次。
///
/// 返回值带回「这次真正落地的预处理模型」，供 file_id 缓存按真实模型记账 ——
/// 否则退回默认策略的产物会被记成「音频模型」产物，后续又被错误复用。
Future<({String fileId, String model})> _dbArkUploadWithModelFallback({
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
  String? label,
}) async {
  try {
    final id = await _dbArkUploadToTosBucket(
      file: file,
      fileName: fileName,
      bucket: bucket,
      prefix: prefix,
      model: model,
      apiKey: apiKey,
      fps: fps,
      maxVideoTokens: maxVideoTokens,
      minFrames: minFrames,
      onProgress: onProgress,
    );
    return (fileId: id, model: model);
  } catch (e) {
    if (model.trim().isEmpty || !dbArkIsPreprocessModelRejected(e)) rethrow;
    logp('⚠️ ${label ?? fileName} 预处理模型 $model 被服务端拒绝（$e）');

    // 只允许「去掉服务端不认的 model 参数」这一种退化，不做换模型重试：
    // 换预处理模型属于已被证伪的偷懒兜底，会让音频链路再次回到不可控状态。
    logp('⚠️ ${label ?? fileName} 退回未指定模型的默认预处理'
        '（该片音频可能不被抽取，后续逐段校验会拦截）');
    final id = await _dbArkUploadToTosBucket(
      file: file,
      fileName: fileName,
      bucket: bucket,
      prefix: prefix,
      model: '',
      apiKey: apiKey,
      fps: fps,
      maxVideoTokens: maxVideoTokens,
      minFrames: minFrames,
      onProgress: onProgress,
    );
    return (fileId: id, model: '');
  }
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
  // ★ 上传进度 1 秒本地补报：4MB 一块在弱网下要几秒到几十秒，
  //   只按「块」上报会让界面长时间停在同一个百分比上，看起来像卡死。
  final uploadTicker = Timer.periodic(const Duration(seconds: 1), (_) {
    onProgress?.call(sent, total);
  });
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
    uploadTicker.cancel();
    try { await raf.close(); } catch (_) {}
    try { req.abort(); } catch (_) {}
    throw DbVideoArkException('TOS/方舟上传中断：$e', code: 'upload_failed');
  }
  uploadTicker.cancel();
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
  var status = 'processing';
  // ★ 本地秒表：进度秒数由 1 秒定时器推进，与「状态查询」彻底解耦。
  //   旧实现只在查询返回后才 onTick 一次；网络抖动时一次查询就可能阻塞
  //   十几秒（连接超时 10 秒 + 重试间隔 3 秒），界面上就是
  //   「抽帧卡在 15 秒不动」。现在无论查询多慢，秒数每秒都会走一格。
  final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
    onTick?.call(status, DateTime.now().difference(start).inSeconds);
  });
  var intervalMs = 1500;
  try {
    while (true) {
      final waited = DateTime.now().difference(start);
      if (waited > timeout) {
        throw DbVideoArkException(
            '方舟视频预处理超时（${waited.inMinutes} 分钟未完成，file=$fileId）');
      }
      Map<String, dynamic> info;
      try {
        // ★ 查询自带硬超时：dbArkFileInfo 只对「拿到响应头」设了超时，
        //   响应体读到一半被中间设备挂住时会永久 await，进度条随之停住。
        info = await dbArkFileInfo(apiKey: apiKey, fileId: fileId)
            .timeout(const Duration(seconds: 20));
      } catch (e) {
        onTick?.call(status, DateTime.now().difference(start).inSeconds);
        logp('⚠️ 查询文件状态失败（将重试）: $e');
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }
      status = mStr(info, 'status').toLowerCase();
      onTick?.call(status, DateTime.now().difference(start).inSeconds);
      if (status == 'active' || status == 'processed') {
        logp('✅ 方舟视频预处理完成: $fileId '
            '（${DateTime.now().difference(start).inSeconds} 秒）');
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
  } finally {
    ticker.cancel();
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
  String? preprocessModel,
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

  // 预处理模型由调用方按「是否带音轨」解析好（见 dbArkVideoPreprocessModel），
  // 未传时退回配置值，保持旧行为。
  final ppModel = (preprocessModel ?? cfg.preprocessModel).trim();
  logp('🎛️ 视频预处理模型: ${ppModel.isEmpty ? '(未指定，服务端默认策略)' : ppModel}'
      '（文件 $fileName）');

  // 配置里的 fps 原样透传，绝不自动降帧。
  final fps = cfg.fps <= 0 ? 1.0 : cfg.fps;
  final key = _dbArkCacheKey(f, size);

  final cached = _dbArkCacheLookup(key, fps, ppModel);
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
  final up = await _dbArkUploadWithModelFallback(
    file: f,
    fileName: fileName,
    bucket: cfg.tosBucket,
    prefix: cfg.tosPrefix,
    model: ppModel,
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
  final arkId = up.fileId;
  if (up.model != ppModel) {
    logp('⚠️ 预处理模型实际回退为「未指定」（原计划 $ppModel）');
  }
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
  _dbArkCacheStore(key, arkId, up.model, fps);
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
  final l = dsNormalizeLang(lang);
  if (l == 'ja') return _dbVideoPromptJa;
  if (l == 'ko') return _dbVideoPromptKo;
  if (l == 'ru') return _dbVideoPromptRu;
  if (l == 'fr') return _dbVideoPromptFr;
  if (l == 'zh') return _dbVideoPromptZh;
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

/// 长视频（被等分切段、只送转写文本）专用的交付规范。
///
/// 与「视频随请求送出」时不同：模型这次看不到画面，只能看到逐段转写。
/// 如果还按普通问答走，模型会把转写照抄成摘要，细节二次丢失。
/// 所以这里要求它「原样交付这份记录」，只允许排版，不允许删减。
String dbVideoTranscriptPrompt(String lang) {
  final l = dsNormalizeLang(lang);
  if (l == 'ja') return _dbVideoTranscriptPromptJa;
  if (l == 'ko') return _dbVideoTranscriptPromptKo;
  if (l == 'ru') return _dbVideoTranscriptPromptRu;
  if (l == 'fr') return _dbVideoTranscriptPromptFr;
  if (l == 'zh') return _dbVideoTranscriptPromptZh;
  return _dbVideoTranscriptPromptEn;
}

const String _dbVideoTranscriptPromptZh = '''【长视频逐段转写交付规范 · 必须遵守】

本次视频超过了方舟单次请求可接收的帧数上限，已按时间轴等分切段、逐段完整看过。
下面以【完整理解】开头的内容，就是逐段转写得到的原始记录（不是摘要）。

1. 用户要的是「视频里究竟发生了什么、细节是什么」。你要交付的正是这份记录的完整内容：
   按全片时间轴顺序整理输出，保留每一条时间点与原始表述。
2. 禁止概括、禁止合并同类项、禁止用「之后」「随后」「接下来」跳过任何一段，
   禁止只挑几条重点，禁止把多个事件压缩成一句话。
3. 允许在不改变事实的前提下排版（分节、列表、加小标题），但不得删减信息，
   不得改写数字、专名、台词原文与画面文字。
4. 用户的问题若只针对某一点：先把完整记录给出来，再回答那一点。
5. 不设字数上限，记录有多长就交付多长。
6. 记录里标有（不确定）的地方，输出时保留该标注，不得当成确定事实。''';

const String _dbVideoTranscriptPromptEn = '''[Long-video transcript delivery contract — mandatory]

This video exceeds the number of frames a single Ark request can accept, so it was
split on the timeline and every segment was watched in full. The text below the
"complete understanding" heading is the verbatim per-segment record, not a summary.

1. Deliver that record in full, in timeline order, keeping every timestamp and the
   original wording.
2. Do not summarise, do not merge entries, do not skip any segment with vague words
   such as "then", "later", "in the middle", and never compress several events into
   one sentence.
3. You may reformat (sections, lists, sub-headings) but must not drop information and
   must not rewrite numbers, proper nouns, quoted lines or on-screen text.
4. If the user asks about one specific point, still deliver the full record first,
   then answer that point.
5. No length limit: deliver as much as the record contains.
6. Keep the (uncertain) markers where the record has them; never present them as facts.''';

const String _dbVideoTranscriptPromptJa = '''【長時間動画の逐段転写 納品規約 · 必須】

本動画は 1 回のリクエストで受け取れるフレーム数の上限を超えているため、
タイムラインで等分し、各区間を完全に視聴しました。以下の「完全理解」以降は
区間ごとの逐語記録であり、要約ではありません。

1. その記録の内容を丸ごと納品してください。全編のタイムライン順に並べ、
   各時刻と元の表現を保持します。
2. 要約・統合・省略は禁止です。「その後」「続いて」「途中で」などの曖昧な語で
   区間を飛ばすこと、数件をまとめて一文にすることも禁止です。
3. 事実を変えない範囲での整形（見出し・箇条書き）は可。ただし情報を削らず、
   数字・固有名詞・台詞原文・画面文字を書き換えないこと。
4. 質問が一点だけの場合でも、まず完全な記録を出し、その後に答えます。
5. 字数制限はありません。記録の長さだけ納品してください。
6. 記録内の（不確実）表記はそのまま残し、断定に変えないこと。''';

const String _dbVideoTranscriptPromptKo = '''[장시간 영상 구간별 전사 전달 규격 — 필수]

이 영상은 한 번의 요청으로 받을 수 있는 프레임 수를 초과하여 타임라인을 균등 분할하고 각 구간을 완전히 시청했습니다. 아래 "완전 이해"로 시작하는 내용은 구간별 축어 기록이며 요약이 아닙니다.

1. 그 기록의 내용을 전부 전달하십시오. 전체 타임라인 순서로 정리하고 각 시점과 원문 표현을 유지합니다.
2. 요약·통합·생략은 금지입니다. "그 후", "이어서", "중간에" 같은 모호한 말로 구간을 건너뛰거나 여러 사건을 한 문장으로 압축하지 마십시오.
3. 사실을 바꾸지 않는 범위의 정리(소제목, 목록)는 가능합니다. 다만 정보를 삭제하지 말고 숫자·고유명사·대사 원문·화면 글자를 바꾸지 마십시오.
4. 질문이 한 점만 묻더라도 먼저 완전한 기록을 제시한 뒤 그 점에 답하십시오.
5. 글자 수 제한은 없습니다. 기록 길이만큼 전달하십시오.
6. 기록의 (불확실) 표시는 그대로 유지하고 단정으로 바꾸지 마십시오.''';

const String _dbVideoTranscriptPromptRu = '''[Контракт на передачу расшифровки длинного видео — обязательно]

Это видео превышает число кадров, которое можно получить за один запрос, поэтому оно было разделено по таймлайну и каждый фрагмент просмотрен полностью. Текст ниже заголовка «полное понимание» — дословная запись по фрагментам, а не пересказ.

1. Передайте эту запись полностью, в порядке общей хронологии, сохраняя каждую отметку времени и исходные формулировки.
2. Запрещены пересказ, объединение и пропуски. Не пропускайте фрагменты словами «потом», «затем», «в середине» и не сжимайте несколько событий в одно предложение.
3. Можно форматировать (разделы, списки, подзаголовки), но нельзя удалять информацию и менять числа, имена собственные, цитаты и текст на экране.
4. Если вопрос касается одного пункта, сначала дайте полную запись, затем ответьте на этот пункт.
5. Ограничения по длине нет: передайте столько, сколько содержит запись.
6. Сохраняйте пометки «(неопределённо)» и не превращайте их в факты.''';

const String _dbVideoTranscriptPromptFr = '''[Contrat de livraison de transcription de vidéo longue — obligatoire]

Cette vidéo dépasse le nombre d'images qu'une seule requête Ark peut recevoir ; elle a donc été découpée sur la chronologie et chaque segment a été regardé en entier. Le texte sous « compréhension complète » est la transcription mot pour mot par segment, pas un résumé.

1. Livrez cette transcription dans son intégralité, dans l'ordre chronologique, en conservant chaque horodatage et la formulation d'origine.
2. Ne résumez pas, ne fusionnez pas, ne sautez aucun segment avec des mots vagues comme « puis », « ensuite », « au milieu », et ne compressez jamais plusieurs événements en une phrase.
3. Vous pouvez reformater (sections, listes, sous-titres) sans supprimer d'information ni réécrire les nombres, noms propres, répliques citées ou texte à l'écran.
4. Si l'utilisateur ne pose une question que sur un point, livrez d'abord la transcription complète, puis répondez à ce point.
5. Aucune limite de longueur : livrez tout ce que contient la transcription.
6. Conservez les marqueurs « (incertain) » et ne les présentez jamais comme des faits.''';

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

const String _dbVideoPromptKo = '''[영상 이해 출력 규격 — 필수]

이 요청에는 영상이 첨부되어 있습니다. 답변 전에 영상 전체를 실제로 시청하고 아래 규칙을 따르십시오. 이것은 검증 가능한 결과물이며 감상문이 아닙니다.

1. 전체 타임라인
1.1 00:00부터 시간 순서로 진행하고, 각 항목 앞에 00:00, 03:12 형식의 타임스탬프를 붙입니다.
1.2 각 항목에는 화면에서 무슨 일이 일어나는지, 누가 등장하는지, 무엇을 말하는지, 화면에 어떤 글자가 있는지, 카메라가 어떻게 움직이는지 씁니다.
1.3 영상 길이에 맞게 충분히 씁니다. 글자 수 제한은 없습니다. "그 후", "이어서", "중간에" 같은 모호한 말로 구간을 건너뛰지 마십시오.
1.4 내용이 많으면 단계별로 묶어도 되지만, 항목별 타임스탬프를 유지하고 합치지 마십시오.

2. 세부 사항 완전 포함
2.1 인물: 수, 외모, 의상, 머리, 신원 단서, 표정 변화, 구체적 행동.
2.2 장면: 장소, 환경, 조명, 날씨, 시간대, 소품, 배경 요소.
2.3 화면 속 글자: 자막, 제목, 댓글, UI 요소, 간판, 포장, 숫자. 원문 그대로 옮기고 의역하지 마십시오.
2.4 대사와 소리: 들리는 대사, 내레이션, 효과음, 음악 변화를 타임스탬프와 함께 원문 그대로 옮깁니다. 들리지 않으면 "여기서는 확인할 수 없음"이라고 쓰고 창작하지 마십시오.
2.5 행동과 사건: 누가 무엇을 했는지, 순서, 원인과 결과.
2.6 전환과 카메라: 컷, 편집점, 시점 변화, 속도 변화, 효과, 반복 화면.
2.7 숫자와 고유명사: 모든 숫자, 가격, 날짜, 시간, 인명, 지명, 브랜드, 모델명, 링크를 정확히 옮깁니다. 생략도 추측도 금지.

3. 절대 금지
3.1 요약만, 주제 감상, "내용이 풍부함", "볼 만함" 같은 채우기 금지.
3.2 보지 않은 내용을 쓰지 마십시오. 불확실한 점은 (불확실)로 표시.
3.3 길다고 압축하지 말고 항목을 늘리십시오.
3.4 같은 정보를 반복해 분량을 채우지 마십시오.

4. 구성
4.1 첫 문장에 결론: 주제 + 줄거리 + 결말.
4.2 그다음 타임라인에 따라 모든 세부를 전개.
4.3 마지막에 "핵심 정보 목록": 등장한 모든 숫자, 고유명사, 결론, 할 일.

5. 사용자 질문과의 관계
질문이 한 점만 묻더라도 먼저 전체 타임라인과 세부 기록을 제시한 뒤 답하십시오. 그 한 점만 답하지 마십시오.''';

const String _dbVideoPromptRu = '''[Спецификация вывода для понимания видео — обязательно]

К запросу приложено видео. Перед ответом вы должны реально просмотреть всё видео и соблюдать правила ниже. Это проверяемый результат, а не впечатление.

1. Полная хронология
1.1 Начните с 00:00 и идите по времени; каждый пункт начинайте с отметки в формате 00:00 или 03:12.
1.2 В каждом пункте укажите, что происходит на экране, кто появляется, что говорится, какой текст виден, как меняется камера.
1.3 Пишите столько, сколько требует видео. Ограничения по длине нет. Не пропускайте фрагменты словами «потом», «затем», «в середине».
1.4 При большом объёме можно группировать по этапам, но сохраняйте отметки времени для каждого пункта и не объединяйте их.

2. Исчерпывающие детали (по каждому пункту)
2.1 Люди: количество, внешность, одежда, причёска, признаки личности, изменения мимики, конкретные действия.
2.2 Сцена: место, окружение, свет, погода, время суток, реквизит, элементы фона.
2.3 Текст на экране: субтитры, заголовки, комментарии, элементы интерфейса, вывески, упаковка, цифры. Переписывайте дословно, не перефразируйте и не переводите вместо оригинала.
2.4 Речь и звук: слышимые реплики, закадровый текст, звуковые эффекты, изменения музыки — дословно с отметками времени. Где не слышно, пишите «здесь невозможно подтвердить». Не выдумывайте.
2.5 Действия и события: кто что сделал, в каком порядке, причина и результат.
2.6 Переходы и камера: склейки, монтажные точки, смена ракурса, ускорение/замедление, эффекты, повторяющиеся кадры.
2.7 Числа и имена собственные: все числа, цены, даты, длительность, имена, места, бренды, модели, ссылки — точно. Ничего не пропускайте и не угадывайте.

3. Жёсткие запреты
3.1 Не только пересказ, не тематическое эссе, не «богатый контент» / «стоит посмотреть».
3.2 Не описывайте то, чего не видели. Неопределённость помечайте как (неопределённо).
3.3 Не сжимайте из-за длины видео; добавляйте пункты.
3.4 Не заполняйте объём повторами.

4. Структура
4.1 Начните с вывода в одном предложении: тема + основная линия + финал.
4.2 Затем полная хронология со всеми деталями.
4.3 В конце — «Ключевые сведения»: все числа, имена собственные, выводы, задачи.

5. Связь с вопросом пользователя
Даже если пользователь спрашивает об одном пункте, сначала дайте полную хронологию и запись деталей, затем ответьте. Не ограничивайтесь только этим пунктом.''';

const String _dbVideoPromptFr = '''[Contrat de sortie pour la compréhension vidéo — obligatoire]

Une vidéo est jointe. Vous devez réellement regarder toute la vidéo avant de répondre et suivre les règles ci-dessous. Il s'agit d'un livrable vérifiable, pas d'une impression.

1. Chronologie complète
1.1 Commencez à 00:00 et avancez chronologiquement ; chaque entrée commence par un horodatage au format 00:00 ou 03:12.
1.2 Chaque entrée doit préciser ce qui se passe à l'écran, qui apparaît, ce qui est dit, quel texte est visible et comment la caméra évolue.
1.3 Écrivez autant que la vidéo l'exige. Aucune limite de longueur. Ne sautez jamais de sections avec des mots vagues comme « puis », « ensuite », « au milieu ».
1.4 Si le contenu est dense, regroupez par phases, mais conservez les horodatages par entrée et ne fusionnez pas.

2. Détail exhaustif (chaque élément)
2.1 Personnes : nombre, apparence, vêtements, coiffure, indices d'identité, changements d'expression, actions concrètes.
2.2 Scène : lieu, environnement, lumière, météo, moment de la journée, accessoires, éléments de fond.
2.3 Texte à l'écran : sous-titres, titres, commentaires, éléments d'interface, enseignes, emballages, chiffres. Transcription mot pour mot ; ne reformulez pas et ne traduisez pas à la place de l'original.
2.4 Dialogue et son : répliques audibles, narration, effets sonores, changements de musique, mot pour mot avec horodatage. Si inaudible, écrivez « impossible à confirmer ici ». N'inventez jamais.
2.5 Actions et événements : qui a fait quoi, dans quel ordre, avec quelle cause et quel résultat.
2.6 Transitions et caméra : coupes, points de montage, changements d'angle, accélérations, effets, images répétées.
2.7 Nombres et noms propres : chaque nombre, prix, date, durée, nom de personne, lieu, marque, modèle et lien doit être transcrit exactement. N'omettez rien, ne devinez rien.

3. Interdictions strictes
3.1 Pas de réponse uniquement résumée, pas de dissertation thématique, pas de remplissage « contenu riche » / « à voir ».
3.2 Ne décrivez jamais ce que vous n'avez pas vu. Marquez l'incertitude par (incertain).
3.3 Ne compressez pas parce que la vidéo est longue ; ajoutez des entrées.
3.4 Ne remplissez pas avec des informations répétées.

4. Structure
4.1 Ouvrez par une conclusion en une phrase : sujet + fil conducteur + issue.
4.2 Puis la chronologie complète avec tous les détails requis.
4.3 Terminez par une liste « Informations clés » : tous les nombres, noms propres, conclusions, actions à faire.

5. Relation avec la question de l'utilisateur
Même si l'utilisateur ne pose une question que sur un point, vous devez d'abord livrer la chronologie complète et le détail, puis répondre. Ne répondez pas seulement à ce point.''';


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

/// 分段规划用的安全帧上限：在 3600 的基础上留 600 帧余量。
///
/// 为什么不用 3600 直接规划：3600 是服务端「允许的上限值」，正好贴着边界时，
/// 只要预处理多抽一帧（首帧补齐、关键帧对齐、min_frames 生效）就会撞
/// number of the input image (3601) exceeds the limit (3600)；
/// 而实测 3600 帧（12 分钟 @5fps）也已经贴着单文件预处理 ~15 分钟的失败边界。
/// 规划按 3000 帧切分，两个边界都不贴。
const int dbArkFrameSafePerRequest = 3000;

/// 视频回答的 max_tokens 下限（十进制 64K = 64000）。
///
/// 「模型把细节全说出来」不是提示词能单独保证的：输出预算是硬约束，
/// 预算不足时模型写到一半就被切断，用户看到的就是「理解不全」。
/// 只要请求里带视频，就把预算抬到这个下限；同时仍受
/// 「模型上限」与「全局输出档位」双重封顶，绝不越过上游允许值。
int dbVideoAnswerTokenFloor(String model) {
  const int want = 64 * 1000; // 64K，十进制
  final cap = dbSpecialModelMaxOutput(model);
  final global = dbCurrentOutputLimit();
  var v = want;
  if (cap > 0 && cap < v) v = cap;
  if (global > 0 && global < v) v = global;
  if (v < 8192) v = 8192;
  return v;
}

/// 单段完整转写的输出预算：按时长给，短段不浪费、长段不截断。
///
/// 旧实现固定 8000 token：一段 10 分钟的片子要按时间点写清画面、台词、
/// 画面文字，8000 token（约 5 千字）根本写不完，服务端 finish_reason=length
/// 直接截断 —— 这是「长视频细节不全」最直接的一处丢细节。
int dbVideoTranscriptMaxTokens(double segmentSec) {
  if (segmentSec <= 0) return 32000;
  var v = (segmentSec * 60).round(); // 每秒 60 token 的书写预算
  if (v < 16000) v = 16000;
  if (v > 64000) v = 64000;
  return v;
}

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

// ============================================================
// 音频轨前置拦截 —— 根治方舟 `audio_url duration` 400
// ------------------------------------------------------------
// 服务端硬性下限 10ms，实测报错原文：
//   {"error":{"code":"InvalidParameter",
//     "message":"The request failed because the duration of the input
//     audio (8ms) is shorter than the limit (10ms).",
//     "param":"audio_url duration","type":"BadRequest"}}
//
// ★★ 最高优先级铁律（2026-11-25 六修，不可违背）：
//   本项目要的是「带音频的视频理解」，2.1lite 原生支持音视频联合理解。
//   音频是刚需输入，绝不是可选附件。任何情况下都禁止：
//     · 剥离音轨、`-an`、生成 noaud 文件、无声重试；
//     · 把「删掉音频」当作 400 的兜底；
//     · 把「无音频」当成 8ms 报错的容错方案。
//   接口限制只是「单个分片的音频时长必须 ≥10ms」，不是不让传音频。
//   正确的修法只有四条：从切片源头不产生 <10ms 碎片、本地前置校验、
//   极短碎片与相邻分片合并、服务端仍报错时合并相邻分片重试（≤3 次）；
//   全程保留原音频流。
//
// ★ 2026-11-25 六修：已彻底删除 `_dbStripAudioToCopy`、noaud 文件生成、
//   无声重试三条降级路径（连同 `_dbStripSegmentAudioInPlace`、
//   `_dbSegNoAudioName`），代码中不存在任何「自动剥离音频」的分支。
//
// 本机可复现出「8ms 级」音频轨的三条成因（全部被本模块拦掉）：
//   1) 切片音频的时长元数据塌缩：`-ss` 输入 seek + `-c:v copy` 之后，
//      音频轨 PTS 常停在原始偏移上，moov 里写出的 duration 只有几毫秒；
//   2) 音频轨只剩一两个包：源片音频本身极短或损坏，重封装不增加样本，
//      元数据即使写了 481s，真实样本仍然只有 8ms；
//   3) 音频轨起点不是 0：服务端按「容器时长」抽音频时窗口内取不到样本。
//
// 放行顺序（任何 <10ms 的音频都不许进入请求）：
//   体检（音频流元数据 + 实际包数 + 实际解码时长 + 起点偏移，全部毫秒整数）
//   → 命中风险：重建「起点 0 / 长度等于视频 / 单一 AAC 轨」（保留音频样本）
//   → 重建后仍不合格：与相邻分片合并，重新切割、重新探测
//   → 合并后仍不合格：抛 audio_too_short，任务中止，绝不剥离音频
//
// ★ 2026-11-25 四修：真机 8ms 的根因之一在「上传时没指定预处理模型」。
//   Files API 文档原文：「如需处理视频中的音频内容，
//   preprocess_configs.video.model 该字段需指定为支持音频理解的模型」；
//   **不传该字段时**按 doubao-seed-1.8 之前的策略预处理 —— 音频根本不被
//   处理，服务端只挂一条约 8ms 的占位音频，chat 阶段必然 400。
//   故：带音轨的视频一律显式指定该字段（优先复用推理模型，其次官方音频
//   推荐模型）。该字段只影响抽帧/音频预处理策略，推理模型与结果口径不变。
// ============================================================

/// 方舟 chat 对输入音频的硬性下限：10ms（毫秒整数，全链路统一单位）。
const int dbArkAudioHardMinMs = 10;

/// 兼容旧调用：10ms 的秒值。
const double dbArkAudioHardMinSec = dbArkAudioHardMinMs / 1000.0;

/// 兜底用的音频预处理模型：官方音频理解推荐模型（能真正抽出视频音频）。
///
/// 只在「推理模型不是方舟原生 id」或「用户配置的预处理模型被服务端拒绝」
/// 时兜底使用；正常路径优先复用用户的推理模型，不改变其模型选择。
const String dbArkAudioPreprocessModel = 'doubao-seed-2-0-lite-260428';

/// 是否是方舟原生的模型 / 接入点 id（可以安全地写进预处理字段）。
///
/// 方舟模型 id 形如 `doubao-seed-2-1-lite-260915`（结尾是 6 位日期），
/// 接入点形如 `ep-2025...`；中转站别名（如 `doubao-2.1-lite`）不在此列，
/// 写进预处理字段会被服务端判「模型不存在」，所以一律不认。
bool dbArkLooksLikeArkModel(String model) {
  final m = dbCanonicalModelValue(model).trim().toLowerCase();
  if (m.startsWith('ep-')) return true;
  return RegExp(r'^doubao-[a-z0-9.-]+-\d{6}$').hasMatch(m);
}

/// 解析视频上传时真正要写进 `preprocess_configs.video.model` 的模型。
///
/// 官方文档：该字段不传时按 doubao-seed-1.8 之前的策略预处理，**视频中的
/// 音频不会被处理**，服务端只剩一条约 8ms 的占位音频 → chat 阶段必 400。
/// 所以只要文件带音轨，就必须显式指定一个**支持音频理解**的模型。
///
/// 优先级（尽量保持用户原有模型选择不变）：
///   1) 用户显式配置的 preprocessModel（先做别名归一）；
///   2) 接入点 ep-xxx：能力由用户自建接入点决定，原样复用；
///   3) 本次推理模型，且它本身具备音频理解（2.1-lite / 2.0-lite / 2.0-mini
///      原生全模态，音画口径与推理侧一致）；
///   4) 官方音频理解推荐模型 [dbArkAudioPreprocessModel]。
/// 无音轨时保持原样（可以为空），行为与修复前完全一致。
/// ★ 该字段只影响抽帧 / 音频预处理策略，**推理模型不会被改动**。
String dbArkVideoPreprocessModel({
  required String configured,
  required bool hasAudio,
  String inference = '',
}) {
  final c = dbCanonicalModelValue(configured.trim());
  if (!hasAudio) return c;
  if (c.isNotEmpty) return c;
  final i = dbCanonicalModelValue(inference.trim());
  if (i.toLowerCase().startsWith('ep-')) return i;
  if (dbArkLooksLikeArkModel(i) && dbSupportsAudioInput(i)) return i;
  return dbArkAudioPreprocessModel;
}

/// 本地重建阈值：比服务端下限留 5 倍余量。低于它先重建音频轨，
/// 但最终放行只看 [dbArkAudioHardMinMs]（12ms 这类合法短轨照常放行）。
const int dbArkAudioSafeMinMs = 50;

/// 音频轨起点容差（毫秒）：超过它即视为「PTS 未归零」，服务端抽音频可能取不到样本。
const int dbArkAudioMaxStartMs = 500;

/// 「音频分片过短」专用错误码：调用方据此触发合并，绝不剥离音频。
const String dbArkAudioTooShortCode = 'audio_too_short';

/// 单条音频轨的体检结果（ffprobe 一次取全，内部一律换算成毫秒整数比较）。
///
/// 为什么三个时长都要看：
///   切片后的 AAC 可能「元数据写 481s、实际只有 1 个包」，
///   服务端抽出来的仍然只有 8ms；任何一项暴露短时长都必须按短处理。
class _DbAudioHealth {
  final bool hasAudio;
  final String codec;

  /// 流元数据时长（秒）。
  final double metaDur;

  /// 按实际包数估算的时长（秒）：AAC 每包 1024 采样。
  final double packetDur;

  /// 音频轨起点（秒）。
  final double startTime;
  final int packets;

  const _DbAudioHealth({
    required this.hasAudio,
    required this.codec,
    required this.metaDur,
    required this.packetDur,
    required this.startTime,
    required this.packets,
  });

  /// 音频轨起点偏移（毫秒）。
  int get startMs => startTime <= 0 ? 0 : (startTime * 1000).round();

  /// 元数据与包数估算中的较小值（毫秒）；0 = 两者都读不到（按不合格处理）。
  int get metaMs {
    final vals = <int>[];
    if (metaDur > 0) vals.add((metaDur * 1000).round());
    if (packetDur > 0) vals.add((packetDur * 1000).round());
    if (vals.isEmpty) return 0;
    var m = vals.first;
    for (final v in vals) {
      if (v < m) m = v;
    }
    return m;
  }

  /// 需要先本地重建：过短或起点偏移（阈值比服务端下限宽，留修复余量）。
  bool get risky =>
      hasAudio && (metaMs < dbArkAudioSafeMinMs || startMs > dbArkAudioMaxStartMs);

  String get desc => 'codec=$codec 起点=${startMs}ms '
      '元数据=${metaDur > 0 ? '${(metaDur * 1000).round()}ms' : '无'}'
      '${packetDur > 0 ? ' 包数=$packets（约 ${(packetDur * 1000).round()}ms）' : ''}';

  String get riskReason {
    if (!hasAudio) return '无音频轨';
    final why = <String>[];
    if (metaMs < dbArkAudioSafeMinMs) why.add('元数据/包数时长 ${metaMs}ms');
    if (startMs > dbArkAudioMaxStartMs) why.add('起点偏移 ${startMs}ms');
    return why.isEmpty ? '正常' : why.join('，');
  }
}

double _dbParseTimeBase(String tb) {
  final parts = tb.split('/');
  if (parts.length != 2) return 0;
  final n = double.tryParse(parts[0]);
  final d = double.tryParse(parts[1]);
  if (n == null || d == null || d <= 0) return 0;
  return n / d;
}

/// 音频轨体检：把「元数据时长、真实包数、起点偏移」一次取全。
Future<_DbAudioHealth> _dbAudioHealth(File f) async {
  const none = _DbAudioHealth(
    hasAudio: false,
    codec: '',
    metaDur: 0,
    packetDur: 0,
    startTime: 0,
    packets: 0,
  );
  try {
    final r = await Process.run('ffprobe', [
      '-v', 'error',
      '-select_streams', 'a:0',
      '-count_packets',
      '-show_entries',
      'stream=codec_name,duration,duration_ts,time_base,nb_frames,'
          'sample_rate,start_time,nb_read_packets',
      '-of', 'json',
      f.path,
    ]);
    if (r.exitCode != 0) return none;
    final j = asMap(jsonDecode('${r.stdout}'));
    final streams = asList(j['streams']);
    if (streams.isEmpty) return none;
    final s = asMap(streams[0]);
    var meta = double.tryParse(mStr(s, 'duration')) ?? 0;
    if (meta <= 0) {
      final ts = double.tryParse(mStr(s, 'duration_ts')) ?? 0;
      final tb = _dbParseTimeBase(mStr(s, 'time_base'));
      if (ts > 0 && tb > 0) meta = ts * tb;
    }
    final sr = intArgDefault(s, 'sample_rate', 0);
    var packets = intArgDefault(s, 'nb_read_packets', 0);
    if (packets <= 0) packets = intArgDefault(s, 'nb_frames', 0);
    final packetDur = (packets > 0 && sr > 0) ? packets * 1024.0 / sr : 0.0;
    final start = double.tryParse(mStr(s, 'start_time')) ?? 0;
    return _DbAudioHealth(
      hasAudio: true,
      codec: mStr(s, 'codec_name').toLowerCase(),
      metaDur: meta,
      packetDur: packetDur,
      startTime: start < 0 ? 0 : start,
      packets: packets,
    );
  } catch (_) {}
  return none;
}

/// 音频轨条数（整片直传时用于判断是否会被服务端抽到「非主轨」）。
Future<int> _dbAudioTrackCount(File f) async {
  try {
    final r = await Process.run('ffprobe', [
      '-v', 'error',
      '-select_streams', 'a',
      '-show_entries', 'stream=index',
      '-of', 'default=nw=1:nk=1',
      f.path,
    ]);
    if (r.exitCode != 0) return 0;
    return '${r.stdout}'
        .split('\n')
        .where((e) => e.trim().isNotEmpty)
        .length;
  } catch (_) {}
  return 0;
}

/// 视频流时长（秒）；读不到回退容器时长。
Future<double> _dbProbeVideoDurationSec(File f) async {
  try {
    final r = await Process.run('ffprobe', [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=duration',
      '-of', 'default=nw=1:nk=1',
      f.path,
    ]);
    if (r.exitCode == 0) {
      final d = double.tryParse('${r.stdout}'.trim());
      if (d != null && d > 0) return d;
    }
  } catch (_) {}
  return _dbProbeDurationSec(f);
}

/// 解码整条音频，返回真实可解码时长（秒）；失败返回 0。
///
/// 为什么不能只看元数据：切片后的 AAC 可能「元数据写 481s、实际只有 1 个包」，
/// 服务端解码/抽取得到的仍是 8ms。解码到 null 才拿得到真实样本长度。
///
/// ★ 切片时的音频 pts 可能不从 0 开始（例如第 2 段从 20s 起），
///   `out_time_us` 是沿原始时间轴的，所以用「末值 − 首值」算真实跨度，
///   否则 20s 的段会被量成 40s，把坏轨放过去。
Future<double> _dbDecodedAudioSec(File f) async {
  try {
    final r = await Process.run('ffmpeg', [
      '-nostdin', '-hide_banner', '-v', 'error', '-progress', 'pipe:1',
      '-i', f.path, '-map', '0:a:0', '-f', 'null', '-',
    ]);
    final out = '${r.stdout}';
    var first = -1.0;
    var last = 0.0;
    for (final m
        in RegExp(r'^out_time_us=(\d+)', multiLine: true).allMatches(out)) {
      final v = double.tryParse(m.group(1) ?? '') ?? 0;
      if (first < 0) first = v;
      if (v > last) last = v;
    }
    if (last <= 0) return 0;
    if (first > 0 && last >= first) return (last - first) / 1000000;
    return last / 1000000;
  } catch (_) {}
  return 0;
}

/// 可信音频时长（毫秒）：元数据、包数估算、实际解码三者取最小值。
///
/// ★ 时长判断只认 ffprobe / ffmpeg 解出来的真实流时长，
///   绝不读方舟预处理返回的「标注时长」，也不读容器整体时长。
Future<({_DbAudioHealth health, int audioMs})> _dbMeasureAudio(File f) async {
  final h = await _dbAudioHealth(f);
  if (!h.hasAudio) return (health: h, audioMs: 0);
  final decoded = await _dbDecodedAudioSec(f);
  var ms = h.metaMs;
  if (decoded > 0) {
    final dms = (decoded * 1000).round();
    if (ms <= 0 || dms < ms) ms = dms;
  }
  return (health: h, audioMs: ms);
}

/// 原地重建音频轨：保留原音频样本，样本不足处用静音补齐到视频全长；
/// 视频流始终 `-c:v copy`（不重编码、不改画质）。
///
/// 重建失败只返回 false，**绝不剥离音频**：由调用方合并相邻分片或抛错。
Future<bool> _dbRepairAudioInPlace(File seg, {required String label}) async {
  final fixed = File('${seg.path}.audfix.mp4');
  final ok = await _dbRebuildAudioToCopy(src: seg, dst: fixed);
  if (!ok) {
    try {
      if (fixed.existsSync()) fixed.deleteSync();
    } catch (_) {}
    logp('⚠️ $label 音频轨重建失败（保留原文件，不剥离音频）');
    return false;
  }
  final m = await _dbMeasureAudio(fixed);
  final pass = m.health.hasAudio &&
      m.audioMs >= dbArkAudioHardMinMs &&
      m.health.startMs <= dbArkAudioMaxStartMs;
  if (!pass) {
    logp('⚠️ $label 重建后仍不合格：${m.health.desc}，可信 ${m.audioMs}ms');
    try {
      fixed.deleteSync();
    } catch (_) {}
    return false;
  }
  logp('✅ $label 音频轨已重建：${m.health.desc}，可信 ${m.audioMs}ms'
      '（原样本保留，静音补齐，不剥离）');
  try {
    seg.deleteSync();
  } catch (_) {}
  fixed.renameSync(seg.path);
  return true;
}

/// 源片带音轨、但某一段切出来完全没有音轨（音频结束早于视频结尾）时，
/// 补一条与视频等长的静音 AAC 轨 —— 保证「源片有音轨 → 每段都带 audio」。
Future<bool> _dbAddSilentAudioTrack(File seg) async {
  final out = File('${seg.path}.silent.mp4');
  final r = await _dbRunFfmpegWithTicks([
    '-y', '-hide_banner', '-loglevel', 'error',
    '-i', seg.path,
    '-f', 'lavfi', '-i', 'anullsrc=channel_layout=stereo:sample_rate=48000',
    '-map', '0:v:0', '-map', '1:a:0',
    '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
    '-shortest', '-movflags', '+faststart',
    out.path,
  ]);
  if (r.exitCode != 0 || !out.existsSync() || out.lengthSync() <= 0) {
    try {
      if (out.existsSync()) out.deleteSync();
    } catch (_) {}
    return false;
  }
  try {
    seg.deleteSync();
  } catch (_) {}
  out.renameSync(seg.path);
  return true;
}

/// 重建一条「起点 0、长度等于视频」的单一 AAC 音频轨，再与原视频流重新封装。
/// 视频流始终 `-c:v copy`：不重编码、不改分辨率、不改帧率、不丢画质。
///
/// 这一步同时解决三件事：PTS 归零（asetpts）、样本补齐（apad + -t）、
/// 单轨化（只取 a:0），因此无论源片音频多烂，产物都是结构规整的 AAC。
Future<bool> _dbRebuildAudioToCopy({
  required File src,
  required File dst,
  double targetSec = 0,
}) async {
  final vDur = await _dbProbeVideoDurationSec(src);
  final dur = vDur > 0 ? vDur : targetSec;
  if (dur <= 0) return false;
  final tmpA = File('${dst.path}.aud.m4a');
  try {
    final r1 = await _dbRunFfmpegWithTicks([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-i', src.path,
      '-map', '0:a:0', '-vn',
      '-c:a', 'aac', '-b:a', '128k',
      '-af', 'aresample=async=1:first_pts=0,asetpts=PTS-STARTPTS,apad',
      '-t', dur.toStringAsFixed(3),
      '-movflags', '+faststart',
      tmpA.path,
    ]);
    if (r1.exitCode != 0 || !tmpA.existsSync() || tmpA.lengthSync() <= 0) {
      logp('⚠️ 音频轨重建失败（ffmpeg exit=${r1.exitCode}）：'
          '${'${r1.stderr}'.trim()}');
      return false;
    }
    final r2 = await _dbRunFfmpegWithTicks([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-i', src.path, '-i', tmpA.path,
      '-map', '0:v:0', '-map', '1:a:0',
      '-c', 'copy', '-movflags', '+faststart',
      dst.path,
    ]);
    if (r2.exitCode != 0 || !dst.existsSync() || dst.lengthSync() <= 0) {
      logp('⚠️ 音频轨重建后封装失败（ffmpeg exit=${r2.exitCode}）：'
          '${'${r2.stderr}'.trim()}');
      try {
        dst.deleteSync();
      } catch (_) {}
      return false;
    }
    return true;
  } finally {
    try {
      if (tmpA.existsSync()) tmpA.deleteSync();
    } catch (_) {}
  }
}

/// 分段上传前的音频前置校验（唯一合法出口：音频全程保留）。
///
/// 1) 无音频轨 → 源片本身就没音轨，按纯视频放行（合法特例）；
/// 2) 可信时长 ≥10ms 且起点归零 → 直接放行；
/// 3) 不合格 → 原地重建音频轨（保留原样本、静音补齐）；
/// 4) 重建后仍不合格 → 抛 audio_too_short，由调用方合并相邻分片重切。
///
/// ★ 任何情况下都不剥离音频、不生成 noaud 文件、不走无声重试。
Future<({bool hasAudio, bool rebuilt, int audioMs})>
    dbArkEnsureSegmentAudioSafe(
  File seg, {
  required String label,
}) async {
  final m = await _dbMeasureAudio(seg);
  if (!m.health.hasAudio) {
    logp('🔇 $label 无音频轨（源片本身无音轨），按纯视频放行');
    return (hasAudio: false, rebuilt: false, audioMs: 0);
  }
  logp('🎚️ $label 音频体检：${m.health.desc} → 可信 ${m.audioMs}ms');
  if (m.audioMs >= dbArkAudioHardMinMs &&
      m.health.startMs <= dbArkAudioMaxStartMs) {
    return (hasAudio: true, rebuilt: false, audioMs: m.audioMs);
  }
  logp('⚠️ $label 音频不合格（${m.health.riskReason}）→ 重建音频轨（不剥离）');
  final ok = await _dbRepairAudioInPlace(seg, label: label);
  if (!ok) {
    throw DbVideoArkException(
        '$label 音频真实时长不足 ${dbArkAudioHardMinMs}ms 且无法本地修复'
        '（音频已完整保留，绝不剥离；将改用合并相邻分片重试）',
        code: dbArkAudioTooShortCode);
  }
  final m2 = await _dbMeasureAudio(seg);
  return (hasAudio: true, rebuilt: true, audioMs: m2.audioMs);
}

/// 判断异常是否就是方舟的「音频时长过短」400。
bool dbArkIsAudioTooShortError(Object err) {
  final s = '$err'.toLowerCase();
  return s.contains('audio_url duration') ||
      (s.contains('input audio') && s.contains('shorter than the limit')) ||
      (s.contains('duration of the input audio') && s.contains('10ms'));
}

/// 整片直传前的前置拦截：源视频音频轨若会被判 8ms，先生成修复副本再上传。
///
/// 绝不改动用户原文件：需要修复时只在系统临时目录生成一份副本，
/// 由调用方在上传结束后连目录一起清理。
///
/// 返回值里的 [hasAudio] 是「最终上传文件是否仍带音轨」——调用方用它决定
/// `preprocess_configs.video.model` 要不要强制音频能力模型。
/// ★ 修复无法完成时直接抛 audio_too_short，绝不剥离音频降级成无声视频。
Future<({File file, Directory? tempDir, bool hasAudio, String note})>
    dbArkPrepareWholeVideoSafe(File src) async {
  final health = await _dbAudioHealth(src);
  if (!health.hasAudio) {
    logp('🔇 整片无音频轨（纯视频），按原样上传');
    return (file: src, tempDir: null, hasAudio: false, note: '无音频轨');
  }
  final measured = await _dbMeasureAudio(src);
  logp('🎚️ 整片音频体检: ${health.desc} → 可信 ${measured.audioMs}ms');
  // 多音轨也要重建：服务端可能抽取「非主轨」，抽到一条空轨就是 8ms。
  final trackCount = await _dbAudioTrackCount(src);
  final multiTrack = trackCount > 1;
  if (!health.risky && !multiTrack && measured.audioMs >= dbArkAudioHardMinMs) {
    return (file: src, tempDir: null, hasAudio: true, note: '音频正常');
  }
  if (!health.risky && multiTrack) {
    logp('⚠️ 整片存在 $trackCount 条音频轨 → 只保留主轨后上传（原文件不动）');
  } else {
    logp('⚠️ 整片音频异常（${health.riskReason}，可信 ${measured.audioMs}ms）'
        '→ 生成修复副本后上传（原文件不动，不剥离）');
  }
  final tmpDir = Directory.systemTemp.createTempSync('kewe_audfix_');
  final dst = File('${tmpDir.path}/safe.mp4');
  final ok = await _dbRebuildAudioToCopy(src: src, dst: dst);
  if (ok) {
    final m2 = await _dbMeasureAudio(dst);
    final pass = m2.health.hasAudio &&
        m2.audioMs >= dbArkAudioHardMinMs &&
        m2.health.startMs <= dbArkAudioMaxStartMs;
    if (pass) {
      logp('✅ 整片音频已重建: ${m2.health.desc}，可信 ${m2.audioMs}ms（不剥离）');
      return (
        file: dst,
        tempDir: tmpDir,
        hasAudio: true,
        note: '音频已重建',
      );
    }
    logp('⚠️ 整片音频重建后仍不合格: ${m2.health.desc}，可信 ${m2.audioMs}ms');
  } else {
    logp('⚠️ 整片音频重建失败（原文件不动，不剥离）');
  }

  try {
    if (dst.existsSync()) dst.deleteSync();
  } catch (_) {}
  try {
    tmpDir.deleteSync(recursive: true);
  } catch (_) {}
  throw DbVideoArkException(
      '整片音频轨无法修复到 ≥${dbArkAudioHardMinMs}ms'
      '（音频已完整保留，绝不剥离为无声视频）：${src.path}',
      code: dbArkAudioTooShortCode);
}

/// 批量清理临时目录（解密目录、音频修复副本目录）。
void _dbCleanupDirs(List<Directory?> dirs) {
  for (final d in dirs) {
    if (d == null) continue;
    try {
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// 按帧总数规划段数：≤安全帧上限（3000 帧）就是 1 段（整片直传，不分段）。
///
/// [fileBytes] / [maxSegmentBytes] 是「路由层」按目标模型传入的可选约束：
/// 两者都 >0 时才叠加体积维度（如 DeepSeek 1017 的 50MB 上限）。切片内核
/// 默认不读任何体积常数，豆包系列模型保持长分片。
int dbArkPlanSegCount(
  double durationSec,
  double fps, {
  int fileBytes = 0,
  int maxSegmentBytes = 0,
}) {
  if (durationSec <= 0) return 1;
  final f = fps <= 0 ? 1.0 : fps;
  final frames = durationSec * f;
  var n = 1;
  if (frames > dbArkFrameSafePerRequest) {
    n = (frames / dbArkFrameSafePerRequest).ceil();
    if (n < 2) n = 2;
  }
  if (fileBytes > 0 && maxSegmentBytes > 0) {
    final bySize = (fileBytes / maxSegmentBytes).ceil();
    if (bySize > n) n = bySize;
  }
  if (n > 200) n = 200;
  return n;
}

/// 已切好且音频校验通过的分片（时间轴一律毫秒整数，避免浮点尾差）。
class _DbSegPart {
  final File file;
  final int startMs;
  final int endMs;

  /// 等分规划时的「目标结束时间」（毫秒），未做音频帧对齐前的原始值。
  /// 仅用于日志核对：对齐偏移 = endMs - targetEndMs，必须 ≤ 单帧时长。
  final int targetEndMs;

  /// 合并来源说明；空字符串 = 未经合并。
  final String mergeNote;

  bool hasAudio;
  int audioMs;
  bool rebuilt;

  /// 本段最终转写正文；null = 尚未成功。
  String? text;

  /// 本段失败原因；null = 正常。
  String? error;

  _DbSegPart({
    required this.file,
    required this.startMs,
    required this.endMs,
    this.targetEndMs = 0,
    this.mergeNote = '',
    required this.hasAudio,
    required this.audioMs,
    required this.rebuilt,
  });

  double get startSec => startMs / 1000.0;
  double get endSec => endMs / 1000.0;
  double get lenSec => (endMs - startMs) / 1000.0;
}

/// 视频帧率（优先 avg_frame_rate）；读不到按 25 兜底。
Future<double> _dbVideoFps(File f) async {
  try {
    final r = await Process.run('ffprobe', [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=avg_frame_rate,r_frame_rate',
      '-of', 'default=nw=1:nk=1',
      f.path,
    ]);
    if (r.exitCode == 0) {
      for (final line in '${r.stdout}'.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        final parts = t.split('/');
        if (parts.length == 2) {
          final n = double.tryParse(parts[0]);
          final d = double.tryParse(parts[1]);
          if (n != null && d != null && n > 0 && d > 0) return n / d;
        }
        final v = double.tryParse(t);
        if (v != null && v > 0) return v;
      }
    }
  } catch (_) {}
  return 25;
}

/// 音频采样帧栅格：裁切点必须落在「帧结束边界」上。
///
/// 8ms 碎片的根因不是毫秒取整，而是刀口切进了音频采样帧内部：容器里只剩下
/// 不足一帧的残样本，服务端一量就是几毫秒。这里按 a:0 的采样率与编码帧长
/// 算出真实帧栅格，所有分片边界向最近的帧结束点取整（浮动 ≤ 单帧）。
class _DbAudioGrid {
  final double startSec;
  final double frameSec;

  const _DbAudioGrid(this.startSec, this.frameSec);

  bool get valid => frameSec > 0.0001;

  /// 把时间点（秒）对齐到最近的音频帧结束边界。
  double align(double t) {
    if (!valid) return t;
    final idx = ((t - startSec) / frameSec + 0.5).floor();
    return startSec + idx * frameSec;
  }
}

/// 读取 a:0 的采样率 / 编码 / 起始时间，换算音频帧栅格。
///
/// 不整段读帧列表（几分钟的 AAC 就有上万帧，2GB 长片更会拖垮内存与 IO）：
/// 帧长只由编码器每帧样本数与采样率决定，属于常量，解析流元数据即可。
Future<_DbAudioGrid> _dbAudioGrid(File f) async {
  try {
    final r = await Process.run('ffprobe', [
      '-v', 'error',
      '-select_streams', 'a:0',
      '-show_entries', 'stream=sample_rate,codec_name,start_time',
      '-of', 'json',
      f.path,
    ]);
    if (r.exitCode == 0) {
      final j = asMap(jsonDecode('${r.stdout}'));
      final streams = asList(j['streams']);
      if (streams.isNotEmpty) {
        final s = asMap(streams[0]);
        final sr = intArgDefault(s, 'sample_rate', 0);
        final codec = mStr(s, 'codec_name').toLowerCase();
        final start = double.tryParse(mStr(s, 'start_time')) ?? 0;
        if (sr > 0) {
          final frameSamples = switch (codec) {
            'mp3' => 1152,
            'ac3' || 'eac3' => 1536,
            'opus' => 960,
            _ => 1024, // AAC / 其他主流音频编码
          };
          return _DbAudioGrid(start, frameSamples / sr.toDouble());
        }
      }
    }
  } catch (_) {}
  return const _DbAudioGrid(0, 0);
}

/// 视频关键帧时间点（毫秒）。`-c:v copy` 只能从关键帧起切，边界必须落在
/// 关键帧上，否则视频会从上一关键帧开始、时间轴与内容整体前移。
Future<List<int>> _dbKeyframeMs(File f) async {
  try {
    final r = await Process.run('ffprobe', [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_packets',
      '-show_entries', 'packet=pts_time,flags',
      '-of', 'csv=p=0',
      f.path,
    ]);
    if (r.exitCode == 0) {
      final out = <int>[];
      for (final line in '${r.stdout}'.split('\n')) {
        final parts = line.trim().split(',');
        if (parts.length < 2 || !parts[1].startsWith('K')) continue;
        final pts = double.tryParse(parts[0]);
        if (pts == null) continue;
        out.add((pts * 1000).round());
      }
      if (out.isNotEmpty) {
        out.sort();
        return out;
      }
    }
  } catch (_) {}
  return const <int>[];
}

/// 按毫秒区间切一段：视频流 `-c:v copy`（不重编码、不改分辨率/帧率/画质），
/// 音频重编码为 AAC 并用 apad 补齐到段长。
///
/// 为什么音频必须重编码：实测 `-c copy` 切出的片段，AAC 的时长元数据会被
/// 方舟解析成 3.625ms 直接拒收：
///   "The request failed because the duration of the input audio (3.625ms)
///    is shorter than the limit (10ms)"（param: audio_url duration）。
/// 重编码 + apad 后音频轨真实解码时长等于段长，服务端不会再量出 8ms。
Future<File> _dbCutSegment({
  required File src,
  required ({int start, int end, int targetEnd}) range,
  required String outPath,
  required bool srcHasAudio,
  double audioFrameSec = 0,
  void Function(int elapsedSec)? onTick,
}) async {
  final startSec = (range.start / 1000.0).toStringAsFixed(3);
  final lenD = (range.end - range.start) / 1000.0;
  final lenSec = lenD.toStringAsFixed(3);
  // ★ 音频长度向下取整到整数个采样帧：末帧必须是完整帧，否则容器里会
  //   留下不足一帧的残样本，服务端一量就是几毫秒（audio_url 400）。
  var audioLenD = lenD;
  if (srcHasAudio && audioFrameSec > 0.0001) {
    final whole = (lenD / audioFrameSec).floor();
    audioLenD = whole * audioFrameSec;
    if (audioLenD < audioFrameSec) audioLenD = audioFrameSec;
    if (audioLenD > lenD) audioLenD = lenD;
  }
  final audioLenSec = audioLenD.toStringAsFixed(6);
  // ★ 视频必须用「帧数」收口：实测 `-c:v copy` + 输入 seek 时 `-t` 只截住
  //   音频，视频会一路复制到片尾（20s 的段实测写出 40s、内容与时间轴错位）。
  final fps = await _dbVideoFps(src);
  var frames = (lenD * fps).round();
  if (frames < 1) frames = 1;
  frames += 2; // 关键帧对齐余量
  final args = <String>[
    '-y', '-hide_banner', '-loglevel', 'error',
    '-ss', startSec,
    '-i', src.path,
    '-map', '0:v:0',
    // ★ 只取第一条音频轨：`0:a?` 会映射全部音轨，多音轨源片切片后
    //   服务端可能抽到一条空轨/坏轨，量出 8ms 直接 400。
    '-map', srcHasAudio ? '0:a:0' : '0:a:0?',
    '-c:v', 'copy',
    if (srcHasAudio) ...<String>[
      '-c:a', 'aac',
      '-b:a', '128k',
      // 输入 seek 后音频首帧 pts 可能不为 0，异步对齐到 0；
      // apad 补静音到段长，再用 atrim 精确收口到「整帧长度」。
      '-af', 'aresample=async=1:first_pts=0,apad,'
          'atrim=duration=$audioLenSec',
    ],
    // ★ 输出侧 -t 必须放在 -i 之后：放在输入侧只限制「读取多少」，
    //   apad 会无限产帧，封装器会一直写下去（实测卡死十几小时）。
    '-frames:v', '$frames',
    '-t', lenSec,
    '-avoid_negative_ts', 'make_zero',
    '-movflags', '+faststart',
    outPath,
  ];
  final r = await _dbRunFfmpegWithTicks(args, onTick: onTick);
  if (r.exitCode != 0) {
    throw DbVideoArkException(
        '视频切段失败（${_dbClock(range.start / 1000.0)} - '
        '${_dbClock(range.end / 1000.0)}，ffmpeg exit=${r.exitCode}）：'
        '${'${r.stderr}'.trim()}');
  }
  final f = File(outPath);
  if (!f.existsSync() || f.lengthSync() <= 0) {
    throw DbVideoArkException('视频切段失败（无输出）：$outPath');
  }
  return f;
}

/// 等分切段 + 逐段音频前置校验（碎片与相邻段合并重切，不剥离音频）。
///
/// 边界一律用毫秒整数计算：浮点秒乘除是 8ms/9ms 临界误差的高发点。
Future<List<_DbSegPart>> _dbSplitByTime({
  required File src,
  required int segCount,
  required double duration,
  required bool srcHasAudio,
  void Function(int index, int total, int elapsedSec)? onSeg,
}) async {
  final tmpDir = Directory(
      '${Directory.systemTemp.path}/kewe_vseg_${DateTime.now().microsecondsSinceEpoch}');
  tmpDir.createSync(recursive: true);

  final totalMs = (duration * 1000).round();
  if (totalMs <= 0) throw DbVideoArkException('视频时长为 0，无法切段');

  // ★ 双约束，各管各的刀口：
  //   · 视频：`-c:v copy` 只能从关键帧起切，边界必须落在关键帧上，
  //     否则视频会从上一关键帧开始、内容与时间轴整体前移（上一版实测
  //     20s 的段只写进 18.07s 音频，就是被这个前滚截断的）。
  //   · 音频：重编码后长度向下取整到「整数个采样帧」，末帧永远是完整帧，
  //     不会在容器里留下几毫秒的残样本（audio_url duration 400 的源头）。
  //   等分目标只提供方向；两者取整误差都在一帧 / 一个 GOP 内。
  final aGrid = srcHasAudio ? await _dbAudioGrid(src) : const _DbAudioGrid(0, 0);
  if (srcHasAudio) {
    if (aGrid.valid) {
      final frameMs = (aGrid.frameSec * 1000).toStringAsFixed(2);
      logp('🎯 音频帧栅格：起点 ${(aGrid.startSec * 1000).toStringAsFixed(1)}ms，'
          '单帧 $frameMs ms（每段音频长度向下取整到整帧）');
    } else {
      logp('⚠️ 读不到音频帧栅格，音频长度退回毫秒等分（仍会逐段校验 audio 时长）');
    }
  }
  final keyframes = await _dbKeyframeMs(src);
  final bounds = <int>[0];
  final targetByBound = <int>[0];
  for (var i = 1; i < segCount; i++) {
    final target = (totalMs * i) ~/ segCount;
    var b = target;
    int? pick;
    for (final k in keyframes) {
      if (k <= bounds.last + 800) continue;
      if (k >= totalMs - 500) continue;
      if (pick == null || (k - target).abs() < (pick - target).abs()) pick = k;
    }
    if (pick != null && (pick - target).abs() <= 6000) b = pick;
    bounds.add(b);
    targetByBound.add(target);
    final frameMs = aGrid.valid ? (aGrid.frameSec * 1000).toStringAsFixed(2) : '-';
    logp('✂️ 分片边界 ${i}: 目标结束 ${target}ms → 视频关键帧 ${b}ms'
        '（偏移 ${b - target >= 0 ? '+' : ''}${b - target}ms，'
        '音频按 $frameMs ms/帧收整）');
  }
  bounds.add(totalMs);
  targetByBound.add(totalMs);

  final ranges = <({int start, int end, int targetEnd})>[];
  for (var i = 0; i < bounds.length - 1; i++) {
    if (bounds[i + 1] > bounds[i]) {
      ranges.add((
        start: bounds[i],
        end: bounds[i + 1],
        targetEnd: targetByBound[i + 1]
      ));
    }
  }
  // 尾部残段（<500ms）并进上一段，绝不单独成一个分片。
  if (ranges.length > 1 && ranges.last.end - ranges.last.start < 500) {
    final last = ranges.removeLast();
    final prev = ranges.removeLast();
    ranges.add((
      start: prev.start,
      end: last.end,
      targetEnd: last.targetEnd
    ));
  }

  final files = <File>[];
  final rangeMerged = List<bool>.filled(ranges.length, false);
  for (var i = 0; i < ranges.length; i++) {
    onSeg?.call(i, ranges.length, 0);
    files.add(await _dbCutSegment(
      src: src,
      range: ranges[i],
      outPath: '${tmpDir.path}/seg_${i.toString().padLeft(3, '0')}.mp4',
      srcHasAudio: srcHasAudio,
      audioFrameSec: aGrid.frameSec,
      onTick: (sec) => onSeg?.call(i, ranges.length, sec),
    ));
  }

  if (!srcHasAudio) {
    logp('🔇 源片无音频轨：${files.length} 个分片按纯视频上传（合法特例）');
    return <_DbSegPart>[
      for (var i = 0; i < files.length; i++)
        _DbSegPart(
          file: files[i],
          startMs: ranges[i].start,
          endMs: ranges[i].end,
          targetEndMs: ranges[i].targetEnd,
          hasAudio: false,
          audioMs: 0,
          rebuilt: false,
        ),
    ];
  }

  // 逐段前置校验：<10ms 的音轨先本地重建；重建不回来的与相邻段合并重切。
  var guard = 0;
  while (true) {
    var bad = -1;
    for (var i = 0; i < files.length; i++) {
      final m = await _dbMeasureAudio(files[i]);
      if (!m.health.hasAudio) {
        // 源片有音轨、这段却没有：补静音轨，绝不按「无音频」上传。
        logp('⚠️ 第 ${i + 1}/${files.length} 段切出来没有音轨'
            '（源片有音轨）→ 补静音轨后上传（不改成无音频）');
        if (await _dbAddSilentAudioTrack(files[i])) continue;
        bad = i;
        break;
      }
      final pass = m.audioMs >= dbArkAudioHardMinMs &&
          m.health.startMs <= dbArkAudioMaxStartMs;
      if (pass) {
        logp('✅ 第 ${i + 1}/${files.length} 段音频校验通过'
            '（可信 ${m.audioMs}ms，起点 ${m.health.startMs}ms）');
        continue;
      }
      logp('⚠️ 第 ${i + 1}/${files.length} 段音频不合格'
          '（${m.health.riskReason}，可信 ${m.audioMs}ms）'
          '→ 本地重建音频轨（保留原样本，不剥离）');
      if (await _dbRepairAudioInPlace(files[i],
          label: '第 ${i + 1}/${files.length} 段')) {
        final m2 = await _dbMeasureAudio(files[i]);
        logp('✅ 第 ${i + 1}/${files.length} 段重建后通过'
            '（可信 ${m2.audioMs}ms）');
        continue;
      }
      bad = i;
      break;
    }
    if (bad < 0) break;

    // 合并：与相邻分片并成一段，重新切割、重新探测（全程保留音频）。
    if (files.length <= 1) {
      throw DbVideoArkException(
          '整片只有 1 个分片：'
          '对齐裁切、分片合并均已尝试，仍触发校验，需核查该模型接口规则',
          code: dbArkAudioTooShortCode);
    }
    guard++;
    if (guard > ranges.length + 5) {
      throw DbVideoArkException(
          '音频碎片合并次数异常（$guard 次），已中止；音频始终完整保留',
          code: dbArkAudioTooShortCode);
    }
    final nb = bad > 0 ? bad - 1 : bad + 1;
    final s = ranges[bad].start < ranges[nb].start
        ? ranges[bad].start
        : ranges[nb].start;
    final e = ranges[bad].end > ranges[nb].end
        ? ranges[bad].end
        : ranges[nb].end;
    final tEnd = ranges[bad].targetEnd > ranges[nb].targetEnd
        ? ranges[bad].targetEnd
        : ranges[nb].targetEnd;
    for (final k in <int>[bad, nb]) {
      try {
        files[k].deleteSync();
      } catch (_) {}
    }
    final keep = bad < nb ? bad : nb;
    final drop = bad > nb ? bad : nb;
    logp('🔗 第 ${bad + 1}/${files.length} 段与相邻段合并为 '
        '${_dbClock(s / 1000.0)} - ${_dbClock(e / 1000.0)}'
        '（${e - s}ms）后重切（音频不剥离）');
    ranges[keep] = (start: s, end: e, targetEnd: tEnd);
    files[keep] = await _dbCutSegment(
      src: src,
      range: (start: s, end: e, targetEnd: tEnd),
      outPath: '${tmpDir.path}/seg_merge_${guard}_${s}_$e.mp4',
      srcHasAudio: true,
      audioFrameSec: aGrid.frameSec,
      onTick: (sec) => onSeg?.call(keep, ranges.length, sec),
    );
    ranges.removeAt(drop);
    files.removeAt(drop);
    rangeMerged[keep] = true;
    rangeMerged.removeAt(drop);
  }

  final parts = <_DbSegPart>[];
  for (var i = 0; i < files.length; i++) {
    final m = await _dbMeasureAudio(files[i]);
    parts.add(_DbSegPart(
      file: files[i],
      startMs: ranges[i].start,
      endMs: ranges[i].end,
      targetEndMs: ranges[i].targetEnd,
      mergeNote: rangeMerged[i] ? '源分段碎片合并' : '',
      hasAudio: m.health.hasAudio,
      audioMs: m.audioMs,
      rebuilt: false,
    ));
  }
  logp('🎬 分段完成：${parts.length} 段，全部通过音频前置校验（≥${dbArkAudioHardMinMs}ms）');
  return parts;
}

/// ffmpeg 执行期间每 2 秒回调一次耗时（避免长时间无事件）。
Future<ProcessResult> _dbRunFfmpegWithTicks(
  List<String> args, {
  void Function(int elapsedSec)? onTick,
}) async {
  final t0 = DateTime.now();
  final ticker = Timer.periodic(const Duration(seconds: 2), (_) {
    onTick?.call(DateTime.now().difference(t0).inSeconds);
  });
  try {
    return await Process.run('ffmpeg', args);
  } finally {
    ticker.cancel();
  }
}

/// 单次「带视频的 chat 请求」：返回正文与结束原因。
/// finish == 'length' 表示输出被 max_tokens 截断，调用方必须续写补齐。
Future<({String text, String finish})> _dbArkChatOnce({
  required String apiKey,
  required String model,
  required List<Map<String, dynamic>> messages,
  required int maxTokens,
}) async {
  final body = <String, dynamic>{
    'model': model,
    'messages': messages,
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
  final choice = asMap(choices[0]);
  final msg = asMap(choice['message']);
  var text = mStr(msg, 'content').trim();
  if (text.isEmpty) text = mStr(msg, 'reasoning_content').trim();
  final finish = mStr(choice, 'finish_reason').trim().toLowerCase();
  return (text: text, finish: finish);
}

/// 用 file_id 做完整转写（内部自动续写，直到写完或达到轮数上限）。
///
/// ★ 为什么必须续写：服务端把 max_tokens 用完时返回 finish_reason=length，
///   正文会在半句处断掉。旧实现只发一次请求、默认 8000 token，
///   长片段的记录必然被截断 —— 这是「长视频细节不全」最直接的丢细节点。
///   续写轮次不再附带视频（视觉特征已在第一轮进入上下文），
///   只把已写正文作为 assistant 上文接下去写，避免重复计视频 token。
Future<String> _dbArkChatByFileId({
  required String apiKey,
  required String model,
  required String fileId,
  required String prompt,
  int maxTokens = 32000,
  void Function(int chars)? onProgress,
}) async {
  final budget = maxTokens <= 0 ? 32000 : maxTokens;
  final buf = StringBuffer();
  for (var round = 0; round < 3; round++) {
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'user',
        'content': <Map<String, dynamic>>[
          if (round == 0)
            <String, dynamic>{
              'type': 'video_url',
              'video_url': <String, dynamic>{'file_id': fileId},
            },
          <String, dynamic>{'type': 'text', 'text': prompt},
        ],
      },
      if (buf.isNotEmpty) ...<Map<String, dynamic>>[
        <String, dynamic>{'role': 'assistant', 'content': buf.toString()},
        <String, dynamic>{
          'role': 'user',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'text': '上文是你正在写的这份记录，被输出长度上限截断了。'
                  '请从中断处继续写，直接接着输出剩下的部分：'
                  '不要重复已有内容，不要写任何说明、标题或总结。',
            },
          ],
        },
      ],
    ];
    final r = await _dbArkChatOnce(
      apiKey: apiKey,
      model: model,
      messages: messages,
      maxTokens: budget,
    );
    if (r.text.isNotEmpty) buf.write(r.text);
    onProgress?.call(runeLen(buf.toString()));
    if (r.finish != 'length') break;
    logp('🎞️ 转写被输出上限截断（第 ${round + 1} 轮，'
        '已 ${runeLen(buf.toString())} 字），自动续写');
  }
  final text = buf.toString().trim();
  if (text.isEmpty) {
    throw DbVideoArkException('视频分段理解返回空内容');
  }
  return text;
}

/// 段转写 + 每 2 秒上报一次耗时（非流式请求期间界面不会假死）。
Future<String> _dbArkDescribeSegment({
  required String apiKey,
  required String model,
  required String fileId,
  required String prompt,
  required int maxTokens,
  void Function(int chars)? onChars,
  void Function(int elapsedSec)? onTick,
}) async {
  final t0 = DateTime.now();
  final ticker = Timer.periodic(const Duration(seconds: 2), (_) {
    onTick?.call(DateTime.now().difference(t0).inSeconds);
  });
  try {
    return await _dbArkChatByFileId(
      apiKey: apiKey,
      model: model,
      fileId: fileId,
      prompt: prompt,
      maxTokens: maxTokens,
      onProgress: onChars,
    );
  } finally {
    ticker.cancel();
  }
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

/// 分段完整理解：逐段上传（fps 严格等于配置值，不降帧）、
/// 逐段做完整转写，最后按全片时间轴拼接成一份连续记录。
///
/// ★ 音频纪律（2026-11-25 六修）：全程保留音频。8ms 400 的处理顺序是
///   本地前置校验 → 重建音频轨 → 与相邻分片合并重切（≤3 次）→ 仍不合格如实中止；
///   任何分支都不得剥离音轨、不得生成 noaud 文件、不得无声重试、不得换模型重试。
Future<String> dbDescribeVideoInSegments({
  required File file,
  required String fileName,
  required DbVideoArkConfig cfg,
  required String apiKey,
  required int segCount,
  required double duration,
  required String model,
  void Function(Map<String, dynamic> info)? onProgress,
}) async {
  final fps = cfg.fps <= 0 ? 1.0 : cfg.fps;
  // ★ 推理模型必须用调用方本次真正路由到的模型（model 参数），
  //   不能拿 preprocessModel 顶替：后者只决定上传时的音频预处理能力，
  //   两者混用会导致「路由到 DeepSeek 1017、实际却用 2.1-lite 转写」。
  final inferenceModel = model.trim().isNotEmpty
      ? model.trim()
      : 'doubao-seed-2-1-lite-260915';
  // 推理模型与预处理模型是两件事：预处理必须显式指定模型（否则音频不被
  // 抽出、只剩 8ms 占位）；推理模型保持用户配置，绝不做静默替换。
  final srcHasAudio = (await _dbAudioHealth(file)).hasAudio;
  Directory? tmpDir;
  var uploadSeq = 0;
  try {
    onProgress?.call({'stage': 'seg_split', 'segments': segCount});
    final parts = await _dbSplitByTime(
      src: file,
      segCount: segCount,
      duration: duration,
      srcHasAudio: srcHasAudio,
      onSeg: (i, total, elapsedSec) {
        onProgress?.call({
          'stage': 'seg_split',
          'segment': i + 1,
          'segments': total,
          'percent': ((i + 1) * 100) ~/ total,
          'elapsed': elapsedSec,
        });
      },
    );
    tmpDir = parts.first.file.parent;
    logp('🎬 ${fileName}: 分段 ${parts.length} 段，'
        '音轨=${srcHasAudio ? '有（全程保留）' : '无（源片本身无音轨）'}');

    /// 上传 → 等预处理 → 转写，这一个分片完整跑完才返回正文。
    Future<String> describePart({
      required int index,
      required _DbSegPart p,
      required String uploadName,
      required String ppModel,
      required int maxTokens,
    }) async {
      final segSize = p.file.lengthSync();
      final up = await _dbArkUploadWithModelFallback(
        file: p.file,
        fileName: uploadName,
        bucket: cfg.tosBucket,
        prefix: cfg.tosPrefix,
        model: ppModel,
        apiKey: apiKey,
        fps: fps,
        maxVideoTokens: cfg.maxVideoTokens,
        minFrames: cfg.minFrames,
        label: '第 ${index + 1}/${parts.length} 段',
      );
      final fileId = up.fileId;
      await dbArkWaitFileActive(
        apiKey: apiKey,
        fileId: fileId,
        timeout: dbArkPreprocessTimeoutFor(segSize),
        onTick: (status, waitedSec) {
          onProgress?.call({
            'stage': 'preprocess',
            'segment': index + 1,
            'segments': parts.length,
            'status': status,
            'waited': waitedSec,
          });
        },
      );
      onProgress?.call({
        'stage': 'describe',
        'segment': index + 1,
        'segments': parts.length,
        'chars': 0,
      });
      logp('🧠 第 ${index + 1}/${parts.length} 段转写开始'
          '（段长 ${_dbClock(p.lenSec)}，预算 $maxTokens token，'
          '文件 ${dbFmtSize(segSize)}）');
      return _dbArkDescribeSegment(
        apiKey: apiKey,
        model: inferenceModel,
        fileId: fileId,
        prompt: _dbSegFullPrompt(
          videoName: fileName,
          index: index,
          total: parts.length,
          startSec: p.startSec,
          endSec: p.endSec,
        ),
        maxTokens: maxTokens,
        onChars: (chars) => onProgress?.call({
          'stage': 'describe',
          'segment': index + 1,
          'segments': parts.length,
          'chars': chars,
        }),
        onTick: (sec) => onProgress?.call({
          'stage': 'describe',
          'segment': index + 1,
          'segments': parts.length,
          'elapsed': sec,
        }),
      );
    }

    // ★ 段级容错：一段失败（上传 / 预处理 / 转写任一环节）只标记该段，
    //   绝不能让整段循环中断；只有「音频时长不足且合并 3 次仍修不好」
    //   才会按铁律中止整个任务（绝不剥离音频降级通关）。
    final okBlocks = <String>[];
    final failedNotes = <String>[];

    var i = 0;
    while (i < parts.length) {
      var p = parts[i];
      if (p.text != null) {
        i++;
        continue;
      }
      var segLabel = '第 ${i + 1}/${parts.length} 段';
      onProgress?.call({
        'stage': 'segment_start',
        'segment': i + 1,
        'segments': parts.length,
        'start': p.startMs ~/ 1000,
        'end': p.endMs ~/ 1000,
      });

      var merges = 0;

      // 合并相邻分片并重试（音频全程保留）；合并 3 次仍不合格则中止任务。
      Future<void> mergeAndRetry(Object? cause) async {
        merges++;
        if (merges > 3) {
          throw DbVideoArkException(
              '$segLabel 音频被判过短（$cause）：'
              '对齐裁切、分片合并均已尝试，仍触发校验，需核查该模型接口规则',
              code: dbArkAudioTooShortCode);
        }
        logp('⚠️ $segLabel 音频仍被判过短（$cause）→ '
            '与相邻分片合并后重试（第 $merges/3 次，音频不剥离）');
        i = await _dbMergeSegParts(
          parts,
          i,
          src: file,
          srcHasAudio: srcHasAudio,
        );
        p = parts[i];
        segLabel = '第 ${i + 1}/${parts.length} 段';
      }

      while (true) {
        try {
          // ★ 上传前最后一道音频校验：任何 <10ms 都在这里被拦下；
          //   不合格先重建音频轨，绝不剥离。
          ({bool hasAudio, bool rebuilt, int audioMs}) gate;
          try {
            gate = await dbArkEnsureSegmentAudioSafe(p.file, label: segLabel);
          } on DbVideoArkException catch (e) {
            if (e.code != dbArkAudioTooShortCode) rethrow;
            await mergeAndRetry(e.message);
            continue;
          }
          p.hasAudio = gate.hasAudio;
          p.audioMs = gate.audioMs;
          p.rebuilt = gate.rebuilt;
          var ppModel = dbArkVideoPreprocessModel(
            configured: cfg.preprocessModel,
            hasAudio: p.hasAudio,
            inference: inferenceModel,
          );
          logp('🎛️ $segLabel 预处理模型: $ppModel'
              '（音轨=${p.hasAudio ? '有' : '无'}，推理模型=$inferenceModel）');
          final alignOff = p.endMs - p.targetEndMs;
          final tAlign = p.startMs + p.audioMs;
          final audioOff = tAlign - p.endMs;
          logp('📊 分片清单 | 段=${i + 1}/${parts.length} | '
              '等分目标=${p.targetEndMs}ms | 裁切T=${p.endMs}ms'
              '（视频关键帧，规划偏移=${alignOff >= 0 ? '+' : ''}${alignOff}ms） | '
              'T_align=${tAlign}ms | 音频对齐偏移='
              '${audioOff >= 0 ? '+' : ''}${audioOff}ms | '
              '音频=${p.audioMs}ms | 大小=${dbFmtSize(p.file.lengthSync())} | '
              '路由模型=$inferenceModel | '
              '合并=${p.mergeNote.isEmpty ? '否' : '是（${p.mergeNote}）'}');

          // ★ 唯一自愈路径：服务端仍判「音频过短」→ 与相邻分片合并重切
          //   （最多 3 次）。不做「分片二次预处理 / 换预处理模型 / _audpp 变体
          //   重传」——这些是已被证伪的偷懒兜底，只会掩盖刀口问题。
          final segBudget = dbVideoTranscriptMaxTokens(
              p.lenSec > 0 ? p.lenSec : duration / parts.length);
          Object? audioErr;
          String? text;
          try {
            text = await describePart(
              index: i,
              p: p,
              uploadName: _dbSegFileName(fileName, i, parts.length,
                  variant: uploadSeq++),
              ppModel: ppModel,
              maxTokens: segBudget,
            );
          } catch (e) {
            if (!dbArkIsAudioTooShortError(e)) rethrow;
            audioErr = e;
          }
          if (audioErr != null) {
            await mergeAndRetry(audioErr);
            continue;
          }

          p.text = text;
          logp('🎬 $segLabel 完整理解完成'
              '（${_dbClock(p.startSec)}-${_dbClock(p.endSec)}，'
              '${runeLen(text ?? '')} 字）');
          onProgress?.call({
            'stage': 'segment_done',
            'segment': i + 1,
            'segments': parts.length,
            'percent': ((i + 1) * 100) ~/ parts.length,
          });
          break;
        } catch (e) {
          // 音频碎片无法修复属于致命项：按铁律中止任务，
          // 绝不像旧实现那样剥离音频后假装成功。
          if (e is DbVideoArkException && e.code == dbArkAudioTooShortCode) {
            rethrow;
          }
          p.error = '$segLabel（${_dbClock(p.startSec)} - '
              '${_dbClock(p.endSec)}）：$e';
          logp('⚠️ ${p.error} —— 跳过该段，继续处理其余分段');
          onProgress?.call({
            'stage': 'segment_failed',
            'segment': i + 1,
            'segments': parts.length,
            'error': '$e',
          });
          break;
        }
      }
      i++;
    }

    for (final p in parts) {
      if (p.text != null) {
        okBlocks.add(parts.length > 1
            ? '【${_dbClock(p.startSec)} - ${_dbClock(p.endSec)}】\n${p.text}'
            : p.text!);
      }
      if (p.error != null) failedNotes.add(p.error!);
    }

    if (okBlocks.isEmpty) {
      throw DbVideoArkException(
          '全部分段理解失败：${failedNotes.join('；')}');
    }

    final body = okBlocks.join('\n\n');
    if (parts.length == 1 && failedNotes.isEmpty) return body;
    final failedSuffix = failedNotes.isEmpty
        ? ''
        : '\n\n【未能理解的段落（原片对应时间轴，内容缺失，请勿臆补）】\n'
            '${failedNotes.join('\n')}';
    return '''【《$fileName》完整理解 · 全片 ${_dbClock(duration)} · ${_dbFpsStr(fps)} fps · 等分 ${parts.length} 段】
（下面按全片时间轴顺序连续记录；分段只为绕过方舟「单次请求 3600 帧」的上限，内容本身是一整条视频，段与段自然衔接。）

$body$failedSuffix''';
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

/// 把第 i 段与相邻分片合并、重新切割并做音频前置校验；
/// 返回合并后所在的下标。全程保留音频，绝不剥离。
Future<int> _dbMergeSegParts(
  List<_DbSegPart> parts,
  int i, {
  required File src,
  required bool srcHasAudio,
}) async {
  var idx = i;
  var guard = 0;
  final aGrid = srcHasAudio ? await _dbAudioGrid(src) : const _DbAudioGrid(0, 0);
  while (parts.length > 1) {
    guard++;
    if (guard > parts.length + 3) break;
    final nb = idx > 0 ? idx - 1 : idx + 1;
    final s = parts[idx].startMs < parts[nb].startMs
        ? parts[idx].startMs
        : parts[nb].startMs;
    final e = parts[idx].endMs > parts[nb].endMs
        ? parts[idx].endMs
        : parts[nb].endMs;
    final tEnd = parts[idx].targetEndMs > parts[nb].targetEndMs
        ? parts[idx].targetEndMs
        : parts[nb].targetEndMs;
    final tmpPath =
        '${parts[idx].file.parent.path}/seg_merge_srv_${s}_${e}_'
        '${DateTime.now().microsecondsSinceEpoch}.mp4';
    final f = await _dbCutSegment(
      src: src,
      range: (start: s, end: e, targetEnd: tEnd),
      outPath: tmpPath,
      srcHasAudio: srcHasAudio,
      audioFrameSec: aGrid.frameSec,
    );
    var hasAudio = false;
    var audioMs = 0;
    var rebuilt = false;
    var ok = true;
    try {
      final gate = await dbArkEnsureSegmentAudioSafe(
        f,
        label: '合并段 ${_dbClock(s / 1000.0)}-${_dbClock(e / 1000.0)}',
      );
      hasAudio = gate.hasAudio;
      audioMs = gate.audioMs;
      rebuilt = gate.rebuilt;
    } on DbVideoArkException catch (err) {
      if (err.code != dbArkAudioTooShortCode) rethrow;
      ok = false;
    }
    if (!ok) {
      try {
        f.deleteSync();
      } catch (_) {}
      // 这一段合起来还是修不好：继续并到更远的相邻段（范围更大、音频更多）。
      idx = nb;
      continue;
    }
    final keep = idx < nb ? idx : nb;
    final drop = idx > nb ? idx : nb;
    try {
      parts[keep].file.deleteSync();
    } catch (_) {}
    try {
      parts[drop].file.deleteSync();
    } catch (_) {}
    final merged = _DbSegPart(
      file: f,
      startMs: s,
      endMs: e,
      targetEndMs: tEnd,
      mergeNote: '服务端400后与第 ${nb + 1} 段合并',
      hasAudio: hasAudio,
      audioMs: audioMs,
      rebuilt: rebuilt,
    );
    parts.removeAt(drop);
    parts[keep] = merged;
    logp('🔗 分片已合并：${_dbClock(s / 1000.0)} - ${_dbClock(e / 1000.0)}'
        '（${e - s}ms，音频 ${audioMs}ms，未剥离）');
    return keep;
  }
  throw DbVideoArkException(
      '音频仍被判过短且已无可合并的相邻分片：'
      '对齐裁切、分片合并均已尝试，仍触发校验，需核查该模型接口规则',
      code: dbArkAudioTooShortCode);
}

/// 段文件名：ASCII、带段号；[variant] 保证每次重传都是新名字，
/// 避免 TOS 同名覆盖（合并 / 重试后段号可能重复使用）。
String _dbSegFileName(String videoName, int index, int total,
    {int variant = 0}) {
  var base = videoName.trim();
  final dot = base.lastIndexOf('.');
  var stem = dot > 0 ? base.substring(0, dot) : base;
  final ext = dot > 0 ? base.substring(dot).toLowerCase() : '.mp4';
  if (stem.length > 50) stem = stem.substring(0, 50);
  stem = stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (stem.isEmpty) stem = 'video';
  final no = (index + 1).toString().padLeft(2, '0');
  final all = total.toString().padLeft(2, '0');
  final v = variant > 0 ? '_v$variant' : '';
  return '${stem}_s${no}of$all$v$ext';
}
