import AppKit
import XCTest
@testable import Echo

final class PerformanceTests: XCTestCase {
    /// Synchronous admission/cancellation on the main actor. Device and network
    /// startup remain explicit external diagnostics with the same signing identity.
    @MainActor func testVoiceStartupAdmissionAndCancellation() {
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            let store = TaskStore(harness: AgentHarness(resolveModel: { TestBootstrap.OfflineModel.factory }))
            let conversation = WorkspaceConversation(store: store)
            let voice = VoiceSessionController(audio: TestBootstrap.Audio(),
                recognizer: { TestBootstrap.Recognizer() }, synthesizer: { TestBootstrap.Synthesizer() },
                permission: { true })
            defer { voice.shutdown(); store.shutdown() }
            XCTAssertTrue(voice.start(conversation: conversation, configuration: VoiceConfiguration(), key: "fixture"))
            voice.end(reason: .user)
            XCTAssertFalse(voice.isActive)
        }
    }

    @MainActor func testRuntimeSpriteLoadAndCopy() throws {
        let root = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("pets/chiyan")
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            do {
                let store = try PetStore(directory: root)
                XCTAssertGreaterThan(store.image.width, 0)
                store.stop()
            } catch { XCTFail("Runtime load failed: \(error)") }
        }
    }

    @MainActor func testTranscriptPersistenceEncoding() {
        let messages = (0..<200).map { ConversationMessage(role: $0.isMultiple(of: 2) ? .user : .assistant,
            content: "离线性能样本 \($0)：正文、Unicode 🌱 与 `code`。") }
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            do {
                let data = try JSONEncoder().encode(messages)
                let decoded = try JSONDecoder().decode([ConversationMessage].self, from: data)
                XCTAssertEqual(decoded.count, messages.count)
            } catch { XCTFail("Transcript coding failed: \(error)") }
        }
    }
}
