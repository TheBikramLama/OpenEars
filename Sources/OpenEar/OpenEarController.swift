import AppKit
import AudioCore
import Combine
import ServiceManagement
import UserNotifications

enum TimerChip: Hashable {
    case minutes(Int)
    case forever
    case until
}

@MainActor
final class OpenEarController: ObservableObject {
    /// The user's on/off choice. Calls, speakers or a missing mic can still keep sound from playing; see `isListening`.
    @Published var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            if !isOn { clearTimer() }
            reconcile()
        }
    }

    @Published var settings: Settings {
        didSet { settingsChanged(from: oldValue) }
    }

    @Published private(set) var status = "Off"
    /// Room sound is actually playing in the headphones right now.
    @Published private(set) var isListening = false
    @Published private(set) var isDucking = false
    @Published private(set) var duckingUnavailable = false
    @Published private(set) var inputs: [String] = []
    @Published private(set) var offAt: Date?
    @Published private var chosenChip: TimerChip?

    // Held here because SwiftUI's @State macro isn't available when building without Xcode.
    @Published var showingUntilPicker = false
    @Published var untilTime = Date().addingTimeInterval(3600)

    /// Fires when a sound alert goes off, for the on-screen badge.
    let alerts = PassthroughSubject<AlertSound, Never>()

    /// The chip to highlight. Turning on any other way counts as no time limit.
    var activeChip: TimerChip? {
        guard isOn else { return nil }
        return chosenChip ?? .forever
    }

    var activePreset: SoundPreset? {
        (SoundPreset.builtIn + settings.userPresets).first { $0.sounds(like: settings.sound) }
    }

    var inputLevel: Float { engine.inputLevel }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                status = "Launch at login failed: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

    private let engine = AudioEngine()
    private let ducker = OutputDucker()
    private var listener: SoundListener?
    private var holding = false
    private var alertListenUntil: Date?
    private var otherMicApp: String?
    private var lastOutputID: AudioDeviceID?
    private var speechStreak = 0
    private var lastSpeech = Date.distantPast
    private var duckCompensation: Float = 0
    private var alertCooldowns: [AlertSound: Date] = [:]
    private var lastInputFrames: UInt64 = 0
    private var offWork: DispatchWorkItem?
    private var timers: [Timer] = []
    private var lastInSchedule: Bool?

    init() {
        settings = Settings.load()
        inputs = AudioDevices.inputNames()
        lastOutputID = AudioDevices.defaultOutput()?.id

        AudioDevices.observeChanges { [weak self] in
            Task { @MainActor in self?.devicesChanged() }
        }

        // Core Audio can drop the mic stream across sleep, so start fresh on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartEngine() }
        }

        every(15) { $0.checkSchedule() }
        every(1.5) { $0.checkOtherMicUse() }
        every(0.5) { $0.checkDucking() }
        every(3) { $0.checkEngineIsAlive() }
        checkSchedule()
        checkOtherMicUse()
        reconcile()
    }

    // MARK: Actions

    /// Clicking the active chip again turns ambient sound off.
    func select(_ chip: TimerChip, until date: Date? = nil) {
        if chip == activeChip, chip != .until {
            isOn = false
            return
        }
        clearTimer()
        chosenChip = chip
        switch chip {
        case .minutes(let minutes):
            scheduleOff(at: Date().addingTimeInterval(TimeInterval(minutes * 60)))
        case .until:
            if let date { scheduleOff(at: date) }
        case .forever:
            break
        }
        isOn = true
    }

    /// Hold-to-hear: plays the room only while the shortcut is held.
    func setHolding(_ holding: Bool) {
        guard self.holding != holding else { return }
        self.holding = holding
        reconcile()
    }

    func apply(_ preset: SoundPreset) {
        settings.sound = preset
    }

    func savePreset(named name: String) {
        var preset = settings.sound
        preset.name = name
        settings.userPresets.removeAll { $0.name == name }
        settings.userPresets.append(preset)
    }

    func deletePreset(_ preset: SoundPreset) {
        settings.userPresets.removeAll { $0.name == preset.name }
    }

    func forgetHeadphones() {
        settings.trustedOutputs = []
    }

    func resetAudioSettings() {
        settings.sound = Settings().sound
        settings.buffer = Settings().buffer
    }

    func shutdown() {
        endDucking(immediately: true)
        listener?.stop()
        engine.stop()
    }

    // MARK: The one place that decides what runs

    private func reconcile() {
        let output = AudioDevices.defaultOutput()
        let alertPlayback = alertListenUntil.map { $0 > Date() } ?? false
        let wantsSound = isOn || holding || alertPlayback
        let pausedForCall = settings.pauseDuringCalls ? otherMicApp : nil
        let onSpeakers = output.map { $0.isSpeaker } ?? true

        let playing = wantsSound && pausedForCall == nil && !onSpeakers
        let analysing = pausedForCall == nil && (settings.alertsEnabled || (settings.duckingEnabled && playing))
        if !playing { endDucking(immediately: false) }

        guard playing || analysing else {
            stopEngine()
            isListening = false
            status = wantsSound ? pausedStatus(call: pausedForCall, output: output) : "Off"
            return
        }

        guard let input = AudioDevices.inputID(named: settings.inputDevice) ?? AudioDevices.defaultInputID() else {
            stopEngine()
            isListening = false
            status = "No microphone found"
            return
        }

        let config = AudioEngine.Config(
            inputDevice: input,
            outputDevice: playing ? output?.id : nil,
            bufferFrames: UInt32(settings.buffer),
            analysis: analysing
        )
        if engine.config != config {
            listener?.stop()
            listener = nil
            do {
                try engine.start(config, params: params)
            } catch {
                log.error("Couldn't start audio: \(error.localizedDescription, privacy: .public)")
                isListening = false
                status = "Couldn't start audio: \(error.localizedDescription)"
                return
            }
            // Give the fresh engine one full check interval before judging it stalled.
            lastInputFrames = .max
            if analysing { startListener() }
        } else {
            engine.setParams(params)
        }

        isListening = playing
        if playing, let output {
            status = holding && !isOn ? "Listening while you hold the shortcut" : "Listening through \(settings.inputDevice)"
            trust(output)
        } else {
            status = wantsSound ? pausedStatus(call: pausedForCall, output: output) : "Off. Listening for alert sounds"
        }
    }

    private func pausedStatus(call: String?, output: AudioDevice?) -> String {
        if let call { return "Paused while \(call) uses the microphone" }
        if let output { return "Paused: sound is going to \(output.name). Plug in your headphones." }
        return "Paused: no headphones found"
    }

    private var params: OEParams {
        OEParams(
            gainDB: Float(settings.gain),
            bassDB: Float(settings.bass),
            trebleDB: Float(settings.treble),
            highpassHz: Float(settings.highpass),
            superHearing: settings.superHearing,
            noiseGate: settings.noiseReduction,
            duckCompensationDB: duckCompensation
        )
    }

    private func stopEngine() {
        listener?.stop()
        listener = nil
        engine.stop()
    }

    private func restartEngine() {
        stopEngine()
        reconcile()
    }

    private func startListener() {
        guard let read = engine.analysisReader() else { return }
        do {
            listener = try SoundListener(sampleRate: engine.sampleRate, read: read) { [weak self] scores in
                self?.heard(scores)
            }
        } catch {
            log.error("Sound recognition unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    // Remember outputs the user has listened through, for auto-start.
    private func trust(_ output: AudioDevice) {
        guard !settings.trustedOutputs.contains(output.uid) else { return }
        DispatchQueue.main.async { [weak self] in self?.settings.trustedOutputs.append(output.uid) }
    }

    private func settingsChanged(from old: Settings) {
        guard settings != old else { return }
        settings.save()

        if settings.scheduleEnabled != old.scheduleEnabled || settings.startMinutes != old.startMinutes
            || settings.endMinutes != old.endMinutes || settings.days != old.days {
            lastInSchedule = nil
            checkSchedule()
        }
        if settings.alertsEnabled && !old.alertsEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        if !settings.duckingEnabled { endDucking(immediately: false) }
        if settings.pauseDuringCalls != old.pauseDuringCalls { checkOtherMicUse() }
        // Effects update live; only device, latency or listening changes restart the audio.
        reconcile()
    }

    // MARK: Devices, calls and health

    private func devicesChanged() {
        inputs = AudioDevices.inputNames()
        let output = AudioDevices.defaultOutput()
        if output?.id != lastOutputID {
            lastOutputID = output?.id
            if let output, settings.autoStartOnHeadphones, !isOn, settings.trustedOutputs.contains(output.uid) {
                isOn = true
                return
            }
        }
        restartEngine()
    }

    private func checkOtherMicUse() {
        let app = settings.pauseDuringCalls ? AudioDevices.otherAppUsingMicrophone() : nil
        guard app != otherMicApp else { return }
        otherMicApp = app
        log.info("Other app using the mic: \(app ?? "none", privacy: .public)")
        reconcile()
    }

    // If Core Audio stops delivering mic audio without an error, start over.
    private func checkEngineIsAlive() {
        guard engine.isRunning else { return }
        let frames = engine.inputFrames
        defer { lastInputFrames = frames }
        if frames == lastInputFrames {
            log.error("Mic audio stalled, restarting")
            restartEngine()
        }
    }

    // MARK: Sound recognition

    private func heard(_ scores: [String: Double]) {
        if let top = scores.max(by: { $0.value < $1.value }) {
            log.debug("Heard \(top.key, privacy: .public) (\(Int(top.value * 100))%)")
        }
        if settings.duckingEnabled, isListening {
            // One-off false positives are common, so wait for two speech results in a row.
            if (scores["speech"] ?? 0) >= 0.8 {
                speechStreak += 1
                lastSpeech = Date()
                if speechStreak >= 2 { startDucking() }
            } else {
                speechStreak = 0
            }
        }

        guard settings.alertsEnabled else { return }
        for sound in settings.alertSounds {
            let confidence = sound.labels.compactMap { scores[$0] }.max() ?? 0
            guard confidence >= 0.75 else { continue }
            if let cooldown = alertCooldowns[sound], cooldown > Date() { continue }
            alertCooldowns[sound] = Date().addingTimeInterval(20)
            alert(sound)
        }
    }

    private func alert(_ sound: AlertSound) {
        log.info("Heard \(sound.title, privacy: .public)")
        alerts.send(sound)

        let content = UNMutableNotificationContent()
        content.title = "\(sound.title) nearby"
        content.body = isListening ? "OpenEar heard it around you." : "OpenEar is letting the room in for 30 seconds."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))

        guard settings.alertTurnsOnAmbient, !isOn else { return }
        alertListenUntil = Date().addingTimeInterval(30)
        reconcile()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.5) { [weak self] in self?.reconcile() }
    }

    // MARK: Ducking

    private func startDucking() {
        guard !isDucking, let output = engine.config?.outputDevice else { return }
        let reduction = ducker.duck(device: output, by: Float(settings.duckAmount))
        duckingUnavailable = reduction == 0
        guard reduction > 0.5 else { return }
        log.info("Ducking other audio by \(reduction) dB")
        isDucking = true
        duckCompensation = reduction
        engine.setParams(params)
    }

    private func checkDucking() {
        if isDucking, Date().timeIntervalSince(lastSpeech) > 3 { endDucking(immediately: false) }
    }

    /// Takes OpenEar's boost away first and the system volume back second, so nothing is ever briefly too loud.
    private func endDucking(immediately: Bool) {
        speechStreak = 0
        guard isDucking else { return }
        isDucking = false
        duckCompensation = 0
        engine.setParams(params)
        if immediately {
            ducker.restore()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, !self.isDucking else { return }
                self.ducker.restore()
            }
        }
    }

    // MARK: Timers and schedule

    private func every(_ seconds: TimeInterval, _ action: @escaping (OpenEarController) -> Void) {
        timers.append(Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                action(self)
            }
        })
    }

    private func scheduleOff(at date: Date) {
        offAt = date
        let work = DispatchWorkItem { [weak self] in self?.isOn = false }
        offWork = work
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + date.timeIntervalSinceNow, execute: work)
    }

    private func clearTimer() {
        offWork?.cancel()
        offWork = nil
        offAt = nil
        chosenChip = nil
    }

    // The schedule only flips the switch when a window starts or ends, so a manual toggle in between sticks.
    private func checkSchedule() {
        guard settings.scheduleEnabled else {
            lastInSchedule = nil
            return
        }
        let inSchedule = settings.isInSchedule(at: Date())
        if inSchedule != lastInSchedule {
            lastInSchedule = inSchedule
            isOn = inSchedule
        }
    }
}
