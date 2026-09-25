# Echo

Apple Silicon Mac 上的原生桌宠、AI 对话与 Agent 工作区。Swift / AppKit / SwiftUI 提供界面，Rust 提供 Agent 与精灵运行时。[使用说明](docs/user-guide.md)包含配置、快捷键和数据位置。

## 环境与运行

需要 macOS 27、Xcode 27（Swift 6）、Rust/Cargo，以及相邻的 `../mini-agent-rs` 路径依赖。本轮依赖验收 revision：`57d3d53`。首次构建需下载 Cargo 依赖。

打开 `Echo.xcodeproj`，选择 **Echo**：

- **⌘R**：`DevelopmentDebug`，Apple Development 签名、无优化、LLDB 断点。
- **⌘U**：默认 **EchoFast**，确定性的业务行为测试。
- **Product → Scheme → Test Plan**：选择其他计划，或在 Test Navigator 单独运行一个场景。

开发签名 Team 位于 `Echo-Development.xcconfig`；先在 Xcode Accounts 配置自己的 Apple Development 证书。`Debug` / `Release` 使用 ad-hoc；`Development` 保留优化后的开发签名。缺少证书不会自动切换身份。

所有正常产物在 DerivedData；Rust adapter 与 Swift 链接共用 `$(OBJROOT)/EchoCargo`，各 Swift 配置继续链接 release Rust。prompt 从 Cargo 实际解析依赖复制到 App／测试 bundle，运行时不需要源码目录。

## 测试计划

| Scheme / Plan | 范围 |
|---|---|
| Echo / **EchoFast** | Chat、Model、Settings、TaskSource 替身、假音频与回放、工作区逻辑；无 App 自动化、HTTP fixture 或设备 |
| Echo / **EchoOffline** | Fast + 文件系统、组件、真实 Swift↔Rust、App hosted、XCUITest |
| Echo / **EchoSanitizers** | 公开 C ABI 所有权；ASAN 只插桩 C/Swift 消费者 |
| Echo / **EchoPerformance** | `TestPerformance` 配置；时钟、CPU、内存 metrics |
| Echo-Live / **EchoLive、EchoSoak** | 手动真实模型、ASR/TTS 与长连接；读取生产身份的凭据 |
| Echo-Device / **EchoDevice** | 手动 Apple 本地识别；固定合成 WAV、真实 Speech 权限与语言资源 |

离线测试使用临时工作区、内存凭据与假设备。XCUITest 需要桌面会话和 macOS UI Automation 认证；运行期间会操作测试 App 的窗口。Live／Device 不在默认或离线计划中，缺少条件或提前结束不算通过。

```sh
ECHO_VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/echo-native.XXXXXX")"
xcodebuild test -project Echo.xcodeproj -scheme Echo -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ECHO_VERIFY_ROOT/DerivedData" \
  -testPlan EchoFast -resultBundlePath "$ECHO_VERIFY_ROOT/Fast.xcresult"
# 完整离线回归：将 EchoFast / Fast.xcresult 换成 EchoOffline / Offline.xcresult
# 单个场景加：'-only-testing:EchoVoiceTests/EchoVoiceScenarios/VoiceTests/snapshotTests()'
# 性能计划加：-configuration TestPerformance -testPlan EchoPerformance

cargo test --locked --workspace --target-dir "$ECHO_VERIFY_ROOT/Cargo"
cargo clippy --locked --workspace --all-targets \
  --target-dir "$ECHO_VERIFY_ROOT/Cargo" -- -D warnings
```

Cargo 只负责本仓库的 Rust 测试；相邻依赖保留自己的 Cargo 测试。Swift 测试的日志、截图与请求记录进入 `.xcresult` 或系统临时目录。

## 产品系统验收

系统验证器只消费 Xcode 已构建产品：

```sh
xcodebuild build -project Echo.xcodeproj -scheme Echo -configuration Release \
  -derivedDataPath "$ECHO_VERIFY_ROOT/DerivedData"
xcodebuild build -project Echo.xcodeproj -scheme Echo-SystemFixtures -configuration Release \
  -derivedDataPath "$ECHO_VERIFY_ROOT/DerivedData"
/bin/zsh scripts/test-signing.sh \
  --app "$ECHO_VERIFY_ROOT/DerivedData/Build/Products/Release/Echo.app"
python3 tests/packaged-app-test.py \
  --app "$ECHO_VERIFY_ROOT/DerivedData/Build/Products/Release/Echo.app" \
  --fixture-server "$ECHO_VERIFY_ROOT/DerivedData/Build/Products/Release/EchoFixtureServer" \
  --output "$ECHO_VERIFY_ROOT/System"
```

真实 Keychain 连续性另行手动验证：向 `test-signing.sh` 传入 `--keychain-first`、`--keychain-rebuilt`（两份 Development fixtures）与 `--keychain-unrelated`（不同签名 fixture）。验证器仅操作并清理合成测试凭据。

## 手动诊断与迁移状态

- **Echo-Diagnostics**：默认 `--dictation-trace-auto`；Scheme 中可切换到 `--diagnose-voice`。只在显式启动时启用，日志写私有临时文件；听写日志包含完整转写。语音诊断需生产凭据和设备，180 秒超时报告失败。
- **EchoFrameworkRepros**：Run 参数选择 scroll-anchor-tail、swiftui-outline-list-reentrancy、textkit2-composer-sync、status-color-contrast、window-focus-ring；不进入测试计划。
- `measure-voice-startup.sh --pid PID --helper BUILT_EchoCoreAudioProbe`：仅做进程外日志和设备占用采样，App 启动与操作由 Xcode／UI 测试负责。

Live／Soak／Speech 原生宿主已可构建，真实服务与设备对照尚未执行。因此四个旧手动 probe 及其 `--app BUILT_PROBE_APP` wrapper 暂保留，完成同条件对照后退役。[迁移记录](docs/xcode-native-migration.md)记录场景标识、实测证据及剩余门槛。
