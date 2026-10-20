import Foundation

/// Explicit, local transcript tracing for ordinary dictation only (never Live Voice).
/// Keep this separate from VoiceDiagnostics, whose logs never contain transcripts.
@MainActor final class DictationDiagnostics {
    static let shared: DictationDiagnostics? = {
        let url: URL
        if CommandLine.arguments.contains("--dictation-trace-auto") {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("echo-dictation-\(UUID()).jsonl")
        } else if let index = CommandLine.arguments.firstIndex(of: "--dictation-trace"),
                  CommandLine.arguments.indices.contains(index + 1) {
            url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        } else { return nil }
        do {
            let logger = try DictationDiagnostics(url: url)
            print("Ordinary dictation transcript trace: \(url.path)")
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
    private var counts: [String: Int] = [:]
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
        counts[event, default: 0] += 1
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

    func printSummary() {
        print("录音轮数：\(counts["recording.start", default: 0])；Apple 原始回调：\(counts["apple.rawCallback", default: 0])；识别回调：\(counts["recognizer.callback", default: 0])")
        if counts["recognizer.callback", default: 0] == 0 {
            print("本次没有采集到识别回调，不能用来定位转写覆盖；请保留日志供排查入口／授权。")
        }
    }
}

/// A trace field for an optional value: JSON null when there is none.
func traceField(_ value: Any?) -> Any { value ?? NSNull() }

@MainActor final class DictationTrace {
    private let logger: DictationDiagnostics
    private let recordingID: UUID
    let conversationID: UUID
    private let canRecord: () -> Bool
    private var draftObservation: ObservationHandle?
    private var lastSnapshots: [String: Data] = [:]
    private var callbacks = 0

    init(logger: DictationDiagnostics, recordingID: UUID, conversationID: UUID,
         store: TaskStore, canRecord: @escaping () -> Bool) {
        self.logger = logger; self.recordingID = recordingID; self.conversationID = conversationID
        self.canRecord = canRecord
        // Recorded right after each change, with the draft it replaced and the one it set. The event
        // keeps its name so traces stay comparable with ones recorded before the change.
        draftObservation = observeTransitions({ [weak store] in store?.mainDraft ?? "" }) { [weak self] before, next in
            self?.record("draft.willSet", ["before": before, "proposed": next])
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

    @discardableResult func callback(_ result: ASRResult, accepted: Bool) -> Int {
        callbacks += 1
        record("recognizer.callback", [
            "callbackIndex": callbacks, "callbackType": "ASRResult", "accepted": accepted,
            "streamFinal": result.streamFinal,
            "text": traceField(result.result?.text),
            "utterances": traceField(result.result?.utterances?.map { utterance -> [String: Any] in
                ["text": utterance.text, "start_time": utterance.start_time, "end_time": utterance.end_time,
                 "definite": traceField(utterance.definite),
                 "status": utterance.definite.map { $0 ? "final" : "partial" } ?? "unspecified"]
            })
        ])
        return callbacks
    }
}
