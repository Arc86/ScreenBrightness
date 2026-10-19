import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a virtual key code plus modifiers.
struct Hotkey: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    static let defaultBrighter = Hotkey(keyCode: UInt32(kVK_UpArrow), modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)
    static let defaultDimmer = Hotkey(keyCode: UInt32(kVK_DownArrow), modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)

    /// Builds a shortcut from a key press, or nil when the press can't stand alone as a global shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let isFunctionKey = Self.functionKeyNames[Int(event.keyCode)] != nil
        guard !flags.isEmpty || isFunctionKey else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue)
    }

    init(keyCode: UInt32, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var displayString: String {
        var text = ""
        if modifierFlags.contains(.control) { text += "⌃" }
        if modifierFlags.contains(.option) { text += "⌥" }
        if modifierFlags.contains(.shift) { text += "⇧" }
        if modifierFlags.contains(.command) { text += "⌘" }
        return text + keyName
    }

    private var keyName: String {
        if let name = Self.specialKeyNames[Int(keyCode)] ?? Self.functionKeyNames[Int(keyCode)] { return name }
        return Self.character(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifierFlags.contains(.command) { result |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { result |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { result |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// The character the key produces on the current keyboard layout, ignoring modifiers.
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = unsafeBitCast(layoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layout) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { keyboardLayout in
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(keyboardLayout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState, characters.count, &length, &characters)
            return status == noErr && length > 0 ? String(utf16CodeUnits: characters, count: length) : nil
        }
    }
}

/// Registers the brighter/dimmer shortcuts with the system. Holding a shortcut repeats it.
/// Carbon hot keys need no permissions, unlike the event tap.
@MainActor
final class HotkeyCenter {
    var onPress: ((BrightnessDirection) -> Void)?
    /// Directions whose shortcut couldn't be registered, usually because another app owns it.
    private(set) var conflicts: Set<BrightnessDirection> = []

    private var registrations: [BrightnessDirection: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var repeatTask: Task<Void, Never>?

    private static let signature: OSType = 0x5342_5254 // "SBRT"

    func register(brighter: Hotkey?, dimmer: Hotkey?) {
        installHandlerIfNeeded()
        for ref in registrations.values { UnregisterEventHotKey(ref) }
        registrations = [:]
        conflicts = []

        for (direction, hotkey) in [(BrightnessDirection.up, brighter), (.down, dimmer)] {
            guard let hotkey else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: direction == .up ? 1 : 2)
            let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registrations[direction] = ref
            } else {
                conflicts.insert(direction)
            }
        }
    }

    fileprivate func handle(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr, id.signature == Self.signature else { return OSStatus(eventNotHandledErr) }
        let direction: BrightnessDirection = id.id == 1 ? .up : .down

        repeatTask?.cancel()
        if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
            onPress?(direction)
            // Carbon hot keys don't auto-repeat, so repeat while held, like the system brightness keys.
            repeatTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                while !Task.isCancelled {
                    self?.onPress?(direction)
                    try? await Task.sleep(for: .milliseconds(90))
                }
            }
        }
        return noErr
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        let types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, types.count, types,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

private func hotkeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    // Carbon delivers hot key events on the main thread.
    nonisolated(unsafe) let center = userData
    nonisolated(unsafe) let hotkeyEvent = event
    return MainActor.assumeIsolated {
        Unmanaged<HotkeyCenter>.fromOpaque(center).takeUnretainedValue().handle(hotkeyEvent)
    }
}
