import Foundation
import Combine
import OSLog

/// Why a Live Voice call ended, one case per `VoiceSessionController.end` call site, so a log
/// can tell a user's click from each failure path without matching on message text.
enum VoiceEndReason: String, Sendable {
    case user = "用户结束"
    case uploadBacklog = "上传积压（audioInput 满 10 包）"
    case captureFailed = "采集流错误"
    case captureEnded = "采集流结束"
    case firstPacketTimeout = "麦克风首包超时"
    case permissionDenied = "麦克风权限被拒"
    case audioStartFailed = "音频设备启动失败"
    case audioDevice = "音频设备变化/播放器故障"
    case audioRecoveryFailed = "音频设备恢复失败"
    case audioPlayerFailed = "音频播放器故障"
    case recognitionClosed = "ASR 连接被关闭"
    case recognitionFailed = "ASR socket/服务错误"
    case replyFailed = "模型回复失败"
    case synthesisInput = "合成文本输入错误"
    case playbackFailed = "TTS socket/播放错误"
    case retired = "会话被退役"
    case systemSleep = "系统睡眠"
    case conversationDeleted = "会话被删除"
    case shutdown = "应用退出"
    case unspecified = "未标注来源"
}

/// What ended VoiceAudio's session, so a call's end reason tells the three apart.
enum VoiceAudioFailure: Equatable, Sendable {
    /// The policy decided against recovering from a configuration change.
    case deviceChange
    /// A recovery was attempted and did not bring the call back.
    case recoveryFailed
    case player
}

extension VoiceEndReason {
    init(_ failure: VoiceAudioFailure) {
        switch failure {
        case .deviceChange: self = .audioDevice
        case .recoveryFailed: self = .audioRecoveryFailed
        case .player: self = .audioPlayerFailed
        }
    }
}

// Only locally constructed metadata belongs here. Never log keys, request headers,
// transcripts, remote error bodies or raw audio.
@MainActor final class VoiceDiagnostics: ObservableObject {
    static let shared = VoiceDiagnostics()
    @Published private(set) var lines: [String] = []
    private let logger = Logger(subsystem: "local.chiyan.desktop-pet", category: "voice")
    var text: String { lines.joined(separator: "\n") }

    func record(_ stage: String, _ status: String, _ message: String) {
        let line = "\(Date().ISO8601Format()) [\(stage)] \(status) \(message)"
        lines.append(line)
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        logger.notice("\(line, privacy: .public)")
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    // MARK: - Live Voice timeline

    // One call's millisecond marks, measured from the click that started it, plus why it ended.
    // Lines are written only while a call is open, so the spans on shared paths (PlanetStore,
    // workspace saves) stay silent the rest of the time. Signposts are always emitted, so the
    // same stages line up with Time Profiler in Instruments ("voice-timeline" category).
    private let signposter = OSSignposter(subsystem: "local.chiyan.desktop-pet", category: "voice-timeline")
    private var timelineStart: ContinuousClock.Instant?
    var isTimelineOpen: Bool { timelineStart != nil }

    func beginTimeline(_ entry: String) {
        timelineStart = .now
        signposter.emitEvent("voice.begin", "\(entry, privacy: .public)")
        record("计时", "MARK", "+0.0ms 开始（\(entry)）")
    }
    /// Drops a timeline whose call never started, so its spans do not leak into ordinary saves.
    func cancelTimeline() { timelineStart = nil }

    func mark(_ name: String) {
        signposter.emitEvent("voice.mark", "\(name, privacy: .public)")
        guard let offset = offset(at: .now) else { return }
        record("计时", "MARK", "\(offset) \(name)")
    }

    /// Times a synchronous stretch of main-thread work. `quietAfter` keeps a recurring span (the
    /// workspace save) from flooding the 300-line buffer once startup is over: past that point
    /// only runs at least `quietBelow` long are written.
    func measure<T>(_ name: StaticString, _ detail: @autoclosure () -> String = "",
                    quietAfter: Duration? = nil, quietBelow: Duration = .milliseconds(16),
                    _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let begin = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            let duration = begin.duration(to: .now)
            if let start = timelineStart, let offset = offset(at: begin) {
                let quiet = quietAfter.map { start.duration(to: begin) > $0 && duration < quietBelow } ?? false
                if !quiet {
                    let extra = detail()
                    record("计时", "SPAN", "\(offset) \(name) 耗时 \(Self.milliseconds(duration))\(extra.isEmpty ? "" : " \(extra)")")
                }
            }
        }
        return try body()
    }

    /// A span timed elsewhere (off the main actor, or across an await), written from its own
    /// start instant so it lines up with the marks. No signpost: the interval is already over.
    func recordSpan(_ name: String, start: ContinuousClock.Instant, duration: Duration) {
        guard let offset = offset(at: start) else { return }
        record("计时", "SPAN", "\(offset) \(name) 耗时 \(Self.milliseconds(duration))")
    }

    /// The call's single termination line. `detail` carries what the caller knows about the
    /// session at that moment.
    func endTimeline(_ reason: VoiceEndReason, detail: String) {
        let offset = offset(at: .now) ?? "+?"
        signposter.emitEvent("voice.end", "\(reason.rawValue, privacy: .public)")
        record("通话结束", "REASON", "\(offset) \(reason.rawValue) \(detail)")
        timelineStart = nil
    }

    private func offset(at instant: ContinuousClock.Instant) -> String? {
        timelineStart.map { "+" + Self.milliseconds($0.duration(to: instant)) }
    }
    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1fms", duration / .milliseconds(1))
    }

    // `nonisolated` so a URLSession delegate callback, which never runs on the main actor,
    // can summarise its error there and hand the finished string over to be recorded.
    nonisolated static func reason(_ error: Error) -> String {
        if let error = error as? SettingsError { return error.diagnostic }
        let value = error as NSError
        var text = "domain=\(value.domain) code=\(value.code)"
        if value.code == -10875 { text += " (kAudioUnitErr_FailedInitialization：音频单元初始化失败)" }
        // URLSession reports a dropped connection as a URLError wrapping the POSIX or TLS
        // error that actually names the cause. Only domains and codes travel: a message
        // is arbitrary payload.
        var underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let current = underlying, depth < 3 {
            text += " ← \(current.domain)/\(current.code)"
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return text
    }
}
