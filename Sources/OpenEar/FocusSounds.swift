import AudioCore
import AudioToolbox

/// The nature scenes Focus can mix. Order matches OEScene in Soundscape.h.
enum FocusScene: String, CaseIterable, Identifiable {
    case fire, rain, storm, night, forest, ocean, wind, stream

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fire: "Fireplace"
        case .rain: "Rain"
        case .storm: "Thunderstorm"
        case .night: "Night"
        case .forest: "Rainforest"
        case .ocean: "Ocean"
        case .wind: "Wind"
        case .stream: "Stream"
        }
    }

    var symbol: String {
        switch self {
        case .fire: "flame.fill"
        case .rain: "cloud.rain.fill"
        case .storm: "cloud.bolt.rain.fill"
        case .night: "moon.stars.fill"
        case .forest: "leaf.fill"
        case .ocean: "water.waves"
        case .wind: "wind"
        case .stream: "drop.fill"
        }
    }

    fileprivate var scene: OEScene {
        OEScene(rawValue: UInt32(Self.allCases.firstIndex(of: self)!))
    }
}

/// Random mixes that sound right together: one steady bed, plus up to two extras that suit it.
/// Fully random sliders mostly add up to mush, so the extras come from a short list per bed.
enum FocusDice {
    private static let beds: [(FocusScene, weight: Int)] = [(.rain, 3), (.ocean, 2), (.stream, 2), (.wind, 1), (.storm, 1)]

    private static let extras: [FocusScene: [FocusScene]] = [
        .rain: [.fire, .night, .forest, .stream],
        .storm: [.fire, .night],
        .ocean: [.wind, .night, .fire],
        .wind: [.fire, .night, .rain],
        .stream: [.forest, .night, .fire, .rain],
    ]

    // Keyed by bed, then first extra, so the same pair can have a different name depending on which leads.
    private static let names: [String: String] = [
        "rain+fire": "Rainy cabin",
        "rain+night": "Rainy night",
        "rain+forest": "Jungle shower",
        "rain+stream": "Wet woods",
        "storm+fire": "Storm by the fire",
        "storm+night": "Stormy night",
        "ocean+wind": "Windy coast",
        "ocean+night": "Beach at night",
        "ocean+fire": "Beach bonfire",
        "wind+fire": "Mountain hut",
        "wind+night": "Open plains",
        "wind+rain": "Blustery day",
        "stream+forest": "Jungle creek",
        "stream+night": "Creek at night",
        "stream+fire": "Riverside camp",
        "stream+rain": "Drizzly brook",
    ]

    /// A new mix, different from `current` in which scenes it uses.
    static func roll(differentFrom current: [String: Double]) -> (name: String, levels: [String: Double]) {
        let currentScenes = Set(current.filter { $0.value > 0 }.keys)
        while true {
            let mix = makeMix()
            if Set(mix.levels.keys) != currentScenes { return mix }
        }
    }

    private static func makeMix() -> (name: String, levels: [String: Double]) {
        let bed = pickBed()
        var levels = [bed.rawValue: round(Double.random(in: 0.5...0.8))]
        let options = (extras[bed] ?? []).shuffled()
        let count = [0, 1, 1, 1, 2, 2].randomElement()!
        for (i, extra) in options.prefix(count).enumerated() {
            // The second extra stays in the background.
            levels[extra.rawValue] = round(i == 0 ? Double.random(in: 0.25...0.6) : Double.random(in: 0.15...0.35))
        }
        let scenes = Set(levels.keys.compactMap(FocusScene.init(rawValue:)))
        return (name(for: scenes, bed: bed, first: options.first.flatMap { count > 0 ? $0 : nil }), levels)
    }

    private static func pickBed() -> FocusScene {
        let total = beds.reduce(0) { $0 + $1.weight }
        var pick = Int.random(in: 0..<total)
        for (scene, weight) in beds {
            if pick < weight { return scene }
            pick -= weight
        }
        return .rain
    }

    private static func name(for scenes: Set<FocusScene>, bed: FocusScene, first: FocusScene?) -> String {
        if scenes.count == 1 { return bed.title }
        if let first, let name = names["\(bed.rawValue)+\(first.rawValue)"] { return scenes.count > 2 ? name + "+" : name }
        return scenes.map(\.title).sorted().joined(separator: " & ")
    }

    private static func round(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}

/// Plays Focus scenes through the default output. Separate from the mic engine, so it works with ambient sound off.
final class FocusPlayer {
    private static let sampleRate = 48_000.0

    // Lives as long as the app, so the render callback can never outlive it.
    private let soundscape: OpaquePointer = oe_soundscape_create(FocusPlayer.sampleRate, UInt32.random(in: 1...UInt32.max))!
    private var unit: AudioUnit?

    var isPlaying: Bool { unit != nil }

    func setLevels(_ levels: [String: Double], master: Double) {
        for scene in FocusScene.allCases {
            oe_soundscape_set_level(soundscape, scene.scene, Float(levels[scene.rawValue] ?? 0))
        }
        oe_soundscape_set_master(soundscape, Float(master))
    }

    func start() throws {
        guard unit == nil else { return }
        // The default output unit follows whatever device macOS is playing to, and converts the sample rate.
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioEngineError(step: "Finding the output unit", status: -1)
        }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "Creating the focus output")
        guard let newUnit else { return }
        do {
            var format = AudioStreamBasicDescription(
                mSampleRate: Self.sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try check(AudioUnitSetProperty(newUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                           &format, UInt32(MemoryLayout.size(ofValue: format))), "Setting the focus format")
            var callback = AURenderCallbackStruct(inputProc: oe_soundscape_callback,
                                                  inputProcRefCon: UnsafeMutableRawPointer(soundscape))
            try check(AudioUnitSetProperty(newUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                           &callback, UInt32(MemoryLayout.size(ofValue: callback))), "Connecting focus sounds")
            try check(AudioUnitInitialize(newUnit), "Preparing focus sounds")
            try check(AudioOutputUnitStart(newUnit), "Starting focus sounds")
        } catch {
            AudioComponentInstanceDispose(newUnit)
            throw error
        }
        unit = newUnit
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw AudioEngineError(step: step, status: status) }
    }
}
