import Foundation

/// What the monitor says it supports, parsed from its MCCS capabilities string,
/// e.g. `(prot(monitor)…vcp(10 12 60(11 12 0F 10) 62 8D)…)`.
struct MonitorCapabilities: Equatable, Sendable {
    let vcpCodes: Set<UInt8>
    /// Allowed values for codes that list them, e.g. `60(11 12 0F 10)`.
    let valueLists: [UInt8: [Int]]

    init(parsing capabilities: String) {
        var codes: Set<UInt8> = []
        var lists: [UInt8: [Int]] = [:]
        if let vcpStart = capabilities.range(of: "vcp(") {
            // Walk the vcp(…) list. Codes sit at depth 1; a code followed by "(…)" lists its allowed values.
            var depth = 1
            var token = ""
            var lastCode: UInt8?
            func endToken() {
                if depth == 1, let code = UInt8(token, radix: 16) {
                    codes.insert(code)
                    lastCode = code
                } else if depth == 2, let lastCode, let value = Int(token, radix: 16) {
                    lists[lastCode, default: []].append(value)
                }
                token = ""
            }
            for character in capabilities[vcpStart.upperBound...] {
                switch character {
                case "(":
                    endToken()
                    depth += 1
                case ")":
                    endToken()
                    depth -= 1
                case " ":
                    endToken()
                default:
                    token.append(character)
                }
                if depth == 0 { break }
            }
        }
        vcpCodes = codes
        valueLists = lists
    }

    var inputs: [MonitorInput] {
        (valueLists[DDCProtocol.VCP.input.rawValue] ?? [])
            .map(MonitorInput.init(code:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Only offered when the monitor lists its presets, since writing an unlisted value can hang
    /// a monitor's DDC controller until it is power-cycled.
    var colorPresets: [ColorPreset] {
        guard supports(.colorPreset) else { return [] }
        return (valueLists[DDCProtocol.VCP.colorPreset.rawValue] ?? []).map(ColorPreset.init(code:))
    }

    func supports(_ code: DDCProtocol.VCP) -> Bool {
        vcpCodes.contains(code.rawValue)
    }
}

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
}

/// A colour temperature preset, identified by its MCCS value (VCP 0x14).
struct ColorPreset: Identifiable, Equatable, Hashable, Sendable {
    let code: Int

    var id: Int { code }

    var name: String {
        switch code {
        case 0x01: "sRGB"
        case 0x02: "Native"
        case 0x03: "4000 K"
        case 0x04: "5000 K"
        case 0x05: "6500 K"
        case 0x06: "7500 K"
        case 0x07: "8200 K"
        case 0x08: "9300 K"
        case 0x09: "10000 K"
        case 0x0A: "11500 K"
        case 0x0B...0x0D: "User \(code - 0x0A)"
        default: String(format: "Preset 0x%02X", code)
        }
    }

    /// Warm presets get an orange swatch, cool ones blue.
    var kelvin: Int? {
        [0x03: 4000, 0x04: 5000, 0x05: 6500, 0x06: 7500, 0x07: 8200, 0x08: 9300, 0x09: 10000, 0x0A: 11500][code]
    }

    /// Some monitors report a different number than the one that selected the preset.
    /// Maps a value read back from the monitor to the value to write, per monitor model.
    static func fromReading(_ value: Int, monitor storageKey: String?) -> Int {
        guard let storageKey, let map = readingQuirks[storageKey] else { return value }
        return map[value] ?? value
    }

    private static let readingQuirks: [String: [Int: Int]] = [
        // MSI MPG321CX OLED: measured by writing each listed value and reading it back.
        "13929-15830": [77: 0x01, 6: 0x04, 5: 0x05, 10: 0x06, 1: 0x07, 4: 0x08, 11: 0x0A, 7: 0x0B],
    ]
}
