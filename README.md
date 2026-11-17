# Kewe（聚维）· 三维度聚合大模型中枢

Kewe 是一个运行在 Android Termux 环境里的本地大模型中枢。它用 Dart 编写，启动后在本机提供一个 HTTP 服务和一个网页界面，把 DeepSeek、火山方舟（豆包）与 OpenAI 兼容中转站三条大模型通道接在同一个界面里使用。三条通道各自拥有独立的消息流，互不可见。除了普通对话，它还带有文件管理、多模态理解、音频与图片生成、实时语音通话、机器翻译、角色扮演、单词本、论坛、备份恢复等功能。在工具模式下，模型还能通过 ADB 通道操控手机屏幕。

本文档以当前仓库的源码为准编写。旧版 README 描述的是早期 Go 实现，那一版已经被完整改写为 Dart 版本（`pubspec.yaml` 中的版本号为 2.1.0，程序内部版本字符串为 `2.1.0-dart`）。如果你发现本文档与源码不一致，请以源码为准，并欢迎提交修正。

---

## 目录

1. [项目概览](#1-项目概览)
2. [快速开始](#2-快速开始)
3. [目录结构](#3-目录结构)
4. [配置与环境变量](#4-配置与环境变量)
5. [启动、停止与后台运行](#5-启动停止与后台运行)
6. [网页界面使用教程](#6-网页界面使用教程)
7. [DeepSeek 维度](#7-deepseek-维度)
8. [豆包维度](#8-豆包维度)
9. [工具模式与安全闸门](#9-工具模式与安全闸门)
10. [ADB 自动化引擎](#10-adb-自动化引擎)
11. [文件管理](#11-文件管理)
12. [备份与恢复](#12-备份与恢复)
13. [论坛、单词本、角色扮演、公告、峰谷提醒、X 推文](#13-论坛单词本角色扮演公告峰谷提醒x-推文)
14. [计费与用量统计](#14-计费与用量统计)
15. [数据存储与加密](#15-数据存储与加密)
16. [HTTP API 参考](#16-http-api-参考)
17. [辅助脚本：st.py 与 ha.py](#17-辅助脚本stpy-与-hapy)
18. [二次开发指南](#18-二次开发指南)
19. [安全与隐私](#19-安全与隐私)
20. [故障排查](#20-故障排查)
21. [已知限制与维护状态](#21-已知限制与维护状态)
22. [常见问题](#22-常见问题)
23. [附录：命令速查](#23-附录命令速查)

---

## 1. 项目概览

### 1.1 它解决什么问题

大模型服务通常各自为政：DeepSeek 擅长推理与长文本，豆包在多模态、语音、图片和视频理解上功能更全。Kewe 把两者放进一个界面，让用户在同一套会话列表、同一套文件库和同一套备份体系里切换使用。

它还解决了几个在手机上使用大模型时常见的麻烦：

- 不依赖云端服务器。程序跑在用户自己的手机上，会话数据保存在本机 `data/` 目录。
- 不需要 root。ADB 自动化通过无线调试的 `127.0.0.1:5555` 通道完成，权限等同 shell（uid=2000）。
- 文件管理支持 64 MB 分片上传，单文件上限在源码中为 5 GB（`DS_MAX_FILE_SIZE`）。模型侧的限制另计，视频理解通道单独为 2 GB。

### 1.2 三维度的含义

项目名中的「三维度」指三条相互独立的模型通道。每个会话属于其中一个维度，切换维度后，界面会换成另一条消息流，不会混用其他维度的消息、API Key 或计费口径。

| 维度标识（源码常量） | 含义 | 模型来源 | 判定方式 |
| :--- | :--- | :--- | :--- |
| `DS_DIM_DS`（值 `ds`） | DeepSeek 维度，默认维度 | DeepSeek 官方接口 | 模型名不属于豆包或中转站目录时使用 |
| `DS_DIM_DB`（值 `db`） | 豆包维度 | 火山方舟（Ark）接口 | 豆包模式开启，或模型属于豆包目录 |
| `DS_DIM_ST`（值 `st`） | 中转站维度，又称 ST 维度 | 任意 OpenAI 兼容的中转站，默认端点 `https://sta1n.ai/v1` | 模型属于中转站预置模型或用户自定义中转站模型 |

这三个标识是 Dart 常量（定义于 `sessions.dart`），不是环境变量。它们会写入会话文件的第 9 个字段，因此同一个会话里三条消息流可以各自保存、各自读取。

维度的判定顺序（见 `chat_send.dart` 的维度函数）：请求体里显式传入的 `dim` 优先；未传入时，若模型属于中转站目录，判为 `st`；其余情况按豆包或 DeepSeek 的模型目录判断。

> 说明：中转站维度是在源码中后加入的。旧版文档把 Kewe 描述为「DeepSeek 与豆包」双维度，那一描述已经过时。

### 1.3 主要能力一览

| 类别 | 能力 | 对应源码 |
| :--- | :--- | :--- |
| 对话 | 流式输出、深度思考（reasoning）、会话搜索、跨会话引用 | `chat_send.dart`、`chat_handlers.dart`、`search.dart`、`session_ref.dart` |
| 多模态 | 图片理解、音频理解、视频理解（大视频通道，最大 2 GB） | `doubao.dart`、`doubao_video_ark.dart` |
| 生成 | AI 生图、图片编辑、音频生成、播客生成（SSE 流） | `doubao.dart`、`chat_send.dart` |
| 语音 | 端到端实时语音通话（Seeduplex，WebSocket）、Edge TTS、语音识别 | `doubao_realtime.dart`、`tts_edge.dart`、`tts_drm.dart` |
| 翻译 | 火山机器翻译大模型、本地术语表 | `doubao_translate.dart` |
| 工具 | DeepSeek 工具模式、豆包专属工具模式、ADB 屏幕操控 | `tools.dart`、`doubao_tools.dart`、`tool_gate.dart` |
| 文件 | 分片上传（64 MB 分片）、下载、元数据管理 | `files.dart` |
| 数据 | 加密存储（AES-256-GCM）、备份打包（tar.gz）、还原 | `ds_crypto.dart`、`aes_gcm.dart`、`backup.dart` |
| 社区 | 论坛、日语单词本、角色扮演（Cosplay）、公告 | `forum.dart`、`vocab.dart`、`cosplay.dart`、`announcements.dart` |
| 计费 | 按真实 token 用量计算人民币费用、峰谷时段提醒 | `token_cost.dart`、`ds_usage.dart`、`peakvalley.dart` |
| 其他 | X（推特）推文抓取、虚拟屏幕、开发者提示词注入 | `xtweet.dart`、`virtual_display.dart`、`devtools.dart` |

### 1.4 技术栈

- 语言：Dart SDK `>=3.0.0 <4.0.0`
- 第三方依赖：无。`pubspec.yaml` 中 `dependencies` 为空。HTTP 服务基于 `dart:io`，AES-256-GCM、SHA-256、HMAC、tar.gz 都在仓库内用纯 Dart 实现（`aes_gcm.dart`、`sha256.dart`）。
- 前端：原生 HTML、CSS 和 JavaScript，由 `index.html` 与一组 `*.js`、`*.css` 文件组成，没有构建步骤。
- 自动化：Python 3（`auto.py`、`doubao_auto.py`、`st.py`、`ha.py`）与 Bash（`adb_up.sh`）。

### 1.5 运行环境要求

| 项目 | 要求 |
| :--- | :--- |
| 设备 | 安卓手机或平板，系统版本需支持 Termux 与无线调试 |
| 终端 | Termux（推荐，最新版从 F-Droid 或 GitHub 获取） |
| Dart | Termux 中可用的 Dart SDK，版本 3.0 及以上 |
| Python | Python 3.8 及以上（自动化脚本使用标准库） |
| ADB | Termux 中的 `android-tools` 包，用于连接本机 `127.0.0.1:5555` |
| 网络 | 能访问 DeepSeek 与火山方舟的 API 地址 |
| API Key | DeepSeek Key 与/或火山方舟 Key，视使用的维度而定 |

---

## 2. 快速开始

下面的步骤假设你从零开始，在 Termux 中跑通服务。每一步都给出了校验命令，确认成功后再进入下一步。

### 2.1 更新 Termux 并安装基础工具

```bash
pkg update -y && pkg upgrade -y
pkg install -y git python dart android-tools
```

校验：

```bash
dart --version        # 应输出 Dart SDK 版本，3.0 及以上
python3 --version     # 应输出 Python 3.x
adb version           # 应输出 Android Debug Bridge 版本信息
```

### 2.2 获取代码

如果仓库已经在手机上，直接进入目录即可。否则克隆：

```bash
cd ~
git clone https://github.com/RKHJ-XNWU/Kewe && mv Kewe kewe
cd kewe
```

校验：

```bash
git log --oneline -n 3    # 能看到最近的提交记录
ls bin/main.dart lib/src  # 能看到入口文件与源码目录
```

### 2.3 启动服务（JIT 方式，最省事）

不需要编译，直接用 `dart run` 启动：

```bash
cd ~/kewe
dart run bin/main.dart
```

看到类似下面的日志，说明服务已经监听：

```
✅ サーバーが起動しました。http://localhost:9999/ でアクセスできます
```

> 日志中的启动提示目前仍是日语，这是源码中已有的文案，并非配置问题。

### 2.4 编译为原生可执行文件（AOT，推荐长期使用）

AOT 编译后启动更快，内存占用更低：

```bash
cd ~/kewe
dart compile exe bin/main.dart -o app
./app
```

校验：

```bash
ls -l app                 # 应看到一个可执行文件
file app                  # 在仓库里的 app 为 ARM aarch64 的 ELF 文件
```

`app` 已列入 `.gitignore`，不会被误提交。

### 2.5 打开界面

在手机浏览器中访问：

```
http://localhost:9999/
```

如果你改过端口，把 `9999` 换成对应端口。页面由根目录的 `index.html` 提供，服务端对未知路径会回退到 `index.html`。

### 2.6 填入 API Key

进入界面后，按所选维度在设置里填入 Key：

- DeepSeek 维度：填 DeepSeek 官方 API Key。
- 豆包维度：填火山方舟 API Key。若要使用语音通话，还要填写「全双工 Key」。

Key 保存后会加密写入 `data/` 目录。具体流程见 [第 15 章](#15-数据存储与加密)。

### 2.7 首次跑通检查清单

按顺序勾选，全部通过即表示基础环境可用：

1. `dart run bin/main.dart` 能启动且没有异常退出。
2. 浏览器打开 `http://localhost:9999/` 能看到界面。
3. 在 DeepSeek 维度发送一句「你好」，能收到流式回复。
4. 在会话列表中能看到刚才的会话。
5. 关闭并重新打开应用后，历史会话仍然存在（说明 `data/` 持久化正常）。

校验第 3 步可以用命令行直接测试接口（需已配置 Key）：

```bash
curl -s http://localhost:9999/api/ds-chat/config | head -c 500
```

返回 JSON 即说明路由正常。

---

## 3. 目录结构

### 3.1 顶层布局

```
kewe/
├── bin/
│   └── main.dart              程序入口：目录初始化、路由注册、HTTP 监听
├── lib/src/                   后端全部业务模块（约 29,000 行 Dart）
├── i18n/                      多语言词典与提示词
│   ├── i18n.js
│   ├── ai-prompts.js
│   └── locales/               zh / ja / en / ko / fr / ru 各一份，另有 *-extra.js
├── index.html                 网页界面入口
├── deepseek-chat.js / .css    DeepSeek 聊天界面主逻辑与样式
├── dsc-*.js / dsc-*.css       聊天界面的各类插件（豆包、论坛、单词本、滑动、换行等）
├── ds-*.js / ds-*.css         文件管理、开发者工具等界面模块
├── peakvalley.js / .css       峰谷提醒界面
├── tex-chtml-full-speech.js   第三方公式渲染脚本（约 2 MB，属于打包产物，请勿手动修改）
├── auto.py                    ADB 通用自动化引擎
├── doubao_auto.py             豆包专属自动化引擎（结构化输出、原子计划）
├── adb_up.sh                  ADB 通道拉起脚本
├── st.py                      一键编译、启动、后台守护、服务注册
├── ha.py                      聊天记录思考链折叠工具
├── pubspec.yaml               Dart 包描述（无第三方依赖）
├── pubspec.lock               Dart 锁文件（空，因为没有依赖）
├── .gitignore                 忽略规则（密钥、data、app、缓存等）
├── kewe.png                   项目图标（index.html 引用）
├── sw.png                     界面脚本 deepseek-chat.js 引用的图片
├── README.md                  本文档
├── app                        AOT 编译产物（可选，由 dart compile exe 生成）
├── data/                      运行时数据目录（自动创建，不提交）
└── .backup_tmp/               备份与还原的临时目录（自动创建，不提交）
```

### 3.2 bin 与 lib 的分工

`bin/main.dart` 只做三件事：

1. 调用各模块的 `init*Dir()`，确保数据目录存在。
2. 注册全部 HTTP 路由（`_register(path, handler)`）。
3. 启动 `HttpServer`，把每个请求分派给对应 handler。

所有真正的逻辑都在 `lib/src/` 中，按功能拆分，互相通过普通函数调用，没有依赖注入框架。

### 3.3 lib/src 模块速览

下表按功能域分组，列出每个文件的职责。详细接口见 [第 16 章](#16-http-api-参考)。

| 域 | 文件 | 职责 |
| :--- | :--- | :--- |
| 基础 | `globals.dart` | 路径常量、环境变量读取、文本转义、时间格式、日志 |
| 基础 | `httpsrv.dart` | 静态资源、CORS、JSON 响应、请求体读取、日志中间件 |
| 基础 | `net.dart` | 共享 HttpClient，连接池复用，自动探测系统代理 |
| 基础 | `sha256.dart`、`aes_gcm.dart` | 纯 Dart 的摘要与对称加密实现 |
| 密钥 | `ds_crypto.dart` | 主密钥管理、AES-256-GCM 加解密、配置读写 |
| DeepSeek | `deepseek_api.dart` | DeepSeek 官方 API 调用层，流式解析 |
| DeepSeek | `chat_handlers.dart` | 会话、消息、配置等基础接口 |
| DeepSeek | `chat_send.dart` | 发送消息、SSE 流式输出、小说模式、续写、中止保存 |
| DeepSeek | `sessions.dart` | 会话与消息的 `.sts` 单文件存储 |
| DeepSeek | `model_router.dart` | 模型自动路由（含图片时切到视觉模型） |
| DeepSeek | `session_ref.dart` | 跨会话引用（@ 其他会话）的解析与快照注入 |
| DeepSeek | `search.dart` | 会话全文搜索，内存缓存与游标分页 |
| DeepSeek | `ds_usage.dart`、`token_cost.dart` | 真实用量记录与人民币计费 |
| DeepSeek | `tools.dart` | 工具模式 schema 与执行器（约 3,000 行） |
| DeepSeek | `tool_gate.dart` | 工具模式统一闸门与显式授权通道 |
| 豆包 | `doubao.dart` | 火山方舟接入：文本、图片、音频、播客、ASR、视觉、会话 |
| 豆包 | `doubao_video_ark.dart` | 大视频理解通道（分片、最大 2 GB） |
| 豆包 | `doubao_realtime.dart` | 端到端实时语音（Seeduplex）与 RTC 任务编排 |
| 豆包 | `doubao_thinking.dart` | 深度思考输出整理 |
| 豆包 | `doubao_tools.dart` | 豆包专属工具模式（按模型档位裁剪工具集） |
| 豆包 | `doubao_translate.dart` | 机器翻译与本地术语表 |
| 豆包 | `doubao_wiki.dart` | 联网内容插件（抖音百科等信源） |
| 豆包 | `doubao_intent.dart` | 已停用的意图识别模块，源码头部标注 DISABLED，保留以便回溯 |
| 语音 | `tts_edge.dart`、`tts_drm.dart` | Microsoft Edge TTS 的 WebSocket 合成与 Sec-MS-GEC v2 签名 |
| 文件 | `files.dart` | 分片上传、下载、列表、删除、元数据 |
| 备份 | `backup.dart` | tar.gz 打包下载、multipart 上传解压还原 |
| 社区 | `forum.dart` | 论坛帖子展示与发帖 |
| 社区 | `vocab.dart` | 日语单词本，首字分片存储，256 个图片分桶 |
| 社区 | `cosplay.dart` | 角色扮演（角色库的增删改查与切换） |
| 社区 | `announcements.dart` | 公告的发布与激活 |
| 社区 | `peakvalley.dart` | DeepSeek 峰谷时段提醒与后台调度循环 |
| 中转 | `relay.dart` | OpenAI 兼容中转站接入（配置与模型列表） |
| 显示 | `displaymodels.dart` | 自定义显示模型的存储 |
| 开发者 | `devtools.dart` | 注入 system 角色提示词 |
| 其他 | `xtweet.dart` | X（推特）推文抓取，多后端并发竞速 |
| 其他 | `virtual_display.dart` | 虚拟屏幕（副屏）创建与操作 |

### 3.4 运行时目录（data 与 .backup_tmp）

程序启动时会自动创建数据目录。路径由 `BASE_DIR` 决定，默认为 `/data/data/com.termux/files/home/kewe`，可用环境变量 `DSH_BASE` 覆盖。`DATA_DIR` 为 `BASE_DIR/data`。

```
data/
├── deepseek_chat/             DeepSeek 维度的会话与配置
│   ├── sessions/              每个会话一个 .sts 文件
│   ├── ds_chat_config.sts     DeepSeek 配置（API Key 等敏感字段加密）
│   ├── ds_master.key          主密钥（hex 编码，权限 600）
│   └── devtools/              开发者注入提示词
├── ds_files/                  文件管理：meta/、blob/、chunks/
├── dispost/                   论坛帖子（forum.dart）
├── vocab/                     日语单词本：words/ 与 images/（按首字分桶）
├── cosplay/                   角色扮演角色库
├── announcements/             公告
├── displaymodels/             自定义显示模型
├── peakvalley/                峰谷提醒配置
├── relay/                     中转站配置（relay_config.sts）
└── voice/                     豆包语音音色等
.backup_tmp/                   备份与还原的临时目录
```

> 注意：`data/` 与 `.backup_tmp/` 都已写入 `.gitignore`。`data/` 中包含你的会话内容、文件元数据和主密钥，不要把它们提交到公开仓库。

### 3.5 .gitignore 说明

`.gitignore` 做了以下保护：

- 密钥与凭证：`*.key`、`*.keys`、`.main`、`.mians`、`.env`、`.env.*`（保留 `.env.example`）。
- 二进制：仅根目录的 `app`。
- 数据：任意层级的 `data/`。
- 临时：`.backup_tmp/`、`tmp/`、`temp/`、`.cache/`、`*.tmp`。
- 工具链：`.dart_tool/`、`build/`、`.packages`、`pubspec.lock`。
- Python 缓存与虚拟环境、日志、编辑器目录、系统垃圾文件。

提交前建议运行 `git status` 检查，确认没有 `data/`、`.env` 或 `app` 出现在待提交列表里。

---

## 4. 配置与环境变量

Kewe 的配置分为三层，优先级从高到低依次是：进程环境变量、`.env` 文件、界面里保存的配置（落盘到 `data/`）。

### 4.1 .env 文件

程序启动时会依次查找以下两个位置的 `.env`，找到第一个存在的文件就停止查找：

1. `$BASE_DIR/.env`（默认 `/data/data/com.termux/files/home/kewe/.env`）
2. 当前工作目录下的 `.env`

解析规则（见 `bin/main.dart` 中的 `parseDotEnvFile`）：

- 空行与以 `#` 开头的行会被忽略。
- 支持 `export KEY=VALUE` 写法。
- 值两端的单引号或双引号会被去掉。
- 如果同名环境变量已经存在于进程环境中，`.env` 中的值会被忽略。

示例：

```bash
# ~/kewe/.env
DSH_PORT=9999
DSH_BASE=/data/data/com.termux/files/home/kewe
DS_MASTER_KEY=替换为64位十六进制字符串
PROXY=http://127.0.0.1:7890
```

> `.env` 已写入 `.gitignore`。如果你要保存模板，请另存为 `.env.example` 并只放占位符。

### 4.2 已识别的环境变量

下表列出源码中通过 `getEnv` 或 `Platform.environment` 直接读取的变量。

| 变量 | 默认值 | 说明 | 位置 |
| :--- | :--- | :--- | :--- |
| `DSH_PORT` | `9999` | HTTP 服务监听端口，监听地址为 `0.0.0.0` | `globals.dart` |
| `DSH_BASE` | `/data/data/com.termux/files/home/kewe` | 项目根目录，`data/` 与 `.backup_tmp/` 都建在它下面 | `globals.dart` |
| `DSH_DEBUG` | 未设置 | 设为 `1` 时，未捕获异常会输出完整堆栈 | `bin/main.dart` |
| `DS_MASTER_KEY` | 未设置 | 主密钥，64 位十六进制（即 32 字节）。设置后优先于密钥文件 | `ds_crypto.dart` |
| `DS_WORKSPACE` | 未设置 | 工具模式下文件操作的工作区根目录，未设置时回退到 `HOME` | `tools.dart` |
| `PROXY` / `SOCKS5_PROXY` / `ALL_PROXY` / `HTTPS_PROXY` / `HTTP_PROXY`（含小写形式） | 未设置 | 出站代理，按此顺序探测，第一个有效值生效。也可在 `$BASE_DIR/proxy.conf` 或当前目录的 `proxy.conf` 中配置 | `net.dart` |
| `HOME` | 系统值 | 工具模式的工作区回退路径 | `tools.dart` |

源码中还有一批以 `DS_` 开头的常量，它们多数是「调参」型配置，并非由 `getEnv` 读取，而是在源码中以 `const` 定义或在代码里通过 `intArgDefault` 等方式读取。例如 `DS_MAX_FILE_SIZE`（5 GB）、`DS_CHUNK_SIZE`（64 MB）、`DS_UPLOAD_SESSION_TTL`（1 小时）、`DS_ORPHAN_GRACE_PERIOD`（30 分钟）。这些值如需修改，请直接改源码并重新编译。

### 4.3 主密钥

主密钥用于 AES-256-GCM 加密 API Key 等敏感配置。获取顺序：

1. 读取环境变量 `DS_MASTER_KEY`。长度不是 64 位十六进制时忽略。
2. 读取 `data/deepseek_chat/ds_master.key`。
3. 两者都没有时，用安全随机数生成 32 字节，写入 `ds_master.key` 并执行 `chmod 600`。

密钥生成后会缓存在进程内存中，本进程内不会重复读取。

> 重要：`ds_master.key` 一旦丢失，已加密的配置将无法解密，只能重新填写 Key。请将它与备份一同保管，但不要公开。

### 4.4 DeepSeek 配置

DeepSeek 配置保存在 `data/deepseek_chat/ds_chat_config.sts`。Key 等字段以 `DSENC1|` 为前缀加密存放。界面里修改配置后，服务端会调用 `saveDsConfig` 重新写入。

可通过接口读取（不会返回明文 Key）：

```bash
curl -s http://localhost:9999/api/ds-chat/config
```

### 4.5 豆包配置

豆包配置位于 `data/doubao/` 之下，由 `doubao.dart` 中的 `getDbConfig` 与保存函数管理。界面中可以分别填写：

- 普通 API Key（用于文本、图片、视频理解等）
- 全双工 Key（仅用于豆包语音通话，见 [第 8 章](#8-豆包维度)）
- 语音、翻译、音频等专属额度所对应的 Key（源码中按功能分组）

保存后若界面不显示刚填写的全双工 Key，这属于前端的显示策略，数据文件中实际已写入。核对方法是检查 `data/doubao/` 下的配置文件是否有更新时间变化。

### 4.6 中转站（relay）配置

中转站配置保存在 `data/relay/relay_config.sts`，格式为明文 JSON。保存时源码会执行 `chmod 600`，让文件只对当前用户可读写。中转站的 Key 与 DeepSeek Key、豆包 Key 分开保存，源码不内置任何中转站 Key。

配置字段（来自 `relay.dart` 中的 `RelayConfig`）：

| 字段 | 类型 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `baseUrl` | 字符串 | `https://sta1n.ai/v1` | 中转站 Base URL，须包含 `/v1`。末尾的 `/` 会被自动去掉 |
| `apiKey` | 字符串 | 空 | 中转站 Key，明文保存 |
| `customModels` | 字符串数组 | 空数组 | 用户自定义的中转站模型名 |
| `stream` | 布尔值 | `true` | 是否使用流式输出 |

聊天请求的端点由 `relayChatEndpoint()` 生成，结果为 `<baseUrl>/chat/completions`。例如默认配置下端点是 `https://sta1n.ai/v1/chat/completions`。

> 中转站配置是明文存储。请勿在共享设备或被同步的目录中使用。备份文件中会包含这份 Key，参见 [12.3 节](#123-备份中的敏感信息)。

### 4.7 配置修改的生效方式

| 修改内容 | 是否需要重启 |
| :--- | :--- |
| 界面里保存的 Key、模型、开关 | 不需要，下一次请求即生效 |
| `.env` 中的端口、`DSH_BASE` | 需要重启 |
| `DS_MASTER_KEY` | 需要重启，且已有加密数据需要重新填写 |
| 源码中的常量 | 需要重新编译或重新 `dart run` |

---

## 5. 启动、停止与后台运行

项目提供两种入口：直接使用 Dart 工具链，或使用辅助脚本 `st.py`。两者最终运行的都是 `bin/main.dart`。

### 5.1 三种启动方式对比

| 方式 | 命令 | 启动速度 | 资源占用 | 适用场景 |
| :--- | :--- | :--- | :--- | :--- |
| JIT | `dart run bin/main.dart` | 较慢，每次启动都要编译 | 较高 | 开发调试 |
| AOT | `dart compile exe bin/main.dart -o app && ./app` | 快 | 较低 | 日常使用 |
| 脚本 | `python3 st.py` | 自动选择 AOT 或 JIT | 同上 | 一键使用、后台运行、注册服务 |

`st.py` 会先检查 `app` 是否存在且可执行。存在则直接运行 AOT 产物；否则尝试编译，编译失败时自动回退到 JIT。

### 5.2 前台运行

```bash
cd ~/kewe
python3 st.py
```

日志直接打印在终端。按 `Ctrl+C` 即可停止。

### 5.3 后台运行（守护模式）

```bash
cd ~/kewe
python3 st.py --daemon
```

守护模式会：

1. 使用 `setsid` 把进程从当前终端分离，关闭终端窗口后服务不会退出。
2. 尝试执行 `termux-wake-lock` 防止 CPU 休眠。该命令需要 Termux:API 支持，失败时只记录日志，不影响服务启动。
3. 把日志写入 `data/st.log`（查看方式见下文）。

查看运行状态与日志：

```bash
python3 st.py --status
python3 st.py --logs        # 默认显示最后 50 行
python3 st.py --logs 200    # 显示最后 200 行
```

停止与重启：

```bash
python3 st.py --stop
python3 st.py --restart
```

### 5.4 编译控制

| 参数 | 作用 |
| :--- | :--- |
| `--rebuild` | 强制重新编译 AOT |
| `--skip-build` | 跳过编译，直接运行现有的 `app` |
| `--no-aot` | 不编译，直接用 `dart run` |

示例：

```bash
python3 st.py --rebuild          # 代码改动后重新编译
python3 st.py --skip-build       # 已有 app，直接跑
python3 st.py --no-aot           # 跳过编译，节省时间
```

### 5.5 注册为 termux-services 服务

如果安装了 `termux-services`，可以让服务随 Termux 启动：

```bash
pkg install -y termux-services
python3 st.py --install-service
```

卸载：

```bash
python3 st.py --remove-service
```

服务名为 `kewe`，常用管理命令：

```bash
sv up kewe
sv down kewe
sv status kewe
```

> 服务注册依赖 termux-services 的 runit 环境。注册后如果 `sv status` 报错，请重新打开 Termux 再试。

### 5.6 `--watch` 参数

`st.py --watch` 会监视源码变化并自动重新编译。它适合开发阶段，不建议在日常使用时开启，因为编译会占用大量 CPU 与内存。

### 5.7 停止时需要注意的事

- 服务停止时，正在进行的流式请求会被中断。`ds-chat/abort-save` 接口可以在中断前把已生成的部分内容保存下来。
- 备份与还原过程中不要强制停止，否则可能留下 `.backup_tmp/` 中的半成品文件。
- 长时间的文件分片上传会在服务重启后失效，需要重新上传。`DS_UPLOAD_SESSION_TTL` 默认为 1 小时。

### 5.8 健康检查

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9999/
curl -s http://localhost:9999/api/ds-chat/config | head -c 200
```

返回 `200` 且 JSON 可读，说明服务正常。

---

## 6. 网页界面使用教程

界面由根目录的 `index.html` 加载，核心脚本为 `deepseek-chat.js`。豆包相关功能由 `dsc-doubao*.js` 系列脚本扩展。下面按界面区域说明操作方式。

### 6.1 第一次打开

1. 在浏览器输入 `http://localhost:9999/`。
2. 页面左侧是会话列表，右侧是聊天区域，底部是输入框。
3. 首次使用时，先点击设置按钮，选择维度（DeepSeek 或豆包），填入对应 Key，点击保存。

### 6.2 切换维度

维度决定这一条会话使用哪套模型与 Key。切换方法：

- 在新建会话时直接选择维度。
- 在已有会话中切换模型时，若模型属于另一维度，界面会提示是否新建会话。

建议：一个会话只用一个维度。跨维度切换会让上下文中的模型风格与计费口径混在一起，排查问题时难以分辨。

### 6.3 发送消息

1. 在底部输入框输入文字。
2. 按发送按钮或回车（具体取决于设置）。
3. 回复以流式方式输出。开启深度思考时，思考内容会作为 reasoning 单独返回并保存。

发送的内容会保存到当前会话的 `.sts` 文件中。

### 6.4 附件

点击输入框旁的附件按钮，可以选择图片、音频、视频或普通文件。

- 图片：在 DeepSeek 维度中，如果模型不支持图片，会由模型路由自动切换到视觉兜底模型（见 [7.6 节](#76-模型路由)）。
- 音频与视频：在豆包维度中使用对应的多模态通道（见 [8.4 节](#84-多模态理解)）。
- 普通文件：通过文件管理上传（见 [第 11 章](#11-文件管理)），消息中会附带文件 ID。

### 6.5 会话操作

| 操作 | 方法 |
| :--- | :--- |
| 新建 | 在会话列表中新建会话（具体按钮位置以界面为准） |
| 删除 | 支持单个删除与批量删除（接口 `/api/ds-chat/sessions/batch-delete`） |
| 搜索 | 使用顶部搜索框，支持全文检索（由 `search.dart` 提供） |
| 跨会话引用 | 输入会话引用符号后选择目标会话，系统会注入其快照（由 `session_ref.dart` 提供） |

### 6.6 重新生成与续写

- 重新生成：在最后一条回复下方点击重试，会用同样的上下文重新请求。
- 续写：当回复因为长度限制中断时，可以点击续写按钮，接口 `/api/ds-chat/continue` 会接着生成。

### 6.7 中止与保存

点击停止按钮会中断当前的流式请求。此时服务端会调用 `/api/ds-chat/abort-save`，把已经生成的部分保存下来，避免内容丢失。

### 6.8 深度思考与思考等级

界面提供思考等级选项。服务端接收 `reasoningLevel` 字段，默认值为 `1`。等级越高，模型思考的时间越长，消耗的 token 也越多。

### 6.9 工具模式开关

工具模式允许模型调用手机上的工具（例如屏幕操作、应用启动、文件读写）。它默认关闭。开启方法、权限闸门与风险见 [第 9 章](#9-工具模式与安全闸门)。

### 6.10 多语言界面

界面文案由 `i18n/` 目录提供，语言代码为 `zh`、`ja`、`en`、`ko`、`ru`、`fr`，默认语言由 `i18n.js` 决定。切换语言后，部分界面文字与内部提示词仍可能保留日语。这是已知情况，详见 [第 21 章](#21-已知限制与维护状态)。

### 6.11 朗读

会话中的回复可以点击朗读。服务端通过 `/api/ds-chat/tts` 调用 Edge TTS（`tts_edge.dart`）合成语音。文本超过 2500 字符（`DS_TTS_CHUNK_RUNES`）时会分段合成，单次请求上限为 1,000,000 字符（`DS_TTS_MAX_RUNES`）。

维护说明：README 旧版（作者问答部分）称语音朗读已永久暂停维护，因为日语符号会误发音。使用前请先测试。

### 6.12 图片生成

豆包维度的生图接口是 `/api/doubao/image`，图片编辑接口是 `/api/doubao/image-edit`。DeepSeek 维度另有 `/api/ds-chat/generate-image`，可用性取决于所配置的模型。

### 6.13 界面快捷操作速查

| 操作 | 说明 |
| :--- | :--- |
| 查看用量 | 用量信息由 `ds_usage.dart` 记录，并按 `token_cost.dart` 的价目换算为人民币 |
| 折叠长代码 | 聊天记录的长代码块可用 `ha.py` 折叠（见 [17.2 节](#172-hapy思考链代码折叠)） |

---

## 7. DeepSeek 维度

DeepSeek 维度直接调用 DeepSeek 官方接口，地址为 `https://api.deepseek.com/chat/completions`（源码常量 `DS_API_URL`）。请求格式是 OpenAI 兼容的 Chat Completions，支持流式（SSE）输出。

### 7.1 可用模型

源码 `model_router.dart` 与 `token_cost.dart` 中出现的 DeepSeek 模型名如下。下表只列出用户可在界面中选择的主要型号：

| 界面名称 / 模型标识 | 类型 | 说明 |
| :--- | :--- | :--- |
| `deepseek-flash` | 文本 + 图片 | 默认模型（`DS_DEFAULT_MODEL`）。模型路由的视觉兜底也指向它 |
| `deepseek-v4.1-flash` | 文本 + 图片 | 与 `deepseek-flash` 同价位，别名之一 |
| `deepseek-v4-flash` | 纯文本 | 旧别名，源码中按纯文本处理，请勿当作视觉模型使用 |
| `deepseek-v4-pro` | 纯文本 | 高价位，适合复杂推理 |
| `deepseek-chat` / `deepseek-reasoner` | 纯文本 | 旧接口名，计价与 v4-pro 相同 |

> 模型名由 DeepSeek 官方目录决定，源码中部分名称带有 `-1017`、`-0813` 等后缀。遇到「模型不存在」的错误时，请先在官方控制台核对当前可用的模型名。

### 7.2 配置步骤

1. 在 DeepSeek 官网控制台创建 API Key。
2. 打开 Kewe 界面，进入设置，选择 DeepSeek 维度。
3. 粘贴 Key 并保存。
4. 发送一条短消息测试。

命令行测试（需先把 `YOUR_KEY` 换成你的 Key，并确保不会留在 shell 历史里）：

```bash
read -rs -p "DeepSeek Key: " DSKEY; echo
curl -s https://api.deepseek.com/chat/completions \
  -H "Authorization: Bearer $DSKEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-flash","messages":[{"role":"user","content":"你好"}]}' | head -c 300
unset DSKEY
```

如果返回 JSON 且包含 `choices`，说明 Key 与网络都正常。这条测试直接访问官方接口，不经过 Kewe，用来区分是 Key 问题还是程序问题。

### 7.3 请求链路

一次发送的大致路径如下：

1. 前端 `POST /api/ds-chat/send`，带上 `sessionId`、`content`、`fileIds`、`reasoningLevel`、工具模式开关等字段。
2. `chat_send.dart` 根据模型名判定维度（DS / DB / ST）。
3. 若消息含图片，`model_router.dart` 决定是否切换到视觉模型。
4. 组装历史消息，超出 `DS_MAX_HISTORY_MSGS`（条数）或 `DS_MAX_HISTORY_CHARS`（字符数）的部分会被截断。
5. 调用 `deepseek_api.dart` 的流式接口，把 `delta` 通过 SSE 推给前端。
6. 完成后写入 `.sts` 会话文件，并记录 `ds_usage.dart` 中的用量。

### 7.4 小说模式

`chat_send.dart` 中包含小说模式（长文分段续写）。相关常量定义在 `deepseek_api.dart` 与 `sessions.dart` 中，包括 `DS_NOVEL_CHUNK_CHARS`（分块字符数）、`DS_NOVEL_MAX_ROUNDS`（最多轮数）、`DS_NOVEL_MIN_CHARS` 与 `DS_NOVEL_MAX_CHARS`（目标长度范围）。这些值是源码常量，不是环境变量，需要修改时请直接改源码。

### 7.5 中止与保存

`POST /api/ds-chat/abort-save` 会在用户中止流式输出后，把已经生成的部分连同 reasoning 写入会话。这样即使中断，也不会丢失已经生成的内容。

### 7.6 模型路由

`model_router.dart` 决定含图片的请求应该使用哪个模型：

- 如果当前模型在内置视觉列表中（如 `deepseek-flash`、`deepseek-vision`），直接使用。
- 如果当前模型在纯文本列表中（如 `deepseek-v4-pro`、`deepseek-chat`），自动切换到默认视觉兜底模型 `deepseek-flash`。
- 第三方模型名包含 `vision`、`vl-`、`gpt-4o`、`gemini`、`claude-3` 等关键字时，按视觉模型处理。

路由规则可以在界面的模型路由设置中补充，配置保存在 `data/deepseek_chat/model_router.sts`。

### 7.7 跨会话引用

`session_ref.dart` 允许在一个会话里引用另一个会话的内容。引用时系统会取出目标会话的快照，并注入到当前上下文中。快照大小受 `DS_REF_MAX_SNAPSHOT_BYTES` 限制，单次最多引用 `DS_REF_MAX_REFERENCES` 个会话。

### 7.8 中转站维度（st）

中转站维度（`DS_DIM_ST`，简称 ST 维度）是 Kewe 的第三条模型通道。它不属于 DeepSeek，也不属于豆包。它通过 OpenAI 兼容的 Chat Completions 协议接入中转站，因此可以接入任何支持这一协议的服务。

源码中 ST 维度预置了五个模型。它们是 `relay.dart` 中的 `relayPresetModels`，与中转站 `/v1/models` 返回的模型 id 完全一致。前端 `deepseek-chat.js` 中的 `RELAY_MODEL_IDS` 也保存了同一份列表。

#### 7.8.1 五个预设模型

| 序号 | 模型 id（完整字符串，含方括号） | 厂商标签 | 计费方式 | 输入（未命中，元/百万 tokens） | 输入（命中，元/百万 tokens） | 输出（元/百万 tokens） |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | `[次][抗截断]gemini-3.8-flash` | Google | 固定价，元/请求 | 不适用 | 不适用 | 不适用（每次请求 0.025 元） |
| 2 | `[Kiro]claude-opus-4-8` | Anthropic | 按 token | 3.5 | 0.35 | 17.5 |
| 3 | `[Kiro]claude-haiku-5-5` | Anthropic | 按 token | 0.21 | 0.021 | 1.05 |
| 4 | `[ASP]gemini-3.8-flash` | Google | 按 token | 0.3 | 0.03 | 1.5 |
| 5 | `[抗截断]gemini-3.8-flash` | Google | 按 token | 0.3 | 0.03 | 1.5 |

这些数值来自 `relay.dart` 的 `relayModelCatalog` 与 `token_cost.dart` 的价格表。它们是源码中的参考单价。中转站实际扣费以中转站后台为准，价格变动后需要同步修改源码。

每个模型的名字都保留了方括号前缀。方括号部分是中转站的分组或标签，发送请求时必须完整使用，不能去掉。`token_cost.dart` 的价格查找会先转为小写再匹配，所以 `[Kiro]` 与 `[kiro]` 会命中同一个价格。

> 关于「专门用于角色扮演」：源码中这五个模型只是 ST 维度的预置目录。`relay.dart` 与前端都没有给它们加角色扮演标记，也没有根据角色扮演开关切换模型。把它们用于角色扮演，是使用上的安排。角色扮演的人设注入发生在系统提示词构建阶段（`chat_send.dart` 中调用 `renderActiveCosplayPersona()`），与模型所在维度无关。因此在 ST 维度下开启角色扮演，人设会和普通对话一样被注入。

#### 7.8.2 如何为角色扮演选择模型

源码没有对五个模型的角色扮演质量做出评价，下面的建议只基于价格与模型名称，不是性能测试结论。

- **长篇连续对话、希望控制成本**：`[Kiro]claude-haiku-5-5` 的输出单价最低（1.05 元/百万 tokens），适合日常角色对话。
- **质量优先、可以接受较高成本**：`[Kiro]claude-opus-4-8` 的输出单价最高（17.5 元/百万 tokens），适合关键剧情或需要细腻文风的场景。
- **希望每次请求的费用固定**：`[次][抗截断]gemini-3.8-flash` 按请求计费，每次 0.025 元，与消耗的 token 数量无关。模型名中的「抗截断」是名称上的说明，源码没有说明它的具体机制。
- **Google 系两款 gemini 模型**：`[ASP]` 与 `[抗截断]` 两个版本的单价完全相同。它们在源码中是两个独立的模型 id，可以自行对比输出效果后选择。

#### 7.8.3 配置步骤

1. 打开网页界面，进入 ST 维度。界面里有一个 ST 切换按钮（`dsc-doubao.js` 中的 `injectStDimButton`），模型选择器中也有「中转站」分组。
2. 第一次使用时，在中转站设置里填入 Base URL 与 Key。默认 Base URL 为 `https://sta1n.ai/v1`，如果你使用其他中转站，请改成该站点的 `/v1` 地址。
3. 保存后，界面会调用 `GET /api/relay/models` 拉取模型列表，包括五个预设模型与你的自定义模型。
4. 在模型选择器中选择一个模型，发送消息。

也可以直接调用接口完成配置。以下示例中的域名与 Key 都是占位符：

```bash
# 查看当前配置（返回中会包含 hasKey 和脱敏后的 maskedKey，不返回明文 Key）
curl -s http://localhost:9999/api/relay/config

# 写入配置：只提交需要修改的字段即可
curl -s -X POST http://localhost:9999/api/relay/config \
  -H 'Content-Type: application/json' \
  -d '{
    "baseUrl": "https://example-relay.invalid/v1",
    "apiKey": "替换为你的中转站Key",
    "stream": true
  }'

# 清空 Key
curl -s -X POST http://localhost:9999/api/relay/config \
  -H 'Content-Type: application/json' \
  -d '{"clearKey": true}'

# 拉取模型列表
curl -s http://localhost:9999/api/relay/models
```

写入规则（来自 `handleRelayConfig`）：

- 请求体里 `apiKey` 为空字符串时，保留原来的 Key，不会被清空。要清空必须传 `clearKey: true`。
- 请求体里没有 `customModels` 字段时，保留原列表。传入数组时，整体替换原列表，空字符串项会被过滤。
- 请求体里没有 `stream` 字段时，保留原设置。
- 保存失败时返回 HTTP 500 与错误信息「配置保存失败」。

#### 7.8.4 一次 ST 请求的完整链路

以下步骤对应 `chat_send.dart` 与 `chat_handlers.dart` 中的逻辑：

1. 请求进入 `/api/ds-chat/send` 或对应的流式接口。
2. 系统先确定维度。显式的 `dim` 字段优先；未指定时，`isRelayModel(model)` 为真则判为 `st`。
3. 若判为 ST 维度，`useRelay` 为真，系统读取 `getRelayConfig()`。
4. 如果中转站 Key 为空，请求直接返回错误，不会改用 DeepSeek 的 Key。源码中的判断是 `relayCfg.apiKey.isEmpty`。
5. Key 存在时，端点替换为 `relayChatEndpoint()`，认证头使用中转站 Key。
6. 请求体按 OpenAI Chat Completions 格式组装，系统提示词中包含工具模式说明（若已开启）与角色扮演人设（若已开启）。
7. 流式输出时，SSE 数据逐条转发给网页界面。中止请求时，`chat_handlers.dart` 会按维度 `st` 处理中止逻辑。
8. 完成后，消息按 `dim = st` 写入当前会话文件。

所有失败都会如实返回错误。源码注释明确写明：不伪造成功，不静默降级到其他维度。

#### 7.8.5 自定义中转站模型

如果中转站提供了预置列表之外的模型，可以把它加入自定义列表。

```bash
curl -s -X POST http://localhost:9999/api/relay/config \
  -H 'Content-Type: application/json' \
  -d '{"customModels": ["示例-模型-A", "示例-模型-B"]}'
```

加入后有三点需要知道：

- 自定义模型会被 `isRelayModel()` 识别为中转站模型，因此会走 ST 维度，不会被当成 DeepSeek 模型。
- 前端会同步自定义列表（`window.__dscSetRelayCustomModels`）。如果界面没有刷新，自定义模型可能暂时显示在错误的分组中，刷新模型列表即可。
- 自定义模型没有内置价格。`/api/relay/models` 返回的 `vendor` 为空，`miss`、`hit`、`out` 都是 0。具体计费口径参见 [14.5 节](#145-未定价模型)。

#### 7.8.6 费用计算示例

ST 维度的单价是全天均价，没有高峰与闲时倍率。`token_cost.dart` 对中转站模型标注了 `flat: true`，所以峰谷时段不影响它。

按 token 计费的模型，费用公式为：

> 费用（元）= 未命中输入 tokens ÷ 1,000,000 × 输入未命中单价 + 命中缓存 tokens ÷ 1,000,000 × 输入命中单价 + 输出 tokens ÷ 1,000,000 × 输出单价

以下是一次请求的算例，假设：未命中输入 1 万 tokens，输出 2 千 tokens，没有缓存命中。

| 模型 | 计算过程 | 合计（元） |
| :--- | :--- | :--- |
| `[Kiro]claude-opus-4-8` | 0.01 × 3.5 + 0.002 × 17.5 | 0.070 |
| `[Kiro]claude-haiku-5-5` | 0.01 × 0.21 + 0.002 × 1.05 | 0.0042 |
| `[ASP]gemini-3.8-flash` | 0.01 × 0.3 + 0.002 × 1.5 | 0.006 |
| `[抗截断]gemini-3.8-flash` | 0.01 × 0.3 + 0.002 × 1.5 | 0.006 |
| `[次][抗截断]gemini-3.8-flash` | 每次请求固定计费 | 0.025 |

如果同样 1 万 tokens 全部命中缓存，`[Kiro]claude-opus-4-8` 的输入部分为 0.01 × 0.35 = 0.0035 元，比未命中便宜约 90%。长对话重复使用同一段上下文时，缓存命中率越高，费用越低。

这些数字是按源码单价手算的结果。实际账单以中转站和 `/api/ds-usage` 中的统计为准。

#### 7.8.7 ST 维度与其他维度的隔离

- 每个会话的消息带有 `dim` 字段。后端在读取消息时按维度过滤（`getDsMessages(sessionID, dim: ...)`）。
- 网页界面切换维度时，会整体换成对应维度的消息流。前端注释中把三条消息流描述为「互不可见」。
- 中转站的 Key、端点与模型列表都独立于 DeepSeek 与豆包，修改其中一个不会影响另外两个。
- 同一个会话文件里可以同时存在三个维度的消息，只要在界面中切换维度即可分别查看。

#### 7.8.8 常见问题

| 现象 | 可能原因 | 处理方法 |
| :--- | :--- | :--- |
| 发送后提示中转站 Key 为空 | 中转站 Key 未填写，或被 `clearKey` 清空 | 调用 `GET /api/relay/config` 查看 `hasKey`，重新写入 Key |
| 模型列表里没有五个预设模型 | 前端未刷新，或后端配置接口异常 | 调用 `GET /api/relay/models`，确认返回的 `models` 中包含预设项 |
| 自定义模型被当作 DeepSeek 发送 | 前端自定义列表未同步 | 刷新页面或重新拉取模型列表 |
| 请求返回上游错误 | Key 无效、模型名拼写错误、余额不足或中转站限流 | 原样查看错误内容，核对模型 id 是否包含完整方括号前缀 |
| 端点地址不对 | Base URL 漏写 `/v1` | 修改为 `https://<域名>/v1`，系统会自动拼接 `/chat/completions` |

### 7.9 搜索

`search.dart` 提供会话全文检索。它把会话内容缓存在内存中，支持游标分页。接口是 `GET /api/ds-chat/search`。注意：缓存在服务重启后会重建，首次搜索较慢属于正常现象。

### 7.10 翻译

`POST /api/ds-chat/translate` 用当前 DeepSeek 模型做文本翻译。对于机器翻译专用通道，请使用豆包维度的 `/api/doubao/translate`，见 [8.8 节](#88-机器翻译)。

---

## 8. 豆包维度

豆包维度通过火山方舟（Ark）与火山引擎语音服务调用豆包模型。它覆盖文本、图片、视频、音频生成、播客、语音识别、实时语音与机器翻译，所有能力都由 `dbModelCatalog`（`doubao.dart`）统一登记。

### 8.1 密钥类型

豆包相关功能需要的密钥不止一种，请先弄清楚：

| 密钥 | 用途 | 在界面中的位置 |
| :--- | :--- | :--- |
| 方舟 API Key | 文本、图片、视觉、视频生成与理解 | 豆包配置的主 Key |
| 全双工 Key | 端到端实时语音通话（Seeduplex） | 豆包配置中的「全双工」项，需往下滚动才能看到 |
| 语音 Key（AppID / Token） | 音频生成、播客、语音识别、机器翻译 | 豆包配置中的语音项 |

若只使用文本对话，只需方舟 API Key。

### 8.2 模型目录

`dbModelCatalog` 登记的模型按用途分类（`cat` 字段）：

| 类别 | 代表模型标识 | 用途 |
| :--- | :--- | :--- |
| `chat` | `doubao-seed-2-1-lite-*`、`doubao-seed-2-1-pro-*` 等 | 文本对话与工具模式 |
| `realtime` | `Doubao_scene_SLM_Doubao_realtime_voice_model` | 实时语音对话 |
| `asr` | `Doubao_Seed_ASR_AUC_2.0`、`Doubao_Seed_ASR_Streaming_2.0` | 录音文件识别与流式识别 |
| `podcast` | `Doubao_scene_SLM_Doubao_Podcast_model` | 双人播客生成 |
| `tts` | `SeedAudio1.0` | 音声生成（端到端，并非传统 TTS） |
| `image` | `doubao-seedream-4-5-*`、`doubao-seedream-5-0-*` | AI 生图 |
| `imageedit` | `doubao-seededit-3-0-i2i-*` | 图片编辑 |
| `video` | `doubao-seedance-2-*` | 视频生成 |

> 模型标识中的日期后缀会随官方更新变化。`dbModelCatalog` 是唯一的登记来源，接入新模型时应同时更新它与计价表。

### 8.3 文本与工具模式

文本对话走 `POST /api/doubao/chat`。当工具模式开启时，`doubao_tools.dart` 会按模型档位裁剪可用工具：

| 档位 | 适用模型 | 工具范围 |
| :--- | :--- | :--- |
| `lite` | 名称含 `lite` 或 `mini` | 精简工具集，控制上下文长度 |
| `turbo` | 均衡档 | 中等工具集 |
| `pro` | 名称含 `pro`、`evolving`、`character` | 全量工具 |
| `special` | 名称含 `vision`、`tts`、`asr`、`realtime`、`seeduplex` | 仅感知类工具，无函数调用编排 |
| `none` | 非豆包模型 | 不加载豆包工具 |

建议：工具编排任务使用 pro 档模型，日常聊天使用 lite 档模型，并为两者开设独立会话，避免上下文相互干扰。

### 8.4 多模态理解

| 能力 | 接口 | 说明 |
| :--- | :--- | :--- |
| 图片理解 | `/api/doubao/chat`（带图片） | 没有独立的图片理解路径，图片随对话消息一起发送 |
| 音频理解 | `/api/doubao/analyze-audio` | 对音频做内容理解 |
| 视频理解 | `/api/doubao/video`、`/api/doubao/video/status`、`/api/doubao/video/tasks` | 大视频通道，最大 2 GB |

视频理解的上传路径取决于文件大小：

- 托管存储（Files API）上限 512 MB。
- 对象存储（TOS，`tos-cn-beijing.volces.com`）上限 2 GB。
- 超过 512 MB 的视频会走 TOS 路径。直接把 2 GB 视频转成 base64 放进 JSON 会导致内存溢出，源码中已经避开了这条路线。

视频理解的任务是异步的。提交后用 `/api/doubao/video/status` 查询状态，用 `/api/doubao/video/tasks` 列出历史任务。

### 8.5 生图与图片编辑

生图请求的常用字段（以 `handleDbImage` 读取的字段为准）：

| 字段 | 说明 |
| :--- | :--- |
| `model` | 生图模型，如 `doubao-seedream-5-0-260128` |
| `prompt` | 提示词 |
| `ratio` | 画面比例 |
| `resolution` | 分辨率档位 |
| `style` / `customStyle` | 风格预设或自定义风格 |
| `name` | 生成文件的名称 |

```bash
curl -s -X POST http://localhost:9999/api/doubao/image \
  -H "Content-Type: application/json" \
  -d '{"model":"doubao-seedream-5-0-260128","prompt":"海边的灯塔，清晨，油画风格"}'
```

图片编辑接口为 `/api/doubao/image-edit`，需要提供原图与编辑指令，具体字段以 `handleDbImageEdit` 为准。

### 8.6 音频生成与播客

- 音频生成：`/api/doubao/audio-generate`，模型为 `SeedAudio1.0`。它是端到端的音声生成，适合场景音、广播剧，**不是**传统的文本转语音（TTS）。
- 播客：`/api/doubao/podcast`（一次性返回）与 `/api/doubao/podcast/sse`（SSE 流式返回）。

播客规则：

- 固定双人，发言人标识为 `A` 与 `B`，返回格式为 `{"speaker":"A"|"B","text":"台词"}` 的数组。
- 每句台词不超过 120 字。
- 支持三种生成方式（按主题、按文本素材、按网页信源，具体以界面为准）。

SSE 事件由 `chat_send.dart` 与 `doubao.dart` 转发，前端按事件类型逐段渲染。

### 8.7 语音识别

- 录音文件识别：`/api/doubao/asr`，模型 `Doubao_Seed_ASR_AUC_2.0`。
- 流式识别：模型 `Doubao_Seed_ASR_Streaming_2.0`，用于边说边转写。
- 语音轮次：`/api/doubao/voice/turn`，把一次语音输入作为一轮对话处理。

### 8.8 机器翻译

机器翻译使用火山引擎的机器翻译大模型，接口为 `POST https://openspeech.bytedance.com/api/v3/machine_translation/matx_translate`，本项目的入口是 `/api/doubao/translate`。

术语表：

| 接口 | 作用 |
| :--- | :--- |
| `/api/doubao/glossary/list` | 列出术语表 |
| `/api/doubao/glossary/get` | 获取单条术语 |
| `/api/doubao/glossary/save` | 新增或更新术语 |
| `/api/doubao/glossary/delete` | 删除术语 |

术语表以 `|` 分隔的文本保存在 `data/body_text` 目录，字段为 `term_id|source_term|target_term|source_lang|target_lang`。`source_lang` 与 `target_lang` 留空时表示通用术语。

翻译结果的朗读采用「先下载、再播放」的方式，原因是直接流式播放容易被拦截。这是源码中的设计选择。

### 8.9 实时语音通话（Seeduplex）

端到端实时语音通过 WebSocket 连接火山引擎：

```
wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue
```

本地路径为 `/api/doubao/realtime`（WebSocket 升级），状态查询用 `/api/doubao/realtime/status`。

使用要点：

- 必须填写全双工 Key，否则通话无法建立。
- 通话是端到端的语音模型，直接说话即可，**不支持**在语音通话中让模型顺带调用手机工具。需要做事情时，请切换到 DeepSeek 维度或文本工具模式。
- 通话记录可在界面中查看。音色列表与保存/删除接口位于 `/api/doubao/voice/*`。

### 8.10 RTC 任务

`/api/doubao/rtc/start` 与 `/api/doubao/rtc/stop` 用于创建和结束 RTC AI 音视频互动任务。它是服务端编排，适合需要长连接的场景。

### 8.11 联网内容插件

`doubao_wiki.dart` 接入豆包的联网内容插件，可用信源包括抖音百科（`douyin`）与头条图文（`toutiao`）。该能力通过 `/api/v3/responses` 调用，不属于普通函数调用。

工具模式下，若用户显式选择某个信源，系统会先关闭工具模式，再只开启该信源（见 [9.2 节](#92-闸门原理)）。

### 8.12 豆包计费

豆包的文本、语音、音频、翻译等各类额度分别计算，互不混用。计价表见 [第 14 章](#14-计费与用量统计)。

---

## 9. 工具模式与安全闸门

工具模式让模型可以调用手机上的工具，例如读写文件、启动应用、模拟点击、截图、读取剪贴板等。这是本项目最需要谨慎使用的功能。

### 9.1 工具模式的状态来源

工具模式的开关只以服务端状态为准。前端传来的 `enableTools` 与 `toolModeUI` 只是输入信号，不能单独决定是否执行工具。

具体规则在 `tool_gate.dart` 中实现：

1. 服务端为每个会话保存一个工具模式状态（`_modeBySession`）。
2. 只有在一次正在处理的聊天请求生命周期内（请求租约），工具才可能被放行。
3. 请求结束或租约过期后，任何残留的绑定都不再具备执行资格。
4. 每次执行工具前，必须通过 `DsToolGate.check`。未通过则直接返回拒绝文本，不会进入工具实现，也不会产生副作用。

### 9.2 闸门原理

`tool_gate.dart` 的几个关键入口：

| 方法 | 作用 |
| :--- | :--- |
| `beginRequest` / `endRequest` | 开始与结束一次请求的租约 |
| `syncMode` | 同步会话的工具模式状态 |
| `issueGrant` | 发放一次性授权（用于用户显式点击的插件） |
| `check` | 外层校验，执行前调用 |
| `checkInner` | 内层校验，属于同一次调用的第二层，不消耗授权 |
| `diag` | 输出当前闸门状态，用于排查 |

`dsSafeExecTool` 是两层校验中的外层，`executeDsTool` 是内层。两层属于同一次调用，所以内层必须使用 `checkInner`。否则一次性授权会在外层被消费，内层再判断时就会被拒绝。

### 9.3 工具清单

工具定义由 `buildDsTools()`（`tools.dart`）给出。按功能分组如下：

| 分组 | 代表工具 | 说明 |
| :--- | :--- | :--- |
| 文件 | `list_dir`、`read_file`、`create_file`、`append_file`、`get_file_size`、`download_file` | 文件读写与下载 |
| 网络 | `http_request` | 发起 HTTP 请求 |
| 进程 | `list_processes`、`kill_process`、`execute_command`、`batch_command`、`run_background` | 命令执行与进程管理 |
| 应用 | `start_app`、`current_app`、`is_app_running`、`force_stop_app` | 应用生命周期 |
| 屏幕 | `screenshot`、`ui_dump`、`find_element`、`tap`、`long_press`、`swipe`、`input_text`、`key_event`、`ocr_screen`、`get_screen_text` | 屏幕感知与操作 |
| 批量 | `batch_tap`、`batch_swipe`、`batch_command` | 批量操作 |
| 等待 | `smart_wait`、`wait_for_element`、`wait_seconds` | 等待界面稳定或元素出现 |
| 弹窗 | `dismiss_popup`、`auto_dismiss_dialogs`、`is_popup_present` | 弹窗处理 |
| 系统 | `volume_set`、`brightness`、`wifi_enable`、`battery_status`、`torch`、`camera_photo` 等 | 设备状态与控制 |
| ADB | `adb_status`、`adb_connect`、`adb_shell` | 本机 ADB 通道 |
| Shizuku | `shizuku_status`、`shizuku_start`、`shizuku_auto_setup`、`shizuku_exec`、`shizuku_install_rish` | Shizuku 通道（保留，见下文说明） |

工具清单以源码为准。新增或删除工具后，请同步修改 `doubao_tools.dart` 中的档位配置。

### 9.4 通道说明

手机上的操作有两条底层通道：

- ADB 通道：通过无线调试连接 `127.0.0.1:5555`，权限为 shell（uid=2000）。这是本项目推荐的通道，不需要 root。
- 第二通道（特权 shell 工具）：源码保留了相关工具，但 `tools.dart` 中的常量 `shizukuDisabled` 为 `true`，这些工具当前处于停用状态，调用会被直接拒绝。本项目统一使用 ADB 通道，不依赖任何第二通道。

### 9.5 风险与建议

- 工具模式会让模型在你的手机上执行真实操作。开启前，请确认当前会话的目标是安全的。
- `kill_process`、`force_stop_app`、`uninstall_app`、`shizuku_exec`、`execute_command` 等工具会产生不可逆影响。建议只在可控环境中开启。
- 不要在含有重要数据的设备上让模型自动执行删除类命令。
- 发现模型行为异常时，立即关闭工具模式，并检查 `tool_gate.dart` 的 `diag` 输出。

---

## 10. ADB 自动化引擎

ADB 自动化是工具模式的底座。它通过无线调试的 `127.0.0.1:5555` 连接设备，所有操作都以 shell（uid=2000）身份执行，不需要 root。

### 10.1 工作原理

```
Termux ──(adb client)──> 127.0.0.1:5555 ──(无线调试)──> Android shell（uid=2000）
```

- Termux 中的 `adb` 作为客户端连接本机无线调试端口。
- 无线调试由系统的「开发者选项」开启。
- 通过 `input`、`am`、`pm`、`settings`、`dumpsys`、`uiautomator` 等命令完成点击、输入、启动应用和读取界面。

### 10.2 一次性设置：开启无线调试

1. 打开系统「设置」→「开发者选项」。如果没有该选项，连续点击「版本号」七次开启。
2. 打开「无线调试」。
3. 进入无线调试页面，记下设备使用的端口，并确认连接端口为 `5555`。若系统给出的端口不是 5555，需要先用「使用配对码配对设备」完成配对，并按系统提示的 `adb connect` 地址操作。
4. 保持无线调试开启。

> 不同安卓版本的菜单名称略有差异。以系统实际菜单为准。

### 10.3 拉起通道：adb_up.sh

`adb_up.sh` 做三件事：

1. 检查 adb server 是否在运行，不在则以 `setsid` 启动，使其脱离终端。
2. 执行 `adb connect 127.0.0.1:5555`。
3. 执行 `adb -s 127.0.0.1:5555 shell id`，校验返回值是否含 `uid=2000`。

运行：

```bash
cd ~/kewe
bash adb_up.sh
```

成功输出：

```
✅ 接続済み 127.0.0.1:5555  (uid=2000(shell))
```

失败时脚本返回非零退出码，并提示检查无线调试是否已开启。

### 10.4 auto.py：通用引擎

`auto.py` 是 ADB 通用引擎，既可以命令行使用，也可以被其他 Python 代码导入。

运行方式：

```bash
python3 auto.py -h             # 查看全部子命令
python3 auto.py status         # 检查设备在线与 uid
python3 auto.py current        # 当前前台应用
python3 auto.py shot --ocr     # 截图并 OCR
python3 auto.py tap-text "确定"
python3 auto.py type "你好，世界"
```

子命令按用途分组：

| 分组 | 子命令 |
| :--- | :--- |
| 连接 | `status`、`on`、`off`、`unlock`、`stable` |
| 点击与滑动 | `tap`、`tap-text`、`tap-id`、`long`、`swipe`、`key` |
| 查找与等待 | `dump`、`find`、`wait`、`wait-gone` |
| 弹窗 | `kill-popup`（支持 `--rounds` 与 `--allow`） |
| 应用 | `start`、`stop`、`uninstall`、`installed`、`current` |
| 屏幕 | `shot`（支持 `--path`、`--ocr`）、`notify` |
| 文本 | `type`、`type-into`、`copy`、`cut`、`paste`、`clip-get`、`select-all`、`select-all-keys`、`clear`、`edit-text` |

`auto.py` 内置了掉线重连、失败重试与超时保护。`run()` 函数在设备掉线时会调用 `ensure()` 重新连接，最多重试 3 次。

### 10.5 doubao_auto.py：豆包专用适配版

`doubao_auto.py` 与 `auto.py` 底座相同，但输出为结构化 JSON，并且增加了面向模型的设计：

- `--json` 参数返回统一信封：`{"ok": true, "data": {...}, "meta": {...}}`。
- `observe` 一次返回当前应用、屏幕文字、可点击元素、界面指纹、电量与亮度，减少模型往返次数。
- `plan` 接受一个 JSON 数组，依次执行多步操作，任一步失败即停止并报告失败位置。
- `wait_model` 轮询界面指纹，连续若干次不变才判定界面稳定。
- 输入文本有三档回退：ADBKeyboard、剪贴板粘贴、逐字符 keyevent。

示例：

```bash
python3 doubao_auto.py observe --json
python3 doubao_auto.py text "你好"
python3 doubao_auto.py plan --json '[
  {"op":"start_app","pkg":"com.example.app"},
  {"op":"wait_model","stable_ms":800},
  {"op":"tap_text","text":"确定"}
]'
python3 doubao_auto.py screen off
python3 doubao_auto.py screen on
```

`doubao_auto.py` 的子命令包括 `tap`、`long_press`、`swipe`、`key`、`back`、`home`、`tap_text`、`tap_rid`、`find`、`wait_text`、`wait_gone`、`wait_model`、`popup`、`dismiss`、`start`、`stop`、`installed`、`uninstall`、`current`、`shot`、`ocr`、`battery`、`brightness`、`wake`、`size`、`hash`、`screen`，以及一组 `vd_*` 虚拟屏幕命令。

### 10.6 输入法规则

源码和脚本中对文本输入有明确约定：

1. 输入中文或 emoji 前，把输入法切换到 `com.android.adbkeyboard/.AdbIME`（ADB Keyboard）。
2. 中文与 emoji 通过 Base64 或剪贴板送入，不能直接用 `input text`。
3. 输入完成后，切回原输入法（脚本中的 `_ime_restore` 函数会记录并恢复）。

输入法的查询与切换命令：

```bash
adb shell settings get secure default_input_method
adb shell ime enable com.android.adbkeyboard/.AdbIME
adb shell ime set com.android.adbkeyboard/.AdbIME
```

> 使用 ADB Keyboard 前，需要先在手机上安装该应用。`auto.py` 不会替你安装它。

### 10.7 屏幕方向

本项目把屏幕方向固定为当前方向。源码中不包含任何修改自动旋转或显示方向的命令，也不应新增此类命令。如需屏幕旋转，请自行在系统设置中操作，项目不会代为执行。

### 10.8 虚拟屏幕（副屏）

`virtual_display.dart` 与 `doubao_auto.py` 中的 `vd_*` 命令用于在虚拟副屏上运行应用，主屏可以同时做别的事。

- 创建：`vd_create`，默认 720×1280，密度 320。
- 启动应用：`vd_launch`，目标可以是包名、`包名/.Activity` 或 HTTPS 链接。
- 操作：`vd_tap`、`vd_swipe`、`vd_key`、`vd_text`。
- 截图与识别：`vd_shot`、`vd_ocr`、`vd_observe`。
- 销毁：`vd_destroy`。

副屏由系统分配 displayId，源码注释中的实测值为 10，因此不要硬编码该值。

### 10.9 在工具模式里使用 ADB

工具模式下，模型会调用 `adb_status`、`adb_connect`、`adb_shell` 等工具。调用顺序是：

1. 先检查 `adb_status`。
2. 若通道未就绪，执行 `adb_connect`。
3. 再执行 `adb_shell` 或 `batch_command`。

如果 `adb_status` 失败，请先按 [10.3 节](#103-拉起通道adb_upsh) 手动拉起通道，并确认无线调试已开启。

---

---

## 11. 文件管理

文件管理（`files.dart`）负责把较大的文件传到本机，供对话、多模态理解和工具模式引用。它的目标是在手机内存有限的前提下，稳定地接收大文件。

### 11.1 规则速查

| 规则 | 数值 | 来源 |
| :--- | :--- | :--- |
| 分片大小 | 64 MB | `DS_CHUNK_SIZE` |
| 单文件上限 | 5 GB | `DS_MAX_FILE_SIZE` |
| 上传会话有效期 | 1 小时 | `DS_UPLOAD_SESSION_TTL` |
| 孤立分片保留期 | 30 分钟 | `DS_ORPHAN_GRACE_PERIOD` |
| 单个请求体上限 | 分片大小加 64 KB | 读取请求体时的限制 |

分片的目的是避免一次性把大文件读进内存。64 MB 是源码中为解决内存溢出（OOM）问题而设定的值。

### 11.2 存储布局

```
data/ds_files/
├── meta/         元数据，按月分文件，如 ds_file_2025-01.sts
├── blob/         完成上传的文件内容
└── chunks/       上传中的分片，完成后合并并删除
```

元数据每行一条记录，格式为：

```
id|name|size|mime|category|createdAt|relPath|source|prompt
```

字段中的特殊字符会按 `escDs` 规则转义（管道符、换行、反斜杠）。

### 11.3 上传流程

前端自动完成以下步骤，接口调用顺序如下：

1. `POST /api/ds-files/upload/start`：提交文件名、大小、MIME 类型，服务端返回上传会话 ID 与总分片数。
2. `POST /api/ds-files/upload/chunk`：逐个分片上传，每个分片的大小不超过 64 MB。
3. `POST /api/ds-files/upload/complete`：服务端检查分片齐全后合并、写入 `blob/`，并追加一条元数据。

中途失败时，可以用同一个会话 ID 继续上传未完成的分片。超过有效期的会话会被清理。

### 11.4 手动使用接口

查看文件列表：

```bash
curl -s http://localhost:9999/api/ds-files/list
```

删除单个文件：

```bash
curl -s -X POST http://localhost:9999/api/ds-files/delete \
  -H "Content-Type: application/json" \
  -d '{"id":"替换为文件ID"}'
```

清空全部文件是不可撤销的操作，接口为 `/api/ds-files/clear-all`。执行前请确认已经备份。

下载：`GET /api/ds-files/download`，参数以源码 `handleDsFileDownload` 为准。

### 11.5 常见问题

- 上传很慢：分片串行上传时，速度受网络与手机存储写入速度限制。Termux 所在的存储建议放在内部存储，而不是外部 SD 卡。
- 上传到一半失败：检查会话是否超过 1 小时。超时后需要重新开始上传。
- 文件列表为空但磁盘上有文件：元数据按月分文件，检查 `meta/` 下是否有对应月份的 `.sts`。

---

## 12. 备份与恢复

备份与还原由 `backup.dart` 完成。它直接打包 `data/` 目录，并以标准 tar 格式（ustar）输出，与 Go 版本的格式保持兼容。

### 12.1 备份

```bash
curl -s -o kewe-backup.tar.gz http://localhost:9999/api/backup
```

备份文件是 `tar.gz` 压缩包，内容为 `data/` 目录下的文件。备份过程中会用 `.backup_tmp/` 作为临时目录，备份结束后会清理其中的文件。

### 12.2 还原

还原接口为 `POST /api/restore`，使用 `multipart/form-data` 上传备份文件：

```bash
curl -s -X POST http://localhost:9999/api/restore \
  -F "file=@kewe-backup.tar.gz"
```

还原会解压到 `data/`。**这会覆盖同名文件**，请在还原前备份当前数据。

### 12.3 备份中的敏感信息

备份包含：

- 会话内容（明文 `.sts`，除非你已经开启相关加密）。
- 加密后的配置文件（`DSENC1|` 前缀）。
- 主密钥文件 `ds_master.key`（hex 明文）。

这意味着备份包本身就等同于「内容 + 解密钥匙」。不要把备份上传到公开网盘，也不要随意发给别人。如果需要分享备份，请先删除 `ds_master.key`，但要知道删除后加密配置将无法解开。

### 12.4 备份的铁律（源码注释）

1. 备份前先停止正在写入的服务，或者确认没有正在进行的流式请求。
2. 还原前先备份当前数据。
3. 还原后重启服务，确认会话与配置都能正常加载。

### 12.5 手动备份（不经过接口）

如果服务未启动，可以直接打包目录：

```bash
cd ~/kewe
tar -czf ~/kewe-data-$(date +%Y%m%d).tar.gz data
```

还原时：

```bash
cd ~/kewe
tar -xzf ~/kewe-data-20250101.tar.gz
```

这里是直接操作文件系统，请先停止服务，避免写入冲突。

---

## 13. 论坛、单词本、角色扮演、公告、峰谷提醒、X 推文

### 13.1 论坛

论坛（`forum.dart`）是一组帖子，数据保存在 `data/dispost/`。它支持展示、发帖和管理。

| 接口 | 作用 |
| :--- | :--- |
| `GET /api/forum/posts` | 列出帖子 |
| `GET /api/forum/posts/detail` | 读取单条帖子 |
| `POST /api/forum/posts/action` | 对帖子执行操作（如点赞、置顶，以源码为准） |
| `POST /api/forum/posts/delete` | 删除帖子 |
| `POST /api/forum/posts/clear` | 清空帖子 |

论坛只在本机使用，不会自动同步到其他设备。

### 13.2 日语单词本

单词本（`vocab.dart`）按单词首字符分片保存，便于在大量词条中快速定位。

存储结构：

```
data/vocab/words/<首字>.sts
data/vocab/images/b_XX/<文件名>      XX 为 00 到 ff 的 256 个桶
```

图片按哈希分入 256 个桶。删除单词或更换图片后，如果图片所在的桶目录变空，系统会自动删除该目录。

| 接口 | 作用 |
| :--- | :--- |
| `GET /api/vocab` | 查询单词 |
| `GET /api/vocab/review` | 复习列表 |
| `POST /api/vocab/clear` | 清空单词本 |
| `GET /api/vocab/image` | 读取单词配图 |
| `POST /api/vocab/upload` | 上传单词配图 |

单词本依赖界面中的「单词」按钮（由 `dsc-vocab.js` 提供），界面的生词高亮也来自这里。

### 13.3 角色扮演（Cosplay）

角色扮演模块在 `cosplay.dart` 中实现。它维护一个角色库，每个角色是一张遵循 Tavern（SillyTavern）v2 角色卡字段的卡片。激活一个角色后，系统会把它的设定拼成一段人设文本，放进每次请求的系统提示词里。

角色扮演不改变模型所在的维度。DeepSeek、豆包、ST 三个维度都能开启角色扮演。

#### 13.3.1 存储位置

| 文件 | 作用 |
| :--- | :--- |
| `data/cosplay/cosplay_state.sts` | 总开关、思考风格、当前激活角色 |
| `data/cosplay/<角色id>.sts` | 每个角色一个文件 |
| `data/deepseek_chat/cosplay.json` | 旧版 JSON 数据。首次读取时会迁移到 `.sts` 格式 |

`cosplay_state.sts` 的格式为 `#STATE|enabled|thinkingStyle|activeRole`。

角色 id 会经过清洗：`/`、`\`、`..`、`|` 都会被替换为下划线，防止路径穿越。

#### 13.3.2 角色卡字段

字段定义见 `cosplay.dart` 的 `CosplayRole`。接口与导入导出使用的字段名也在同一文件中。

| 字段（JSON 键） | 含义 | 注入到提示词时的标签 |
| :--- | :--- | :--- |
| `name` | 角色显示名，必填 | 「你正在扮演角色「名字」」开头 |
| `emoji` | 图标字符 | 拼在名字之后 |
| `system_prompt` | 原样插入的指令块，优先级最高 | 不加标签，直接放在开头 |
| `description` | 身份与背景设定（我是谁） | `【身分】` |
| `personality` | 性格的核心与层次 | `【性格】` |
| `style` | 说话风格（怎么说） | `【口調】` |
| `rules` | 行动准则（该做与不该做） | `【守則】` |
| `behavior` | 私下互动方式 | `【行動】` |
| `scenario` | 情境、世界观、关系设定 | `【情境】` |
| `mes_example` | 会话例（few-shot） | `【会話例】` |
| `post_history_instructions` | 历史之后追加的指令 | 不加标签，放在末尾 |
| `first_mes` | 开场白台词 | 不参与提示词，只用于展示 |
| `creator_notes`、`character_version`、`creator` | 创作者信息 | 不参与提示词，只用于导入导出 |

`first_mes` 不会进入系统提示词。它用于界面展示与导出，如果希望模型开场就说这句话，需要自己在对话里发出。

#### 13.3.3 提示词拼接顺序

`renderCosplayPersona()` 按以下顺序拼接，每一段之间用换行分隔：

1. 开头一句：`你正在扮演角色「名字」` 加图标。
2. `system_prompt`（非空时）。
3. `【身分】`、`【性格】`、`【口調】`、`【守則】`、`【行動】`、`【情境】`、`【会話例】`（各字段非空时）。
4. `post_history_instructions`（非空时）。
5. 固定尾句：要求角色在保持设定的同时，也作为 Agent 助手完成实际工作。

之后 `renderActiveCosplayPersona()` 会再追加一段思考风格指令，二选一：

- `neutral`（默认）：思考过程中禁止用圆括号写内心独白，分析内容直接陈述。
- `role`：思考过程中允许以角色第一人称写内心独白。

如果开关已开启，但没有选择任何角色，系统会插入一段提示，让模型暂时保持默认助手身份。

#### 13.3.4 接口

接口是 `/api/ds-cosplay`，GET 返回状态，POST 按 `action` 字段执行动作。

| `action` | 作用 | 其他字段 |
| :--- | :--- | :--- |
| `setEnabled` | 开启或关闭角色扮演 | `enabled`（布尔值） |
| `setThinkingStyle` | 设置思考风格 | `style`，取值 `role` 或 `neutral`，其他值按 `neutral` 处理 |
| `setActiveRole` | 切换激活角色 | `id`，传 `null` 字符串或空值会结束角色扮演 |
| `upsertRole` | 新增或更新角色 | `card`，角色卡对象 |
| `removeRole` | 删除角色 | `id` |

以下示例中的角色与内容都是虚构的占位内容：

```bash
# 查看状态与角色列表
curl -s http://localhost:9999/api/ds-cosplay

# 开启角色扮演
curl -s -X POST http://localhost:9999/api/ds-cosplay \
  -H 'Content-Type: application/json' \
  -d '{"action": "setEnabled", "enabled": true}'

# 新增一个示例角色
curl -s -X POST http://localhost:9999/api/ds-cosplay \
  -H 'Content-Type: application/json' \
  -d '{
    "action": "upsertRole",
    "card": {
      "name": "示例角色甲",
      "emoji": "🎭",
      "description": "一名虚构的图书管理员，负责看守镇上的旧书库。",
      "personality": "话不多，记性好，对借书的人有耐心。",
      "style": "语气平稳，句子短，偶尔用反问。",
      "rules": "不编造书库里没有的书籍信息。",
      "scenario": "故事发生在一座虚构的小镇。",
      "first_mes": "欢迎来到旧书库，想找哪一类书？"
    }
  }'

# 切换为该角色
curl -s -X POST http://localhost:9999/api/ds-cosplay \
  -H 'Content-Type: application/json' \
  -d '{"action": "setActiveRole", "id": "替换为角色id"}'

# 结束角色扮演，回到默认身份
curl -s -X POST http://localhost:9999/api/ds-cosplay \
  -H 'Content-Type: application/json' \
  -d '{"action": "setActiveRole", "id": "null"}'

# 删除角色
curl -s -X POST http://localhost:9999/api/ds-cosplay \
  -H 'Content-Type: application/json' \
  -d '{"action": "removeRole", "id": "替换为角色id"}'
```

角色 id 可以先调用 GET `/api/ds-cosplay` 查看角色列表后获取。

所有失败都返回 HTTP 500 与错误文字，不会伪造成功。

#### 13.3.5 在网页界面中使用

1. 在界面中找到角色扮演（界面语言中对应「角色扮演」或「ロールプレイ」）的设置区域，打开开关。具体位置随界面版本可能不同。
2. 角色列表中每个角色有切换、编辑、删除三个操作。删除按钮使用危险样式。
3. 思考风格（neutral 或 role）在同一区域切换。

前端中相关函数包括 `cosplayApplyState`、`renderCosplayList`、`cosplayRequest`，它们调用上述接口。

#### 13.3.6 角色扮演与五个 ST 预设模型

ST 维度预置的五个模型（见 [7.8.1 节](#781-五个预设模型)）可以用于角色扮演。源码没有为它们设置专用的角色扮演开关，也没有根据角色扮演状态切换模型。人设注入只看开关与激活角色，与模型名无关。

一个实用的组合方式：

| 场景 | 维度 | 模型 | 理由 |
| :--- | :--- | :--- | :--- |
| 日常角色对话，控制成本 | ST | `[Kiro]claude-haiku-5-5` | 输出单价最低 |
| 关键剧情，追求质量 | ST | `[Kiro]claude-opus-4-8` | 输出单价最高，适合细腻文风 |
| 每次请求费用固定 | ST | `[次][抗截断]gemini-3.8-flash` | 按请求计费，每次 0.025 元 |
| 需要多模态或语音 | 豆包 | 豆包模型 | ST 维度不负责语音与图片 |
| 需要 DeepSeek 推理 | DeepSeek | DeepSeek 模型 | 推理能力由模型本身决定 |

这些建议基于价格与模型名，不是角色扮演质量的测试结论。

#### 13.3.7 设计上的边界

- 角色设定只影响输出风格与口吻，不改变模型的安全边界。
- 工具模式开启时，角色设定与工具安全规则冲突，以工具模式的闸门为准。
- `renderCosplayPersona` 末尾的固定尾句要求角色继续作为 Agent 助手完成实际工作。角色不能用来绕过工具模式的确认流程。
- 角色卡内容会进入请求体并发送给模型提供方，请勿在角色卡里写入真实的密钥或隐私信息。

#### 13.3.8 常见问题

| 现象 | 可能原因 | 处理方法 |
| :--- | :--- | :--- |
| 开关打开，但回复没有角色味道 | 没有选择激活角色 | 调用 GET 查看 `activeRole`，用 `setActiveRole` 设置 |
| 设置了角色，但 `first_mes` 没有出现 | `first_mes` 不参与提示词 | 把开场白写进 `scenario` 或 `mes_example`，或自行在对话中发出 |
| 切换角色后不生效 | 旧会话已有上下文 | 新开一个会话，或在当前会话中明确提示模型切换 |
| 角色扮演开关打不开 | 状态文件不可写 | 检查 `data/cosplay/` 目录的写入权限 |
| 旧版角色丢失 | 迁移未执行 | 确认 `data/deepseek_chat/cosplay.json` 存在，重启服务后再读取一次 |

### 13.4 公告

公告（`announcements.dart`）是界面顶部的通知条。公告保存在 `data/announcements/`。

| 接口 | 作用 |
| :--- | :--- |
| `GET /api/announcements` | 列出全部公告（管理用） |
| `GET /api/announcements/active` | 获取当前生效的公告（界面使用） |

### 13.5 峰谷提醒

峰谷提醒（`peakvalley.dart`）根据 DeepSeek 官方的峰谷定价时段，在高峰开始与低谷开始时推送通知。

- 阶段常量：`peak`（高峰）与 `valley`（低谷）。
- 支持的时区（`pvTimezones`）：`Asia/Shanghai`、`Asia/Hong_Kong`、`Asia/Taipei`、`Asia/Tokyo`、`Asia/Singapore`、`Asia/Seoul`、`UTC`、`Europe/London`、`Europe/Paris`、`America/New_York`、`America/Los_Angeles` 等。
- 推送渠道包括 serverchan、bark、dingtalk、wecom 等（源码中共 7 种）。

时区处理说明：源码没有依赖 IANA 时区库，而是内置了这些时区的固定偏移与夏令时规则。如果要新增时区，需要在源码中补充对应规则。

调度由 `pvSchedulerLoop()` 在 `main.dart` 启动时开始运行。

### 13.6 X（推特）推文抓取

`xtweet.dart` 支持抓取 X 推文，内部会并发尝试多个后端，采用先返回者胜出的策略。接口：

| 接口 | 作用 |
| :--- | :--- |
| `GET /api/x/tweet` | 获取单条推文 |
| `GET /api/x/timeline` | 获取时间线 |

抓取依赖外部服务的可用性。服务不可用时，接口会返回错误，并不会伪造结果。

---

## 14. 计费与用量统计

### 14.1 显示位置

每条回复下方会显示本次用量与人民币估算。数据来自服务端的真实用量记录，不是按字数估算。

### 14.2 计价口径

计价表在 `token_cost.dart` 中，单位为元，按每百万 tokens 计价。主要字段：

| 字段 | 含义 |
| :--- | :--- |
| `hit` | 缓存命中输入单价 |
| `miss` | 缓存未命中输入单价 |
| `out` | 输出单价 |
| `audio` / `audioHit` | 音频输入的未命中 / 命中单价（可选） |
| `flat` | 是否为全天均价，没有峰谷倍率 |
| `perRequest` | 固定价（元/请求），大于 0 时优先按请求计费 |

DeepSeek 部分（节选自源码）：

| 模型 | 命中 | 未命中 | 输出 |
| :--- | :--- | :--- | :--- |
| `deepseek-flash` / `deepseek-v4-flash` / `deepseek-v4.1-flash` | 0.02 | 1.0 | 4.0 |
| `deepseek-v4-pro` / `deepseek-chat` / `deepseek-reasoner` | 0.15 | 4.5 | 13.5 |

豆包 `doubao-seed-2-1-lite`（终日均价）：输入未命中 0.8、输入命中 0.16、输出 2.7，音频输入未命中 12、命中 2.4。

中转站模型也在同一张表中，多数为全天均价，个别模型按固定价计费。

中转站五个预设模型的单价如下（元 / 100 万 tokens，固定价除外）：

| 模型 | 输入未命中 | 输入命中 | 输出 | 计费方式 |
| :--- | ---: | ---: | ---: | :--- |
| `[Kiro]claude-opus-4-8` | 3.5 | 0.35 | 17.5 | 按 token，全天均价 |
| `[Kiro]claude-haiku-5-5` | 0.21 | 0.021 | 1.05 | 按 token，全天均价 |
| `[ASP]gemini-3.8-flash` | 0.3 | 0.03 | 1.5 | 按 token，全天均价 |
| `[抗截断]gemini-3.8-flash` | 0.3 | 0.03 | 1.5 | 按 token，全天均价 |
| `[次][抗截断]gemini-3.8-flash` | — | — | — | 固定价 0.025 元 / 请求 |

具体算例见 [7.8.6 节](#786-费用计算示例)。

### 14.3 计算公式

对于按 token 计费的模型：

```
费用 = 命中 tokens × hit / 1e6
     + 未命中 tokens × miss / 1e6
     + 输出 tokens × out / 1e6
```

若模型配置了 `perRequest`，则费用为 `perRequest × 请求次数`。

峰谷模型还会根据当前时段（高峰或低谷）选择倍率，具体在 `token_cost.dart` 中由时段判定函数决定。节假日表 `_HOLIDAYS` 也参与判定，需要定期更新年份。

### 14.4 数据会保存吗

用量记录会随会话一起保存，格式在 `.sts` 的 `usage` 字段中。这样即使重启，历史费用也能查看。

### 14.5 未定价模型

如果模型不在计价表中，界面会显示用量但不显示费用。这是有意设计，源码注释说明「绝不估算」。要显示费用，需要在 `token_cost.dart` 中补充价目。

### 14.6 额度与计费的区别

- DeepSeek 的费用直接来自官方账户余额。
- 豆包的文本、语音、音频、翻译、播客各有各自的额度，互不混用。README 旧版说明中写明，它们不会消耗文本额度。
- 中转站费用取决于中转站自己的计价。

计费数字仅用于参考，以服务商账单为准。

---

## 15. 数据存储与加密

### 15.1 会话格式（.sts）

会话按 `.sts` 单文件存储，每个会话一个文件，位于 `data/deepseek_chat/sessions/`。文件是按行的文本格式：

```
#S|会话ID|标题|创建时间|更新时间
#M|消息ID|role|content|createdAt|attachments|reasoning|usage|dim
```

- `#S` 开头为会话头，`#M` 开头为消息。
- 字段之间以 `|` 分隔。字段内的管道符会被转义为 `\p`，换行转义为 `\n`，反斜杠转义为 `\\`。
- 解析时使用 `unescDs` 还原。

这种格式便于 `grep`、`awk` 与脚本处理，但不适合手工编辑。修改前请先备份。

### 15.2 加密

敏感配置使用 AES-256-GCM 加密，格式为：

```
DSENC1|base64(nonce || 密文 || tag)
```

- 算法：AES-256-GCM（纯 Dart 实现，见 `aes_gcm.dart`）。
- 密钥：32 字节，来自主密钥（见 [4.3 节](#43-主密钥)）。
- nonce：每次加密随机生成。
- 完整性：GCM 的 tag 保证密文未被篡改，解密失败会直接报错。

源码中的 `sha256.dart` 与 HMAC 实现用于其他签名场景（如 Edge TTS 签名），与 API Key 加密是分开的。

### 15.3 哪些数据是加密的

| 数据 | 是否加密 |
| :--- | :--- |
| DeepSeek API Key 等配置 | 是（`DSENC1|`） |
| 会话内容 | 否，明文 `.sts` |
| 文件元数据 | 否，明文 `.sts` |
| 中转站 Key | 否，明文 JSON（`relay_config.sts`） |
| 主密钥 | 否，hex 明文，权限 600 |

这个差异很重要。如果你需要更高的隐私保护，建议把 `data/` 放在加密的存储中，或者只在可信设备上运行。

### 15.4 文件权限

主密钥写入后会执行 `chmod 600`。其他数据文件的权限沿用 Termux 的默认值。请检查 `data/` 目录的权限，确保只有当前用户可读。

### 15.5 数据迁移

`migrateDsChatToPerSession()` 会在启动时把旧版本的会话格式迁移到每个会话一个文件的新格式。迁移是自动的，不需要手动操作。迁移前后的数据都保留在 `data/` 中，便于回退。

---

## 16. HTTP API 参考

### 16.1 通用约定

- 基础地址：`http://localhost:9999`（端口由 `DSH_PORT` 决定）。
- 请求与响应默认使用 JSON，编码为 UTF-8，`Content-Type: application/json; charset=utf-8`。
- CORS：服务端返回 `Access-Control-Allow-Origin: *`，允许的方法为 `GET, POST, DELETE, OPTIONS`，允许的请求头为 `Content-Type`。
- 未知路径回退到 `index.html`。这意味着请求不存在的 API 路径时，可能得到 HTML 而不是 404 JSON，请注意检查响应类型。
- 流式接口（发送消息、播客 SSE）使用 `text/event-stream`，并关闭了自动 gzip 压缩，避免流被缓冲。
- 空闲连接超时为 120 秒。

### 16.2 错误格式

大多数错误以 JSON 返回，包含错误信息字段。服务端内部异常会记录日志，返回 HTTP 500 与「サーバー内部エラー」文案（源码中的日语文案，请以状态码为准）。

### 16.3 DeepSeek 聊天接口

| 方法 | 路径 | 说明 |
| :--- | :--- | :--- |
| GET | `/api/ds-chat/config` | 读取配置（不返回明文 Key） |
| — | `/api/ds-chat/config` 的保存 | `handleDsChatConfig` 只实现了 GET 分支，配置保存由界面完成，不建议用 curl 直接写入 |
| GET / POST | `/api/ds-chat/sessions` | 列出或创建会话 |
| POST | `/api/ds-chat/sessions/batch-delete` | 批量删除会话，请求体含 `ids` 数组 |
| GET | `/api/ds-chat/messages` | 读取会话消息（分页，参数见源码） |
| GET | `/api/ds-chat/reasoning` | 读取某条消息的 reasoning |
| POST | `/api/ds-chat/session-mention` | 解析跨会话引用 |
| POST | `/api/ds-chat/search` | 全文搜索会话 |
| POST | `/api/ds-chat/send` | 发送消息，SSE 流式返回 |
| POST | `/api/ds-chat/continue` | 续写中断的回复 |
| POST | `/api/ds-chat/abort-save` | 中止并保存已生成内容 |
| GET / POST | `/api/ds-chat/model-router` | 读取或修改模型路由规则 |
| POST | `/api/ds-chat/test` | 测试 Key 与模型连通性 |
| POST | `/api/ds-chat/tts` | 朗读文本（Edge TTS） |
| POST | `/api/ds-chat/stt` | 语音转文字 |
| POST | `/api/ds-chat/translate` | 翻译 |
| POST | `/api/ds-chat/generate-image` | 生成图片 |

发送消息的主要请求字段（来自 `chat_send.dart`）：

| 字段 | 类型 | 说明 |
| :--- | :--- | :--- |
| `sessionId` | 字符串 | 会话 ID |
| `content` | 字符串 | 用户消息正文，会被去除首尾空白 |
| `fileIds` | 字符串数组 | 已上传文件的 ID |
| `reasoningLevel` | 整数 | 思考等级，默认 1 |
| 工具相关开关 | 布尔 | 工具模式开关，服务端仍会二次校验 |

示例（SSE 返回，`-N` 关闭 curl 缓冲）：

```bash
curl -N -X POST http://localhost:9999/api/ds-chat/send \
  -H "Content-Type: application/json" \
  -d '{"sessionId":"替换为会话ID","content":"用一句话介绍你自己","reasoningLevel":1}'
```

### 16.4 豆包接口

| 方法 | 路径 | 说明 |
| :--- | :--- | :--- |
| GET / POST | `/api/doubao/config` | 读取或保存豆包配置 |
| GET | `/api/doubao/models` | 列出模型目录 |
| POST | `/api/doubao/image` | 生图 |
| POST | `/api/doubao/image-edit` | 图片编辑 |
| POST | `/api/doubao/video` | 提交视频生成或理解任务 |
| GET | `/api/doubao/video/status` | 查询视频任务状态 |
| GET | `/api/doubao/video/tasks` | 列出视频任务 |
| POST | `/api/doubao/tts` | 语音合成 |
| POST | `/api/doubao/audio-generate` | 音频生成（SeedAudio1.0） |
| POST | `/api/doubao/podcast` | 播客生成（一次性） |
| POST | `/api/doubao/podcast/sse` | 播客生成（SSE 流式） |
| POST | `/api/doubao/asr` | 语音识别 |
| POST | `/api/doubao/voice/turn` | 语音单轮对话 |
| POST | `/api/doubao/chat` | 文本对话（含图片） |
| POST | `/api/doubao/analyze-audio` | 音频理解 |
| GET | `/api/doubao/realtime` | 实时语音（WebSocket 升级） |
| GET | `/api/doubao/realtime/status` | 实时语音状态 |
| POST | `/api/doubao/voice/save` | 保存音色 |
| GET | `/api/doubao/voice/list` | 列出音色 |
| POST | `/api/doubao/voice/delete` | 删除音色 |
| POST | `/api/doubao/voice/clear` | 清空音色 |
| POST | `/api/doubao/rtc/start` | 启动 RTC 任务 |
| POST | `/api/doubao/rtc/stop` | 停止 RTC 任务 |
| POST | `/api/doubao/translate` | 机器翻译 |
| GET | `/api/doubao/glossary/list` | 术语表列表 |
| GET | `/api/doubao/glossary/get` | 获取术语 |
| POST | `/api/doubao/glossary/save` | 保存术语 |
| POST | `/api/doubao/glossary/delete` | 删除术语 |

> 上表的 GET 与 POST 方法依据 `main.dart` 注册的路由与各 handler 中的 `req.method` 判断整理。个别接口同时支持两种方法，实际以 handler 为准。

### 16.5 文件接口

| 方法 | 路径 | 说明 |
| :--- | :--- | :--- |
| POST | `/api/ds-files/upload/start` | 开始分片上传 |
| POST | `/api/ds-files/upload/chunk` | 上传一个分片 |
| POST | `/api/ds-files/upload/complete` | 完成上传 |
| GET | `/api/ds-files/download` | 下载文件 |
| GET | `/api/ds-files/list` | 列出文件 |
| POST | `/api/ds-files/delete` | 删除文件 |
| POST | `/api/ds-files/clear-all` | 清空全部文件（不可撤销） |

### 16.6 开发者工具接口

| 方法 | 路径 | 说明 |
| :--- | :--- | :--- |
| GET / POST | `/api/ds-devtools/prompts` | 读取或保存注入的提示词 |
| POST | `/api/ds-devtools/prompts/batch-delete` | 批量删除提示词 |

### 16.7 其他接口

| 方法 | 路径 | 说明 |
| :--- | :--- | :--- |
| GET / POST / DELETE | `/api/ds-cosplay` | 角色库 |
| GET | `/api/x/tweet` | 推文 |
| GET | `/api/x/timeline` | 时间线 |
| GET | `/api/announcements` | 公告列表 |
| GET | `/api/announcements/active` | 生效中的公告 |
| GET / POST | `/api/relay/config` | 中转站配置 |
| GET | `/api/relay/models` | 中转站模型列表 |
| GET | `/api/displaymodels` | 自定义显示模型 |
| GET | `/api/backup` | 下载备份 |
| POST | `/api/restore` | 上传还原 |
| GET / POST | `/api/forum/posts` | 论坛帖子 |
| GET / POST | `/api/vocab` | 单词本 |

### 16.8 健康检查

```bash
# 服务是否在线
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9999/

# 配置接口是否返回 JSON
curl -s http://localhost:9999/api/ds-chat/config | head -c 200; echo

# 豆包模型列表
curl -s http://localhost:9999/api/doubao/models | head -c 300; echo
```

---

## 17. 辅助脚本：st.py 与 ha.py

### 17.1 st.py：一键启动与守护

`st.py` 负责编译、启动、后台守护与服务注册。它的命令行参数已在 [第 5 章](#5-启动停止与后台运行) 说明。

内部行为要点：

- AOT 产物判定是无状态的，只看 `app` 是否存在且可执行。
- 编译失败不会删除旧的 `app`，而是先编译到临时文件，成功后再原子替换。
- 日志写入 `data/st.log`，`--logs` 会读取该文件。
- 守护模式使用 `setsid` 脱离终端。

### 17.2 ha.py：思考链代码折叠

`ha.py` 解决的问题是：工具模式下，思考链（reasoning）常会输出大量代码。这些代码被写入聊天记录后，会让界面渲染变卡。

它的做法是：不删除任何内容，只把超过一定行数的代码块用 `<details>` 与 `<summary>` 包起来，默认折叠。点击展开即可看到完整内容。

子命令：

| 命令 | 作用 |
| :--- | :--- |
| `clean` | 一次性处理目录下所有聊天记录，默认会先备份 |
| `watch` | 持续监听目录，有新变化时处理 |
| `export` | 生成展示副本，不修改原文件 |
| `proxy` | 启动 HTTP 代理，实时折叠上游 DeepSeek 的响应 |

示例：

```bash
# 一次性优化（推荐，在服务退出后执行）
python3 ha.py clean --dir data/deepseek_chat/

# 只生成展示副本，原文件不动
python3 ha.py export --dir data/deepseek_chat/ --out display/

# 启动代理，默认监听 9000，上游为 https://api.deepseek.com
python3 ha.py proxy --port 9000
```

参数默认值：

| 参数 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `--min-lines` | 15 | 代码块超过该行数才折叠 |
| `--interval` | 2 秒 | `watch` 的轮询间隔 |
| `--no-backup` | 否 | 不备份原文件（不推荐） |
| `--upstream` | `https://api.deepseek.com` | `proxy` 的上游地址 |

注意：Go 程序运行时会持续向 `.sts` 文件追加写入，`watch` 与服务同时读写同一文件有数据竞争风险。推荐在服务停止后执行 `clean`。

### 17.3 adb_up.sh 与 auto.py、doubao_auto.py

这三个脚本已在 [第 10 章](#10-adb-自动化引擎) 详细说明。简要对应关系：

| 文件 | 角色 |
| :--- | :--- |
| `adb_up.sh` | 拉起 ADB 通道，校验 uid=2000 |
| `auto.py` | 通用自动化引擎，命令行与导入均可 |
| `doubao_auto.py` | 豆包专用版，输出结构化 JSON |

---

## 18. 二次开发指南

### 18.1 项目结构原则

- 入口只做初始化与路由注册（`bin/main.dart`）。
- 业务逻辑按功能拆分在 `lib/src/`。
- 同一功能的 HTTP 处理函数与业务函数通常在同一文件中。
- 全局路径与常量集中在 `globals.dart`，修改路径时只改这里。

### 18.2 新增一个 HTTP 接口

1. 在对应模块中写 handler，签名为 `Future<void> handleXxx(HttpRequest req)`。
2. 在 `bin/main.dart` 的 `registerRoutes()` 中注册：

   ```dart
   _register('/api/xxx', handleXxx);
   ```

3. `_register` 会自动包上日志与 CORS 中间件，无需重复处理。
4. 请求体使用 `readJsonBody`（或 `readBodyText`、`readBodyBytes`）读取，响应使用 `jsonResponse` 或 `errJson`。

### 18.3 新增一个工具（让模型能调用）

1. 在 `tools.dart` 的 `buildDsTools()` 中添加 `fnTool(名称, 描述, 参数 schema)`。
2. 在 `executeDsTool` 的 `switch` 中添加对应分支。
3. 如果工具有副作用，必须在执行前调用 `DsToolGate.check`，并确保内层调用使用 `checkInner`。
4. 在 `doubao_tools.dart` 中决定它属于哪个档位，避免在 lite 档加载过多工具。

### 18.4 新增一个豆包模型

1. 在 `dbModelCatalog`（`doubao.dart`）中登记模型标识、显示名与类别。
2. 如果需要计价，在 `token_cost.dart` 的 `_PRICE` 中添加价目。
3. 如果模型名不符合现有前缀规则，在 `dbIsDoubaoModel` 或 `dbToolProfileOf` 中补充判断。

### 18.5 新增一种语言

1. 在 `i18n/locales/` 中新增 `xx.js` 与 `xx-extra.js`。
2. 在 `i18n/i18n.js` 的 `LANGS` 数组中加入语言代码。
3. 参照 [7.4 节的自检方法](#74-语言纯净规则本项目硬性要求) 检查词条数量与残留字符。

### 18.6 代码风格约定

- Dart 代码沿用现有的注释风格：文件头以 `// ====` 包住，写明文件名与职责。
- 函数与变量使用 `lowerCamelCase`，常量使用 `UPPER_SNAKE_CASE` 或 `kXxx`（与现有代码保持一致）。
- 日志统一使用 `logp`，不要直接 `print`。
- 不引入第三方依赖。项目从设计上就是零依赖的。

### 18.7 提交前自检

```bash
# 静态检查
dart analyze

# 编译验证
dart compile exe bin/main.dart -o /tmp/kewe_test_app

# 启动测试
DSH_PORT=19999 dart run bin/main.dart &
sleep 3
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:19999/
kill %1
rm -f /tmp/kewe_test_app
```

最后一行的 `rm` 只删除你本次编译生成的临时文件，不要扩大范围。

---

## 19. 安全与隐私

### 19.1 威胁模型

Kewe 默认只为本机使用设计。它的 HTTP 服务监听 `0.0.0.0`，这意味着同一局域网内的设备也能访问。请注意：

- 服务没有内置登录或访问令牌。任何能访问该端口的人都能读取会话、调用模型并消耗你的额度。
- 工具模式下，能访问接口的人也能让模型操作手机。
- 因此，**不要把端口暴露到公网**。

### 19.2 建议的加固措施

1. 只在可信 Wi-Fi 下运行，或通过防火墙限制端口访问。
2. 不做端口转发与内网穿透，除非你已经给前置加上认证。
3. 定期检查 `data/` 目录的权限，确保只有当前用户可读。
4. 不在共享设备上保存 Key。
5. 工具模式按需开启，用完关闭。

### 19.3 Key 管理

- 不要把 Key 写进源码、`.env.example` 或提交到 Git。
- `.gitignore` 已经排除 `.env`、`*.key`、`data/` 与 `app`，提交前仍请用 `git status` 检查。
- 如果 Key 泄露，立即在对应平台吊销并重新生成。
- 不要在 shell 历史中留下明文 Key。示例中使用 `read -rs` 的方式可以避免这一点。

### 19.4 依赖与供应链

项目不依赖第三方 Dart 包，所有加密与 HTTP 实现都在仓库内。这减少了供应链风险，但也意味着安全相关代码需要自行审阅。Python 脚本只使用标准库。

### 19.5 日志

服务日志会记录请求路径、耗时和错误信息。日志中不应包含 Key。如果你在排查时要分享日志，请先检查并删除敏感内容。

### 19.6 隐私与第三方

- 发送给 DeepSeek、火山方舟、中转站的内容会离开设备，受对方的隐私政策约束。
- 语音、图片、视频等多媒体内容同样会上传。
- 本项目本身不做遥测，不向作者服务器上报数据。

---

## 20. 故障排查

### 20.1 启动类

| 现象 | 可能原因 | 处理方法 |
| :--- | :--- | :--- |
| `dart: command not found` | 未安装 Dart SDK | `pkg install dart`，然后重新打开终端 |
| 端口被占用，反复重试后退出 | 旧进程还在运行 | `python3 st.py --stop`，或 `ss -lntp` 查看占用进程后结束它 |
| `app` 无法运行 | 编译不完整或架构不匹配 | `python3 st.py --rebuild` |
| 启动后立即退出 | 环境变量格式错误，如 `DS_MASTER_KEY` 不是 64 位十六进制 | 检查 `.env` 与环境变量 |
| 找不到 `index.html` | 当前目录不正确，或 `DSH_BASE` 设置错误 | 在项目根目录执行，或检查 `DSH_BASE` |

### 20.2 访问类

| 现象 | 可能原因 | 处理方法 |
| :--- | :--- | :--- |
| 浏览器打不开页面 | 服务未启动，或端口不对 | `curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9999/` |
| 页面能打开但接口报错 | 前端缓存的是旧版本脚本 | 强制刷新页面，或清除站点数据 |
| 同局域网其他设备打不开 | 服务监听正常，但被防火墙或路由隔离拦截 | 检查设备 IP 与路由设置 |

### 20.3 请求类

| 现象 | 可能原因 | 处理方法 |
| :--- | :--- | :--- |
| 发送后长时间无回应 | 网络不通、代理配置错误 | 设置 `HTTPS_PROXY` 或 `PROXY`，并用 `ds-chat/test` 测试 |
| 401 或 403 | Key 错误或过期 | 在控制台重新生成 Key，并在界面保存 |
| 429 | 请求过于频繁或额度用完 | 稍后再试，或检查账户余额 |
| 模型不存在 | 模型名已变更 | 在官方控制台核对模型名，并更新界面选择 |
| 回复被截断 | 输出 token 上限 | 使用续写接口 `/api/ds-chat/continue` |
| 思考一直不结束 | SSE 被压缩缓冲 | 源码已关闭 autoCompress，若仍出现，检查是否经过了中间代理 |

### 20.4 数据类

| 现象 | 可能原因 | 处理方法 |
| :--- | :--- | :--- |
| 配置解密失败 | 主密钥变了或丢失 | 恢复 `ds_master.key`，或重新填写 Key |
| 会话列表为空 | `sessions/` 目录为空或迁移未完成 | 检查 `data/deepseek_chat/sessions/` |
| 搜索不到刚发的内容 | 搜索缓存未刷新 | 重启服务，或稍等片刻 |
| 还原后数据异常 | 备份包不完整，或还原中断 | 用之前的备份重新还原 |

### 20.5 语言类

界面或日志中出现日语是源码的已知问题（见 [第 21 章](#21-已知限制与维护状态)）。这不是配置错误，也不会影响基本功能。

### 20.6 ADB 类

| 现象 | 可能原因 | 处理方法 |
| :--- | :--- | :--- |
| `adb_up.sh` 显示未连接 | 无线调试未开启，或端口不是 5555 | 在开发者选项中开启无线调试，并确认端口 |
| `uid` 不是 2000 | 连接的不是 shell 通道 | 确认连接的是无线调试端口，而不是其他设备 |
| 输入中文失败 | ADB Keyboard 未安装或未切换 | 安装 ADB Keyboard，并参照 [10.6 节](#106-输入法规则) 切换 |
| 设备掉线频繁 | 手机省电策略断开了无线调试 | 关闭对 Termux 的电池优化，保持无线调试开启 |

### 20.7 看日志的正确姿势

1. 服务以前台方式运行时，日志直接在终端显示。
2. 后台运行时，使用 `python3 st.py --logs 200` 查看 `data/st.log`。
3. 需要更详细的堆栈时，设置 `DSH_DEBUG=1` 后重启服务。
4. 排查 ADB 问题时，直接在终端执行 `adb devices`、`adb -s 127.0.0.1:5555 shell id`。

---

## 21. 已知限制与维护状态

### 21.1 维护状态

README 旧版（作者问答与维护声明部分）描述的状态如下，本节保留其要点，供使用者知悉：

- 项目以现状交付，作者不再投入精力做全量功能的长期维护。
- 仅保障中文环境下的基础运行。
- 以下功能被标记为暂停维护：视频模型相关能力（成本较高）、语音朗读（日语符号可能导致误读）、文本转语音的稳定性、多语言深度适配。
- 只修复 bug 与模型失效后的更新，不再新增功能。

以上是旧版文档中的说明。本次 README 改写以源码为准，但维护状态属于作者声明，请以仓库的最新提交与作者说明为准。

### 21.2 日语残留

源码、系统提示词与部分界面文案原生为日语。使用中文界面时，仍可能看到未翻译的日语，尤其是：

- 启动日志（如「サーバーが起動しました」）。
- 部分错误文案（如「サーバー内部エラー」）。
- 工具模式的系统提示词。
- 部分 `dsc-ja-fix.js` 修补的文案。

这是源码本身的情况，不是配置问题。

### 21.3 朗读问题

点击朗读时，文本中的特殊字符或日语符号可能导致读音错误。这已在旧版说明中列为暂停修复。若需要稳定朗读，可以在发送给 TTS 之前清理文本。

### 21.4 模型与接口依赖

- DeepSeek 与豆包的模型名、接口路径都可能随官方更新变化。
- 豆包的部分功能（如抖音百科信源）依赖平台的「联网内容插件」，其可用性由平台决定。
- 实时语音、RTC 与播客依赖火山引擎的语音服务，需要额外的 Key 与额度。

### 21.5 平台限制

- 只在 Termux 与安卓上测试过。在 Linux 桌面运行时，ADB 与 Termux 相关功能需要自行适配。
- 虚拟屏幕依赖系统支持，不同机型表现不同。
- 长时间运行时，手机省电策略可能会杀掉后台进程。建议使用 `st.py --daemon`，并把 Termux 设为不受电池优化限制。

### 21.6 工具模式限制

- 工具模式的安全闸门依赖服务端状态。服务重启后，会话的工具状态需要重新开启。
- Shizuku 相关工具当前停用。
- 工具调用的结果依赖设备状态，例如界面变化后，之前的坐标可能失效，需要重新 `find_element` 或 `ui_dump`。

### 21.7 数据限制

- 会话以单文件存储，单个会话特别大时，读写会变慢。
- 搜索使用内存缓存，内容很多时会占用较多内存。
- 没有内置数据库，没有索引服务。

---

## 22. 常见问题

以下问答覆盖安装、使用、计费、数据和安全等常见问题。答案以源码与旧版文档为依据。

### 安装与部署

**Q：必须用 Termux 吗？**
不必须。任何能运行 Dart 与 Python 的 Linux 终端都可以。但 ADB 通道与 Termux 集成最为顺畅，所以推荐 Termux。

**Q：必须安装 Dart 吗？**
运行或编译主程序需要 Dart SDK。只使用 Python 脚本（如 `ha.py`）时不需要。

**Q：为什么 `pubspec.lock` 是空的？**
因为项目没有任何第三方依赖，`packages` 为空是正常现象。

**Q：`app` 文件可以直接分享吗？**
它是为 ARM aarch64 Android 编译的产物，只能在相同架构上运行。分享前请确认它不包含你的私有配置（配置在 `data/` 中，不在二进制里）。

**Q：如何升级？**
`git pull` 拉取最新代码，然后 `python3 st.py --rebuild` 重新编译。升级前先备份 `data/`。

### 启动与运行

**Q：怎样让服务关闭终端后仍然运行？**
使用 `python3 st.py --daemon`。它会用 `setsid` 脱离终端。

**Q：怎样开机自启？**
安装 `termux-services` 后执行 `python3 st.py --install-service`。是否开机自启还取决于 Termux:Boot 的配置，本项目未内置 Termux:Boot 脚本。

**Q：端口能改吗？**
可以，设置 `DSH_PORT` 环境变量或在 `.env` 中写入。改完需要重启。

**Q：服务占用多少内存？**
取决于会话大小与并发请求。AOT 编译版本通常比 JIT 版本占用更少。

### 语言与显示

**Q：为什么界面有日语？**
源码原生是日语开发，部分文案未完全翻译。详见 [21.2 节](#212-日语残留)。

**Q：可以只用英文界面吗？**
界面支持多种语言代码，但仍有部分日语文案。英文用户需要接受这一限制。

### 对话与模型

**Q：为什么推荐 DeepSeek 维度作为主要工作维度？**
源码与旧版说明都建议以 DeepSeek 为主。豆包的语音通话与部分生成功能有各自的限制，例如语音通话不支持在对话中顺带调用手机工具。

**Q：图片发给纯文本模型会怎样？**
模型路由会自动切换到视觉兜底模型（`deepseek-flash`）。见 [7.6 节](#76-模型路由)。

**Q：思考等级越高越好吗？**
不一定。思考越深，耗时与 token 越多。日常问答使用默认等级即可。

### 计费与 token

**Q：费用准确吗？**
费用来自服务端记录的真实用量，并按计价表换算。它与服务商账单可能有细微差别，应以账单为准。

**Q：为什么有些模型不显示费用？**
它不在计价表中。源码注释说明这是有意的「绝不估算」设计。

**Q：会重复计费吗？**
旧版说明称「如果不乱操作，一般不会重复计费」。重复请求（如反复点击重试）会产生额外费用，请避免无意义的重试。

### 豆包与多模态

**Q：豆包语音通话能顺便让模型做事吗？**
不能。语音通话是端到端的语音模型，不支持在通话中调用手机工具。需要做事请切换到 DeepSeek 维度或文本工具模式。

**Q：全双工 Key 在哪里填？**
豆包配置中往下拉即可看到。保存后界面不显示是前端策略，数据文件中已经写入。

**Q：视频最大能传多大？**
视频理解通道支持最大 2 GB。托管存储上限 512 MB，超过的会走对象存储（TOS）路径。

**Q：机器翻译的朗读为什么要先下载？**
源码设计为先下载音频、再播放，目的是保证播放完整，并且不容易被浏览器拦截。

### 文件、备份与数据

**Q：文件上传失败怎么办？**
检查网络与存储空间，确认上传会话未超过 1 小时。失败后可以重新上传。

**Q：备份能在别的手机上还原吗？**
可以，但需要同时带上 `ds_master.key`，否则加密配置无法解开。

**Q：`data/` 能删吗？**
删除会丢失全部会话与配置。删除前务必先备份。

### ADB 与设备操控

**Q：必须 root 吗？**
不需要。ADB 通过无线调试的 shell（uid=2000）工作。

**Q：为什么屏幕操作经常失败？**
界面变化、弹窗或加载未完成都会导致操作失败。建议先 `smart_wait` 或 `wait_for_element`，再执行点击。

**Q：会不会误点击广告或弹窗？**
自动化引擎的弹窗处理会尝试关闭弹窗。但它无法区分所有场景，误操作仍可能发生。重要操作前建议确认当前界面。

**Q：屏幕能自动旋转吗？**
本项目把屏幕方向固定为当前方向，不提供修改自动旋转的命令。若需要，请自行在系统设置中操作。

### 安全、授权与贡献

**Q：可以公开部署给别人用吗？**
不建议。服务没有登录认证，只适合本机或可信局域网使用。

**Q：可以 fork 后修改吗？**
源码与旧版文档允许 fork 后二次开发，但要保留原作者署名。

**Q：提示词是否公开？**
旧版说明称，部分提示词是作者的内部资产，未公开。只有明确标注为开源的提示词可以自由使用。你可以编写自己的外部提示词，通过开发者工具注入。

**Q：如何贡献代码？**
提交前请按 [18.7 节](#187-提交前自检) 做静态检查与编译验证，并遵守 [18.6 节](#186-代码风格约定) 的风格约定。

---

## 23. 附录：命令速查

```bash
# ===== 安装与编译 =====
pkg install -y git python dart android-tools
dart compile exe bin/main.dart -o app

# ===== 启动与停止 =====
python3 st.py                   # 前台启动（自动选择 AOT 或 JIT）
python3 st.py --daemon          # 后台守护
python3 st.py --status          # 查看状态
python3 st.py --logs 100        # 查看最近 100 行日志
python3 st.py --stop            # 停止
python3 st.py --restart         # 重启
python3 st.py --rebuild         # 强制重新编译
python3 st.py --no-aot          # 直接用 dart run（不编译）
python3 st.py --install-service # 注册 termux-services
sv status kewe                  # 服务状态（已注册时）

# ===== 环境 =====
export DSH_PORT=9999
export DSH_BASE=/data/data/com.termux/files/home/kewe
export DS_MASTER_KEY=替换为64位十六进制

# ===== ADB 通道 =====
bash adb_up.sh                  # 拉起并校验 uid=2000
adb devices                     # 查看设备列表

# ===== 自动化 =====
python3 auto.py -h
python3 auto.py status
python3 auto.py shot --ocr
python3 doubao_auto.py observe --json

# ===== 维护 =====
python3 ha.py clean --dir data/deepseek_chat/
python3 ha.py export --dir data/deepseek_chat/ --out display/

# ===== 健康检查 =====
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9999/
curl -s http://localhost:9999/api/ds-chat/config | head -c 200; echo

# ===== 静态检查 =====
dart analyze
```

---

## 附录 B：一句话记住这个项目

Kewe 是一个跑在手机 Termux 里的本地三维度大模型界面：DeepSeek 负责推理与对话，豆包负责多模态、语音与生成，ADB 通道让模型在用户授权下操作手机，而所有会话与密钥都留在你自己的设备上。

---

## 24. 架构与请求生命周期

这一章从整体结构出发，说明一次请求从浏览器到模型、再回到浏览器的完整路径。理解它之后，排查问题会容易很多。

### 24.1 分层视图

```
┌──────────────────────────────────────────────────────────────┐
│ 浏览器（index.html + deepseek-chat.js + dsc-*.js ...）        │
└───────────────┬──────────────────────────────────────────────┘
                │ HTTP / SSE / WebSocket（localhost:9999）
┌───────────────▼──────────────────────────────────────────────┐
│ bin/main.dart：路由表 registerRoutes()                        │
│   每条路由包一层：loggerMiddleware → corsMiddleware → handler │
└───────────────┬──────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────┐
│ 业务层 lib/src/                                               │
│   会话 sessions.dart  发送 chat_send.dart  工具 tools.dart    │
│   豆包 doubao*.dart   文件 files.dart      备份 backup.dart   │
└───────┬───────────────────┬──────────────────┬───────────────┘
        │                   │                  │
┌───────▼──────┐   ┌────────▼────────┐  ┌──────▼──────────────┐
│ 存储 data/   │   │ 外部模型 API     │  │ 本机 ADB 通道       │
│ .sts / 加密   │   │ DeepSeek / Ark  │  │ 127.0.0.1:5555      │
│              │   │ 语音 / 翻译 /RTC│  │ auto.py 等          │
└──────────────┘   └─────────────────┘  └─────────────────────┘
```

每一层只依赖下一层，不会反向调用。`globals.dart` 与 `httpsrv.dart` 是几乎所有模块都会引用的基础层。

### 24.2 启动序列

`main()` 的执行顺序如下（与 `bin/main.dart` 一致）：

1. 解析 `.env`（`loadDotEnv`）。已存在的环境变量优先，不会被覆盖。
2. `initDirs()`：创建 `data/` 与 `.backup_tmp/`。
3. 依次初始化各模块的目录：DeepSeek 聊天、公告、展示模型、论坛、单词本、角色扮演、文件管理、工作区、开发者工具。
4. `migrateDsChatToPerSession()`：把旧格式会话迁移为每会话一文件。
5. 注入工具模式的 schema 提供者与执行器（`buildDsTools`、`buildDbTools`、`executeDsTool`）。
6. `registerRoutes()`：注册全部路由。
7. 启动峰谷提醒调度循环（`pvSchedulerLoop`）。
8. 绑定端口。绑定失败时最多重试 10 次，每次间隔 300 毫秒，全部失败才退出。
9. 关闭自动 gzip 压缩，把空闲超时设为 120 秒。
10. 进入 `await for` 循环，逐个请求分派。每个请求在独立的异步任务中处理，单个请求出错不会影响服务。

### 24.3 请求分派

`dispatch(req)` 根据 `req.uri.path` 在 `_routes` 中查找 handler：

- 找到：调用对应 handler。
- 找不到：交给静态资源处理。静态资源处理会按路径读取根目录下的文件，若文件不存在则回退到 `index.html`。
- 静态资源路径经过 `_safeJoin` 规范化：`..` 段会被回退消解，越界的路径不会逃出 `BASE_DIR`。

### 24.4 一次聊天发送的完整链路

以 DeepSeek 维度为例：

```
浏览器 POST /api/ds-chat/send
  │
  ├─ 读取 JSON 请求体（sessionId、content、fileIds、reasoningLevel、工具开关）
  ├─ 解析维度：DS / DB / ST（chat_send.dart 的维度判定函数）
  ├─ 工具模式：tool_gate 记录会话状态，开启请求租约 beginRequest
  ├─ 附件：读取 fileIds 对应的元数据与 blob
  ├─ 模型路由：含图片时视情况切换到视觉模型（model_router.dart）
  ├─ 拼装历史：按条数与字符数上限截断（DS_MAX_HISTORY_MSGS / DS_MAX_HISTORY_CHARS）
  ├─ 跨会话引用：解析 mention 并注入快照（session_ref.dart）
  ├─ 调用 DeepSeek：流式请求，若 400 响应体中提到 stream_options 或 thinking，则去掉对应字段后重试（各最多一次）
  │     ├─ 每个 SSE 分片解析 reasoning_content 与 content
  │     ├─ 工具调用：若模型返回 tool_calls，经闸门检查后执行，结果回填再请求
  │     └─ 循环上限：DS_TOOL_MAX_ITERATIONS
  ├─ 推送增量给浏览器（SSE）
  ├─ 写入 .sts：消息、reasoning、usage
  └─ 结束租约 endRequest，释放会话绑定
```

若中途用户点击停止，服务端会在 `abort-save` 中保存已生成内容，并结束当前请求。

### 24.5 流式解析要点

- DeepSeek 的流以 SSE 形式返回，每行 `data: {...}`，以 `data: [DONE]` 结束。
- `reasoning_content` 与 `content` 分别累积，前端分开渲染。
- 思考链的增量可能以 0.3 至 1.0 秒为单位批量到达（源码注释说明这是服务端攒批所致）。这意味着界面的思考区域会一段一段更新，不是逐字更新。这属于正常现象。
- 工具调用的 `tool_calls` 按 `index` 增量拼接：`id` 与 `name` 出现时记录，参数字符串逐段追加，流结束后再统一解析为 JSON。

### 24.6 HTTP 客户端

`net.dart` 提供共享的 HttpClient：

- 连接超时：10 秒。
- 空闲连接超时：90 秒。
- 每个主机最大连接数：100。
- 自动解压：开启（`autoUncompress`）。
- 代理：按 `PROXY`、`SOCKS5_PROXY`、`ALL_PROXY`、`HTTPS_PROXY`、`HTTP_PROXY` 及其小写形式的顺序探测，并读取 `proxy.conf`。

注意：`dart:io` 的 HttpClient 不支持自定义 SOCKS5 拨号，所以 SOCKS5 配置只会被解析，实际的代理转发只能走 HTTP 代理。若你只有 SOCKS5 代理，需要在本机先把它转换成 HTTP 代理，或者在系统层面做透明代理。

### 24.7 重试策略

| 场景 | 策略 |
| :--- | :--- |
| DeepSeek 返回 400，响应提到 `stream_options`，且请求含该字段 | 去掉该字段后重试一次 |
| DeepSeek 返回 400，响应提到 `thinking`，且请求含该字段 | 去掉该字段后重试一次 |
| 上述两类 400 相继出现 | 最多尝试 3 次，每种各最多去掉一次 |
| 小说模式的单段生成失败 | 每段最多 3 次，失败后等待 3 秒再试 |

其他错误不自动重试。这是为了避免重复计费。

### 24.8 错误处理原则

- 所有失败都如实返回。源码注释中多次强调「绝不伪造成功」。
- 上游错误码会原样或以包装后的 JSON 返回给前端。
- 服务端内部异常会被捕获并记录，返回 500。
- 工具模式下，闸门拒绝的调用会返回明确的拒绝文本，而不是静默忽略。

---

## 25. 版本演进与提交历史

### 25.1 版本号

- `pubspec.yaml`：`version: 2.1.0`
- 程序内部：`kAppVersion = '2.1.0-dart'`
- `bin/main.dart` 中的 `versionInfo()` 会输出 JSON 格式的版本信息。源码注释提到 `--version` 参数，但入口目前没有解析该参数，如需命令行查看，可在 `main` 中自行接入。

### 25.2 从 Go 到 Dart 的迁移

源码中多处注释写明「100% 对齐 Go 版」。这说明本项目经历了从 Go 实现到 Dart 实现的迁移：

- 旧版 README 描述的是 Go 版的启动方式、目录与依赖。
- `st.py` 的头部注释记载，Go 项目（约 14,080 行）被完整改写为 Dart v2.0.0，`go.mod`、`go.sum`、`*.go` 已删除。
- 迁移后，接口路径、数据格式（`.sts`、`DSENC1|` 加密前缀、文件元数据格式）保持不变，以便已有数据可以直接使用。

迁移注意事项：

- 旧的 Go 版编译产物 `app` 与 Dart 版不兼容，升级时需要重新编译。
- 旧版 `st.py` 在 Dart 版中会报错，因为它按 Go 项目的方式检测与编译。当前版本的 `st.py` 已改为 Dart 工具链。

### 25.3 近期提交（节选）

下面列出 `git log` 中较新的提交，便于了解项目近期的变化方向：

| 日期 | 提交说明 |
| :--- | :--- |
| 2026-11-17 | 更新了版本（53e206c） |
| 2026-11-17 | 优化了提示词，改成了中文（d2de012） |
| 2026-11-17 | 更新了最新快照版本（2b4ad8d） |
| 2026-11-16 | 接入了第三方维度，修复了大量漏洞（b5767f1） |
| 2026-11-16 | 增加了计价系统，优化了体验（b715a22） |
| 2026-11-15 | 最新版已发布（088551b） |
| 2026-11-15 | 现在可以直传视频，不需要中转（2744a6d） |
| 2026-11-15 | 播客有损音频变更为无损音频，格式从 mp3 变成 wav（6f82e1c） |
| 2026-11-14 | 最终维护版本，修复众多 bug（340e06c） |

更早的提交包括：增加豆包搜索与抖音百科信源、加入工具模式的自动纠偏机制（后被移除，改为允许模型无限次调用工具）、以及多次版本回退。

### 25.4 关于「播客格式变化」

提交 `6f82e1c` 把播客从 mp3 改为 wav。升级后，旧播客文件仍是 mp3，新生成的是 wav。两者都可以播放，但文件体积差异明显。

### 25.5 关于工具模式的历史修复

历史上存在一个问题：工具模式关闭后，某些关键词仍会触发工具调用。源码 `tool_gate.dart` 的注释记录了修复过程：

1. 前端与后端曾经各自根据关键词「自动打开」工具模式，绕过了用户的开关。
2. 修复后，工具模式的状态只以服务端为准，前端的输入只作为同步信号。
3. 引入请求租约，堵住「上一个请求未解绑、后续调用沿用旧状态」的泄漏路径。

这段历史说明：工具模式的权限边界是有意设计的重点。修改相关代码时，务必保留闸门检查。

### 25.6 关于 ha.py 与 st.py

这两个脚本是对运行环境的补充，不属于主程序。`st.py` 的头部注释记录了它从 Go 版改为 Dart 版的过程。`ha.py` 的注释则说明它是针对聊天记录体积的「外挂」，与主程序解耦。

---

## 26. 分场景操作手册

这一章按使用目的组织内容，每个场景都给出从头到尾的操作步骤。

### 26.1 场景一：只想在手机上和 DeepSeek 聊天

适合人群：只需要文本对话，不需要多模态或工具。

步骤：

1. 按 [第 2 章](#2-快速开始) 完成安装，并启动服务。
2. 在浏览器打开 `http://localhost:9999/`。
3. 进入设置，选择 DeepSeek 维度，填入 DeepSeek API Key，保存。
4. 新建会话，选择 `deepseek-flash`（默认模型）。
5. 发送「你好」，确认能收到流式回复。
6. 在会话列表中确认会话已出现。
7. 切换到其他应用，再回到浏览器，确认会话仍在。

校验：

```bash
curl -s http://localhost:9999/api/ds-chat/sessions | head -c 300
```

若返回的 JSON 中包含刚建的会话，场景完成。

### 26.2 场景二：让模型读一张图片

步骤：

1. 确认服务运行，且 DeepSeek 维度已配置。
2. 新建会话，选择任意模型。发送含图片的消息时，模型路由会自动选择视觉模型，或者你可以直接选择 `deepseek-flash`。
3. 通过附件按钮选择图片，并输入问题，例如「这张图里有什么」。
4. 发送，等待回复。

校验：回复内容应与图片内容相关。若模型回答与图片无关，检查模型路由设置，确认当前模型支持图片输入。

### 26.3 场景三：处理一个大文件

适合人群：需要上传超过普通附件大小的文件（如 500 MB 的视频）。

步骤：

1. 确认文件不超过 5 GB。
2. 在界面中选择文件管理，上传文件。前端会自动拆分为 64 MB 分片。
3. 上传完成后，文件出现在文件列表中，并分配文件 ID。
4. 在对话中引用该文件 ID 发送。若是视频，使用豆包维度的视频理解通道（最大 2 GB）。

校验：

```bash
curl -s http://localhost:9999/api/ds-files/list | head -c 500
```

确认文件记录中的大小与原文件一致。

异常处理：上传到一半中断，可以重新发起上传。超过 1 小时的上传会话会被清理，需要从头开始。

### 26.4 场景四：让手机自动完成一件小事

适合人群：想让模型通过 ADB 通道在手机上执行一连串操作，例如打开某个应用并截图。

步骤：

1. 按 [10.2 节](#102-一次性设置开启无线调试) 开启无线调试。
2. 在 Termux 中执行 `bash adb_up.sh`，确认输出 `uid=2000`。
3. 在界面中开启工具模式。
4. 在对话中描述任务，例如「打开设置，截一张图」。
5. 观察模型调用的工具，每一步都应当在界面中可见。
6. 任务完成后关闭工具模式。

校验：

```bash
python3 auto.py status
python3 auto.py current
```

确认 `current` 显示的前台应用与任务预期一致。

风险提示：工具模式会真实操作手机。任务开始前先确认界面状态，不要在含有重要数据的界面执行删除、支付、发送等操作。

### 26.5 场景五：把豆包当成多模态工具用

步骤：

1. 在豆包配置中填入方舟 API Key。若需要语音，同时填写语音相关 Key。
2. 新建豆包维度会话，选择合适的文本模型（lite 档适合日常聊天，pro 档适合工具编排）。
3. 需要生图时，调用 `/api/doubao/image`，或在界面中选择生图功能。
4. 需要视频理解时，通过视频理解通道上传视频，并用 `/api/doubao/video/status` 查询进度。

校验：生图接口返回的结果中应包含图片地址或数据；视频任务状态从「处理中」变为完成。

### 26.6 场景六：生成一段播客

步骤：

1. 在豆包配置中确认语音相关 Key 已填写。
2. 调用 `/api/doubao/podcast/sse` 提交主题或文本素材。
3. 观察 SSE 事件流，每段台词以 `speaker` 为 A 或 B 标识。
4. 生成完成后，音频文件以 wav 格式保存。

校验：返回的台词数组中每句不超过 120 字，发言人只有 A 与 B 两种。

### 26.7 场景七：定期备份

步骤：

1. 设定备份频率（建议每周一次）。
2. 每次备份前，确认服务没有正在进行的请求。
3. 执行备份接口或手动打包。
4. 将备份存放在手机之外的安全位置。注意备份中包含主密钥。
5. 每隔一段时间抽样还原到临时目录，确认备份可用。

校验：

```bash
tar -tzf kewe-backup.tar.gz | head -20
```

确认包内包含 `deepseek_chat/`、`ds_files/` 等目录。

### 26.8 场景八：在后台长期运行

步骤：

1. 执行 `python3 st.py --daemon`。
2. 在 Termux 通知栏确认 Termux 正在运行。
3. 将 Termux 从电池优化中排除（系统设置中找到 Termux，设为不受限制）。
4. 如果需要，执行 `python3 st.py --install-service` 注册服务。
5. 每天检查一次 `python3 st.py --status`。

校验：

```bash
python3 st.py --status
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9999/
```

### 26.9 场景九：从旧版迁移数据

步骤：

1. 在旧环境中打包 `data/` 目录。
2. 在新环境中确保 Dart 版程序可以启动。
3. 把备份还原到 `data/`，或者直接复制 `data/` 目录。
4. 启动服务。会话迁移（`migrateDsChatToPerSession`）会自动执行。
5. 检查会话列表与配置是否正常。

校验：会话数量与旧环境一致；配置可以解密（即 `ds_master.key` 也已迁移）。

---

## 27. 术语表

| 术语 | 含义 |
| :--- | :--- |
| 维度 | 一条独立的模型通道，目前包括 DeepSeek（DS）、豆包（DB）与中转站（ST） |
| 会话（session） | 一组连续的对话消息，保存为一个 `.sts` 文件 |
| 消息（message） | 会话中的一条用户或助手内容 |
| reasoning / 思考链 | 模型在给出回答前的推理内容，与正文分开保存 |
| 工具模式 | 允许模型调用手机工具的功能，由 `tool_gate.dart` 控制 |
| 请求租约 | 工具模式在一次请求期间的临时授权，请求结束即失效 |
| 闸门（gate） | 工具执行前的检查点，拒绝未授权的调用 |
| 档位（tier） | 豆包工具模式按模型能力划分的工具集等级：lite、turbo、pro、special、none |
| 分片（chunk） | 大文件上传时拆分的一段数据，默认 64 MB |
| 元数据（meta） | 描述文件信息（名称、大小、类型等）的记录，保存在 `meta/` |
| 主密钥（master key） | 用于加密 API Key 等配置的 32 字节密钥 |
| DSENC1 | 加密配置的前缀标识，格式为 base64(nonce ∥ 密文 ∥ tag) |
| .sts | 本项目使用的按行管道分隔文本格式，用于会话与元数据 |
| 峰谷提醒 | 按 DeepSeek 官方峰谷时段推送通知的功能 |
| 中转站（relay） | OpenAI 兼容的第三方接口服务 |
| ADB 通道 | 通过无线调试连接的 shell 通道，权限为 uid=2000 |
| uid=2000 | Android 的 shell 用户标识，ADB 通道的运行身份 |
| wake lock | 防止 CPU 休眠的锁，由 `termux-wake-lock` 获取 |
| SSE | Server-Sent Events，服务端向浏览器单向推送的事件流 |
| 全双工 Key | 豆包实时语音通话所需的专用密钥 |
| 端到端语音 | 语音输入直接由模型处理，不经过单独的识别与合成步骤 |
| 音声生成 | SeedAudio1.0 模型的功能，生成场景音或广播剧，不同于传统 TTS |
| 峰谷时段 | DeepSeek 按时段定价的区间，高峰与低谷价格不同 |
| 命中（hit）/ 未命中（miss） | 输入 token 是否命中服务商的缓存，两者单价不同 |

---

## 28. 设计决策说明

这一章记录源码中体现的主要设计取舍，方便二次开发者理解「为什么这样做」。

### 28.1 零第三方依赖

项目不引入任何 pub 包。理由是：

- 降低供应链风险。
- `dart run bin/main.dart` 即可启动，不需要 `pub get`。
- 在 Termux 中，第三方包的原生编译可能失败。

代价是：HTTP、加密、压缩、tar 都需要自己实现（`aes_gcm.dart`、`sha256.dart`、`backup.dart`）。

### 28.2 单文件会话存储

每个会话一个 `.sts` 文件，而不是数据库。理由是：

- 不依赖数据库引擎，备份与迁移只需复制文件。
- 文本格式便于用 `grep`、`awk` 检查。
- 单个会话损坏不会影响其他会话。

代价是：会话很大时，读取与搜索都会变慢。搜索通过内存缓存部分弥补。

### 28.3 配置加密而非内容加密

只加密 API Key 等配置，不加密会话内容。理由是：

- 会话内容需要被搜索、被脚本处理，加密后会失去这些能力。
- 主密钥与数据放在同一设备上，加密主要防止误泄露（如截图、同步盘），而不是防止设备被攻破。

如果你的威胁模型需要加密会话内容，需要自行修改存储层。

### 28.4 工具模式的服务端状态

工具模式的开关只以服务端为准。理由是：前端状态可以被伪造或误判，只有服务端能可靠地决定是否执行危险操作。

### 28.5 关闭自动 gzip

源码注释说明，自动压缩会缓冲 SSE 流，导致思考链一直不推进。因此关闭压缩，牺牲一点传输体积换取流式的及时性。

### 28.6 不估算费用

计费只使用服务商返回的真实用量。理由是：估算的数字容易误导用户，而真实用量来自服务商，更可信。未定价的模型只显示用量，不显示费用。

### 28.7 视频走对象存储

超过 512 MB 的视频不能走托管文件接口，而要走对象存储（TOS）。理由是：把 2 GB 视频转成 base64 放进 JSON 会导致内存溢出。

### 28.8 播客与翻译的音频：先下载再播放

理由是：流式播放容易被浏览器拦截或中途卡顿，先完整下载再播放更可靠。代价是需要等待下载完成。

### 28.9 会话格式的转义

`.sts` 的字段转义采用 `\p`、`\n`、`\\`。理由是：保持每条记录为一行，便于按行读取、追加与脚本处理。

### 28.10 不做语音合成

作者在旧版说明中解释，不做传统语音合成是「不想做」，并非技术无法实现。原因包括需要额外依赖，以及已有端到端语音与音声生成能力。

---

---

## 29. 接口请求体详解

这一章针对需要直接调用 HTTP 接口的读者。每个示例的字段都来自对应 handler 的源码读取位置。未在源码中出现的字段不会列出。

### 29.1 中转站配置

字段（来自 `relay.dart`）：

| 字段 | 类型 | 说明 |
| :--- | :--- | :--- |
| `baseUrl` | 字符串 | OpenAI 兼容的基础地址，须包含 `/v1` |
| `apiKey` | 字符串 | 中转站 Key，保存为明文 JSON |
| `customModels` | 字符串数组 | 自定义的模型名列表，用于补充拉取不到的模型 |

保存配置：

```bash
curl -s -X POST http://localhost:9999/api/relay/config \
  -H "Content-Type: application/json" \
  -d '{
    "baseUrl": "https://example-relay.invalid/v1",
    "apiKey": "替换为你的中转站Key",
    "customModels": ["gpt-4o-mini"]
  }'
```

示例中的域名是占位符，请替换为你实际使用的中转站地址。

拉取模型列表：

```bash
curl -s http://localhost:9999/api/relay/models
```

注意：`GET /api/relay/config` 返回的内容不应包含明文 Key。如果你发现返回里有 Key，请检查接口实现是否被修改。

### 29.2 角色库（Cosplay）

字段（来自 `cosplay.dart`）：

| 字段 | 说明 |
| :--- | :--- |
| `action` | 动作类型，决定执行新增、更新、切换、删除等操作 |
| `id` | 角色 ID，更新、切换、删除时使用 |
| `role` | 角色设定（身份与背景） |
| `style` | 说话风格 |
| `neutral` | 中立 / 默认状态的设定，源码中保留为独立字段 |

示例（新增或更新角色）：

```bash
curl -s -X POST http://localhost:9999/api/ds-cosplay \
  -H "Content-Type: application/json" \
  -d '{
    "action": "upsert",
    "id": "guide-01",
    "role": "一位耐心的编程导师，专门解答 Dart 相关问题。",
    "style": "简洁，先给结论再给例子。"
  }'
```

`action` 的具体取值以 `handleDsCosplay` 中的分支为准。若取值错误，接口会返回错误，而不是静默忽略。

角色扮演属于对话风格层面的设置。它不会关闭工具模式的安全闸门，也不改变模型的基本行为准则。

### 29.3 论坛帖子

字段（来自 `forum.dart`）：

| 字段 | 说明 |
| :--- | :--- |
| `id` | 帖子 ID |
| `title` | 标题 |
| `content` | 正文 |
| `author` | 作者名 |
| `summary` | 摘要 |
| `createdAt` / `updatedAt` | 时间戳 |
| `action` | 对帖子的操作类型 |
| `ids` | 批量删除时的 ID 数组 |

示例（查询单条帖子）：

```bash
curl -s "http://localhost:9999/api/forum/posts/detail?id=替换为帖子ID"
```

删除多条帖子：

```bash
curl -s -X POST http://localhost:9999/api/forum/posts/delete \
  -H "Content-Type: application/json" \
  -d '{"ids": ["id-1", "id-2"]}'
```

删除是不可撤销的操作。源码中没有回收站，执行前请确认。

### 29.4 公告

字段（来自 `announcements.dart`）：

| 字段 | 说明 |
| :--- | :--- |
| `id` | 公告 ID |
| `title` | 标题 |
| `content` | 正文 |
| `startTime` | 生效开始时间 |
| `endTime` | 生效结束时间 |

`/api/announcements/active` 只返回当前时间处于 `startTime` 与 `endTime` 之间的公告。界面顶部的公告条使用这个接口。

### 29.5 单词本

字段（来自 `vocab.dart`）：

| 字段 | 说明 |
| :--- | :--- |
| `word` | 单词原文 |
| `reading` | 读音（假名） |
| `pitch` | 音调 |
| `pos` | 词性 |
| `meaning` | 释义 |
| `example` | 例句 |
| `level` | 等级 |
| `tags` | 标签 |
| `image` | 配图（文件名或引用） |
| `createdAt` / `updatedAt` | 时间戳 |
| `lastReviewedAt` / `nextReviewAt` | 复习相关时间，用于复习调度 |

复习调度依据 `nextReviewAt` 决定下一次复习的时间。`/api/vocab/review` 返回到期需要复习的词条。

### 29.6 自定义显示模型

字段（来自 `displaymodels.dart`）：

| 字段 | 说明 |
| :--- | :--- |
| `id` | 显示模型的标识 |

显示模型用于在界面的模型列表中增加自定义名称。单个名称长度受 `DM_MAX_FILE_RUNES`（80 个字符）限制。

### 29.7 豆包配置与模型

- `GET /api/doubao/models`：返回 `dbModelCatalog` 登记的模型，每个条目包含标识、显示名与类别。
- `GET` / `POST /api/doubao/config`：读取或保存豆包配置。读取时不返回明文密钥。

### 29.8 开发者提示词

`/api/ds-devtools/prompts` 支持读取与保存注入的提示词，作用于 system 角色。它的典型用途是：

- 写一段自定义的系统提示词，覆盖或补充界面默认行为。
- 在不修改源码的前提下，调整模型的语气与格式。

提示词保存在 `data/deepseek_chat/devtools/inject_prompts`。

注意：注入的提示词会直接影响模型行为，包括工具模式的使用倾向。注入前请逐条检查，尤其要避免写入鼓励模型绕过确认步骤的内容。

---

## 30. 逐模块参考说明

这一章按源码文件逐个说明职责、主要函数与使用注意事项。它适合在阅读或修改某一模块时查阅。

### 30.1 globals.dart

职责：全局路径、环境变量读取、文本转义、时间格式和日志。

要点：

- `BASE_DIR`：项目根目录，可用 `DSH_BASE` 覆盖。
- `DATA_DIR`、`BACKUP_TMP_DIR`：由 `BASE_DIR` 派生。
- `PORT`：由 `DSH_PORT` 决定，默认 9999。
- `MAX_UPLOAD_SIZE`：常量 50 TB，表示源码层面不做硬性限制。实际限制来自磁盘与文件模块的 `DS_MAX_FILE_SIZE`（5 GB）。
- `logp`：统一日志函数，应优先使用它而非 `print`。

### 30.2 httpsrv.dart

职责：HTTP 辅助层，包括静态资源、CORS、JSON 响应、请求体读取与日志中间件。

要点：

- `loggerMiddleware`：记录每个请求的方法、路径与耗时，格式为「方法 路径 耗时毫秒」。
- `corsMiddleware`：设置 CORS 响应头，并对 OPTIONS 预检请求直接返回。
- `readJsonBody`：读取并解析 JSON 请求体。超过 `limit` 会报错。
- `readBodyBytes` / `readBodyText`：读取原始字节或文本。
- `jsonResponse` / `jsonRaw`：返回 JSON。
- `errJson`：返回带错误信息的 JSON。
- 静态资源：路径经 `_safeJoin` 规范化，不存在时回退到 `index.html`。

### 30.3 net.dart

职责：共享的 HttpClient 与代理探测。

要点：

- 两个工厂函数分别为普通请求与流式请求创建客户端，参数略有不同。
- 代理解析结果缓存在 `_proxyCache` 中，首次调用后不再重复探测。
- 代理探测来源：环境变量与 `proxy.conf`。

### 30.4 sha256.dart 与 aes_gcm.dart

职责：纯 Dart 的摘要与对称加密。

要点：

- `sha256.dart` 提供 SHA-256 与 HMAC-SHA256，用于 TTS 签名等场景。
- `aes_gcm.dart` 提供 AES-256 的单块加解密，并用 CTR 模式串联实现 GCM。密钥长度必须是 32 字节，否则抛出 `ArgumentError`。
- 文件中包含 FIPS-197 的标准测试向量，可用于验证实现。

注意：自行实现的加密代码应当经过审阅。如果你要用于高安全场景，建议替换为经过审计的成熟实现。

### 30.5 ds_crypto.dart

职责：主密钥管理、AES-256-GCM 封装与配置读写。

要点：

- `getOrCreateMasterKey()`：获取或生成主密钥，结果缓存在进程内。
- `dsEncrypt` / `dsDecrypt`：加密与解密字符串，格式为 `DSENC1|` 前缀加 base64。
- `dsConfigEncPrefix` 常量：`DSENC1|`。
- `DS_DEFAULT_MODEL`：默认模型名，当前为 `deepseek-flash`。

### 30.6 sessions.dart

职责：会话与消息的 `.sts` 存储。

要点：

- 每个会话一个文件，位于 `data/deepseek_chat/sessions/`。
- 行格式：`#S` 为会话头，`#M` 为消息。
- 字段转义与还原：`escDs` 与 `unescDs`。
- 常量：`DS_TTS_MAX_RUNES`（100 万）与 `DS_TTS_CHUNK_RUNES`（2500），用于朗读分段。
- 迁移函数 `migrateDsChatToPerSession` 在启动时运行。

### 30.7 chat_handlers.dart

职责：会话、消息与配置的基础接口。

要点：

- 维度判定辅助函数会根据请求中的维度字段，或根据模型名回退判定。
- 中止与保存的处理位于 `handleDsChatAbortSave`。
- 测试接口 `handleDsChatTest` 只接受 POST，用于验证 Key 与模型的连通性。

### 30.8 chat_send.dart

职责：发送消息、SSE 流式、小说模式、续写。

要点：

- 维度判定函数：若模型属于中转站，返回 ST；若属于豆包聊天模型，返回 DB；否则返回 DS。
- 工具循环上限：DeepSeek 通道使用 `DS_TOOL_MAX_ITERATIONS`，中转站与豆包使用各自的上限。
- 消息的 `fileIds` 会解析为文件元数据，再注入上下文。
- `reasoningLevel` 默认值为 1。

### 30.9 deepseek_api.dart

职责：DeepSeek 官方 API 调用层。

要点：

- 常量 `DS_API_URL` 指向 `https://api.deepseek.com/chat/completions`。
- 流式解析按 SSE 逐行读取，区分 `reasoning_content` 与 `content`。
- 400 错误时按条件去掉 `stream_options` 或 `thinking` 后重试。
- 包含 `DS_TOOL_AGENT_SYSTEM_PROMPT` 等系统提示词常量（源码中多为日语原文，见 [21.2 节](#212-日语残留)）。
- 小说模式的分段生成包含重试逻辑：每段最多 3 次。

### 30.10 model_router.dart

职责：根据内容与模型能力，选择是否切换到视觉模型。

要点：

- `MR_VERSION`：当前规则版本，为 `mr1`。
- 内置视觉模型集合、内置纯文本模型集合，以及第三方视觉关键字列表。
- 规则可以在界面中补充，保存在 `model_router.sts`。
- 名称匹配不区分大小写，并把下划线替换为连字符后比较。

### 30.11 session_ref.dart

职责：跨会话引用（mention）的解析与快照注入。

要点：

- 引用的目标会话只读，不会被修改。
- 快照大小受 `DS_REF_MAX_SNAPSHOT_BYTES` 限制，引用数量受 `DS_REF_MAX_REFERENCES` 限制。

### 30.12 search.dart

职责：会话全文搜索。

要点：

- 搜索结果支持游标分页。
- 内存缓存在服务启动后按需构建。
- 大量会话时首次搜索较慢，属于预期行为。

### 30.13 ds_usage.dart 与 token_cost.dart

职责：记录每条回复的真实用量，并按价目表换算为人民币。

要点：

- 用量来自服务商返回的 `usage` 字段，不做估算。
- `_PRICE` 为精确匹配表，`_PRICE_PREFIX` 为前缀匹配表（用于带日期后缀的模型名）。
- `_HOLIDAYS` 为节假日表，用于峰谷判定。需要定期补充新年份的节假日。

### 30.14 tools.dart

职责：工具模式的 schema 与执行器。

要点：

- `buildDsTools()`：返回全部工具定义，使用 `fnTool` 与 `objSchema` 构造。
- `executeDsTool(name, args)`：按名称分派执行，每个分支内部都会检查闸门。
- `dsWorkspaceDir`：工具操作的工作区路径，优先 `DS_WORKSPACE`，其次 `HOME`，最后 `/`。
- 默认值常量：命令超时 30 秒（最大 86400 秒），滑动时长 150 毫秒，长按时长 600 毫秒。
- 源码中 `shizukuDisabled = true`，相关工具不可用。

### 30.15 tool_gate.dart

职责：工具模式的统一闸门。

要点：

- 会话工具状态集中保存在 `_modeBySession`。
- 请求租约通过 `beginRequest` 与 `endRequest` 管理。
- `check` 用于外层，`checkInner` 用于内层，两者不能混用。
- `diag()` 输出闸门状态，便于排查「为什么工具没有执行」。

### 30.16 doubao.dart

职责：火山方舟（豆包）的核心接入，包括文本、图片、音频、播客、语音识别、会话等。

要点：

- `dbModelCatalog`：模型登记表，是模型分类的唯一来源。
- `dbIsChatModel`：判断某模型是否为聊天模型。
- 配置读写与模型列表接口。
- 文件规模超过 2000 行，修改前建议先读懂其中的分组注释。

### 30.17 doubao_tools.dart

职责：豆包专属工具模式，决定各模型档位可用的工具。

要点：

- `dbToolProfileOf(model)`：根据模型名返回档位配置，包括最大轮数、最大工具数、是否允许联网插件混用、是否允许媒体、是否允许自动化。
- `buildDbTools(model)`：按档位裁剪工具集。
- `dbIsDoubaoModel(model)`：判断模型是否属于豆包系列。
- `dbToolCountOf(model)`：返回当前档位的工具数量。

### 30.18 doubao_video_ark.dart

职责：大视频理解通道。

要点：

- 托管存储（Files API）限制 512 MB。
- 对象存储（TOS，默认 `tos-cn-beijing.volces.com`）限制 2 GB。
- 避免把大视频整体读进内存，源码注释说明 2 GB 视频若走 base64 会导致 OOM。
- 视频任务异步执行，通过状态接口轮询。

### 30.19 doubao_realtime.dart

职责：端到端实时语音（Seeduplex）与 RTC 任务。

要点：

- WebSocket 地址：`wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue`。
- 音色的保存、列表、删除、清空接口位于此文件。
- `handleDbVoiceList` 只接受 GET，其他方法返回 405。

### 30.20 doubao_thinking.dart

职责：豆包深度思考的输出优化。

要点：该模块整理思考链输出，减少界面渲染压力。具体规则以源码为准。

### 30.21 doubao_translate.dart

职责：机器翻译与本地术语表。

要点：

- 接口：`https://openspeech.bytedance.com/api/v3/machine_translation/matx_translate`。
- 术语表目录：`data/body_text`，每行一条，字段用 `|` 分隔。
- 术语表的增删改查有独立接口。

### 30.22 doubao_wiki.dart

职责：豆包联网内容插件（抖音百科、头条图文等信源）。

要点：

- 信源常量包括 `douyin` 与 `toutiao`。
- 调用经由 `/api/v3/responses`，并非普通的函数调用。
- 显式选择信源时，工具模式会先关闭，再只开启该信源，这是为了遵守闸门的一致性规则。

### 30.23 doubao_intent.dart

职责：已停用的意图识别模块。

要点：源码头部标注为 DISABLED。保留该文件是为了便于回溯，当前版本不会被调用。

### 30.24 tts_edge.dart 与 tts_drm.dart

职责：Microsoft Edge TTS 的 WebSocket 流式合成，以及 Sec-MS-GEC v2 签名。

要点：

- `tts_drm.dart` 负责生成请求签名，依赖 `sha256.dart` 中的哈希函数。
- `tts_edge.dart` 建立 WebSocket 连接，流式接收音频。
- 朗读长文本时按 2500 字符分段（见 `sessions.dart` 中的常量）。

注意：`tts_edge.dart` 依赖外部服务，服务不稳定时朗读会失败。旧版说明已将 TTS 列为不再保障的功能。

### 30.25 files.dart

职责：文件管理的分片上传、下载、列表、删除。

要点：

- 分片大小 64 MB，单文件上限 5 GB。
- 上传会话在 1 小时后过期，孤立分片在 30 分钟后清理。
- 元数据按月分文件。
- 请求体限制为分片大小加 64 KB，防止过大的分片占用内存。

### 30.26 backup.dart

职责：备份（tar.gz 打包）与还原（multipart 上传解压）。

要点：

- 生成的 tar 为 ustar 格式，与 Go 版兼容。
- 还原时会覆盖同名文件。
- 备份中包含 `ds_master.key`，传输与保存时需要保护。

### 30.27 forum.dart、vocab.dart、cosplay.dart、announcements.dart

分别是论坛、单词本、角色库与公告，见 [第 13 章](#13-论坛单词本角色扮演公告峰谷提醒x-推文)。

### 30.28 peakvalley.dart

职责：峰谷时段判定、模板渲染、七种推送渠道与定时调度。

要点：

- 阶段常量：`peak` 与 `valley`。
- 时区使用内置的固定偏移与夏令时规则，不依赖 IANA 数据库。
- 推送模板中的占位符包括 `{phase}`、`{start}`、`{end}`、`{time}`。
- 推送渠道在 `switch` 中分支实现，包括 serverchan、bark、dingtalk、wecom 等。

### 30.29 xtweet.dart

职责：X（推特）推文抓取。

要点：多个后端并发请求，采用最先返回的结果。失败时如实返回错误。

### 30.30 virtual_display.dart

职责：虚拟屏幕（副屏）的创建、操作与截图。

要点：

- 默认尺寸 720×1280，密度 320。
- 通过 `overlay_display_devices` 全局设置创建副屏，displayId 由系统分配。
- 副屏截图只能通过截图 OCR 获取文字，因为 uiautomator 不支持副屏。

### 30.31 doubao_auto.py 与 auto.py 的内部结构

- 底座：`_sh`（调用 adb）、`run`（带重试的执行）、`ensure`（掉线重连）。
- 输入：`input_text` 按字符集选择方案。纯 ASCII 且无特殊字符时直接用 `input text`，否则走 ADB Keyboard 或剪贴板。
- 查找：`dump` 把界面导出到 `/sdcard/auto_dump.xml`，再解析为控件树。

注意：`auto.py` 的 `DUMP_PATH` 指向 `/sdcard/auto_dump.xml`，该文件由脚本生成，属于脚本自身的临时文件。

### 30.32 st.py、ha.py、adb_up.sh

分别见 [第 5 章](#5-启动停止与后台运行)、[第 17 章](#17-辅助脚本stpy-与-hapy) 与 [10.3 节](#103-拉起通道adb_upsh)。

---

## 31. 按问题类型的排查流程

这一章把第 20 章的故障表扩展为完整的排查步骤。每一步都有明确的判断依据。

### 31.1 服务无法启动

1. 确认当前目录与 `BASE_DIR`：`pwd` 与 `echo $DSH_BASE`。
2. 确认 Dart 可用：`dart --version`。
3. 确认端口未被占用：`ss -lntp | grep 9999`（若没有 `ss`，可用 `netstat -lntp`）。
4. 执行 `dart run bin/main.dart`，观察输出。
   - 若提示端口绑定失败，说明旧进程未退出，执行 `python3 st.py --stop` 后重试。
   - 若提示语法错误，说明代码有改动，执行 `dart analyze` 查看具体位置。
5. 若需要更详细的信息，设置 `DSH_DEBUG=1` 后重新启动。

### 31.2 页面能打开但发送无回应

1. 检查 DeepSeek 配置：`curl -s http://localhost:9999/api/ds-chat/config`。
2. 使用测试接口：`curl -s -X POST http://localhost:9999/api/ds-chat/test`。该接口会用当前配置发起一次最小请求。
3. 若测试失败，查看返回的错误信息：
   - 认证失败：重新填写 Key。
   - 网络错误：检查代理设置。
   - 模型错误：核对模型名。
4. 若测试通过但发送仍无回应，查看日志：`python3 st.py --logs 100`。
5. 若界面卡在「思考」，检查是否经过了会压缩 SSE 的中间代理。

### 31.3 工具模式开启但模型没有调用工具

1. 确认工具模式在界面中已开启。
2. 确认当前模型支持工具调用。豆包的 `special` 档（视觉、语音）不做函数调用编排。
3. 查看闸门状态：`diag()` 的输出会说明会话绑定与租约情况。
4. 查看模型回复中是否有工具调用的尝试，但被拒绝的文本。若有，说明闸门拦截了调用，需要检查授权流程。
5. 若模型根本没有尝试调用，尝试在提示中明确描述需要执行的操作。

### 31.4 ADB 工具报错

1. 执行 `bash adb_up.sh`，确认通道状态。
2. 若输出未连接，检查无线调试是否开启，端口是否为 5555。
3. 若通道已连接但工具报错，执行 `python3 auto.py status` 与 `python3 auto.py current`，确认设备在线且前台应用正确。
4. 若界面操作失败，先执行 `python3 auto.py dump` 查看当前界面控件，再决定点击坐标或文本。
5. 若输入中文失败，检查 ADB Keyboard 是否已安装并启用。

### 31.5 数据看起来丢失

1. 先确认不是显示问题：刷新页面，或重启服务。
2. 检查 `data/deepseek_chat/sessions/` 下是否有对应的 `.sts` 文件。
3. 若文件存在但界面不显示，检查 `.sts` 格式是否完整（每行以 `#S` 或 `#M` 开头）。
4. 若文件不存在，检查最近是否执行过还原或清理操作。
5. 从备份中恢复时，先把当前 `data/` 另存一份，再还原。

### 31.6 计费数字异常

1. 确认模型名是否在计价表中。不在表中时，界面只显示用量。
2. 对照 [14.2 节](#142-计价口径) 的价目，手工计算一次。
3. 检查是否命中缓存：缓存命中与未命中的单价差异很大。
4. 检查是否属于峰谷时段，部分模型有时段倍率。
5. 以服务商账单为准。若账单与本地估算差异较大，可能是价目表过期，需要更新 `token_cost.dart`。

### 31.7 文件上传反复失败

1. 检查文件大小是否超过 5 GB。
2. 检查存储空间：`df -h ~`。
3. 检查上传会话是否超时（1 小时）。
4. 检查分片是否按顺序上传，且每个分片不超过 64 MB。
5. 清理孤立分片需要等待 30 分钟，或删除 `chunks/` 中对应的残留文件（仅删除本次上传生成的文件）。

### 31.8 后台服务意外退出

1. 查看日志：`python3 st.py --logs 200`。
2. 检查 Termux 是否被系统杀掉：查看通知栏，确认 Termux 是否仍在运行。
3. 关闭电池优化，并确认 `termux-wake-lock` 已获取。
4. 若频繁退出，考虑注册为 termux-services 服务，由 runit 监督重启。

---

## 32. 按人群的入门路线

这一章给出不同背景读者的推荐阅读顺序。

### 32.1 只想用的普通用户

推荐阅读顺序：

1. [第 1 章](#1-项目概览)：了解项目能做什么。
2. [第 2 章](#2-快速开始)：完成安装。
3. [第 6 章](#6-网页界面使用教程)：熟悉界面。
4. [第 7 章](#7-deepseek-维度) 或 [第 8 章](#8-豆包维度)：选择一个维度开始使用。
5. [第 14 章](#14-计费与用量统计)：了解费用。
6. [第 19 章](#19-安全与隐私)：了解隐私与安全。

暂时可以跳过的内容：第 16 章（API）、第 18 章（二次开发）、第 24 章（架构）。

### 32.2 想开启手机自动化的用户

推荐阅读顺序：

1. [第 9 章](#9-工具模式与安全闸门)：理解工具模式的边界。
2. [第 10 章](#10-adb-自动化引擎)：完整掌握 ADB 通道。
3. [第 26.4 节](#264-场景四让手机自动完成一件小事)：跟随示例操作。
4. [第 31.4 节](#314-adb-工具报错)：排查 ADB 问题。
5. [第 19 章](#19-安全与隐私)：务必阅读风险部分。

### 32.3 想调用 API 的开发者

推荐阅读顺序：

1. [第 16 章](#16-http-api-参考)：接口清单。
2. [第 29 章](#29-接口请求体详解)：请求体字段。
3. [第 24 章](#24-架构与请求生命周期)：理解请求链路。
4. [第 30 章](#30-逐模块参考说明)：查阅模块细节。
5. [第 18 章](#18-二次开发指南)：开始修改代码。

### 32.4 想参与开发的贡献者

推荐阅读顺序：

1. [第 3 章](#3-目录结构)：目录结构。
2. [第 24 章](#24-架构与请求生命周期)：架构。
3. [第 28 章](#28-设计决策说明)：设计取舍。
4. [第 18 章](#18-二次开发指南)：开发约定。
5. [第 25 章](#25-版本演进与提交历史)：版本历史。

修改前必须做的事：

- 先 `dart analyze`，确保无静态错误。
- 修改工具模式相关代码时，确认闸门检查没有被绕过。
- 修改存储格式时，确认旧数据仍可读取。

---

## 33. 更新与维护操作

### 33.1 更新代码

```bash
cd ~/kewe
git status                 # 确认没有未提交的改动，或先备份
git pull --ff-only         # 只允许快进合并，避免意外覆盖
python3 st.py --rebuild    # 重新编译
python3 st.py --restart    # 重启服务
```

说明：

- `--ff-only` 可以避免在本地有改动时产生冲突。若拉取失败，先处理本地改动，不要强制覆盖。
- 更新前备份 `data/`。

### 33.2 更新前的备份

```bash
cd ~/kewe
tar -czf ~/kewe-data-pre-update-$(date +%Y%m%d).tar.gz data
```

### 33.3 清理编译产物

若需要释放空间，可以删除旧的编译产物。这里只删除项目根目录下的 `app`，且只在确认不需要它时执行：

```bash
cd ~/kewe
ls -l app          # 先确认文件
rm -f app          # 确认后再删除，之后可用 st.py --rebuild 重新生成
```

`rm -f app` 只针对项目自己生成的编译产物，不要用通配符批量删除其他文件。

### 33.4 检查磁盘占用

```bash
du -sh ~/kewe/data                    # 数据总大小
du -sh ~/kewe/data/ds_files           # 文件管理占用
du -sh ~/kewe/data/vocab              # 单词本占用
du -sh ~/kewe/.backup_tmp             # 备份临时目录（应当很小）
```

若 `.backup_tmp` 占用较大，说明备份过程被中断，可以在确认没有备份进程运行后手动检查其中的文件。

### 33.5 健康巡检清单

每周执行一次：

- [ ] `python3 st.py --status` 显示运行正常
- [ ] `curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9999/` 返回 200
- [ ] 最近一次备份时间在一周以内
- [ ] 磁盘剩余空间充足（建议至少 2 GB）
- [ ] 最近的日志中没有反复出现的错误
- [ ] Key 的额度与账单正常

### 33.6 卸载

1. 停止服务：`python3 st.py --stop`。
2. 如已注册服务：`python3 st.py --remove-service`。
3. 备份 `data/`，确认备份可用。
4. 删除项目目录前，再次确认备份文件存在。

只有在确认备份后，才可以删除项目目录。删除 `data/` 会丢失全部会话与配置。

---

## 34. 术语补充与常见误解

### 34.1 常见误解

**误解一：Kewe 是一个在线服务。**
不是。它只在你的手机上运行，没有云端服务器。数据只存在本机。

**误解二：开启工具模式后模型就能随意操作手机。**
不是。工具调用必须经过服务端闸门检查。工具模式的状态以服务端为准，前端开关不是充分条件。

**误解三：豆包语音通话可以一边聊天一边让模型操作手机。**
不能。语音通话是端到端语音模型，不支持在通话中调用工具。

**误解四：只要有 Key 就能用所有功能。**
不是。豆包的语音、翻译、音频等功能各需要额外的 Key 与额度。

**误解五：`app` 可以在任何设备上运行。**
不能。它是为 ARM aarch64 Android 编译的产物。

**误解六：`data/` 可以随意删除，反正可以重新生成。**
不能。`data/` 包含全部会话、配置与主密钥。删除后无法恢复，除非有备份。

**误解七：备份文件是安全的，可以随便分享。**
不对。备份包含主密钥，等同于内容加解密钥匙。

**误解八：计费数字就是账单金额。**
不一定。本地显示的是估算值，以服务商账单为准。

### 34.2 容易混淆的概念

| 概念 A | 概念 B | 区别 |
| :--- | :--- | :--- |
| 维度 | 模型 | 维度是通道，模型是通道里的具体型号 |
| 工具模式 | ADB 通道 | 工具模式是开关，ADB 通道是底层连接 |
| 全双工 Key | 方舟 API Key | 前者用于实时语音，后者用于文本等通用能力 |
| 音声生成 | TTS | 音声生成是端到端生成，TTS 是文字转语音 |
| 托管文件 | 对象存储（TOS） | 托管文件上限 512 MB，对象存储上限 2 GB |
| 命中 token | 未命中 token | 命中缓存单价低，未命中单价高 |
| 高峰 | 低谷 | 高峰与低谷是 DeepSeek 按时段的定价区间 |
| 主密钥 | API Key | 主密钥用于加密配置，API Key 是服务商的凭证 |

---

## 35. 版权、署名与许可

### 35.1 署名要求

根据旧版作者问答，项目允许 fork 后二次开发，但要求保留原作者署名。这是作者提出的条件，请在二次分发时保留相关署名。

### 35.2 许可证

仓库中未发现独立的 `LICENSE` 文件。在没有明确许可证的情况下，默认的版权限制适用。若你计划分发修改版，请先与原作者确认授权范围。

### 35.3 第三方服务的版权

本项目调用的 DeepSeek、火山方舟、火山引擎、Microsoft Edge TTS、X 等服务，其使用须遵守各自的服务条款。生成内容的版权与使用规则也由对应服务商决定。

### 35.4 本文档的范围

本文档依据仓库源码与旧版说明编写。它不代表原作者的正式声明。涉及维护承诺、版权归属的内容，请以作者的原始说明为准。

---

## 36. 附录：完整字段对照表

### 36.1 DeepSeek 发送请求

| 字段 | 必填 | 类型 | 说明 |
| :--- | :--- | :--- | :--- |
| `sessionId` | 是 | 字符串 | 会话 ID |
| `content` | 是 | 字符串 | 消息正文，首尾空白会被去除 |
| `fileIds` | 否 | 字符串数组 | 文件 ID 列表 |
| `reasoningLevel` | 否 | 整数 | 思考等级，默认 1 |
| 工具开关 | 否 | 布尔 | 服务端会二次校验 |

### 36.2 中转站配置

| 字段 | 必填 | 类型 | 说明 |
| :--- | :--- | :--- | :--- |
| `baseUrl` | 是 | 字符串 | 须包含 `/v1` |
| `apiKey` | 是 | 字符串 | 明文保存 |
| `customModels` | 否 | 字符串数组 | 自定义模型名 |

### 36.3 角色库

| 字段 | 必填 | 类型 | 说明 |
| :--- | :--- | :--- | :--- |
| `action` | 是 | 字符串 | 动作类型 |
| `id` | 视动作而定 | 字符串 | 角色 ID |
| `role` | 否 | 字符串 | 身份设定 |
| `style` | 否 | 字符串 | 说话风格 |
| `neutral` | 否 | 字符串 | 中立设定 |

### 36.4 论坛帖子

| 字段 | 必填 | 类型 | 说明 |
| :--- | :--- | :--- | :--- |
| `id` | 视动作而定 | 字符串 | 帖子 ID |
| `title` | 否 | 字符串 | 标题 |
| `content` | 否 | 字符串 | 正文 |
| `author` | 否 | 字符串 | 作者 |
| `summary` | 否 | 字符串 | 摘要 |
| `ids` | 批量删除时必填 | 字符串数组 | ID 列表 |

### 36.5 公告

| 字段 | 必填 | 类型 | 说明 |
| :--- | :--- | :--- | :--- |
| `id` | 否 | 字符串 | 公告 ID |
| `title` | 是 | 字符串 | 标题 |
| `content` | 是 | 字符串 | 正文 |
| `startTime` | 否 | 时间 | 生效开始 |
| `endTime` | 否 | 时间 | 生效结束 |

### 36.6 单词本

| 字段 | 必填 | 类型 | 说明 |
| :--- | :--- | :--- | :--- |
| `word` | 是 | 字符串 | 单词原文 |
| `reading` | 否 | 字符串 | 假名读音 |
| `pitch` | 否 | 字符串 | 音调 |
| `pos` | 否 | 字符串 | 词性 |
| `meaning` | 否 | 字符串 | 释义 |
| `example` | 否 | 字符串 | 例句 |
| `level` | 否 | 字符串 | 等级 |
| `tags` | 否 | 字符串数组 | 标签 |
| `image` | 否 | 字符串 | 配图 |

### 36.7 豆包生图

| 字段 | 必填 | 类型 | 说明 |
| :--- | :--- | :--- | :--- |
| `model` | 是 | 字符串 | 生图模型标识 |
| `prompt` | 是 | 字符串 | 提示词 |
| `ratio` | 否 | 字符串 | 画面比例 |
| `resolution` | 否 | 字符串 | 分辨率 |
| `style` | 否 | 字符串 | 风格 |
| `customStyle` | 否 | 字符串 | 自定义风格 |
| `name` | 否 | 字符串 | 文件名 |

---

## 37. 结语

Kewe 的核心思路很朴素：把大模型放到用户自己的手机上，让用户自己掌握数据、密钥与操作边界。它没有花哨的架构，也没有第三方依赖，主要靠 Dart 与 Python 标准库完成所有功能。

使用它时，请记住三件事：

1. 数据只在本机，备份要妥善保管，包括主密钥。
2. 工具模式能真实操作手机，开启前确认目标，用完关闭。
3. 费用与额度以服务商账单为准，不要依赖本地估算做决策。

如果你在阅读本文档时发现与源码不一致的地方，请以源码为准，并欢迎修正。
