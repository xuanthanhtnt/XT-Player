import Foundation
#if os(macOS)
import CoreAudio
#else
import AVFoundation
#endif

/// The sample rate the output hardware itself runs at, to tell whether audio reaches it at the file's own rate
/// or is resampled by the system mixer on the way.
enum AudioHardware {
    /// `device` is mpv's audio-device: "auto" (system default) or "coreaudio/<device UID>".
    static func sampleRate(device: String) -> Double {
        #if os(macOS)
        guard let id = deviceID(device) else { return 0 }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
        #else
        return AVAudioSession.sharedInstance().sampleRate
        #endif
    }

    #if os(macOS)
    private static func deviceID(_ device: String) -> AudioDeviceID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if device.hasPrefix("coreaudio/") {
            var uid = String(device.dropFirst("coreaudio/".count)) as CFString
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = withUnsafeMutablePointer(to: &uid) {
                AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
            }
            if status == noErr, id != kAudioObjectUnknown { return id }
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }
    #endif
}
