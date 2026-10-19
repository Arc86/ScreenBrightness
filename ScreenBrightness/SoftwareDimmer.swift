import CoreGraphics

/// Dims a display past its hardware minimum by scaling its gamma table.
/// macOS restores the calibrated tables on quit; `reset()` does it sooner.
@MainActor
final class SoftwareDimmer {
    private struct Table {
        var red, green, blue: [CGGammaValue]
    }

    private(set) var factor = 1.0
    private var baseTable: Table?
    private var displayID: CGDirectDisplayID?

    func apply(_ factor: Double, to displayID: CGDirectDisplayID?) {
        let factor = min(max(factor, 0.05), 1)
        guard factor < 1 else {
            if self.factor < 1 { reset() }
            return
        }
        guard let displayID, factor != self.factor || displayID != self.displayID else { return }
        self.factor = factor
        if displayID != self.displayID { baseTable = nil }
        self.displayID = displayID

        guard let base = baseTable ?? captureTable(displayID) else { return }
        baseTable = base
        let scale = CGGammaValue(factor)
        let red = base.red.map { $0 * scale }
        let green = base.green.map { $0 * scale }
        let blue = base.blue.map { $0 * scale }
        CGSetDisplayTransferByTable(displayID, UInt32(red.count), red, green, blue)
    }

    /// Re-applies the current dimming, e.g. after the display was reconfigured and macOS reset its tables.
    func reapply() {
        guard factor < 1, let displayID else { return }
        let factor = self.factor
        reset()
        apply(factor, to: displayID)
    }

    func reset() {
        factor = 1
        baseTable = nil
        CGDisplayRestoreColorSyncSettings()
    }

    private func captureTable(_ displayID: CGDirectDisplayID) -> Table? {
        let capacity = 1024
        var table = Table(red: .init(repeating: 0, count: capacity),
                          green: .init(repeating: 0, count: capacity),
                          blue: .init(repeating: 0, count: capacity))
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, UInt32(capacity), &table.red, &table.green, &table.blue, &count) == .success,
              count > 0 else { return nil }
        let used = Int(count)
        return Table(red: Array(table.red.prefix(used)), green: Array(table.green.prefix(used)), blue: Array(table.blue.prefix(used)))
    }
}
