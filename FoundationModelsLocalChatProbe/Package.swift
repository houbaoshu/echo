// swift-tools-version: 6.2
// 独立的本地 Core AI 模型 chat-only 探针。与 Echo.xcodeproj、Rust workspace、
// FoundationModelsAgentProbe 完全隔离，删除整个 FoundationModelsLocalChatProbe/ 目录即可移除。
import PackageDescription

let package = Package(
    name: "FoundationModelsLocalChatProbe",
    platforms: [.macOS("27.0")],
    dependencies: [
        // 本地 apple/coreai-models 克隆（与 echo 仓库同级），提供 CoreAILanguageModel: LanguageModel。
        .package(path: "../../coreai-models")
    ],
    targets: [
        .executableTarget(
            name: "fm-local-chat-probe",
            dependencies: [
                .product(name: "CoreAILM", package: "coreai-models")
            ],
            swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        )
    ],
    swiftLanguageModes: [.v6]
)
