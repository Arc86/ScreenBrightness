import Foundation

enum BrightnessDirection: Sendable {
    case up, down
}

/// The app's single brightness scale. 0…100 is the monitor's hardware brightness; below 0 the
/// monitor stays at its minimum and the picture is dimmed further in software, down to `extraDimFloor`.
enum BrightnessLevel {
    static let extraDimFloor = -50.0
    /// Sixteen steps across the hardware range, like the built-in display keys.
    static let keyStep = 100.0 / 16
    /// How much of the picture is left at `extraDimFloor`.
    static let floorDimFactor = 0.2

    static func hardwareValue(for level: Double) -> Int {
        Int(min(max(level, 0), 100).rounded())
    }

    /// Multiplier for the picture: 1 at 0 and above, falling linearly to `floorDimFactor` at the floor.
    static func dimFactor(for level: Double) -> Double {
        guard level < 0 else { return 1 }
        let depth = min(level / extraDimFloor, 1)
        return 1 - (1 - floorDimFactor) * depth
    }

    /// The next level one step away, snapped to the step grid so repeated presses land on the same values.
    static func stepped(from level: Double, direction: BrightnessDirection, step: Double) -> Double {
        let delta = direction == .up ? step : -step
        return ((level + delta) / step).rounded() * step
    }
}
