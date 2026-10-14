import AppKit
import SwiftUI

/// Big hour:minute wheels for the "Until…" chip. Scroll or click the faded neighbours to change a value.
struct UntilPicker: View {
    @Binding var time: Date
    let onStart: (Date) -> Void

    private var calendar: Calendar { .current }
    private var hour: Int { calendar.component(.hour, from: time) }
    private var minute: Int { calendar.component(.minute, from: time) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Until").font(.headline)
                Spacer()
                DatePicker("Until", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.field)
                    .labelsHidden()
            }

            HStack(spacing: 10) {
                WheelColumn(value: hour, count: 24) { set(hour: $0, minute: minute) }
                Text(":").font(.system(size: 34, weight: .medium)).foregroundStyle(.secondary)
                WheelColumn(value: minute, count: 60) { set(hour: hour, minute: $0) }
            }
            .frame(maxWidth: .infinity)

            Divider()

            HStack {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Start") { onStart(target) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    // A time earlier than now means tomorrow.
    private var target: Date {
        calendar.nextDate(after: Date(), matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime) ?? time
    }

    private var summary: String {
        let day = calendar.isDateInToday(target) ? "Today" : "Tomorrow"
        let minutes = max(1, Int(target.timeIntervalSinceNow / 60))
        let length = minutes < 60 ? "\(minutes)m"
            : minutes % 60 == 0 ? "\(minutes / 60)h"
            : "\(minutes / 60)h \(minutes % 60)m"
        return "\(day) · \(length)"
    }

    private func set(hour: Int, minute: Int) {
        time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? time
    }
}

private struct WheelColumn: View {
    let value: Int
    let count: Int
    let onChange: (Int) -> Void

    var body: some View {
        VStack(spacing: 6) {
            neighbour(-1)
            Text(String(format: "%02d", value))
                .font(.system(size: 44, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
                .frame(width: 92, height: 68)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            neighbour(1)
        }
        .overlay(ScrollWheelCatcher { step($0) })
    }

    private func neighbour(_ offset: Int) -> some View {
        Button { step(offset) } label: {
            Text(String(format: "%02d", wrapped(value + offset)))
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func step(_ offset: Int) {
        onChange(wrapped(value + offset))
    }

    private func wrapped(_ n: Int) -> Int {
        (n % count + count) % count
    }
}

/// SwiftUI has no scroll-wheel event on macOS, so catch it in AppKit. Clicks pass through to the buttons underneath.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        CatcherView()
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onStep = onStep
    }

    final class CatcherView: NSView {
        var onStep: ((Int) -> Void)?
        private var pending: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }

        override func scrollWheel(with event: NSEvent) {
            // Trackpads send many tiny deltas, so add them up and step once per notch.
            pending += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
            while abs(pending) >= 1 {
                let direction: CGFloat = pending > 0 ? 1 : -1
                onStep?(pending > 0 ? -1 : 1)
                pending -= direction
            }
        }
    }
}
