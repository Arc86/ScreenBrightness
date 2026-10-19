import AppKit

/// Dims a display past its hardware minimum, either by scaling its gamma table or by
/// laying a translucent black window over it.
@MainActor
final class SoftwareDimmer {
    enum Method: String, CaseIterable, Identifiable, Sendable {
        /// Deepest blacks and invisible to screenshots, but replaces the display's colour tables,
        /// which other colour tools (Night Shift, f.lux) also change. Ignored while HDR is on.
        case gamma
        /// Works alongside Night Shift and HDR. Hidden from screenshots and screen sharing.
        case overlay

        var id: Self { self }
    }

    /// Above everything except the HUD, including the menu bar and full-screen apps.
    static let overlayWindowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))

    private struct GammaTable {
        var red, green, blue: [CGGammaValue]
    }

    private(set) var factor = 1.0
    private var method: Method = .gamma
    private var displayID: CGDirectDisplayID?
    private var baseTable: GammaTable?
    private var overlay: NSWindow?

    func apply(_ factor: Double, to displayID: CGDirectDisplayID?, method: Method) {
        let factor = min(max(factor, 0.05), 1)
        guard factor < 1 else {
            if self.factor < 1 { reset() }
            return
        }
        guard let displayID else { return }
        if method != self.method || displayID != self.displayID {
            reset()
            self.method = method
            self.displayID = displayID
        }
        guard factor != self.factor || (method == .overlay && overlay == nil) else { return }
        self.factor = factor

        switch method {
        case .gamma: applyGamma(factor, to: displayID)
        case .overlay: applyOverlay(factor, to: displayID)
        }
    }

    /// Re-applies the current dimming, e.g. after the display was reconfigured and macOS reset its tables.
    func reapply() {
        guard factor < 1, let displayID else { return }
        let factor = self.factor
        let method = self.method
        reset()
        apply(factor, to: displayID, method: method)
    }

    func reset() {
        if method == .gamma && factor < 1 {
            CGDisplayRestoreColorSyncSettings()
        }
        baseTable = nil
        overlay?.orderOut(nil)
        overlay = nil
        factor = 1
    }

    // MARK: Gamma

    private func applyGamma(_ factor: Double, to displayID: CGDirectDisplayID) {
        guard let base = baseTable ?? captureTable(displayID) else { return }
        baseTable = base
        let scale = CGGammaValue(factor)
        let red = base.red.map { $0 * scale }
        let green = base.green.map { $0 * scale }
        let blue = base.blue.map { $0 * scale }
        CGSetDisplayTransferByTable(displayID, UInt32(red.count), red, green, blue)
    }

    private func captureTable(_ displayID: CGDirectDisplayID) -> GammaTable? {
        let capacity = 1024
        var table = GammaTable(red: .init(repeating: 0, count: capacity),
                               green: .init(repeating: 0, count: capacity),
                               blue: .init(repeating: 0, count: capacity))
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, UInt32(capacity), &table.red, &table.green, &table.blue, &count) == .success,
              count > 0 else { return nil }
        let used = Int(count)
        return GammaTable(red: Array(table.red.prefix(used)), green: Array(table.green.prefix(used)), blue: Array(table.blue.prefix(used)))
    }

    // MARK: Overlay

    private func applyOverlay(_ factor: Double, to displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return }
        let window = overlay ?? makeOverlay()
        overlay = window
        window.setFrame(screen.frame, display: false)
        window.alphaValue = 1 - factor
        window.orderFrontRegardless()
    }

    private func makeOverlay() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = Self.overlayWindowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Keep the overlay out of screenshots and screen sharing, like gamma dimming.
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        return window
    }
}
