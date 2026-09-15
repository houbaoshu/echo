import Foundation
import Combine

/// Explicit, local transcript tracing for ordinary dictation only (never Live Voice).
/// Keep this separate from VoiceDiagnostics, whose logs never contain transcripts.
@MainActor final class DictationDiagnostics {
    static let shared: DictationDiagnostics? = {
        guard let index = CommandLine.arguments.firstIndex(of: "--dictation-trace"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        do {
            let logger = try DictationDiagnostics(url: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            let executable = Bundle.main.executableURL
            let modified = try? executable?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            logger.record("process.start", fields: [
                "executable": executable?.path ?? "", "pid": ProcessInfo.processInfo.processIdentifier,
                "binaryModifiedAt": modified?.ISO8601Format() ?? "", "traceVersion": 2
            ])
            return logger
        } catch {
            FileHandle.standardError.write(Data("Cannot open ordinary ASR trace: \(error.localizedDescription)\n".utf8))
            return nil
        }
    }()

    private let output: FileHandle
    private var sequence = 0
    private let started = ProcessInfo.processInfo.systemUptime

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        output = try FileHandle(forWritingTo: url)
        try output.seekToEnd()
    }

    func record(_ event: String, fields: [String: Any]) {
        sequence += 1
        var row = fields
        row["event"] = event; row["sequence"] = sequence
        row["time"] = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        row["elapsedMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
        do {
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(0x0a)
            try output.write(contentsOf: data)
        } catch {
            FileHandle.standardError.write(Data("Cannot write ordinary ASR trace: \(error.localizedDescription)\n".utf8))
        }
    }
}

@MainActor final class DictationTrace {
    private let logger: DictationDiagnostics
    private let recordingID: UUID
    let conversationID: UUID
    private let canRecord: () -> Bool
    private var draftObservation: AnyCancellable?
    private var lastSnapshots: [String: Data] = [:]
    private var callbacks = 0

    init(logger: DictationDiagnostics, recordingID: UUID, conversationID: UUID,
         store: TaskStore, canRecord: @escaping () -> Bool = { true }) {
        self.logger = logger; self.recordingID = recordingID; self.conversationID = conversationID
        self.canRecord = canRecord
        // @Published emits before assignment. The proposed value is logged separately.
        draftObservation = store.$mainDraft.dropFirst().sink { [weak self, weak store] next in
            self?.record("draft.willSet", ["before": store?.mainDraft ?? "", "proposed": next])
        }
    }

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        guard canRecord() else { return }
        var row = fields
        row["recordingID"] = recordingID.uuidString
        row["conversationID"] = conversationID.uuidString
        logger.record(event, fields: row)
    }

    func snapshot(_ event: String, _ fields: [String: Any]) {
        // Waveform renders do not need to repeat identical editor state.
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys),
              lastSnapshots[event] != data else { return }
        lastSnapshots[event] = data
        record(event, fields)
    }

    func frame(_ frame: VoiceWire.Frame) {
        var fields: [String: Any] = ["messageType": Int(frame.type), "streamFinal": frame.final,
                                    "wireSequence": frame.sequence.map { Int($0) } as Any? ?? NSNull(),
                                    "payloadBytes": frame.payload.count]
        // Preserve missing fields and raw timestamps for a future replay fixture.
        // Whitelist recognition fields rather than logging arbitrary server payloads.
        if let payload = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] {
            if let result = payload["result"] as? [String: Any] {
                var asr: [String: Any] = [:]
                if let text = result["text"] { asr["text"] = text }
                if let utterances = result["utterances"] as? [[String: Any]] {
                    asr["utterances"] = utterances.map { utterance in
                        utterance.filter { ["text", "start_time", "end_time", "definite"].contains($0.key) }
                    }
                } else if let utterances = result["utterances"] { asr["utterances"] = utterances }
                fields["asr"] = ["result": asr]
            } else { fields["asr"] = payload["result"].map { ["result": $0] } ?? [:] }
        }
        record("transport.frame", fields)
    }

    @discardableResult func callback(_ result: ASRResult, accepted: Bool) -> Int {
        callbacks += 1
        record("recognizer.callback", [
            "callbackIndex": callbacks, "callbackType": "ASRResult", "accepted": accepted,
            "streamFinal": result.streamFinal,
            "text": result.result?.text as Any? ?? NSNull(),
            "utterances": result.result?.utterances?.map { utterance -> [String: Any] in
                ["text": utterance.text, "start_time": utterance.start_time, "end_time": utterance.end_time,
                 "definite": utterance.definite as Any? ?? NSNull(),
                 "status": utterance.definite.map { $0 ? "final" : "partial" } ?? "unspecified"]
            } as Any? ?? NSNull()
        ])
        return callbacks
    }
}
