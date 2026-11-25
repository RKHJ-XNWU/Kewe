// 音频前置拦截自测（临时脚本，验证后删除，不随仓库提交）。
// 运行：dart run tool/selftest_audio_gate.dart
import 'dart:convert';
import 'dart:io';

import '../lib/src/doubao_video_ark.dart';

Future<Map<String, dynamic>> _probeAudio(File f) async {
  final r = await Process.run('ffprobe', [
    '-v', 'error',
    '-select_streams', 'a:0',
    '-count_packets',
    '-show_entries',
    'stream=codec_name,duration,start_time,nb_read_packets,sample_rate',
    '-of', 'json',
    f.path,
  ]);
  final j = jsonDecode('${r.stdout}') as Map<String, dynamic>;
  final streams = (j['streams'] as List?) ?? const [];
  if (streams.isEmpty) return {'has': false};
  final s = streams.first as Map<String, dynamic>;
  return {
    'has': true,
    'codec': s['codec_name'],
    'duration': double.tryParse('${s['duration']}') ?? 0,
    'start': double.tryParse('${s['start_time']}') ?? 0,
    'packets': int.tryParse('${s['nb_read_packets']}') ?? 0,
  };
}

Future<int> _audioTrackCount(File f) async {
  final r = await Process.run('ffprobe', [
    '-v', 'error',
    '-show_entries', 'stream=codec_type',
    '-of', 'default=nw=1:nk=1',
    f.path,
  ]);
  return '${r.stdout}'
      .split('\n')
      .where((e) => e.trim() == 'audio')
      .length;
}

Future<double> _decoded(File f) async {
  final r = await Process.run('ffmpeg', [
    '-nostdin', '-hide_banner', '-v', 'error', '-progress', 'pipe:1',
    '-i', f.path, '-map', '0:a:0', '-f', 'null', '-',
  ]);
  var d = 0.0;
  for (final m
      in RegExp(r'^out_time_us=(\d+)', multiLine: true).allMatches('${r.stdout}')) {
    final v = double.tryParse(m.group(1) ?? '') ?? 0;
    if (v > 0) d = v / 1000000;
  }
  return d;
}

/// 模拟服务端「按容器时长抽音频」：结果必须接近视频时长，不能是 8ms。
Future<double> _arkLikeExtract(File f) async {
  final wav = File('${f.path}.ark.wav');
  final dv = await Process.run('ffprobe', [
    '-v', 'error',
    '-show_entries', 'format=duration',
    '-of', 'default=nw=1:nk=1',
    f.path,
  ]);
  final fd = '${dv.stdout}'.trim();
  await Process.run('ffmpeg', [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-i', f.path, '-map', '0:a:0', '-vn',
    '-c:a', 'pcm_s16le', '-ar', '16000', '-t', fd, wav.path,
  ]);
  final p = await Process.run('ffprobe', [
    '-v', 'error',
    '-show_entries', 'format=duration',
    '-of', 'default=nw=1:nk=1',
    wav.path,
  ]);
  try {
    wav.deleteSync();
  } catch (_) {}
  return double.tryParse('${p.stdout}'.trim()) ?? 0;
}

Future<File> _mk(String name, List<String> args) async {
  final out = File('/tmp/audgate/$name');
  final r = await Process.run('ffmpeg', ['-y', '-hide_banner', '-loglevel', 'error', ...args, out.path]);
  if (r.exitCode != 0) {
    throw StateError('构建 $name 失败: ${r.stderr}');
  }
  return out;
}

int _fail = 0;
void _check(String name, bool ok, String detail) {
  stdout.writeln('${ok ? '  ✓' : '  ✗'} $name — $detail');
  if (!ok) _fail++;
}

Future<void> main() async {
  Directory('/tmp/audgate').createSync(recursive: true);

  // 1) 健康视频：音频 20s，与视频对齐
  final healthy = await _mk('healthy.mp4', [
    '-f', 'lavfi', '-i', 'testsrc=duration=20:size=640x360:rate=25',
    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=20',
    '-c:v', 'libx264', '-c:a', 'aac', '-shortest',
  ]);

  // 2) 8ms 坏音频：视频 15s，音频轨只有 8ms
  final tinyA = await _mk('tiny.m4a', [
    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.008', '-c:a', 'aac',
  ]);
  final broken = await _mk('broken.mp4', [
    '-f', 'lavfi', '-i', 'testsrc=duration=15:size=640x360:rate=25',
    '-i', tinyA.path, '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'libx264', '-c:a', 'copy',
  ]);

  // 3) 纯视频（无音频轨）
  final videoOnly = await _mk('videoonly.mp4', [
    '-f', 'lavfi', '-i', 'testsrc=duration=10:size=640x360:rate=25', '-c:v', 'libx264',
  ]);

  // 4) 音频起点带偏移（模拟 -ss 切片后 PTS 未归零）
  final shifted = await _mk('shifted.mp4', [
    '-f', 'lavfi', '-i', 'testsrc=duration=15:size=640x360:rate=25',
    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=15',
    '-c:v', 'libx264', '-c:a', 'aac', '-shortest',
  ]);
  final shiftedReal = await _mk('shifted_real.mp4', [
    '-ss', '5.000', '-t', '10.000', '-i', shifted.path,
    '-map', '0:v:0', '-map', '0:a:0', '-c:v', 'copy', '-c:a', 'aac',
    '-af', 'aresample=async=1:first_pts=0', '-movflags', '+faststart',
  ]);

  // 5) 双音轨（切片后必须只保留一条）
  final multi = await _mk('multi.mp4', [
    '-f', 'lavfi', '-i', 'testsrc=duration=20:size=640x360:rate=25',
    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=20',
    '-f', 'lavfi', '-i', 'sine=frequency=880:duration=20',
    '-map', '0:v', '-map', '1:a', '-map', '2:a',
    '-c:v', 'libx264', '-c:a', 'aac', '-shortest',
  ]);

  stdout.writeln('=== A. 健康视频：必须原样放行（不改文件）');
  final bytesBefore = healthy.lengthSync();
  final mtimeBefore = healthy.lastModifiedSync();
  await dbArkEnsureSegmentAudioSafe(healthy, label: '健康视频', targetSec: 20);
  _check('文件未被改动',
      healthy.lengthSync() == bytesBefore && healthy.lastModifiedSync() == mtimeBefore,
      'size=${healthy.lengthSync()}');

  stdout.writeln('=== B. 8ms 坏音频：必须重建为与视频等长');
  final b0 = await _probeAudio(broken);
  _check('初始确实是 8ms 级坏轨', (b0['duration'] as double) < 0.05,
      'duration=${b0['duration']}s packets=${b0['packets']}');
  await dbArkEnsureSegmentAudioSafe(broken, label: '8ms 坏轨', targetSec: 15);
  final b1 = await _probeAudio(broken);
  final bDec = await _decoded(broken);
  final bExtract = await _arkLikeExtract(broken);
  _check('修复后音频时长 ≥ 视频时长', (b1['duration'] as double) >= 14.5,
      'duration=${b1['duration']}s');
  _check('修复后起点归零', (b1['start'] as double) <= 0.5, 'start=${b1['start']}s');
  _check('修复后可解码 ≥ 10ms', bDec >= 0.01, 'decoded=${bDec}s');
  _check('服务端式抽取不再 8ms', bExtract >= 14.5, 'extract=${bExtract}s');

  stdout.writeln('=== C. 纯视频：跳过（无需伪造音频）');
  final beforeC = videoOnly.lengthSync();
  await dbArkEnsureSegmentAudioSafe(videoOnly, label: '纯视频');
  final c0 = await _probeAudio(videoOnly);
  _check('仍然没有音频轨', c0['has'] == false && videoOnly.lengthSync() == beforeC, '');

  stdout.writeln('=== D. 音频起点偏移：必须归零');
  final d0 = await _probeAudio(shiftedReal);
  stdout.writeln('  切片后起点=${d0['start']}s duration=${d0['duration']}s');
  await dbArkEnsureSegmentAudioSafe(shiftedReal, label: '偏移片段', targetSec: 10);
  final d1 = await _probeAudio(shiftedReal);
  _check('修复后起点 ≤ 0.5s', (d1['start'] as double) <= 0.5, 'start=${d1['start']}s');
  _check('修复后时长仍接近 10s', (d1['duration'] as double) >= 9.5,
      'duration=${d1['duration']}s');

  stdout.writeln('=== D2. 合成「音频 PTS 大偏移」：必须被判风险并归零');
  final offsetSrc = await _mk('offset_src.mp4', [
    '-f', 'lavfi', '-i', 'testsrc=duration=10:size=640x360:rate=25',
    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=10',
    '-c:v', 'libx264', '-c:a', 'aac', '-shortest',
  ]);
  final offsetAudio = await _mk('offset_a.m4a', [
    '-i', offsetSrc.path, '-map', '0:a:0', '-c:a', 'copy',
  ]);
  final offsetMux = await _mk('offset.mp4', [
    '-f', 'lavfi', '-i', 'testsrc=duration=10:size=640x360:rate=25',
    '-itsoffset', '8.000', '-i', offsetAudio.path,
    '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'libx264', '-c:a', 'copy',
    '-t', '10',
  ]);
  final o0 = await _probeAudio(offsetMux);
  stdout.writeln('  合成后起点=${o0['start']}s duration=${o0['duration']}s');
  final o0Extract = await _arkLikeExtract(offsetMux);
  stdout.writeln('  合成后「服务端式抽取」=${o0Extract}s（偏移大时会塌成极小值）');
  await dbArkEnsureSegmentAudioSafe(offsetMux, label: '偏移大片段', targetSec: 10);
  final o1 = await _probeAudio(offsetMux);
  final o1Extract = await _arkLikeExtract(offsetMux);
  _check('修复后起点 ≤ 0.5s', (o1['start'] as double) <= 0.5, 'start=${o1['start']}s');
  _check('修复后抽取恢复到视频长度', o1Extract >= 9.0, 'extract=${o1Extract}s');

  stdout.writeln('=== E. 双音轨切片：只保留一条');
  final segMulti = await _mk('seg_multi.mp4', [
    '-ss', '5.000', '-t', '10.000', '-i', multi.path,
    '-map', '0:v:0', '-map', '0:a:0?',
    '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
    '-af', 'aresample=async=1:first_pts=0',
    '-avoid_negative_ts', 'make_zero', '-movflags', '+faststart',
  ]);
  final tracks = await _audioTrackCount(segMulti);
  _check('切片只带 1 条音频轨', tracks == 1, 'tracks=$tracks');

  stdout.writeln('=== F. 整片前置：坏音频 → 产出健康副本，原文件不动');
  final wholeSrc = await _mk('whole_broken.mp4', [
    '-f', 'lavfi', '-i', 'testsrc=duration=15:size=640x360:rate=25',
    '-i', tinyA.path, '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'libx264', '-c:a', 'copy',
  ]);
  final wholeBytes = wholeSrc.lengthSync();
  final safe = await dbArkPrepareWholeVideoSafe(wholeSrc);
  final f0 = await _probeAudio(safe.file);
  _check('返回的是副本（不是原文件）', safe.file.path != wholeSrc.path, safe.file.path);
  _check('副本音频已合格', f0['has'] == true && (f0['duration'] as double) >= 14.5,
      'duration=${f0['duration']}s');
  _check('原文件未被改动', wholeSrc.lengthSync() == wholeBytes, 'size=${wholeSrc.lengthSync()}');
  if (safe.tempDir != null) {
    try {
      safe.tempDir!.deleteSync(recursive: true);
    } catch (_) {}
  }

  stdout.writeln('=== F2. 整片多音轨：只保留主轨副本，原文件不动');
  final multiBytes = multi.lengthSync();
  final safe2 = await dbArkPrepareWholeVideoSafe(multi);
  final f2Tracks = await _audioTrackCount(safe2.file);
  _check('返回副本（不是原文件）', safe2.file.path != multi.path, safe2.file.path);
  _check('副本只有 1 条音频轨', f2Tracks == 1, 'tracks=$f2Tracks');
  _check('原文件未被改动', multi.lengthSync() == multiBytes, 'size=${multi.lengthSync()}');
  if (safe2.tempDir != null) {
    try {
      safe2.tempDir!.deleteSync(recursive: true);
    } catch (_) {}
  }

  stdout.writeln('=== G. 400 报文识别');
  _check('识别 audio_url duration 报文',
      dbArkIsAudioTooShortError(
          'DbVideoArkException: 视频分段理解失败（HTTP 400）：{"error":{"code":"InvalidParameter","message":"The request failed because the duration of the input audio (8ms) is shorter than the limit (10ms).","param":"audio_url duration"}}'),
      '');
  _check('不误判其它 400', !dbArkIsAudioTooShortError('HTTP 400：invalid model'), '');

  stdout.writeln('=== H. 预处理模型解析（8ms 根因：model 必须支持音频）');
  _check('空配置 + 有音轨 + 方舟原生推理模型 → 复用推理模型',
      dbArkVideoPreprocessModel(
              configured: '',
              hasAudio: true,
              inference: 'doubao-seed-2-1-lite-260915') ==
          'doubao-seed-2-1-lite-260915',
      '');
  _check('空配置 + 有音轨 + 非方舟模型 → 音频推荐模型',
      dbArkVideoPreprocessModel(
              configured: '', hasAudio: true, inference: 'relay-gpt-4o') ==
          dbArkAudioPreprocessModel,
      '');
  _check('配置的 preprocessModel 优先',
      dbArkVideoPreprocessModel(
              configured: 'ep-20251125-abcdef',
              hasAudio: true,
              inference: 'doubao-seed-2-1-lite-260915') ==
          'ep-20251125-abcdef',
      '');
  _check('无音轨 → 原配置原样透传（空即空）',
      dbArkVideoPreprocessModel(configured: '', hasAudio: false) == '', '');
  _check('方舟原生 id 判定',
      dbArkLooksLikeArkModel('ep-20251125-abcdef') &&
          dbArkLooksLikeArkModel('doubao-seed-2-1-lite-260915'),
      '');
  _check('中转站别名不写进预处理字段',
      !dbArkLooksLikeArkModel('gpt-4o-relay') &&
          !dbArkLooksLikeArkModel('doubao-2.1-lite'),
      '');
  _check('识别「带 model 上传被拒」的 project 400',
      dbArkIsPreprocessModelRejected(
          '方舟 TOS 上传失败（HTTP 400）：{"error":{"code":"InvalidParameter","message":"Project is invalid","param":"project_name"}}'),
      '');
  _check('音频过短 400 不应被当成模型被拒',
      !dbArkIsPreprocessModelRejected(
          'HTTP 400：audio_url duration (8ms) shorter than the limit (10ms)'),
      '');

  stdout.writeln('=== I. 边界矩阵：极短 / 静音 / 容器-流不一致 / 分段规划');
  final ultraShort = await _mk('ultra_short.mp4', [
    '-f', 'lavfi', '-i', 'testsrc=duration=0.6:size=320x180:rate=25',
    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.6',
    '-c:v', 'libx264', '-c:a', 'aac', '-shortest',
  ]);
  final r1 = await dbArkEnsureSegmentAudioSafe(ultraShort,
      label: '极短视频', targetSec: 0.6);
  final p1 = await _probeAudio(ultraShort);
  _check('极短视频保留音轨且 ≥10ms',
      r1.hasAudio && !r1.degraded && (p1['duration'] as double) >= 0.5,
      'duration=${p1['duration']}s');

  final silent = await _mk('silent.mp4', [
    '-f', 'lavfi', '-i', 'testsrc=duration=2:size=320x180:rate=25',
    '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo',
    '-t', '2', '-c:v', 'libx264', '-c:a', 'aac',
  ]);
  final r2 = await dbArkEnsureSegmentAudioSafe(silent,
      label: '静音视频', targetSec: 2);
  final p2 = await _probeAudio(silent);
  _check('纯静音不被误判为坏轨',
      r2.hasAudio && !r2.degraded && (p2['duration'] as double) >= 1.9,
      'duration=${p2['duration']}s');

  final mismatch = await _mk('mismatch.mp4', [
    '-f', 'lavfi', '-i', 'testsrc=duration=3:size=320x180:rate=25',
    '-i', tinyA.path, '-map', '0:v:0', '-map', '1:a:0',
    '-c:v', 'libx264', '-c:a', 'copy',
  ]);
  final r3 = await dbArkEnsureSegmentAudioSafe(mismatch,
      label: '容器-流不一致', targetSec: 3);
  final p3 = await _probeAudio(mismatch);
  _check('容器时长 3s / 音频流 0.008s 被修复为视频长度',
      r3.hasAudio && !r3.degraded && (p3['duration'] as double) >= 3.0,
      'duration=${p3['duration']}s');

  _check('分段规划：3000 帧以内不分段', dbArkPlanSegCount(600, 5) == 1,
      'segs=${dbArkPlanSegCount(600, 5)}');
  _check('分段规划：2400s×5fps=12000 帧 → 4 段',
      dbArkPlanSegCount(2400, 5) == 4, 'segs=${dbArkPlanSegCount(2400, 5)}');
  _check('分段规划：时长为 0 时按 1 段', dbArkPlanSegCount(0, 5) == 1, '');

  stdout.writeln('');
  stdout.writeln(_fail == 0 ? '全部通过（0 失败）' : '存在失败项：$_fail');
  exit(_fail == 0 ? 0 : 1);
}
