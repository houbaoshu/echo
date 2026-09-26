// swift-tools-version: 6.2
// 独立的 Foundation Models Agent harness 探针。与 Echo.xcodeproj、Rust workspace 完全隔离，
// 删除整个 FoundationModelsAgentProbe/ 目录即可移除。
import Foundation
import PackageDescription

/// `EchoExecutorFFI/` 是探针专用 Rust staticlib（只读依赖 mini-agent-rs 的生产执行器）。
/// 先 `cargo build --release --manifest-path EchoExecutorFFI/Cargo.toml`，再 `swift build`。
let ffiLibDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("EchoExecutorFFI/target/release").path

let package = Package(
    name: "FoundationModelsAgentProbe",
    platforms: [.macOS("27.0")],
    dependencies: [
        // Apple 官方 utilities，提供 ChatCompletionsLanguageModel。锁定到调查时的提交。
        .package(
            url: "https://github.com/apple/foundation-models-utilities.git",
            revision: "cc3820def1fe016bc6cd49d958cd2f2a29be76a8"
        )
    ],
    targets: [
        .target(name: "CEchoExec"),
        .target(
            name: "AgentProbe",
            dependencies: [
                "CEchoExec",
                .product(name: "FoundationModelsUtilities", package: "foundation-models-utilities"),
            ],
            swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")],
            linkerSettings: [.unsafeFlags(["-L", ffiLibDir]), .linkedLibrary("echo_probe_exec")]
        ),
        .executableTarget(
            name: "fm-agent-probe",
            dependencies: ["AgentProbe"],
            swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
        .testTarget(
            name: "AgentProbeTests",
            dependencies: ["AgentProbe"],
            swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
