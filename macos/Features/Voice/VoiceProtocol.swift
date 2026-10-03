import Foundation
import zlib

struct VoiceConfiguration: Codable, Equatable, Sendable {
    var speaker = "zh_female_gaolengyujie_uranus_bigtts"

    func validated() throws -> Self {
        var value = self
        value.speaker = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.speaker.isEmpty, value.speaker.utf8.count <= 256 else {
            throw SettingsError(localized: "请输入有效的音色 ID。")
        }
        return value
    }
}

// All integer fields are big endian. Bounds are checked before reading or allocating.
enum VoiceWire {
    static let limit = 4 * 1024 * 1024
    struct Frame: Sendable {
        var type: UInt8
        var event: Int?
        var sessionID: String?
        var sequence: Int32?
        var final = false
        var payload: Data
    }
    static func integer(_ value: UInt32) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    struct Reader {
        let data: Data
        var offset = 0
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= VoiceWire.limit, offset <= data.count - count else {
                throw SettingsError(localized: "语音服务返回了不完整的数据包。")
            }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        mutating func uint() throws -> UInt32 {
            try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        mutating func blob() throws -> Data { try take(Int(try uint())) }
        mutating func string() throws -> String {
            guard let value = String(data: try blob(), encoding: .utf8) else { throw SettingsError(localized: "语音事件标识无效。") }
            return value
        }
    }
    static func unzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw SettingsError(localized: "无法解压语音数据。")
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var status: Int32 = Z_OK
            repeat {
                var chunk = [UInt8](repeating: 0, count: 16384)
                let written = chunk.withUnsafeMutableBytes { output -> Int in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return output.count - Int(stream.avail_out)
                }
                guard status == Z_OK || status == Z_STREAM_END, written > 0 || status == Z_STREAM_END,
                      result.count + written <= limit else { throw SettingsError(localized: "语音压缩数据无效或过大。") }
                result.append(contentsOf: chunk.prefix(written))
            } while status != Z_STREAM_END
            return result
        }
    }
    static func decode(_ data: Data, tts: Bool) throws -> Frame {
        guard data.count >= 4, data.count <= limit, data[0] >> 4 == 1, data[0] & 15 >= 1 else {
            throw SettingsError(localized: "语音服务的数据协议不兼容。")
        }
        let type = data[1] >> 4, flags = data[1] & 15, compression = data[2] & 15
        guard [UInt8(9), 11, 15].contains(type), compression <= 1 else { throw SettingsError(localized: "未知语音消息类型。") }
        var reader = Reader(data: data)
        _ = try reader.take(Int(data[0] & 15) * 4)
        var frame = Frame(type: type, payload: Data())
        if type == 15 {
            let code = try reader.uint()
            // Never surface an arbitrary remote payload, which may echo credentials.
            throw SettingsError(localized: "语音服务拒绝请求（错误码 \(code)），请检查密钥、音色和套餐额度。")
        }
        if flags & 1 != 0 { frame.sequence = Int32(bitPattern: try reader.uint()) }
        frame.final = flags & 2 != 0
        if tts, flags & 4 != 0 {
            let event = Int(try reader.uint()); frame.event = event
            if [50, 51, 52].contains(event) { _ = try reader.string() }
            else { frame.sessionID = try reader.string() }
        }
        frame.payload = try reader.blob()
        guard reader.offset == data.count else { throw SettingsError(localized: "语音数据包长度不匹配。") }
        if compression == 1 { frame.payload = try unzip(frame.payload) }
        return frame
    }
    static func asr(_ payload: Data, audio: Bool = false, final: Bool = false) -> Data {
        // Uncompressed payloads are explicitly permitted by the ASR v3 protocol.
        Data([0x11, audio ? (final ? 0x22 : 0x20) : 0x10, audio ? 0x00 : 0x10, 0])
            + integer(UInt32(payload.count)) + payload
    }
    static func tts(event: Int, session: String? = nil, payload: Data = Data("{}".utf8)) -> Data {
        var data = Data([0x11, 0x14, 0x10, 0]) + integer(UInt32(event))
        if let session { let id = Data(session.utf8); data += integer(UInt32(id.count)) + id }
        return data + integer(UInt32(payload.count)) + payload
    }
}

struct ASRResult: Decodable, Sendable {
    // Apple can finalize a phrase while isFinal remains false for the request.
    // This metadata is never decoded from the remote ASR protocol.
    struct LocalSegment: Sendable {
        let start: TimeInterval
        let duration: TimeInterval
    }
    struct Result: Decodable, Sendable {
        struct Utterance: Decodable, Sendable {
            let text: String
            let start_time: Int
            let end_time: Int
            let definite: Bool?
        }
        let text: String?
        let utterances: [Utterance]?
    }
    let result: Result?
    // Transport metadata, not part of the service JSON payload.
    var streamFinal = false
    var localSegment: LocalSegment? = nil
    init(result: Result?, streamFinal: Bool = false, localSegment: LocalSegment? = nil) {
        self.result = result; self.streamFinal = streamFinal; self.localSegment = localSegment
    }
    private enum CodingKeys: String, CodingKey { case result }
}

struct VoiceTranscription: Sendable {
    var subtitle = ""
    var beganSpeaking = false
    var committed: [String] = []
}

extension ASRResult.Result.Utterance {
    private enum CodingKeys: String, CodingKey { case text, start_time, end_time, definite }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // The live API omits zero-valued fields (notably start_time for the first
        // utterance). Empty interim utterances can omit text/timestamps as well.
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        start_time = try values.decodeIfPresent(Int.self, forKey: .start_time) ?? 0
        end_time = try values.decodeIfPresent(Int.self, forKey: .end_time) ?? 0
        definite = try values.decodeIfPresent(Bool.self, forKey: .definite)
    }
}

struct VoiceUtteranceTracker {
    // Finalized times advance monotonically; repeated text in a later utterance is valid.
    private var finalEnd = -1
    private var currentStart: Int?
    mutating func accept(_ result: ASRResult) -> VoiceTranscription {
        var update = VoiceTranscription()
        for utterance in (result.result?.utterances ?? []).sorted(by: { $0.start_time < $1.start_time }) {
            let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard utterance.end_time > finalEnd, !text.isEmpty else { continue }
            if currentStart != utterance.start_time {
                currentStart = utterance.start_time; update.beganSpeaking = true
            }
            update.subtitle = text
            if utterance.definite == true {
                update.committed.append(text); finalEnd = utterance.end_time; currentStart = nil
            }
        }
        return update
    }
}

struct VoiceTextDelta {
    private(set) var previous = ""
    mutating func append(_ cumulative: String) throws -> String {
        guard cumulative.hasPrefix(previous) else {
            throw SettingsError(localized: "模型改写了已播报的文本，语音通话已结束；完整回复保留在会话中。")
        }
        let delta = String(cumulative.dropFirst(previous.count))
        previous = cumulative
        return delta
    }
}
