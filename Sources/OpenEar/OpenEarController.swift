import AppKit
import Darwin
import ServiceManagement

enum TimerChip: Hashable {
    case minutes(Int)
    case forever
    case until
}

@MainActor
final class OpenEarController: ObservableObject {
    @Published var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            if !isOn { clearTimer() }
            apply()
        }
    }

    @Published var settings: Settings {
        didSet { settingsChanged(from: oldValue) }
    }

    @Published private(set) var status = "Off"
    @Published private(set) var inputs: [String] = []
    @Published private(set) var offAt: Date?
    @Published private var chosenChip: TimerChip?

    // Held here because SwiftUI's @State macro isn't available when building without Xcode.
    @Published var showingUntilPicker = false
    @Published var untilTime = Date().addingTimeInterval(3600)

    /// The chip to highlight. Turning on any other way counts as no time limit.
    var activeChip: TimerChip? {
        guard isOn else { return nil }
        return chosenChip ?? .forever
    }

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

    // Release builds ship their own SoX. Fall back to Homebrew's for plain `swift run`.
    private let soxPath = [Bundle.main.url(forAuxiliaryExecutable: "sox")?.path, "/opt/homebrew/bin/sox", "/usr/local/bin/sox"]
        .compactMap { $0 }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    private var process: Process?
    private var lastSoxMessage: String?
    private var restartWork: DispatchWorkItem?
    private var offWork: DispatchWorkItem?
    private var scheduleTimer: Timer?
    private var watchdogTimer: Timer?
    private var lastCPUTime: UInt64 = 0
    private var lastInSchedule: Bool?

    init() {
        settings = Settings.load()
        inputs = AudioDevices.inputNames()

        AudioDevices.observeChanges { [weak self] in
            guard let self else { return }
            inputs = AudioDevices.inputNames()
            // Re-check the speaker guard whenever headphones come or go.
            if isOn { apply() }
        }

        // CoreAudio drops SoX's input stream across sleep, so start fresh on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isOn else { return }
                self.apply()
            }
        }

        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSchedule() }
        }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSoxIsAlive() }
        }
        checkSchedule()
    }

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

    func resetAudioSettings() {
        let defaults = Settings()
        settings.gain = defaults.gain
        settings.bass = defaults.bass
        settings.treble = defaults.treble
        settings.highpass = defaults.highpass
        settings.buffer = defaults.buffer
    }

    func shutdown() {
        stop()
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

    private func settingsChanged(from old: Settings) {
        guard settings != old else { return }
        settings.save()

        if settings.soxArguments != old.soxArguments, isOn {
            // Sliders fire continuously while dragging, so wait for them to settle before restarting SoX.
            restartWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.apply() }
            restartWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        if settings.scheduleEnabled != old.scheduleEnabled || settings.startMinutes != old.startMinutes
            || settings.endMinutes != old.endMinutes || settings.days != old.days {
            lastInSchedule = nil
            checkSchedule()
        }
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

    // When CoreAudio stops delivering mic audio, SoX waits forever without exiting.
    // A live SoX always burns some CPU, so a frozen CPU counter means it's stuck.
    private func checkSoxIsAlive() {
        guard let process, process.isRunning else { return }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(process.processIdentifier, PROC_PIDTASKINFO, 0, &info, size) == size else { return }
        let cpuTime = info.pti_total_user + info.pti_total_system
        defer { lastCPUTime = cpuTime }
        if cpuTime == lastCPUTime {
            apply()
        }
    }

    private func apply() {
        stop()
        guard isOn else {
            status = "Off"
            return
        }
        guard let soxPath else {
            status = "SoX not found. Run: brew install sox"
            return
        }
        if let output = AudioDevices.defaultOutput(), output.isBuiltInSpeaker {
            status = "Paused: output is \(output.name). Plug in your IEMs."
            return
        }
        start(soxPath)
    }

    private func start(_ soxPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: soxPath)
        process.arguments = settings.soxArguments
        process.standardOutput = FileHandle.nullDevice

        // Drain stderr as it arrives. A full pipe would block SoX mid-write and freeze the audio.
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init)
            Task { @MainActor in self?.lastSoxMessage = line }
        }
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in self?.processEnded(ended) }
        }

        lastSoxMessage = nil
        lastCPUTime = 0
        do {
            try process.run()
            self.process = process
            status = "Listening through \(settings.inputDevice)"
        } catch {
            status = "Couldn't start SoX: \(error.localizedDescription)"
        }
    }

    private func processEnded(_ ended: Process) {
        // stop() clears `process` first, so only unexpected exits get here.
        guard ended === process else { return }
        process = nil
        status = "SoX stopped: \(lastSoxMessage ?? "exit code \(ended.terminationStatus)")"
    }

    private func stop() {
        restartWork?.cancel()
        guard let process else { return }
        self.process = nil
        // SIGKILL, not terminate(): a stuck SoX ignores SIGTERM. It only writes to the audio device, so nothing is lost.
        kill(process.processIdentifier, SIGKILL)
    }
}
