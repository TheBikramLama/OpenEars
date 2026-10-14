import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var controller: OpenEarController
    let checkForUpdates: () -> Void

    private let buffers: [(frames: Int, label: String)] = [
        (64, "Lowest (may crackle)"),
        (128, "Low"),
        (256, "Normal"),
        (512, "Safe"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ambientCard

            Text(controller.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                featureTile("Super hearing", "ear.badge.waveform", $controller.settings.superHearing)
                featureTile("Noise reduction", "waveform.badge.minus", $controller.settings.noiseReduction)
            }

            presetRow

            Divider()

            sectionPicker
            if let section = controller.openSection {
                sectionPage(section)
                    // Only the contents fade. Animating the panel's own resize is what made it feel slow.
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }

            Divider()

            Toggle("Launch at login", isOn: $controller.launchAtLogin)

            Text("⌃⌥⌘O on/off  ·  ⌃⌥⌘S super hearing  ·  hold ⌃⌥⌘H to hear")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack {
                Button("Reset sound") { controller.resetAudioSettings() }
                Spacer()
                Button("Check for Updates…", action: checkForUpdates)
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 320)
        // The default translucent background turns grey and washed out over bright windows.
        .background(MenuMaterial().ignoresSafeArea())
    }

    // MARK: Top card

    private var ambientCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(headline).font(.headline)
                Spacer()
                Toggle("Ambient sound", isOn: $controller.isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                chip("15m", .minutes(15))
                chip("30m", .minutes(30))
                chip("1h", .minutes(60))
                chip("2h", .minutes(120))
                chip("4h", .minutes(240))
                chip("8h", .minutes(480))
                chip("∞", .forever)
                chip("Until…", .until, systemImage: "clock") { controller.showingUntilPicker = true }
                    .popover(isPresented: $controller.showingUntilPicker) { untilPicker }
            }
            LevelMeter(controller: controller)
        }
        .padding(12)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var headline: String {
        guard controller.isOn else { return "Ambient sound is off" }
        guard let offAt = controller.offAt else { return "On, no time limit" }
        return "On until \(offAt.formatted(date: .omitted, time: .shortened))"
    }

    private func chip(_ title: String, _ chip: TimerChip, systemImage: String? = nil, action: (() -> Void)? = nil) -> some View {
        pill(title, systemImage: systemImage, isActive: controller.activeChip == chip) {
            if let action { action() } else { controller.select(chip) }
        }
    }

    /// `leading` lines up icons and titles down a column, for lists like the alert sounds.
    private func pill(_ title: String, systemImage: String? = nil, isActive: Bool, leading: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let systemImage, leading {
                    HStack(spacing: 6) {
                        // Symbols differ in width, so give each the same slot to keep the titles aligned.
                        Image(systemName: systemImage).frame(width: 18)
                        Text(title)
                    }
                } else if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
            .padding(.vertical, 6)
            .padding(.horizontal, leading ? 12 : 4)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background(isActive ? Color.accentColor : Color.primary.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func featureTile(_ title: String, _ symbol: String, _ isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(isOn.wrappedValue ? Color.white : Color.primary)
                    .background(isOn.wrappedValue ? Color.accentColor : Color.primary.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(isOn.wrappedValue ? "On" : "Off").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var untilPicker: some View {
        UntilPicker(time: $controller.untilTime) { date in
            controller.select(.until, until: date)
            controller.showingUntilPicker = false
        }
    }

    // MARK: Presets

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(SoundPreset.builtIn + controller.settings.userPresets) { preset in
                    pill(preset.name, isActive: controller.activePreset?.name == preset.name) {
                        controller.apply(preset)
                    }
                    .contextMenu {
                        if controller.settings.userPresets.contains(preset) {
                            Button("Delete “\(preset.name)”") { controller.deletePreset(preset) }
                        }
                    }
                }
                pill("Save…", systemImage: "plus", isActive: false) { askForPresetName() }
            }
        }
    }

    private func askForPresetName() {
        let alert = NSAlert()
        alert.messageText = "Save sound as a preset"
        alert.informativeText = "Saves the current volume, tone, super hearing and noise reduction. Right-click a preset to delete it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Preset name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { controller.savePreset(named: name) }
        }
    }

    // MARK: Sections

    // The buttons never move when a page opens, so quick repeat clicks can't land on a slider below.
    private var sectionPicker: some View {
        HStack(spacing: 6) {
            sectionButton(.sound, "Sound", "slider.horizontal.3")
            sectionButton(.smart, "Smart", "sparkles")
            sectionButton(.schedule, "Schedule", "calendar")
        }
    }

    private func sectionButton(_ section: MenuSection, _ title: String, _ symbol: String) -> some View {
        pill(title, systemImage: symbol, isActive: controller.openSection == section) {
            controller.openSection = controller.openSection == section ? nil : section
        }
    }

    private func sectionPage(_ section: MenuSection) -> some View {
        Group {
            switch section {
            case .sound: soundSection
            case .smart: smartSection
            case .schedule: scheduleSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mic", selection: $controller.settings.inputDevice) {
                ForEach(micOptions, id: \.self) { Text($0).tag($0) }
            }
            slider("Volume", $controller.settings.gain, 0...40, unit: "dB")
            slider("Bass", $controller.settings.bass, -10...12, unit: "dB")
            slider("Treble", $controller.settings.treble, -12...6, unit: "dB")
            slider("Rumble cut", $controller.settings.highpass, 20...300, unit: "Hz")
            Picker("Latency", selection: $controller.settings.buffer) {
                ForEach(buffers, id: \.frames) { Text($0.label).tag($0.frames) }
            }
        }
    }

    private var smartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            option("Pause during calls", "Stops while another app uses the mic, like Zoom or FaceTime",
                   $controller.settings.pauseDuringCalls)

            option("Lower music when someone talks", "Turns other audio down while people speak nearby",
                   $controller.settings.duckingEnabled)
            if controller.settings.duckingEnabled {
                slider("Lower by", $controller.settings.duckAmount, 4...24, unit: "dB")
                if controller.duckingUnavailable {
                    Text("These headphones don't let apps change their volume.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            option("Sound alerts", "Notifies you about important sounds, even while ambient sound is off",
                   $controller.settings.alertsEnabled)
            if controller.settings.alertsEnabled {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    ForEach(AlertSound.allCases) { sound in
                        pill(sound.title, systemImage: sound.symbol, isActive: controller.settings.alertSounds.contains(sound), leading: true) {
                            if controller.settings.alertSounds.contains(sound) {
                                controller.settings.alertSounds.remove(sound)
                            } else {
                                controller.settings.alertSounds.insert(sound)
                            }
                        }
                    }
                }
                Toggle("Let the room in for 30 seconds", isOn: $controller.settings.alertTurnsOnAmbient)
            }

            option("Start when headphones connect", "Only for headphones you've used OpenEar with before",
                   $controller.settings.autoStartOnHeadphones)
            if controller.settings.autoStartOnHeadphones, !controller.settings.trustedOutputs.isEmpty {
                Button("Forget \(controller.settings.trustedOutputs.count) remembered headphones") {
                    controller.forgetHeadphones()
                }
                .font(.caption)
            }
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            option("Turn on automatically", "On during these hours, on the days you pick",
                   $controller.settings.scheduleEnabled)
            if controller.settings.scheduleEnabled {
                HStack {
                    DatePicker("From", selection: time($controller.settings.startMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("to", selection: time($controller.settings.endMinutes), displayedComponents: .hourAndMinute)
                }
                .labelsHidden()
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: weekday(day))
                            .toggleStyle(.button)
                    }
                }
            }
        }
    }

    private func option(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        // A plain switch Toggle sits right after its label, so switches ended up at different spots.
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    // MARK: Helpers

    // Keep the saved mic selectable even while it's unplugged.
    private var micOptions: [String] {
        let current = controller.settings.inputDevice
        return controller.inputs.contains(current) ? controller.inputs : [current] + controller.inputs
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // A step would draw a tick per value (281 for Rumble cut), which made the Sound page slow to open.
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: range)
        }
    }

    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date()
            },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func weekday(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { controller.settings.days.contains(day) },
            set: { isOn in
                if isOn { controller.settings.days.insert(day) } else { controller.settings.days.remove(day) }
            }
        )
    }
}

/// Live mic level, refreshed 20 times a second while the menu is open.
private struct LevelMeter: View {
    @ObservedObject var controller: OpenEarController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            let fraction = controller.isListening || controller.settings.alertsEnabled
                ? CGFloat(max(0, min(1, (controller.inputLevel + 60) / 60)))
                : 0
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule()
                            .fill(LinearGradient(colors: [.teal, .green, .yellow], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * fraction)
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

/// The same opaque-feeling material as system menus, kept active even when OpenEar isn't the frontmost app.
private struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
