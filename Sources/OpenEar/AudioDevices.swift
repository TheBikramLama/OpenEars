import AppKit
import CoreAudio
import Foundation

struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    /// Mic audio played through speakers feeds back into the mic and howls, so passthrough must never run there.
    /// Bluetooth and USB speakers can't be told apart from headphones; those are handled by only auto-starting
    /// on outputs the user has already used OpenEar with.
    var isSpeaker: Bool {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return name.localizedCaseInsensitiveContains("speaker")
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
            return true
        default:
            return false
        }
    }
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

    /// Some devices list separate input and output halves under one name, so match only the half with a mic.
    static func inputID(named name: String) -> AudioDeviceID? {
        deviceIDs().first { hasInput($0) && self.name(of: $0) == name }
    }

    static func defaultInputID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        return read(system, kAudioHardwarePropertyDefaultInputDevice, &id) && id != 0 ? id : nil
    }

    static func defaultOutput() -> AudioDevice? {
        var id = AudioDeviceID(0)
        guard read(system, kAudioHardwarePropertyDefaultOutputDevice, &id), id != 0,
              let name = name(of: id) else { return nil }
        var transport = UInt32(0)
        _ = read(id, kAudioDevicePropertyTransportType, &transport)
        return AudioDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? name, name: name, transport: transport)
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    static func setBufferFrameSize(_ id: AudioDeviceID, _ frames: UInt32) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = frames
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// Name of another app recording from any microphone, such as a video call. Ignores OpenEar itself.
    static func otherAppUsingMicrophone() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for process in processes {
            var running = UInt32(0)
            guard read(process, kAudioProcessPropertyIsRunningInput, &running), running != 0 else { continue }
            var pid = pid_t(0)
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
                  pid != ownPID, let app = appName(for: pid) else { continue }
            return app
        }
        return nil
    }

    /// Calls `handler` on the main queue when devices are plugged in or out, or the default devices change.
    static func observeChanges(_ handler: @escaping () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(system, &address, .main) { _, _ in handler() }
        }
    }

    /// The app a process belongs to, or nil for background system services such as Siri's "Hey Siri" listener.
    /// Call apps often record from helper processes inside their bundle, e.g. Google Chrome Helper, so the
    /// outermost .app in the path names the app.
    private static func appName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let app = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) else { return nil }
        return String(app.dropLast(4))
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
        string(id, kAudioObjectPropertyName)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
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
