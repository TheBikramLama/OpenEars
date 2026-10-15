import AppKit
import Carbon
import Combine
import Sparkle
import SwiftUI

// Plain AppKit start-up. A SwiftUI App needs a scene, and the only kind that fits a menu bar app
// (MenuBarExtra) grew with its content but never shrank. The menu bar item and its popover live in AppDelegate.
@main
@MainActor
enum OpenEarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = editMenu()
        app.run()
    }

    // Never shown in a menu bar app, but its shortcuts make copy and paste work in text fields.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let menu = NSMenu()
        menu.addItem(editItem)
        return menu
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = OpenEarController()
    private let hotKeys = HotKeys()
    private let hud = StatusHUD()
    // Checks the GitHub releases feed daily and offers new versions, verified with the EdDSA key in Info.plist.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func checkForUpdates() {
        NSApp.activate()
        updater.checkForUpdates(nil)
    }
    private var subscriptions = Set<AnyCancellable>()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMenuBarItem()

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
        controller.$focusOn.removeDuplicates().dropFirst()
            .sink { [hud] isOn in
                hud.show(symbol: "headphones", text: isOn ? "Focus sounds on" : "Focus sounds off")
            }
            .store(in: &subscriptions)
        controller.alerts
            .sink { [hud] sound in hud.show(symbol: sound.symbol, text: "\(sound.title) nearby") }
            .store(in: &subscriptions)
    }

    private func setUpMenuBarItem() {
        let menu = NSHostingController(rootView: MenuView(controller: controller) { [weak self] in
            self?.popover.performClose(nil)
            self?.checkForUpdates()
        })
        // The popover follows the SwiftUI content's size, animating as sections open and close.
        menu.sizingOptions = .preferredContentSize
        popover.contentViewController = menu
        popover.behavior = .transient
        popover.animates = true

        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        controller.$isListening.combineLatest(controller.$settings.map(\.superHearing), controller.$focusPlaying)
            .removeDuplicates { $0 == $1 }
            .sink { [statusItem] listening, superHearing, focus in
                statusItem.button?.image = MenuBarIcon.image(listening: listening, superHearing: superHearing, focus: focus)
            }
            .store(in: &subscriptions)
    }

    // Left click opens the full menu. Right click, or Control-click, shows quick actions.
    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            quickMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            // Activate so the pickers and text fields inside take keyboard input.
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func quickMenu() -> NSMenu {
        let menu = NSMenu()
        let ambient = menu.addItem(withTitle: "Ambient Sound", action: #selector(toggleAmbient), keyEquivalent: "")
        ambient.state = controller.isOn ? .on : .off
        let superHearing = menu.addItem(withTitle: "Super Hearing", action: #selector(toggleSuperHearing), keyEquivalent: "")
        superHearing.state = controller.settings.superHearing ? .on : .off
        let focus = menu.addItem(withTitle: "Focus Sounds", action: #selector(toggleFocus), keyEquivalent: "")
        focus.state = controller.focusOn ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit OpenEar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        return menu
    }

    @objc private func toggleAmbient() { controller.isOn.toggle() }
    @objc private func toggleSuperHearing() { controller.settings.superHearing.toggle() }
    @objc private func toggleFocus() { controller.focusOn.toggle() }
    @objc private func checkForUpdatesFromMenu() { checkForUpdates() }

    /// openear://on, off, toggle, super, focus. For Shortcuts, Raycast or scripts.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host {
            case "on": controller.isOn = true
            case "off": controller.isOn = false
            case "toggle": controller.isOn.toggle()
            case "super": controller.settings.superHearing.toggle()
            case "focus": controller.focusOn.toggle()
            default: break
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Puts the system volume back if OpenEar quits mid-duck.
        controller.shutdown()
    }
}

enum MenuBarIcon {
    // Tinted while active so it stands out from the monochrome menu bar.
    static func image(listening: Bool, superHearing: Bool, focus: Bool) -> NSImage {
        // The room takes priority: hold-to-hear and alerts can let it in during Focus.
        let name = listening ? (superHearing ? "ear.badge.waveform" : "ear.fill") : focus ? "headphones" : "ear"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "OpenEar") ?? NSImage()
        // Focus uses the plain menu bar style, like the idle ear: indigo was too dark to see.
        guard listening else {
            image.isTemplate = true
            return image
        }
        let color: NSColor = superHearing ? .systemPurple : .systemTeal
        let tinted = image.withSymbolConfiguration(.init(paletteColors: [color])) ?? image
        tinted.isTemplate = false
        return tinted
    }
}
