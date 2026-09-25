# Echo 原生测试迁移记录

基线：Echo `61f1e113395c66653c29535889b309ce06012c9f`；相邻 mini-agent-rs `57d3d53f0191362abbe23409f766731415a8eb34`。上游路径依赖测试继续由其仓库管理。

## 验证证据

所有本次日志和 xcresult 位于 `/private/tmp/echo-native-migration/`。该目录不提交。沙箱内首次尝试因 Swift 宏插件和 Rust host dylib 加载失败，未执行测试；清除本次临时 checkout 的 Rust 缓存后重跑。真实服务、Keychain 授权及 Speech 设备测试尚未执行。历史基线报告不作为本轮通过证据。

基线实测：`BehaviorBaseline.xcresult` 发现 6 个 XCTest，5 通过、1 runner crash、0 skip。崩溃为 `VoiceTests.swift:171` 的 “the page starts from a successful test”，调用场景 `settingsPageRevisitKeepsSuccessTests`；旧实现使用固定短 sleep 等待异步成功，`VoiceRetry.xcresult` 单独重跑通过；固定 25 ms sleep 存在调度敏感性。Session CLI 和 Bridge Probe 完整通过。所有旧断言与场景源码保持原样。

构建基线修正：原 adapter 传入 SDKROOT/MACOSX_DEPLOYMENT_TARGET 时，干净构建的 zerofrom_derive dylib 出现 `mis-aligned LINKEDIT string pool`。原生 Cargo 和移除这两个 host 环境变量的最小隔离环境均完成 release 构建。行为基线仅在临时副本跳过 adapter，使用相同源码单独构建的静态库；不计为原工程干净构建通过。

## 迁移门槛

按 inventory → 构建/资源/宿主隔离 → 原生断言 → production bridge → UI → 手动计划 → 退役 → 干净 checkout 验收推进。旧入口仅在等价原生场景通过后退役。未实测的场景不能记为通过。

## 场景映射

[逐场景映射](xcode-native-cases.tsv)列出旧场景、原生 test identifier、fixture 源码与该场景实测证据。Swift Testing 的参数化标识保留参数标签，具体输入由 Xcode Test Navigator／xcresult 展开；同一用例在不同计划中只注册一次。

| 旧入口 | 当前职责与新入口 |
|---|---|
| 五个粗 XCTest wrappers | 已删除；Chat/TaskSource/Voice/Workspace Swift Testing，View XCTest |
| Bridge Probe、Session CLI、AgentVoice production | EchoIntegrationTests，共享真实 loopback HTTP/SSE fixture |
| 快捷键 CLI | 部件/IME → EchoViewTests，精细 responder/滚动 → EchoAppIntegrationTests，真实输入 → EchoUITests；8 个 UI 与 9 个 hosted 场景已分别整批通过 |
| 两份 clang ASAN 编排 | EchoCABITests / EchoSanitizers；保留公开 C ABI |
| packaged 业务/历史断言 | HistoryIntegrationTests；系统验证器只检查产品边界 |
| Live / Soak / Speech probes | 新 hosted plans 可构建，旧手动入口等待真实环境同条件对照；未执行不能记为通过 |
| 语音诊断 / 听写追踪 | Echo-Diagnostics，显式参数、私有临时日志、超时和回调摘要 |
| CoreAudio 即时编译 | EchoCoreAudioProbe；外部采样器只消费预构建工具 |

## Phase 2 验证

- `Phase2Resources.xcresult`：8 个 XCTest 全部通过，0 skip，保留旧行为断言验证 bundle 资源迁移。
- Rust release 库位于 `DerivedData/Build/Intermediates.noindex/EchoCargo`；无 repo `build/target`。原有目录完整移动到 `/private/tmp/echo-native-migration/preexisting/`，未删除。
- hosted bundle 仅 `@testable import Echo`；测试实际默认 prompt 开 session、确认清理，以及宿主未建立用户工作区窗口。
- 首次 UI smoke 被 macOS “Enable UI Automation”认证阻挡；用户认证后，修正 runner 容器临时目录校验，`Phase2UIContainer.xcresult` 1 个真正 XCUITest 通过。
- `DevelopmentDebug` 构建成功；LLDB 在隔离 hosted 模式命中 `main.swift:12`，日志 `lldb.log`。

## Phase 3 / Chat + TaskSource

`NativeFastRetry.xcresult` / `FastRestored.xcresult`：20 个 Swift Testing 方法（含参数化场景），全部通过。`FailureProbe.xcresult` 临时反转 `AgentTaskSourceTests.wireTests` 的 history 断言，确认失败精确定位原用例与源码；随后自动恢复并通过完整 Fast。未改生产业务语义。

Model 请求协议、失败种类和配置迁移端点分别参数化；取消、SSE framing、回复、未知存档版本独立运行。旧 Chat/TaskSource XCTest 总入口已删除。最终收口时进一步拆出历史兼容、缺配置、不可读凭据和保存回滚，`ChatSettingsSeparated.xcresult` 的 16 个 Chat/Model/Settings 方法通过。

## Phase 3 / Voice + Workspace

`NativeVoiceWorkspace.xcresult` 通过：Voice 47 个 Swift Testing 方法，含 Apple Speech/Dictation 录制回放和假音频；Workspace 10 个方法，含真实临时文件/权限/watcher。Voice 使用串行父 suite 隔离共享 diagnostics；旧 AgentVoice production 集成入口暂保留，等待 Phase 4。固定等待连接成功改为明确条件与 deadline。

## Phase 3 / View

`NativeViewIsolated.xcresult`：30 个独立 XCTest 全部通过（71 秒），0 skip。Target 更名 EchoViewTests；IME/TextKit/布局/视图组件断言原生化，截图输出系统临时目录。真实事件旧 CLI 暂移至 `tests/legacy/ShortcutRegression.swift`，仅在 UI 等价场景通过后删除。

## Phase 4 / Production integration

- `NativeIntegrationSockets.xcresult`：Bridge 2 + Session 13 个原生方法通过。Swift loopback HTTP/SSE fixture 保留真实 socket、分段 Unicode、工具、延迟、取消和断线；监听使用非阻塞 accept + 50ms poll，关闭有明确 deadline。
- `NativeIntegrationVoice.xcresult`：Voice 47 个原生方法与 Integration 通过；AgentVoice 的五种路由 × 两协议，以及 Markdown 流式 × 两协议转入 Integration，不再由 Voice 粗包装重复执行。假音频与 fixture 提取共享支持文件。
- `NativeHistoryRuntimeRetry.xcresult`：Integration 21 个方法（含 14 个参数化输入）全部通过。新增真实 read/edit/verify、跨协议恢复、v1 history/v2 checkpoint/receipt/projection/opaque reasoning 校验；新增 Runtime 错误、真实帧复制、销毁后 CGImage 数据生命期覆盖。
- `NativeCABI.xcresult`：XCTest 驱动公开 C ABI 的 500 次 create/poll/reject/cancel/destroy/free，Address Sanitizer 通过。C 条件失败返回源码行到 XCTest；只对 C/Swift 消费者插桩，不宣称覆盖 Rust 内部所有访存。
- 原 Session CLI 转为 EchoIntegrationTests；旧 AgentBridgeProbe、三个重复 shell、model Python fixture、Voice 粗包装和全局 cwd helper 退役。session Python fixture 暂供 packaged 系统入口，待 Xcode FixtureServer 建成后删除。
- 所有 Integration suites 共享串行父 suite；每场景独立临时目录与端口，关闭后检查 Rust 活跃会话归零。真实服务、Speech、Keychain 授权测试未运行。

## Phase 5 / 原生 UI、性能与手动入口

- `NativeUIProjectsVoicePet.xcresult`：5 个真正 XCUITest 通过，覆盖发送/流式/Stop/Retry/退出重启、搜索/设置、项目/预览/解绑、假音频和桌宠独立草稿。macOS UI Automation 经用户系统认证后可用。
- `NativeHostedFinal.xcresult`：7 个 hosted XCTest 通过；真实 App 默认 prompt、启动隔离、菜单/IME、指针监控、滚动锚点、项目列表键盘滚动、AX 激活。随后补充的设置 responder 与侧栏 Tab/面板几何分别在 `NativeSettingsSidebarRows` / `NativeSidebarGeometry` 通过；真实输入扩展仍在验证。
- `NativePerformanceRetry.xcresult`：2 个 optimized/ad-hoc XCTest metrics 场景通过（Runtime 精灵加载/帧复制；会话编码）。没有将真实服务波动作为日常阈值。
- `manual-live-build.log`、`manual-device-build.log`：Live/Soak、Device 测试宿主 DevelopmentDebug build-for-testing 通过。hosted bundle 只导入宿主模块，无重复 production 源和 Rust runtime。真实服务、Speech、Keychain 未执行。
- 固定 Speech WAV 与旧生成资源字节一致；格式、帧数和 SHA-256 见 `tests/fixtures/speech/README.md`。四秒停顿、相同短语保留。
- `framework-repros-build.log`：可选 Repros Target 构建通过，5 个场景不依赖 Echo/Rust，不进入 Test Plan。历史视觉原型已删除，三个产品探索入口仅保留调查结论。

## Phase 6 / 系统验证器收口

- `system-fixtures-retry.log`：Swift loopback server 与 CoreAudio 工具、独立 wrapper/module 的 Keychain fixtures 构建通过。
- `signing-native.log`：Release ad-hoc、无 entitlements、资源篡改负例通过（只修改临时副本）。未进行真实 Keychain 授权测试。
- `packaged-native.log`：已构建的 Release App 搬至含空格路径，空 cwd 加载 pet/prompt；系统 dylib、普通 AppKit 退出、Rust shell/child 清理通过。证据目录 `System/packaged-liqrn185`。
- 两个 Python 模型服务均由共享 Swift socket fixture 替代。旧打包 build wrapper、offline signing wrapper、旧 prompt/Swift 环境/音频生成脚本及旧 EchoTests Scheme 已退役。
- 四个服务/设备旧手动 wrapper 暂保留，仅接收 `--app`；不构建、不写 repo。按用户计划，必须真实同条件对照后才能删除，当前不宣称这部分迁移完成。

## 最终收口复验

- `FastTagged.xcresult`：确认 Xcode 27 原生 tag 筛选实际发现 72 个方法（12 Chat、8 TaskSource、46 Voice、3 Workspace、3 presentation），并排除组件 XCTest。随后 Chat/Settings 新拆出 4 个独立场景；最终 Fast 应发现 76 个方法。
- `UIEight.xcresult`：8 个 XCUITest 整批通过；完整设置行点击、未保存编辑、侧栏行/分组/悬停、搜索隔离、桌宠焦点与草稿、项目解绑、假音频和重启恢复。
- `HostedVisibleSidebar.xcresult`：9 个 hosted 方法整批通过。修正 fixture 的初始窗口尺寸，明确侧栏可见；保留完整正反向 Tab 循环，未修改产品焦点逻辑。
- `manual-live-final-build.log`、`manual-device-final-build.log`、`manual-legacy-final-build.log`：新 Live/Device 宿主与四个保留的旧 probe 全部可构建；未调用真实服务/设备。
- `final/clean-build.log`：独立源码 checkout（相邻依赖为独立副本），无旧 build/target 的 Offline build-for-testing 通过。
- `final/cargo-test.log`、`final/cargo-clippy.log`：16 个 Rust 测试通过，clippy --all-targets -D warnings 通过。
- `final/incremental-evidence.json`：隔离修改本仓库与相邻依赖 Rust 源，两个静态库 hash 均变化；依赖 prompt 在 App/Voice/Integration bundle 同步更新。源码已恢复并重建，未修改用户的相邻仓库。
- `sampling-complete-result.txt` / `sampling-incomplete-result.txt`：外部采样摘要接受完整记录、拒绝只有开始标记的不完整采样；没有启动真实音频设备。

- `DomainFailureAttributionComplete.xcresult`：Voice snapshot、Workspace quick composer、Presentation column thresholds 三个精确 identifier 均只报告预期的原生 issue（3 fail / 0 pass / 0 skip，无 runner crash），错误指向各自 Swift 源码行；临时注入已由 finally 恢复。

## Phase 7 / 最终验收（2026-09-25）

本节为最终状态；前述分阶段结果保留当时的中间状态。验收源码位于 `final/echo` 的独立 Git checkout，相邻 `final/mini-agent-rs` 为独立副本，首次构建没有旧 `build/target` 或缓存产物。最终源码与工作区一致（验收报告的后续补记除外）。

| 最终证据 | 结果 |
|---|---|
| `final/FastFinal.xcresult` | 76 个原生方法通过，0 fail / 0 skip；Chat 16、TaskSource 8、Voice 46、Workspace 3、presentation 3 |
| `final/OfflineFinal.xcresult` | 149 个方法通过，0 fail / 0 skip；Chat 16、TaskSource 8、Voice 47、Workspace 10、View 30、hosted 9、UI 8、production integration 21 |
| `final/Sanitizers.xcresult` | 1 个 C ABI 方法、500 次 handle 生命周期通过；能力边界仍是 C/Swift 消费者 ASAN |
| `final/Performance.xcresult` | 3 个 XCTest metrics 方法通过：Runtime/帧复制、会话编码、假设备下同步语音 admission/cancel；TestPerformance 优化配置 |
| `final/cargo-test.log` / `final/cargo-clippy.log` | 16 个本仓库 Rust 测试通过；all-targets clippy -D warnings 通过 |
| `final/release-build.log` / `final/system-fixtures-build.log` | Release 产品与系统 fixture 构建通过 |
| `final/signing.log` | ad-hoc、无 entitlements、临时副本篡改负例通过 |
| `final/packaged.log` / `final/System/packaged-q4sj1tx9` | 含空格搬包路径、空 cwd、默认资源、系统 dylib、正常 AppKit 退出、shell/子进程清理通过 |
| `final/development-debug-build.log` / `final/lldb.log` | DevelopmentDebug 构建通过；LLDB 命中生产 `AppDelegate.applicationDidFinishLaunching` 的 `main.swift:13` |
| `final/invalid-bootstrap.json` | 不完整 UI 参数及未知测试模式均在 workspace 初始化前以 status 2 退出 |
| `final/framework-repros-build.log` | 可选 framework Repros Target 构建通过；手动系统状态复现未运行 |
| `final/cleanliness.json` | Git 与 ignored 清单前后一致；源码 checkout 无 build/target/.build/DerivedData，无残余 fixture/App 进程 |

逐场景 TSV 已与上述结果树核对：153 个唯一原生方法（149 Offline + 1 ASAN + 3 performance）都有 test identifier、fixture 和通过证据。参数化方法的各输入由 xcresult 展开。Fast 是 Offline 的子集，不另计重复入口。

Offline 保留 11 条 AppKit/SwiftUI runtime warning（小窗口 toolbar 约束和视图更新期间发布状态）；没有隐藏或关闭这些诊断，也没有 runner crash。它们不是本次测试失败，迁移没有据此修改产品行为。Fast、ASAN、Performance 没有 runtime warning。

## 手动门槛与保留入口

Live / Soak / Speech / 真实 Keychain 未执行，不计为通过。`manual-signing-identities.json` 已静态确认新旧宿主的 bundle identifier 与开发签名 Team 一致；这不能替代真实授权与服务对照。四个旧 probe 与消费预构建 App 的 wrapper 按门槛保留，只有同条件手动对照完成后才退役。

现保留 8 个 shell（2 个构建/资源 adapter、2 个系统观察/签名验证器、4 个过渡手动 probe wrapper）和 1 个 Python 产品系统验证器。正常 Swift 编译及测试由 Xcode 负责；Cargo 测试继续由 Cargo 负责。原有历史产物仍完整保存在 `preexisting/`，没有删除。
