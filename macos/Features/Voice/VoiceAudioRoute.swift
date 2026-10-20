import CoreAudio
import Foundation

/// The system default devices an engine graph was built on. Only the device identities
/// matter here: a Bluetooth headset keeps its identity across a profile switch, while
/// picking another output in Control Center changes it.
struct VoiceAudioRoute: Equatable, Sendable {
    var input: UInt32
    var output: UInt32
    static var current: VoiceAudioRoute {
        VoiceAudioRoute(input: defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
                        output: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))
    }
    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> UInt32 {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr else { return 0 }
        return device
    }
}

/// Opening the microphone drives a Bluetooth headset from A2DP to HFP, so Core Audio
/// reconfigures the very route the call just started on and AVAudioEngine stops itself
/// roughly a second after start(). That is Echo's own recording doing it, not the user
/// choosing another device, and restarting the engine on the unchanged route recovers the
/// call. Every other configuration change still ends it, so a real device switch is not
/// masked: the check is device identity, not the notification. A Live Voice call and a
/// dictation opt in to following a switch to another device at the same sample rate instead.
struct VoiceConfigurationChangePolicy: Sendable {
    enum Decision: Equatable, Sendable {
        case restartEngine
        /// Restart on the new default devices and reset the player; queued reply audio is kept.
        case recoverSwitch
        case endCall(String)
    }
    struct Change: Sendable {
        var baseline: VoiceAudioRoute
        var current: VoiceAudioRoute
        /// Seconds since the engine started, bounding recovery to initialization.
        var elapsed: TimeInterval
        var restarts: Int
        var queuedPlaybackFrames: Int
        /// Sample rate the duplex graph was built with; nil for a playback-only graph.
        var graphSampleRate: Double?
        var inputSampleRate: Double
        /// Set only for a Live Voice call or a dictation; everything else still ends on a switch.
        var recoversDeviceSwitch: Bool = false
    }
    let initializationWindow: TimeInterval = 10
    let maximumRestarts = 3
    func decide(_ change: Change) -> Decision {
        guard change.current == change.baseline else {
            let switched = "默认设备已切换 输入 \(change.baseline.input)→\(change.current.input) 输出 \(change.baseline.output)→\(change.current.output)"
            guard change.recoversDeviceSwitch else { return .endCall(switched) }
            if let rate = change.graphSampleRate, rate != change.inputSampleRate {
                return .endCall("\(switched)，采集采样率 \(rate) Hz→\(change.inputSampleRate) Hz，需要重建音频图")
            }
            // Queued audio is not checked: it survives the restart and is queued again.
            return .recoverSwitch
        }
        guard change.elapsed < initializationWindow else {
            return .endCall("同一设备在初始化窗口 \(Int(initializationWindow)) 秒之后重新配置 elapsed=\(Int(change.elapsed))")
        }
        guard change.restarts < maximumRestarts else {
            return .endCall("启动期已恢复 \(change.restarts) 次仍在重新配置，超出上限")
        }
        // Restarting drops whatever the player still holds, so never recover over audible audio.
        guard change.queuedPlaybackFrames == 0 else {
            return .endCall("重新配置时仍有 \(change.queuedPlaybackFrames) 帧回复音频未播完")
        }
        // A different rate invalidates the tap and the duplex connection, which a plain restart
        // cannot fix; rebuilding the graph is deliberately left out of this change.
        if let rate = change.graphSampleRate, rate != change.inputSampleRate {
            return .endCall("采集采样率已从 \(rate) Hz 变为 \(change.inputSampleRate) Hz")
        }
        return .restartEngine
    }
}
