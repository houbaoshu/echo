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
    static func reason(_ error: Error) -> String {
        if let error = error as? SettingsError { return error.message }
        let value = error as NSError
        return "domain=\(value.domain) code=\(value.code)" +
            (value.code == -10875 ? " (kAudioUnitErr_FailedInitialization：音频单元初始化失败)" : "")
    }
}
