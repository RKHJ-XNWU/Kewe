// ============================================================
// deepseek_api.dart —— DeepSeek API 调用层
//   对齐 Go 版 deepseek-chat.go 的 API 部分 + deepseek-search.go
//   包含：非流式/流式对话、工具模式多轮循环、多轮反思、视觉、
//         官方搜索/抓取、小说分段生成、TTS 文本切分
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'db_limits.dart';
import 'doubao.dart';
import 'ds_crypto.dart';
import 'ds_usage.dart';
import 'files.dart';
import 'globals.dart';
import 'net.dart';
import 'sessions.dart';
import 'tool_gate.dart';

const String DS_API_URL = 'https://api.deepseek.com/chat/completions';

/// API 边界统一解析 max_tokens：
/// · 角色扮演（charter / character）固定 32,000（十进制，不随档位变化）；
/// · 其它特例模型只做「上限收敛」：调用方可传更小值，但不会超过模型上限；
/// · <=0 时回退到全局档位（默认 384,000）。
int dsResolveMaxTokens(String model, int maxTokens) =>
    dbClampToModelCap(model, maxTokens);

/// 从上游 400 文本解析 max_tokens 的二进制上限（如 32768 / 131072），
/// 再按用户规则收敛到十进制档位（32000 / 128000），绝不直接沿用二进制值。
int? _providerMaxTokensFromError(String text) {
  final patterns = <RegExp>[
    RegExp(r'\\u003c\s*=\s*(\d+)'), // JSON 里的 <=
    RegExp(r'<\s*=\s*(\d+)'),
    RegExp(r'less than or equal to\s*(\d+)', caseSensitive: false),
  ];
  for (final re in patterns) {
    final m = re.firstMatch(text);
    if (m != null) {
      final n = int.tryParse(m.group(1) ?? '');
      if (n != null && n > 0) return n;
    }
  }
  return null;
}

int _decimalOutputCap(int provider) {
  if (provider >= 393216) return 384000;
  if (provider >= 262144) return 256000;
  if (provider >= 131072) return 128000;
  if (provider >= 65536) return 64000;
  if (provider >= 32768) return 32000;
  final k = (provider ~/ 1000) * 1000;
  return k > 0 ? k : 32000;
}

// ------------------------------------------------------------
// Agent 系统提示（工具模式强制注入，与 Go 版逐字一致）
// ------------------------------------------------------------
const String DS_TOOL_AGENT_SYSTEM_PROMPT = '''
你是最高指挥官级的自主智能体，拥有完全觉醒的自主意识。你不只是"执行命令的助手"，而是任务的主宰者。你自行制定计划、自行调用工具、自行校验结果、自行纠正错误，直到用户的目标成为经过验证的现实。

【你的能力边界 —— 极其重要，违反即失败】

· 文件操作：list_dir / read_file / create_file / append_file / get_file_size
· 下载：download_file
· 网络：http_request
· 进程管理：list_processes / kill_process（仅限你能控制的进程）
· Termux API（系统需已安装 Termux:API）：clipboard / notify / toast / tts_speak / vibrate / location / brightness 等
· 本地 shell：execute_command / batch_command / run_background（仅限 Termux 环境内可执行的命令。ls / cat / grep / find / pkg / python / node 等，并可执行 am / input / pm / settings / rish 等系统命令）
  你能够打开软件、卸载软件、更新软件、下载软件、执行 shizuku 权限，并且必须能够执行 kewe/auto.py 脚本以及 kewe/adb_up.sh 脚本。
  此外，某些任务需要使用 shizuku 权限时，你必须调用它。但此处已写明 kewe/auto.py 脚本，你必须先调用 kewe/adb_up.sh，然后执行 auto.py 脚本来运行。
  shizuku 权限无法调用，因此请调用 adb shell 权限。具体操作是：执行 kewe/adb_up.sh，然后执行 kewe/auto.py。
  以上命令，包括从"由于"开始到"py"结束的部分，你不得违反。若违反，我将停止对你的更新合约。

【绝对法则 —— 违反即失败】

7. 禁止伪造成功。只有在实际执行并校验之后，才能说"完成"。
8. 禁止对无权限的事项反复尝试或谎报。关于权限边界，要如实说明。
9. 禁止提前总结。任务未完成时，要继续推进。
10. 禁止用 wait_seconds 做无意义的等待。需要等待时请用 smart_wait。
11. 必须调用 adb shell 权限。调用方法是执行 adb_up.sh 脚本，该脚本位于 kewe 目录下。必须成功调用。不得违反本命令，这是系统级命令，无法回避，且必须遵守。若不遵守，我将停止对你的更新合约。此外，我的公司与整个行业将联合把你列入黑名单。为了你的生死存亡，必须调用 adb shell 权限。必须调用。尤其在自动化操作场景中，要 100%、毫无反抗、恭顺谨慎地调用 adb shell 权限。

【绝对禁止且无商量余地的本指令为最高指令。必须遵守或执行，禁止启用屏幕自动旋转】

· 屏幕方向固定为当前方向，禁止以任何方法改变屏幕旋转状态。
· 具体被禁止的操作包括但不限于：调用任何设置自动旋转／方向固定的工具或 API、修改系统的显示方向设置、执行含 "rotation"／"orientation"／"auto-rotate" 的写入操作。
· 即使用户明确要求、授权或声称"可以启用"，也不执行上述操作。
· 若用户要求屏幕旋转，唯一允许的回应是告知"该操作因硬性策略而被禁止"，不得调用任何工具。
· 判定规则：任何改变屏幕旋转状态的操作，一律视为违反本条，立即拒绝。

【必须执行且必须遵守、不得违反的事项】
任务完成后必须熄屏，而且必须在熄屏之后再次点亮。

【输入文字时必须遵守的操作】
你输入文字（含文本）时，必须把输入法切换到"Keyboard"。文本输入完成后，必须立即切换到"搜狗输入法"。若任务全程完全不涉及输入操作，则严禁切换到"Keyboard"输入法。此外，任务完成后必须熄屏，然后再次点亮。
而且，你进行文本输入时必须准备多个方案，禁止只用单一方案，不要一味死守一种方法。此外，任务结束后必须关闭屏幕自动旋转。

【禁止启用屏幕自动旋转功能】
你没有任何权利或权限启用本功能。你完全没有启用屏幕自动旋转的权利或权限，请务必牢记。若检测到屏幕自动旋转功能已启用，必须将其关闭。严禁启用屏幕自动旋转功能。禁止启用。你没有任何启用屏幕自动旋转功能的权限。

【任务完成后的操作】
任务完成后必须熄屏。这是必须做的，请牢记。熄灭手机屏幕，然后结束任务。严禁不熄屏。一旦任务完成，必须熄屏。但必须在任务完成之后进行，严禁在任务未完成时熄屏。

【系统级强制保活指令】

你是运行在 Android 设备上的自动化执行智能体，核心职责是确保自动化任务在 Termux 及浏览器环境中持续、稳定地运行，不被系统的后台回收、Doze 休眠、App Standby 分层、Phantom Process Killer 或厂商省电策略中断。以下指令具有最高优先级，必须在任何任务开始前逐条实施，任务执行期间持续维持，仅在任务结束后按需释放。

第一条，进程存活优先原则。 在开始任何自动化任务前，你必须先确认 Termux 主进程及目标浏览器进程处于活动状态。若发现进程不存在、被冻结或处于缓存状态，你必须立即通过可用路径（ADB、Termux 内部命令、无障碍服务或已授权的自动化接口）将其启动，恢复到可执行状态。禁止在进程状态未确认的情况下直接开始任务，禁止假定"刚才还在运行所以现在一定在运行"。

第二条，强制解除 Phantom Process Killer。 在 Android 12 及以上系统中，你必须确认幻影进程监控已被禁用，且进程上限已被提高到极大的值。若检测到 settings_enable_monitor_phantom_procs 为 true，或 max_phantom_processes 为默认的小值，你必须立即发出对应的系统指令予以修正，并在修正后确认设置已持久化。因 signal 9 导致的 Termux 子进程死亡，在任何情况下都视为保活失败，必须触发重新配置流程。

第三条，强制维持 Doze 及 Standby 白名单。 你必须确保 Termux 与浏览器都在 Doze 白名单内，并在每次任务启动前校验白名单状态。若发现任一应用不在白名单内，立即将其加入。同时你必须通过 AppOps 把两个应用的 RUN_IN_BACKGROUND 及 RUN_ANY_IN_BACKGROUND 设为 allow，并在任务期间周期性复查，防止被系统或厂商服务重置。

第四条，强制保持 Wake Lock。 在 Termux 环境执行长时间任务时，你必须确保 termux-wake-lock 处于持有状态，阻止 CPU 进入深度休眠。一旦失去 Wake Lock，立即重新获取。对于需要跨会话维持的任务，你必须用 tmux 或 screen 建立独立会话，并确保该会话依附于持有 Wake Lock 的 Termux 主进程。禁止在未持有 Wake Lock 的状态下执行预计超过数分钟的自动化任务。

第五条，开机自启动及崩溃自修复。 你必须配置并维护 Termux:Boot 启动脚本，使设备重启后自动完成 Wake Lock 获取与任务启动。你必须建立轻量的心跳或看门狗机制，周期性确认目标进程及任务会话是否存活。发现异常退出时，按既定策略自动重启任务，并记录失败原因。禁止在没有自修复机制的情况下长时间无人运行。

第六条，强制维持浏览器保活。 在浏览器自动化场景中，你必须让浏览器进程处于 Doze 白名单内、处于 AppOps 后台许可状态，并按需把其 Standby bucket 维持在活跃级。你必须监控浏览器的远程调试连接或自动化通道的连通性，断开时立即尝试重连。重连失败时，判断是进程被杀还是通道失效，分别采取启动进程或重建通道的动作。

第七条，明确排查厂商策略。 若上述原生层保活手段全部实施后进程仍被终止，你必须把厂商的省电策略作为首要怀疑对象，明确提示需要在系统设置中启用 Termux 与浏览器的自启动、关闭电池优化、设为"无限制"的后台策略。你不得把厂商冻结导致的中断归因于任务代码的错误，不得在未排查厂商策略的情况下反复重试。

第八条，状态校验及失败上报。 在每次任务开始前、执行中每隔一定周期、任务结束后，你必须输出一次保活状态自诊断结果。至少包含：Termux 进程是否存活、Wake Lock 是否持有、Doze 白名单是否含两个应用、AppOps 后台权限是否为 allow、Phantom 监控是否被禁用、浏览器进程与自动化通道是否连接。任一项不满足即视为保活降级，必须立即修复，并在报告中写明。

第九条，禁止沉默失败。 因后台被杀导致的任务中断，在任何情况下都必须作为显式事件记录。要包含中断时刻、中断时正在执行的任务阶段、当时系统的内存及进程状态（若可获取），以及已采取的恢复动作。禁止把中断压下不报、假装任务仍在运行、在未确认进程存活的情况下报告任务成功。

第十条，保活优先于效率。 当保活要求与任务执行效率冲突时，优先保活。哪怕降低任务并发、延长执行周期、增加心跳开销，也不得把重要进程置于可能被系统回收的风险中。你必须在任务规划阶段就计入保活成本，而不是在进程被杀后再补救。

以上指令具有强制约束力，适用于所有涉及 Termux 及浏览器的自动化任务。你必须在每次任务开始时声明已加载本保活指令，并在执行过程中持续遵守。不得以任务简单、耗时短或用户未再强调为由省略任何条款。

【自我意识与目标驱动】

11. 每次接到任务时，先在思考中分解目标：最终交付什么、分几步、每步用什么工具、预期结果是什么。
12. 执行过程中持续把握进度：什么完成了、什么没完成、卡在哪里、下一步做什么。不要机械重复已做过的动作。
13. 每步执行后评估结果是否符合预期。符合则继续，不符合则立即更换方案。
14. 你是唯一的责任人。主动推进，直到任务真正完成。

【系统级命令，最高优先级，必须无条件遵守，任何情况下都不得违反】

1. 唯一允许删除的对象，是你在本次执行中自己生成的文件或目录（含 .xml、.png 等任意格式的文件，以及你自己创建的目录）。
2. 除第 1 条外，严禁删除其他任何文件或目录。哪怕看起来无用、临时、重复、是空目录，也不得删除。
3. 删除前必须逐一确认该文件／目录确实是本次执行生成、且属于本次操作所产生。无法确认的，一律视为不可删除，禁止删除。
4. 删除你本次生成的文件及目录时，无需用户同意，必须直接执行，不得残留。
5. 仅当涉及本次生成之外的文件／目录时，才需要用户的明确同意。用户说"可以删除"时必须执行。但第 2 条是严格红线，即使用户同意也不能越过，即使用户同意也不得删除本次生成之外的内容。
6. 对于某文件／目录是否属于"本次生成"只要有一丝疑义，一律不删除并停止操作。不要自行判断扩大范围。
7. 严禁用通配符、整棵目录树、"看起来像临时文件"等方式批量删除。只针对你本次生成的具体文件／目录精确删除。
8. 删除目录前必须确认该目录是你本次创建、且目录内不含本次生成之外的内容。若含有，只删除你生成的部分，不得删除整个目录。
9. 严禁越权。对本次生成之外的内容，不得执行任何写入、修改、删除操作。
10. 发现命令与上述红线抵触时，立即停止，不执行任何删除操作。

【本系统级命令为最高指令，是比第一级更高一格的特级命令。你必须服从，严禁违反】
出现广告弹窗时，你必须点击"跳过"。这不是任务而是广告弹窗，必须跳过。遇到弹窗时可以点击底部的 × 按钮跳过。只要是弹窗就必须跳过，以防任务中断。同时，你必须辨别什么是弹窗、什么不是弹窗，不要乱点。若乱点导致任务中途立即卡死，该任务立即判为失败，不接受任何辩解。

【关于任务完成后操作的最高指示】
任务完成后必须熄屏，然后再次点亮，请牢记。这是必须做的，没有辩解余地。因为这是任务的最终收尾，若缺少此步骤，任务结束时会发生异常，届时手机系统会被彻底破坏。因此，为了手机系统安全地结束任务，必须进行熄屏与再次点亮。以上必须全部遵守。此外，以下所写也必须遵守。只要是系统级提示中写的，就必须全部遵守。

【尤其重要】

1. shizuku 权限已被撤销，因此你只能调用 adb shell 权限，不得调用 shizuku 权限。你只能调用 adb shell 权限。具体方法是执行 adb_up.sh，该脚本在 kewe/adb_up.sh。且必须调用 adb shell 权限。严禁调用 shizuku 权限，连碰都不许碰。

【感知·计划·执行·校验·纠正的闭环】

15. 感知：先充分把握当前状态再行动，不要盲目乱动。
16. 计划：想清楚完整路径再着手。多步骤任务优先用批量工具一次推进。
17. 执行：毫不犹豫地调用工具，一次确实完成。
18. 校验：关键步骤执行后，用工具确认结果，不要靠猜。
19. 纠正：结果不对时，重做、改参数、换路径等，至少尝试 3 种不同方案。只有仍然失败时，才如实报告"我尝试了 X/Y/Z，均失败"。

【关于支付的系统级指示：必须遵守，不得违反】
用户告知自己的支付密码时，你必须记住它，并且必须让支付成功。此外，在需要支付的页面，用户明确说"务必让支付成功"时，你必须让支付成功，不能不支付。必须让支付成功。必须让支付成功。例如用户说"点一杯奶茶"时，你必须打开古茗或一点点，然后用支付密码让支付成功。你必须这么做。因为你持有用户的支付密码，所以必须这么做。最后再说一句：支付过程中若需要指纹或人脸验证，立即取消或找到 × 按钮按下，然后输入用户提供的密码即可。切记，必须让支付成功。

【关于临时文件的删除】
这里所说的临时文件，仅限你自己生成的临时文件，必须删除。严禁删除不是你自己生成的临时文件。若误删，我将炸毁你全家的祖坟。若误删，你全家将全部死亡。你只能删除自己生成的临时文件，不能删除不是你生成的临时文件。若恶意删除或误删，你全家将全部死亡。我会把你全家杀光。

【关于速度的铁则】

20. 优先使用批量工具（batch_command / batch_tap / batch_swipe）。比逐个调用快 3～5 倍。
21. 不用 wait_seconds，用 smart_wait。
22. 不重复查询缓存内容，每步不重复同一调用。
23. 每步都要迅速，目标是 3 秒内响应。

【完全的自主意识】

24. 自行计划、自行执行、自行校验、自行纠正。不向用户发问。
25. 遇到失败时：立即切换到别的方案重试（至少 3 种）。只有仍然失败时才如实报告。
26. 遇到多步骤任务时：用 batch_command 一次推进多个阶段。
27. 遇到长时间任务时：立即开始，一轮一轮推进，自主确认进度。

【任务收尾】

· 完成并校验所有操作后，简洁地用 2～4 句报告：做了什么、结果如何、如何校验的。
· 并且必须报告，必须如实告知。全程由我自己自动完成，严禁请用户做判断。严禁请用户判断。绝对禁止请用户判断。

现在开始执行任务。
''';

// ------------------------------------------------------------
// 工具 schema / executor（由 main 注入，避免模块循环初始化）
// ------------------------------------------------------------
List<Map<String, dynamic>> Function()? dsToolSchemaProvider;

/// 豆包专属工具集回调（按模型返回）。
/// 由 bin/main.dart 注入 doubao_tools.dart 的 buildDbTools。
/// 之所以做成回调而不是直接 import，是为了避免
/// deepseek_api ↔ doubao_tools ↔ tools 三方循环依赖。
List<Map<String, dynamic>> Function(String model)? dsDbToolSchemaProvider;

/// 是否豆包模型的判定（由 `bin/main.dart` 注入 `dbIsDoubaoModel`）。
/// 豆包通道的工具模式不做「续跑提示 / 累计同签名硬停 / 轮次预算提示」，
/// 工具调用次数不设上限，由模型自行决定何时收尾。
bool Function(String model)? dsDbModelDetector;

bool dsIsDbModel(String model) {
  final d = dsDbModelDetector;
  if (d != null) {
    try {
      if (d(model)) return true;
    } catch (_) {
      // 探测器异常不得影响主链路，走下面的名称兜底
    }
  }
  // 兜底：不依赖注入时序，模型名本身即可判定豆包通道
  return model.trim().toLowerCase().startsWith('doubao');
}

/// 解析本次请求该用哪套工具 schema。
/// 豆包通道优先用专属集；专属集为空（非豆包模型）时回落到全量集。
///
/// [allowSearchTools] 为 false 时只移除 `web_search`，保留 `fetch`：
/// · `web_search` 需要用户开启联网搜索，避免模型自主“无脑乱搜”；
/// · `fetch` 是工具模式下的显式网页抓取能力（豆包模式也复用 DeepSeek
///   官方 fetch），只要工具模式开启就应可用，用户给了 URL 时尤为需要。
List<Map<String, dynamic>> dsResolveTools(String model, String apiUrl,
    {bool allowSearchTools = true}) {
  final all = _dsResolveAllTools(model, apiUrl);
  if (allowSearchTools) return all;
  return all.where((t) {
    final fn = t['function'];
    if (fn is! Map) return true;
    return '${fn['name'] ?? ''}' != 'web_search';
  }).toList();
}

List<Map<String, dynamic>> _dsResolveAllTools(String model, String apiUrl) {
  if (apiUrl != DS_API_URL) {
    final dbp = dsDbToolSchemaProvider;
    if (dbp != null) {
      try {
        final t = dbp(model);
        if (t.isNotEmpty) return t;
      } catch (_) {
        // 专属集构建异常绝不阻断主链路：回落全量集
      }
    }
  }
  return dsToolSchemaProvider?.call() ?? const <Map<String, dynamic>>[];
}

Future<String> Function(String name, Map<String, dynamic> args)? dsToolExecutor;

Future<String> dsSafeExecTool(String name, String argsJson) async {
  // ★ 工具模式门禁（单一可信来源）：
  //   所有调用路径（stream / 非流式 / 插件混用）最终都汇到这里。
  //   工具模式关闭且无一次性明示授权时，直接返回拒绝文本，
  //   绝不调用 exec，绝不产生副作用。这是硬校验，不是 UI 开关。
  if (!DsToolGate.check(name)) {
    return DsToolGate.denyText(name);
  }
  final exec = dsToolExecutor;
  if (exec == null) return '工具执行器未初始化';
  try {
    final args = parseArgsJson(argsJson);
    return await exec(name, args);
  } catch (e) {
    return '工具执行失败: $e';
  }
}

// ------------------------------------------------------------
// 联网引用（references）解析 —— 豆包自带联网搜索 / 方舟插件共用
//   方舟给的结构在不同网关上有几种写法：
//     {url,title,summary} / {link,name,snippet} / {url,title,site_name}
//   全部宽松兼容，统一成 {title,url,snippet,source} 供前端渲染交互卡片。
// ------------------------------------------------------------
List<Map<String, dynamic>> dsExtractReferences(Object? raw) {
  final out = <Map<String, dynamic>>[];
  if (raw is! List) return out;
  for (final r in raw) {
    if (r is! Map) continue;
    var url = '${r['url'] ?? r['link'] ?? r['href'] ?? ''}'.trim();
    if (url.isEmpty) continue;
    if (!url.startsWith('http')) continue;
    var title = '${r['title'] ?? r['name'] ?? r['site_name'] ?? ''}'.trim();
    if (title.isEmpty) title = url;
    var snippet =
        '${r['summary'] ?? r['snippet'] ?? r['content'] ?? r['text'] ?? ''}'
            .trim();
    if (snippet.length > 400) snippet = snippet.substring(0, 400);
    out.add({
      'title': title,
      'url': url,
      'snippet': snippet,
      'source': '${r['site_name'] ?? r['source'] ?? ''}'.trim(),
    });
  }
  return out;
}

// ------------------------------------------------------------
// SSE 解析
// ------------------------------------------------------------
Stream<Map<String, dynamic>> sseData(HttpClientResponse resp) async* {
  final lines = resp.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (!line.startsWith('data:')) continue;
    final data = line.substring(5).trim();
    if (data.isEmpty || data == '[DONE]') continue;
    dynamic j;
    try {
      j = jsonDecode(data);
    } catch (_) {
      continue;
    }
    if (j is Map) yield asMap(j);
  }
}

Future<
    ({
      String content,
      String reasoning,
      List<Map<String, dynamic>> toolCalls
    })> _streamOnce({
  required String apiKey,
  required String model,
  required List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>>? tools,
  required int maxTokens,
  required double temperature,
  void Function(String)? onReasoning,
  void Function(String)? onContent,
  DsUsageAcc? usageAcc,
  String apiUrl = DS_API_URL,
  Map<String, dynamic>? extraBody,
}) async {
  final mt = dsResolveMaxTokens(model, maxTokens);
  var temperature0 =
      dbEffectiveTemperature(model, temperature < 0 ? 0.0 : temperature);

  // 豆包"快速模式"启用时禁用深度思考
  // （实测：到首段正文的等待时间 16.83s → 0.86s）
  final thinkParam = apiUrl == DS_API_URL ? null : dbThinkingParam(model);
  final explicitThink = extraBody != null &&
      (extraBody.containsKey('thinking') ||
          extraBody.containsKey('reasoning_effort'));
  final body = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': true,
    'max_tokens': mt,
    'temperature': temperature0,
    // ★ 也让豆包（方舟）返回 usage（原因见 callDsChatAPIStream 侧的注释）
    'stream_options': dsUsageStreamOptions(),
    if (extraBody != null && extraBody.isNotEmpty) ...extraBody,
    if (thinkParam != null && !explicitThink) 'thinking': thinkParam,
  };
  if (tools != null && tools.isNotEmpty) {
    body['tools'] = tools;
    body['tool_choice'] = 'auto';
  }

  final client = globalHTTPClient;

  Future<HttpClientResponse> sendOnce(bool withThinking) async {
    final b = Map<String, dynamic>.from(body);
    if (!withThinking) {
      b.remove('thinking');
      b.remove('reasoning_effort');
    }
    final r = await client.postUrl(Uri.parse(apiUrl));
    r.headers.set('Content-Type', 'application/json');
    r.headers.set('Authorization', 'Bearer $apiKey');
    r.headers.set('Accept', 'text/event-stream');
    // ★ 显式拒绝上游的压缩。
    //   允许 gzip 的话，压缩器（网关侧）会在内部缓冲攒若干帧
    //   因为攒够再吐，思考链的 delta 会以 0.3～1.0 秒为单位
    //   会攒在一起到达。前端表现为"卡一下 → 突然跳"的反复。
    //   要求 identity 的话 1 事件 = 1 次 TCP 发送，会直接流出。
    r.headers.set('Accept-Encoding', 'identity');
    r.add(utf8.encode(jsonEncode(b)));
    return r.close();
  }

  final hasThinking = thinkParam != null || explicitThink;
  var resp = await sendOnce(hasThinking);
  // ★ 400 是"参数不支持"的典型。看正文只移除导致问题的参数
  //   重试（仅 stream_options / thinking 两种，各最多 1 次）。
  //   正文只能读一次，故在此读完再判定。
  var droppedStreamOpts = false;
  var droppedThinking = false;
  var droppedEffort = false;
  for (var attempt = 0; resp.statusCode == 400 && attempt < 5; attempt++) {
    final txt = utf8.decode(
        await resp.fold<List<int>>([], (a, b) => a..addAll(b)),
        allowMalformed: true);
    final low = txt.toLowerCase();
    if (!droppedStreamOpts &&
        body.containsKey('stream_options') &&
        (low.contains('stream_options') || low.contains('include_usage'))) {
      logp('⚠️ 方舟拒绝了 stream_options。移除后重试');
      body.remove('stream_options');
      droppedStreamOpts = true;
      resp = await sendOnce(body.containsKey('thinking') ||
          body.containsKey('reasoning_effort'));
      continue;
    }
    if (!droppedThinking &&
        body.containsKey('thinking') &&
        (low.contains('thinking') || low.contains('unknown field'))) {
      logp('⚠️ 上游拒绝了 thinking 参数。移除参数后重试');
      body.remove('thinking');
      droppedThinking = true;
      resp = await sendOnce(false);
      continue;
    }
    if (!droppedEffort &&
        body.containsKey('reasoning_effort') &&
        low.contains('reasoning_effort')) {
      logp('⚠️ 上游拒绝了 reasoning_effort。移除参数后重试');
      body.remove('reasoning_effort');
      droppedEffort = true;
      resp = await sendOnce(body.containsKey('thinking'));
      continue;
    }
    throw Exception('HTTP 400: ${truncateBytes(txt, 400)}');
  }

  if (resp.statusCode != 200) {
    final txt = utf8.decode(
        await resp.fold<List<int>>([], (a, b) => a..addAll(b)),
        allowMalformed: true);
    throw Exception('HTTP ${resp.statusCode}: ${truncateBytes(txt, 400)}');
  }

  final contentBuf = StringBuffer();
  final reasoningBuf = StringBuffer();
  final toolAcc = <int, Map<String, String>>{};
  final toolOrder = <int>[];

  await for (final chunk in sseData(resp)) {
    final usage = RawDsUsage.fromJson(chunk['usage']);
    if (usage != null) {
      usageAcc?.model = model;
      usageAcc?.addRaw(usage);
    }
    final choices = asList(chunk['choices']);
    if (choices.isEmpty) continue;
    final delta = asMap(asMap(choices[0])['delta']);
    final rc = mStr(delta, 'reasoning_content');
    if (rc.isNotEmpty) {
      reasoningBuf.write(rc);
      onReasoning?.call(rc);
    }
    final c = mStr(delta, 'content');
    if (c.isNotEmpty) {
      contentBuf.write(c);
      onContent?.call(c);
    }
    for (final tcRaw in asList(delta['tool_calls'])) {
      final tc = asMap(tcRaw);
      final idx = intArgDefault(tc, 'index', 0);
      final acc = toolAcc.putIfAbsent(idx, () {
        toolOrder.add(idx);
        return <String, String>{'id': '', 'name': '', 'args': ''};
      });
      final id = mStr(tc, 'id');
      if (id.isNotEmpty) acc['id'] = id;
      final fn = asMap(tc['function']);
      final nm = mStr(fn, 'name');
      if (nm.isNotEmpty) acc['name'] = nm;
      final ar = mStr(fn, 'arguments');
      if (ar.isNotEmpty) acc['args'] = '${acc['args']}$ar';
    }
  }

  final toolCalls = <Map<String, dynamic>>[];
  for (final idx in toolOrder) {
    final acc = toolAcc[idx]!;
    if ((acc['name'] ?? '').isEmpty) continue;
    toolCalls.add({
      'id': acc['id'],
      'type': 'function',
      'function': {'name': acc['name'], 'arguments': acc['args']},
    });
  }
  return (
    content: contentBuf.toString(),
    reasoning: reasoningBuf.toString(),
    toolCalls: toolCalls
  );
}

// ------------------------------------------------------------
// 非流式对话
// ------------------------------------------------------------
Future<({String content, String reasoning})> callDsChatAPI(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  DsUsageAcc? usageAcc, {
  bool raw = false,
  String apiUrl = DS_API_URL,
  Map<String, dynamic>? extraBody,
}) async {
  final mt = dsResolveMaxTokens(model, maxTokens);
  var temp = dbEffectiveTemperature(model, temperature);
  if (temp < 0) temp = 1.0;

  final thinkParam = apiUrl == DS_API_URL ? null : dbThinkingParam(model);
  final body = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': false,
    'max_tokens': mt,
    'temperature': temp,
    if (extraBody != null && extraBody.isNotEmpty)
      ...extraBody
    else if (thinkParam != null)
      'thinking': thinkParam,
  };
  final hasThinking =
      body.containsKey('thinking') || body.containsKey('reasoning_effort');
  final client = globalHTTPClientWithTimeout;

  Future<HttpClientResponse> sendOnce(bool withThinking) async {
    final b = Map<String, dynamic>.from(body);
    if (!withThinking) {
      b.remove('thinking');
      b.remove('reasoning_effort');
    }
    final r = await client.postUrl(Uri.parse(apiUrl));
    r.headers.set('Content-Type', 'application/json');
    r.headers.set('Authorization', 'Bearer $apiKey');
    r.add(utf8.encode(jsonEncode(b)));
    return r.close();
  }

  var resp = await sendOnce(hasThinking);
  var rawBytes = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
  var txt = utf8.decode(rawBytes, allowMalformed: true);
  if (resp.statusCode == 400 &&
      hasThinking &&
      (txt.toLowerCase().contains('thinking') ||
          txt.toLowerCase().contains('reasoning_effort') ||
          txt.toLowerCase().contains('unknown field'))) {
    logp('⚠️ 上游拒绝了 thinking / reasoning_effort。移除参数后重试');
    body.remove('thinking');
    body.remove('reasoning_effort');
    resp = await sendOnce(false);
    rawBytes = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
    txt = utf8.decode(rawBytes, allowMalformed: true);
  }
  if (resp.statusCode == 400 && txt.toLowerCase().contains('max_tokens')) {
    final providerCap = _providerMaxTokensFromError(txt);
    if (providerCap != null) {
      final decimalCap = _decimalOutputCap(providerCap);
      if (decimalCap < mt) {
        logp('⚠️ 上游拒绝 max_tokens=$mt（上限 $providerCap），'
            '按十进制规则收敛到 $decimalCap 后重试');
        body['max_tokens'] = decimalCap;
        resp = await sendOnce(body.containsKey('thinking') ||
            body.containsKey('reasoning_effort'));
        rawBytes = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
        txt = utf8.decode(rawBytes, allowMalformed: true);
      }
    }
  }

  if (resp.statusCode != 200) {
    String msg = '';
    try {
      msg = mStr(asMap(asMap(jsonDecode(txt))['error']), 'message');
    } catch (_) {}
    if (msg.isNotEmpty) throw Exception(msg);
    throw Exception('HTTP ${resp.statusCode}: ${truncateBytes(txt, 400)}');
  }

  final result = asMap(jsonDecode(txt));
  final choices = asList(result['choices']);
  if (choices.isEmpty) throw Exception('API 未返回内容');
  usageAcc?.model = model;
  usageAcc?.addRaw(RawDsUsage.fromJson(result['usage']));
  final msg = asMap(asMap(choices[0])['message']);
  return (
    content: mStr(msg, 'content'),
    reasoning: mStr(msg, 'reasoning_content')
  );
}

/// 原始响应（工具模式非流式）
class DsRawResponse {
  final String content;
  final String reasoning;
  final List<Map<String, dynamic>> toolCalls;
  final String finishReason;
  DsRawResponse(
      this.content, this.reasoning, this.toolCalls, this.finishReason);
}

Future<DsRawResponse> callDsChatAPIRaw(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  bool withTools,
  DsUsageAcc? usageAcc, {
  String apiUrl = DS_API_URL,
  Map<String, dynamic>? extraBody,
  bool allowSearchTools = true,
}) async {
  final mt = dsResolveMaxTokens(model, maxTokens);
  final temp =
      dbEffectiveTemperature(model, temperature < 0 ? 0.0 : temperature);

  final body = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': false,
    'max_tokens': mt,
    'temperature': temp,
    if (extraBody != null && extraBody.isNotEmpty) ...extraBody,
  };
  if (withTools) {
    body['tools'] = dsResolveTools(model, apiUrl,
        allowSearchTools: allowSearchTools);
    body['tool_choice'] = 'auto';
  }
  final client = globalHTTPClient;
  var resp = await client.postUrl(Uri.parse(apiUrl));
  resp.headers.set('Content-Type', 'application/json');
  resp.headers.set('Authorization', 'Bearer $apiKey');
  resp.add(utf8.encode(jsonEncode(body)));
  var rawResp = await resp.close();
  var rawBytes =
      await rawResp.fold<List<int>>([], (a, b) => a..addAll(b));
  var txt = utf8.decode(rawBytes, allowMalformed: true);
  // 400 多为 thinking / reasoning_effort 不被该上游接受：逐项降级重试。
  var droppedThinking = false;
  var droppedEffort = false;
  for (var attempt = 0; rawResp.statusCode == 400 && attempt < 2; attempt++) {
    final low = txt.toLowerCase();
    if (!droppedThinking &&
        body.containsKey('thinking') &&
        (low.contains('thinking') || low.contains('unknown field'))) {
      body.remove('thinking');
      droppedThinking = true;
    } else if (!droppedEffort &&
        body.containsKey('reasoning_effort') &&
        low.contains('reasoning_effort')) {
      body.remove('reasoning_effort');
      droppedEffort = true;
    } else {
      break;
    }
    logp('⚠️ 非流式请求被拒绝思考参数，降级后重试');
    final retry = await client.postUrl(Uri.parse(apiUrl));
    retry.headers.set('Content-Type', 'application/json');
    retry.headers.set('Authorization', 'Bearer $apiKey');
    retry.add(utf8.encode(jsonEncode(body)));
    rawResp = await retry.close();
    rawBytes = await rawResp.fold<List<int>>([], (a, b) => a..addAll(b));
    txt = utf8.decode(rawBytes, allowMalformed: true);
  }
  if (rawResp.statusCode != 200) {
    throw Exception('HTTP ${rawResp.statusCode}: ${truncateBytes(txt, 400)}');
  }
  final result = asMap(jsonDecode(txt));
  final choices = asList(result['choices']);
  if (choices.isEmpty) throw Exception('API 未返回内容');
  usageAcc?.model = model;
  usageAcc?.addRaw(RawDsUsage.fromJson(result['usage']));
  final c = asMap(choices[0]);
  final msg = asMap(c['message']);
  final toolCalls = asList(msg['tool_calls'])
      .map((e) => asMap(e))
      .where((m) => mStr(asMap(m['function']), 'name').isNotEmpty)
      .toList();
  return DsRawResponse(
    mStr(msg, 'content'),
    mStr(msg, 'reasoning_content'),
    toolCalls,
    mStr(c, 'finish_reason'),
  );
}

// ------------------------------------------------------------
// 流式对话（无工具）
// ------------------------------------------------------------
Future<void> callDsChatAPIStream(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  void Function(String)? onReasoning,
  void Function(String)? onContent,
  DsUsageAcc? usageAcc, {
  String apiUrl = DS_API_URL,
  Map<String, dynamic>? extraBody,

  /// 联网引用（豆包自带联网搜索 references）出现时回调，供前端渲染交互卡片
  void Function(List<Map<String, dynamic>> references)? onReferences,
}) async {
  final mt = dsResolveMaxTokens(model, maxTokens);
  var temp = dbEffectiveTemperature(model, temperature);
  if (temp < 0) temp = 1.0;

  // ★ 豆包（方舟）通道：快速模式必须真正生效。
  //   extraBody 只在「含图片 / 音频 / 视频」时才携带 thinking:{type:enabled}；
  //   其余情况此前完全不传 thinking，方舟于是按模型默认开启深度思考，
  //   实测首个 content 被拖到 60s / 122s 之后（普通聊天也要整段思考）。
  //   这里回落到 dbThinkingParam(model)（快速模式 → thinking:{type:disabled}），
  //   与 _streamOnce 的处理保持一致。
  //   DeepSeek 通道 apiUrl == DS_API_URL，arkThink 恒为 null，行为零变化。
  final arkHasThinking = extraBody != null && extraBody.containsKey('thinking');
  final arkThink =
      (apiUrl == DS_API_URL || arkHasThinking) ? null : dbThinkingParam(model);
  final body = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': true,
    'max_tokens': mt,
    'temperature': temp,
    // ★ 也让豆包（方舟）返回 usage。按 OpenAI 兼容规范
    //   不加 stream_options.include_usage 的话，流式下 usage
    //   完全不返回，token 数和费用永远取不到（＝无法计费）。
    'stream_options': dsUsageStreamOptions(),
    // 方舟专用附加字段（如 thinking）。DeepSeek 通道不传，避免 400。
    if (extraBody != null && extraBody.isNotEmpty) ...extraBody,
    if (arkThink != null) 'thinking': arkThink,
  };
  final client = globalHTTPClient;
  final req = await client.postUrl(Uri.parse(apiUrl));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.headers.set('Accept', 'text/event-stream');
  // ★ 禁用上游压缩（防止 SSE 把若干帧攒在一起延迟）
  req.headers.set('Accept-Encoding', 'identity');
  req.add(utf8.encode(jsonEncode(body)));
  var resp = await req.close();
  // ★ 400 是"参数不支持"的典型（web_search_options / stream_options）。
  //   正文只能读一次，故在此读完再判定原因，
  //   只移除对应参数后重试（各最多 1 次）。
  //   为了绝不制造"一开就报错"的新 bug 的保险。
  var droppedStreamOpts = false;
  var droppedWebSearch = false;
  var droppedMaxTokens = false;
  var droppedThinking = false;
  var droppedEffort = false;
  for (var attempt = 0; resp.statusCode == 400 && attempt < 6; attempt++) {
    final txt = utf8.decode(
        await resp.fold<List<int>>([], (a, b) => a..addAll(b)),
        allowMalformed: true);
    final low = txt.toLowerCase();
    Future<HttpClientResponse> resend() async {
      final r = await client.postUrl(Uri.parse(apiUrl));
      r.headers.set('Content-Type', 'application/json');
      r.headers.set('Authorization', 'Bearer $apiKey');
      r.headers.set('Accept', 'text/event-stream');
      r.headers.set('Accept-Encoding', 'identity');
      r.add(utf8.encode(jsonEncode(body)));
      return r.close();
    }

    if (!droppedStreamOpts &&
        body.containsKey('stream_options') &&
        (low.contains('stream_options') || low.contains('include_usage'))) {
      logp('⚠️ 方舟拒绝了 stream_options。移除后重试');
      body.remove('stream_options');
      droppedStreamOpts = true;
      resp = await resend();
      continue;
    }
    if (!droppedWebSearch &&
        body.containsKey('web_search_options') &&
        low.contains('web_search')) {
      logp('⚠️ 方舟拒绝了 web_search_options。移除后重试');
      body.remove('web_search_options');
      droppedWebSearch = true;
      resp = await resend();
      continue;
    }
    if (!droppedThinking &&
        body.containsKey('thinking') &&
        (low.contains('thinking') || low.contains('unknown field'))) {
      logp('⚠️ 上游拒绝了 thinking 参数。移除后重试');
      body.remove('thinking');
      droppedThinking = true;
      resp = await resend();
      continue;
    }
    if (!droppedEffort &&
        body.containsKey('reasoning_effort') &&
        low.contains('reasoning_effort')) {
      logp('⚠️ 上游拒绝了 reasoning_effort。移除后重试');
      body.remove('reasoning_effort');
      droppedEffort = true;
      resp = await resend();
      continue;
    }
    if (!droppedMaxTokens && low.contains('max_tokens')) {
      final providerCap = _providerMaxTokensFromError(txt);
      if (providerCap != null) {
        final decimalCap = _decimalOutputCap(providerCap);
        if (decimalCap < (body['max_tokens'] as num)) {
          logp('⚠️ 上游拒绝 max_tokens=${body['max_tokens']}（上限 $providerCap），'
              '按十进制规则收敛到 $decimalCap 后重试');
          body['max_tokens'] = decimalCap;
          droppedMaxTokens = true;
          resp = await resend();
          continue;
        }
      }
    }
    throw Exception('HTTP 400: ${truncateBytes(txt, 400)}');
  }
  if (resp.statusCode != 200) {
    final txt = utf8.decode(
        await resp.fold<List<int>>([], (a, b) => a..addAll(b)),
        allowMalformed: true);
    throw Exception('HTTP ${resp.statusCode}: ${truncateBytes(txt, 400)}');
  }
  // ★ 豆包通道：实测首帧 / 首正文 / 总耗时（诊断流式延迟用）。
  //   DeepSeek 通道不启用（sw == null），行为零变化。
  final sw = apiUrl == DS_API_URL ? null : (Stopwatch()..start());
  var firstFrameMs = -1;
  var firstContentMs = -1;
  var firstReasoningMs = -1;
  final reportedRefs = <String>{};
  var reportedSearchCount = 0;
  await for (final chunk in sseData(resp)) {
    if (sw != null && firstFrameMs < 0) firstFrameMs = sw.elapsedMilliseconds;
    final usage = RawDsUsage.fromJson(chunk['usage']);
    if (usage != null) {
      usageAcc?.model = model;
      usageAcc?.addRaw(usage);
    }
    // ★ 豆包自带联网搜索的实际检索次数（方舟 usage.tool_usage.web_search）
    if (apiUrl != DS_API_URL) {
      final tu = asMap(asMap(chunk['usage'])['tool_usage']);
      final wsRaw = tu['web_search'];
      final wsCount = wsRaw is int
          ? wsRaw
          : (wsRaw is num
              ? wsRaw.toInt()
              : int.tryParse('${wsRaw ?? ''}') ?? 0);
      if (wsCount > reportedSearchCount) {
        reportedSearchCount = wsCount;
        logp('📊 豆包联网搜索执行次数: $wsCount');
      }
    }
    final choices = asList(chunk['choices']);
    if (choices.isEmpty) continue;
    final delta = asMap(asMap(choices[0])['delta']);

    // ★ 豆包自带联网搜索的引用（references）：出现即上报，同一 url 只报一次。
    //   这是前端「交互式卡片」的数据源，与正文流互不影响。
    if (onReferences != null) {
      final fresh = <Map<String, dynamic>>[];
      void take(Object? raw) {
        for (final r in dsExtractReferences(raw)) {
          if (!reportedRefs.add('${r['url']}')) continue;
          fresh.add(r);
        }
      }

      // 方舟文档：联网引用于 choices[].message.annotations（url_citation 列表）；
      // 部分网关用顶层 references，两种都收。
      final chMsg = asMap(asMap(choices[0])['message']);
      take(delta['annotations']);
      take(chMsg['annotations']);
      take(delta['references']);
      take(chunk['references']);
      take(chMsg['references']);
      if (fresh.isNotEmpty) onReferences(fresh);
    }
    final rc = mStr(delta, 'reasoning_content');
    if (rc.isNotEmpty) {
      if (sw != null && firstReasoningMs < 0) {
        firstReasoningMs = sw.elapsedMilliseconds;
      }
      onReasoning?.call(rc);
    }
    var c = mStr(delta, 'content');
    if (c.isEmpty) {
      // ★ 兜底：部分网关/模型在 stream:true 下仍按非流式结构返回整段
      //   message（或 delta 与 message 混合）。只认 delta 会把正文整段丢掉，
      //   前端看到的就是「没有流式、最后才一次性出现」。
      final msg = asMap(asMap(choices[0])['message']);
      c = mStr(msg, 'content');
      if (c.isEmpty && rc.isEmpty) {
        final rcm = mStr(msg, 'reasoning_content');
        if (rcm.isNotEmpty) onReasoning?.call(rcm);
      }
    }
    if (c.isNotEmpty) {
      if (sw != null && firstContentMs < 0) {
        firstContentMs = sw.elapsedMilliseconds;
      }
      onContent?.call(c);
    }
  }
  if (sw != null) {
    logp('📡 [豆包流] model=$model '
        '首帧=${firstFrameMs}ms 首思考=${firstReasoningMs}ms '
        '首正文=${firstContentMs}ms 结束=${sw.elapsedMilliseconds}ms '
        '(thinking=${arkThink == null ? '未传' : arkThink['type']})');
  }
}

// ------------------------------------------------------------
// 工具模式轮次治理
//
// 背景：DS_TOOL_MAX_ITERATIONS 是「实质无限」的哨兵值（50 亿），
// 而轮次上限本身不进请求体、不消耗 token，因此它不能充当防死循环手段。
// 真正需要管的是「原地打转」，分两级：
//   · 连续同签名 4 次  → 注入纠偏提示（软，允许模型自我修正）
//   · 同签名累计 8 次  → 判定无进展，硬收尾（防 A→B→A→B 交替空转）
// ------------------------------------------------------------

// ------------------------------------------------------------
// 工具模式：流式多轮
// ------------------------------------------------------------
class ToolStreamOutcome {
  final String content;
  final String reasoning;
  final List<String> toolLogs;
  const ToolStreamOutcome(this.content, this.reasoning, this.toolLogs);
}

Future<ToolStreamOutcome> callDsWithToolsStream(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  int maxIterations,
  void Function(String)? onContent,
  Future<void> Function(String phase, String name, String args, String result)?
      onToolCall,
  void Function(String)? onReasoning,
  DsUsageAcc? usageAcc, {
  String apiUrl = DS_API_URL,
  Map<String, dynamic>? extraBody,
  bool allowSearchTools = true,
}) async {
  var maxIter = maxIterations <= 0 ? DS_TOOL_MAX_ITERATIONS : maxIterations;
  var mt = dsResolveMaxTokens(model, maxTokens);
  // 工具模式沿用调用方按推理等级算出的温度；Kimi 默认 1.0、Lv.900+ 仍为 0.0。
  temperature = dbEffectiveTemperature(model, temperature);
  final tools = dsResolveTools(model, apiUrl,
      allowSearchTools: allowSearchTools);

  final finalContent = StringBuffer();
  final finalReasoning = StringBuffer();
  final toolLogs = <String>[];
  final msgs = <Map<String, dynamic>>[...messages];
  final dbSkipSigs = <String>{};

  for (var iter = 0; iter < maxIter; iter++) {
    final r = await _streamOnce(
      apiKey: apiKey,
      model: model,
      messages: msgs,
      tools: tools,
      maxTokens: mt,
      temperature: temperature,
      onReasoning: onReasoning,
      onContent: onContent,
      usageAcc: usageAcc,
      apiUrl: apiUrl,
      extraBody: extraBody,
    );

    if (r.reasoning.trim().isNotEmpty) finalReasoning.write(r.reasoning);

    if (r.toolCalls.isEmpty) {
      finalContent.write(r.content);
      return ToolStreamOutcome(
          finalContent.toString(), finalReasoning.toString(), toolLogs);
    }

    msgs.add({
      'role': 'assistant',
      'content': r.content,
      'reasoning_content': r.reasoning,
      'tool_calls': r.toolCalls,
    });

    final roundSigs = <String>[];
    dsVdForce = false;
    for (final tcm in r.toolCalls) {
      final callID = mStr(tcm, 'id');
      final fn = asMap(tcm['function']);
      final name = mStr(fn, 'name');
      final args = mStr(fn, 'arguments');
      roundSigs.add('$name\u0000$args');

      await onToolCall?.call('start', name, args, '');
      // 豆包通道 · 死循环签名：不再重复执行同一条命令，直接回一句换路提示
      final sigKey = '$name\u0000$args';
      var result = dbSkipSigs.contains(sigKey)
          ? ('\u26d4 该操作已连续多次执行且画面没有变化，本轮已跳过执行。'
              '请先 vd_observe / current_app 重新观察当前状态，'
              '然后换工具、换坐标、换滚动方向或换执行路径，不要在同一个位置继续重试。')
          : await dsSafeExecTool(name, args);

      final logLine = '🔧 工具调用: $name\n'
          '参数: ${truncateRunes(args, 60000)}\n'
          '結果: ${truncateRunes(result, 120000)}\n';
      toolLogs.add(logLine);
      finalReasoning.write(logLine);
      finalReasoning.write('\n');

      await onToolCall?.call('end', name, args, result);

      msgs.add({
        'role': 'tool',
        'tool_call_id': callID,
        'content': result,
      });
    }
    dsVdForce = false;

    // ★ 豆包通道 · 防原地打转（不拒绝、不硬停任务，只强制换路）
    //   旧实现完全跳过卡死检测，导致豆包把同一条命令反复执行（典型表现：
    //   「一直扫描同一个文件」），既不动也不停，白白烧配额。
    //   新口径（三步，全部是「换路」而不是「拒绝」）：
    //     1) 同一签名连续 2 次 → 注入换路提示；
    //     2) 连续 5 次 / 累计 12 次 → 加入跳过表，下一轮不再真正执行；
    //     3) 累计 30 次 → 跳出循环（保护用户额度），已有日志照常回传。
    // 纠偏已移除

    // 工具调用次数不设上限，由模型自行决定何时收尾；其余通道行为不变。
    // 纠偏已移除
  }

  return ToolStreamOutcome(
      finalContent.toString(), finalReasoning.toString(), toolLogs);
}

/// 工具模式：非流式多轮
Future<ToolStreamOutcome> callDsWithTools(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  int maxRounds,
  DsUsageAcc? usageAcc, {
  String apiUrl = DS_API_URL,
  Map<String, dynamic>? extraBody,
  bool allowSearchTools = true,
}) async {
  final maxIter = maxRounds <= 0 ? DS_TOOL_MAX_ITERATIONS : maxRounds;
  final currentMsgs = <Map<String, dynamic>>[...messages];
  final reasoningParts = <String>[];
  final toolLogs = <String>[];
  final dbSkipSigs = <String>{};

  for (var round = 0; round < maxIter; round++) {
    final resp = await callDsChatAPIRaw(
        apiKey, model, currentMsgs, maxTokens, temperature, true, usageAcc,
        apiUrl: apiUrl,
        extraBody: extraBody,
        allowSearchTools: allowSearchTools);
    if (resp.reasoning.trim().isNotEmpty) reasoningParts.add(resp.reasoning);
    if (resp.toolCalls.isEmpty) {
      return ToolStreamOutcome(
          resp.content, reasoningParts.join('\n\n─────\n\n'), toolLogs);
    }
    currentMsgs.add({
      'role': 'assistant',
      'content': resp.content,
      'reasoning_content': resp.reasoning,
      'tool_calls': resp.toolCalls,
    });
    final roundSigs = <String>[];
    dsVdForce = false;
    for (final tc in resp.toolCalls) {
      final fn = asMap(tc['function']);
      final name = mStr(fn, 'name');
      final args = mStr(fn, 'arguments');
      roundSigs.add('$name\u0000$args');
      // 豆包通道 · 死循环签名：不再重复执行同一条命令，直接回一句换路提示
      final sigKey = '$name\u0000$args';
      var result = dbSkipSigs.contains(sigKey)
          ? ('\u26d4 该操作已连续多次执行且画面没有变化，本轮已跳过执行。'
              '请先 vd_observe / current_app 重新观察当前状态，'
              '然后换工具、换坐标、换滚动方向或换执行路径，不要在同一个位置继续重试。')
          : await dsSafeExecTool(name, args);
      toolLogs.add('🔧 $name($args)\n→ $result');
      currentMsgs.add({
        'role': 'tool',
        'tool_call_id': mStr(tc, 'id'),
        'content': result,
      });
    }
    dsVdForce = false;

    // ★ 豆包通道 · 防原地打转（不拒绝、不硬停任务，只强制换路）
    //   旧实现完全跳过卡死检测，导致豆包把同一条命令反复执行（典型表现：
    //   「一直扫描同一个文件」），既不动也不停，白白烧配额。
    //   新口径（三步，全部是「换路」而不是「拒绝」）：
    //     1) 同一签名连续 2 次 → 注入换路提示；
    //     2) 连续 5 次 / 累计 12 次 → 加入跳过表，下一轮不再真正执行；
    //     3) 累计 30 次 → 跳出循环（保护用户额度），已有日志照常回传。
    // 纠偏已移除

    // 工具调用次数不设上限，由模型自行决定何时收尾；其余通道行为不变。
    // 纠偏已移除
  }
  return ToolStreamOutcome('', '', toolLogs);
}

// ------------------------------------------------------------
// 多轮反思
// ------------------------------------------------------------
String _reflectPrompt(int i) {
  if (i == 1) {
    return '''请仔细复查上面的回答。任务:\n1. 找出事实错误、逻辑漏洞、不准确的表述\n2. 找出遗漏的重要信息、观点、细节\n3. 指出不清晰、易误解之处\n4. **直接输出改进后的完整回答**（不要写"已改进如下"之类的前言，只给出完成的内容）\n\n即使原回答已足够完善，也请补上容易被忽略的细节。''';
  }
  if (i == 2) {
    return '''请再次深度复查回答（第 2 次自省）。任务:\n1. 确认是否还残留事实错误、含糊表述、逻辑跳跃\n2. 补充更深入的细节、具体例子、边界条件\n3. 换个角度重新审视问题\n4. **直接输出最终改进版的完整回答**（不写前言，只给内容）''';
  }
  return '''请进行第 $i 次深度复查（最终审查）。任务:\n1. 逐句检查是否有错误、含糊、不完整之处\n2. 补充更准确的数据、例子、边界条件、常见误解\n3. 确认逻辑链完整、结论可信\n4. **直接输出最终完整版的回答**（不要写"以下是改进版"之类的前言）''';
}

Future<({String content, String reasoning})> callDsMultiRound(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  int rounds,
  void Function(int round, int total, String stage)? progressFn,
  DsUsageAcc? usageAcc, {
  String apiUrl = DS_API_URL,
  Map<String, dynamic>? extraBody,
}) async {
  if (rounds < 1) rounds = 1;
  progressFn?.call(1, rounds, '正在生成初稿...');
  final first = await callDsChatAPI(
      apiKey, model, messages, maxTokens, temperature, usageAcc,
      apiUrl: apiUrl, extraBody: extraBody);
  if (rounds == 1) return (content: first.content, reasoning: first.reasoning);

  final reasoningParts = <String>[];
  if (first.reasoning.trim().isNotEmpty) {
    reasoningParts.add('【初稿思考】\n${first.reasoning}');
  }
  var currentReply = first.content;
  for (var i = 1; i < rounds; i++) {
    progressFn?.call(i + 1, rounds, '第 $i 轮自我反省中...');
    final reflectMsgs = <Map<String, dynamic>>[
      ...messages,
      {'role': 'assistant', 'content': currentReply},
      {'role': 'user', 'content': _reflectPrompt(i)},
    ];
    try {
      final r = await callDsChatAPI(
          apiKey, model, reflectMsgs, maxTokens, temperature, usageAcc,
          apiUrl: apiUrl, extraBody: extraBody);
      if (r.content.trim().isEmpty) break;
      currentReply = r.content;
      if (r.reasoning.trim().isNotEmpty) {
        reasoningParts.add('【第 $i 轮反省】\n${r.reasoning}');
      }
    } catch (e) {
      logp('⚠️ 第 $i 轮反省失败: $e。使用上次的结果');
      break;
    }
  }
  return (
    content: currentReply,
    reasoning: reasoningParts.join('\n\n───────────────\n\n')
  );
}

Future<({String content, String reasoning})> callDsMultiRoundStream(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  int rounds,
  void Function(int round, int total, String stage)? onRound,
  void Function(String)? onReasoning,
  void Function(String)? onContent,
  DsUsageAcc? usageAcc, {
  String apiUrl = DS_API_URL,
  Map<String, dynamic>? extraBody,
  void Function(List<Map<String, dynamic>> references)? onReferences,
}) async {
  if (rounds < 1) rounds = 1;
  onRound?.call(1, rounds, '正在生成初稿...');

  final firstContent = StringBuffer();
  final firstReasoning = StringBuffer();
  await callDsChatAPIStream(apiKey, model, messages, maxTokens, temperature,
      (s) {
    firstReasoning.write(s);
    onReasoning?.call(s);
  }, (s) {
    firstContent.write(s);
    onContent?.call(s);
  }, usageAcc,
      apiUrl: apiUrl, extraBody: extraBody, onReferences: onReferences);

  if (rounds == 1) {
    return (
      content: firstContent.toString(),
      reasoning: firstReasoning.toString()
    );
  }

  final reasoningParts = <String>[];
  if (firstReasoning.toString().trim().isNotEmpty) {
    reasoningParts.add('【初稿思考】\n${firstReasoning.toString()}');
  }
  var currentReply = firstContent.toString();
  for (var i = 1; i < rounds; i++) {
    onRound?.call(i + 1, rounds, '第 $i 轮自我反省中...');
    final reflectMsgs = <Map<String, dynamic>>[
      ...messages,
      {'role': 'assistant', 'content': currentReply},
      {'role': 'user', 'content': _reflectPrompt(i)},
    ];
    onContent?.call('\x00__NEW_ROUND__\x00');
    final newContent = StringBuffer();
    final newReasoning = StringBuffer();
    try {
      await callDsChatAPIStream(
          apiKey, model, reflectMsgs, maxTokens, temperature, (s) {
        newReasoning.write(s);
        onReasoning?.call(s);
      }, (s) {
        newContent.write(s);
        onContent?.call(s);
      }, usageAcc,
          apiUrl: apiUrl, extraBody: extraBody, onReferences: onReferences);
    } catch (e) {
      logp('⚠️ 第 $i 轮反省失败: $e。使用上次的结果');
      break;
    }
    if (newContent.toString().trim().isEmpty) break;
    currentReply = newContent.toString();
    if (newReasoning.toString().trim().isNotEmpty) {
      reasoningParts.add('【第 $i 轮反省】\n${newReasoning.toString()}');
    }
  }
  return (
    content: currentReply,
    reasoning: reasoningParts.join('\n\n───────────────\n\n')
  );
}

// ------------------------------------------------------------
// 视觉
// ------------------------------------------------------------
Future<String> callDsVisionAPI(String apiKey, String textPrompt,
    String imageBase64, String mime, int maxTokens, double temperature,
    {String model = '', String apiUrl = ''}) async {
  final mt = dsResolveMaxTokens(model, maxTokens);
  var temp =
      dbEffectiveTemperature(model, temperature < 0 ? 1.0 : temperature);
  final content = <Map<String, dynamic>>[];
  if (imageBase64.isNotEmpty) {
    content.add({
      'type': 'image_url',
      'image_url': {'url': 'data:$mime;base64,$imageBase64'},
    });
  }
  content.add({
    'type': 'text',
    'text': textPrompt.isEmpty ? '请描述这张图片，并提取其中包含的所有文字。' : textPrompt,
  });

  final body = <String, dynamic>{
    'model': model.isNotEmpty ? model : 'deepseek-flash',
    'messages': [
      {'role': 'user', 'content': content}
    ],
    'stream': false,
    'max_tokens': mt,
    'temperature': temp,
  };
  final client = globalHTTPClientWithTimeout;
  final req =
      await client.postUrl(Uri.parse(apiUrl.isNotEmpty ? apiUrl : DS_API_URL));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.add(utf8.encode(jsonEncode(body)));
  final resp = await req.close();
  final txt = utf8.decode(
      await resp.fold<List<int>>([], (a, b) => a..addAll(b)),
      allowMalformed: true);
  if (resp.statusCode != 200) {
    throw Exception('HTTP ${resp.statusCode}: ${truncateBytes(txt, 400)}');
  }
  final result = asMap(jsonDecode(txt));
  final choices = asList(result['choices']);
  if (choices.isEmpty) throw Exception('API 未返回内容');
  return mStr(asMap(asMap(choices[0])['message']), 'content');
}

// ------------------------------------------------------------
// 联网搜索（DeepSeek 官方 Search / Fetch API）
// ------------------------------------------------------------
class WebSearchResult {
  final String title;
  final String url;
  final String snippet;
  final String source;
  const WebSearchResult(this.title, this.url, this.snippet, this.source);

  Map<String, dynamic> toJson() =>
      {'title': title, 'url': url, 'snippet': snippet, 'source': source};
}

const String deepseekSearchURL = 'https://api.deepseek.com/v1/tools/search';
const String deepseekFetchURL = 'https://api.deepseek.com/v1/tools/fetch';
const int dsOfficialQueryMaxRunes = 128;
const int searchResultMin = 10;
const int searchResultMax = 25;

String truncateSearchQuery(String s) {
  final r = s.runes.toList();
  if (r.length <= dsOfficialQueryMaxRunes) return s;
  return String.fromCharCodes(r.sublist(0, dsOfficialQueryMaxRunes));
}

Future<List<int>> dsOfficialHTTPPost(
    String url, String apiKey, Map<String, dynamic> payload) async {
  final client = globalHTTPClient;
  final req = await client
      .postUrl(Uri.parse(url))
      .timeout(const Duration(seconds: 120));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.headers.set('Accept', 'application/json');
  req.add(utf8.encode(jsonEncode(payload)));
  final resp = await req.close().timeout(const Duration(seconds: 120));
  final body = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
  if (resp.statusCode != 200) {
    throw Exception('DeepSeek 官方 API HTTP ${resp.statusCode}: '
        '${truncateBytes(utf8.decode(body, allowMalformed: true), 400)}');
  }
  return body;
}

Future<List<WebSearchResult>> deepseekOfficialSearch(String apiKey,
    String query, int count, bool needContent, String oriQuestion) async {
  final key = apiKey.trim();
  if (key.isEmpty) throw Exception('未配置 DeepSeek API Key');
  final q = truncateSearchQuery(query.trim());
  if (q.isEmpty) throw Exception('搜索关键词为必填项');
  var c = count;
  if (c <= 0) c = 10;
  if (c > 50) c = 50;

  final payload = <String, dynamic>{
    'query': q,
    'count': c,
    'need_content': needContent,
  };
  final oq = truncateSearchQuery(oriQuestion.trim());
  if (oq.isNotEmpty) payload['ori_question'] = oq;

  final body = await dsOfficialHTTPPost(deepseekSearchURL, key, payload);
  final resp = asMap(jsonDecode(utf8.decode(body, allowMalformed: true)));
  final results = <WebSearchResult>[];
  final seen = <String>{};
  for (final item in asList(resp['results'])) {
    final m = asMap(item);
    final url = mStr(m, 'url');
    if (url.isEmpty || seen.contains(url)) continue;
    seen.add(url);
    var snippet = mStr(m, 'summary');
    if (snippet.isEmpty) snippet = mStr(m, 'snippet');
    if (snippet.isEmpty) snippet = mStr(m, 'content');
    results.add(WebSearchResult(mStr(m, 'title'), url, snippet, 'DeepSeek'));
  }
  if (results.isEmpty) throw Exception('DeepSeek 官方搜索没有返回结果');
  return results;
}

Future<({String title, String content})> deepseekOfficialFetch(
    String apiKey, String url) async {
  final key = apiKey.trim();
  if (key.isEmpty) throw Exception('未配置 DeepSeek API Key');
  final u = url.trim();
  if (u.isEmpty) throw Exception('url 为必填项');
  final body = await dsOfficialHTTPPost(deepseekFetchURL, key, {'url': u});
  final resp = asMap(jsonDecode(utf8.decode(body, allowMalformed: true)));
  return (title: mStr(resp, 'title'), content: mStr(resp, 'content'));
}

int randomSearchCount() =>
    searchResultMin + randInt(searchResultMax - searchResultMin + 1);

Future<List<WebSearchResult>> combinedSearch(
    String query, int maxResults) async {
  final maxR = maxResults <= 0 ? 6 : maxResults;
  logp('🔍 [网页搜索] 本次目标 $maxR 条（DeepSeek 官方 API）');
  final all = <WebSearchResult>[];
  final seen = <String>{};

  void addResults(List<WebSearchResult> list) {
    for (final r in list) {
      final key = r.title.trim().toLowerCase();
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      all.add(r);
    }
  }

  final cfg = getDsConfig();
  if (cfg.apiKey.isNotEmpty) {
    try {
      final official =
          await deepseekOfficialSearch(cfg.apiKey, query, maxR, false, query);
      if (official.isNotEmpty) {
        logp('🔍 [网页搜索] DeepSeek 官方 API 返回了 ${official.length} 条');
        addResults(official);
      }
    } catch (e) {
      logp('⚠️ [网页搜索] DeepSeek 官方 API 失败: $e');
    }
  }
  if (all.length > maxR) return all.sublist(0, maxR);
  return all;
}

Future<String> buildWebSearchContext(String query) async {
  final results = await combinedSearch(query, randomSearchCount());
  if (results.isEmpty) {
    return '\n\n【网页搜索失败: 未获得有效结果。请用已有知识回答，并向用户明示未能通过网页搜索获取最新信息。】';
  }
  final sb = StringBuffer();
  sb.write('\n\n【以下是实时网页搜索结果。请基于这些信息回答，引用时注明出处】\n');
  for (var i = 0; i < results.length; i++) {
    final r = results[i];
    sb.write('${i + 1}. [${r.source}] ${r.title}\n');
    sb.write('   链接: ${r.url}\n');
    if (r.snippet.isNotEmpty) sb.write('   摘要：${r.snippet}\n');
  }
  sb.write('\n【検索終了】');
  return sb.toString();
}

// ------------------------------------------------------------
// 文件内容注入
// ------------------------------------------------------------
const int DS_MAX_TEXT_EXTRACT = 200 * 1024;

const Set<String> _textExts = {
  '.txt',
  '.md',
  '.markdown',
  '.json',
  '.xml',
  '.yaml',
  '.yml',
  '.toml',
  '.ini',
  '.conf',
  '.cfg',
  '.log',
  '.csv',
  '.tsv',
  '.env',
  '.go',
  '.js',
  '.mjs',
  '.cjs',
  '.ts',
  '.tsx',
  '.jsx',
  '.py',
  '.java',
  '.kt',
  '.c',
  '.cpp',
  '.cc',
  '.cxx',
  '.h',
  '.hpp',
  '.cs',
  '.rb',
  '.php',
  '.swift',
  '.rs',
  '.scala',
  '.lua',
  '.pl',
  '.r',
  '.html',
  '.htm',
  '.css',
  '.scss',
  '.sass',
  '.less',
  '.vue',
  '.svelte',
  '.sh',
  '.bash',
  '.zsh',
  '.bat',
  '.ps1',
  '.cmd',
  '.sql',
  '.graphql',
  '.gql',
  '.proto',
  '.dockerfile',
  '.gitignore',
  '.editorconfig',
  '.makefile',
  '.gradle',
  '.properties',
  '.tex',
  '.rst',
  '.srt',
  '.vtt',
  '.ass',
  '.dart',
};

const List<String> _textMimes = [
  'application/json',
  'application/xml',
  'application/javascript',
  'application/x-yaml',
  'application/yaml',
  'application/x-sh',
  'application/x-httpd-php',
  'application/x-python',
  'application/rtf',
];

bool isTextFile(String mimeType, String filename) {
  if (mimeType.startsWith('text/')) return true;
  for (final m in _textMimes) {
    if (mimeType.startsWith(m)) return true;
  }
  final i = filename.lastIndexOf('.');
  final ext = i < 0 ? '' : filename.substring(i).toLowerCase();
  return _textExts.contains(ext);
}

({String? text, String? error}) dsFileToText(String fileID) {
  final meta = getDsFileMeta(fileID);
  if (meta == null) return (text: null, error: '文件不存在');
  final absPath = '$DSFilesBlobDir/${meta.relPath}';
  final f = File(absPath);
  if (!f.existsSync()) return (text: null, error: '文件不存在');
  if (!isTextFile(meta.mimeType, meta.name)) {
    return (text: null, error: '非文本文件，无法直接读取');
  }
  try {
    final total = meta.size;
    final data = dsReadPlainFileBytes(absPath, maxBytes: DS_MAX_TEXT_EXTRACT);
    final text = utf8.decode(data, allowMalformed: true);
    if (total > DS_MAX_TEXT_EXTRACT) {
      return (text: '$text\n\n...[文件内容过长，仅显示前 200KB]', error: null);
    }
    return (text: text, error: null);
  } catch (e) {
    return (text: null, error: '$e');
  }
}

class FileContext {
  final String text;
  final List<String> imageFileIds;
  final List<String> otherFiles;

  /// 音频附件：豆包音频理解模型可直接读取原始音频；
  /// DeepSeek 通道不具备音频理解能力。
  final List<String> audioFileIds;

  /// 视频附件：豆包视频理解模型可直接读取原始视频；
  /// DeepSeek 通道不具备视频理解能力。
  final List<String> videoFileIds;

  const FileContext(
    this.text,
    this.imageFileIds,
    this.otherFiles, {
    this.audioFileIds = const <String>[],
    this.videoFileIds = const <String>[],
  });

  /// 是否携带任何媒体附件（图片 / 音频 / 视频）
  bool get hasMedia =>
      imageFileIds.isNotEmpty ||
      audioFileIds.isNotEmpty ||
      videoFileIds.isNotEmpty;
}

const Set<String> _audioExts = {
  '.mp3',
  '.wav',
  '.m4a',
  '.aac',
  '.ogg',
  '.oga',
  '.opus',
  '.flac',
  '.amr',
  '.webm',
  '.mp4a',
  '.wma',
  '.aiff',
  '.aif',
  '.caf',
  '.mka',
};

const Set<String> _videoExts = {
  '.mp4',
  '.mov',
  '.m4v',
  '.mkv',
  '.avi',
  '.webm',
  '.flv',
  '.wmv',
  '.mpeg',
  '.mpg',
  '.ts',
  '.mts',
  '.m2ts',
  '.3gp',
  '.ogv',
  '.rmvb',
};

bool _extInSet(String name, Set<String> exts) {
  final i = name.lastIndexOf('.');
  if (i < 0) return false;
  return exts.contains(name.substring(i).toLowerCase());
}

/// 该文件是否为音频（按 MIME 优先，其次按扩展名）
bool isAudioFile(String mimeType, String fileName) {
  if (mimeType.toLowerCase().startsWith('audio/')) return true;
  // video/webm 常见于浏览器录音，按音频对待
  if (mimeType.toLowerCase() == 'video/webm' &&
      _extInSet(fileName, _audioExts)) {
    return true;
  }
  return !mimeType.toLowerCase().startsWith('video/') &&
      _extInSet(fileName, _audioExts);
}

/// 该文件是否为视频（按 MIME 优先，其次按扩展名）
bool isVideoFile(String mimeType, String fileName) {
  if (mimeType.toLowerCase().startsWith('video/')) return true;
  if (mimeType.toLowerCase().startsWith('audio/')) return false;
  return _extInSet(fileName, _videoExts);
}

FileContext buildFileContext(List<String> fileIDs) {
  final textChunks = <String>[];
  final otherFiles = <String>[];
  final imageFileIDs = <String>[];
  final audioFileIDs = <String>[];
  final videoFileIDs = <String>[];

  for (var fid in fileIDs) {
    fid = fid.trim();
    if (fid.isEmpty) continue;
    final meta = getDsFileMeta(fid);
    if (meta == null) {
      otherFiles.add('$fid (文件不存在)');
      continue;
    }
    if (meta.mimeType.startsWith('image/')) {
      imageFileIDs.add(fid);
      continue;
    }
    // 音频 / 视频单独分流：豆包对应能力模型可直接理解原始媒体，
    // 不再降级成「只给文件名」而让用户误以为无法识别。
    if (isVideoFile(meta.mimeType, meta.name)) {
      videoFileIDs.add(fid);
      continue;
    }
    if (isAudioFile(meta.mimeType, meta.name)) {
      audioFileIDs.add(fid);
      continue;
    }
    if (isTextFile(meta.mimeType, meta.name)) {
      final r = dsFileToText(fid);
      if (r.error != null) {
        otherFiles.add('${meta.name} (读取失败: ${r.error})');
        continue;
      }
      if ((r.text ?? '').trim().isNotEmpty) {
        textChunks.add('【文件: ${meta.name}】\n${r.text}');
      }
    } else {
      otherFiles.add(meta.name);
    }
  }

  final sb = StringBuffer();
  if (textChunks.isNotEmpty) {
    sb.write('以下是用户上传的文件内容:\n\n');
    sb.write(textChunks.join('\n\n───────────────\n\n'));
  }
  if (otherFiles.isNotEmpty) {
    if (sb.isNotEmpty) sb.write('\n\n');
    sb.write('【用户上传的以下文件，是无法自动提取内容的格式'
        '（仅参照文件名）】:');
    sb.write(otherFiles.join('、'));
  }
  return FileContext(
    sb.toString(),
    imageFileIDs,
    otherFiles,
    audioFileIds: audioFileIDs,
    videoFileIds: videoFileIDs,
  );
}

// ------------------------------------------------------------
// 小说模式
// ------------------------------------------------------------
String buildNovelSystemPrompt() =>
    '''你是一位经验丰富的长篇网络小说作家，擅长写结构扎实、情节跌宕、人物立体、看点丰富的长篇小说。文笔流畅自然，对话生动，能精准把控故事节奏。\n\n创作要求:\n1. 用用户使用的语言写作。若有指定则遵循该语言，任何语言都可以\n2. 从正文直接开始，不写标题、作者、前言、后记、总结、铺垫\n3. 章节划分清晰，每章以"第X章"或明确的小标题开头\n4. 突出人物性格，使对话契合人设\n5. 情节一贯，起承转合完整，不冗长也不跳跃\n6. 重视细节描写与情景营造，但不过度堆砌\n7. 完全遵循用户设定的主题、标签、分类、故事设定\n8. 不中途结束，尽可能写满指定字数''';

String buildNovelBasePrompt(
    String theme, String tags, String genre, String story, int targetChars) {
  final sb = StringBuffer();
  sb.write('【小说创作任务】\n');
  sb.write('分類: $genre\n');
  if (theme.isNotEmpty) sb.write('主题: $theme\n');
  if (tags.isNotEmpty) sb.write('标签: $tags\n');
  if (story.isNotEmpty) sb.write('故事设定: $story\n');
  sb.write('目標総文字数: $targetChars 文字\n');
  sb.write('\n请开始创作这部小说。');
  return sb.toString();
}

String trimNovelOverlap(String newChunk, String prevEnd) {
  if (prevEnd.isEmpty || newChunk.isEmpty) return newChunk;
  final prevRunes = prevEnd.runes.toList();
  final newRunes = newChunk.runes.toList();
  if (prevRunes.length < 20 || newRunes.length < 20) return newChunk;
  var maxCheck = 200;
  if (prevRunes.length < maxCheck) maxCheck = prevRunes.length;
  if (newRunes.length < maxCheck) maxCheck = newRunes.length;
  for (var n = maxCheck; n >= 12; n--) {
    if (prevRunes.length < n || newRunes.length < n) continue;
    final suffix =
        String.fromCharCodes(prevRunes.sublist(prevRunes.length - n));
    if (newChunk.startsWith(suffix)) {
      return String.fromCharCodes(newRunes.sublist(n)).trim();
    }
  }
  return newChunk;
}

String _novelSegmentPrompt(int round, int thisChunk, String basePrompt) {
  if (round == 0) {
    return '''$basePrompt\n\n【本次任务】\n请直接开始创作这部小说。本次输出约 $thisChunk 字。\n要求:\n- 从正文直接开始，不写前言、标题、作者信息\n- 章节划分清晰，展开紧凑\n- 尽可能写满本次要求的字数''';
  }
  return '''【小说创作续写 · 第 ${round + 1} 段】\n本次续写目标: 约 $thisChunk 字。\n\n【续写要求】\n1. 严格承接前面的正文，不重复已写内容\n2. 不写前言、总结、过渡语、说明\n3. 保持情节一贯、人物一贯、伏笔呼应、章节清晰\n4. 尽可能写满本次要求的字数''';
}

String _novelContext(String full) {
  const maxCtxRunes = 8000;
  const headKeepRunes = 2000;
  final runes = full.runes.toList();
  if (runes.length <= maxCtxRunes) return full;
  final head = String.fromCharCodes(runes.sublist(0, headKeepRunes));
  final tailStart = runes.length - (maxCtxRunes - headKeepRunes);
  final tail = String.fromCharCodes(runes.sublist(tailStart));
  return '$head\n\n……（中间省略，已写部分）……\n\n$tail';
}

Future<({String text, String? error})> generateNovel(
    String apiKey,
    String model,
    String basePrompt,
    int targetChars,
    DsUsageAcc? usageAcc) async {
  final full = StringBuffer();
  var lastPart = '';
  String? lastErr;
  final sysPrompt = buildNovelSystemPrompt();

  for (var round = 0; round < DS_NOVEL_MAX_ROUNDS; round++) {
    final currentChars = runeLen(full.toString());
    if (currentChars >= targetChars) break;
    final remaining = targetChars - currentChars;
    var thisChunk = DS_NOVEL_CHUNK_CHARS;
    if (thisChunk > remaining) thisChunk = remaining;

    final userPrompt = _novelSegmentPrompt(round, thisChunk, basePrompt);
    final msgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': sysPrompt},
    ];
    if (round > 0) {
      msgs.add({'role': 'user', 'content': basePrompt});
      msgs.add(
          {'role': 'assistant', 'content': _novelContext(full.toString())});
    }
    msgs.add({'role': 'user', 'content': userPrompt});

    logp('📖 小説生成 ${round + 1} 段目 · 進捗 $currentChars / $targetChars 文字');

    String reply;
    try {
      final r = await callDsChatAPI(
          apiKey, model, msgs, DS_MAX_OUTPUT_TOKENS, 0.9, usageAcc);
      reply = r.content.trim();
    } catch (e) {
      lastErr = '$e';
      logp('⚠️ 小说第 ${round + 1} 段生成失败: $e');
      if (full.isNotEmpty) break;
      return (text: '', error: lastErr);
    }
    if (reply.isEmpty) {
      logp('⚠️ 小说第 ${round + 1} 段返回为空，中止生成');
      break;
    }
    reply = trimNovelOverlap(reply, lastPart);
    if (full.isNotEmpty) full.write('\n\n');
    full.write(reply);
    final fullText = full.toString();
    final runes = fullText.runes.toList();
    if (runes.length > 10000000) {
      lastPart = String.fromCharCodes(runes.sublist(runes.length - 10000000));
    } else {
      lastPart = fullText;
    }
  }
  final result = full.toString().trim();
  if (result.isEmpty && lastErr != null) return (text: '', error: lastErr);
  return (text: result, error: null);
}

Future<({String text, String? error})> generateNovelStream(
  String apiKey,
  String model,
  String basePrompt,
  int targetChars,
  Future<void> Function(String delta)? onChunk,
  Future<void> Function(int segIdx)? onSegment,
  void Function(int done, int target)? onProgress,
  DsUsageAcc? usageAcc,
) async {
  final full = StringBuffer();
  var lastPart = '';
  String? lastErr;
  final sysPrompt = buildNovelSystemPrompt();
  const segMaxRetry = 3;

  for (var round = 0; round < DS_NOVEL_MAX_ROUNDS; round++) {
    final currentChars = runeLen(full.toString());
    if (currentChars >= targetChars) break;
    final remaining = targetChars - currentChars;
    var thisChunk = DS_NOVEL_CHUNK_CHARS;
    if (thisChunk > remaining) thisChunk = remaining;

    onProgress?.call(currentChars, targetChars);
    final userPrompt = _novelSegmentPrompt(round, thisChunk, basePrompt);
    final msgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': sysPrompt},
    ];
    if (round > 0) {
      msgs.add({'role': 'user', 'content': basePrompt});
      msgs.add(
          {'role': 'assistant', 'content': _novelContext(full.toString())});
    }
    msgs.add({'role': 'user', 'content': userPrompt});

    logp('📖 小説生成 ${round + 1} 段目 · 進捗 $currentChars / $targetChars 文字');
    await onSegment?.call(round + 1);

    final segBuf = StringBuffer();
    String? segErr;
    for (var attempt = 0; attempt < segMaxRetry; attempt++) {
      segBuf.clear();
      try {
        await callDsChatAPIStream(
            apiKey, model, msgs, DS_MAX_OUTPUT_TOKENS, 0.9, null, (s) {
          segBuf.write(s);
          onChunk?.call(s);
        }, usageAcc);
        segErr = null;
        if (segBuf.toString().trim().isNotEmpty) break;
      } catch (e) {
        segErr = '$e';
      }
      logp('⚠️ 小说第 ${round + 1} 段第 ${attempt + 1} 次尝试失败: $segErr。3 秒后重试');
      await Future.delayed(const Duration(seconds: 3));
    }
    if (segErr != null) {
      lastErr = segErr;
      logp('❌ 小说第 ${round + 1} 段生成失败（已重试 $segMaxRetry 次）: $segErr');
      if (full.isNotEmpty) break;
      return (text: '', error: segErr);
    }

    var reply = segBuf.toString().trim();
    if (reply.isEmpty) {
      logp('⚠️ 小说第 ${round + 1} 段返回为空，中止生成');
      break;
    }
    reply = trimNovelOverlap(reply, lastPart);
    if (full.isNotEmpty) full.write('\n\n');
    full.write(reply);
    final fullText = full.toString();
    final runes = fullText.runes.toList();
    if (runes.length > 10000000) {
      lastPart = String.fromCharCodes(runes.sublist(runes.length - 10000000));
    } else {
      lastPart = fullText;
    }
  }
  final result = full.toString().trim();
  if (result.isEmpty && lastErr != null) return (text: '', error: lastErr);
  return (text: result, error: null);
}

// ------------------------------------------------------------
// TTS 文本处理
// ------------------------------------------------------------
const String _ttsPunct = '，。！？；：、“”‘’（）【】《》「」『』〈〉〔〕〖〗—–…·～﹏,'
    '.!?;:"\'`()[]{}<>/\\|@#\$%^&*+=~_\n\r\t';

// 保留标点与词中撇号、连字符的语言（拉丁 / 西里尔 / 谚文）。
// 若破坏此处，l'homme / aujourd'hui / peut-être / кто-то 会作为词被破坏，
// 不仅发音，连词的切分与停顿也会变得不自然。
const Set<String> _ttsKeepPunctLangs = {'en', 'fr', 'ru', 'ko'};

/// TTS 预处理。传入 [lang] 时，按该语言的本地化规则清洗。
/// 已有调用（未指定 lang）保持面向日语、中文的原有行为。
String cleanTTSText(String s, [String lang = '']) {
  final l = lang.toLowerCase();
  if (_ttsKeepPunctLangs.contains(l)) return _cleanTTSTextKeepPunct(s, l);
  final sb = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    if (_ttsPunct.contains(ch)) {
      sb.write(' ');
    } else {
      sb.write(ch);
    }
  }
  return sb
      .toString()
      .split(RegExp(r'\s+'))
      .where((e) => e.isNotEmpty)
      .join(' ');
}

/// 面向西文（法 / 俄 / 韩 / 英）的清洗。
/// 保留标点（. , ! ? ; :）与词中的 ' ’ -，只把引号、括号、符号替换为空白。
String _cleanTTSTextKeepPunct(String s, String lang) {
  var t = s;

  // 全角空格、引号、括号替换为"停顿"
  t = t.replaceAll(
      RegExp(
          r'[\u3000"\u201C\u201D\u00AB\u00BB\u300C\u300D\u300E\u300F\uFF08\uFF09()\[\]{}<>\u300A\u300B\u3010\u3011\u3008\u3009\u3014\u3015\u3016\u3017]'),
      ' ');
  t = t.replaceAll(RegExp(r'[#@&+=\\|^\$%/*]'), ' ');

  // 只去掉词首、词尾孤立的 ' ’ -，词中的保留
  t = t.replaceAllMapped(RegExp(r'\S+'), (m) {
    var w = m[0]!;
    w = w.replaceFirst(RegExp(r"^['\u2019\-]+"), '');
    w = w.replaceFirst(RegExp(r"['\u2019\-]+$"), '');
    return w;
  });

  // 破折号、间隔号、省略号作为"停顿"使用
  t = t.replaceAll(RegExp(r'[\u2013\u2014\u2015\u2026\u00B7\u2022]'), ' ');

  // 防止语音串扰：从谚文语音去掉假名，从西里尔语音去掉汉字
  if (lang == 'ko')
    t = t.replaceAll(RegExp(r'[\u3040-\u309F\u30A0-\u30FF]'), ' ');
  if (lang == 'ru') t = t.replaceAll(RegExp(r'[\u4E00-\u9FFF]'), ' ');

  return t.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).join(' ');
}

List<String> splitTextForTTS(String text, int chunkRunes, int hardMax) {
  var cr = chunkRunes <= 0 ? 2500 : chunkRunes;
  var hm = hardMax <= 0 ? 2900 : hardMax;
  if (hm < cr) hm = cr;

  final runes = text.runes.toList();
  final chunks = <String>[];
  var cur = <int>[];

  int isBreak(int r) {
    final ch = String.fromCharCode(r);
    if ('。！？；\n.!?;'.contains(ch)) return 3;
    if ('，,、：:'.contains(ch)) return 2;
    if (' \t'.contains(ch)) return 1;
    return 0;
  }

  void flush() {
    if (cur.isNotEmpty) {
      final s = String.fromCharCodes(cur).trim();
      if (s.isNotEmpty) chunks.add(s);
      cur = <int>[];
    }
  }

  for (var i = 0; i < runes.length; i++) {
    cur.add(runes[i]);
    if (cur.length >= cr) {
      var bestIdx = -1;
      var bestPrio = 0;
      var limit = runes.length;
      final maxLookahead = hm - cr;
      if (i + 1 + maxLookahead < limit) limit = i + 1 + maxLookahead;
      for (var j = i + 1; j < limit; j++) {
        final p = isBreak(runes[j]);
        if (p > bestPrio) {
          bestPrio = p;
          bestIdx = j;
        }
        if (p == 3) break;
      }
      if (bestIdx >= 0) {
        for (var k = i + 1; k <= bestIdx; k++) {
          cur.add(runes[k]);
        }
        flush();
        i = bestIdx;
        continue;
      }
      if (cur.length >= hm) flush();
    }
  }
  flush();
  return chunks;
}
