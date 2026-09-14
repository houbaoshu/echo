# Echo

Echo 是面向 Apple Silicon Mac 的原生聊天工作区，提供桌面精灵、多会话文本聊天、语音转写和 Live Voice。界面使用 AppKit / SwiftUI，精灵动画由 Rust 运行时驱动。

## 当前功能

- **桌面精灵**：内置赤焰和沧沧，支持待机、悬停跳跃、方向拖动及 v2 素材的注视动画。点击精灵打开主窗口；浮层显示当前活动摘要，支持跟进、停止和隐藏。隐藏摘要或主窗口不会取消后台模型请求。
- **聊天工作区**：原生三栏布局，包含项目与会话侧栏、聊天区和默认收起的项目文件栏。输入框上方可搜索、选择或添加项目，首次发送后固定归属；项目行可直接新建对话。支持会话搜索、重命名、删除、独立草稿和多会话并行请求。新对话首次发送后才进入列表；已有会话在本次运行中保持顺序，重启后按保存的对话时间排序。
- **项目文件**：目录树按需展开，支持隐藏文件开关与手动刷新；只读预览不超过 1 MiB 的 UTF-8 或带 BOM 的 UTF-16 文本。符号链接不跟随，不支持的文件可在 Finder 中显示。同一项目共享本次运行中的浏览位置；重新打开文件栏、应用回到前台或当前项目 Agent 任务结束时刷新。浏览内容不会加入模型上下文或工作区快照。
- **统一 Agent 会话**：支持 OpenAI 兼容的 Chat Completions 和 Responses，使用非流式模型请求。Rust Core 决定直接回答或执行 bash；运行中可追加指令，助手说明与最终回复正常显示，命令及结果进入可折叠工具记录。Stop 等待清理结束；“继续处理”保留真实工具历史，不重复原用户消息。
- **消息显示**：支持标题、强调、链接、列表、引用和代码块，复制保留 Markdown 原文。Enter 发送，Shift + Enter 换行，中文输入法确认候选字不会发送。
- **语音转写**：输入框麦克风按钮将识别结果追加到草稿，不自动发送。转写绑定启动时的会话，不要求配置文本模型。
- **Live Voice**：语音定稿进入统一 Agent 会话，任务执行、请求模型或等待项目期间均可追加语音要求。仅播报最终回复，确认插话时停止播报；界面 Stop 取消任务，结束语音保留 Agent 任务继续运行。全应用同时只运行一个语音会话，切换会话或打开设置不会改变其归属。转写、Live Voice 和语音设置测试互斥。
- **精灵导入**：设置中可导入包含 `pet.json` 和 WebP 精灵图的文件夹，支持 v1/v2 素材，导入后点击卡片切换。重复素材不会重复导入；切换保留窗口位置和会话。

项目文件夹也作为命令的初始工作目录。普通聊天无需目录，首次工具调用可在所属会话选择或关联项目；同一真实目录按轮次串行，不同目录可并行。活动任务期间不能解除项目关联或重新定位。bash 自动在本机执行，项目目录不是访问边界；Stop 不回滚已有修改。移除项目不会删除磁盘文件。

## 构建与运行

需要 Apple Silicon Mac、macOS 26 或更新版本、Rust/Cargo，以及支持 Swift 6 的 Xcode Command Line Tools 和 macOS 26 SDK。首次构建需要下载 Rust 依赖。脚本使用系统 `/bin/zsh`，默认选择 macOS 26 SDK，也可通过 `SDKROOT` 指定兼容 SDK。

Agent 集成实验已完成第 5 阶段端到端与打包验收，结果与复验入口见 [第 5 阶段交付记录](docs/agent-integration-stage5.md)。构建需要相邻的 `../mini-agent-agent-core-exp`（第 1 阶段会话核心），通过 Cargo 路径依赖编译，并将其 `config/prompts/conversation.md` 打包到应用资源。运行时无需该源码目录。接口见 [第 2 阶段交付记录](docs/agent-integration-stage2.md)，会话与持久化见 [第 3 阶段交付记录](docs/agent-integration-stage3.md)，语音范围见 [第 4 阶段交付记录](docs/agent-integration-stage4.md)。

仅构建验证包，不访问签名钥匙串：

```sh
/bin/zsh scripts/build.sh
```

产物为 `build/validation/Echo.app`，使用 ad-hoc 签名并检查签名完整性。

日常运行在正常桌面终端中执行：

```sh
/bin/zsh scripts/build.sh --signing development --run
```

产物为 `build/Echo.app`，已包含精灵素材，可移出源码目录运行。不带 `--run` 时仅构建；`--run` 必须搭配 `--signing development`。重新构建启动前先退出已运行的应用。

开发签名优先使用可用的 Apple 签名证书；有多个时用 `ECHO_SIGNING_IDENTITY` 指定证书 SHA-1。没有 Apple 证书时，脚本会在 `.local-signing/` 创建或复用本机自签证书和专用钥匙串，并添加当前用户的代码签名信任，可能触发系统授权。该目录包含本机签名材料，不应提交或分享。自签版本修改代码后仍可能再次请求 API Key 访问授权。

应用不显示 Dock 图标。点击桌面精灵打开聊天，关闭或最小化主窗口会保留精灵；右键精灵选择“关闭精灵”或使用 `⌘Q` 退出。

## 配置与使用

通过主窗口齿轮或 `⌘,` 打开设置。

1. 在“模型”中选择协议，填写 API 根地址、API Key 和 Model ID，然后保存。例如根地址 `https://api.openai.com/v1`，应用会按协议追加 `/chat/completions` 或 `/responses`。支持 HTTPS 和本机回环 HTTP。
2. “测试连接”使用 Rust 模型层验证当前表单所选协议能否返回有效的 bash 工具调用；不执行命令、不保存配置、不上传已有会话。正常聊天使用已保存的配置；首次启动不会自动发送模型请求。
3. 使用语音前，模型设置中保存的密钥必须具有豆包 / 火山方舟 Agent Plan 语音服务权限。当前语音默认复用该密钥，兼容已有的专用语音凭据；普通文本服务的密钥不一定可用于语音。语音页仅提供音色 ID 配置，不提供单独密钥输入框。
4. 在“语音”中保存音色 ID，或使用“检查连接”“试听音色”验证。默认音色为 `zh_female_gaolengyujie_uranus_bigtts`。检查和试听会请求服务，但不录音、不自动保存。首次转写或通话需要麦克风权限，识别音频发送到语音服务，音频在本机仅作内存处理。

常用快捷键：`⌘N` 新对话、`⌘F` 搜索、`⌘⌥S` 切换侧栏、`⌘⌥I` 切换项目文件、`⌘W` 隐藏主窗口。

## 架构与数据

| 路径 | 职责 |
| --- | --- |
| `runtime/src/` | Rust 精灵清单解析、WebP 解码与切帧、动画状态和交互优先级 |
| `runtime/include/` | C ABI 与 Swift 模块映射；Swift 复制帧数据并缓存为 `CGImage` |
| `agent-bridge/`、`macos/AgentBridge.swift` | 独立 Agent C ABI、共享 Tokio 后台运行、事件与取消生命周期、Swift 内存所有权及轮询适配 |
| `macos/PetStore.swift`、`PetWindow.swift`、`PetCatalog.swift` | 精灵运行时桥接、透明悬浮窗口、素材导入与切换 |
| `macos/Companion*.swift`、`MainWindowController.swift`、`ConversationViews.swift` | 桌面浮层、窗口布局和聊天界面 |
| `macos/WorkspaceStore.swift`、`TaskStore.swift`、`AgentTaskSource.swift` | 项目调度、每会话任务与工具状态、统一历史和 Core 接入；旧 ModelTaskSource 保留用于兼容回归 |
| `macos/Voice*.swift`、`DictationController.swift` | 语音状态、WebSocket 协议、AVAudioEngine 采集与播放、插话和转写 |
| `macos/Settings*.swift` | 设置界面、配置持久化和钥匙串访问 |
| `assets/pets/`、`scripts/`、`tests/` | 内置素材、构建与诊断脚本、回归测试 |

本地数据目录为 `~/Library/Application Support/local.chiyan.desktop-pet/`：

- `workspace.json` 保存项目和会话索引；`agent-sessions/<会话 ID>.json` 单独原子保存消息、草稿、完整模型历史和工具记录。工具意图保存后才放行，结果保存失败会停止后续执行。索引保留备份；单会话历史损坏或缺失时禁止执行，不回退到缺少工具结果的旧聊天。重启后未完成任务标记中断，缺失工具结果按“执行结果未知”恢复，不自动重放命令。旧工作区在加载后兼容迁移。
- `settings.json` 保存模型配置、音色和精灵选择；`pets/` 保存导入素材。
- API Key 保存在 macOS 钥匙串，不写入上述 JSON；窗口布局偏好保存在 UserDefaults。

## 已知限制

- 当前是本机开发应用，没有公证、安装器或自动更新；不支持 Intel Mac 或 macOS 26 之前的系统。
- 工具首版仅支持 bash，每次模型决策最多执行一条命令；不支持附件。模型设置只维护一组服务配置，不自动获取模型或音色列表。
- Live Voice 已通过模拟插话回归、真实 ASR → Rust Agent → TTS 链路及本机音频设备诊断。真人插话的主观延迟、扬声器回声和多设备切换尚未做系统性体验评估。
- 聊天只处理文本；Markdown 不渲染图片、HTML、表格或代码高亮。没有会话上下文自动摘要或长度裁剪，长会话可能超过服务限制。
- 语音接口固定使用豆包 / 火山方舟 Agent Plan 的 ASR、TTS 服务，并非端到端语音模型。插话先暂停播报再确认新语音，极短插话或重复助手原话可能被忽略；播报结束后有约 2 秒尾音保护期。延迟和回声表现仍需在实际麦克风、耳机及扬声器环境中验证。
- 精灵不会自主移动，精灵动画未适配系统“减少动态效果”。没有精灵下载或删除管理；导入 WebP 最大 32 MB、约 1600 万像素，素材路径不能越出所选文件夹。

## 验证与诊断

本地回归入口（Rust 首次构建仍可能下载依赖）：

```sh
cargo test --locked --workspace
cargo clippy --locked --workspace -- -D warnings
/bin/zsh scripts/test-agent-bridge.sh
/bin/zsh scripts/test-agent-session.sh
/bin/zsh scripts/test-chat.sh
/bin/zsh scripts/test-chat-ui.sh
/bin/zsh scripts/test-workspace.sh
/bin/zsh scripts/test-voice.sh
/bin/zsh scripts/test-voice.sh --agent-integration
/bin/zsh scripts/build.sh
/bin/zsh scripts/test-signing.sh
/bin/zsh scripts/test-packaged-app.sh build/validation/Echo.app
```

聊天、工作区和语音回归使用模拟依赖；默认签名测试不访问真实钥匙串。`test-packaged-app.sh` 将完整应用复制到 `/private/tmp`，从空工作目录启动真实窗口，使用本机模型服务和临时文件验证两种协议、历史恢复与退出清理，并保存窗口截图；需要桌面和屏幕录制权限。它们不能替代真实服务、麦克风或跨构建钥匙串授权验证。

`test-voice.sh --agent-integration` 使用本机回环模型服务、真实 Rust Core 和临时项目内的 bash，ASR/TTS 与音频设备仍为模拟依赖；需要 Python 3 和回环端口权限。

以下检查在正常桌面环境中按需运行，会访问钥匙串或真实服务；语音脚本还需要 Python 3：

```sh
/bin/zsh scripts/test-signing.sh --keychain
/bin/zsh scripts/test-agent-live.sh
/bin/zsh scripts/test-voice-live.sh --play
/bin/zsh scripts/diagnose-voice.sh
```

`test-agent-live.sh` 用已保存的服务配置与密钥验证两种协议的直接回复和临时项目读改验。实网 Agent 和语音探针均打包提示词并使用开发签名，可能触发钥匙串访问授权；不更改保存的模型设置。

实网语音测试发送固定测试语句，经 Rust Agent 完成回复后只合成最终文本一次，不读取已有聊天、不录音；去掉 `--play` 可跳过播放。诊断脚本会构建开发签名应用，检查本地采集、连接及播放，上传的 ASR 探针为静音，日志写入 `build/test-logs/voice-diagnostic.log`。应先在应用中授予麦克风权限。正常语音日志也可在“设置 → 语音”查看。
