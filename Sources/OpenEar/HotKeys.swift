import Carbon

/// System-wide shortcuts via Carbon hotkeys, which work without Accessibility permission.
@MainActor
final class HotKeys {
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { hotKeys.handlers[id.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func register(keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F45_4152), id: id) // 'OEAR'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if let ref { refs.append(ref) }
    }
}
