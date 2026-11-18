# 聊天记录导入 + 自定义 API（yoyo520956/OpenMinis fork）

基于官方 OpenMinis 源码修改的个人版本，新增两件事：

## 1. 导入其他 AI 的聊天记录

入口：**设置 → Backup & Restore → 「导入聊天记录」tab**

支持的文件与来源（自动识别，无需手动选）：

| 来源 | 文件形态 | 识别依据 |
|---|---|---|
| ChatGPT | 官方导出 .zip、conversations.json、.jsonl | `mapping` + `title` |
| Claude | 官方数据导出 .zip/.json/.jsonl | `chat_messages` + `uuid`/`name` |
| Grok / xAI | 导出 .json（`{"conversations":[...]}` 或 flat） | `responses` / `$date.$numberLong` |
| DeepSeek | 网页版/社区工具导出 .json / .md / .txt | `messages[{role,content}]` 或角色标记 |
| 豆包 | 社区导出 .json / .md / .txt | 同上 + `## 豆包` 标记 |
| 通用 | OpenAI Chat-Completions JSON、Anthropic Messages JSON、任意 JSONL、Markdown 对话稿 | `role/content`、`## 用户/助手`、`Human:/Assistant:`、`**用户**:` 等 |

流程：选文件 → 自动解析并列出所有识别到的会话（可勾选）→ 选导入后会话使用的模型 → 导入。
导入结果是**全新的本机会话**（标题带「（来自 来源）」后缀，source 字段 `import:<格式>`），
在首页会话列表里直接可见、可继续对话。

### DeepSeek / 豆包 / Grok 怎么拿到导出文件

这三家**没有官方批量导出**，用社区工具：

- DeepSeek：Chrome 扩展 `ypyf/deepseek-chat-exporter`（导出 Markdown/JSON）、`lyqtzs/deepseek-chat-exporter`（多格式）、Tampermonkey 脚本类
- 豆包：`zhx6172815/doubao-chat-exporter`（Markdown/JSON/TXT，无水印）、`yxmc/Doubao-Conversation-Export`
- Grok/xAI：`Covai-Labs/ace`（AI Chat Exporter，支持 Grok）、`pinguarmy/ai-chat-exporter`
- ChatGPT / Claude：网页版自带官方导出（Settings → Export data / 数据导出）

导出后把文件放进「文件」App，App 内导入页直接选即可（zip 自动解压）。

## 2. 自定义 API（官方已内置，无需改码）

OpenMinis 官方就支持**任意 OpenAI 兼容 API**：

入口：**设置 → AI Providers → 添加实例 → OpenAI 类型 → 填自定义 Base URL + API Key + 模型 ID**

各家的 Base URL 例子：

| 服务商 | Base URL | 模型 ID 例子 |
|---|---|---|
| DeepSeek | `https://api.deepseek.com` | `deepseek-chat`、`deepseek-reasoner` |
| 豆包/火山方舟 | `https://ark.cn-beijing.volces.com/api/v3` | 你的 endpoint id |
| xAI (Grok) | `https://api.x.ai/v1` | `grok-3` 等 |
| Ollama / LM Studio / vLLM | `http://192.168.x.x:11434/v1` | 任意本地模型 |
| 硅基流动 / OpenRouter 等 | 对应兼容端点 | 对应模型 id |

（`appendV1Suffix` 选项决定 URL 是否自动补 `/v1`；Anthropic 类型也支持自定义 key 登录。）

## 构建 / 安装

- 仓库自带 CI：`.github/workflows/chat-import-ci.yml`（push main 自动跑）
  - `parser-test` job：用真实解析器源文件跑 10 组夹具测试（ChatGPT/Claude/Grok/OpenAI/DeepSeek/JSONL/Markdown/垃圾输入）
  - `build-ipa` job：完整构建 → 产出 `Minis-chatimport.ipa`（未签名，ad-hoc 签名）
- 安装：下载 artifact → [Sideloadly](https://sideloadly.io)（或 AltStore/SideStore）自签 → 7 天有效期，重签即可
- 本地构建方法见官方 `BUILDING.md`（首次要编 iSH/FFmpeg/rootfs 等依赖，30–60 分钟）

## 改了哪些文件

| 文件 | 说明 |
|---|---|
| `src/ios/Agent/Chat/ChatImport/ChatArchiveParser.swift` | 新增：纯 Foundation 解析器（各家格式 → 归一化会话） |
| `src/ios/Agent/Chat/ChatImport/ChatImportService.swift` | 新增：zip 解压 + 写 ChatStore + 模型绑定 |
| `src/ios/Views/Settings/ChatImportView.swift` | 新增：导入页 UI（选择/预览/选模型/结果） |
| `src/ios/Views/Settings/BackupAndRestoreView.swift` | 修改：加「导入聊天记录」tab |
| `src/ios/Minis.xcodeproj/project.pbxproj` | 修改：3 个新文件入 target（ChatImport 组） |
| `src/ios/MinisTests/Standalone/ChatImportParserStandaloneTest.swift` | 新增：解析器夹具自测（CI 跑） |
| `.github/workflows/chat-import-ci.yml` | 新增：解析测试 + iOS 构建 + IPA 产物 |
