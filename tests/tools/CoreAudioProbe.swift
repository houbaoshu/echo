import CoreAudio
import Foundation

@main enum CoreAudioProbe {
    static func main() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), running = UInt32(0), size = UInt32(4)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != 0 else {
            FileHandle.standardError.write(Data("Cannot resolve the default input device: \(status)\n".utf8)); exit(1)
        }
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        let result = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        guard result == noErr else {
            FileHandle.standardError.write(Data("Cannot sample input-device usage: \(result)\n".utf8)); exit(1)
        }
        print(running)
    }
}
