// swift-tools-version: 6.2
// 独立的 native coding harness 探针：Foundation Models + 纯 Swift coding tools，不依赖 Rust / mini-agent-rs。
// 与 Echo.xcodeproj、Rust workspace、其它探针完全隔离，删除整个 FoundationModelsNativeCodingProbe/ 目录即可移除。
import PackageDescription

let package = Package(
    name: "FoundationModelsNativeCodingProbe",
    platforms: [.macOS("27.0")],
    dependencies: [
        // Apple 官方 utilities，提供 ChatCompletionsLanguageModel（DeepSeek 对照用）。与 AgentProbe 锁定同一提交。
        .package(
            url: "https://github.com/apple/foundation-models-utilities.git",
            revision: "cc3820def1fe016bc6cd49d958cd2f2a29be76a8"
        )
    ],
    targets: [
        .target(
            name: "NativeCoding",
            dependencies: [
                .product(name: "FoundationModelsUtilities", package: "foundation-models-utilities")
            ],
            swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
        .executableTarget(
            name: "fm-native-coding-probe",
            dependencies: ["NativeCoding"],
            swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
        .testTarget(
            name: "NativeCodingTests",
            dependencies: ["NativeCoding"],
            swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
