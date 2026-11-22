// ============================================================
// relay.dart —— OpenAI 兼容中转站接入层（sta1n.ai 等）
//   能力：文本聊天（chat completions，OpenAI 兼容协议）
//   用途：把任意 OpenAI 兼容中转站作为独立渠道接入 Kewe，
//        与 DeepSeek / 豆包（方舟）互不影响，支持自定义模型名。
//
//   设计原则：
//     1) 零第三方依赖（与整个项目一致，仅 dart:io / dart:convert）
//     2) API Key 独立保存（与 DeepSeek Key、豆包 Key 分离），明文 JSON
//        只存放在数据目录 data/relay/relay_config.sts（独立维度目录）。
//        源码绝不硬编码任何 Key，Key 一律由前端页面填写后落盘到数据目录。
//     3) 调用复用 deepseek_api.dart 的 callDsChatAPI / callDsChatAPIStream，
//        它们本身就是标准 OpenAI Chat Completions 客户端，只是默认端点
//        指向 DeepSeek；这里把 apiUrl 换成中转站端点即可。
//     4) 所有失败都如实返回错误，绝不伪造成功。
//     5) 流式输出默认开启（stream 配置默认 true）。
// ============================================================

import 'dart:convert';
import 'dart:io';

import 'globals.dart';
import 'httpsrv.dart';

// ============================================================
// ★★★ 中转站（st 维度）全局停用开关（安全/隐私整改）★★★
//   原因：中转站渠道会把用户聊天内容转发到第三方站点，存在严重的
//         用户隐私泄露风险。现从前端到后端彻底停用该渠道：
//           · 前端：任何进入 st 维度 / 选择中转站模型的操作都弹窗报错；
//           · 后端：任何中转站配置、模型清单、聊天/续写/测试调用一律拒绝。
//   DeepSeek（ds）与豆包（db）两个维度完全不受影响。
//   该开关为编译期常量，恒为 true，不提供任何运行时重新开启的入口。
// ============================================================
const bool RELAY_DISABLED = true;

/// 停用后对外统一返回的错误信息（前端弹窗与后端响应共用同一文案）。
const String RELAY_DISABLED_MSG =
    '中转站（st 维度）API 已停止服务：因该渠道存在泄露用户聊天隐私的风险，'
    '现已从前端到后端全面停用，无法再调用任何中转站模型。'
    'DeepSeek 与豆包维度可正常使用。';

/// 后端统一拦截：只要中转站处于停用状态，任何请求都直接返回 403。
/// 返回 true 表示已拦截并写好响应，调用方必须立即 return。
Future<bool> relayRejectIfDisabled(HttpRequest req) async {
  if (!RELAY_DISABLED) return false;
  try {
    await dsJSONErr(req.response, 403, RELAY_DISABLED_MSG);
  } catch (_) {}
  return true;
}

/// 默认中转站 base URL（OpenAI 兼容，含 /v1）。
/// 用户给的连接信息：{"url":"https://sta1n.ai"} 但 API 接入网站是
/// https://sta1n.ai/v1，因此 chat completions = <base>/chat/completions。
const String RELAY_DEFAULT_BASE = 'https://sta1n.ai/v1';

/// 预置模型（与中转站 /v1/models 返回的模型 id 完全一致）
const List<String> relayPresetModels = <String>[
  '[次][抗截断]gemini-3.8-flash',
  '[Kiro]claude-opus-4-8',
  '[Kiro]claude-haiku-5-5',
  '[ASP]gemini-3.8-flash',
  '[抗截断]gemini-3.8-flash',
];

/// 单模型计费价目（与 token_cost.dart 的 TokenPrice 语义一致，单位：元/百万 tokens）。
/// 仅用于向 UI / API 暴露「参考单价」，真实计费仍走 token_cost.dart 的价格表。
class RelayModelSpec {
  final String id;
  final String vendor;
  final double miss; // 输入（缓存未命中）
  final double hit;  // 缓存命中
  final double out;  // 输出
  final double? perRequest; // 固定价（元/请求），存在时优先按请求计费

  const RelayModelSpec(
    this.id,
    this.vendor,
    this.miss,
    this.hit,
    this.out, {
    this.perRequest,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'vendor': vendor,
        'miss': miss,
        'hit': hit,
        'out': out,
        if (perRequest != null) 'perRequest': perRequest,
      };
}

/// 预置价目表（单位：元 / 100 万 tokens；固定价单位为 元/请求）
const List<RelayModelSpec> relayModelCatalog = <RelayModelSpec>[
  RelayModelSpec('[次][抗截断]gemini-3.8-flash', 'Google', 0, 0, 0, perRequest: 0.025),
  RelayModelSpec('[Kiro]claude-opus-4-8', 'Anthropic', 3.5, 0.35, 17.5),
  RelayModelSpec('[Kiro]claude-haiku-5-5', 'Anthropic', 0.21, 0.021, 1.05),
  RelayModelSpec('[ASP]gemini-3.8-flash', 'Google', 0.3, 0.03, 1.5),
  RelayModelSpec('[抗截断]gemini-3.8-flash', 'Google', 0.3, 0.03, 1.5),
];

// ------------------------------------------------------------
// 配置（明文 JSON，存放在 data/relay/relay_config.sts —— 独立维度目录）
// ------------------------------------------------------------
String get relayDir => '$DATA_DIR/relay';
String get relayConfigFile => '$relayDir/relay_config.sts';

class RelayConfig {
  String baseUrl;
  String apiKey;
  List<String> customModels;

  /// 流式输出开关：默认开启（true）。
  bool stream;

  RelayConfig({
    this.baseUrl = RELAY_DEFAULT_BASE,
    this.apiKey = '',
    List<String>? customModels,
    this.stream = true,
  }) : customModels = customModels ?? <String>[];

  Map<String, dynamic> toJson() => <String, dynamic>{
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'customModels': customModels,
        'stream': stream,
      };

  factory RelayConfig.fromJson(Map<String, dynamic> j) => RelayConfig(
        baseUrl: trimOr(mStr(j, 'baseUrl'), RELAY_DEFAULT_BASE),
        apiKey: mStr(j, 'apiKey'),
        customModels: asList(j['customModels']).map((e) => '$e').toList(),
        stream: j.containsKey('stream') ? mBool(j, 'stream') : true,
      );
}

RelayConfig? _relayCfgCache;
String _relayCfgCacheRaw = '';

RelayConfig getRelayConfig() {
  try {
    final f = File(relayConfigFile);
    if (!f.existsSync()) {
      return _relayCfgCache ?? RelayConfig();
    }
    final raw = f.readAsStringSync();
    if (_relayCfgCache != null && raw == _relayCfgCacheRaw) return _relayCfgCache!;
    final cfg = RelayConfig.fromJson(asMap(jsonDecode(raw)));
    _relayCfgCache = cfg;
    _relayCfgCacheRaw = raw;
    return cfg;
  } catch (e) {
    logp('⚠️ 中转站设置读取失败: $e');
    return RelayConfig();
  }
}

bool saveRelayConfig(RelayConfig cfg) {
  try {
    ensureDir(relayDir);
    final raw = const JsonEncoder.withIndent('  ').convert(cfg.toJson());
    File(relayConfigFile).writeAsStringSync(raw);
    Process.runSync('chmod', ['600', relayConfigFile]);
    _relayCfgCache = cfg;
    _relayCfgCacheRaw = raw;
    return true;
  } catch (e) {
    logp('❌ 中转站设置保存失败: $e');
    return false;
  }
}

// ------------------------------------------------------------
// 端点 / 模型判定
// ------------------------------------------------------------
String relayBaseUrl([RelayConfig? c]) {
  var b = (c ?? getRelayConfig()).baseUrl.trim();
  if (b.isEmpty) b = RELAY_DEFAULT_BASE;
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  return b;
}

String relayChatEndpoint() => '${relayBaseUrl(null)}/chat/completions';

/// 该模型是否属于「中转站」目录 —— 用于普通聊天里的自动路由判定。
/// 只有预置模型与用户自定义中转站模型才走中转站通道，
/// 绝不与 DeepSeek / 豆包目录互相抢占。
bool isRelayModel(String model) {
  final m = model.trim();
  if (m.isEmpty) return false;
  if (relayPresetModels.contains(m)) return true;
  final cfg = getRelayConfig();
  for (final custom in cfg.customModels) {
    if (custom.trim() == m) return true;
  }
  return false;
}

// ------------------------------------------------------------
// 模型清单 JSON（供前端 / API 使用）
// ------------------------------------------------------------
List<Map<String, dynamic>> relayModelListJson() {
  final cfg = getRelayConfig();
  final seen = <String>{};
  final out = <Map<String, dynamic>>[];
  for (final spec in relayModelCatalog) {
    seen.add(spec.id);
    out.add({
      'value': spec.id,
      'label': spec.id,
      'vendor': spec.vendor,
      'miss': spec.miss,
      'hit': spec.hit,
      'out': spec.out,
      if (spec.perRequest != null) 'perRequest': spec.perRequest,
      'custom': false,
    });
  }
  for (final c in cfg.customModels) {
    final v = c.trim();
    if (v.isEmpty || !seen.add(v)) continue;
    out.add({
      'value': v,
      'label': v,
      'vendor': '',
      'miss': 0,
      'hit': 0,
      'out': 0,
      'custom': true,
    });
  }
  return out;
}

Map<String, dynamic> relayConfigJson() {
  final cfg = getRelayConfig();
  var masked = '';
  final k = cfg.apiKey.trim();
  if (k.length > 8) {
    masked = '${k.substring(0, 4)}••••${k.substring(k.length - 4)}';
  } else if (k.isNotEmpty) {
    masked = '••••••••';
  }
  return {
    'hasKey': k.isNotEmpty,
    'maskedKey': masked,
    'baseUrl': cfg.baseUrl,
    'customModels': cfg.customModels,
    'presetModels': relayPresetModels,
    'catalog': relayModelListJson(),
    'stream': cfg.stream,
  };
}

// ------------------------------------------------------------
// HTTP 处理器
// ------------------------------------------------------------
Future<void> handleRelayConfig(HttpRequest req) async {
  final res = req.response;
  // ★ 停用整改：中转站配置接口（GET/POST）一律拒绝，前端无法再读取或写入 Key/端点。
  if (await relayRejectIfDisabled(req)) return;
  if (req.method == 'GET') {
    await dsJSONOk(res, 200, {'success': true, ...relayConfigJson()});
    return;
  }
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
  final old = getRelayConfig();
  final cfg = RelayConfig(
    baseUrl: trimOr(mStr(body, 'baseUrl'), old.baseUrl),
    apiKey: mStr(body, 'apiKey').trim().isEmpty
        ? old.apiKey
        : mStr(body, 'apiKey').trim(),
    customModels: body.containsKey('customModels')
        ? asList(body['customModels'])
            .map((e) => '$e'.trim())
            .where((e) => e.isNotEmpty)
            .toList()
        : old.customModels,
    stream: body.containsKey('stream') ? mBool(body, 'stream') : old.stream,
  );
  if (mBool(body, 'clearKey')) cfg.apiKey = '';
  if (!saveRelayConfig(cfg)) {
    await dsJSONErr(res, 500, '配置保存失败');
    return;
  }
  await dsJSONOk(res, 200, {'success': true, ...relayConfigJson()});
}

Future<void> handleRelayModels(HttpRequest req) async {
  // ★ 停用整改：中转站模型清单接口一律拒绝，前端拿不到任何可调用模型。
  if (await relayRejectIfDisabled(req)) return;
  await dsJSONOk(req.response, 200, {
    'success': true,
    'models': relayModelListJson(),
  });
}
