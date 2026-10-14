import AudioCore
import AudioToolbox
import CoreAudio
import os

let log = Logger(subsystem: "io.github.thebikramlama.openear", category: "audio")

struct AudioEngineError: LocalizedError {
    let step: String
    let status: OSStatus
    var errorDescription: String? { "\(step) failed (\(status))" }
}

/// Mic to headphones through Core Audio's HAL units, with the processing in AudioCore.
/// The mic and the headphones each get their own unit, so they can be different devices.
final class AudioEngine {
    struct Config: Equatable {
        var inputDevice: AudioDeviceID
        /// nil records without playing anything, for sound recognition while ambient sound is off.
        var outputDevice: AudioDeviceID?
        var bufferFrames: UInt32
        var analysis: Bool
    }

    private(set) var config: Config?
    private(set) var sampleRate: Double = 48_000
    private var core: OpaquePointer?
    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?

    var isRunning: Bool { inputUnit != nil }
    var inputLevel: Float { core.map { oe_core_input_level($0) } ?? -120 }
    var inputFrames: UInt64 { core.map { oe_core_input_frames($0) } ?? 0 }

    deinit { stop() }

    func start(_ config: Config, params: OEParams) throws {
        stop()
        let rate = AudioDevices.nominalSampleRate(config.inputDevice) ?? 48_000
        guard let core = oe_core_create(rate) else { throw AudioEngineError(step: "Allocating audio buffers", status: -1) }
        self.core = core
        self.config = config
        sampleRate = rate
        var params = params
        oe_core_set_params(core, &params)
        oe_core_set_analysis_enabled(core, config.analysis)
        oe_core_set_output_enabled(core, config.outputDevice != nil)

        do {
            AudioDevices.setBufferFrameSize(config.inputDevice, config.bufferFrames)
            if let output = config.outputDevice {
                AudioDevices.setBufferFrameSize(output, config.bufferFrames)
                outputUnit = try makeOutputUnit(device: output, rate: rate, core: core)
            }
            inputUnit = try makeInputUnit(config, rate: rate, core: core)
            log.info("Audio started at \(rate) Hz, \(config.bufferFrames) frames, output: \(config.outputDevice != nil)")
        } catch {
            stop()
            throw error
        }
    }

    func setParams(_ params: OEParams) {
        guard let core else { return }
        var params = params
        oe_core_set_params(core, &params)
    }

    /// Hands sound recognition a reader bound to this run's buffers. Stop the reader before stopping the engine.
    func analysisReader() -> ((UnsafeMutablePointer<Float>, Int) -> Int)? {
        guard let core else { return nil }
        return { destination, maxFrames in Int(oe_core_read_analysis(core, destination, Int32(maxFrames))) }
    }

    func stop() {
        // Stop both units before freeing the buffers their callbacks use.
        for unit in [inputUnit, outputUnit].compactMap({ $0 }) {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        inputUnit = nil
        outputUnit = nil
        if let core { oe_core_destroy(core) }
        core = nil
        config = nil
    }

    private func makeInputUnit(_ config: Config, rate: Double, core: OpaquePointer) throws -> AudioUnit {
        let unit = try makeUnit(kAudioUnitSubType_HALOutput)
        do {
            var on: UInt32 = 1
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, "Enabling the mic")
            var off: UInt32 = 0
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, "Disabling mic playback")
            var device = config.inputDevice
            try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, "Selecting the mic")
            var format = Self.format(rate: rate, channels: 1)
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, "Setting the mic format")
            var callback = AURenderCallbackStruct(inputProc: oe_input_callback, inputProcRefCon: UnsafeMutableRawPointer(core))
            try set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, "Connecting the mic")
            oe_core_set_input_unit(core, unit)
            try check(AudioUnitInitialize(unit), "Preparing the mic")
            try check(AudioOutputUnitStart(unit), "Starting the mic")
            return unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private func makeOutputUnit(device: AudioDeviceID, rate: Double, core: OpaquePointer) throws -> AudioUnit {
        let unit = try makeUnit(kAudioUnitSubType_HALOutput)
        do {
            var device = device
            try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, "Selecting the headphones")
            // Feed it the mic's sample rate; the unit converts to whatever the headphones run at.
            var format = Self.format(rate: rate, channels: 2)
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, "Setting the headphone format")
            var callback = AURenderCallbackStruct(inputProc: oe_output_callback, inputProcRefCon: UnsafeMutableRawPointer(core))
            try set(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, "Connecting the headphones")
            try check(AudioUnitInitialize(unit), "Preparing the headphones")
            try check(AudioOutputUnitStart(unit), "Starting the headphones")
            return unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private func makeUnit(_ subtype: OSType) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioEngineError(step: "Finding the audio unit", status: -1)
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "Creating the audio unit")
        return unit!
    }

    private static func format(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func set<T: BitwiseCopyable>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                        _ element: AudioUnitElement, _ value: inout T, _ step: String) throws {
        try check(AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<T>.size)), step)
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw AudioEngineError(step: step, status: status) }
    }
}
