# Echo

Echo 是面向 Apple Silicon Mac 的原生聊天工作区，提供桌面精灵、多会话文本聊天、语音转写和 Live Voice。界面使用 AppKit / SwiftUI，精灵动画由 Rust 运行时驱动。

## 当前功能

- **桌面精灵**：内置赤焰和沧沧，支持待机、悬停跳跃、方向拖动及 v2 素材的注视动画。点击精灵打开主窗口；浮层显示当前活动摘要，支持跟进、停止和隐藏。隐藏摘要或主窗口不会取消后台模型请求。
- **聊天工作区**：原生三栏布局，包含项目与会话侧栏、聊天区和可收起的详情栏。支持会话搜索、重命名、删除、独立草稿和多会话并行请求。新对话首次发送后才进入列表；已有会话在本次运行中保持顺序，重启后按保存的对话时间排序。
- **文本模型**：支持 OpenAI 兼容的 Chat Completions 和 Responses 接口、SSE 流式回复及非流式 JSON 响应。可停止并保留已收到的文本；失败、停止或中断后可原位重试，不重复追加用户消息。后续请求携带用户消息、已完成回复及停止时保留的非空回复。
- **消息显示**：支持标题、强调、链接、列表、引用和代码块，复制保留 Markdown 原文。Enter 发送，Shift + Enter 换行，中文输入法确认候选字不会发送。
- **语音转写**：输入框麦克风按钮将识别结果追加到草稿，不自动发送。转写绑定启动时的会话，不要求配置文本模型。
- **Live Voice**：通过流式 ASR → 文本模型 → 流式 TTS 进行语音对话，支持临时字幕、静音、结束语音、文字打断和语音插话。全应用同时只运行一个语音会话，切换会话或打开设置不会改变其归属。转写、Live Voice 和语音设置测试互斥。
- **精灵导入**：设置中可导入包含 `pet.json` 和 WebP 精灵图的文件夹，支持 v1/v2 素材，导入后点击卡片切换。重复素材不会重复导入；切换保留窗口位置和会话。

项目文件夹仅用于组织会话，支持重命名、Finder 定位和重新定位路径；移除项目不会删除磁盘文件。

## 构建与运行

需要 Apple Silicon Mac、macOS 26 或更新版本、Rust/Cargo，以及支持 Swift 6 的 Xcode Command Line Tools 和 macOS 26 SDK。首次构建需要下载 Rust 依赖。脚本使用系统 `/bin/zsh`，默认选择 macOS 26 SDK，也可通过 `SDKROOT` 指定兼容 SDK。

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
2. “测试连接”使用当前表单发送固定短消息，不保存配置、不上传会话。正常聊天使用已保存的配置；首次启动不会自动发送模型请求。
3. 使用语音前，模型设置中保存的密钥必须具有豆包 / 火山方舟 Agent Plan 语音服务权限。当前语音默认复用该密钥，兼容已有的专用语音凭据；普通文本服务的密钥不一定可用于语音。语音页仅提供音色 ID 配置，不提供单独密钥输入框。
4. 在“语音”中保存音色 ID，或使用“检查连接”“试听音色”验证。默认音色为 `zh_female_gaolengyujie_uranus_bigtts`。检查和试听会请求服务，但不录音、不自动保存。首次转写或通话需要麦克风权限，识别音频发送到语音服务，音频在本机仅作内存处理。

常用快捷键：`⌘N` 新对话、`⌘F` 搜索、`⌘⌥S` 切换侧栏、`⌘⌥I` 切换详情栏、`⌘W` 隐藏主窗口。

## 架构与数据

| 路径 | 职责 |
| --- | --- |
| `runtime/src/` | Rust 精灵清单解析、WebP 解码与切帧、动画状态和交互优先级 |
| `runtime/include/` | C ABI 与 Swift 模块映射；Swift 复制帧数据并缓存为 `CGImage` |
| `macos/PetStore.swift`、`PetWindow.swift`、`PetCatalog.swift` | 精灵运行时桥接、透明悬浮窗口、素材导入与切换 |
| `macos/Companion*.swift`、`MainWindowController.swift`、`ConversationViews.swift` | 桌面浮层、窗口布局和聊天界面 |
| `macos/WorkspaceStore.swift`、`TaskStore.swift`、`ModelTaskSource.swift` | 项目与会话管理、每会话任务状态、模型请求与取消 |
| `macos/Voice*.swift`、`DictationController.swift` | 语音状态、WebSocket 协议、AVAudioEngine 采集与播放、插话和转写 |
| `macos/Settings*.swift` | 设置界面、配置持久化和钥匙串访问 |
| `assets/pets/`、`scripts/`、`tests/` | 内置素材、构建与诊断脚本、回归测试 |

本地数据目录为 `~/Library/Application Support/local.chiyan.desktop-pet/`：

- `workspace.json` 保存项目、会话、消息和草稿，采用原子写入并保留有效备份；损坏时保留原件并尝试恢复。重启后未完成请求标记为中断，不会自动重发。
- `settings.json` 保存模型配置、音色和精灵选择；`pets/` 保存导入素材。
- API Key 保存在 macOS 钥匙串，不写入上述 JSON；窗口布局偏好保存在 UserDefaults。

## 已知限制

- 当前是本机开发应用，没有公证、安装器或自动更新；不支持 Intel Mac 或 macOS 26 之前的系统。
- 不读取项目文件内容，不修改项目文件，不执行工具、Shell 或 Git，也不支持附件。模型设置只维护一组服务配置，不自动获取模型或音色列表。
- 聊天只处理文本；Markdown 不渲染图片、HTML、表格或代码高亮。没有会话上下文自动摘要或长度裁剪，长会话可能超过服务限制。
- 语音接口固定使用豆包 / 火山方舟 Agent Plan 的 ASR、TTS 服务，并非端到端语音模型。插话先暂停播报再确认新语音，极短插话或重复助手原话可能被忽略；播报结束后有约 2 秒尾音保护期。延迟和回声表现仍需在实际麦克风、耳机及扬声器环境中验证。
- 精灵不会自主移动，精灵动画未适配系统“减少动态效果”。没有精灵下载或删除管理；导入 WebP 最大 32 MB、约 1600 万像素，素材路径不能越出所选文件夹。

## 验证与诊断

本地回归入口（Rust 首次构建仍可能下载依赖）：

```sh
cargo test --locked --workspace
cargo clippy --locked --workspace -- -D warnings
/bin/zsh scripts/test-chat.sh
/bin/zsh scripts/test-chat-ui.sh
/bin/zsh scripts/test-workspace.sh
/bin/zsh scripts/test-voice.sh
/bin/zsh scripts/build.sh
/bin/zsh scripts/test-signing.sh
```

聊天、工作区和语音回归使用模拟依赖；默认签名测试不访问真实钥匙串。它们不能替代真实服务、麦克风或跨构建钥匙串授权验证。

以下检查在正常桌面环境中按需运行，会访问钥匙串或真实服务；语音脚本还需要 Python 3：

```sh
/bin/zsh scripts/test-signing.sh --keychain
/bin/zsh scripts/test-voice-live.sh --play
/bin/zsh scripts/diagnose-voice.sh
```

实网语音测试发送固定测试语句，不读取聊天、不录音；去掉 `--play` 可跳过播放。诊断脚本会构建开发签名应用，检查本地采集、连接及播放，上传的 ASR 探针为静音，日志写入 `build/test-logs/voice-diagnostic.log`。应先在应用中授予麦克风权限。正常语音日志也可在“设置 → 语音”查看。
