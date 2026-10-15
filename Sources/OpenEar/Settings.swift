import Foundation

struct Settings: Codable, Equatable {
    var inputDevice = "MacBook Pro Microphone"
    var gain = 20.0
    var bass = 6.0
    var treble = -3.0
    var highpass = 80.0
    var buffer = 128
    var superHearing = false
    var noiseReduction = false
    /// Focus mix, 0 to 1 per FocusScene raw value.
    var focusLevels: [String: Double] = ["fire": 0.5, "rain": 0.6]
    /// Name of the last dice roll, cleared once a slider moves.
    var focusMixName: String? = "Rainy cabin"

    var pauseDuringCalls = true
    var duckingEnabled = false
    var duckAmount = 10.0
    var alertsEnabled = false
    var alertSounds: Set<AlertSound> = [.doorbell, .knock, .alarm, .siren]
    var alertTurnsOnAmbient = true
    var autoStartOnHeadphones = false
    /// Outputs OpenEar has played through, by Core Audio UID. Only these can auto-start it.
    var trustedOutputs: [String] = []
    var userPresets: [SoundPreset] = []

    var scheduleEnabled = false
    var startMinutes = 9 * 60
    var endMinutes = 18 * 60
    var days: Set<Int> = [2, 3, 4, 5, 6] // Calendar weekdays, 1 = Sunday

    private static let key = "settings"

    static func load() -> Settings {
        // Merge over the defaults so settings saved before a new field existed still load.
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { $1 }),
              let settings = try? JSONDecoder().decode(Settings.self, from: merged) else { return Settings() }
        return settings
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    func isInSchedule(at date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, days.contains(weekday) else { return false }
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinutes <= endMinutes {
            return now >= startMinutes && now < endMinutes
        }
        // Window crosses midnight, e.g. 22:00 to 02:00.
        return now >= startMinutes || now < endMinutes
    }

    /// The settings a preset captures.
    var sound: SoundPreset {
        get {
            SoundPreset(name: "", gain: gain, bass: bass, treble: treble, highpass: highpass,
                        superHearing: superHearing, noiseReduction: noiseReduction)
        }
        set {
            gain = newValue.gain
            bass = newValue.bass
            treble = newValue.treble
            highpass = newValue.highpass
            superHearing = newValue.superHearing
            noiseReduction = newValue.noiseReduction
        }
    }
}

struct SoundPreset: Codable, Equatable, Identifiable {
    var name: String
    var gain: Double
    var bass: Double
    var treble: Double
    var highpass: Double
    var superHearing: Bool
    var noiseReduction: Bool

    var id: String { name }

    static let builtIn: [SoundPreset] = [
        SoundPreset(name: "Home", gain: 15, bass: 4, treble: -2, highpass: 80, superHearing: false, noiseReduction: false),
        SoundPreset(name: "Office", gain: 20, bass: 6, treble: -3, highpass: 120, superHearing: false, noiseReduction: true),
        SoundPreset(name: "Café", gain: 22, bass: 0, treble: 2, highpass: 160, superHearing: true, noiseReduction: true),
        // A high cut-off keeps wind rumble out.
        SoundPreset(name: "Outdoors", gain: 18, bass: -2, treble: 0, highpass: 220, superHearing: false, noiseReduction: false),
    ]

    func sounds(like other: SoundPreset) -> Bool {
        gain == other.gain && bass == other.bass && treble == other.treble && highpass == other.highpass
            && superHearing == other.superHearing && noiseReduction == other.noiseReduction
    }
}
