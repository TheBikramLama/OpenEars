import CoreAudio

/// Turns the headphones' system volume down while someone talks, and back up afterwards.
/// OpenEar raises its own volume by the same amount, so music gets quieter and the room doesn't.
final class OutputDucker {
    private var device: AudioDeviceID = 0
    private var saved: [AudioObjectPropertyElement: Float32] = [:]
    private var applied: [AudioObjectPropertyElement: Float32] = [:]

    var isDucked: Bool { !saved.isEmpty }

    /// Returns how many dB the volume actually went down: less near the bottom of the range, 0 if the
    /// device has no adjustable volume.
    func duck(device: AudioDeviceID, by amount: Float) -> Float {
        if isDucked { restore() }
        self.device = device
        var reduction = amount
        for element in volumeElements(of: device) {
            guard let current = decibels(element), let range = range(element) else { continue }
            let target = max(Float32(range.mMinimum), current - amount)
            guard setDecibels(element, target) else { continue }
            saved[element] = current
            applied[element] = target
            reduction = min(reduction, current - target)
        }
        return isDucked ? reduction : 0
    }

    func restore() {
        for (element, original) in saved {
            // If the user moved the volume while ducked, keep their choice.
            if let current = decibels(element), let target = applied[element], abs(current - target) < 0.75 {
                _ = setDecibels(element, original)
            }
        }
        saved = [:]
        applied = [:]
    }

    /// The main volume control if the device has one, otherwise each stereo channel.
    private func volumeElements(of device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        if isSettable(device, kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &channels)
        return channels.filter { isSettable(device, $0) }
    }

    private func address(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    private func isSettable(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Bool {
        var address = address(kAudioDevicePropertyVolumeDecibels, element)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr
            && settable.boolValue
    }

    private func decibels(_ element: AudioObjectPropertyElement) -> Float32? {
        var address = address(kAudioDevicePropertyVolumeDecibels, element)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func setDecibels(_ element: AudioObjectPropertyElement, _ value: Float32) -> Bool {
        var address = address(kAudioDevicePropertyVolumeDecibels, element)
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private func range(_ element: AudioObjectPropertyElement) -> AudioValueRange? {
        var address = address(kAudioDevicePropertyVolumeRangeDecibels, element)
        var value = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}
