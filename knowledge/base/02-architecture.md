# Kewe 架构与数据地图

## 运行形态

- Dart HTTP 服务：`bin/main.dart`，默认端口 `9999`，`DSH_PORT` 可覆盖。
- 账户层：`lib/src/kewe_auth.dart`，Cookie 会话 30 天。
- 账号数据根：`data/users/<userId>/`，不同账号完全隔离。
- 登录后所有旧模块通过 Zone 自动落到账号目录；未登录业务 API 统一 404。

## 聊天数据（最终决定）

- 路径：`data/users/<userId>/deepseek_chat/sessions/*.sts`
- 格式：`#S|id|title|createdAt|updatedAt` + `#M|...`
- 标题、正文、思考链：**明文**存储，便于后端起编辑器直接修改。
- 旧版本 `KWENC1:` 密文在首次登录时自动解密迁移为明文。
- 前端没有消息/思维链编辑 UI；修改聊天只能在后端数据文件中进行。
- 文件附件仍使用 `KEWEFILE1` 分块加密容器，与聊天正文无关。

## 知识库数据库

- 共享规则：`knowledge/skill.md`、`knowledge/base/`。
- 账号数据库：`data/users/<userId>/knowledge/db.json`。
- 每条正文：`data/users/<userId>/knowledge/entries/<id>.md`。
- API：
  - `GET /api/knowledge/status`
  - `GET /api/knowledge/search?q=...&limit=...`
  - `GET /api/knowledge/entry?id=...`
  - `POST /api/knowledge/save` `{title, content, tags, id?}`
  - `POST /api/knowledge/delete` `{id}`
  - `GET /api/knowledge/skill`

## 模型工具

- `knowledge_status`
- `knowledge_search`
- `knowledge_read`
- `knowledge_save`
- `knowledge_delete`

模型在每次聊天请求中会收到知识库能力提示和账号知识索引；需要细节时调用上述工具。

## 手机自动化

- `adb_status` / `adb_connect` / `adb_shell`
- `ocr_screen` / `get_screen_text` / `wait_for_element`
- `batch_tap` / `batch_swipe` / `batch_command`
- 所有动作必须用户明确发起，涉及支付、删除、发消息、权限变更需再次确认。
