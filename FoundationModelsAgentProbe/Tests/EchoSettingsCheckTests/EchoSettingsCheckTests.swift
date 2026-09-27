import EchoSettingsCheck
import FoundationModels
import Testing

@MainActor @Suite struct EchoSettingsCheckTests {
    @Test func `harness shape compiles and runs under Echo settings`() async throws {
        let harness = CheckHarness()
        let first = try await harness.turn("one")
        let second = try await harness.turn("two")
        for entry in harness.log.all { print("REPORT S0 \(entry.tag) main=\(entry.main)") }
        print("REPORT S0 live=\(harness.live) requestsSeenHistory=\(harness.requestsSeenHistory)")
        #expect(first == "reply 1 done")
        #expect(second == "reply 2 done")
        // 第二轮的 session 由 harness history（不含 instructions）重建，instructions 由 profile 补上
        #expect(harness.requestsSeenHistory == [1, 5])
        #expect(harness.history.count == 6)
        // 流式快照回到主线程投影
        #expect(harness.live.contains { $0.hasPrefix("reply 1") })
        // executor、hooks、tool 均不在主线程
        #expect(harness.log.all.filter { $0.tag != "harness.after" }.allSatisfy { !$0.main })
    }
}
