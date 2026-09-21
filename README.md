# Echo

Echo 是面向 Apple Silicon Mac 的桌面应用，将 macOS 桌宠、AI 对话与 Agent 工具执行整合在一个原生工作区中。Swift / AppKit / SwiftUI 负责界面和系统能力，Rust Agent Core 负责模型交互与会话决策。

Mini Agent 主线迁移已完成[第 5 阶段自动验收](docs/mini-agent-mainline-bridge-v2-plan.md)。Swift 与 Rust/C 接口使用 [wire v2](docs/mini-agent-mainline-bridge-v2-contract.md)，核心存档仍为 v1；保存确认、输入回执和目录放行已接入。主线 feature 矩阵、桌宠完整本地回归及独立 ad-hoc 应用包验收均已通过；真实模型服务与 Live Voice 仍需发布前抽验。

## 核心能力

- **桌宠**：内置赤焰和沧沧，支持待机、悬停、拖动和适配素材的注视动画。点击桌宠打开聊天，浮层显示活动摘要；设置中可导入包含 `pet.json` 和 WebP 精灵图的 v1/v2 素材。
- **普通聊天**：支持多会话、搜索、重命名、删除、独立草稿和多会话并行请求。无需关联项目即可对话；新会话首次发送后进入列表。
- **Agent 会话与工具执行**：普通问答和工具任务共用会话，由 Rust Core 决定直接回答或调用 bash。运行中可追加指令，命令和结果显示在可折叠工具记录中；“继续处理”保留真实工具历史。
- **Stop / 取消**：停止当前会话的模型请求或工具任务，并等待清理完成。隐藏窗口不会取消后台任务；Stop 不回滚已完成的文件修改。
- **普通麦克风听写**：将识别结果追加到启动听写时的会话草稿，不自动发送。优先使用已保存的语音专用凭据连接豆包 ASR；没有可用专用凭据时，在录音前尝试 Apple on-device ASR fallback。取消或识别失败不提交临时文字。
- **Live Voice**：说话时识别文字实时出现在会话中该条用户消息的位置，识别过程中原地修正，定稿后成为正式消息并进入 Agent 会话，可在执行任务期间继续追加要求；仅播报最终回复，确认插话后停止播报。结束语音会保留 Agent 任务继续运行，停止任务使用 Stop。全应用同时只运行一个语音会话，普通听写、Live Voice 和语音设置测试互斥。
- **多 Provider 配置**：按 Provider 保存 API Key、Base URL、Model ID 和协议，支持 OpenAI 兼容的 Chat Completions / Responses；保存后切换当前使用的配置。
- **文件目录浏览**：项目目录树使用系统源列表，支持 ↑ / ↓ 遍历、← / → 展开折叠、Return 打开和右键菜单；目录按需展开，监听文件变化并刷新，同一项目保留本次运行中的浏览位置。隐藏文件不显示，符号链接不跟随；可在 Finder 中定位文件或拷贝路径。浏览内容不会自动加入模型上下文。
- **文件预览与消息渲染**：文本文件只读预览，常见代码文件支持语法高亮，Markdown 文件显示渲染内容。支持 PNG、JPEG、WebP、GIF 等可解码图片的预览，GIF 仅显示首帧。聊天回复支持 Markdown 标题、强调、链接、列表、引用和代码块，消息与代码块均可复制。
- **会话持久化**：本地保存项目、消息、草稿、模型历史和工具记录。重启后将未完成任务标记为中断，不自动重放命令。

工具执行前需要关联项目文件夹，作为命令的初始工作目录。同一真实目录的任务按轮次串行，不同目录可并行。bash 自动在本机执行，项目目录不是文件访问边界；移除项目不会删除磁盘文件。

## 构建与运行

需要 Apple Silicon Mac、macOS 27 或更新版本、Rust/Cargo，以及带 Swift 6 与 macOS 27 SDK 的 Xcode。应用的 SDK 由工程设置决定；`scripts/swift-env.sh` 只为 Cargo 与 clang 解析 SDK，可通过 `SDKROOT` 覆盖。首次构建需要下载 Rust 依赖。

当前构建还依赖相邻目录中的 `mini-agent-rs`：

```text
workspace/
├── desktop-pet-agent-exp/  # 本仓库
└── mini-agent-rs/          # Rust Agent Core，Cargo 路径依赖
```

相邻主线工作区须包含 `conversation::runner` 实现，本轮验收基线为主线提交 `3127fa2`。构建时由 Cargo metadata 解析 `echo-agent` 的实际依赖目录，并打包其中的 `config/prompts/conversation.md`。构建后的应用运行时无需源码目录。

macOS 应用由 `Echo.xcodeproj` 构建，Rust 静态库仍由 Cargo 负责，经工程里的 `RustCore` target 触发。

在本仓库根目录执行：

```sh
# 构建验证包：ad-hoc 签名，不访问签名钥匙串
xcodebuild -scheme Echo -configuration Release \
    CONFIGURATION_BUILD_DIR="$PWD/build/validation" build
# 产物：build/validation/Echo.app

# 开发签名并运行
/bin/zsh scripts/signing-identity.sh
xcodebuild -scheme Echo -configuration Development \
    CONFIGURATION_BUILD_DIR="$PWD/build" build
open build/Echo.app
# 产物：build/Echo.app
```

两个 configuration 的区别只有签名：`Release` 用 ad-hoc，`Development` 用证书。在 Xcode 里 ⌘R 走 `Development`，不会跑出 ad-hoc 包——ad-hoc 签名绑定代码哈希，每次重新构建都会丢掉钥匙串授权。`signing-identity.sh` 解析（必要时自举）签名身份，只需在身份变化或 `build/` 被清空后重跑。重新构建启动前先退出已运行的 Echo。

开发签名优先使用可用的 Apple 签名证书，可通过 `ECHO_SIGNING_IDENTITY` 指定证书 SHA-1。没有 Apple 证书时，脚本会在 `.local-signing/` 创建或复用本机自签证书与专用钥匙串，并添加当前用户的代码签名信任，可能触发系统授权。该目录包含本机签名材料，不应提交或分享；自签版本重新构建后仍可能再次请求 API Key 访问授权。

应用不显示 Dock 图标。点击桌宠打开主窗口，关闭或最小化窗口会保留桌宠；右键桌宠选择“关闭精灵”或使用 `⌘Q` 退出。

## 模型与语音配置

通过主窗口齿轮或 `⌘,` 打开独立设置窗口。设置与聊天可同时使用；关闭设置保留未保存的编辑并停止连接检查和语音试听。

### 文本模型

在“模型”中选择 Provider 和协议，填写 API 根地址、API Key、Model ID 后保存。界面提供 OpenAI、DeepSeek、自定义及 Ollama 配置项，其中 Ollama 不是当前正式支持目标。

例如根地址为 `https://api.openai.com/v1` 时，应用按协议追加 `/chat/completions` 或 `/responses`。支持 HTTPS 和本机回环 HTTP。每个 Provider 记住一组配置，保存后成为当前 active provider；未保存的表单修改不影响正常会话。

“测试连接”使用 Rust 模型层检查当前表单配置能否返回有效的 bash 工具调用，不执行命令、不保存配置，也不上传已有会话。

### 语音与 Apple 本地识别

文本模型 Key 与语音 Agent Plan Key 分开存储，普通听写已与文本模型配置解耦：更换文本 Provider、Base URL 或 Key 不改变普通听写的 ASR 选择。两类 Key 的服务权限不能视为通用。

| 入口 | 当前凭据与服务选择 |
| --- | --- |
| 普通麦克风听写 | 仅使用已保存的 Agent Plan / 语音专用 Key 连接豆包 ASR；没有可用专用凭据时尝试 Apple 本地识别，不使用文本模型 Key |
| Live Voice | 优先使用已保存的语音专用 Key；未配置时仍保留复用已保存模型 Key 的兼容逻辑，该 Key 必须具备 Agent Plan 语音权限 |
| 语音设置测试 | 使用语音专用凭据，未配置时同样回退到已保存模型 Key；测试连接或试听会访问真实服务 |

当前语音设置页只提供音色 ID、保存、测试连接和试听，尚无独立 Key 输入框；已有语音专用凭据可继续使用。默认音色为 `zh_female_gaolengyujie_uranus_bigtts`。

普通听写的 Apple fallback 使用固定 `zh-CN` on-device 配置，可识别中文及中英混说，不跟随 macOS 界面语言。录音前检查语音识别权限、本地识别能力和服务可用性；不满足条件时提示错误，不转入 Apple 云端识别。本轮录音开始后不切换服务，远程 ASR 运行中失败也不会自动转到 Apple。

首次听写或通话需要麦克风权限，Apple 本地识别还需要语音识别权限与可用的本地语言资源。豆包 ASR 会接收识别音频；Apple fallback 在设备上识别。Live Voice 使用豆包 / 火山方舟 Agent Plan ASR 与 TTS，不提供 Apple fallback。

## 快捷键

| 快捷键 | 操作 |
| --- | --- |
| `⌘N` | 新建对话 |
| `⌘B` | 切换左侧栏 |
| `⌘⌥B` | 切换右侧项目文件栏 |
| `⌃⇧D` | 开始 / 结束普通听写 |
| `⌃⇧V` | 开始 / 结束 Live Voice |
| `⌘.` / `Esc` | 停止当前会话的回复或 Agent 任务 |
| `⌘F` | 搜索聊天 |
| `⌘,` | 打开设置 |
| `⌘W` | 关闭当前窗口（主窗口隐藏，桌宠继续运行） |
| `⌘Q` | 退出应用 |
| `Enter` / `Shift+Enter` | 发送 / 换行 |

这些是应用内快捷键。输入框获得焦点时同样可用；中文输入法确认候选字不会发送消息。`Esc` 不结束普通听写或 Live Voice，输入法组合输入或无可停止任务时保留默认行为。

## 架构与本地数据

| 模块 | 职责 |
| --- | --- |
| `macos/` | Swift 前端：桌宠和窗口、聊天与文件预览、项目调度、设置与钥匙串、会话落盘、麦克风采集、ASR/TTS 和音频播放 |
| `../mini-agent-rs/` | Rust Agent Core：模型协议、会话状态和恢复、异步运行器、保存门控、工具执行和取消清理 |
| `agent-bridge/`、`macos/AgentBridge.swift`、`macos/AgentWire.swift` | Rust 负责 v2 编解码、FFI 所有权、后台初始化、共享 Tokio runtime 与清理计数；Swift 使用类型化请求、批次与错误 |
| `runtime/` | Rust 桌宠运行时：素材清单解析、WebP 解码与切帧、动画状态和交互优先级 |
| `Echo.xcodeproj`、`Echo.xcconfig` | 应用、测试与探针的构建配置；`RustCore` target 触发 Cargo |
| `assets/pets/`、`scripts/`、`tests/` | 内置桌宠素材、构建辅助与诊断脚本、回归测试 |

本地数据位于 `~/Library/Application Support/local.chiyan.desktop-pet/`：

- `workspace.json` 保存项目和会话索引，`agent-sessions/<会话 ID>.json` 单独原子保存消息、草稿、模型历史及工具记录。
- `settings.json` 保存模型配置、音色和桌宠选择，`pets/` 保存导入素材。
- API Key 保存在 macOS 钥匙串，不写入上述 JSON；窗口布局偏好保存在 UserDefaults。

工具意图保存后才放行，结果保存失败会停止后续执行。会话历史缺失或损坏时禁止继续执行；重启恢复时，缺失的工具结果标记为“执行结果未知”。

## 测试与诊断

在仓库根目录运行本地回归（首次 Cargo 构建可能下载依赖）：

```sh
cargo test --locked --workspace
cargo clippy --locked --workspace -- -D warnings
xcodebuild test -scheme EchoTests
/bin/zsh scripts/test-agent-bridge.sh
/bin/zsh scripts/test-agent-session.sh
/bin/zsh scripts/test-native-shortcuts.sh
/bin/zsh scripts/test-signing.sh
```

`EchoTests` scheme 覆盖聊天 / 模型 / 设置、Agent 任务源、语音、工作区与会话 UI。单独运行某一项用 `-only-testing`，例如 `xcodebuild test -scheme EchoTests -only-testing:EchoChatTests` 或 `-only-testing:EchoVoiceTests/AgentVoiceIntegrationSuite`（对应原来的 `--agent-integration`）。

其余几个套件必须以可执行文件而非 XCTest bundle 运行，每个都有对应的 Xcode target，脚本只负责构建、准备夹具和运行：`test-agent-bridge.sh` 与 `test-agent-session.sh` 依赖 `Bundle.main` 定位打包好的 prompt，而 XCTest bundle 里 `Bundle.main` 是 Xcode 的 `xctest`；`test-native-shortcuts.sh` 的原生菜单与真实指针场景需要 `NSApplication.run()` 事件循环，该循环以 `exit(0)` 结束，XCTest 宿主会判为崩溃。

这些入口使用模拟依赖或本机测试服务，不依赖真实模型 / 语音服务。Agent 集成测试需要 Python 3 和本机回环端口权限，部分测试会在临时项目执行 bash；UI 测试需在桌面环境运行。默认签名回归不访问真实钥匙串。

打包验收（不带参数时自行构建验证包）：

```sh
/bin/zsh scripts/test-packaged-app.sh
```

打包测试将应用复制到 `/private/tmp`，从空工作目录启动，使用本机模型服务和临时项目检查协议、历史恢复与退出清理，并保存窗口截图。验收还核对 sidecar 的 checkpoint、输入映射、显示顺序、最终回复去重及 Responses 元数据，检查主线程心跳和退出后的 shell/子进程清理；需要 Python 3、桌面环境及屏幕录制权限。

可选的真实设备、服务和诊断入口：

| 命令 | 用途 |
| --- | --- |
| `/bin/zsh scripts/test-apple-speech-device.sh` | 用系统合成的中英文及混合音频检查 Apple 本地识别；不录麦克风，需语音识别权限和本地语言资源 |
| `/bin/zsh scripts/test-signing.sh --keychain` | 检查开发签名与真实钥匙串授权 |
| `/bin/zsh scripts/test-agent-live.sh` | 用已保存模型配置验证真实回复和临时项目读改验 |
| `/bin/zsh scripts/test-voice-live.sh --play` | 验证真实 ASR → Rust Agent → TTS 链路并播放；不录麦克风，去掉 `--play` 跳过播放 |
| `/bin/zsh scripts/test-voice-soak.sh [秒数] [--cut 秒数]` | 长连接空闲浸泡，检查 socket 有序关闭；日志写入 `build/test-logs/voice-soak-*.log` |
| `/bin/zsh scripts/test-agent-ffi.sh` | 仅 Rust/C 的 ASAN 探针，检查 C ABI 的所有权与生命周期 |
| `/bin/zsh scripts/diagnose-voice.sh` | 构建开发签名应用，检查采集、连接和播放，日志位于 `build/test-logs/voice-diagnostic.log` |
| `/bin/zsh scripts/trace-dictation.sh` | 跟踪普通听写回调；先构建开发签名应用并退出已运行实例，日志写入 `build/test-logs/dictation-*.jsonl` |

这些入口的应用包同样由 Xcode target 构建（`AgentLiveProbe`、`VoiceLiveProbe`、`VoiceSoakProbe`、`AppleSpeechDeviceProbe`、`KeychainProbe`），脚本只负责签名模式、夹具与运行参数。真实服务检查使用已保存凭据，可能触发钥匙串授权并产生服务用量。语音设备与诊断脚本需要 Python 3；听写跟踪会记录转写全文和草稿，仅用于本地诊断，正常启动不启用。

## 当前限制

- 当前普通聊天 / Agent 回复以非流式为主，生产路径使用非流式模型请求；尚无会话上下文自动摘要或长度裁剪，长会话可能超过服务限制。
- 工具仅支持 bash，每次模型决策最多执行一条命令；聊天不支持附件或图片输入，图片预览仅用于本地文件浏览。
- 超过 **1 MiB** 的文本文件不预览；文本编码仅支持 UTF-8 和带 BOM 的 UTF-16。图片文件上限为 **32 MiB**，解码预览最长边限制为 4096 像素。
- 代码高亮仅用于文件预览，基于轻量规则，不是 Tree-sitter / LSP 级语义高亮；聊天 Markdown 代码块尚无语法高亮。Markdown 渲染不提供图片、HTML 或表格排版。
- 本地 Ollama 模型不是当前正式支持目标。每个 Provider 仅保存一组配置，同一时刻只有一个 active provider，不支持多账号管理或自动获取模型 / 音色列表。
- Live Voice 依赖 Agent Plan ASR/TTS，未完全移除模型 Key 复用逻辑，也不是端到端语音模型。Apple 本地听写准确率受语言资源和语音内容影响；真人插话延迟、扬声器回声及多设备切换尚未完成系统性体验评估。
- 部分资源清理和缓存淘汰留待后续版本：删除会话尚不清理独立历史文件，项目浏览缓存尚无容量淘汰策略。
- 当前没有公证、安装器或自动更新，不支持 Intel Mac 或 macOS 27 之前的系统。
