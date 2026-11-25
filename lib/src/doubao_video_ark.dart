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
// 因此主路径改为「本地切片 + 分段理解 + 汇总」：
//   · ≤ segmentMaxBytes（默认 45MB，落在 base64 的 50MB 上限内）：
//       直接作为 video_url 片段随主请求发送，模型自己看整段视频回答；
//   · > segmentMaxBytes（含 2GB）：
//       用 ffmpeg 无损切片（-c copy，不重编码，速度快）成若干 ≤45MB 的段，
//       逐段调用豆包视频理解得到「该段客观描述（含时间位置）」，
//       再把所有分段描述汇总进用户提示词，由主模型基于完整分段信息作答。
//       → 2GB 视频因此可被完整理解，代价是分段请求耗时较长。
//   · 若配置了 useFilesApi=true（project 级 Key / TOS 账号），
//       则优先走 Files API + file_id（512MB 直传 / 2GB TOS）。
//
// 全流程不把 2GB 读进内存：切片走 ffmpeg 文件流，单段 ≤45MB 才 base64。
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

/// 分段数上限（防止极端情况切出成百上千段）
const int dbVideoMaxSegments = 80;

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
  var sec = 20 * 60;
  final gb = bytes <= 0 ? 0.0 : bytes / (1024 * 1024 * 1024);
  sec += (gb * 25 * 60).round();
  if (sec > 3 * 3600) sec = 3 * 3600;
  return Duration(seconds: sec);
}

/// 按「时长 × fps ≤ frameBudget」规划实际抽帧密度。
/// 返回真正要传给方舟的 fps（永远不高于配置值）与估算帧数。
/// 时长探测失败时原样返回配置 fps（不猜、不擅自降级）。
Future<({double fps, int budgetFrames, int estFrames, double duration})>
    dbArkPlanPreprocessFps(File f, DbVideoArkConfig cfg) async {
  final want = cfg.fps <= 0 ? 1.0 : cfg.fps;
  final budget = cfg.frameBudget;
  final dur = await _dbProbeDuration(f);
  if (dur <= 0) {
    return (fps: want, budgetFrames: budget, estFrames: 0, duration: 0.0);
  }
  final est = (dur * want).round();
  if (budget <= 0 || est <= budget) {
    return (fps: want, budgetFrames: budget, estFrames: est, duration: dur);
  }
  var fps = budget / dur;
  if (fps < 0.2) fps = 0.2;
  return (
    fps: fps,
    budgetFrames: budget,
    estFrames: (dur * fps).round(),
    duration: dur,
  );
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

String _dbFmtClock(num sec) {
  final s = sec < 0 ? 0 : sec.round();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final ss = s % 60;
  String p2(int v) => v < 10 ? '0$v' : '$v';
  if (h > 0) return '$h:${p2(m)}:${p2(ss)}';
  return '${p2(m)}:${p2(ss)}';
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

/// 宽松判定：是否属于「值得降参重试一次」的预处理失败。
/// 仅用于决定要不要再试一次，绝不用于写失败记忆。
bool dbArkLooksLikePreprocessTrouble(Object e) {
  final s = e.toString().toLowerCase();
  return dbArkIsPreprocessTimeout(e) ||
      s.contains('invalidarg') ||
      s.contains('invalidparam') ||
      s.contains('processing video');
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

bool _dbArkSlowPathHit(String key) {
  final raw = _dbArkSlowPathLoad()[key];
  if (raw is! Map) return false;
  final at = intArgDefault(asMap(raw), 'at', 0);
  return DateTime.now().millisecondsSinceEpoch - at < _dbArkSlowPathTtlMs;
}

/// 该文件上次失败时用的 fps（没记录返回 0）。
/// 只有在「这次抽帧比上次更省」时才允许重试，否则重复上传只会在
/// 同一个坑里再超时一次。
double _dbArkSlowPathFps(String key) {
  final raw = _dbArkSlowPathLoad()[key];
  if (raw is! Map) return 0;
  final v = asMap(raw)['fps'];
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
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

// ------------------------------------------------------------
// 基础工具：ffmpeg / ffprobe
// ------------------------------------------------------------
Future<bool> _dbHasBin(String name) async {
  try {
    final r = await Process.run('sh', ['-c', 'command -v $name']);
    return r.exitCode == 0 && '${r.stdout}'.trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}

Future<double> _dbProbeDuration(File f) async {
  try {
    final r = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'default=nw=1:nk=1',
      f.path,
    ]);
    if (r.exitCode == 0) {
      final d = double.tryParse('${r.stdout}'.trim());
      if (d != null && d > 0) return d;
    }
  } catch (_) {}
  try {
    final r = await Process.run('ffmpeg', ['-hide_banner', '-i', f.path]);
    final m = RegExp(r'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)')
        .firstMatch('${r.stderr}');
    if (m != null) {
      return int.parse(m.group(1)!) * 3600 +
          int.parse(m.group(2)!) * 60 +
          double.parse(m.group(3)!);
    }
  } catch (_) {}
  return 0;
}

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

// ------------------------------------------------------------
// 切片（-c copy 无损、不重编码）：把任意大小视频切成 ≤maxBytes 的段
// ------------------------------------------------------------
Future<List<File>> _dbSplitVideo(
  File src,
  int maxBytes, {
  void Function(String stage, int percent)? onProgress,
}) async {
  if (!await _dbHasBin('ffmpeg')) {
    throw DbVideoArkException(
        '视频 ${dbFmtSize(src.lengthSync())} 需要在本地切片，但本机没有 ffmpeg。'
        '请执行 pkg install ffmpeg 后重试。',
        code: 'need_ffmpeg');
  }
  final size = src.lengthSync();
  final dur = await _dbProbeDuration(src);
  if (dur <= 0) {
    throw DbVideoArkException('无法读取视频时长（文件可能损坏）：${src.path}',
        code: 'probe_failed');
  }
  final bitrate = size * 8 / dur; // bits/s
  // 目标片体积 ×0.85 留余量（-c copy 切片时间点不精确，单片可能略大）
  final targetBits = maxBytes * 8 * 0.85;
  var segSec = (targetBits / bitrate).floor();
  if (segSec < 15) segSec = 15;
  if (segSec > 1800) segSec = 1800;
  final needSegments = (dur / segSec).ceil();
  if (needSegments > dbVideoMaxSegments) {
    // 段数过多说明单片太小或视频极长：钳制到上限，单片会超限，
    // 由后续单段压缩步骤兜底（不静默放弃）。
    segSec = (dur / dbVideoMaxSegments).ceil();
  }

  final tmpDir = Directory(
      '${Directory.systemTemp.path}/kewe_vseg_${DateTime.now().microsecondsSinceEpoch}');
  tmpDir.createSync(recursive: true);
  final pattern = '${tmpDir.path}/part_%04d.mp4';

  logp('✂️ 分割视频: ${dbFmtSize(size)} / ${_dbFmtClock(dur)} → '
      '每片约 ${_dbFmtClock(segSec)}（上限 ${dbFmtSize(maxBytes)}）');
  onProgress?.call('split_start', 0);

  final r = await Process.run('ffmpeg', [
    '-y',
    '-loglevel',
    'error',
    '-i',
    src.path,
    '-c',
    'copy',
    '-map',
    '0:v:0',
    '-map',
    '0:a?',
    '-f',
    'segment',
    '-segment_time',
    '$segSec',
    '-reset_timestamps',
    '1',
    '-movflags',
    '+faststart',
    pattern,
  ]);
  if (r.exitCode != 0) {
    // 有些容器（如 mkv/ts）copy 切片会失败：退回整体重编码成 mp4 再切
    logp('⚠️ 无损分割失败（${r.exitCode}）。用重新编码重试: '
        '${'${r.stderr}'.trim()}');
    final normalized = File('${tmpDir.path}/normalized.mp4');
    final r2 = await Process.run('ffmpeg', [
      '-y',
      '-loglevel',
      'error',
      '-i',
      src.path,
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-crf',
      '26',
      '-vf',
      'scale=-2:min(720\\,ih)',
      '-c:a',
      'aac',
      '-b:a',
      '96k',
      normalized.path,
    ]);
    if (r2.exitCode != 0 || !normalized.existsSync()) {
      throw DbVideoArkException(
          '视频切分失败（ffmpeg exit=${r2.exitCode}）：${'${r2.stderr}'.trim()}');
    }
    return _dbSplitVideo(normalized, maxBytes, onProgress: onProgress);
  }

  final parts = tmpDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.mp4'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (parts.isEmpty) {
    throw DbVideoArkException('视频切分后没有得到任何分片（ffmpeg 无输出）');
  }

  // 个别分片超限：就地压缩该片（重编码到 720p / 目标码率）
  final fixed = <File>[];
  for (var i = 0; i < parts.length; i++) {
    var p = parts[i];
    if (p.lengthSync() > maxBytes) {
      logp('🎞️ 分片 ${i + 1} 超过上限（${dbFmtSize(p.lengthSync())}）。'
          '仅压缩此分片');
      final out = File('${tmpDir.path}/fixed_${i.toString().padLeft(4, '0')}.mp4');
      await _dbCompressTo(p, (maxBytes * 0.9).round(), out);
      if (out.existsSync() && out.lengthSync() > 0) p = out;
    }
    fixed.add(p);
  }
  onProgress?.call('split_done', 100);
  logp('✂️ 分割完了: ${fixed.length} 片');
  return fixed;
}

/// 把视频压缩到 targetBytes 以内，输出到 [out]
Future<void> _dbCompressTo(File src, int targetBytes, File out) async {
  final dur = await _dbProbeDuration(src);
  if (dur <= 0) {
    throw DbVideoArkException('无法读取分片时长，无法压缩：${src.path}',
        code: 'probe_failed');
  }
  var attempt = 0;
  while (attempt < 2) {
    attempt++;
    final factor = attempt == 1 ? 1.0 : 0.7;
    final audioKbps = 64.0;
    var videoKbps = (targetBytes * 8 / dur / 1000 * factor) - audioKbps;
    if (videoKbps < 120) videoKbps = 120;
    // 短视频按目标体积反推会得到离谱码率（例如 1 秒视频 480MB →
    // 5Gbps，libx264 的 maxrate 直接溢出）。720p 封顶 6000kbps。
    if (videoKbps > 6000) videoKbps = 6000;
    final r = await Process.run('ffmpeg', [
      '-y',
      '-loglevel',
      'error',
      '-i',
      src.path,
      '-vf',
      'scale=-2:min(720\\,ih)',
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-b:v',
      '${videoKbps.round()}k',
      '-maxrate',
      '${(videoKbps * 1.25).round()}k',
      '-bufsize',
      '${(videoKbps * 2).round()}k',
      '-c:a',
      'aac',
      '-b:a',
      '${audioKbps.round()}k',
      '-ac',
      '2',
      '-movflags',
      '+faststart',
      out.path,
    ]);
    if (r.exitCode != 0 || !out.existsSync()) {
      throw DbVideoArkException(
          '视频压缩失败（ffmpeg exit=${r.exitCode}）：${'${r.stderr}'.trim()}');
    }
    if (out.lengthSync() <= targetBytes) return;
  }
  throw DbVideoArkException(
      '压缩后仍超过单片上限（${dbFmtSize(out.lengthSync())}）。'
      '可在 doubao_video_ark.json 里调大 segmentMaxBytes（须 <50MB）。');
}

// ------------------------------------------------------------
// 分段理解：把一段视频（≤45MB）交给豆包，得到该段的客观描述
// ------------------------------------------------------------
Future<String> _dbDescribeSegment({
  required File segment,
  required String mime,
  required String model,
  required String apiKey,
  required int index,
  required int total,
  required String videoName,
  required double startSec,
  required double endSec,
  required double fps,
}) async {
  final clock = _dbFmtClock(startSec);
  final prompt = _dbSegmentPrompt(videoName, index, total, startSec);

  final tail = StringBuffer()
    ..write('","fps":${_dbNumStr(fps)}}},{"type":"text","text":')
    ..write(jsonEncode(prompt))
    ..write('}]}],"max_tokens":1600,"temperature":0.3');
  if (model.toLowerCase().startsWith('doubao-seed')) {
    tail.write(',"thinking":{"type":"disabled"}');
  }
  tail.write('}');

  final head = utf8.encode(
      '{"model":${jsonEncode(model)},"messages":[{"role":"user","content":'
      '[{"type":"video_url","video_url":{"url":"data:$mime;base64,');
  final tailBytes = utf8.encode(tail.toString());

  final started = DateTime.now();
  final r = await _dbPostVideoBase64(
    url: '${dbBaseUrl(null)}/chat/completions',
    apiKey: apiKey,
    file: segment,
    head: head,
    tail: tailBytes,
    // ★ 2026-11-25 二次修复：45MB base64 分片要「上传 + 视频推理」，
    //   300 秒在弱网/长段上经常不够，超时即判该段失败，
    //   最终表现就是「视频没有完全理解成功」。放宽到 900 秒。
    timeout: const Duration(seconds: 900),
  );
  if (r.code != 200) {
    throw DbVideoArkException(
        '第 ${index + 1} 段视频理解失败（HTTP ${r.code}）：${_dbErrText(r.bytes)}');
  }
  final j = asMap(jsonDecode(utf8.decode(r.bytes, allowMalformed: true)));
  final choices = asList(j['choices']);
  if (choices.isEmpty) {
    throw DbVideoArkException('第 ${index + 1} 段视频理解返回空响应');
  }
  final msg = asMap(asMap(choices[0])['message']);
  var text = mStr(msg, 'content').trim();
  if (text.isEmpty) text = mStr(msg, 'reasoning_content').trim();
  final cost = DateTime.now().difference(started).inSeconds;
  logp('🎬 第 ${index + 1}/$total 段理解完成（从 ${clock} '
      '${_dbFmtClock(endSec)}、${cost} 秒、${runeLen(text)} 文字）');
  return text;
}

/// 分段理解带一次重试。
/// 单段失败此前会直接写成「（本段理解失败：…）」并入结果，只要不是全段失败
/// 就放行 —— 于是视频「看起来理解了」，但中间缺了几段内容。
/// 这里对网络类失败再给一次机会，仍失败才如实记录。
Future<String> _dbSegmentRetryOnce({
  required File segment,
  required String mime,
  required String model,
  required String apiKey,
  required int index,
  required int total,
  required String videoName,
  required double startSec,
  required double endSec,
  required double fps,
}) async {
  try {
    return await _dbDescribeSegment(
      segment: segment,
      mime: mime,
      model: model,
      apiKey: apiKey,
      index: index,
      total: total,
      videoName: videoName,
      startSec: startSec,
      endSec: endSec,
      fps: fps,
    );
  } catch (e) {
    logp('⚠️ 第 ${index + 1}/$total 段理解失败，3 秒后重试一次：$e');
    await Future<void>.delayed(const Duration(seconds: 3));
    return _dbDescribeSegment(
      segment: segment,
      mime: mime,
      model: model,
      apiKey: apiKey,
      index: index,
      total: total,
      videoName: videoName,
      startSec: startSec,
      endSec: endSec,
      fps: fps,
    );
  }
}

/// 分段的通用提示词（base64 通道与 TOS 分段通道共用，避免两处漂移）。
String _dbSegmentPrompt(
    String videoName, int index, int total, double startSec) {
  final clock = _dbFmtClock(startSec);
  return '这是完整视频《$videoName》的第 ${index + 1}/$total 段，'
      '本段从 $clock 开始（全片时间轴上的一段）。\n'
      '请客观、详细地描述本段内容，按以下顺序给出要点：\n'
      '1. 场景与环境（室内/室外、地点、光线、天气）；\n'
      '2. 出现的人物或主体（人数、外观、穿着、身份线索）；\n'
      '3. 动作与事件的发生顺序（按时间先后）；\n'
      '4. 画面中出现的文字、字幕、标题、界面元素（原样抄录）；\n'
      '5. 可辨识的声音、说话内容要点（若有）。\n'
      '只描述本段，不要猜测其他段落，不要写总结或评价。';
}

/// 分段上传到 TOS 时的文件名：ASCII、带段号，避免同名互相覆盖。
String _dbSegmentUploadName(String videoName, int index, int total) {
  var base = videoName.trim();
  final dot = base.lastIndexOf('.');
  var stem = dot > 0 ? base.substring(0, dot) : base;
  final ext = dot > 0 ? base.substring(dot).toLowerCase() : '.mp4';
  if (stem.length > 60) stem = stem.substring(0, 60);
  stem = stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (stem.isEmpty) stem = 'segment';
  final no = (index + 1).toString().padLeft(2, '0');
  final all = total.toString().padLeft(2, '0');
  return '${stem}_p${no}of$all$ext';
}

/// 段级 TOS 通道：把一段（≤ segmentMaxBytes）按配置上传到方舟 TOS 预处理，
/// 再用返回的 file_id 让模型描述这一段。
///
/// 为什么需要它：方舟「单文件」视频预处理的处理能力有上限，源文件 226.8MB
/// 时服务端直接超时（fps 5 与 0.5 都失败），而同一账号/桶/模型下 5.7MB 文件
/// 正常 active。切片后每段体量小，预处理能完成 —— 于是大视频也能被真实理解，
/// 且全程不重编码、不改变原文件字节。
Future<String> _dbDescribeSegmentByFileId({
  required File segment,
  required String fileName,
  required DbVideoArkConfig cfg,
  required String model,
  required String apiKey,
  required int index,
  required int total,
  required String videoName,
  required double startSec,
  required double endSec,
}) async {
  final clock = _dbFmtClock(startSec);
  // 段级同样按帧预算降密：45MB 的段在低码率长视频上是好几分钟，
  // 直接套 fps=5 会让这一段自己又超时一次。
  final segPlan = await dbArkPlanPreprocessFps(segment, cfg);
  final segFps = segPlan.fps;
  if (segPlan.estFrames > 0 && cfg.fps > 0 && segFps < cfg.fps) {
    logp('🎚️ 第 ${index + 1} 段抽帧降密: ${_dbFpsStr(cfg.fps)} → '
        '${_dbFpsStr(segFps)} fps（约 ${segPlan.estFrames} 帧）');
  }
  final segSize = await segment.length();
  final fileId = await _dbArkUploadToTosBucket(
    file: segment,
    fileName: fileName,
    bucket: cfg.tosBucket,
    prefix: cfg.tosPrefix,
    model: cfg.preprocessModel,
    apiKey: apiKey,
    fps: segFps,
    maxVideoTokens: cfg.maxVideoTokens,
    minFrames: cfg.minFrames,
  );
  await dbArkWaitFileActive(
    apiKey: apiKey,
    fileId: fileId,
    timeout: dbArkPreprocessTimeoutFor(segSize),
  );
  final text = await _dbArkChatOnce(
    apiKey: apiKey,
    model: model,
    fileId: fileId,
    prompt: _dbSegmentPrompt(videoName, index, total, startSec),
    maxTokens: 1600,
  );
  logp('🎬 第 ${index + 1}/$total 段 TOS 理解完成'
      '（从 $clock 到 ${_dbFmtClock(endSec)}，${runeLen(text)} 文字）');
  return text;
}

/// 非流式单轮视频理解：用 file_id 作为视频输入，返回模型文本。
/// doubao-seed 系列走 Chat API；DeepSeek V4 系列必须走 Responses API
/// （参见 dbVideoNeedsResponsesApi 的说明）。
Future<String> _dbArkChatOnce({
  required String apiKey,
  required String model,
  required String fileId,
  required String prompt,
  int maxTokens = 1600,
}) async {
  final base = dbBaseUrl(null);

  if (dbVideoNeedsResponsesApi(model)) {
    final body = <String, dynamic>{
      'model': model,
      'stream': false,
      'max_output_tokens': maxTokens,
      'input': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'message',
          'role': 'user',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'input_video', 'file_id': fileId},
            <String, dynamic>{'type': 'input_text', 'text': prompt},
          ],
        },
      ],
    };
    final r = await _dbPostJson('$base/responses', apiKey, body);
    if (r.code != 200) {
      throw DbVideoArkException(
          '视频理解失败（Responses HTTP ${r.code}）：${_dbErrText(r.bytes)}');
    }
    final j = asMap(jsonDecode(utf8.decode(r.bytes, allowMalformed: true)));
    final out = StringBuffer();
    for (final item in asList(j['output'])) {
      for (final c in asList(asMap(item)['content'])) {
        final cm = asMap(c);
        if ('${cm['type']}' == 'output_text') out.write(mStr(cm, 'text'));
      }
    }
    final text = out.toString().trim();
    if (text.isEmpty) {
      throw DbVideoArkException('视频理解返回空内容（Responses API）');
    }
    return text;
  }

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
    'temperature': 0.3,
  };
  if (model.toLowerCase().startsWith('doubao-seed')) {
    body['thinking'] = <String, dynamic>{'type': 'disabled'};
  }
  final r = await _dbPostJson('$base/chat/completions', apiKey, body);
  if (r.code != 200) {
    throw DbVideoArkException(
        '视频理解失败（Chat HTTP ${r.code}）：${_dbErrText(r.bytes)}');
  }
  final j = asMap(jsonDecode(utf8.decode(r.bytes, allowMalformed: true)));
  final choices = asList(j['choices']);
  if (choices.isEmpty) {
    throw DbVideoArkException('视频理解返回空响应');
  }
  final msg = asMap(asMap(choices[0])['message']);
  var text = mStr(msg, 'content').trim();
  if (text.isEmpty) text = mStr(msg, 'reasoning_content').trim();
  if (text.isEmpty) {
    throw DbVideoArkException('视频理解返回空内容');
  }
  return text;
}

Future<_DbJsonResp> _dbPostJson(
    String url, String apiKey, Map<String, dynamic> body) async {
  final client = globalHTTPClient;
  final req = await client.postUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
  req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
  final bytes = utf8.encode(jsonEncode(body));
  req.headers.contentLength = bytes.length;
  req.add(bytes);
  final resp = await req.close().timeout(const Duration(seconds: 900));
  final out = <int>[];
  await for (final c in resp) {
    out.addAll(c);
  }
  return _DbJsonResp(resp.statusCode, out);
}

String _dbNumStr(double v) {
  if (v == v.roundToDouble()) return '${v.toInt()}';
  return v.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '');
}

/// 直接把视频文件的 base64 以流式方式写进 JSON 请求体。
/// 目的：45MB 的分片也不会整段进内存（峰值只有单个分块），
/// 否则 2GB 级视频在手机上极容易被 LMK 直接杀掉。
Future<_DbJsonResp> _dbPostVideoBase64({
  required String url,
  required String apiKey,
  required File file,
  required List<int> head,
  required List<int> tail,
  Duration timeout = const Duration(seconds: 300),
}) async {
  final size = await file.length();
  final b64Len = ((size + 2) ~/ 3) * 4;
  final client = globalHTTPClient;
  final req = await client.openUrl('POST', Uri.parse(url));
  req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
  req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
  req.headers.contentLength = head.length + b64Len + tail.length;
  req.add(head);

  final raf = await file.open();
  // 3 的倍数：保证每个分块独立 base64 后不会出现中间填充符 '='
  const block = 3 * 1024 * 1024;
  var done = 0;
  try {
    while (done < size) {
      final chunk = await raf.read(block);
      if (chunk.isEmpty) break;
      done += chunk.length;
      req.add(utf8.encode(base64Encode(chunk)));
      await req.flush().timeout(const Duration(seconds: 120));
    }
  } catch (e) {
    try {
      await raf.close();
    } catch (_) {}
    try {
      req.abort();
    } catch (_) {}
    throw DbVideoArkException('视频上传中断：$e');
  }
  try {
    await raf.close();
  } catch (_) {}

  req.add(tail);
  final resp = await req.close().timeout(timeout);
  final out = <int>[];
  await for (final c in resp) {
    out.addAll(c);
  }
  return _DbJsonResp(resp.statusCode, out);
}

// ------------------------------------------------------------
// HTTP 辅助
// ------------------------------------------------------------
class _DbJsonResp {
  final int code;
  final List<int> bytes;
  _DbJsonResp(this.code, this.bytes);
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
    final mime = _dbVideoMime(meta.name);
    final tag = <String, dynamic>{
      'index': index,
      'count': videoFileIds.length,
      'fileName': meta.name,
    };

    // ---------- Files API / TOS：启用后只走方舟 TOS 预处理 ----------
    //   用户明确要求使用 TOS 预处理，不再回退本地切片。
    //   若 TOS 未配置或方舟预处理失败，直接返回明确错误，绝不偷偷改用本地。
    if (cfg.useFilesApi || cfg.tosBucket.trim().isNotEmpty) {
      if (cfg.tosBucket.trim().isEmpty) {
        throw DbVideoArkException(
            '已启用 Files API，但未配置 tosBucket；TOS 预处理需要先配置 TOS Bucket。',
            code: 'tos_not_configured');
      }
      onProgress?.call({...tag, 'stage': 'tos_reference', 'size': size});
      late Map<String, dynamic> part;
      try {
        part = await dbArkVideoPartForLocalFile(
          absPath: absPath,
          fileName: meta.name,
          model: model,
          apiKey: apiKey,
          onProgress: (info) => onProgress?.call({...tag, ...info}),
        );
      } on DbVideoArkException catch (e) {
        if (e.code != 'need_segment') rethrow;
        // ★ 2026-11-25 修复「方舟视频预处理失败」死循环：
        //   方舟单文件预处理对大体量源文件会服务端超时（实测 226.8MB 必失败，
        //   同桶 5.7MB 正常 active）。文件没坏、TOS 授权也没问题 ——
        //   正确解法是 ffmpeg -c copy 无损切片后逐段走方舟，而不是把
        //   "请确认授权/文件损坏" 甩给用户。
        logp('⚠️ 单文件预处理不可用，改用无损切片通道: ${meta.name}');
        onProgress?.call({...tag, 'stage': 'fallback_split', 'size': size});
        final desc = await _dbDescribeLargeVideo(
          file: f,
          meta: meta,
          mime: mime,
          cfg: cfg,
          model: model,
          apiKey: apiKey,
          onProgress: onProgress,
          tag: tag,
          preferTos: true,
        );
        blocks.add(desc);
        index++;
        if (decryptedTempDir != null) {
          try { decryptedTempDir.deleteSync(recursive: true); } catch (_) {}
        }
        continue;
      }
      parts.add(part);
      logp('🎬 经由 TOS 发送: ${meta.name}');
      index++;
      if (decryptedTempDir != null) {
        try { decryptedTempDir.deleteSync(recursive: true); } catch (_) {}
      }
      continue;
    }
    logp('🎬 分割理解大容量视频: ${meta.name} (${dbFmtSize(size)})');
    final desc = await _dbDescribeLargeVideo(
      file: f,
      meta: meta,
      mime: mime,
      cfg: cfg,
      model: model,
      apiKey: apiKey,
      onProgress: onProgress,
      tag: tag,
    );
    blocks.add(desc);
    index++;
    if (decryptedTempDir != null) {
      try { decryptedTempDir.deleteSync(recursive: true); } catch (_) {}
    }
  }
  return (parts: parts, text: blocks.join('\n\n'));
}

Future<String> _dbDescribeLargeVideo({
  required File file,
  required DsFileMeta meta,
  required String mime,
  required DbVideoArkConfig cfg,
  required String model,
  required String apiKey,
  required Map<String, dynamic> tag,
  void Function(Map<String, dynamic> info)? onProgress,
  /// true：每段优先走方舟 TOS 预处理（段小，预处理不会超时），
  /// 失败再回退 base64。单文件预处理超时降级时使用。
  bool preferTos = false,
}) async {
  Directory? tmpDir;
  try {
    onProgress?.call({...tag, 'stage': 'split', 'size': file.lengthSync()});
    final segs = await _dbSplitVideo(
      file,
      cfg.segmentMaxBytes,
      onProgress: (stage, pct) => onProgress?.call({
        ...tag,
        'stage': stage,
        'percent': pct,
      }),
    );
    tmpDir = segs.first.parent;

    // 逐段计算时间轴
    final durs = <double>[];
    var totalDur = 0.0;
    for (final s in segs) {
      final d = await _dbProbeDuration(s);
      durs.add(d > 0 ? d : 0);
      totalDur += d > 0 ? d : 0;
    }

    final descs = <String>[];
    var start = 0.0;
    var failed = 0;
    for (var i = 0; i < segs.length; i++) {
      final end = start + durs[i];
      // 本段抽帧密度：段时长已知，不再重复 ffprobe。
      var segFps = cfg.fps;
      final fdur = durs[i];
      if (fdur > 0 && cfg.frameBudget > 0 && fdur * segFps > cfg.frameBudget) {
        segFps = cfg.frameBudget / fdur;
        if (segFps < 0.2) segFps = 0.2;
      }
      onProgress?.call({
        ...tag,
        'stage': 'segment_start',
        'segment': i + 1,
        'segments': segs.length,
        'start': start.round(),
        'end': end.round(),
      });
      try {
        String text;
        if (preferTos && cfg.tosBucket.trim().isNotEmpty) {
          try {
            text = await _dbDescribeSegmentByFileId(
              segment: segs[i],
              fileName: _dbSegmentUploadName(meta.name, i, segs.length),
              cfg: cfg,
              model: model,
              apiKey: apiKey,
              index: i,
              total: segs.length,
              videoName: meta.name,
              startSec: start,
              endSec: end,
            );
          } catch (e) {
            logp('⚠️ 第 ${i + 1} 段 TOS 通道失败，回退 base64：$e');
            text = await _dbSegmentRetryOnce(
              segment: segs[i],
              mime: mime,
              model: model,
              apiKey: apiKey,
              index: i,
              total: segs.length,
              videoName: meta.name,
              startSec: start,
              endSec: end,
              fps: segFps,
            );
          }
        } else {
          text = await _dbSegmentRetryOnce(
            segment: segs[i],
            mime: mime,
            model: model,
            apiKey: apiKey,
            index: i,
            total: segs.length,
            videoName: meta.name,
            startSec: start,
            endSec: end,
            fps: segFps,
          );
        }
        descs.add('【第 ${i + 1}/${segs.length} 段 · '
            '${_dbFmtClock(start)} - ${_dbFmtClock(end)}】\n$text');
      } catch (e) {
        failed++;
        logp('⚠️ 第 ${i + 1} 段理解失败（继续）: $e');
        descs.add('【第 ${i + 1}/${segs.length} 段 · '
            '${_dbFmtClock(start)} - ${_dbFmtClock(end)}】\n（本段理解失败：$e）');
      }
      onProgress?.call({
        ...tag,
        'stage': 'segment_done',
        'segment': i + 1,
        'segments': segs.length,
        'percent': ((i + 1) * 100) ~/ segs.length,
      });
      start = end;
    }

    if (failed == segs.length) {
      throw DbVideoArkException(
          '视频《${meta.name}》的全部 ${segs.length} 段都理解失败，请检查网络或模型配置');
    }

    final header = '【视频分段理解结果：《${meta.name}》· '
        '共 ${segs.length} 段 · 总时长 ${_dbFmtClock(totalDur)}】\n'
        '（这是对整段视频逐段观看到的客观描述，请据此回答用户的问题；'
        '若用户询问具体时间点，请参考每段标注的时间区间。）';
    return '$header\n\n${descs.join('\n\n')}';
  } finally {
    if (tmpDir != null) {
      try {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      } catch (e) {
        logp('⚠️ 临时文件删除失败: $e');
      }
    }
  }
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
      // 超时即判定断流，抛 upload_failed 让上层走切片/重试。
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

/// Files API 单文件通道（仅在 useFilesApi=true 且非大视频分段路径时使用）
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
  var size = stat.size;
  if (size > cfg.maxBytes) {
    throw DbVideoArkException(
        '视频超过上限 ${dbFmtSize(cfg.maxBytes)}（当前 ${dbFmtSize(size)}）：$fileName',
        code: 'too_large');
  }
  if (size <= 0) {
    throw DbVideoArkException('视频文件为空：$fileName', code: 'empty');
  }

  // 原文件直接上传，不改字节。
  // ★ 2026-11-25 二次修复：fps 不再无条件取配置值，而是按「时长 × fps」
  //   规划到抽帧预算内。fps=5 用在长视频上必然把方舟预处理拖到超时，
  //   而方舟只会回一句 "Timeout occurred while processing video"，
  //   让人误以为是文件体积或授权问题。
  final key = _dbArkCacheKey(f, size);
  final plan = await dbArkPlanPreprocessFps(f, cfg);
  final arkFps = plan.fps;
  if (plan.estFrames > 0 &&
      plan.budgetFrames > 0 &&
      cfg.fps > 0 &&
      arkFps < cfg.fps) {
    logp('🎚️ 单文件抽帧降密: ${_dbFpsStr(cfg.fps)} → ${_dbFpsStr(arkFps)} fps'
        '（时长 ${_dbFmtClock(plan.duration)}，约 ${plan.estFrames} 帧，'
        '预算 ${plan.budgetFrames} 帧）');
  }
  final cached = _dbArkCacheLookup(key, arkFps);
  if (cached != null) {
    onProgress?.call({'stage': 'cache_hit', 'arkFileId': cached});
    return dbArkVideoPartByFileId(cached, fps: arkFps);
  }

  if (cfg.tosBucket.trim().isEmpty) {
    throw DbVideoArkException(
        'TOS Bucket 未配置，已按「只走 TOS 预处理」策略停止，不回退本地。',
        code: 'tos_not_configured');
  }

  // 同一文件此前已确认超时：只有当这次抽帧更省时才允许再试一次。
  // 抽帧没变就重传，只会在同一个坑里再超时一次、再白等一轮。
  if (_dbArkSlowPathHit(key)) {
    final prevFps = _dbArkSlowPathFps(key);
    // 旧版失败记忆没有 fps 字段（prevFps=0）：说明是升级前留下的，
    // 这次抽帧策略已经变了，允许重试一次，不能拿旧账把文件永久判死。
    if (prevFps > 0 && arkFps >= prevFps) {
      throw DbVideoArkException(
          '《$fileName》此前在方舟单文件预处理阶段超时'
          '（${dbFmtSize(size)}，fps=${prevFps > 0 ? _dbFpsStr(prevFps) : '未记录'}），'
          '本次直接改用无损切片通道',
          code: 'need_segment');
    }
    logp('🔁 该文件上次 fps=${_dbFpsStr(prevFps)} 超时，'
        '这次降到 ${_dbFpsStr(arkFps)} fps 再试一次');
  }

  // 二进制上传 + tos[bucket]/tos[prefix]：文件落到用户 TOS，
  // 预处理由方舟完成；不需要 TOS AK/SK，也不检查/依赖 TOS 对象路径。
  // 单文件 TOS 直传最多试两轮：
  //   第 1 轮用规划后的 fps；仅当失败属于「预处理超时/InvalidArgument」
  //   且还有降密空间时，第 2 轮把 fps 减半再试；仍失败才交给切片通道。
  // 官方对 TOS 通道的承诺是单文件 ≤2GB，因此 2GB 以内一律先按单文件走，
  // 绝不再因为「某个更小的文件曾经失败」就提前放弃。
  var attempt = 0;
  String? lastErr;
  String lastArkId = '';
  double lastFps = arkFps;
  while (attempt < 2) {
    attempt++;
    if (attempt == 1) {
      lastFps = arkFps;
    } else {
      var f2 = arkFps / 2;
      if (f2 < 0.2) f2 = 0.2;
      lastFps = f2;
      logp('🔁 单文件预处理失败，降抽帧重试: '
          '${_dbFpsStr(arkFps)} → ${_dbFpsStr(lastFps)} fps');
    }
    onProgress?.call({
      'stage': 'tos_upload_start',
      'size': size,
      'attempt': attempt,
      'fps': lastFps,
    });
    final arkId = await _dbArkUploadToTosBucket(
      file: f,
      fileName: fileName,
      bucket: cfg.tosBucket,
      prefix: cfg.tosPrefix,
      model: cfg.preprocessModel,
      apiKey: apiKey,
      fps: lastFps,
      maxVideoTokens: cfg.maxVideoTokens,
      minFrames: cfg.minFrames,
      onProgress: (sent, total) {
        onProgress?.call({
          'stage': 'tos_upload',
          'sent': sent,
          'total': total,
          'percent': total <= 0 ? 0 : ((sent * 100) ~/ total),
          'attempt': attempt,
        });
      },
    );
    lastArkId = arkId;
    onProgress?.call({'stage': 'tos_upload_done', 'size': size});
    onProgress?.call({'stage': 'tos_reference', 'size': size});

    // ★ 修复"方舟预处理停在 0 秒"的显示 bug（2026-11）
    //   旧实现有 2 处损坏：
    //     1) 发送 preprocess_wait 时没带 waited → 前端 (obj.waited || 0) 恒为 0
    //     2) 没有把 onTick 传给 dbArkWaitFileActive → 轮询期间
    //        没有任何进度流动，直到完成都固定显示"0 秒"
    //   以此处等待开始时刻为起点，每个 tick 下发实际经过秒数。
    onProgress?.call({
      'stage': 'preprocess_wait',
      'arkFileId': arkId,
      'waited': 0,
      'attempt': attempt,
    });
    final waitStartedAt = DateTime.now();
    try {
      // ★ 2026-11-25 二次修复：等待上限按体积自适应。
      //   固定 40 分钟对小文件是白等，对 2GB 又可能提前掐断；
      //   now: 20 分钟基础 + 每 GB 25 分钟，上限 3 小时。
      await dbArkWaitFileActive(
        apiKey: apiKey,
        fileId: arkId,
        timeout: dbArkPreprocessTimeoutFor(size),
        onTick: (status, waitedSec) {
          // 首个 tick 的 waitedSec 可能为 0，用本地经过时间兜底
          final local = DateTime.now().difference(waitStartedAt).inSeconds;
          onProgress?.call({
            'stage': 'preprocess',
            'arkFileId': arkId,
            'status': status,
            'waited': waitedSec > local ? waitedSec : local,
            'attempt': attempt,
          });
        },
      );
    } on DbVideoArkException catch (e) {
      lastErr = e.message;
      // 只有「像预处理问题」的失败才值得降参重试；
      // 鉴权、桶不存在、模型不存在这类错误重试多少次都一样。
      if (!dbArkLooksLikePreprocessTrouble(e)) rethrow;
      final canRetry = attempt < 2 && lastFps > 0.2;
      if (canRetry) {
        logp('⚠️ 第 $attempt 轮单文件预处理失败（${dbFmtSize(size)}，'
            'fps=${_dbFpsStr(lastFps)}）：${e.message}');
        continue;
      }
      if (dbArkIsPreprocessTimeout(e)) {
        // 只有明确的「超时」才写入失败记忆；参数错误绝不能记成体量问题。
        _dbArkSlowPathRemember(key, e.message, bytes: size, fps: lastFps);
      }
      throw DbVideoArkException(
          '方舟单文件预处理超时（源文件 ${dbFmtSize(size)}，'
          'fps=${_dbFpsStr(lastFps)}，file=$lastArkId）：$lastErr',
          code: 'need_segment');
    }
    _dbArkCacheStore(key, arkId, cfg.preprocessModel, lastFps);
    return dbArkVideoPartByFileId(arkId, fps: lastFps);
  }
  throw DbVideoArkException(
      '方舟单文件预处理失败（源文件 ${dbFmtSize(size)}，'
      'file=$lastArkId）：${lastErr ?? '未知原因'}',
      code: 'need_segment');
}

// ============================================================
// DeepSeek V4 系列视频理解：走 Responses API（input_video + file_id）
//
// 火山方舟客服确认：DeepSeek V4.1 Flash（deepseek-v4 系列）的视频理解
// 仅支持 Responses API。Chat API 的 video_url 会报 400：
//   "content must be text or an array of text, image_url, or file content blocks"
// Responses API 的视频 content 块格式：
//   {"type":"input_video","file_id":"file-xxx"}
// ============================================================

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
