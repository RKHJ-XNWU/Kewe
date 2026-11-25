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
  /// 超过预算会自动下调 fps，避免服务端预处理超时。
  int frameBudget;

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

    // ---------- 整片直传：唯一通道 ----------
    // ★ 2026-11-25 三次修复（用户明确要求，不再改动）：
    //   不切片、不分段、不降帧、不重试。每个视频原样整片送方舟 TOS
    //   预处理，模型直接看完整视频；成功与否只取决于方舟对整片的
    //   预处理结果，本地不做任何降级改写（切片会把长视频拆成几十段，
    //   汇总后的二手描述必然丢细节，这正是「理解内容跟原片差很多」的根因）。
    if (cfg.tosBucket.trim().isEmpty) {
      throw DbVideoArkException(
          '未配置 tosBucket：整片直传需要 TOS Bucket（≥50MB 的视频无法走 '
          'base64）；已按「禁止分段」策略停止：${meta.name}（${dbFmtSize(size)}）',
          code: 'tos_not_configured');
    }
    onProgress?.call({...tag, 'stage': 'tos_reference', 'size': size});
    final part = await dbArkVideoPartForLocalFile(
      absPath: absPath,
      fileName: meta.name,
      model: model,
      apiKey: apiKey,
      onProgress: (info) => onProgress?.call({...tag, ...info}),
    );
    parts.add(part);
    logp('🎬 整片直传发送: ${meta.name}（${dbFmtSize(size)}）');
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
        '说明：方舟对单视频有约 15 分钟的时长上限，超过就一律报 '
        '"Timeout occurred while processing video"（实测 15 分钟可成功，'
        '20 分钟与 23 分 42 秒必失败），与文件体积、fps 取值、token 预算'
        '均无关。当前策略已禁止切片，不会自动降级分段。',
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
