import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var controller: OpenEarController

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

            Toggle(isOn: $controller.settings.superHearing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Super hearing")
                    Text("Boosts quiet sounds and voices, caps loud ones")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Text("⌃⌥⌘O on/off  ·  ⌃⌥⌘S super hearing")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()

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

            Divider()

            Toggle("Schedule", isOn: $controller.settings.scheduleEnabled)
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

            Divider()

            Toggle("Launch at login", isOn: $controller.launchAtLogin)

            HStack {
                Button("Reset sound") { controller.resetAudioSettings() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 300)
    }

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
            Text("Click a chip to start. Click it again to stop")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var headline: String {
        guard controller.isOn else { return "Ambient sound is off" }
        guard let offAt = controller.offAt else { return "On, no time limit" }
        return "On until \(offAt.formatted(date: .omitted, time: .shortened))"
    }

    private func chip(_ title: String, _ chip: TimerChip, systemImage: String? = nil, action: (() -> Void)? = nil) -> some View {
        let isActive = controller.activeChip == chip
        return Button {
            if let action { action() } else { controller.select(chip) }
        } label: {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background(isActive ? Color.accentColor : Color.secondary.opacity(0.18), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var untilPicker: some View {
        UntilPicker(time: $controller.untilTime) { date in
            controller.select(.until, until: date)
            controller.showingUntilPicker = false
        }
    }

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
            Slider(value: value, in: range, step: 1)
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
