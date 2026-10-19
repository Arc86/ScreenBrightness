import Foundation

/// A video input on the monitor, identified by its MCCS input source value (VCP 0x60).
struct MonitorInput: Identifiable, Equatable, Sendable {
    let code: Int

    var id: Int { code }

    var name: String {
        switch code {
        case 0x01, 0x02: "VGA \(code)"
        case 0x03, 0x04: "DVI \(code - 2)"
        case 0x0F: "DisplayPort"
        // On monitors with one DisplayPort and one USB-C port, the USB-C port reports as DP 2.
        case 0x10: "USB-C (DP 2)"
        case 0x11: "HDMI 1"
        case 0x12: "HDMI 2"
        case 0x1B: "USB-C"
        default: String(format: "Input 0x%02X", code)
        }
    }

    /// Parses the `60(…)` list out of a capabilities string.
    static func supported(inCapabilities capabilities: String) -> [MonitorInput] {
        guard let start = capabilities.range(of: " 60(") ?? capabilities.range(of: "(60("),
              let end = capabilities[start.upperBound...].firstIndex(of: ")") else { return [] }
        return capabilities[start.upperBound..<end]
            .split(separator: " ")
            .compactMap { Int($0, radix: 16) }
            .map(MonitorInput.init(code:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
