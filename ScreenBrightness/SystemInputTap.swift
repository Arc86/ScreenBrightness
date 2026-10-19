import AppKit
import ApplicationServices
import Observation

/// A system-wide event tap for input macOS doesn't hand to the app on its own:
/// - the keyboard brightness keys (F1/F2 on Mac layouts), which go nowhere without a built-in display;
/// - the volume keys, when the controller wants them (sound playing through the monitor);
/// - scroll-wheel events over the menu bar icon, which macOS 26+ doesn't deliver to status items.
/// Both are swallowed once handled. Needs Accessibility access.
@MainActor
@Observable
final class SystemInputTap {
    enum VolumeKey {
        case up, down, mute
    }

    private(set) var isTrusted = AXIsProcessTrusted()

    @ObservationIgnored var onBrightnessKey: ((BrightnessDirection, _ fine: Bool) -> Void)?
    /// Returns whether the key was handled; unhandled volume keys pass through to macOS.
    @ObservationIgnored var onVolumeKey: ((VolumeKey, _ fine: Bool) -> Bool)?
    @ObservationIgnored var onStatusItemScroll: ((_ deltaY: Double, _ isPrecise: Bool) -> Void)?
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var trustPoll: Timer?
    /// Whether the last volume key-down was handled, so its key-up is swallowed too.
    @ObservationIgnored private var capturedVolumeKey = false

    // From IOKit/hidsystem/ev_keymap.h.
    private static let systemDefinedEventType: UInt32 = 14
    private static let auxControlButtonsSubtype: Int16 = 8
    private static let soundUpKey = 0
    private static let soundDownKey = 1
    private static let brightnessUpKey = 2
    private static let brightnessDownKey = 3
    private static let muteKey = 7

    func start() {
        isTrusted = AXIsProcessTrusted()
        if isTrusted {
            installTap()
        } else {
            pollForTrust()
        }
    }

    /// Shows the system prompt that sends the user to Privacy & Security › Accessibility.
    func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        start()
    }

    private func pollForTrust() {
        guard trustPoll == nil else { return }
        trustPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.trustPoll?.invalidate()
                self.trustPoll = nil
                self.start()
            }
        }
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(Self.systemDefinedEventType)
            | CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: systemInputCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            NSLog("ScreenBrightness: could not create event tap")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns true when the event was handled and should be swallowed.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .scrollWheel:
            return handleScroll(event)
        default:
            return type.rawValue == Self.systemDefinedEventType && handleSystemDefined(event)
        }
    }

    private func handleScroll(_ event: CGEvent) -> Bool {
        // Every scroll on the system passes through here, so do the cheap position check first.
        guard isOverStatusItem(event.location), let nsEvent = NSEvent(cgEvent: event) else { return false }
        if nsEvent.scrollingDeltaY != 0 {
            onStatusItemScroll?(nsEvent.scrollingDeltaY, nsEvent.hasPreciseScrollingDeltas)
        }
        return true
    }

    private func handleSystemDefined(_ event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxControlButtonsSubtype else { return false }

        let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
        let keyFlags = nsEvent.data1 & 0x0000_FFFF
        let isKeyDown = (keyFlags & 0xFF00) >> 8 == 0x0A
        // ⌥⇧ gives quarter steps, matching the built-in display behaviour.
        let fine = nsEvent.modifierFlags.isSuperset(of: [.option, .shift])

        switch keyCode {
        case Self.brightnessUpKey, Self.brightnessDownKey:
            if isKeyDown {
                onBrightnessKey?(keyCode == Self.brightnessUpKey ? .up : .down, fine)
            }
            return true
        case Self.soundUpKey, Self.soundDownKey, Self.muteKey:
            if isKeyDown {
                let key: VolumeKey = keyCode == Self.soundUpKey ? .up : keyCode == Self.soundDownKey ? .down : .mute
                capturedVolumeKey = onVolumeKey?(key, fine) ?? false
            }
            return capturedVolumeKey
        default:
            return false
        }
    }

    /// `location` is in global display coordinates (origin top-left of the main display).
    /// The app's status item is drawn in an NSStatusBarWindow, one per menu bar.
    private func isOverStatusItem(_ location: CGPoint) -> Bool {
        guard let mainHeight = NSScreen.screens.first?.frame.maxY else { return false }
        let point = NSPoint(x: location.x, y: mainHeight - location.y)
        return NSApp.windows.contains { window in
            window.isVisible
                && NSStringFromClass(type(of: window)).contains("StatusBarWindow")
                && window.frame.contains(point)
        }
    }
}

private func systemInputCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    // The tap's run loop source lives on the main run loop, so these never cross threads.
    nonisolated(unsafe) let tapPointer = userInfo
    nonisolated(unsafe) let tappedEvent = event
    let swallowed = MainActor.assumeIsolated {
        Unmanaged<SystemInputTap>.fromOpaque(tapPointer).takeUnretainedValue().handle(type: type, event: tappedEvent)
    }
    return swallowed ? nil : Unmanaged.passUnretained(event)
}
