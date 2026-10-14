import AppKit
import Carbon
import Combine
import SwiftUI

@main
struct OpenEarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: appDelegate.controller)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = OpenEarController()
    private let hotKeys = HotKeys()
    private let hud = StatusHUD()
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let modifiers = controlKey | optionKey | cmdKey
        hotKeys.register(keyCode: kVK_ANSI_O, modifiers: modifiers) { [controller] in
            controller.isOn.toggle()
        }
        hotKeys.register(keyCode: kVK_ANSI_S, modifiers: modifiers) { [controller] in
            controller.settings.superHearing.toggle()
        }
        hotKeys.register(keyCode: kVK_ANSI_H, modifiers: modifiers, onRelease: { [controller] in
            controller.setHolding(false)
        }) { [controller] in
            controller.setHolding(true)
        }

        // Announce every change, including ones made by the schedule.
        controller.$isOn.removeDuplicates().dropFirst()
            .sink { [hud] isOn in
                hud.show(symbol: isOn ? "ear.fill" : "ear", text: isOn ? "Ambient sound on" : "Ambient sound off")
            }
            .store(in: &subscriptions)
        controller.$settings.map(\.superHearing).removeDuplicates().dropFirst()
            .sink { [hud] isOn in
                hud.show(symbol: "ear.badge.waveform", text: isOn ? "Super hearing on" : "Super hearing off")
            }
            .store(in: &subscriptions)
        controller.alerts
            .sink { [hud] sound in hud.show(symbol: sound.symbol, text: "\(sound.title) nearby") }
            .store(in: &subscriptions)
    }

    /// openear://on, off, toggle, super. For Shortcuts, Raycast or scripts.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host {
            case "on": controller.isOn = true
            case "off": controller.isOn = false
            case "toggle": controller.isOn.toggle()
            case "super": controller.settings.superHearing.toggle()
            default: break
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Otherwise SoX keeps running after the app quits.
        controller.shutdown()
    }
}

struct MenuBarIcon: View {
    @ObservedObject var controller: OpenEarController

    var body: some View {
        Image(nsImage: icon)
    }

    // Tinted while active so it stands out from the monochrome menu bar.
    private var icon: NSImage {
        let superHearing = controller.settings.superHearing
        let name = !controller.isListening ? "ear" : superHearing ? "ear.badge.waveform" : "ear.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "OpenEar") ?? NSImage()
        guard controller.isListening else { return image }
        let color: NSColor = superHearing ? .systemPurple : .systemTeal
        let tinted = image.withSymbolConfiguration(.init(paletteColors: [color])) ?? image
        tinted.isTemplate = false
        return tinted
    }
}
