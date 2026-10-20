import AVFoundation

// AVAudioConverter invokes its input block synchronously during convert(). This box never
// escapes that call; all buffer/flag access happens in the converter's input block.
private final class VoiceConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

struct VoiceCapturePacket: Sendable, Equatable {
    let data: Data
    let epoch: Int
}

extension UnsafeRawBufferPointer {
    /// The signed 16-bit little-endian PCM sample starting at `offset`, scaled to -1..<1.
    func pcm16Sample(at offset: Int) -> Double {
        Double(Int16(littleEndian: loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
    }
}

// Conversion runs on the audio tap; finalization on MainActor is protected by the lock.
final class VoicePCMConverter: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var paused = false
    private var packetBytes = 6400
    private var epoch = 1
    private var delivered = 0
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let continuation: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation
    private var pending = Data()
    init(source: AVAudioFormat, continuation: AsyncThrowingStream<VoiceCapturePacket, Error>.Continuation) throws {
        target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: source, to: target) else { throw SettingsError(localized: "麦克风音频格式无法转换。") }
        self.converter = converter; self.continuation = continuation
    }
    func reset(epoch: Int, paused: Bool, monitoring: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.epoch = epoch
        self.paused = paused
        packetBytes = monitoring ? 640 : 6400
        pending.removeAll()
        converter.reset() // Resampler history belongs to the old capture boundary too.
    }
    /// Tap buffers received so far, muted or not: whether the microphone is alive at all.
    var deliveredBuffers: Int { lock.withLock { delivered } }
    func accept(_ input: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        delivered += 1
        guard !finished, !paused else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            continuation.finish(throwing: SettingsError(localized: "麦克风转换缓冲区分配失败。")); return
        }
        let source = VoiceConverterInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if source.supplied { inputStatus.pointee = .noDataNow; return nil }
            source.supplied = true; inputStatus.pointee = .haveData; return source.buffer
        }
        guard status != .error, error == nil, let samples = output.int16ChannelData?[0] else {
            continuation.finish(throwing: SettingsError(localized: "麦克风音频转换失败（code=\(error?.code ?? 0) status=\(status.rawValue)）。")); return
        }
        pending.append(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        while pending.count >= packetBytes {
            let packet = Data(pending.prefix(packetBytes))
            // Not removeFirst, which only slices Data: every packet sent would stay in its storage until a reset.
            pending.removeSubrange(..<(pending.startIndex + packetBytes))
            let capturePacket = VoiceCapturePacket(data: packet, epoch: epoch)
            if case .dropped = continuation.yield(capturePacket) {
                continuation.finish(throwing: SettingsError(localized: "语音上传跟不上录音速度，请检查网络后重试。")); return
            }
        }
    }
    func finish(flush: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if flush, !paused, !pending.isEmpty {
            let capturePacket = VoiceCapturePacket(data: pending, epoch: epoch)
            if case .dropped = continuation.yield(capturePacket) {
                continuation.finish(throwing: SettingsError(localized: "录音尾包处理过慢，已保留识别到的文字。"))
            }
        }
        pending.removeAll(); continuation.finish()
    }
}
