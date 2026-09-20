import Foundation
import Combine
import OSLog

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
    // `nonisolated` so a URLSession delegate callback, which never runs on the main actor,
    // can summarise its error there and hand the finished string over to be recorded.
    nonisolated static func reason(_ error: Error) -> String {
        if let error = error as? SettingsError { return error.message }
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
