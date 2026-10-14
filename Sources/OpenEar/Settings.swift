import Foundation

struct Settings: Codable, Equatable {
    var inputDevice = "MacBook Pro Microphone"
    var gain = 20.0
    var bass = 6.0
    var treble = -3.0
    var highpass = 80.0
    var buffer = 128
    var superHearing = false

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

    var soxArguments: [String] {
        let base = [
            "-q", "--buffer", String(buffer),
            "-t", "coreaudio", inputDevice,
            "-d",
            "gain", Self.format(gain),
            "bass", Self.format(bass),
            "treble", Self.format(treble),
            "highpass", Self.format(highpass),
        ]
        guard superHearing else { return base }
        return base + [
            // Lift the 2-4 kHz range where speech consonants and footsteps live.
            "equalizer", "3000", "1.5q", "6",
            // Boost quiet sounds up to +20 dB and hold loud ones at -6 dB, so a slammed door can't blast your ears.
            // No look-ahead delay (last 0) to keep latency down.
            "compand", "0.005,0.25", "6:-70,-60,-40,-20,-20,-12,0,-6", "0", "-90", "0",
        ]
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

    private static func format(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}
