import AppKit
import Foundation

enum VoiceSoakOutcome: Sendable {
    /// The service finished the request rather than dropping it; the app reports this
    /// as "语音识别连接已结束", which is not the failure under investigation.
    case ended
    case dropped(String)
}

// Opt-in idle soak. Holds one ASR socket open on pure silence to reproduce the drop that
// only appears after a long quiet stretch, with no microphone, no synthesis and no model
// in the way. Nothing is recorded and nothing is uploaded but zeroed PCM.
#if ECHO_LEGACY_PROBE
@main
#endif
struct VoiceSoakTests {
    @MainActor static var utterances = 0
    @MainActor static var outcome: VoiceSoakOutcome?
    @MainActor static var outcomeSeconds: Int64 = 0
    @MainActor static func main() async {
        _ = NSApplication.shared
        do {
            try await run()
        } catch {
            print("FAIL: \(error is SettingsError ? error.localizedDescription : "语音静默浸泡未能启动。")")
            exit(error is VoiceSoakIncomplete ? 2 : 1)
        }
    }
    @MainActor static func run(duration: Double? = nil, disconnectAt: Double? = nil) async throws {
        utterances = 0; outcome = nil; outcomeSeconds = 0
        let arguments = Array(CommandLine.arguments.dropFirst())
        let limit = max(10, duration ?? arguments.first.flatMap(Double.init) ?? 120)
        // Test-only teardown at a chosen moment. It closes the socket under three live
        // operations, which is the race the reported error comes out of, so the origin
        // lines and the delegate's close and complete lines can be checked deliberately.
        var cut: Double? = disconnectAt
        if let flag = arguments.firstIndex(of: "--cut"), flag + 1 < arguments.count {
            cut = Double(arguments[flag + 1])
        }
        let settings = SettingsStore(url: SettingsStore.directory.appendingPathComponent("settings.json"))
        let credentials = try settings.savedVoiceCredentials()
        print("静默浸泡：单条 ASR 连接，上行纯静音，目标 \(Int(limit)) 秒。无麦克风 / 无 TTS / 无模型。")
        fflush(nil)
        // Byte for byte what idle listening uploads: 200 ms of 16 kHz mono PCM16 silence.
        let silence = Data(count: 6400)
        let (stream, input) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(10))
        let started = ContinuousClock.now
        func elapsed() -> Int64 { started.duration(to: .now).components.seconds }
        let feeder = Task {
            while !Task.isCancelled {
                input.yield(silence)
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
            input.finish()
        }
        let recognizer = DoubaoRecognizer()
        var disconnect: Task<Void, Never>?
        if let cut {
            disconnect = Task {
                do { try await Task.sleep(for: .seconds(cut)) } catch { return }
                print("  t=\(Int(cut))s 强制拆链（--cut）"); fflush(nil)
                recognizer.cancel()
            }
        }
        let recognition = Task {
            do {
                try await recognizer.run(key: credentials.key, audio: stream) { result in
                    if result.result?.utterances?.isEmpty == false { utterances += 1 }
                }
                outcome = .ended
            } catch {
                guard !(error is CancellationError) else { return }
                outcome = .dropped(error is SettingsError ? error.localizedDescription : VoiceDiagnostics.reason(error))
            }
            outcomeSeconds = elapsed()
        }
        defer { disconnect?.cancel(); recognizer.cancel(); feeder.cancel(); recognition.cancel(); input.finish() }
        var seconds = 0.0
        while seconds < limit, outcome == nil {
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
            seconds += 1
            if outcome == nil, seconds.truncatingRemainder(dividingBy: 10) == 0 {
                print("  t=\(Int(seconds))s 仍在线"); fflush(nil)
            }
        }
        feeder.cancel(); recognition.cancel(); input.finish()
        // The delegate reports close and completion asynchronously; exiting at once would
        // cut off the two lines that say whether the peer ever sent a close frame.
        try? await Task.sleep(for: .seconds(2))

        // An orderly teardown must not read like a fault. Every operation failed by our own
        // close is an ordinary event marked afterClose=true; a FAIL after that point would
        // put the same ENOTCONN a real drop reports into a healthy end of call.
        let lines = VoiceDiagnostics.shared.lines
        let afterClose = lines.lastIndex { $0.contains("客户端主动关闭") }
            .map { Array(lines[($0 + 1)...]) } ?? []
        let origins = afterClose.filter { $0.contains("origin=") }
        let spurious = origins.filter { $0.contains("] FAIL ") }
        let downgraded = origins.filter { $0.contains("afterClose=true") }
        for line in spurious { print("  意外的 FAIL：\(line)") }
        guard spurious.isEmpty else {
            print("FAIL: 主动关闭后仍记录了 \(spurious.count) 条 FAIL origin 行。")
            throw SettingsError("语音浸泡未满足连接或拆链验证条件。")
        }
        // A line that simply disappeared would satisfy the check above, so a forced teardown
        // has to show the downgraded event it is supposed to produce.
        if cut != nil, downgraded.isEmpty {
            print("FAIL: --cut 强制拆链没有产生 afterClose=true 事件，降级逻辑未被覆盖。")
            throw SettingsError("语音浸泡未满足连接或拆链验证条件。")
        }
        print("拆链检查：afterClose 降级 \(downgraded.count) 条，FAIL 0 条。")

        switch outcome {
        case .none:
            print("PASS: \(elapsed()) 秒内连接保持在线，未断开（静默中返回 \(utterances) 次识别结果）。")
        case .ended:
            print("ENDED: ASR 在 \(outcomeSeconds) 秒后由服务端正常结束（final 帧），不是异常断开。")
            throw VoiceSoakIncomplete()
        case .dropped(let message):
            // With --cut the drop is the point of the run, not a failure of it.
            guard cut == nil else {
                print("PASS(--cut): 强制拆链在 \(outcomeSeconds) 秒后按预期结束。UI 文案：\(message)")
                return
            }
            print("DROP: 连接在 \(outcomeSeconds) 秒后断开。")
            print("  UI 文案：\(message)")
            print("  首因见上方 stderr 中 origin=send / receive / ping 三行，以及 delegate close / complete 两行。")
            throw SettingsError("语音浸泡未满足连接或拆链验证条件。")
        }
    }
}

struct VoiceSoakIncomplete: Error {}
