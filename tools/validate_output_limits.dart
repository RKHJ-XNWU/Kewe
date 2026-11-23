// 全局输出档位无依赖单元测试。
// 运行：DSH_BASE=/tmp/kewe-limit-test dart run tools/validate_output_limits.dart
import 'dart:io';

import '../lib/src/db_limits.dart';
import '../lib/src/globals.dart';

void expectValue(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  final limitFile = File('$DATA_DIR/output_limit.txt');
  if (limitFile.existsSync()) limitFile.deleteSync();

  expectValue(dbCurrentOutputLimit() == 393216, '默认档位必须为 384K');
  expectValue(DB_ALLOWED_OUTPUT_TOKENS.length == 4, '必须恰好有四个档位');
  expectValue(dbParseOutputLimit('64K') == 65536, '64K 解析失败');
  expectValue(dbParseOutputLimit('131072') == 131072, 'token 字符串解析失败');
  for (final invalid in <dynamic>[null, 0, 32768, 512 * 1024, 'abc', '512K']) {
    expectValue(dbParseOutputLimit(invalid) == null, '非法档位未被拒绝: $invalid');
  }

  final models = <String>[
    'deepseek-flash',
    'deepseek-v4-pro',
    'doubao-seed-2-1-pro-260915',
    'doubao-seed-2-1-lite-260915',
    'my-custom-model',
  ];
  for (final option in DB_ALLOWED_OUTPUT_TOKENS) {
    expectValue(saveDbOutputLimit(option), '档位保存失败: $option');
    expectValue(dbCurrentOutputLimit() == option, '档位持久化读取失败: $option');
    for (final model in models) {
      expectValue(dbForcedMaxOutput(model) == option, '$model 未强制使用 $option');
      expectValue(dbForcedContextWindow(model) == 1048576, '$model 上下文不是 1024K');
    }
    expectValue(dbOutputLimitInfo()['maxOutput'] == option, '能力目录未同步 $option');
  }

  expectValue(!saveDbOutputLimit(777), '非法档位不应保存');
  expectValue(dbCurrentOutputLimit() == 393216, '非法保存后不应改变原档位');
  limitFile.writeAsStringSync('broken\n');
  expectValue(dbCurrentOutputLimit() == 393216, '损坏配置必须回退 384K');
  expectValue(dbCanonicalModelValue('doubao-seed-2-1-pro-260628') ==
      'doubao-seed-2-1-pro-260915', 'Pro 模型别名规范化失败');

  print('PASS: 4 tiers × ${models.length} models, persistence, fallback and invalid-input checks.');
}
