# 测试迁移清点（P6）

> 当前签名实现已进一步迁移：Development 使用 Xcode 的 Apple Development 证书与 Team 配置，Release 保持 ad-hoc。旧 identity resolver、signing guard 与基线比较脚本已删除；AppleSpeechDeviceProbe 在 Build Phase 生成音频后由 Xcode 签名。真实 Keychain 授权测试仍保留。以下 P7/P8 内容是迁移历史，其中专用 keychain、自签 requirement 和构建后手工签名不再描述当前实现。

本文件记录迁移前每个测试入口**实际验证什么**、**依赖什么**、**迁到 Xcode 后是什么形态**，以及**哪些无法等价迁移**。P7 的每一批都以本表为验收对照。

## 1. 现有测试是怎么连起来的

不是 20 个独立文件，而是 5 个按命名空间聚合的套件加一批独立探针。

**`VoiceTests` 是一个被扩展的命名空间**，`test-voice.sh` 的 5 个文件共享一个 `checks` 计数器和一组 helper：

| 文件 | 形态 | 场景函数 |
| --- | --- | --- |
| `VoiceTests.swift` | `@main`，持有 `check` / `rejects` / `tick` / `waitUntil` | 20 个 `…Tests()` |
| `VoiceBargeInTests.swift` | `extension VoiceTests` | 6 个 `bargeIn…()` |
| `AgentVoiceTests.swift` | `extension VoiceTests` + 两个 fixture 类 | 9 个 `agent…()` |
| `AppleSpeechTests.swift` | 独立类型，由 `VoiceTests.main()` 调 `run()` | 4 个 |
| `DictationTests.swift` | 独立类型，由 `VoiceTests.main()` 调 `run()` | 4 个 |

`ConversationUITests.swift`（4773 行）已经切成 **35 个 `testXxx` 函数**；`WorkspaceTests` 5 个、`ProjectFileBrowserTests` 2 个。只有 `ChatTests` / `ModelTests` / `SettingsTests` / `AgentTaskSourceTests` 是线性脚本，没有场景函数。

**断言惯例有四种，全部在首次失败时中止**：

| 写法 | 失败行为 | 出现次数 |
| --- | --- | --- |
| `precondition(cond, msg)` | trap | ~1400 |
| `VoiceTests.check(cond, msg)` | `fatalError("FAIL: …")`，否则 `checks += 1` | 280 |
| `WorkspaceTests` / `WorkspaceVoiceCommandTests` 的局部 `check` | `precondition` + 计数 | 145 |
| `VoiceTests.rejects(msg) { … }` | 期望抛出，否则 `fatalError` | 少量 |

所以今天「一条断言失败 = 整个可执行文件中止」，后续断言不再执行。这一点在迁移后保持不变（见 §4）。

**筛选靠命令行 flag**，共 13 个：`--dictation-only`、`--agent-integration`、`--agent-only`、`--pet-only`、`--pet-focus-only`、`--phase4-only`、`--settings-only`、`--project-picker-scroll-only`、`--palette-accessibility-only`、`--voice-transcript-only`、`--status-text-only`、`--paused-only`、`--play`。这些一一对应到 `-only-testing:` 或 test plan。

## 2. 入口逐项

### 2.1 可迁为 XCTest logic-test bundle

不设 `TEST_HOST` / `BUNDLE_LOADER`，把所需 `macos/` 源文件直接编进 bundle —— 与今天 `swiftc` 把源码和测试编在一起完全同构。

| 入口 | 验证什么 | 源集 | 依赖 |
| --- | --- | --- | --- |
| `test-chat.sh` | Provider 凭据存取与迁移、切换、endpoint/model 恢复、语音凭据隔离、保存回滚；模型请求、流式协议、失败与传输取消；会话状态、Stop、Retry 原位重试、停止片段进入上下文、存档往返 | 8 文件子集 | 无 |
| `test-agent-task-source.sh` | v2 Codable / u64 / history；输入 ID 持久性；SendMessage 原子竞态；generation 与 final 去重；保存与租约门控；control 背压 | 8 文件子集，**排除 `macos/AgentBridge.swift`** | 无 |
| `test-agent-session.sh` | 无效设置后重开会话；Chat/Responses 两种协议；目录门控、队列、追加指令；清理；「继续处理」；原子历史与恢复；存储失败 | all-except-main | python3 fixture、`build/agent/conversation.md`、`argv[1]` = 项目根 |
| `test-voice.sh` | 见 §1 的 5 文件聚合：快照与生命周期、采集看门狗、静音播放尾部保护、协议、设置、手动模型、音频转换、播放不产生用户轮次、插话（6 个场景）、Apple 本地识别（4 个）、听写（4 个）、Agent 语音适配与集成（9 个） | all-except-main | cwd 相对的 `build/agent/conversation.md` |
| `test-workspace.sh` | 启动空 composer 与隐藏面；项目关联；会话清理；流式落盘；快速 composer；语音命令；项目文件树的展开/刷新/分离提交 | all-except-main | 桌面环境 |
| `test-chat-ui.sh`（默认） | 27 个 hosted-view 场景：composer 自适应高度、窗口 chrome 与侧栏 accessory、连续听写追加、动作矩阵、停止与 Escape、代码复制与高亮预览、转写尾部锚定、Live Voice composer 状态与归属、设置与桌宠语音联动、桌宠表面布局、气泡呈现、状态文案例外、流式回复渲染、编辑器状态跨语音更新保持…… | all-except-main | 桌面环境 |

### 2.2 必须保持 App target（不能变成 XCTest bundle）

| 入口 | 为什么不能 |
| --- | --- |
| `test-agent-bridge.sh` 的探针 | 验证「从空 cwd 经 `Bundle.main` 定位打包好的 prompt」。XCTest bundle 的 `Bundle.main` 是 `xctest` 而不是被测应用，这条不变量就失去意义 |
| `test-agent-live.sh` | 需要用**生产 bundle 标识 + 开发签名**运行，才能读到钥匙串里已保存的模型凭据 |
| `test-voice-live.sh` | 同上，外加真实 ASR → Rust Agent → TTS 链路与可选播放 |
| `test-voice-soak.sh` | 同上，长连接空闲浸泡，带时长与 `--cut` 参数 |
| `test-apple-speech-device.sh` | 需要 `Info.plist` 里的 `NSSpeechRecognitionUsageDescription` 与签名 bundle 才能拿到语音识别授权 |
| `test-signing.sh --keychain` 的两个探针 | 刻意构造**两个 cdhash 不同**的 `.app`（`-D SECOND_BUILD`），验证代码变化后钥匙串授权的行为。必须是两个独立产物 |

### 2.3 不进 Xcode

| 入口 | 归属 |
| --- | --- |
| `test-agent-ffi.sh` 的 C ABI ASAN 探针 | clang + `cargo`，验证 Rust 侧 C ABI 的所有权与生命周期，与 Swift 无关 |
| `cargo test` / `cargo clippy` | Cargo |
| `test-packaged-app.sh` | python 驱动已签名包，本身不编译 |

## 3. 无法等价迁移的部分

按用户要求明确列出，不做删除或弱化。

**3.1 `-D NATIVE_SHORTCUT_TESTS` 那一路需要真实 AppKit 事件循环。**
`ConversationUITests.swift` 在该编译条件下换成另一个 `main()`，用 `NSApplication.run()` 进入真实事件循环，跑原生菜单快捷键路由、真实指针 monitor、项目选择器键盘滚动、搜索结果可达性激活、设置焦点、桌宠 composer 指针焦点——这些依赖真正的 key window 和系统事件派发。XCTest 的 `xctest` 宿主有自己的 run loop，`NSApplication.run()` 会阻塞。**P7c 必须先实测这一路能否在 XCTest 宿主里成立；若不成立，保留为独立 App target，由 scheme 的 Run action 驱动，并在本文件记录实测结论。**

**3.2 `AgentTaskSourceTests` 的替身类型只能靠源集排除成立。**
它自带一个 `AgentBridge` 类替换生产实现，靠编译时不纳入 `macos/AgentBridge.swift` 生效。任何把完整 App 模块链进来的方案（`TEST_HOST` + `@testable import`）都会让 `AgentTaskSource` 绑回真实类型。logic-test bundle 用显式源集可以保住；这也是不能把所有测试合并成一个 bundle 的原因。

**3.3 `macos/main.swift` 的顶层 `app.run()` 排除了标准 TEST_HOST 方案。**
用 `TEST_HOST = Echo.app` 会真的启动 Echo：建桌宠窗口、读用户真实的 `~/Library/Application Support/local.chiyan.desktop-pet/`、访问真实钥匙串。与现状（测试从不执行 `main.swift`）语义不同，且会碰用户真实数据。logic-test bundle 绕开了这一点。

**3.4 真实指针 UI 测试的既有不稳定性不在本轮解决。**
`docs/macos-27-native-ui-audit.md` §9 已记录：机器被占用时这些测试会整体挂起（干净树同样复现）。迁移不改变这一点，也不试图修。

## 4. 明确的非目标：本轮不改断言写法

`precondition` / `check` / `rejects` 一律原样保留，**测试文件本身不改一行断言**。理由：

- 1400 多个 `precondition` 调用点，逐个改写成 `XCTAssert` 的收益（失败后继续跑）在这些高度有状态的测试里未必是好事——失败后的后续断言在无效状态上执行，会产生误导性的连锁失败。
- 「一条失败即中止」是现状行为，保留它意味着迁移前后的失败语义完全一致，不需要逐条论证覆盖没丢。

P7 每个 bundle 只新增一个薄 wrapper 文件，声明 `XCTestCase` 并在 test 方法里调用已有的场景函数；对现有测试文件的改动至多是去掉 `@main`。

**留给将来的选项**（本轮不做）：`VoiceTests.check`、`WorkspaceTests` 与 `WorkspaceVoiceCommandTests` 的局部 `check` 三处是 580+ 条断言的唯一汇聚点，改成 `XCTFail` 即可让这批断言改为累积报告，无需碰调用点。

## 5. P7 的 target 划分

| 批次 | target | 形态 | 源集 | 取代 |
| --- | --- | --- | --- | --- |
| P7a | `EchoChatTests` | XCTest bundle | 8 文件子集 + ChatTests/ModelTests/SettingsTests | `test-chat.sh` |
| P7a | `EchoAgentTaskSourceTests` | XCTest bundle | 8 文件子集（排除 AgentBridge.swift）+ 测试 | `test-agent-task-source.sh` |
| P7b | `EchoAgentSessionTests` | XCTest bundle | all-except-main + 测试 | `test-agent-session.sh` |
| P7b | `EchoVoiceTests` | XCTest bundle | all-except-main + 5 个测试文件 | `test-voice.sh` |
| P7c | `EchoWorkspaceTests` | XCTest bundle | all-except-main + 3 个测试文件 | `test-workspace.sh` |
| P7c | `EchoConversationUITests` | XCTest bundle | all-except-main + ConversationUITests | `test-chat-ui.sh` 默认路径 |
| P7c | `EchoShortcutUITests` | 待实测（§3.1） | 同上 + `-D NATIVE_SHORTCUT_TESTS` | `test-chat-ui.sh --shortcuts-only` |
| P7d | `AgentBridgeProbe` / `AgentLiveProbe` / `VoiceLiveProbe` / `VoiceSoakProbe` / `AppleSpeechDeviceProbe` | App target | 各自源集 | 对应脚本的编译段 |
| P7d | `KeychainProbe` / `KeychainProbeRebuilt` | App target ×2 | `KeychainAuthorizationProbe.swift`，后者带 `-D SECOND_BUILD` | `test-signing.sh --keychain` 的编译段 |

每批的做法一致：**先加 target、与旧脚本并存**，两边跑同一组场景并对照通过后，再在同一提交里删掉旧脚本的 `swiftc` 段落。

## 6. 迁移实测结论

逐批记录实测结果，替换 §3 中的待验证项。

**P7a（`EchoChatTests` / `EchoAgentTaskSourceTests`）**

- logic-test bundle 方案成立：不设 `TEST_HOST` / `BUNDLE_LOADER`，把所需 `macos/` 源直接编进 bundle，`xcodebuild test` 正常运行，4 + 1 条 PASS 与旧脚本逐条一致、顺序相同。
- `@main` 留在 bundle target 里**不报错**，所以测试文件一行未改。
- §3.2 的替身类型经实测保住：`EchoAgentTaskSourceTests` 的源集不含 `macos/AgentBridge.swift`，`AgentTaskSource` 绑定到测试自带的那个，断言全过。

**P7b（`EchoAgentSessionTests` / `EchoVoiceTests`）**

- **§2.1 的分类在 `test-agent-session.sh` 上是错的，已更正**：该套件的 `testReopenAfterInvalidSettings` 用生产的 `AgentTaskSource(settings:)`，而后者写死 `Bundle.main.resourceURL`。旧的 bare CLI 位于 `build/`，脚本把 prompt 放在 `build/agent/conversation.md` 正是为此；XCTest bundle 里 `Bundle.main` 是 Xcode 的 `xctest`，拿不到。因此它迁成 **command line tool target**，`scripts/test-agent-session.sh` 保留为「备 prompt → xcodebuild → 运行产物」三行。测试文件一行未改，4 条 PASS 一致。
- `EchoVoiceTests` 可以留在 XCTest bundle：`AgentVoiceTests` 用的是 `AgentTaskSource(model:resources:)`，只依赖工作目录。
- Xcode 的 Test action **不接受自定义工作目录**（`customWorkingDirectory` 无效，cwd 落在 `/private/tmp`）。改由 `tests/cases/EchoTestEnvironment.swift` 用编译期 `#filePath` 推出项目根并 `changeCurrentDirectoryPath`，不依赖 scheme 配置。
- 计数核对：`testVoice` 631 条、`testAgentVoiceIntegration` 64 条，与旧脚本逐条一致。首次实测得到 695，原因是 `VoiceTests.checks` 是共享静态计数器而两个入口现在同进程先后运行（631 + 64）；断言未受影响，已在两个 suite 开头重置。
- **覆盖未丢、便利性有变**：`--dictation-only` 与 `--agent-only` 是 `VoiceTests.main()` **内部**的子选择，这些场景仍随 `testVoice` 全量运行，但不再有独立入口；把它们做成单独 test 方法会导致整套运行时重复执行。

**P7c（`EchoWorkspaceTests` / `EchoConversationUITests` / `EchoShortcutUITests`）**

- `EchoWorkspaceTests`、`EchoConversationUITests` 迁为 XCTest bundle，计数与旧脚本一致：工作区 7 条 PASS（含 92 项工作区检查、57 项语音命令检查），会话 UI 31 条 PASS。
- **§3.1 实测有结论**：`NATIVE_SHORTCUT_TESTS` 那一路**不能**做成 XCTest bundle。它的 `main()` 以 `NSApplication.run()` 进入真实事件循环并以 `exit(0)` 收尾，XCTest 宿主会把 `exit` 判为崩溃；场景函数又都是 `private`，无法从 wrapper 逐个驱动。已迁为 command line tool target `EchoShortcutUITests`，由 `scripts/test-native-shortcuts.sh` 构建并运行，9 条 PASS 与基线一致。
- **覆盖未丢、便利性有变**：`test-chat-ui.sh` 透传给测试可执行文件的选择 flag（`--pet-only`、`--phase4-only`、`--settings-only`、`--project-picker-scroll-only`、`--palette-accessibility-only`、`--voice-transcript-only`、`--status-text-only`）不再可用，这些场景仍随默认套件全量运行。原因同 P7b：`ConversationUITests.run()` 在内部消费这些 flag，把它们提成独立 test 方法会在整套运行时重复执行。

**P7d（探针目标）**

七个探针全部迁成 Xcode target，脚本只剩「构建 → 准备夹具 → 运行」：

| target | 形态 | 取代 | 验证状态 |
| --- | --- | --- | --- |
| `AgentBridgeProbe` | app（ad-hoc） | `test-agent-bridge.sh` | **已跑通**，输出与基线一致 |
| `AppleSpeechDeviceProbe` | app（脚本在加完音频夹具后 ad-hoc 签名） | `test-apple-speech-device.sh` | 构建、夹具生成、ad-hoc 签名与 `--verify --strict` 已验证；**未启动**（会弹语音识别授权） |
| `AgentLiveProbe` / `VoiceLiveProbe` / `VoiceSoakProbe` | app（Development 配置，证书签名） | 三个同名脚本 | **仅验证可构建**；运行需真实模型 / 语音服务与已保存凭据 |
| `KeychainProbe` / `KeychainProbeRebuilt` | app ×2（后者带 `SECOND_BUILD`） | `test-signing.sh --keychain` 的编译段 | **待验证**：本机钥匙串当前处于异常状态，见下 |

要点：

- `AppleSpeechDeviceProbe` 必须**不由 Xcode 签名**：脚本要在构建后往 `Contents/Resources` 里塞生成的音频，签名必须发生在那之后。它的 `Info.plist` 从脚本内联搬到了 `tests/apple-speech-probe/Info.plist`。该 target 不带资源，所以 `Contents/Resources` 需要脚本自己 `mkdir`。
- `tests/KeychainAuthorizationProbe.swift` 用的是顶层代码，Xcode 只在文件名为 `main.swift` 时允许，因此改名为 `tests/keychain-probe/main.swift`，**内容一字未改**。
- 探针目标必须带 `Check signing mode` 阶段：它负责解锁专用钥匙串。缺了它，codesign 会弹窗索要一个 `openssl rand -hex 32` 生成、只存在于 `.local-signing/password` 的口令。

**钥匙串卡死及其处置（迁移期间遇到的机器状态问题）**

本次迁移中途，`security unlock-keychain` 开始对 `.local-signing/echo.keychain-db` 报「passphrase 不正确」，签名相关的一切都被挡住。逐项排除的结论：

| 观察 | 结论 |
| --- | --- |
| 口令文件与钥匙串文件 mtime 均未变，口令是完整的 64 位十六进制 | 不是文件被改 |
| 同一份字节复制到 `/tmp/probe-copy.keychain-db`、`/tmp/echo.keychain-db`（同名）均能解锁 | 不是内容、不是口令、不是文件名 |
| 换 inode 后原路径仍失败 | 不是 inode |
| 清掉搜索列表里指向已删除 worktree 的同名条目后仍失败 | 不是搜索列表冲突 |
| 复制到 `.local-signing/signing.keychain-db` 能解锁 | **securityd 对那个确切路径的状态坏了** |

`signing-identity.sh` 因此改用 `signing.keychain-db`，并在旧文件存在时 `mv` 迁移——证书随文件走，所以身份 SHA-1、designated requirement 和应用已有的钥匙串授权都不变。迁移后 `test-signing.sh` 与 `--keychain` 全过，应用产物与基线逐项一致。

**同时更正一处误判**：`security find-identity -v -p codesigning` 返回「0 valid identities」**一直如此**，不是回归。脚本有意不给这张自签证书写信任设置，而 `-v` 只列有信任链的身份；`sign-app.sh` 的发现逻辑本来就只找 Apple 证书，找不到才自举。

**P8（收口）**

- `scripts/sign-app.sh` 删除。它最后一个调用者是自己的回归；`test-signing-offline.sh` 已改成对 Xcode 入口断言：ad-hoc 构建不碰钥匙串、不带 entitlements、签名为 adhoc；五条守卫拒绝每一种不安全模式；解析器仍拒绝 `-` 身份；scheme 的 Run action 绑定证书配置；资源封印仍然生效。顺带去掉了最后一处 `swiftc`（一个一行的合成夹具）。
- 全量回归全绿：`cargo test`（9 个套件）、`cargo clippy -D warnings`、`xcodebuild test -scheme EchoTests`（6 个 test case）、`test-agent-bridge.sh`、`test-agent-session.sh`、`test-native-shortcuts.sh`、`test-signing.sh`、`test-signing.sh --keychain`、`test-packaged-app.sh`。
- `grep -rn swiftc scripts/` 只剩两条注释。App 与全部测试、探针的编译现在都经由 `Echo.xcodeproj`。
