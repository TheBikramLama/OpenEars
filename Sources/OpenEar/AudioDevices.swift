import CoreAudio
import Foundation

struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let isBuiltIn: Bool

    // Built-in mic into built-in speakers howls, so passthrough must never run there.
    var isBuiltInSpeaker: Bool { isBuiltIn && name.localizedCaseInsensitiveContains("speaker") }
}

enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func inputNames() -> [String] {
        var seen = Set<String>()
        return deviceIDs()
            .filter(hasInput)
            .compactMap(name)
            .filter { seen.insert($0).inserted }
    }

    static func defaultOutput() -> AudioDevice? {
        var id = AudioDeviceID(0)
        guard read(system, kAudioHardwarePropertyDefaultOutputDevice, &id), id != 0,
              let name = name(of: id) else { return nil }
        var transport = UInt32(0)
        _ = read(id, kAudioDevicePropertyTransportType, &transport)
        return AudioDevice(id: id, name: name, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
    }

    /// Calls `handler` on the main queue when devices are plugged in or out, or the default output changes.
    static func observeChanges(_ handler: @escaping () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(system, &address, .main) { _, _ in handler() }
        }
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func read(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
    }
}
