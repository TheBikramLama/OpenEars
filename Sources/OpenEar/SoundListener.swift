import AVFoundation
import SoundAnalysis

/// Runs Apple's on-device sound classifier over the mic audio the engine sets aside.
final class SoundListener: NSObject, SNResultsObserving {
    private let analyzer: SNAudioStreamAnalyzer
    private let format: AVAudioFormat
    private let read: (UnsafeMutablePointer<Float>, Int) -> Int
    private let onScores: ([String: Double]) -> Void
    private let queue = DispatchQueue(label: "io.github.thebikramlama.openear.sound-analysis")
    private var timer: DispatchSourceTimer?
    private var position: AVAudioFramePosition = 0

    /// `onScores` gets every sound heard with at least 30% confidence, on the main queue.
    init(sampleRate: Double, read: @escaping (UnsafeMutablePointer<Float>, Int) -> Int,
         onScores: @escaping ([String: Double]) -> Void) throws {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        analyzer = SNAudioStreamAnalyzer(format: format)
        self.read = read
        self.onScores = onScores
        super.init()

        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.overlapFactor = 0.5 // A result every half second instead of every second.
        try analyzer.add(request, withObserver: self)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.2)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    /// Waits for any read in progress, so the engine's buffers can be freed right after.
    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func drain() {
        guard timer != nil,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)),
              let channel = buffer.floatChannelData?[0] else { return }
        let frames = read(channel, Int(buffer.frameCapacity))
        guard frames > 0 else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        analyzer.analyze(buffer, atAudioFramePosition: position)
        position += AVAudioFramePosition(frames)
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        var scores: [String: Double] = [:]
        for classification in result.classifications where classification.confidence >= 0.3 {
            scores[classification.identifier] = classification.confidence
        }
        guard !scores.isEmpty else { return }
        DispatchQueue.main.async { [onScores] in onScores(scores) }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        log.error("Sound recognition failed: \(error.localizedDescription, privacy: .public)")
    }
}

/// Sounds the user can ask to be alerted about, each mapped to the classifier's labels.
enum AlertSound: String, CaseIterable, Codable, Identifiable {
    case doorbell, knock, alarm, siren, phone, baby, dog, shout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .doorbell: "Doorbell"
        case .knock: "Knock"
        case .alarm: "Smoke alarm"
        case .siren: "Siren"
        case .phone: "Phone ringing"
        case .baby: "Baby crying"
        case .dog: "Dog barking"
        case .shout: "Shouting"
        }
    }

    var symbol: String {
        switch self {
        case .doorbell: "bell.fill"
        case .knock: "door.left.hand.closed"
        case .alarm: "flame.fill"
        case .siren: "light.beacon.max.fill"
        case .phone: "phone.fill"
        case .baby: "figure.and.child.holdinghands"
        case .dog: "dog.fill"
        case .shout: "megaphone.fill"
        }
    }

    var labels: Set<String> {
        switch self {
        case .doorbell: ["door_bell"]
        case .knock: ["knock"]
        case .alarm: ["smoke_detector", "alarm_clock"]
        case .siren: ["siren", "police_siren", "ambulance_siren", "fire_engine_siren", "civil_defense_siren"]
        case .phone: ["telephone_bell_ringing", "ringtone", "telephone"]
        case .baby: ["baby_crying"]
        case .dog: ["dog_bark", "dog_bow_wow"]
        case .shout: ["shout", "yell"]
        }
    }
}
