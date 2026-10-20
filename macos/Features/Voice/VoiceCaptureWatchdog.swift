import Foundation

/// The first-packet timeout measures the microphone, not an engine restart: while VoiceAudio
/// recovers from a startup reconfiguration nothing can arrive, and once it has recovered the
/// device gets a full timeout of its own.
enum VoiceCaptureWatchdog {
    enum Decision: Equatable {
        case fire
        case wait(until: ContinuousClock.Instant)
    }
    static func decide(now: ContinuousClock.Instant, armedAt: ContinuousClock.Instant,
                       restartedAt: ContinuousClock.Instant?, restarting: Bool, timeout: Duration) -> Decision {
        // The restart's length is unknown; look again one timeout later, which is never past
        // the deadline a restart completing meanwhile will set.
        if restarting { return .wait(until: now + timeout) }
        // A restart from before this watchdog was armed says nothing about the current capture.
        let deadline = max(armedAt, restartedAt ?? armedAt) + timeout
        return now < deadline ? .wait(until: deadline) : .fire
    }
    /// Arms the timeout now and calls `onTimeout` once it passes. The task ends by itself as soon
    /// as `isCurrent` says the capture it was armed for is no longer the current one.
    @MainActor static func watch(_ audio: any VoiceAudioHandling, timeout: Duration,
                                 isCurrent: @escaping @MainActor () -> Bool,
                                 onTimeout: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        let armedAt = ContinuousClock.now
        return Task { @MainActor [weak audio] in
            while let audio, isCurrent(), !Task.isCancelled {
                let decision = decide(now: .now, armedAt: armedAt, restartedAt: audio.captureRestartedAt,
                                      restarting: audio.isRestartingCapture, timeout: timeout)
                guard case .wait(let deadline) = decision else { onTimeout(); return }
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            }
        }
    }
}
