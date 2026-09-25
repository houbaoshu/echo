import XCTest
@testable import EchoSpeechHost

final class SpeechDeviceTests: XCTestCase {
    @MainActor func testChinese() async throws { try await AppleSpeechDeviceTests.run(selected: "zh-CN") }
    @MainActor func testEnglishWithChineseRecognizer() async throws { try await AppleSpeechDeviceTests.run(selected: "en-US") }
    @MainActor func testMixedLanguage() async throws { try await AppleSpeechDeviceTests.run(selected: "mixed") }
    @MainActor func testThreePhrasesSurviveFourSecondPauses() async throws { try await AppleSpeechDeviceTests.run(selected: "paused") }
}
